import Foundation

/// Zips a folder with the system's ditto (no third-party code). Shared by "Save all attachments" in the
/// reading pane and "attach a folder" in the composer.
enum AttachmentZip {
    /// Zips `directory` into `dest`. With `keepParent` the archive contains the folder itself;
    /// without it, only the folder's contents (what "Save all attachments" wants).
    static func zip(directory: URL, to dest: URL, keepParent: Bool = false) async throws {
        try? FileManager.default.removeItem(at: dest)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = keepParent
                ? ["-c", "-k", "--sequesterRsrc", "--keepParent", directory.path, dest.path]
                : ["-c", "-k", "--sequesterRsrc", directory.path, dest.path]
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 { c.resume() }
                else { c.resume(throwing: NetError.server("Couldn't create the zip file (ditto exited \(proc.terminationStatus)).")) }
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }
}
