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
struct WuiNavigationBarState {
    let title: WuiNavigationTitle
    let color: WuiComputed<WuiResolvedColor>?
    let hidden: WuiComputed<Bool>?
}

@MainActor
func makeNavigationBarState(from bar: CWaterUI.WuiBar, env: WuiEnvironment) -> WuiNavigationBarState {
    guard let titlePtr = bar.title else {
        fatalError("Navigation bar title pointer is null")
    }

    let title = makeNavigationTitle(from: titlePtr, env: env)

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

    return WuiNavigationBarState(title: title, color: color, hidden: hidden)
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
