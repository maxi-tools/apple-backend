// WuiContainer.swift
// Dynamic container layout component - children accessed via Views trait (supports future lazy loading)
//
// # Layout Behavior
// Container delegates layout calculations to the Rust layout engine.
// Size and placement are determined by the layout algorithm (VStack, HStack, etc.).
// Children are accessed via WuiAnyViews for future lazy loading support.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: Depends on children and layout algorithm
// // - sizeThatFits: Delegates to Rust layout engine
// // - Priority: 0 (default)

import CWaterUI
import OSLog

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// A native container that uses the Rust layout engine for child positioning.
/// Container uses `WuiAnyViews` for dynamic child access, enabling future lazy loading.
/// Similar to SwiftUI's ForEach - can access view IDs individually.
@MainActor
final class WuiContainer: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_layout_container_id() }

    private(set) var stretchAxis: WuiStretchAxis

    private var wuiLayout: WuiLayout
    private var anyViews: WuiAnyViews  // Stored for lazy access & view ID lookup
    private var contentsWatcher: WatcherGuard?
    private var childViews: [WuiAnyView] = []  // Currently loaded views
    private var cachedSubViews: CachedSubViewArray?
    private let bridge = NativeLayoutBridge()
    private let env: WuiEnvironment

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let container: CWaterUI.WuiContainer = waterui_force_as_layout_container(anyview)
        let layout = WuiLayout(inner: container.layout!)
        let anyViews = WuiAnyViews(container.contents)
        self.init(stretchAxis: stretchAxis, layout: layout, anyViews: anyViews, env: env)
    }

    // MARK: - Designated Init

    init(stretchAxis: WuiStretchAxis, layout: WuiLayout, anyViews: WuiAnyViews, env: WuiEnvironment)
    {
        self.stretchAxis = stretchAxis
        self.wuiLayout = layout
        self.anyViews = anyViews
        self.env = env
        super.init(frame: .zero)

        reloadChildrenFromRust()
        installContentsWatch()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Child Loading

    private func installContentsWatch() {
        contentsWatcher = watchAnyViewsIds(anyViews) { [weak self] ids, metadata in
            guard let self else { return }
            withPlatformAnimation(metadata) {
                self.syncChildren(ids: ids)
            }
        }
    }

    private func reloadChildrenFromRust() {
        syncChildren(ids: anyViews.allIds())
    }

    private func syncChildren(ids: [Int32]) {
        var children: [WuiAnyView] = []
        children.reserveCapacity(ids.count)
        var seenIds = Set<Int32>()
        for (index, id) in ids.enumerated() {
            precondition(seenIds.insert(id).inserted, "Duplicate child view id in WuiContainer: \(id)")
            let child = anyViews.getView(at: index, env: env)
            child.translatesAutoresizingMaskIntoConstraints = true
            children.append(child)
        }
        setChildren(children)
    }

    /// Get the unique view ID at the specified index.
    /// This returns the view's identity, not the type ID.
    func getViewId(at index: Int) -> WuiId {
        anyViews.getId(at: index)
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        measure(proposal).cgSize
    }

    func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
        return bridge.containerMeasure(
            layout: wuiLayout,
            parentProposal: proposal,
            children: subViewCache()
        )
    }

    // MARK: - Layout

    #if canImport(UIKit)
        override func layoutSubviews() {
            super.layoutSubviews()
            performLayout()
        }

        override func sizeThatFits(_ size: CGSize) -> CGSize {
            let proposal = WuiProposalSize(size: size)
            return sizeThatFits(proposal)
        }

        override var intrinsicContentSize: CGSize {
            sizeThatFits(WuiProposalSize())
        }
    #elseif canImport(AppKit)
        override func layout() {
            super.layout()
            performLayout()
        }

        override var fittingSize: NSSize {
            sizeThatFits(WuiProposalSize())
        }

        override var intrinsicContentSize: NSSize {
            sizeThatFits(WuiProposalSize())
        }

        override var isFlipped: Bool { true }
    #endif

    private func performLayout() {
        guard !childViews.isEmpty else { return }

        // CRITICAL: Create proposal from bounds so children measure with actual available width
        // This ensures VStack centering works correctly - children know the real container width
        let boundsProposal = WuiProposalSize(
            width: Float(bounds.width), height: Float(bounds.height))

        // Measure with bounds-based proposal first - this ensures children know available width
        _ = bridge.containerSize(
            layout: wuiLayout,
            parentProposal: boundsProposal,
            children: subViewCache()
        )

        let rects = bridge.placements(
            layout: wuiLayout,
            bounds: bounds,
            children: subViewCache()
        )

        for (index, rect) in rects.enumerated() {
            guard index < childViews.count else { break }
            var frame = rect
            guard frame.isValidForLayout else {
                let warn =
                    "[WuiLayout] Warning: WuiContainer received invalid rect for child \(index): \(frame)"
                Logger.waterui.warning("\(warn)")
                continue
            }

            #if canImport(AppKit)
                // Convert to AppKit coordinate system if not flipped
                if !isFlipped {
                    frame.origin.y = bounds.height - frame.origin.y - frame.height
                }
            #endif

            childViews[index].frame = frame
        }
    }

    // MARK: - Child Management

    func setChildren(_ newChildren: [WuiAnyView]) {
        for child in childViews {
            child.removeFromSuperview()
        }

        childViews = newChildren
        cachedSubViews = nil
        for child in newChildren {
            child.translatesAutoresizingMaskIntoConstraints = true
            addSubview(child)
        }

        #if canImport(UIKit)
            setNeedsLayout()
        #elseif canImport(AppKit)
            needsLayout = true
        #endif
    }

    private func subViewCache() -> CachedSubViewArray {
        if let cachedSubViews {
            return cachedSubViews
        }

        let cache = bridge.createCachedSubViewArray(children: childViews) { child, childProposal in
            child.measure(childProposal)
        }
        cachedSubViews = cache
        return cache
    }
}
