// WuiList.swift
// List component - scrollable collection of items with optional delete support
//
// # Layout Behavior
// List is greedy - it expands to fill all available space.
// Items are rendered as rows in a scrollable list.
// Supports swipe-to-delete when items have delete handlers.

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private struct ResolvedListItem {
    let view: WuiAnyView
    let deletable: WuiComputed<Bool>?
}

@MainActor
private func resolveListItem(
    from contents: WuiAnyViews,
    at index: Int,
    env: WuiEnvironment
) -> ResolvedListItem {
    guard let viewPtr = waterui_anyviews_get_view(contents.ptr, UInt(index)) else {
        fatalError("List item view pointer is null at index \(index)")
    }

    let listItem = waterui_force_as_list_item(viewPtr)
    guard let contentPtr = listItem.content else {
        fatalError("List item content pointer is null at index \(index)")
    }

    return ResolvedListItem(
        view: WuiAnyView(anyview: contentPtr, env: env),
        deletable: listItem.deletable.map { WuiComputed<Bool>($0) }
    )
}

@MainActor
private func resolveListItemDeletable(
    from contents: WuiAnyViews,
    at index: Int,
    defaultValue: Bool = true
) -> Bool {
    guard let viewPtr = waterui_anyviews_get_view(contents.ptr, UInt(index)) else {
        fatalError("List item view pointer is null at index \(index)")
    }

    let listItem = waterui_force_as_list_item(viewPtr)
    if let contentPtr = listItem.content {
        waterui_drop_anyview(contentPtr)
    }

    guard let deletablePtr = listItem.deletable else {
        return defaultValue
    }

    let deletable = WuiComputed<Bool>(deletablePtr)
    return deletable.value
}

#if canImport(UIKit)
@MainActor
final class WuiList: UITableView, WuiComponent, UITableViewDataSource, UITableViewDelegate {
    static var rawId: CWaterUI.WuiTypeId { waterui_list_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let env: WuiEnvironment
    private let contents: WuiAnyViews
    private var contentsWatcher: WatcherGuard?
    private var itemIds: [Int32] = []

    // Edit mode state
    private var editingComputed: WuiComputed<Bool>?
    private var editingWatcher: WatcherGuard?

    // Callbacks
    private var onDeletePtr: OpaquePointer?
    private var onMovePtr: OpaquePointer?

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiList: CWaterUI.WuiList = waterui_force_as_list(anyview)
        self.init(ffiList: ffiList, env: env)
    }

    // MARK: - Designated Init

    init(ffiList: CWaterUI.WuiList, env: WuiEnvironment) {
        self.env = env
        self.contents = WuiAnyViews(ffiList.contents)
        self.onDeletePtr = ffiList.on_delete
        self.onMovePtr = ffiList.on_move
        super.init(frame: .zero, style: .plain)

        dataSource = self
        delegate = self

        // Register a reusable cell class
        register(WuiListCell.self, forCellReuseIdentifier: WuiListCell.reuseIdentifier)

        // Allow cells to size themselves
        rowHeight = UITableView.automaticDimension
        estimatedRowHeight = 44

        // Setup editing state if provided
        if let editingPtr = ffiList.editing {
            editingComputed = WuiComputed<Bool>(editingPtr)
            editingWatcher = editingComputed?.watch { [weak self] newValue, metadata in
                guard let self = self else { return }
                let animated = metadata.animation != nil
                self.setEditing(newValue, animated: animated)
            }
            // Apply initial editing state
            if let isEditing = editingComputed?.value {
                setEditing(isEditing, animated: false)
            }
        }

        // Initial load + watch structural changes.
        reloadFromRust(animated: false)
        installContentsWatch()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor deinit {
        // Drop action pointers if they exist
        if let ptr = onDeletePtr {
            waterui_drop_index_action(ptr)
        }
        if let ptr = onMovePtr {
            waterui_drop_move_action(ptr)
        }
    }

    // MARK: - Item Loading

    private func installContentsWatch() {
        contentsWatcher = watchAnyViewsIds(contents) { [weak self] ids, metadata in
            guard let self else { return }
            self.applyRustUpdate(ids: ids, metadata: metadata)
        }
    }

    private func reloadFromRust(animated: Bool) {
        updateFromRust(ids: contents.allIds(), animated: animated)
    }

    private func applyRustUpdate(ids: [Int32], metadata: WuiWatcherMetadata) {
        let animated = metadata.animation != nil
        updateFromRust(ids: ids, animated: animated)
    }

    private func updateFromRust(ids: [Int32], animated: Bool) {
        let oldIds = itemIds
        let newIds = ids
        itemIds = newIds

        guard animated else {
            reloadData()
            return
        }

        let diff = newIds.difference(from: oldIds).inferringMoves()
        if diff.isEmpty {
            return
        }

        performBatchUpdates {
            let deletions: [IndexPath] = diff.removals
                .compactMap { (change) -> IndexPath? in
                    guard case let .remove(offset, _, _) = change else { return nil }
                    return IndexPath(row: offset, section: 0)
                }
                .sorted { (lhs, rhs) in lhs.row > rhs.row }
            let insertions: [IndexPath] = diff.insertions
                .compactMap { (change) -> IndexPath? in
                    guard case let .insert(offset, _, _) = change else { return nil }
                    return IndexPath(row: offset, section: 0)
                }
                .sorted { (lhs, rhs) in lhs.row < rhs.row }

            if !deletions.isEmpty { deleteRows(at: deletions, with: .automatic) }
            if !insertions.isEmpty { insertRows(at: insertions, with: .automatic) }

            for change in diff {
                switch change {
                case let .remove(offset, _, associatedWith: .some(to)):
                    moveRow(at: IndexPath(row: offset, section: 0), to: IndexPath(row: to, section: 0))
                default:
                    break
                }
            }
        }
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let width = proposal.width.map { CGFloat($0) } ?? UIScreen.main.bounds.width
        let height = proposal.height.map { CGFloat($0) } ?? UIScreen.main.bounds.height
        return CGSize(width: width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return itemIds.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let dequeuedCell = tableView.dequeueReusableCell(withIdentifier: WuiListCell.reuseIdentifier, for: indexPath)
        guard let cell = dequeuedCell as? WuiListCell else {
            fatalError("Expected WuiListCell for reuse identifier \(WuiListCell.reuseIdentifier)")
        }
        let item = resolveListItem(from: contents, at: indexPath.row, env: env)
        let itemId = itemIds[indexPath.row]
        cell.configure(with: item.view, deletable: item.deletable) { [weak self] metadata in
            guard let self else { return }
            guard let row = self.itemIds.firstIndex(of: itemId) else { return }
            self.reloadRows(
                at: [IndexPath(row: row, section: 0)],
                with: metadata.animation != nil ? .automatic : .none
            )
        }
        return cell
    }

    // MARK: - Editing Support

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        // Can edit if we have a delete callback and the item is deletable
        guard onDeletePtr != nil else { return false }
        return resolveListItemDeletable(from: contents, at: indexPath.row)
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            itemIds.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)

            // Then call Rust callback
            if let deletePtr = onDeletePtr {
                waterui_call_index_action(deletePtr, env.inner, UInt(indexPath.row))
            }
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard onDeletePtr != nil else { return nil }
        guard resolveListItemDeletable(from: contents, at: indexPath.row) else { return nil }

        let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            guard let self = self else {
                completion(false)
                return
            }

            self.itemIds.remove(at: indexPath.row)
            self.deleteRows(at: [indexPath], with: .automatic)

            // Then call Rust callback
            if let deletePtr = self.onDeletePtr {
                waterui_call_index_action(deletePtr, self.env.inner, UInt(indexPath.row))
            }

            completion(true)
        }

        return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    // MARK: - Move/Reorder Support

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return onMovePtr != nil
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let id = itemIds.remove(at: sourceIndexPath.row)
        itemIds.insert(id, at: destinationIndexPath.row)

        // Call Rust callback
        if let movePtr = onMovePtr {
            waterui_call_move_action(movePtr, env.inner, UInt(sourceIndexPath.row), UInt(destinationIndexPath.row))
        }
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        // Show delete button in edit mode only if item is deletable
        guard onDeletePtr != nil else { return .none }
        return resolveListItemDeletable(from: contents, at: indexPath.row) ? .delete : .none
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }
}

// MARK: - WuiListCell

private final class WuiListCell: UITableViewCell {
    static let reuseIdentifier = "WuiListCell"

    private var contentWuiView: WuiAnyView?
    private var deletableWatcher: WatcherGuard?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        with view: WuiAnyView,
        deletable: WuiComputed<Bool>?,
        onDeletableChange: @escaping (WuiWatcherMetadata) -> Void
    ) {
        // Remove previous content
        contentWuiView?.removeFromSuperview()
        deletableWatcher = nil

        // Add new content
        contentWuiView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)

        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        deletableWatcher = deletable?.watch { _, metadata in
            onDeletableChange(metadata)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentWuiView?.removeFromSuperview()
        contentWuiView = nil
        deletableWatcher = nil
    }
}
#endif

#if canImport(AppKit)
private final class WuiListRowContainerView: NSView {
    private var contentWuiView: WuiAnyView?
    private var deleteButton: NSButton?
    private var deletableWatcher: WatcherGuard?

    func configure(
        with view: WuiAnyView,
        itemId: Int32,
        deletable: WuiComputed<Bool>?,
        showsDeleteControl: Bool,
        target: AnyObject?,
        action: Selector?,
        onDeletableChange: @escaping (WuiWatcherMetadata) -> Void
    ) {
        contentWuiView?.removeFromSuperview()
        deleteButton?.removeFromSuperview()
        deletableWatcher = nil

        contentWuiView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)

        if showsDeleteControl, deletable?.value ?? true {
            let button = NSButton(title: "Delete", target: target, action: action)
            button.bezelStyle = .inline
            button.identifier = NSUserInterfaceItemIdentifier(String(itemId))
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            deleteButton = button

            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),

                button.leadingAnchor.constraint(equalTo: view.trailingAnchor, constant: 8),
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                button.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        deletableWatcher = deletable?.watch { _, metadata in
            onDeletableChange(metadata)
        }
    }
}

@MainActor
final class WuiList: NSScrollView, WuiComponent, NSTableViewDataSource, NSTableViewDelegate {
    static var rawId: CWaterUI.WuiTypeId { waterui_list_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let env: WuiEnvironment
    private let contents: WuiAnyViews
    private var contentsWatcher: WatcherGuard?
    private var itemIds: [Int32] = []
    private let tableView: NSTableView

    // Edit mode state
    private var editingComputed: WuiComputed<Bool>?
    private var editingWatcher: WatcherGuard?
    private var isInEditMode: Bool = false

    // Callbacks
    private var onDeletePtr: OpaquePointer?
    private var onMovePtr: OpaquePointer?

    // Pasteboard type for drag-and-drop
    private static let dragType = NSPasteboard.PasteboardType("dev.waterui.listitem")

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiList: CWaterUI.WuiList = waterui_force_as_list(anyview)
        self.init(ffiList: ffiList, env: env)
    }

    // MARK: - Designated Init

    init(ffiList: CWaterUI.WuiList, env: WuiEnvironment) {
        self.env = env
        self.contents = WuiAnyViews(ffiList.contents)
        self.onDeletePtr = ffiList.on_delete
        self.onMovePtr = ffiList.on_move
        self.tableView = NSTableView()

        super.init(frame: .zero)

        // Configure table view to look like SwiftUI List
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        column.width = 200
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 44
        tableView.usesAutomaticRowHeights = true
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular

        // Enable drag-and-drop if move callback exists
        if onMovePtr != nil {
            tableView.registerForDraggedTypes([Self.dragType])
            tableView.draggingDestinationFeedbackStyle = .gap
        }

        // Configure scroll view
        documentView = tableView
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false

        // Setup editing state if provided
        if let editingPtr = ffiList.editing {
            editingComputed = WuiComputed<Bool>(editingPtr)
            editingWatcher = editingComputed?.watch { [weak self] newValue, _ in
                guard let self = self else { return }
                self.isInEditMode = newValue
                self.tableView.reloadData()
            }
            // Apply initial editing state
            if let isEditing = editingComputed?.value {
                isInEditMode = isEditing
            }
        }

        // Initial load + watch structural changes.
        reloadFromRust(animated: false)
        installContentsWatch()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor deinit {
        // Drop action pointers if they exist
        if let ptr = onDeletePtr {
            waterui_drop_index_action(ptr)
        }
        if let ptr = onMovePtr {
            waterui_drop_move_action(ptr)
        }
    }

    // MARK: - Item Loading

    private func installContentsWatch() {
        contentsWatcher = watchAnyViewsIds(contents) { [weak self] ids, metadata in
            guard let self else { return }
            self.applyRustUpdate(ids: ids, metadata: metadata)
        }
    }

    private func applyRustUpdate(ids: [Int32], metadata: WuiWatcherMetadata) {
        let animated = metadata.animation != nil
        updateFromRust(ids: ids, animated: animated)
    }

    private func reloadFromRust(animated: Bool) {
        updateFromRust(ids: contents.allIds(), animated: animated)
    }

    private func updateFromRust(ids: [Int32], animated: Bool) {
        let oldIds = itemIds
        let newIds = ids
        itemIds = newIds

        guard animated else {
            tableView.reloadData()
            return
        }

        let diff = newIds.difference(from: oldIds).inferringMoves()
        if diff.isEmpty {
            return
        }

        tableView.beginUpdates()
        let deletions = diff.removals
            .compactMap { change in
                guard case let .remove(offset, _, _) = change else { return nil }
                return offset
            }
            .sorted(by: >)
        let insertions = diff.insertions
            .compactMap { change in
                guard case let .insert(offset, _, _) = change else { return nil }
                return offset
            }
            .sorted(by: <)
        if !deletions.isEmpty {
            tableView.removeRows(at: IndexSet(deletions), withAnimation: .slideUp)
        }
        if !insertions.isEmpty {
            tableView.insertRows(at: IndexSet(insertions), withAnimation: .slideDown)
        }
        for change in diff {
            switch change {
            case let .remove(from, _, associatedWith: .some(to)):
                tableView.moveRow(at: from, to: to)
            default:
                break
            }
        }
        tableView.endUpdates()
    }

    // MARK: - Delete Action

    private func deleteItem(at row: Int) {
        guard row >= 0, row < itemIds.count else { return }
        guard let deletePtr = onDeletePtr else { return }
        guard resolveListItemDeletable(from: contents, at: row) else { return }

        // Remove from local array first (optimistic)
        itemIds.remove(at: row)
        tableView.removeRows(at: IndexSet(integer: row), withAnimation: .slideUp)

        // Then call Rust callback
        waterui_call_index_action(deletePtr, env.inner, UInt(row))
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenSize = screen?.frame.size ?? CGSize(width: 800, height: 600)
        let width = proposal.width.map { CGFloat($0) } ?? screenSize.width
        let height = proposal.height.map { CGFloat($0) } ?? screenSize.height
        return CGSize(width: width, height: height)
    }

    override var isFlipped: Bool { true }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return itemIds.count
    }

    // MARK: - Drag and Drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard onMovePtr != nil else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .above {
            return .move
        }
        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let items = info.draggingPasteboard.pasteboardItems,
              let item = items.first,
              let rowStr = item.string(forType: Self.dragType),
              let sourceRow = Int(rowStr) else {
            return false
        }

        var destinationRow = row
        if sourceRow < destinationRow {
            destinationRow -= 1
        }

        let movedId = itemIds.remove(at: sourceRow)
        itemIds.insert(movedId, at: destinationRow)

        // Animate the move
        tableView.moveRow(at: sourceRow, to: destinationRow)

        // Call Rust callback
        if let movePtr = onMovePtr {
            waterui_call_move_action(movePtr, env.inner, UInt(sourceRow), UInt(destinationRow))
        }

        return true
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = resolveListItem(from: contents, at: row, env: env)
        let itemId = itemIds[row]
        let containerView = WuiListRowContainerView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.configure(
            with: item.view,
            itemId: itemId,
            deletable: item.deletable,
            showsDeleteControl: isInEditMode && onDeletePtr != nil,
            target: self,
            action: #selector(deleteButtonClicked(_:))
        ) { [weak self] metadata in
            guard let self else { return }
            guard let reloadRow = self.itemIds.firstIndex(of: itemId) else { return }
            self.tableView.reloadData(
                forRowIndexes: IndexSet(integer: reloadRow),
                columnIndexes: IndexSet(integer: 0)
            )
        }
        return containerView
    }

    @objc private func deleteButtonClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = Int32(raw),
              let row = itemIds.firstIndex(of: id) else {
            return
        }
        deleteItem(at: row)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        rowView.isEmphasized = true
        return rowView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let item = resolveListItem(from: contents, at: row, env: env)
        let size = item.view.sizeThatFits(WuiProposalSize(width: Float(tableView.bounds.width), height: nil))
        return max(size.height, 44)
    }
}
#endif
