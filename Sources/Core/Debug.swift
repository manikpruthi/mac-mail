import Foundation

enum Debug {
    static let launch = Date()
    /// Benchmark mode never marks anything read.
    static let bench = ProcessInfo.processInfo.environment["MAC_MAIL_BENCH"] == "1"
    static func ms(since d: Date) -> String { String(format: "%.1f ms", Date().timeIntervalSince(d) * 1000) }
    static let enabled = ProcessInfo.processInfo.environment["MAC_MAIL_DEBUG"] == "1"
    static func log(_ s: @autoclosure () -> String) {
        guard enabled else { return }
        let t = String(format: "%7.0f", Date().timeIntervalSince(launch) * 1000)
        FileHandle.standardError.write(Data(("[macmail] +\(t)ms " + s() + "\n").utf8))
    }
}
