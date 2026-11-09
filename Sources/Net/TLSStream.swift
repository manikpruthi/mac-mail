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

/// A buffered TLS byte stream on Network.framework with line and byte-count reads.
actor TLSStream {
    /// A single response line longer than this is a protocol error, not data.
    static let maxLineLength = 1024 * 1024
    /// A single literal read larger than this is refused (matches IMAPParser.maxLiteralSize).
    static let maxReadSize = 64 * 1024 * 1024

    private let connection: NWConnection
    private var buffer: [UInt8] = []
    private var start = 0
    private(set) var isClosed = false

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 60
        tcp.connectionTimeout = 15
        let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 993, using: params)
    }

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
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { await self?.markClosed() }
            default: break
            }
        }
    }

    private func markClosed() { isClosed = true }

    func close() {
        isClosed = true
        connection.cancel()
    }

    func send(_ data: Data) async throws {
        if isClosed { throw NetError.closed }
        let conn = connection
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    func send(_ string: String) async throws { try await send(Data(string.utf8)) }

    private func fill() async throws {
        if isClosed { throw NetError.closed }
        let conn = connection
        let chunk: Data = try await withCheckedThrowingContinuation { c in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let error { c.resume(throwing: error) }
                else if let data, !data.isEmpty { c.resume(returning: data) }
                else if isComplete { c.resume(throwing: NetError.closed) }
                else { c.resume(returning: Data()) }
            }
        }
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
}
