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

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        tcp.connectionTimeout = 15
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 993, using: params)
    }

    private var closedHandler: (@Sendable () -> Void)?
    func setClosedHandler(_ handler: @escaping @Sendable () -> Void) { closedHandler = handler }

    func open() async throws {
        let once = OnceFlag()
        let conn = connection
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { c.resume() }
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
            case .failed, .cancelled: handler?()
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
    private var closedHandler: (@Sendable () -> Void)?

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func setClosedHandler(_ handler: @escaping @Sendable () -> Void) { closedHandler = handler }

    /// Runs `block` on the streams' run-loop thread.
    private func onThread(_ block: @escaping () -> Void) {
        guard let rl = runLoop else { block(); return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue, block)
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
            }
            t.name = "MacMail STARTTLS \(host)"
            t.qualityOfService = .userInitiated
            thread = t
            t.start()
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            onThread { [self] in
                var i: InputStream?
                var o: OutputStream?
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
            closedHandler?()
        default:
            break
        }
    }

    private func shutDown(_ error: Error) {
        guard !finished else { return }
        failure = failure ?? error
        finished = true
        for s in [input, output].compactMap({ $0 }) as [Stream] {
            s.delegate = nil
            s.close()
            s.remove(from: .current, forMode: .default)
        }
        if let c = openCont { openCont = nil; c.resume(throwing: error) }
        if let c = pendingRead { pendingRead = nil; c.resume(throwing: error) }
        if let w = pendingWrite { pendingWrite = nil; w.cont.resume(throwing: error) }
        closedHandler?()
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

    func open() async throws {
        transport.setClosedHandler { [weak self] in Task { await self?.markClosed() } }
        let t = transport
        // Connection timeout for the STARTTLS transport (NWConnection has its own).
        let watchdog = Task {
            try await Task.sleep(nanoseconds: 20_000_000_000)
            t.close()
        }
        defer { watchdog.cancel() }
        try await transport.open()
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
