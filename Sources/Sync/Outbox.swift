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
        /// Set once SMTP accepted the message. From then on it must never be sent again: all that is
        /// left is deleting the queued copy. Optional so records written by older versions still decode.
        var delivered: Bool?

        var wasDelivered: Bool { delivered == true }
    }

    /// What the decision marker holds for a message that was delivered but whose record couldn't be rewritten.
    private static let deliveredMarker = "delivered"
    private static let deliveredNote = "This message was sent. Its queued copy couldn't be deleted yet; choose Delete to remove it."

    /// Automatic attempts before a failed item is left for the user (C-26).
    static let maxAttempts = 5

    private let dir: URL
    private(set) var items: [Item] = []

    init(directory: URL = AppPaths.outbox) {
        dir = directory
        load()
    }

    private func folder(_ id: String) -> URL { dir.appendingPathComponent(id, isDirectory: true) }

    private static func decode(_ url: URL) -> Item? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Item.self, from: $0) }
    }

    /// Where a decision is recorded when the item's own folder can't be written (it is outside that
    /// folder on purpose: the folder that refused a delete usually refuses writes too).
    private func marker(_ id: String) -> URL { dir.appendingPathComponent(id + ".decision") }

    private func load() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var found: [Item] = []
        var corrupt: [URL] = []
        for var f in folders {
            guard (try? f.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            // A crash before add() renamed its staging folder into place: finish the rename. A complete
            // one loads below; an incomplete one is quarantined with the other unreadable folders.
            if f.pathExtension == "tmp" {
                let final = f.deletingPathExtension()
                if (try? fm.moveItem(at: f, to: final)) != nil { f = final }
            }
            // A record that won't decode, has a non-UUID id (which would escape the Outbox folder),
            // doesn't live in its own folder, or has no regular MIME file, can never be sent (C-26).
            let eml = f.appendingPathComponent("message.eml")
            guard var item = Self.decode(f.appendingPathComponent("item.json")), UUID(uuidString: item.id) != nil,
                  f.lastPathComponent == item.id,
                  (try? eml.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                corrupt.append(f)
                continue
            }
            if let reason = try? String(contentsOf: marker(item.id), encoding: .utf8) {
                item.attempts = max(item.attempts, Self.maxAttempts)
                if reason == Self.deliveredMarker { item.delivered = true } else { item.lastError = reason }
            }
            if item.wasDelivered {
                // Sent before the last quit or crash, but its folder was still there: finish the delete.
                // If that fails again it stays listed as sent, never as something to retry.
                if (try? fm.removeItem(at: f)) != nil {
                    try? fm.removeItem(at: marker(item.id))
                    continue
                }
                item.attempts = max(item.attempts, Self.maxAttempts)
                item.lastError = Self.deliveredNote
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
        let staging = f.appendingPathExtension("tmp")
        let fm = FileManager.default
        do {
            // Both files are written into a staging folder that is renamed into place in one step, so a
            // crash leaves either a whole queued message or nothing that looks like one.
            try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(item)
            try (mime ?? MessageBuilder.build(message)).write(to: staging.appendingPathComponent("message.eml"), options: .atomic)
            try data.write(to: staging.appendingPathComponent("item.json"), options: .atomic)
            try fm.moveItem(at: staging, to: f)
            // A queued message is only real once its record is verifiably on disk (C-02).
            guard (try? Data(contentsOf: f.appendingPathComponent("item.json"))) == data else {
                throw CocoaError(.fileWriteUnknown,
                                 userInfo: [NSLocalizedDescriptionKey: "The Outbox record couldn't be verified on disk."])
            }
        } catch {
            // Nothing counts as queued unless the record is fully on disk; leave no half-written folder (C-02).
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: f)
            throw error
        }
        items.append(item)
        NotificationCenter.default.post(name: .mailOutboxChanged, object: nil)
    }

    /// The queued MIME file, so callers can read it off the main thread.
    func messageURL(_ item: Item) -> URL { folder(item.id).appendingPathComponent("message.eml") }

    func data(_ item: Item) throws -> Data {
        try Data(contentsOf: messageURL(item))
    }

    /// Records that SMTP accepted the message, before anything else happens to it: a crash or a failed
    /// delete after this point must not lead to a second delivery.
    func markDelivered(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].delivered = true
        do { try write(items[i]) } catch {
            do { try Data(Self.deliveredMarker.utf8).write(to: marker(id), options: .atomic) } catch {
                DiagnosticsLog.record("Outbox: couldn't record that a queued message was sent: \(error.localizedDescription)")
            }
        }
    }

    func remove(_ id: String) {
        do {
            try FileManager.default.removeItem(at: folder(id))
        } catch {
            // A folder that couldn't be deleted is loaded again next launch and would be sent, so keep
            // the item and say why (F-05). An already-missing folder counts as deleted.
            if (error as NSError).code != NSFileNoSuchFileError {
                let sent = items.first { $0.id == id }?.wasDelivered == true
                markNeedsDecision(id, reason: sent ? Self.deliveredNote
                                  : "Couldn't delete the queued message: \(error.localizedDescription).")
                return
            }
        }
        try? FileManager.default.removeItem(at: marker(id))
        items.removeAll { $0.id == id }
        NotificationCenter.default.post(name: .mailOutboxChanged, object: nil)
    }

    /// Keeps a message automatic retries can't fix (F-01, F-23): it stays with the reason, and the next
    /// flush skips it until the user picks Retry or Delete in the sidebar.
    func markNeedsDecision(_ id: String, reason: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].attempts = max(items[i].attempts, Self.maxAttempts)
        items[i].lastError = reason
        do { try write(items[i]) } catch {
            // The decision must survive a relaunch or the message could be sent twice: record it beside
            // the folder instead.
            do { try Data(reason.utf8).write(to: marker(id), options: .atomic) } catch {
                DiagnosticsLog.record("Outbox: couldn't update the failure record for a queued message: \(error.localizedDescription)")
            }
        }
        NotificationCenter.default.post(name: .mailOutboxChanged, object: nil)
    }

    /// Clears a refusal so the next flush tries the message again (C-26).
    func resetFailure(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        // A delivered message has nothing left to retry: trying again only means deleting its copy.
        if items[i].wasDelivered { remove(id); return }
        items[i].attempts = 0
        items[i].lastError = nil
        try? FileManager.default.removeItem(at: marker(id))
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
