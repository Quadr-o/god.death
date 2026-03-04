import Foundation

// MARK: - Ключ UserDefaults (единственное место объявления)
// Используется во всех файлах через этот модуль
let kTGExtraShowDeletedMessages = "TGExtraShowDeletedMessages"

// MARK: - Модель удалённого сообщения

public struct DeletedMessageEntry: Codable {
    public let messageId: Int32
    public let peerId: Int64
    public let text: String?
    public let authorName: String?
    public let timestamp: Int32
    public let deletedAt: TimeInterval

    public init(messageId: Int32, peerId: Int64, text: String?, authorName: String?, timestamp: Int32) {
        self.messageId  = messageId
        self.peerId     = peerId
        self.text       = text
        self.authorName = authorName
        self.timestamp  = timestamp
        self.deletedAt  = Date().timeIntervalSince1970
    }
}

// MARK: - Хранилище

public final class DeletedMessageStore {
    public static let shared = DeletedMessageStore()
    private init() {}

    private let defaults   = UserDefaults(suiteName: "com.tgextra.deletedMessages") ?? .standard
    private let storageKey = "tgextra_deleted_entries"

    public func allEntries() -> [DeletedMessageEntry] {
        guard let data = defaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([DeletedMessageEntry].self, from: data)
        else { return [] }
        return entries
    }

    public func entries(forPeerId peerId: Int64) -> [DeletedMessageEntry] {
        return allEntries().filter { $0.peerId == peerId }
    }

    public func save(_ entry: DeletedMessageEntry) {
        var current = allEntries()
        guard !current.contains(where: {
            $0.messageId == entry.messageId && $0.peerId == entry.peerId
        }) else { return }
        current.append(entry)
        if current.count > 500 { current = Array(current.suffix(500)) }
        if let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: storageKey)
        }
    }

    public func remove(messageId: Int32, peerId: Int64) {
        var current = allEntries()
        current.removeAll { $0.messageId == messageId && $0.peerId == peerId }
        if let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: storageKey)
        }
    }

    public func clearAll() {
        defaults.removeObject(forKey: storageKey)
    }
}
