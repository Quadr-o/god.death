import Foundation

// MARK: - Модель удалённого сообщения

public struct DeletedMessageEntry: Codable {
    public let messageId: Int32
    public let peerId: Int64
    public let text: String?
    public let authorName: String?
    public let timestamp: Int32
    public let deletedAt: TimeInterval

    public init(messageId: Int32, peerId: Int64, text: String?, authorName: String?, timestamp: Int32) {
        self.messageId   = messageId
        self.peerId      = peerId
        self.text        = text
        self.authorName  = authorName
        self.timestamp   = timestamp
        self.deletedAt   = Date().timeIntervalSince1970
    }
}

// MARK: - Хранилище (UserDefaults)

public final class DeletedMessageStore {

    public static let shared = DeletedMessageStore()
    private init() {}

    private let defaults = UserDefaults(suiteName: "com.tgextra.deletedMessages") ?? .standard
    private let storageKey = "tgextra_deleted_entries"

    // Загрузить все сохранённые записи
    public func allEntries() -> [DeletedMessageEntry] {
        guard let data = defaults.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([DeletedMessageEntry].self, from: data)
        else { return [] }
        return entries
    }

    // Записи для конкретного чата
    public func entries(forPeerId peerId: Int64) -> [DeletedMessageEntry] {
        return allEntries().filter { $0.peerId == peerId }
    }

    // Сохранить новую запись
    public func save(_ entry: DeletedMessageEntry) {
        var current = allEntries()
        // Не дублируем
        guard !current.contains(where: { $0.messageId == entry.messageId && $0.peerId == entry.peerId }) else { return }
        current.append(entry)
        // Ограничение: не более 500 записей (чтобы не раздувать хранилище)
        if current.count > 500 {
            current = Array(current.suffix(500))
        }
        if let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: storageKey)
        }
    }

    // Удалить конкретную запись
    public func remove(messageId: Int32, peerId: Int64) {
        var current = allEntries()
        current.removeAll { $0.messageId == messageId && $0.peerId == peerId }
        if let data = try? JSONEncoder().encode(current) {
            defaults.set(data, forKey: storageKey)
        }
    }

    // Очистить всё
    public func clearAll() {
        defaults.removeObject(forKey: storageKey)
    }
}
