import CWaterUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Manages a collection of WaterUI views from Rust.
@MainActor
final class WuiAnyViews {
    let id = UUID()
    private let inner: OpaquePointer

    init(_ inner: OpaquePointer) {
        self.inner = inner
    }

    var ptr: OpaquePointer { inner }

    @MainActor deinit {
        waterui_drop_anyviews(inner)
    }

    var count: Int {
        Int(waterui_anyviews_len(inner))
    }

    func getId(at index: Int) -> WuiId {
        waterui_anyviews_get_id(inner, UInt(index))
    }

    /// Returns a WuiAnyView which is already a UIView/NSView.
    func getView(at index: Int, env: WuiEnvironment) -> WuiAnyView {
        let ptr = waterui_anyviews_get_view(inner, UInt(index))
        return WuiAnyView(anyview: ptr!, env: env)
    }

    /// Returns all views as an array of WuiAnyView (which are UIView/NSView).
    func getAllViews(env: WuiEnvironment) -> [WuiAnyView] {
        (0..<count).map { index in
            getView(at: index, env: env)
        }
    }
}

/// Creates a watcher for WuiAnyViews updates.
@MainActor
func makeAnyViewsWatcher(
    _ f: @escaping (WuiAnyViews, WuiWatcherMetadata) -> Void
) -> OpaquePointer {
    let data = wrap(f)

    let call: @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, OpaquePointer?) -> Void =
        {
            data, value, metadata in
            callWrapper(data, WuiAnyViews(value!), metadata)
        }

    let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
        dropWrapper($0, WuiAnyViews.self)
    }

    guard let watcher = waterui_new_watcher_views(data, call, drop) else {
        fatalError("Failed to create AnyViews watcher")
    }
    return watcher
}

/// Watches a `WuiAnyViews` collection for structural changes.
///
/// Callback receives the full ordered list of view IDs whenever the collection updates.
@MainActor
func watchAnyViewsIds(
    _ anyViews: WuiAnyViews,
    _ f: @escaping ([Int32], WuiWatcherMetadata) -> Void
) -> WatcherGuard {
    let data = wrap { (ids: CWaterUI.WuiArray_WuiId, metadata: WuiWatcherMetadata) in
        let array = WuiArray<CWaterUI.WuiId>(ids).toArray()
        f(array.map(\.inner), metadata)
    }

    let call: @convention(c) (UnsafeMutableRawPointer?, CWaterUI.WuiArray_WuiId, OpaquePointer?) -> Void =
        { data, value, metadata in
            callWrapper(data, value, metadata)
        }

    let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
        dropWrapper($0, CWaterUI.WuiArray_WuiId.self)
    }

    guard let guardPtr = waterui_anyviews_watch(anyViews.ptr, data, call, drop) else {
        fatalError("Failed to watch anyviews")
    }
    return WatcherGuard(guardPtr)
}
