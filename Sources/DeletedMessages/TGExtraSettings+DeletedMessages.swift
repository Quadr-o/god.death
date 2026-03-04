import Foundation
import UIKit
import ObjectiveC

// MARK: - UserDefaults ключ
let kTGExtraShowDeletedMessages = "TGExtraShowDeletedMessages"

// MARK: - Индекс секции Messages в таблице TGExtra
// Оригинальные секции: 0=GHOST_MODE, 1=READ_RECEIPT, 2=MISC, 3=FILE_FIXER, 4=FAKE_LOCATION, 5=LANGUAGE, 6=CREDITS
// Вставляем MESSAGES между READ_RECEIPT и MISC → индекс 2
private let kMessagesSectionIndex = 2

// MARK: - Установка хуков

public func tgextra_installDeletedMessagesHooks() {
    guard let cls = NSClassFromString("TGExtra") else {
        print("[TGExtra] Warning: TGExtra class not found — hooks skipped")
        return
    }

    let pairs: [(String, Selector)] = [
        ("numberOfSectionsInTableView:",        #selector(TGExtraHookProxy.tgextra_numberOfSections(_:))),
        ("tableView:numberOfRowsInSection:",    #selector(TGExtraHookProxy.tgextra_numberOfRows(_:inSection:))),
        ("tableView:titleForHeaderInSection:",  #selector(TGExtraHookProxy.tgextra_titleForHeader(_:titleForHeaderInSection:))),
        ("tableView:cellForRowAtIndexPath:",    #selector(TGExtraHookProxy.tgextra_cellForRow(_:cellForRowAt:))),
        ("switchKeyForIndexPath:",              #selector(TGExtraHookProxy.tgextra_switchKey(forIndexPath:))),
        ("tableView:didSelectRowAtIndexPath:",  #selector(TGExtraHookProxy.tgextra_didSelect(_:didSelectRowAt:))),
    ]

    for (origName, swizSel) in pairs {
        let origSel = NSSelectorFromString(origName)
        guard
            let origMethod = class_getInstanceMethod(cls, origSel),
            let swizMethod = class_getInstanceMethod(TGExtraHookProxy.self, swizSel)
        else {
            print("[TGExtra] Swizzle failed: \(origName)")
            continue
        }
        method_exchangeImplementations(origMethod, swizMethod)
    }

    print("[TGExtra] DeletedMessages hooks installed ✓")
}

// MARK: - Proxy с реализацией swizzled методов

@objc class TGExtraHookProxy: NSObject {

    // numberOfSections → оригинал + 1
    @objc func tgextra_numberOfSections(_ tableView: UITableView) -> Int {
        return tgextra_numberOfSections(tableView) + 1  // рекурсия до оригинала через swizzle
    }

    // numberOfRows — наша секция = 1, остальные сдвигаем
    @objc func tgextra_numberOfRows(_ tableView: UITableView, inSection section: Int) -> Int {
        if section == kMessagesSectionIndex { return 1 }
        let adj = section > kMessagesSectionIndex ? section - 1 : section
        return tgextra_numberOfRows(tableView, inSection: adj)
    }

    // titleForHeader
    @objc func tgextra_titleForHeader(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == kMessagesSectionIndex { return "💬 MESSAGES" }
        let adj = section > kMessagesSectionIndex ? section - 1 : section
        return tgextra_titleForHeader(tableView, titleForHeaderInSection: adj)
    }

    // cellForRow
    @objc func tgextra_cellForRow(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == kMessagesSectionIndex {
            return TGExtraHookProxy.buildToggleCell(tableView: tableView, proxy: self)
        }
        let adj = adjustedIndexPath(indexPath)
        return tgextra_cellForRow(tableView, cellForRowAt: adj)
    }

    // switchKeyForIndexPath — ключ UserDefaults для тоггла
    @objc func tgextra_switchKey(forIndexPath indexPath: IndexPath) -> String? {
        if indexPath.section == kMessagesSectionIndex { return kTGExtraShowDeletedMessages }
        return tgextra_switchKey(forIndexPath: adjustedIndexPath(indexPath))
    }

    // didSelectRow
    @objc func tgextra_didSelect(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if indexPath.section == kMessagesSectionIndex {
            tableView.deselectRow(at: indexPath, animated: true)
            return
        }
        tgextra_didSelect(tableView, didSelectRowAt: adjustedIndexPath(indexPath))
    }

    // MARK: - Helpers

    private func adjustedIndexPath(_ ip: IndexPath) -> IndexPath {
        let adj = ip.section > kMessagesSectionIndex ? ip.section - 1 : ip.section
        return IndexPath(row: ip.row, section: adj)
    }

    // MARK: - Построение ячейки

    static func buildToggleCell(tableView: UITableView, proxy: TGExtraHookProxy) -> UITableViewCell {
        let id = "TGExtraDeletedMsgCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
                   ?? UITableViewCell(style: .subtitle, reuseIdentifier: id)

        let isOn = UserDefaults.standard.bool(forKey: kTGExtraShowDeletedMessages)
        cell.textLabel?.text = "🗑️ Показывать удалённые сообщения"
        cell.detailTextLabel?.text = isOn
            ? "Сохраняются как полупрозрачные с иконкой 🗑️"
            : "Выключено"
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.selectionStyle = .none

        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addTarget(proxy, action: #selector(handleToggle(_:)), for: .valueChanged)
        cell.accessoryView = toggle

        return cell
    }

    @objc func handleToggle(_ sender: UISwitch) {
        let newVal = sender.isOn
        UserDefaults.standard.set(newVal, forKey: kTGExtraShowDeletedMessages)

        // При первом включении — устанавливаем хук перехвата
        if newVal { DeletedMessageHook.shared.install() }

        // Обновляем detail label
        if let tv = sender.tgextra_parentTableView() {
            tv.reloadRows(at: [IndexPath(row: 0, section: kMessagesSectionIndex)], with: .none)
        }

        TGExtraToast.show(newVal
            ? "Удалённые сообщения будут сохраняться 🗑️"
            : "Удалённые сообщения больше не сохраняются")
    }
}

// MARK: - UISwitch Helper

extension UISwitch {
    func tgextra_parentTableView() -> UITableView? {
        var v: UIView? = superview
        while v != nil {
            if let tv = v as? UITableView { return tv }
            v = v?.superview
        }
        return nil
    }
}

// MARK: - Toast

struct TGExtraToast {
    static func show(_ message: String) {
        DispatchQueue.main.async {
            guard let window = UIApplication.shared.windows.first(where: { $0.isKeyWindow }) else { return }
            let label = UILabel()
            label.text = message
            label.backgroundColor = UIColor.black.withAlphaComponent(0.78)
            label.textColor = .white
            label.textAlignment = .center
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.layer.cornerRadius = 12
            label.clipsToBounds = true
            label.numberOfLines = 0
            let pad: CGFloat = 16
            let maxW = window.bounds.width - 48
            let sz = label.sizeThatFits(CGSize(width: maxW, height: 200))
            label.frame = CGRect(
                x: (window.bounds.width - min(sz.width + pad * 2, maxW)) / 2,
                y: window.safeAreaInsets.bottom + 80,
                width: min(sz.width + pad * 2, maxW),
                height: sz.height + 14
            )
            label.alpha = 0
            window.addSubview(label)
            UIView.animate(withDuration: 0.25, animations: { label.alpha = 1 }) { _ in
                UIView.animate(withDuration: 0.35, delay: 2.0, animations: { label.alpha = 0 }) { _ in
                    label.removeFromSuperview()
                }
            }
        }
    }
}

// MARK: - Автоинициализация

@objc class TGExtraDeletedMessagesSetup: NSObject {
    @objc static func load() {
        tgextra_installDeletedMessagesHooks()
        if UserDefaults.standard.bool(forKey: kTGExtraShowDeletedMessages) {
            DeletedMessageHook.shared.install()
        }
    }
}
