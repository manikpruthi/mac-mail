import Foundation
import Network

enum NetError: Error, LocalizedError {
    case closed
    case timeout
    case protocolError(String)
    case auth(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .closed: return "The connection to the mail server closed."
        case .timeout: return "The mail server took too long to answer."
        case .protocolError(let m): return "Unexpected server reply: \(m)"
        case .auth(let m): return "Sign-in failed: \(m)"
        case .server(let m): return m
        }
    }

    var isConnectionProblem: Bool {
        switch self {
        case .closed, .timeout, .protocolError: return true
        default: return false
        }
    }
}

/// The "connection closed" callback of a transport. Set by the stream's owner and called from the
/// transport's own queue or thread, so it sits behind a lock.
private final class ClosedHandlerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    func set(_ h: @escaping @Sendable () -> Void) { lock.lock(); handler = h; lock.unlock() }
    func call() {
        lock.lock(); let h = handler; lock.unlock()
        h?()
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// The byte pipe under a mail connection: implicit TLS (Network.framework) or a plain socket that can be
/// upgraded with STARTTLS (Foundation streams, which can switch TLS on mid-connection; NWConnection can't).
protocol ByteTransport: AnyObject, Sendable {
    func open() async throws
    func send(_ data: Data) async throws
    /// Next chunk of bytes; throws NetError.closed at end of stream.
    func receive() async throws -> Data
    /// Switches the established plain connection to TLS (STARTTLS). Certificates are verified for the host.
    func startTLS() async throws
    /// Throws away plaintext already received but not yet delivered (STARTTLS must discard pre-handshake bytes).
    func discardBuffered()
    func close()
    /// Called once when the connection fails or is closed underneath us.
    func setClosedHandler(_ handler: @escaping @Sendable () -> Void)
}

/// Implicit TLS from the first byte (IMAP 993, SMTP 465).
final class NWTransport: ByteTransport, @unchecked Sendable {
    private let connection: NWConnection
    /// False for a port no endpoint can have (0); open() then fails instead of dialling a default.
    private let validPort: Bool

    init(host: String, port: UInt16) {
        validPort = port != 0
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        tcp.connectionTimeout = 15
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 993, using: params)
    }

    private let closedHandler = ClosedHandlerBox()
    func setClosedHandler(_ handler: @escaping @Sendable () -> Void) { closedHandler.set(handler) }

    func open() async throws {
        guard validPort else { throw NetError.server("The server port isn't valid. Check the account's settings.") }
        let once = OnceFlag()
        let conn = connection
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { c.resume() }
                // .waiting (no route yet) fails the attempt on purpose: callers treat it as "offline" and
                // retry on the next trigger, instead of holding a command until the network returns.
                case .failed(let e), .waiting(let e): if once.take() { c.resume(throwing: e) }
                case .cancelled: if once.take() { c.resume(throwing: NetError.closed) }
                default: break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
        let handler = closedHandler
        conn.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: handler.call()
            default: break
            }
        }
    }

    func send(_ data: Data) async throws {
        let conn = connection
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    func receive() async throws -> Data {
        let conn = connection
        return try await withCheckedThrowingContinuation { c in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let error { c.resume(throwing: error) }
                else if let data, !data.isEmpty { c.resume(returning: data) }
                else if isComplete { c.resume(throwing: NetError.closed) }
                else { c.resume(returning: Data()) }
            }
        }
    }

    func startTLS() async throws {
        throw NetError.protocolError("this connection already uses TLS")
    }

    func discardBuffered() {} // bytes are only delivered through receive(), nothing is buffered

    func close() { connection.cancel() }
}

/// A plain TCP connection that is upgraded to TLS with STARTTLS (IMAP 143, SMTP 587). Streams live on their
/// own run-loop thread; every stream call is made there, and callers wait on continuations (F-01).
final class StartTLSTransport: NSObject, ByteTransport, StreamDelegate, @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private var input: InputStream?
    private var output: OutputStream?
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    // Run-loop-thread state.
    private var buffer = Data()
    private var pendingRead: CheckedContinuation<Data, Error>?
    private var pendingWrite: (data: Data, offset: Int, cont: CheckedContinuation<Void, Error>)?
    private var openCont: CheckedContinuation<Void, Error>?
    private var inputOpen = false
    private var outputOpen = false
    private var failure: Error?
    private var atEnd = false
    private var finished = false
    private let closedHandler = ClosedHandlerBox()
    /// Guards `stopped` and the hand-off of blocks to the run loop.
    private let threadLock = NSLock()
    /// Set (under the lock) once the run-loop thread will take no more blocks.
    private var stopped = false

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func setClosedHandler(_ handler: @escaping @Sendable () -> Void) { closedHandler.set(handler) }

    /// Runs `block` on the streams' run-loop thread. Once that thread has stopped, a queued block would
    /// never run and its caller would wait forever, so `stopped` is checked under the same lock that
    /// shutDown() sets it under: a block is either queued before the thread's final drain, or run here.
    /// By then the thread is gone or draining and every block only reports the closed state.
    private func onThread(_ block: @escaping () -> Void) {
        threadLock.lock()
        guard let rl = runLoop else {
            threadLock.unlock()
            block() // not opened yet: nothing else can be running
            return
        }
        if stopped {
            // Late callers run one at a time; shutDown() returns before it would take this lock again.
            block()
            threadLock.unlock()
            return
        }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue, block)
        threadLock.unlock()
        CFRunLoopWakeUp(rl)
    }

    func open() async throws {
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            let t = Thread { [weak self] in
                guard let self else { started.resume(); return }
                self.runLoop = CFRunLoopGetCurrent()
                // A port keeps the run loop alive until close() stops it.
                RunLoop.current.add(Port(), forMode: .default)
                started.resume()
                while !self.finished {
                    _ = RunLoop.current.run(mode: .default, before: .distantFuture)
                }
                // Blocks queued just before the stop was recorded still run (each sees the closed state
                // and fails its caller), so no continuation is left waiting on a dead thread.
                while CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource {}
                _ = CFRunLoopRunInMode(.defaultMode, 0, false)
            }
            t.name = "MacMail STARTTLS \(host)"
            t.qualityOfService = .userInitiated
            thread = t
            t.start()
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            onThread { [self] in
                // Closed before it opened (the connect watchdog, or a reset).
                guard !finished else { c.resume(throwing: failure ?? NetError.closed); return }
                guard port != 0 else {
                    c.resume(throwing: NetError.server("The server port isn't valid. Check the account's settings."))
                    return
                }
                var i: InputStream?
                var o: OutputStream?
                // Only creates the stream pair; the name lookup and the connect happen asynchronously
                // after open(), so the connect watchdog's close() can interrupt them.
                Stream.getStreamsToHost(withName: host, port: Int(port), inputStream: &i, outputStream: &o)
                guard let i, let o else { c.resume(throwing: NetError.closed); return }
                input = i
                output = o
                openCont = c
                for s in [i, o] as [Stream] {
                    s.delegate = self
                    s.schedule(in: .current, forMode: .default)
                    s.open()
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            onThread { [self] in
                if let failure { c.resume(throwing: failure); return }
                guard output != nil, !finished else { c.resume(throwing: NetError.closed); return }
                // One write at a time: replacing a write in flight would leave its caller waiting forever.
                guard pendingWrite == nil else {
                    c.resume(throwing: NetError.protocolError("two writes on one connection"))
                    return
                }
                pendingWrite = (data, 0, c)
                pumpWrite()
            }
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            onThread { [self] in
                if buffer.isEmpty, let input, input.hasBytesAvailable { readAvailable() }
                if !buffer.isEmpty {
                    let d = buffer
                    buffer = Data()
                    c.resume(returning: d)
                } else if let failure {
                    c.resume(throwing: failure)
                } else if atEnd || finished {
                    c.resume(throwing: NetError.closed)
                } else if pendingRead != nil {
                    // One read at a time, for the same reason as writes.
                    c.resume(throwing: NetError.protocolError("two reads on one connection"))
                } else {
                    pendingRead = c
                }
            }
        }
    }

    func startTLS() async throws {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            onThread { [self] in
                // Pre-TLS plaintext buffered so far is discarded with the TLS switch, atomically on the
                // run-loop thread so no event can buffer more plaintext in between (STARTTLS injection).
                buffer.removeAll()
                // Setting the security level on an open stream starts the TLS handshake on the next I/O,
                // with the peer name (and so certificate check) taken from the host we connected to.
                let level = StreamSocketSecurityLevel.negotiatedSSL
                input?.setProperty(level, forKey: .socketSecurityLevelKey)
                output?.setProperty(level, forKey: .socketSecurityLevelKey)
                c.resume()
            }
        }
    }

    func discardBuffered() {
        onThread { [self] in buffer.removeAll() }
    }

    func close() {
        onThread { [self] in shutDown(NetError.closed) }
    }

    // MARK: Run-loop thread

    private func readAvailable() {
        guard let input else { return }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while input.hasBytesAvailable {
            let n = input.read(&chunk, maxLength: chunk.count)
            if n > 0 { buffer.append(chunk, count: n) } else { break }
            if buffer.count > 1024 * 1024 { break }
        }
    }

    private func pumpWrite() {
        guard let output, var w = pendingWrite else { return }
        while w.offset < w.data.count && output.hasSpaceAvailable {
            let n = w.data.withUnsafeBytes { raw -> Int in
                let base = raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: w.offset)
                return output.write(base, maxLength: min(64 * 1024, w.data.count - w.offset))
            }
            if n < 0 { pendingWrite = nil; w.cont.resume(throwing: output.streamError ?? NetError.closed); return }
            if n == 0 { break }
            w.offset += n
        }
        if w.offset >= w.data.count {
            pendingWrite = nil
            w.cont.resume()
        } else {
            pendingWrite = w
        }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            if aStream === input { inputOpen = true } else { outputOpen = true }
            if inputOpen && outputOpen, let c = openCont { openCont = nil; c.resume() }
        case .hasBytesAvailable:
            if pendingRead != nil || buffer.count < 1024 * 1024 { readAvailable() }
            if let c = pendingRead, !buffer.isEmpty {
                pendingRead = nil
                let d = buffer
                buffer = Data()
                c.resume(returning: d)
            }
        case .hasSpaceAvailable:
            pumpWrite()
        case .errorOccurred:
            shutDown(aStream.streamError ?? NetError.closed)
        case .endEncountered:
            atEnd = true
            if let c = pendingRead, buffer.isEmpty { pendingRead = nil; c.resume(throwing: NetError.closed) }
            closedHandler.call()
        default:
            break
        }
    }

    private func shutDown(_ error: Error) {
        guard !finished else { return }
        failure = failure ?? error
        finished = true
        threadLock.lock()
        stopped = true
        threadLock.unlock()
        for s in [input, output].compactMap({ $0 }) as [Stream] {
            s.delegate = nil
            s.close()
            s.remove(from: .current, forMode: .default)
        }
        if let c = openCont { openCont = nil; c.resume(throwing: error) }
        if let c = pendingRead { pendingRead = nil; c.resume(throwing: error) }
        if let w = pendingWrite { pendingWrite = nil; w.cont.resume(throwing: error) }
        closedHandler.call()
        if let rl = runLoop { CFRunLoopStop(rl) }
    }
}

/// A buffered byte stream (TLS from the start, or upgraded with STARTTLS) with line and byte-count reads.
actor TLSStream {
    /// A single response line longer than this is a protocol error, not data.
    static let maxLineLength = 1024 * 1024
    /// A single literal read larger than this is refused (matches IMAPParser.maxLiteralSize).
    static let maxReadSize = 64 * 1024 * 1024

    private let transport: ByteTransport
    private var buffer: [UInt8] = []
    private var start = 0
    private(set) var isClosed = false
    let security: ConnectionSecurity
    /// True once bytes are encrypted (always for implicit TLS; after startTLS() otherwise).
    private(set) var isEncrypted: Bool

    init(host: String, port: UInt16, security: ConnectionSecurity = .tls) {
        self.security = security
        isEncrypted = security == .tls
        transport = security == .tls ? NWTransport(host: host, port: port) : StartTLSTransport(host: host, port: port)
    }

    /// A stream over a caller-supplied transport (the self-test's scripted server).
    init(transport: ByteTransport) {
        security = .tls
        isEncrypted = true
        self.transport = transport
    }

    func open() async throws {
        transport.setClosedHandler { [weak self] in Task { await self?.markClosed() } }
        let t = transport
        // Connection timeout for the STARTTLS transport (NWConnection has its own).
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 20_000_000_000)
            t.close()
        }
        defer { watchdog.cancel() }
        do { try await transport.open() } catch {
            // A connection that failed to open is still alive underneath (an NWConnection keeps waiting
            // for the network, the STARTTLS thread keeps running): release it, or every attempt made
            // while offline leaks one.
            transport.close()
            throw error
        }
    }

    /// Upgrades a STARTTLS connection once the server agreed. Any bytes the server sent before the
    /// handshake are discarded (they could be injected plaintext — the "STARTTLS command injection" class).
    func startTLS() async throws {
        guard security == .startTLS, !isEncrypted else { return }
        buffer.removeAll()
        start = 0
        transport.discardBuffered()
        try await transport.startTLS()
        isEncrypted = true
    }

    private func markClosed() { isClosed = true }

    func close() {
        isClosed = true
        transport.close()
    }

    func send(_ data: Data) async throws {
        if isClosed { throw NetError.closed }
        try await transport.send(data)
    }

    func send(_ string: String) async throws { try await send(Data(string.utf8)) }

    private func fill() async throws {
        if isClosed { throw NetError.closed }
        let chunk = try await transport.receive()
        // Compact consumed bytes so the buffer never grows past what is still unread.
        if start > 0 && (start == buffer.count || start > 512 * 1024) {
            buffer.removeFirst(start)
            start = 0
        }
        buffer.append(contentsOf: chunk)
    }

    /// Reads one line without its CRLF. Lines past maxLineLength abort the connection.
    func readLine() async throws -> [UInt8] {
        var scanned = 0
        while true {
            var i = start + scanned
            while i < buffer.count {
                if buffer[i] == 10 {
                    let end = (i > start && buffer[i - 1] == 13) ? i - 1 : i
                    let line = Array(buffer[start..<end])
                    start = i + 1
                    return line
                }
                i += 1
            }
            scanned = buffer.count - start
            guard scanned <= Self.maxLineLength else { throw NetError.protocolError("line too long") }
            try await fill()
        }
    }

    func readBytes(_ n: Int) async throws -> Data {
        guard n >= 0, n <= Self.maxReadSize else { throw NetError.protocolError("read too large") }
        while buffer.count - start < n { try await fill() }
        let d = Data(buffer[start..<start + n])
        start += n
        return d
    }

    /// Bytes received but not yet consumed (STARTTLS must see none before upgrading).
    var hasBufferedBytes: Bool { buffer.count > start }
}
