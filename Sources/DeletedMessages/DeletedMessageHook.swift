import Foundation
import UIKit
import ObjectiveC

// MARK: - Ключ настройки (синхронизирован с TGExtraSettings)
public let kTGExtraShowDeletedMessages = "TGExtra_ShowDeletedMessages"

// MARK: - Хук удаления сообщений

/// Этот класс устанавливает swizzle на методы Telegram,
/// отвечающие за удаление сообщений из UI и базы данных.
///
/// Telegram iOS использует Swift-классы, многие из которых
/// наследуют NSObject и доступны через ObjC runtime.
/// Ключевые точки перехвата:
///   • ChatMessageItemView  – ячейка сообщения (рендеринг)
///   • ChatControllerImpl   – контроллер чата (экшены)

public final class DeletedMessageHook: NSObject {

    public static let shared = DeletedMessageHook()
    private override init() {}

    // Флаг — уже установлены хуки или нет
    private var isInstalled = false

    // Кэш: messageId → запись (для текущей сессии, быстрый доступ)
    public var sessionCache: [String: DeletedMessageEntry] = [:]

    // MARK: - Установка хуков

    public func install() {
        guard !isInstalled else { return }
        isInstalled = true

        swizzleDeletion()
        swizzleMessageCellLayout()

        print("[TGExtra] DeletedMessageHook installed ✓")
    }

    // MARK: - Swizzle 1: перехват подтверждения удаления (UIAlertController)
    //
    // Telegram показывает UIAlertController с кнопкой "Delete for everyone" /
    // "Delete for me". Мы перехватываем момент ДО того, как алерт появится,
    // чтобы сохранить содержимое сообщения.
    //
    // Точка входа: -[UIAlertController viewWillAppear:]

    private func swizzleDeletion() {
        guard let original = class_getInstanceMethod(UIAlertController.self,
                                                     #selector(UIAlertController.viewWillAppear(_:))),
              let swizzled = class_getInstanceMethod(UIAlertController.self,
                                                     #selector(UIAlertController.tgextra_viewWillAppear(_:)))
        else { return }

        method_exchangeImplementations(original, swizzled)
    }

    // MARK: - Swizzle 2: рендеринг ячейки сообщения
    //
    // Мы перехватываем layoutSubviews ячейки, чтобы добавить
    // визуальный оверлей "удалено" поверх сообщения.

    private func swizzleMessageCellLayout() {
        // Имя класса ячейки в Telegram iOS (открытый исходник)
        let className = "ChatMessageItemView"
        guard let cls = NSClassFromString(className),
              let original = class_getInstanceMethod(cls, #selector(UIView.layoutSubviews)),
              let swizzled = class_getInstanceMethod(UIView.self,
                                                     #selector(UIView.tgextra_chatCell_layoutSubviews))
        else {
            print("[TGExtra] Warning: ChatMessageItemView not found — cell overlay disabled")
            return
        }
        method_exchangeImplementations(original, swizzled)
    }
}

// MARK: - UIAlertController Extension (перехват кнопок удаления)

extension UIAlertController {

    /// Вызывается перед показом каждого алерта.
    /// Если это алерт удаления Telegram — сохраняем сообщение.
    @objc func tgextra_viewWillAppear(_ animated: Bool) {
        tgextra_viewWillAppear(animated) // вызов оригинала

        guard UserDefaults.standard.bool(forKey: kTGExtraShowDeletedMessages) else { return }

        // Проверяем, что это алерт удаления (по заголовку/кнопкам)
        let deleteKeywords = ["Delete", "Удалить", "Удалить для всех", "Delete for Everyone",
                              "Delete for Me", "Удалить только у себя"]
        let hasDeleteAction = actions.contains { action in
            deleteKeywords.contains(where: { action.title?.contains($0) == true })
        }
        guard hasDeleteAction else { return }

        // Swizzle кнопки "Delete" — добавляем захват контекста
        for action in actions where deleteKeywords.contains(where: { action.title?.contains($0) == true }) {
            // Оборачиваем handler через associated object
            let originalHandler = action.tgextra_extractHandler()
            let newHandler: (UIAlertAction) -> Void = { [weak self] alertAction in
                // Сохранить контекст текущего выбранного сообщения
                self?.tgextra_captureSelectedMessages()
                originalHandler?(alertAction)
            }
            action.tgextra_replaceHandler(newHandler)
        }
    }

    /// Пытаемся найти выбранные сообщения через responder chain
    private func tgextra_captureSelectedMessages() {
        // Ищем ChatController в responder chain / window hierarchy
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else { return }
        if let chatVC = window.tgextra_findViewController(ofClassName: "ChatControllerImpl") {
            chatVC.tgextra_captureSelectedMessages()
        }
    }
}

// MARK: - UIAlertAction Handler Swizzle Helper

private var kTGExtraHandlerKey = "tgextra_handler"

extension UIAlertAction {
    func tgextra_extractHandler() -> ((UIAlertAction) -> Void)? {
        // Получаем приватный ivar handler через KVC (работает в Telegram runtime)
        return value(forKey: "handler") as? (UIAlertAction) -> Void
    }

    func tgextra_replaceHandler(_ handler: @escaping (UIAlertAction) -> Void) {
        setValue(handler, forKey: "handler")
    }
}

// MARK: - UIViewController Extension (захват сообщений)

extension UIViewController {

    /// Извлекаем выбранные сообщения из ChatControllerImpl
    @objc func tgextra_captureSelectedMessages() {
        // Через KVC получаем selectedMessages из ChatControllerImpl
        // Структура: selectedMessages: [MessageId: Message]
        guard let selectedMessages = value(forKey: "selectedMessages") as? [AnyHashable: AnyObject]
        else {
            // Fallback: получаем "presentedMessage" (одиночное нажатие)
            tgextra_capturePresentedMessage()
            return
        }

        for (_, message) in selectedMessages {
            tgextra_saveMessage(message)
        }
    }

    private func tgextra_capturePresentedMessage() {
        if let message = value(forKey: "presentedMessage") as? AnyObject {
            tgextra_saveMessage(message)
        }
    }

    private func tgextra_saveMessage(_ message: AnyObject) {
        // Извлекаем поля через KVC (Message — класс в Telegram, наследник NSObject)
        let messageId = (message.value(forKey: "id") as? AnyObject)?.value(forKey: "id") as? Int32 ?? 0
        let peerId    = (message.value(forKey: "id") as? AnyObject)?.value(forKey: "peerId") as? Int64 ?? 0
        let text      = message.value(forKey: "text") as? String
        let timestamp = message.value(forKey: "timestamp") as? Int32 ?? 0

        // Имя автора
        var authorName: String? = nil
        if let author = message.value(forKey: "author") as? AnyObject {
            if let fn = author.value(forKey: "firstName") as? String,
               let ln = author.value(forKey: "lastName") as? String {
                authorName = "\(fn) \(ln)".trimmingCharacters(in: .whitespaces)
            }
        }

        guard messageId != 0 else { return }

        let entry = DeletedMessageEntry(
            messageId: messageId,
            peerId: peerId,
            text: text,
            authorName: authorName,
            timestamp: timestamp
        )
        DeletedMessageStore.shared.save(entry)
        print("[TGExtra] Saved deleted message: id=\(messageId) text='\(text ?? "")'")
    }
}

// MARK: - UIView Extension (оверлей ячейки)

extension UIView {

    /// Вызывается вместо layoutSubviews для ChatMessageItemView
    @objc func tgextra_chatCell_layoutSubviews() {
        tgextra_chatCell_layoutSubviews() // оригинал

        guard UserDefaults.standard.bool(forKey: kTGExtraShowDeletedMessages) else {
            tgextra_removeDeletedOverlay()
            return
        }

        // Получаем messageId из ячейки
        guard let messageId = value(forKey: "messageId") as? Int32,
              let peerId = value(forKey: "peerId") as? Int64
        else { return }

        let isDeleted = DeletedMessageStore.shared.entries(forPeerId: peerId)
            .contains { $0.messageId == messageId }

        if isDeleted {
            tgextra_applyDeletedOverlay()
        } else {
            tgextra_removeDeletedOverlay()
        }
    }

    // MARK: Визуальный оверлей

    private static let overlayTag = 0x74676578 // "tgex" в hex

    func tgextra_applyDeletedOverlay() {
        // Не добавляем дважды
        guard viewWithTag(UIView.overlayTag) == nil else { return }

        // Полупрозрачный оверлей
        alpha = 0.45

        let overlay = UIView(frame: bounds)
        overlay.tag = UIView.overlayTag
        overlay.backgroundColor = UIColor.clear
        overlay.isUserInteractionEnabled = false
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Иконка мусорки
        let trashLabel = UILabel()
        trashLabel.text = "🗑️"
        trashLabel.font = UIFont.systemFont(ofSize: 20)
        trashLabel.sizeToFit()
        trashLabel.center = CGPoint(x: bounds.width - 24, y: 12)
        trashLabel.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
        overlay.addSubview(trashLabel)

        // Подпись "Удалено"
        let deletedLabel = UILabel()
        deletedLabel.text = "Удалено"
        deletedLabel.font = UIFont.italicSystemFont(ofSize: 11)
        deletedLabel.textColor = UIColor.secondaryLabel
        deletedLabel.sizeToFit()
        deletedLabel.frame.origin = CGPoint(x: trashLabel.frame.origin.x - deletedLabel.frame.width - 4,
                                             y: trashLabel.frame.origin.y + (trashLabel.frame.height - deletedLabel.frame.height) / 2)
        deletedLabel.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
        overlay.addSubview(deletedLabel)

        addSubview(overlay)
    }

    func tgextra_removeDeletedOverlay() {
        if let overlay = viewWithTag(UIView.overlayTag) {
            overlay.removeFromSuperview()
        }
        alpha = 1.0
    }
}

// MARK: - UIWindow Helper

extension UIWindow {
    func tgextra_findViewController(ofClassName name: String) -> UIViewController? {
        return rootViewController?.tgextra_find(className: name)
    }
}

extension UIViewController {
    func tgextra_find(className: String) -> UIViewController? {
        if NSStringFromClass(type(of: self)).contains(className) { return self }
        for child in children {
            if let found = child.tgextra_find(className: className) { return found }
        }
        if let presented = presentedViewController {
            return presented.tgextra_find(className: className)
        }
        return nil
    }
}
