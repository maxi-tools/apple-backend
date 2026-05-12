import CWaterUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

@MainActor
final class WuiResolvedColorView: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_resolved_color_id() }

    private(set) var stretchAxis: WuiStretchAxis

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let color = waterui_force_as_resolved_color(anyview)
        self.init(color: color, stretchAxis: stretchAxis)
    }

    init(color: WuiResolvedColor, stretchAxis: WuiStretchAxis) {
        self.stretchAxis = stretchAxis
        super.init(frame: .zero)

        #if canImport(UIKit)
            backgroundColor = color.toUIColor()
        #elseif canImport(AppKit)
            wantsLayer = true
            layer?.backgroundColor = color.toNSColor().cgColor
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let fallback: CGFloat = 10
        return CGSize(
            width: proposal.width.map { CGFloat($0) } ?? fallback,
            height: proposal.height.map { CGFloat($0) } ?? fallback
        )
    }

    #if canImport(AppKit)
        override var isFlipped: Bool { true }
    #endif
}
