import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
struct WuiNavigationTitle {
    let view: WuiAnyView
    let text: String?
    let isPlainText: Bool
}

@MainActor
struct WuiNavigationSearch {
    let text: WuiBinding<WuiStr>
    let promptView: WuiAnyView
    let prompt: String
}

@MainActor
final class WuiNavigationSearchCoordinator: NSObject {
    private let search: WuiNavigationSearch
    private var watcher: WatcherGuard?
    private var isSyncing = false

    init(search: WuiNavigationSearch) {
        self.search = search
    }

    #if canImport(UIKit)
    private weak var uiSearchBar: UISearchBar?

    func attach(searchBar: UISearchBar) {
        uiSearchBar = searchBar
        searchBar.placeholder = search.prompt
        searchBar.delegate = self
        applyText(search.text.value.toString())
        watcher = search.text.watch { [weak self] value, _ in
            self?.applyText(value.toString())
        }
    }

    func attach(searchController: UISearchController) {
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.hidesNavigationBarDuringPresentation = false
        attach(searchBar: searchController.searchBar)
    }

    private func applyText(_ text: String) {
        guard let uiSearchBar else { return }
        guard uiSearchBar.text != text else { return }
        isSyncing = true
        uiSearchBar.text = text
        isSyncing = false
    }
    #elseif canImport(AppKit)
    private weak var nsSearchField: NSSearchField?

    func attach(searchField: NSSearchField) {
        nsSearchField = searchField
        searchField.placeholderString = search.prompt
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        applyText(search.text.value.toString())
        watcher = search.text.watch { [weak self] value, _ in
            self?.applyText(value.toString())
        }
    }

    private func applyText(_ text: String) {
        guard let nsSearchField else { return }
        guard nsSearchField.stringValue != text else { return }
        isSyncing = true
        nsSearchField.stringValue = text
        isSyncing = false
    }
    #endif

    fileprivate func updateBinding(_ text: String) {
        guard !isSyncing else { return }
        search.text.set(WuiStr(string: text))
    }
}

#if canImport(UIKit)
extension WuiNavigationSearchCoordinator: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        updateBinding(searchText)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
    }
}
#elseif canImport(AppKit)
extension WuiNavigationSearchCoordinator: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else {
            fatalError("Navigation search delegate received unexpected control")
        }
        updateBinding(field.stringValue)
    }
}
#endif

@MainActor
func makeInlineNavigationSearchView(
    _ search: WuiNavigationSearch
) -> (PlatformView, WuiNavigationSearchCoordinator) {
    let coordinator = WuiNavigationSearchCoordinator(search: search)
    #if canImport(UIKit)
    let searchBar = UISearchBar(frame: .zero)
    searchBar.searchBarStyle = .minimal
    coordinator.attach(searchBar: searchBar)
    return (searchBar, coordinator)
    #elseif canImport(AppKit)
    let searchField = NSSearchField(frame: .zero)
    coordinator.attach(searchField: searchField)
    return (searchField, coordinator)
    #endif
}

#if canImport(UIKit)
@MainActor
func makeNavigationSearchController(
    _ search: WuiNavigationSearch
) -> (UISearchController, WuiNavigationSearchCoordinator) {
    let controller = UISearchController(searchResultsController: nil)
    let coordinator = WuiNavigationSearchCoordinator(search: search)
    coordinator.attach(searchController: controller)
    return (controller, coordinator)
}
#endif

@MainActor
struct WuiNavigationBarState {
    let title: WuiNavigationTitle
    let leading: WuiAnyView?
    let trailing: WuiAnyView?
    let search: WuiNavigationSearch?
    let color: WuiComputed<WuiResolvedColor>?
    let hidden: WuiComputed<Bool>?
}

@MainActor
func makeNavigationBarState(from bar: CWaterUI.WuiBar, env: WuiEnvironment) -> WuiNavigationBarState {
    guard let titlePtr = bar.title else {
        fatalError("Navigation bar title pointer is null")
    }

    let title = makeNavigationTitle(from: titlePtr, env: env)
    let leading = bar.leading.map { WuiAnyView(anyview: $0, env: env) }
    let trailing = bar.trailing.map { WuiAnyView(anyview: $0, env: env) }

    let color: WuiComputed<WuiResolvedColor>?
    if let colorPtr = bar.color {
        guard let rawColor = waterui_read_computed_color(colorPtr) else {
            fatalError("Navigation bar color computed pointer returned null color")
        }
        let colorValue = WuiColor(rawColor)
        color = colorValue.resolve(in: env)
    } else {
        color = nil
    }

    let hidden: WuiComputed<Bool>?
    if let hiddenPtr = bar.hidden {
        hidden = WuiComputed<Bool>(hiddenPtr)
    } else {
        hidden = nil
    }

    let search: WuiNavigationSearch?
    if let searchPtr = bar.search {
        let binding = WuiBinding<WuiStr>(searchPtr.pointee.text)
        let promptView = WuiAnyView(anyview: searchPtr.pointee.prompt, env: env)
        search = WuiNavigationSearch(
            text: binding,
            promptView: promptView,
            prompt: extractNavigationTitleText(from: promptView).0 ?? ""
        )
    } else {
        search = nil
    }

    return WuiNavigationBarState(
        title: title,
        leading: leading,
        trailing: trailing,
        search: search,
        color: color,
        hidden: hidden
    )
}

@MainActor
private func makeNavigationTitle(from titlePtr: OpaquePointer, env: WuiEnvironment) -> WuiNavigationTitle {
    let titleView = WuiAnyView(anyview: titlePtr, env: env)
    let (text, isPlainText) = extractNavigationTitleText(from: titleView)
    return WuiNavigationTitle(view: titleView, text: text, isPlainText: isPlainText)
}

@MainActor
private func extractNavigationTitleText(from titleView: PlatformView) -> (String?, Bool) {
    #if canImport(UIKit)
    func findText(in view: UIView) -> String? {
        if let label = view as? UILabel {
            return label.attributedText?.string ?? label.text
        }
        for sub in view.subviews {
            if let t = findText(in: sub) { return t }
        }
        return nil
    }
    if let text = findText(in: titleView) {
        return (text, true)
    }
    #elseif canImport(AppKit)
    func findText(in view: NSView) -> String? {
        if let field = view as? NSTextField {
            let plain = field.stringValue
            if !plain.isEmpty { return plain }
            let attributed = field.attributedStringValue.string
            return attributed.isEmpty ? nil : attributed
        }
        for sub in view.subviews {
            if let t = findText(in: sub) { return t }
        }
        return nil
    }
    if let text = findText(in: titleView) {
        return (text, true)
    }
    #endif

    return (nil, false)
}
