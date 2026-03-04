import Foundation
import UIKit
import ObjectiveC

// kTGExtraShowDeletedMessages объявлен в DeletedMessageStore.swift

// MARK: - Индекс секции Messages
private let kMessagesSectionIndex = 2

// MARK: - Установка хуков таблицы (вызывается из ObjC)

@objc public class TGExtraDeletedMessages: NSObject {

    // Этот метод вызывается из TGExtraDeletedMessagesLoader.m через +load
    @objc public static func setup() {
        installMenuHooks()
        if UserDefaults.standard.bool(forKey: kTGExtraShowDeletedMessages) {
            DeletedMessageHook.shared.install()
        }
        print("[TGExtra] DeletedMessages setup complete ✓")
    }

    static func installMenuHooks() {
        guard let cls = NSClassFromString("TGExtra") else {
            // TGExtra ещё не загружен — попробуем позже при открытии меню
            hookViewDidLoad()
            return
        }
        swizzleTableMethods(on: cls)
    }

    static func hookViewDidLoad() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard let cls = NSClassFromString("TGExtra") else { return }
            swizzleTableMethods(on: cls)
        }
    }

    static func swizzleTableMethods(on cls: AnyClass) {
        let pairs: [(String, Selector)] = [
            ("numberOfSectionsInTableView:",       #selector(TGExtraHookProxy.tgextra_numberOfSections(_:))),
            ("tableView:numberOfRowsInSection:",   #selector(TGExtraHookProxy.tgextra_numberOfRows(_:inSection:))),
            ("tableView:titleForHeaderInSection:", #selector(TGExtraHookProxy.tgextra_titleForHeader(_:titleForHeaderInSection:))),
            ("tableView:cellForRowAtIndexPath:",   #selector(TGExtraHookProxy.tgextra_cellForRow(_:cellForRowAt:))),
            ("switchKeyForIndexPath:",             #selector(TGExtraHookProxy.tgextra_switchKey(forIndexPath:))),
            ("tableView:didSelectRowAtIndexPath:", #selector(TGExtraHookProxy.tgextra_didSelect(_:didSelectRowAt:))),
        ]
        for (origName, swizSel) in pairs {
            guard
                let origM = class_getInstanceMethod(cls, NSSelectorFromString(origName)),
                let swizM = class_getInstanceMethod(TGExtraHookProxy.self, swizSel)
            else { continue }
            method_exchangeImplementations(origM, swizM)
        }
        print("[TGExtra] Table hooks installed ✓")
    }
}

// MARK: - Proxy класс

@objc class TGExtraHookProxy: NSObject {

    @objc func tgextra_numberOfSections(_ tableView: UITableView) -> Int {
        return tgextra_numberOfSections(tableView) + 1
    }

    @objc func tgextra_numberOfRows(_ tableView: UITableView, inSection section: Int) -> Int {
        if section == kMessagesSectionIndex { return 1 }
        let adj = section > kMessagesSectionIndex ? section - 1 : section
        return tgextra_numberOfRows(tableView, inSection: adj)
    }

    @objc func tgextra_titleForHeader(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == kMessagesSectionIndex { return "💬 MESSAGES" }
        let adj = section > kMessagesSectionIndex ? section - 1 : section
        return tgextra_titleForHeader(tableView, titleForHeaderInSection: adj)
    }

    @objc func tgextra_cellForRow(_ tableView: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        if ip.section == kMessagesSectionIndex {
            return TGExtraHookProxy.buildToggleCell(tableView: tableView, proxy: self)
        }
        return tgextra_cellForRow(tableView, cellForRowAt: adjusted(ip))
    }

    @objc func tgextra_switchKey(forIndexPath ip: IndexPath) -> String? {
        if ip.section == kMessagesSectionIndex { return kTGExtraShowDeletedMessages }
        return tgextra_switchKey(forIndexPath: adjusted(ip))
    }

    @objc func tgextra_didSelect(_ tableView: UITableView, didSelectRowAt ip: IndexPath) {
        if ip.section == kMessagesSectionIndex {
            tableView.deselectRow(at: ip, animated: true)
            return
        }
        tgextra_didSelect(tableView, didSelectRowAt: adjusted(ip))
    }

    private func adjusted(_ ip: IndexPath) -> IndexPath {
        let s = ip.section > kMessagesSectionIndex ? ip.section - 1 : ip.section
        return IndexPath(row: ip.row, section: s)
    }

    static func buildToggleCell(tableView: UITableView, proxy: TGExtraHookProxy) -> UITableViewCell {
        let id = "TGExtraDeletedMsgCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: id)
                   ?? UITableViewCell(style: .subtitle, reuseIdentifier: id)
        let isOn = UserDefaults.standard.bool(forKey: kTGExtraShowDeletedMessages)
        cell.textLabel?.text = "🗑️ Показывать удалённые сообщения"
        cell.detailTextLabel?.text = isOn ? "Сохраняются как полупрозрачные с 🗑️" : "Выключено"
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.selectionStyle = .none
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addTarget(proxy, action: #selector(handleToggle(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    @objc func handleToggle(_ sender: UISwitch) {
        let val = sender.isOn
        UserDefaults.standard.set(val, forKey: kTGExtraShowDeletedMessages)
        if val { DeletedMessageHook.shared.install() }
        if let tv = sender.tgextra_parentTableView() {
            tv.reloadRows(at: [IndexPath(row: 0, section: kMessagesSectionIndex)], with: .none)
        }
        TGExtraToast.show(val ? "Удалённые сообщения будут сохраняться 🗑️" : "Выключено")
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
                UIView.animate(withDuration: 0.35, delay: 2.0, animations: {
                    label.alpha = 0
                }) { _ in label.removeFromSuperview() }
            }
        }
    }
}
