import CWaterUI
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
enum MenuNodeData {
    case command(MenuCommandData)
    case divider
    case menu(MenuSubmenuData)
}

@MainActor
struct MenuCommandData {
    let label: String
    let iconName: String?
    let actionPtr: OpaquePointer?
    let isDisabled: Bool
    let isSelected: Bool
    let shortcut: MenuShortcutData?
}

@MainActor
struct MenuSubmenuData {
    let label: String
    let iconName: String?
    let items: [MenuNodeData]
}

struct MenuShortcutData {
    let keyEquivalent: String
    let command: Bool
    let shift: Bool
    let option: Bool
    let control: Bool

    #if canImport(UIKit)
    var modifierMask: UIKeyModifierFlags {
        var mask: UIKeyModifierFlags = []
        if command { mask.insert(.command) }
        if shift { mask.insert(.shift) }
        if option { mask.insert(.alternate) }
        if control { mask.insert(.control) }
        return mask
    }
    #elseif canImport(AppKit)
    var modifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if command { mask.insert(.command) }
        if shift { mask.insert(.shift) }
        if option { mask.insert(.option) }
        if control { mask.insert(.control) }
        return mask
    }
    #endif
}

#if canImport(UIKit)
struct UIKitMenuShortcut {
    let input: String
    let modifierMask: UIKeyModifierFlags
    let title: String
    let actionPtr: OpaquePointer
}
#endif

final class MenuActionRef: NSObject {
    let actionPtr: OpaquePointer

    init(actionPtr: OpaquePointer) {
        self.actionPtr = actionPtr
    }
}

@MainActor
func parseMenuNodes(from array: CWaterUI.WuiArray_WuiMenuItem) -> [MenuNodeData] {
    WuiArray<CWaterUI.WuiMenuItem>(array).toArray().map(parseMenuNode)
}

@MainActor
private func parseMenuNode(_ item: CWaterUI.WuiMenuItem) -> MenuNodeData {
    switch item.tag {
    case WuiMenuItemTag_Command:
        return .command(
            MenuCommandData(
                label: readRequiredMenuLabel(item.label, field: "label"),
                iconName: readMenuIconName(item.icon),
                actionPtr: item.action.map { OpaquePointer(UnsafeRawPointer($0)) },
                isDisabled: readRequiredMenuBool(item.disabled, field: "disabled"),
                isSelected: readRequiredMenuBool(item.selected, field: "selected"),
                shortcut: readMenuShortcut(item.shortcut)
            )
        )
    case WuiMenuItemTag_Divider:
        return .divider
    case WuiMenuItemTag_Menu:
        guard let itemsPtr = item.items else {
            fatalError("WuiMenuItem.items is null for submenu item")
        }
        let nested = WuiComputed<CWaterUI.WuiArray_WuiMenuItem>(itemsPtr).value
        return .menu(
            MenuSubmenuData(
                label: readRequiredMenuLabel(item.label, field: "label"),
                iconName: readMenuIconName(item.icon),
                items: parseMenuNodes(from: nested)
            )
        )
    default:
        fatalError("Unsupported WuiMenuItemTag: \(item.tag.rawValue)")
    }
}

@MainActor
private func readRequiredMenuLabel(_ text: CWaterUI.WuiText, field: String) -> String {
    guard let textPtr = text.content else {
        fatalError("WuiMenuItem.\(field).content is null")
    }
    return WuiStyledStr(waterui_read_computed_styled_str(textPtr)).toString()
}

private func readMenuIconName(_ iconPtr: UnsafeMutablePointer<CWaterUI.WuiSystemIcon>?) -> String? {
    guard let iconPtr else { return nil }
    return WuiStr(iconPtr.pointee.name).toString()
}

@MainActor
private func readRequiredMenuBool(
    _ valuePtr: OpaquePointer?,
    field: String
) -> Bool {
    guard let valuePtr else {
        fatalError("WuiMenuItem.\(field) is null for command item")
    }
    return WuiComputed<Bool>(valuePtr).value
}

private func readMenuShortcut(
    _ shortcutPtr: UnsafeMutablePointer<CWaterUI.WuiShortcut>?
) -> MenuShortcutData? {
    guard let shortcutPtr else { return nil }
    let shortcut = shortcutPtr.pointee
    return MenuShortcutData(
        keyEquivalent: WuiStr(shortcut.key).toString(),
        command: shortcut.modifiers.command,
        shift: shortcut.modifiers.shift,
        option: shortcut.modifiers.option,
        control: shortcut.modifiers.control
    )
}

#if canImport(UIKit)
@MainActor
func buildUIKitMenuElements(
    from nodes: [MenuNodeData],
    handler: @escaping (OpaquePointer) -> Void
) -> [UIMenuElement] {
    let groups = splitMenuGroups(nodes)
    guard groups.count > 1 else {
        return groups.first.map { buildUIKitMenuGroup($0, handler: handler) } ?? []
    }

    return groups.map { group in
        UIMenu(title: "", options: .displayInline, children: buildUIKitMenuGroup(group, handler: handler))
    }
}

@MainActor
func buildUIKitMenu(
    title: String,
    imageName: String? = nil,
    from nodes: [MenuNodeData],
    handler: @escaping (OpaquePointer) -> Void
) -> UIMenu {
    UIMenu(
        title: title,
        image: uiMenuImage(named: imageName),
        identifier: nil,
        options: [],
        children: buildUIKitMenuElements(from: nodes, handler: handler)
    )
}

@MainActor
private func buildUIKitMenuGroup(
    _ nodes: [MenuNodeData],
    handler: @escaping (OpaquePointer) -> Void
) -> [UIMenuElement] {
    nodes.compactMap { node in
        switch node {
        case let .command(command):
            let attributes: UIMenuElement.Attributes =
                command.isDisabled || command.actionPtr == nil ? [.disabled] : []
            return UIAction(
                title: command.label,
                image: uiMenuImage(named: command.iconName),
                identifier: nil,
                discoverabilityTitle: nil,
                attributes: attributes,
                state: command.isSelected ? .on : .off
            ) { _ in
                guard let actionPtr = command.actionPtr else { return }
                handler(actionPtr)
            }
        case .divider:
            return nil
        case let .menu(menu):
            return buildUIKitMenu(
                title: menu.label,
                imageName: menu.iconName,
                from: menu.items,
                handler: handler
            )
        }
    }
}

private func uiMenuImage(named name: String?) -> UIImage? {
    guard let name else { return nil }
    return UIImage(systemName: name)
}

@MainActor
func buildUIKitSystemMenus(
    from nodes: [MenuNodeData],
    handler: @escaping (OpaquePointer) -> Void
) -> [UIMenu] {
    nodes.enumerated().map { index, node in
        guard case let .menu(menu) = node else {
            fatalError("App::menu_bar only accepts top-level Menu values")
        }
        return UIMenu(
            title: menu.label,
            image: uiMenuImage(named: menu.iconName),
            identifier: UIMenu.Identifier("dev.waterui.menu.\(index)"),
            options: [],
            children: buildUIKitMenuElements(from: menu.items, handler: handler)
        )
    }
}

@MainActor
func collectUIKitMenuShortcuts(from nodes: [MenuNodeData]) -> [UIKitMenuShortcut] {
    var shortcuts: [UIKitMenuShortcut] = []

    func visit(_ nodes: [MenuNodeData]) {
        for node in nodes {
            switch node {
            case .divider:
                continue
            case let .menu(menu):
                visit(menu.items)
            case let .command(command):
                guard !command.isDisabled else { continue }
                guard let actionPtr = command.actionPtr, let shortcut = command.shortcut else { continue }
                shortcuts.append(
                    UIKitMenuShortcut(
                        input: shortcut.keyEquivalent,
                        modifierMask: shortcut.modifierMask,
                        title: command.label,
                        actionPtr: actionPtr
                    )
                )
            }
        }
    }

    visit(nodes)
    return shortcuts
}

private func splitMenuGroups(_ nodes: [MenuNodeData]) -> [[MenuNodeData]] {
    var groups: [[MenuNodeData]] = []
    var current: [MenuNodeData] = []

    for node in nodes {
        if case .divider = node {
            if !current.isEmpty {
                groups.append(current)
                current.removeAll(keepingCapacity: true)
            }
            continue
        }
        current.append(node)
    }

    if !current.isEmpty {
        groups.append(current)
    }

    return groups
}
#endif

#if canImport(AppKit)
@MainActor
func appendAppKitMenuItems(
    _ nodes: [MenuNodeData],
    to menu: NSMenu,
    target: AnyObject,
    action: Selector
) {
    for node in nodes {
        switch node {
        case .divider:
            menu.addItem(.separator())
        case let .command(command):
            let item = NSMenuItem(
                title: command.label,
                action: command.actionPtr == nil ? nil : action,
                keyEquivalent: command.shortcut?.keyEquivalent ?? ""
            )
            item.target = command.actionPtr == nil ? nil : target
            item.isEnabled = !command.isDisabled && command.actionPtr != nil
            item.state = command.isSelected ? .on : .off
            item.keyEquivalentModifierMask = command.shortcut?.modifierMask ?? []
            item.image = appKitMenuImage(named: command.iconName)
            if let actionPtr = command.actionPtr {
                item.representedObject = MenuActionRef(actionPtr: actionPtr)
            }
            menu.addItem(item)
        case let .menu(submenu):
            let item = NSMenuItem(title: submenu.label, action: nil, keyEquivalent: "")
            item.image = appKitMenuImage(named: submenu.iconName)
            let nested = NSMenu(title: submenu.label)
            appendAppKitMenuItems(submenu.items, to: nested, target: target, action: action)
            item.submenu = nested
            menu.addItem(item)
        }
    }
}

private func appKitMenuImage(named name: String?) -> NSImage? {
    guard let name else { return nil }
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)
}
#endif
