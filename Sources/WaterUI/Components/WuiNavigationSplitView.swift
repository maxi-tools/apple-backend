import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiNavigationSplitView: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_split_navigation_container_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let sidebarView: WuiAnyView
    private let placeholderView: WuiAnyView
    private let detailView: WuiNavigationView?
    private let sidebarWidth: CGFloat
    private let clearSelection: Action

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiSplit = waterui_force_as_split_navigation_container(anyview)
        guard let clearSelectionPtr = ffiSplit.clear_selection else {
            fatalError("NavigationSplitLayout clear_selection action pointer is null")
        }

        let sidebarView = WuiAnyView(anyview: ffiSplit.sidebar, env: env)
        let placeholderView = WuiAnyView(anyview: ffiSplit.placeholder, env: env)

        let detailView: WuiNavigationView?
        if ffiSplit.has_detail {
            guard let detailContent = ffiSplit.detail_content else {
                fatalError("NavigationSplitLayout detail_content pointer is null while has_detail is true")
            }
            detailView = WuiNavigationView(
                ffiNav: CWaterUI.WuiNavigationView(
                    bar: ffiSplit.detail_bar,
                    content: detailContent
                ),
                env: env
            )
        } else {
            detailView = nil
        }

        self.init(
            sidebarView: sidebarView,
            placeholderView: placeholderView,
            detailView: detailView,
            sidebarWidth: CGFloat(ffiSplit.sidebar_width),
            clearSelection: Action(inner: clearSelectionPtr, env: env)
        )
    }

    init(
        sidebarView: WuiAnyView,
        placeholderView: WuiAnyView,
        detailView: WuiNavigationView?,
        sidebarWidth: CGFloat,
        clearSelection: Action
    ) {
        guard sidebarWidth.isFinite, sidebarWidth > 0 else {
            fatalError("NavigationSplitLayout sidebar width must be finite and positive")
        }

        self.sidebarView = sidebarView
        self.placeholderView = placeholderView
        self.detailView = detailView
        self.sidebarWidth = sidebarWidth
        self.clearSelection = clearSelection
        super.init(frame: .zero)

        sidebarView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(sidebarView)

        placeholderView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(placeholderView)

        if let detailView {
            detailView.translatesAutoresizingMaskIntoConstraints = true
            addSubview(detailView)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let width = proposal.width.map(CGFloat.init) ?? 320
        let height = proposal.height.map(CGFloat.init) ?? 480
        return CGSize(width: width, height: height)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        performLayout()
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        performLayout()
    }
    #endif

    private func performLayout() {
        let compact = bounds.width < compactThreshold()

        if compact {
            let showsDetail = detailView != nil
            sidebarView.isHidden = showsDetail
            sidebarView.frame = bounds

            placeholderView.isHidden = true
            placeholderView.frame = .zero

            if let detailView {
                detailView.setBackAction(clearSelection)
                detailView.isHidden = false
                detailView.frame = bounds
            }
            return
        }

        let actualSidebarWidth = min(sidebarWidth, bounds.width * 0.5)
        let sidebarFrame = CGRect(x: 0, y: 0, width: actualSidebarWidth, height: bounds.height)
        let detailFrame = CGRect(
            x: actualSidebarWidth,
            y: 0,
            width: bounds.width - actualSidebarWidth,
            height: bounds.height
        )

        sidebarView.isHidden = false
        sidebarView.frame = sidebarFrame

        if let detailView {
            detailView.setBackAction(nil)
            detailView.isHidden = false
            detailView.frame = detailFrame
            placeholderView.isHidden = true
            placeholderView.frame = .zero
        } else {
            placeholderView.isHidden = false
            placeholderView.frame = detailFrame
        }
    }

    private func compactThreshold() -> CGFloat {
        sidebarWidth + 360
    }
}
