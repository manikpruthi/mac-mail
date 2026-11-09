import Foundation

/// Messages that couldn't be sent because the server was unreachable (F-07). Each one is stored as its
/// finished MIME (attachments included, so the original files may move or vanish) plus a small JSON
/// record, under Application Support/…/Outbox, and survives relaunch. MailService flushes it when the
/// network comes back, on activation and after launch.
@MainActor
final class Outbox {
    struct Item: Codable, Equatable {
        var id: String
        var accountID: String
        var recipients: [String]
        var subject: String
        var created: Date
        var replyToID: Int64?
        var draftToDeleteID: Int64?
        var safetyDraftID: Int64?
        var attempts: Int = 0
        var lastError: String?
    }

    private let dir: URL
    private(set) var items: [Item] = []

    init(directory: URL = AppPaths.outbox) {
        dir = directory
        load()
    }

    private func folder(_ id: String) -> URL { dir.appendingPathComponent(id, isDirectory: true) }

    private func load() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var found: [Item] = []
        var corrupt: [URL] = []
        for f in folders {
            guard (try? f.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let item = (try? Data(contentsOf: f.appendingPathComponent("item.json")))
                .flatMap { try? JSONDecoder().decode(Item.self, from: $0) }
            // A record that won't decode, has a non-UUID id (which would escape the Outbox folder),
            // doesn't live in its own folder, or has no regular MIME file, can never be sent (C-26).
            let eml = f.appendingPathComponent("message.eml")
            guard let item, UUID(uuidString: item.id) != nil, f.lastPathComponent == item.id,
                  (try? eml.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                corrupt.append(f)
                continue
            }
            found.append(item)
        }
        items = found.sorted { $0.created < $1.created }
        if !corrupt.isEmpty { quarantine(corrupt) }
    }

    /// Moves unreadable Outbox folders into a sibling folder instead of dropping them, off the main
    /// thread; they stay inspectable for the Export Diagnostics Log.
    private func quarantine(_ folders: [URL]) {
        let dest = URL(fileURLWithPath: dir.path + " Corrupt")
        let stamp = UUID().uuidString
        DiagnosticsLog.record("Outbox: \(folders.count) unreadable record\(folders.count == 1 ? "" : "s") moved to \(dest.lastPathComponent)")
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (i, f) in folders.enumerated() {
                try? fm.moveItem(at: f, to: dest.appendingPathComponent("\(stamp)-\(i)-\(f.lastPathComponent)", isDirectory: true))
            }
        }
    }

    private func write(_ item: Item) throws {
        let data = try JSONEncoder().encode(item)
        let url = folder(item.id).appendingPathComponent("item.json")
        try data.write(to: url, options: .atomic)
        // A queued message is only real once its record is verifiably on disk (C-02).
        guard (try? Data(contentsOf: url)) == data else {
            throw CocoaError(.fileWriteUnknown,
                             userInfo: [NSLocalizedDescriptionKey: "The Outbox record couldn't be verified on disk."])
        }
    }

    /// Stores a message for later. The MIME is built now, so what's sent later is exactly what was written.
    /// A prebuilt `mime` (already built off the main thread) is reused instead of rebuilt.
    func add(_ message: OutgoingMessage, accountID: String, replyToID: Int64?, draftToDeleteID: Int64?,
             safetyDraftID: Int64?, mime: Data? = nil) throws {
        let item = Item(id: UUID().uuidString, accountID: accountID, recipients: message.allRecipients,
                        subject: message.subject, created: Date(), replyToID: replyToID,
                        draftToDeleteID: draftToDeleteID, safetyDraftID: safetyDraftID)
        let f = folder(item.id)
        do {
            try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try (mime ?? MessageBuilder.build(message)).write(to: f.appendingPathComponent("message.eml"), options: .atomic)
            try write(item)
        } catch {
            // Nothing counts as queued unless the record is fully on disk; leave no half-written folder (C-02).
            try? FileManager.default.removeItem(at: f)
            throw error
        }
        items.append(item)
        NotificationCenter.default.post(name: .mailOutboxChanged, object: nil)
    }

    func data(_ item: Item) throws -> Data {
        try Data(contentsOf: folder(item.id).appendingPathComponent("message.eml"))
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: folder(id))
        items.removeAll { $0.id == id }
        NotificationCenter.default.post(name: .mailOutboxChanged, object: nil)
    }

    /// Clears a refusal so the next flush tries the message again (C-26).
    func resetFailure(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].attempts = 0
        items[i].lastError = nil
        do { try write(items[i]) } catch {
            DiagnosticsLog.record("Outbox: couldn't reset the failure record for a queued message: \(error.localizedDescription)")
        }
        NotificationCenter.default.post(name: .mailOutboxChanged, object: nil)
    }

    func remove(account: String) {
        for i in items where i.accountID == account { remove(i.id) }
    }

    /// Counts an attempt; a non-nil error is a refusal worth showing (network failures pass nil).
    func recordFailure(_ id: String, error: Error?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].attempts += 1
        if let error { items[i].lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        do {
            try write(items[i])
        } catch {
            // The in-memory count still stands; the next successful write persists it (C-26).
            DiagnosticsLog.record("Outbox: couldn't update the failure record for a queued message: \(error.localizedDescription)")
        }
        NotificationCenter.default.post(name: .mailOutboxChanged, object: nil)
    }
}
