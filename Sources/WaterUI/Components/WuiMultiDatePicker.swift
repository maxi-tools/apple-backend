import CWaterUI
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private struct WuiDateRangeFFI {
    var start: CWaterUI.WuiDate
    var end: CWaterUI.WuiDate
}

private struct WuiMultiDatePickerFFI {
    var label: OpaquePointer?
    var value: OpaquePointer?
    var range: WuiDateRangeFFI
    var decorated: OpaquePointer?
}

@_silgen_name("waterui_multi_date_picker_id")
private func waterui_multi_date_picker_id() -> CWaterUI.WuiTypeId
@_silgen_name("waterui_force_as_multi_date_picker")
private func waterui_force_as_multi_date_picker(_ view: OpaquePointer) -> WuiMultiDatePickerFFI
@_silgen_name("waterui_read_binding_date_vec")
private func waterui_read_binding_date_vec(_ binding: OpaquePointer?) -> CWaterUI.WuiArray
@_silgen_name("waterui_watch_binding_date_vec")
private func waterui_watch_binding_date_vec(
    _ binding: OpaquePointer?,
    _ watcher: OpaquePointer?
) -> OpaquePointer?
@_silgen_name("waterui_set_binding_date_vec")
private func waterui_set_binding_date_vec(_ binding: OpaquePointer?, _ value: CWaterUI.WuiArray)
@_silgen_name("waterui_drop_binding_date_vec")
private func waterui_drop_binding_date_vec(_ binding: OpaquePointer?)
@_silgen_name("waterui_read_computed_date_vec")
private func waterui_read_computed_date_vec(_ computed: OpaquePointer?) -> CWaterUI.WuiArray
@_silgen_name("waterui_watch_computed_date_vec")
private func waterui_watch_computed_date_vec(
    _ computed: OpaquePointer?,
    _ watcher: OpaquePointer?
) -> OpaquePointer?
@_silgen_name("waterui_drop_computed_date_vec")
private func waterui_drop_computed_date_vec(_ computed: OpaquePointer?)
@_silgen_name("waterui_new_watcher_date_vec")
private func waterui_new_watcher_date_vec(
    _ data: UnsafeMutableRawPointer?,
    _ call: (@convention(c) (UnsafeMutableRawPointer?, CWaterUI.WuiArray, OpaquePointer?) -> Void)?,
    _ drop: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?
) -> OpaquePointer?

@MainActor
final class WuiMultiDatePicker: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_multi_date_picker_id() }

    private let labelView: WuiAnyView
    private let binding: WuiBinding<CWaterUI.WuiArray>
    private let decorated: WuiComputed<CWaterUI.WuiArray>
    private let range: WuiDateRangeFFI
    private let calendar = Calendar(identifier: .gregorian)
    private var bindingWatcher: WatcherGuard?
    private var decoratedWatcher: WatcherGuard?

    #if canImport(UIKit)
    private let picker = UIDatePicker()
    private let toggleButton = UIButton(type: .system)
    private let selectionList = UIStackView()
    private var calendarView: UICalendarView?
    private var calendarSelection: UICalendarSelectionMultiDate?
    private var calendarDelegate: UIKitMultiDateCoordinator?
    private var isSyncingCalendarSelection = false
    #elseif canImport(AppKit)
    private let picker = NSDatePicker()
    private let toggleButton = NSButton(title: "", target: nil, action: nil)
    private let selectionList = NSStackView()
    #endif

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiPicker = waterui_force_as_multi_date_picker(anyview)
        self.init(
            label: WuiAnyView(anyview: ffiPicker.label!, env: env),
            binding: makeDateArrayBinding(ffiPicker.value!),
            decorated: makeDateArrayComputed(ffiPicker.decorated!),
            range: ffiPicker.range
        )
    }

    private init(
        label: WuiAnyView,
        binding: WuiBinding<CWaterUI.WuiArray>,
        decorated: WuiComputed<CWaterUI.WuiArray>,
        range: WuiDateRangeFFI
    ) {
        self.labelView = label
        self.binding = binding
        self.decorated = decorated
        self.range = range
        super.init(frame: .zero)
        configureSubviews()
        syncFromModel()
        startObservers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        #if canImport(UIKit)
        systemLayoutSizeFitting(
            CGSize(
                width: proposal.width.map { $0.isFinite ? CGFloat($0) : UIView.noIntrinsicMetric }
                    ?? UIView.noIntrinsicMetric,
                height: proposal.height.map { $0.isFinite ? CGFloat($0) : UIView.noIntrinsicMetric }
                    ?? UIView.noIntrinsicMetric
            )
        )
        #elseif canImport(AppKit)
        fittingSize
        #endif
    }

    private func configureSubviews() {
        #if canImport(UIKit)
        let root = UIStackView(arrangedSubviews: [labelView])
        root.axis = .vertical
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 16.0, *) {
            let calendarView = UICalendarView()
            calendarView.availableDateRange = DateInterval(
                start: toDate(range.start),
                end: toDate(range.end)
            )
            let coordinator = UIKitMultiDateCoordinator(owner: self)
            calendarView.delegate = coordinator
            let selection = UICalendarSelectionMultiDate(delegate: coordinator)
            calendarView.selectionBehavior = selection
            self.calendarView = calendarView
            self.calendarSelection = selection
            self.calendarDelegate = coordinator
            root.addArrangedSubview(calendarView)
        } else {
            selectionList.axis = .vertical
            selectionList.spacing = 4
            picker.datePickerMode = .date
            picker.minimumDate = toDate(range.start)
            picker.maximumDate = toDate(range.end)
            picker.preferredDatePickerStyle = .inline
            picker.addTarget(self, action: #selector(toggleCurrentDate), for: .valueChanged)
            toggleButton.addTarget(self, action: #selector(toggleCurrentDate), for: .touchUpInside)
            root.addArrangedSubview(picker)
            root.addArrangedSubview(toggleButton)
            root.addArrangedSubview(selectionList)
        }
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        #elseif canImport(AppKit)
        let root = NSStackView(views: [labelView, picker, toggleButton, selectionList])
        root.orientation = .vertical
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        selectionList.orientation = .vertical
        selectionList.spacing = 4
        picker.datePickerElements = .yearMonthDay
        picker.minDate = toDate(range.start)
        picker.maxDate = toDate(range.end)
        picker.target = self
        picker.action = #selector(toggleCurrentDate)
        toggleButton.target = self
        toggleButton.action = #selector(toggleCurrentDate)
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        #endif
    }

    private func startObservers() {
        bindingWatcher = binding.watch { [weak self] (_: CWaterUI.WuiArray, _: WuiWatcherMetadata) in
            self?.syncFromModel()
        }
        decoratedWatcher = decorated.watch { [weak self] (_: CWaterUI.WuiArray, _: WuiWatcherMetadata) in
            self?.syncFromModel()
        }
    }

    private func selectedDates() -> [CWaterUI.WuiDate] {
        WuiArray<CWaterUI.WuiDate>(c: binding.value).toArray()
    }

    private func decoratedDates() -> [CWaterUI.WuiDate] {
        WuiArray<CWaterUI.WuiDate>(c: decorated.value).toArray()
    }

    private func syncFromModel() {
        let selected = selectedDates()
        let decorated = decoratedDates()
        let decoratedKeys = Set(decorated.map(dateKey))
        let current = selected.first ?? range.start
        #if canImport(UIKit)
        if #available(iOS 16.0, *), let calendarView, let selectionBehavior = calendarSelection {
            let selectedComponents = selected.map(dateComponents)
            let decoratedComponents = decorated.map(dateComponents)
            isSyncingCalendarSelection = true
            selectionBehavior.selectedDates = selectedComponents
            calendarView.reloadDecorations(forDateComponents: selectedComponents, animated: false)
            calendarView.reloadDecorations(forDateComponents: decoratedComponents, animated: false)
            isSyncingCalendarSelection = false
        } else {
            picker.date = toDate(current)
            toggleButton.setTitle(buttonTitle(for: current, selected: selected), for: .normal)
            selectionList.arrangedSubviews.forEach { view in
                selectionList.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for date in selected {
                let label = UILabel()
                label.text = formatted(date, decorated: decoratedKeys.contains(dateKey(date)))
                selectionList.addArrangedSubview(label)
            }
        }
        #elseif canImport(AppKit)
        picker.dateValue = toDate(current)
        toggleButton.title = buttonTitle(for: current, selected: selected)
        selectionList.arrangedSubviews.forEach { view in
            selectionList.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for date in selected {
            let label = NSTextField(
                labelWithString: formatted(date, decorated: decoratedKeys.contains(dateKey(date)))
            )
            selectionList.addArrangedSubview(label)
        }
        #endif
    }

    @objc private func toggleCurrentDate() {
        let current = currentDate()
        applySelectionToggle(current)
    }

    private func applySelectionToggle(_ current: CWaterUI.WuiDate) {
        var selected = selectedDates()
        if let index = selected.firstIndex(where: { dateKey($0) == dateKey(current) }) {
            selected.remove(at: index)
        } else {
            selected.append(current)
            selected.sort { lhs, rhs in
                dateKey(lhs) < dateKey(rhs)
            }
        }
        binding.set(WuiArray(array: selected).intoInner())
        syncFromModel()
    }

    private func currentDate() -> CWaterUI.WuiDate {
        let components = calendar.dateComponents([.year, .month, .day], from: pickerDate())
        return CWaterUI.WuiDate(
            year: Int32(components.year ?? 2000),
            month: UInt8(components.month ?? 1),
            day: UInt8(components.day ?? 1)
        )
    }

    private func buttonTitle(for current: CWaterUI.WuiDate, selected: [CWaterUI.WuiDate]) -> String {
        selected.contains { dateKey($0) == dateKey(current) } ? "Remove Date" : "Add Date"
    }

    private func formatted(_ date: CWaterUI.WuiDate, decorated: Bool) -> String {
        let suffix = decorated ? " •" : ""
        return "\(date.year)-\(String(format: "%02d", date.month))-\(String(format: "%02d", date.day))\(suffix)"
    }

    private func dateKey(_ date: CWaterUI.WuiDate) -> String {
        "\(date.year)-\(date.month)-\(date.day)"
    }

    #if canImport(UIKit)
    private func dateComponents(_ date: CWaterUI.WuiDate) -> DateComponents {
        DateComponents(year: Int(date.year), month: Int(date.month), day: Int(date.day))
    }

    @available(iOS 16.0, *)
    fileprivate func canToggle(_ components: DateComponents) -> Bool {
        guard let date = dateFromComponents(components) else {
            return false
        }
        let currentDate = toDate(date)
        return currentDate >= toDate(range.start) && currentDate <= toDate(range.end)
    }

    @available(iOS 16.0, *)
    fileprivate func toggleFromCalendar(_ components: DateComponents) {
        guard !isSyncingCalendarSelection, let date = dateFromComponents(components) else {
            return
        }
        applySelectionToggle(date)
    }

    @available(iOS 16.0, *)
    fileprivate func decoration(for components: DateComponents) -> UICalendarView.Decoration? {
        guard let date = dateFromComponents(components),
              Set(decoratedDates().map(dateKey)).contains(dateKey(date))
        else {
            return nil
        }
        return .default(color: .secondaryLabel, size: .small)
    }
    #endif

    private func dateFromComponents(_ components: DateComponents) -> CWaterUI.WuiDate? {
        guard let year = components.year,
              let month = components.month,
              let day = components.day
        else {
            return nil
        }
        return CWaterUI.WuiDate(year: Int32(year), month: UInt8(month), day: UInt8(day))
    }

    private func toDate(_ date: CWaterUI.WuiDate) -> Date {
        var components = DateComponents()
        components.year = Int(date.year)
        components.month = Int(date.month)
        components.day = Int(date.day)
        return calendar.date(from: components) ?? Date()
    }

    private func pickerDate() -> Date {
        #if canImport(UIKit)
        picker.date
        #elseif canImport(AppKit)
        picker.dateValue
        #endif
    }
}

#if canImport(UIKit)
@available(iOS 16.0, *)
private final class UIKitMultiDateCoordinator: NSObject, UICalendarSelectionMultiDateDelegate, UICalendarViewDelegate {
    private unowned let owner: WuiMultiDatePicker

    init(owner: WuiMultiDatePicker) {
        self.owner = owner
    }

    func multiDateSelection(_ selection: UICalendarSelectionMultiDate, canSelectDate dateComponents: DateComponents) -> Bool {
        owner.canToggle(dateComponents)
    }

    func multiDateSelection(_ selection: UICalendarSelectionMultiDate, canDeselectDate dateComponents: DateComponents) -> Bool {
        owner.canToggle(dateComponents)
    }

    func multiDateSelection(_ selection: UICalendarSelectionMultiDate, didSelectDate dateComponents: DateComponents) {
        owner.toggleFromCalendar(dateComponents)
    }

    func multiDateSelection(_ selection: UICalendarSelectionMultiDate, didDeselectDate dateComponents: DateComponents) {
        owner.toggleFromCalendar(dateComponents)
    }

    func calendarView(_ calendarView: UICalendarView, decorationFor dateComponents: DateComponents) -> UICalendarView.Decoration? {
        owner.decoration(for: dateComponents)
    }
}
#endif

@MainActor
private func makeDateArrayBinding(_ inner: OpaquePointer) -> WuiBinding<CWaterUI.WuiArray> {
    WuiBinding<CWaterUI.WuiArray>(
        inner: inner,
        read: waterui_read_binding_date_vec,
        watch: { inner, f in
            let g = waterui_watch_binding_date_vec(inner, makeDateArrayWatcher(f))
            return WatcherGuard(g!)
        },
        set: waterui_set_binding_date_vec,
        drop: waterui_drop_binding_date_vec
    )
}

@MainActor
private func makeDateArrayComputed(_ inner: OpaquePointer) -> WuiComputed<CWaterUI.WuiArray> {
    WuiComputed<CWaterUI.WuiArray>(
        inner: inner,
        read: waterui_read_computed_date_vec,
        watch: { inner, f in
            let g = waterui_watch_computed_date_vec(inner, makeDateArrayWatcher(f))
            return WatcherGuard(g!)
        },
        drop: waterui_drop_computed_date_vec
    )
}

@MainActor
private func makeDateArrayWatcher(
    _ f: @escaping (CWaterUI.WuiArray, WuiWatcherMetadata) -> Void
) -> OpaquePointer {
    let data = wrap(f)
    let call: @convention(c) (UnsafeMutableRawPointer?, CWaterUI.WuiArray, OpaquePointer?) -> Void = {
        data, value, metadata in
        callWrapper(data, value, metadata)
    }
    let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
        dropWrapper($0, CWaterUI.WuiArray.self)
    }
    guard let watcher = waterui_new_watcher_date_vec(data, call, drop) else {
        fatalError("Failed to create date array watcher")
    }
    return watcher
}
