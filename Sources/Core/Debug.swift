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

/// A small on-disk log of connection and sync errors for Settings ▸ Storage ▸ Export Diagnostics Log (F-26).
/// Only error text is written — never message content or passwords. Capped at 512 KB (oldest half dropped).
enum DiagnosticsLog {
    private static let queue = DispatchQueue(label: "macmail.diagnostics", qos: .utility)
    static var file: URL { AppPaths.caches.appendingPathComponent("diagnostics.log") }

    static func record(_ message: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + "  " + message.replacingOccurrences(of: "\n", with: " ") + "\n"
        queue.async {
            let url = file
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > 512 * 1024,
               let data = try? Data(contentsOf: url) {
                try? data.suffix(size / 2).write(to: url, options: .atomic)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url, options: .atomic)
            }
        }
    }

    static func export(to dest: URL) throws {
        try queue.sync {
            let header = "Mac Mail \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?")) — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
            var data = Data(header.utf8)
            data.append((try? Data(contentsOf: file)) ?? Data("No errors recorded.\n".utf8))
            try data.write(to: dest, options: .atomic)
        }
    }
}
