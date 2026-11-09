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
        let folders = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        items = folders.compactMap { f in
            guard let data = try? Data(contentsOf: f.appendingPathComponent("item.json")) else { return nil }
            return try? JSONDecoder().decode(Item.self, from: data)
        }.sorted { $0.created < $1.created }
    }

    private func write(_ item: Item) {
        guard let data = try? JSONEncoder().encode(item) else { return }
        try? data.write(to: folder(item.id).appendingPathComponent("item.json"), options: .atomic)
    }

    /// Stores a message for later. The MIME is built now, so what's sent later is exactly what was written.
    func add(_ message: OutgoingMessage, accountID: String, replyToID: Int64?, draftToDeleteID: Int64?,
             safetyDraftID: Int64?) throws {
        let item = Item(id: UUID().uuidString, accountID: accountID, recipients: message.allRecipients,
                        subject: message.subject, created: Date(), replyToID: replyToID,
                        draftToDeleteID: draftToDeleteID, safetyDraftID: safetyDraftID)
        let f = folder(item.id)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try MessageBuilder.build(message).write(to: f.appendingPathComponent("message.eml"), options: .atomic)
        write(item)
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

    func remove(account: String) {
        for i in items where i.accountID == account { remove(i.id) }
    }

    /// Counts an attempt; a non-nil error is a refusal worth showing (network failures pass nil).
    func recordFailure(_ id: String, error: Error?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].attempts += 1
        if let error { items[i].lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        write(items[i])
        NotificationCenter.default.post(name: .mailOutboxChanged, object: nil)
    }
}
