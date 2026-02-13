import CWaterUI
import QuartzCore

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
enum WuiDynamicRangeMode {
    case standard
    case high
}

@MainActor
private enum WuiDynamicRangeAssociatedKeys {
    static var mode: UInt8 = 0
}

@MainActor
func applyDynamicRange(_ mode: WuiDynamicRangeMode, to layer: CALayer?) {
    guard let layer else { return }

    // Keep explicit nested overrides stable: if a sublayer already carries its own mode,
    // preserve that local mode and propagate from there.
    let localMode = (objc_getAssociatedObject(layer, &WuiDynamicRangeAssociatedKeys.mode) as? WuiDynamicRangeMode) ?? mode
    objc_setAssociatedObject(layer, &WuiDynamicRangeAssociatedKeys.mode, localMode, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

    #if canImport(UIKit)
    layer.preferredDynamicRange = (localMode == .high) ? .high : .standard
    #elseif canImport(AppKit)
    layer.preferredDynamicRange = (localMode == .high) ? .high : .standard
    #endif

    if let sublayers = layer.sublayers {
        for sublayer in sublayers {
            applyDynamicRange(localMode, to: sublayer)
        }
    }
}

@MainActor
func applyDynamicRange(_ mode: WuiDynamicRangeMode, to view: PlatformView) {
    objc_setAssociatedObject(view, &WuiDynamicRangeAssociatedKeys.mode, mode, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    #if canImport(AppKit)
    view.wantsLayer = true
    #endif
    applyDynamicRange(mode, to: view.layer)
}

@MainActor
func resolveDynamicRange(for view: PlatformView) -> WuiDynamicRangeMode {
    var current: PlatformView? = view
    while let node = current {
        if let tagged = objc_getAssociatedObject(node, &WuiDynamicRangeAssociatedKeys.mode) as? WuiDynamicRangeMode {
            return tagged
        }
        current = node.superview
    }
    return .high
}

@MainActor
func applyResolvedDynamicRange(to layer: CALayer?, for view: PlatformView) {
    applyDynamicRange(resolveDynamicRange(for: view), to: layer)
}

/// Component for Metadata<StandardDynamicRange>.
@MainActor
final class WuiStandardDynamicRange: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_standard_dynamic_range_id() }

    private let contentView: any WuiComponent

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_standard_dynamic_range(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        applyDynamicRange(.standard, to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func layoutPriority() -> Int32 {
        contentView.layoutPriority()
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        contentView.sizeThatFits(proposal)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.frame = bounds
        applyDynamicRange(.standard, to: self)
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        contentView.frame = bounds
        applyDynamicRange(.standard, to: self)
    }
    #endif
}

/// Component for Metadata<HighDynamicRange>.
@MainActor
final class WuiHighDynamicRange: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_high_dynamic_range_id() }

    private let contentView: any WuiComponent

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_high_dynamic_range(anyview)

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        applyDynamicRange(.high, to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func layoutPriority() -> Int32 {
        contentView.layoutPriority()
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        contentView.sizeThatFits(proposal)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.frame = bounds
        applyDynamicRange(.high, to: self)
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        contentView.frame = bounds
        applyDynamicRange(.high, to: self)
    }
    #endif
}
