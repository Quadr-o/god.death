import Foundation
import UIKit
import ObjectiveC

// MARK: - Хук удаления сообщений
// kTGExtraShowDeletedMessages объявлен в DeletedMessageStore.swift

public final class DeletedMessageHook: NSObject {
    public static let shared = DeletedMessageHook()
    private override init() {}

    private var isInstalled = false

    public func install() {
        guard !isInstalled else { return }
        isInstalled = true
        swizzleAlertController()
        swizzleMessageCellLayout()
        print("[TGExtra] DeletedMessageHook installed ✓")
    }

    // MARK: - Swizzle UIAlertController

    private func swizzleAlertController() {
        guard
            let original = class_getInstanceMethod(UIAlertController.self,
                                                   #selector(UIAlertController.viewWillAppear(_:))),
            let swizzled = class_getInstanceMethod(UIAlertController.self,
                                                   #selector(UIAlertController.tgextra_alertViewWillAppear(_:)))
        else { return }
        method_exchangeImplementations(original, swizzled)
    }

    // MARK: - Swizzle ChatMessageItemView

    private func swizzleMessageCellLayout() {
        let className = "ChatMessageItemView"
        guard
            let cls      = NSClassFromString(className),
            let original = class_getInstanceMethod(cls, #selector(UIView.layoutSubviews)),
            let swizzled = class_getInstanceMethod(UIView.self,
                                                   #selector(UIView.tgextra_chatCell_layoutSubviews))
        else {
            print("[TGExtra] Warning: \(className) not found — overlay disabled")
            return
        }
        method_exchangeImplementations(original, swizzled)
    }
}

// MARK: - UIAlertController Extension

extension UIAlertController {

    @objc func tgextra_alertViewWillAppear(_ animated: Bool) {
        tgextra_alertViewWillAppear(animated)

        guard UserDefaults.standard.bool(forKey: kTGExtraShowDeletedMessages) else { return }

        let deleteKeywords = ["Delete", "Удалить", "Delete for Everyone",
                              "Delete for Me", "Удалить для всех", "Удалить только у себя"]
        let hasDelete = actions.contains { action in
            deleteKeywords.contains(where: { action.title?.contains($0) == true })
        }
        guard hasDelete else { return }

        for action in actions where deleteKeywords.contains(where: { action.title?.contains($0) == true }) {
            let orig = action.value(forKey: "handler") as? (UIAlertAction) -> Void
            let newHandler: (UIAlertAction) -> Void = { [weak self] a in
                self?.tgextra_captureFromWindow()
                orig?(a)
            }
            action.setValue(newHandler, forKey: "handler")
        }
    }

    func tgextra_captureFromWindow() {
        guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }),
              let chatVC = window.tgextra_findVC(className: "ChatControllerImpl")
        else { return }
        chatVC.tgextra_saveSelectedMessages()
    }
}

// MARK: - UIViewController Extension

extension UIViewController {

    @objc func tgextra_saveSelectedMessages() {
        guard let msgs = value(forKey: "selectedMessages") as? [AnyHashable: AnyObject] else {
            tgextra_savePresentedMessage()
            return
        }
        msgs.values.forEach { tgextra_persistMessage($0) }
    }

    func tgextra_savePresentedMessage() {
        if let msg = value(forKey: "presentedMessage") as? AnyObject {
            tgextra_persistMessage(msg)
        }
    }

    func tgextra_persistMessage(_ message: AnyObject) {
        let messageId = (message.value(forKey: "id") as? AnyObject)?.value(forKey: "id") as? Int32 ?? 0
        let peerId    = (message.value(forKey: "id") as? AnyObject)?.value(forKey: "peerId") as? Int64 ?? 0
        let text      = message.value(forKey: "text") as? String
        let timestamp = message.value(forKey: "timestamp") as? Int32 ?? 0

        var authorName: String? = nil
        if let author = message.value(forKey: "author") as? AnyObject,
           let fn = author.value(forKey: "firstName") as? String {
            let ln = author.value(forKey: "lastName") as? String ?? ""
            authorName = "\(fn) \(ln)".trimmingCharacters(in: .whitespaces)
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
        print("[TGExtra] Saved deleted message id=\(messageId)")
    }
}

// MARK: - UIView Extension (оверлей ячейки)

extension UIView {

    @objc func tgextra_chatCell_layoutSubviews() {
        tgextra_chatCell_layoutSubviews()

        guard UserDefaults.standard.bool(forKey: kTGExtraShowDeletedMessages) else {
            tgextra_removeDeletedOverlay()
            return
        }

        guard let messageId = value(forKey: "messageId") as? Int32,
              let peerId    = value(forKey: "peerId") as? Int64
        else { return }

        let isDeleted = DeletedMessageStore.shared
            .entries(forPeerId: peerId)
            .contains { $0.messageId == messageId }

        isDeleted ? tgextra_applyDeletedOverlay() : tgextra_removeDeletedOverlay()
    }

    private static let overlayTag = 0x74676578

    func tgextra_applyDeletedOverlay() {
        guard viewWithTag(UIView.overlayTag) == nil else { return }
        alpha = 0.45

        let overlay = UIView(frame: bounds)
        overlay.tag = UIView.overlayTag
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let trash = UILabel()
        trash.text = "🗑️"
        trash.font = .systemFont(ofSize: 18)
        trash.sizeToFit()
        trash.center = CGPoint(x: bounds.width - 20, y: 12)
        trash.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
        overlay.addSubview(trash)

        let label = UILabel()
        label.text = "Удалено"
        label.font = .italicSystemFont(ofSize: 11)
        label.textColor = .secondaryLabel
        label.sizeToFit()
        label.frame.origin = CGPoint(
            x: trash.frame.minX - label.frame.width - 4,
            y: trash.frame.minY + (trash.frame.height - label.frame.height) / 2
        )
        label.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
        overlay.addSubview(label)

        addSubview(overlay)
    }

    func tgextra_removeDeletedOverlay() {
        viewWithTag(UIView.overlayTag)?.removeFromSuperview()
        alpha = 1.0
    }
}

// MARK: - UIWindow Helper

extension UIWindow {
    func tgextra_findVC(className: String) -> UIViewController? {
        return rootViewController?.tgextra_findVC(className: className)
    }
}

extension UIViewController {
    func tgextra_findVC(className: String) -> UIViewController? {
        if NSStringFromClass(type(of: self)).contains(className) { return self }
        for child in children {
            if let found = child.tgextra_findVC(className: className) { return found }
        }
        return presentedViewController?.tgextra_findVC(className: className)
    }
}
