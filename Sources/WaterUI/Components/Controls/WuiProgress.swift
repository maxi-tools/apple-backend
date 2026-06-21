// WuiProgress.swift
// Progress indicator component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// Linear progress expands horizontally to fill available width (fixed height).
// Circular progress is content-sized (fixed spinner dimensions).
// Use frame modifiers to constrain size if needed.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .horizontal for linear, .none for circular
// // - sizeThatFits: Linear returns proposed width (min 50pt); Circular returns spinner size
// // - Priority: 0 (default)

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiProgress: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_progress_id() }

    private(set) var stretchAxis: WuiStretchAxis

    #if canImport(UIKit)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    #elseif canImport(AppKit)
    private let progressIndicator = NSProgressIndicator()
    #endif
    private let circularTrackLayer = CAShapeLayer()
    private let circularProgressLayer = CAShapeLayer()
    private var watcher: WatcherGuard?
    private var foregroundWatcher: WatcherGuard?
    private var foreground: WuiComputed<WuiResolvedColor>?

    private var labelView: WuiAnyView
    private var value: WuiComputed<Double>
    private var style: WuiProgressStyle
    private var currentValue: Double = 0.0

    // Layout constants
    private let verticalSpacing: CGFloat = 6.0

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let ffiProgress: CWaterUI.WuiProgress = waterui_force_as_progress(anyview)
        let labelView = WuiAnyView(anyview: ffiProgress.label, env: env)
        let value = WuiComputed<Double>(ffiProgress.value)
        self.init(stretchAxis: stretchAxis, label: labelView, value: value, style: ffiProgress.style, env: env)
    }

    // MARK: - Designated Init

    init(
        stretchAxis: WuiStretchAxis,
        label: WuiAnyView,
        value: WuiComputed<Double>,
        style: WuiProgressStyle,
        env: WuiEnvironment? = nil
    ) {
        self.stretchAxis = stretchAxis
        self.labelView = label
        self.value = value
        self.style = style
        self.currentValue = value.value
        super.init(frame: .zero)
        configureSubviews()
        if let env {
            installForeground(env)
        }
        updateLabel(label, force: true)
        updateStyle(style)
        updateValueSource(value, force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // Per LAYOUT_SPEC.md:
        // - Linear ProgressView: axis-expanding (width expands, height intrinsic)
        // - Circular ProgressView: fills the proposed square when available

        let isCircular = style == WuiProgressStyle_Circular

        if isCircular {
            let fallback: CGFloat = 20
            let proposedWidth = proposal.width.map { CGFloat($0) }
            let proposedHeight = proposal.height.map { CGFloat($0) }
            let side = min(proposedWidth ?? proposedHeight ?? fallback, proposedHeight ?? proposedWidth ?? fallback)
            return CGSize(width: side, height: side)
        }

        // Linear progress: axis-expanding on width per LAYOUT_SPEC.md
        // It uses isStretch: true to expand, so here we report MINIMUM usable size
        let labelSize = labelView.sizeThatFits(WuiProposalSize())

        #if canImport(UIKit)
        let progressHeight = progressView.intrinsicContentSize.height
        #elseif canImport(AppKit)
        let progressHeight = progressIndicator.intrinsicContentSize.height
        #endif

        // Intrinsic height: label height + spacing + progress bar height
        let intrinsicHeight = labelSize.height + verticalSpacing + progressHeight

        // For width: report MINIMUM usable size
        // The minimum width ensures label fits and progress bar is visible
        let minProgressWidth: CGFloat = 50.0
        let minWidth = max(labelSize.width, minProgressWidth)

        // When width is proposed, use it (but not less than minimum)
        // When None, return minimum - isStretch:true will expand it to fill remaining space
        let width = proposal.width.map { max(CGFloat($0), minWidth) } ?? minWidth
        let height = proposal.height.map { CGFloat($0) } ?? intrinsicHeight

        return CGSize(width: width, height: max(height, intrinsicHeight))
    }

    // MARK: - Layout

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        performLayout()
    }
    #elseif canImport(AppKit)
    override func layout() {
        super.layout()
        performLayout()
    }

    override var isFlipped: Bool { true }
    #endif

    /// Shared layout logic for both UIKit and AppKit
    private func performLayout() {
        let boundsWidth = bounds.width
        let boundsHeight = bounds.height

        let isCircular = style == WuiProgressStyle_Circular

        if isCircular {
            let side = min(boundsWidth, boundsHeight)
            let ringFrame = CGRect(
                x: (boundsWidth - side) / 2,
                y: (boundsHeight - side) / 2,
                width: side,
                height: side
            )
            #if canImport(UIKit)
            let spinnerSize = activityIndicator.intrinsicContentSize
            activityIndicator.frame = CGRect(
                x: currentValue.isInfinite ? (boundsWidth - spinnerSize.width) / 2 : ringFrame.minX,
                y: currentValue.isInfinite ? (boundsHeight - spinnerSize.height) / 2 : ringFrame.minY,
                width: currentValue.isInfinite ? spinnerSize.width : ringFrame.width,
                height: currentValue.isInfinite ? spinnerSize.height : ringFrame.height
            )
            progressView.frame = .zero
            labelView.frame = .zero
            #elseif canImport(AppKit)
            let spinnerSize = CGSize(width: 20, height: 20)
            progressIndicator.frame = CGRect(
                x: currentValue.isInfinite ? (boundsWidth - spinnerSize.width) / 2 : 0,
                y: currentValue.isInfinite ? (boundsHeight - spinnerSize.height) / 2 : 0,
                width: currentValue.isInfinite ? spinnerSize.width : 0,
                height: currentValue.isInfinite ? spinnerSize.height : 0
            )
            labelView.frame = .zero
            #endif
            layoutCircularLayers(in: ringFrame)
            return
        }

        circularTrackLayer.isHidden = true
        circularProgressLayer.isHidden = true

        // Linear progress: label at top, progress bar below
        let labelSize = labelView.sizeThatFits(WuiProposalSize())

        #if canImport(UIKit)
        let progressHeight = progressView.intrinsicContentSize.height
        #elseif canImport(AppKit)
        let progressHeight = progressIndicator.intrinsicContentSize.height
        #endif

        // Layout label at top
        labelView.frame = CGRect(
            x: 0,
            y: 0,
            width: labelSize.width,
            height: labelSize.height
        )

        // Layout progress bar below label
        let progressY = labelSize.height + verticalSpacing
        #if canImport(UIKit)
        progressView.frame = CGRect(
            x: 0,
            y: progressY,
            width: boundsWidth,
            height: progressHeight
        )
        activityIndicator.frame = .zero
        #elseif canImport(AppKit)
        progressIndicator.frame = CGRect(
            x: 0,
            y: progressY,
            width: boundsWidth,
            height: progressHeight
        )
        #endif
    }

    // MARK: - Update Methods

    func updateLabel(_ newLabel: WuiAnyView, force: Bool = false) {
        guard force || newLabel !== labelView else { return }
        labelView.removeFromSuperview()
        labelView = newLabel
        addSubview(newLabel)
        setNeedsLayoutCompat()
    }

    func updateValueSource(_ newValue: WuiComputed<Double>, force: Bool = false) {
        guard force || newValue !== value else { return }
        watcher = nil
        value = newValue
        updateAppearance(for: newValue.value)
        startWatcher()
    }

    func updateStyle(_ newStyle: WuiProgressStyle) {
        style = newStyle
        updateAppearance(for: value.value)
        setNeedsLayoutCompat()
    }

    // MARK: - Configuration

    private func configureSubviews() {
        // Manual frame layout - just add subviews, performLayout() will position them
        addSubview(labelView)
        configureCircularLayers()

        #if canImport(UIKit)
        activityIndicator.hidesWhenStopped = true
        addSubview(progressView)
        addSubview(activityIndicator)
        #elseif canImport(AppKit)
        addSubview(progressIndicator)
        #endif
    }

    private func startWatcher() {
        watcher = value.watch { [weak self] newValue, metadata in
            guard let self else { return }
            withPlatformAnimation(metadata) {
                self.updateAppearance(for: newValue)
            }
        }
    }

    private func setNeedsLayoutCompat() {
        #if canImport(UIKit)
        setNeedsLayout()
        #elseif canImport(AppKit)
        needsLayout = true
        #endif
    }

    private func installForeground(_ env: WuiEnvironment) {
        guard let computedPtr = waterui_theme_color(env.inner, WuiColorSlot_Foreground) else { return }
        let computed = WuiComputed<WuiResolvedColor>(computedPtr)
        foreground = computed
        foregroundWatcher = computed.watch { [weak self] color, _ in
            self?.applyCircularColor(color)
        }
        applyCircularColor(computed.value)
    }

    private func configureCircularLayers() {
        for layer in [circularTrackLayer, circularProgressLayer] {
            layer.fillColor = nil
            layer.lineCap = .round
            layer.isHidden = true
        }
        circularTrackLayer.opacity = 0.18
        circularProgressLayer.strokeEnd = 0.0

        #if canImport(UIKit)
        layer.addSublayer(circularTrackLayer)
        layer.addSublayer(circularProgressLayer)
        #elseif canImport(AppKit)
        wantsLayer = true
        layer?.addSublayer(circularTrackLayer)
        layer?.addSublayer(circularProgressLayer)
        #endif
    }

    private func layoutCircularLayers(in frame: CGRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        let lineWidth = max(4.0, min(frame.width, frame.height) * 0.08)
        let radius = max(0.0, (min(frame.width, frame.height) - lineWidth) / 2)
        let path = CGMutablePath()
        path.addArc(
            center: CGPoint(x: frame.midX, y: frame.midY),
            radius: radius,
            startAngle: -CGFloat.pi / 2,
            endAngle: CGFloat.pi * 3 / 2,
            clockwise: false
        )

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circularTrackLayer.frame = bounds
        circularProgressLayer.frame = bounds
        circularTrackLayer.path = path
        circularProgressLayer.path = path
        circularTrackLayer.lineWidth = lineWidth
        circularProgressLayer.lineWidth = lineWidth
        CATransaction.commit()
    }

    private func applyCircularColor(_ color: WuiResolvedColor) {
        #if canImport(UIKit)
        let cgColor = color.toUIColor().cgColor
        #elseif canImport(AppKit)
        let cgColor = color.toNSColor().cgColor
        #endif
        circularTrackLayer.strokeColor = cgColor
        circularProgressLayer.strokeColor = cgColor
    }

    private func setCircularProgress(_ value: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        circularProgressLayer.strokeEnd = CGFloat(min(max(value, 0.0), 1.0))
        CATransaction.commit()
    }

    private func updateAppearance(for value: Double) {
        currentValue = value
        let isCircular = style == WuiProgressStyle_Circular
        let isIndeterminate = value.isInfinite

        if isCircular && !isIndeterminate {
            circularTrackLayer.isHidden = false
            circularProgressLayer.isHidden = false
            setCircularProgress(value)

            #if canImport(UIKit)
            activityIndicator.stopAnimating()
            activityIndicator.isHidden = true
            progressView.isHidden = true
            #elseif canImport(AppKit)
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            #endif
            setNeedsLayoutCompat()
            return
        }

        circularTrackLayer.isHidden = true
        circularProgressLayer.isHidden = true

        #if canImport(UIKit)
        if isIndeterminate {
            progressView.isHidden = true
            activityIndicator.isHidden = false
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
            activityIndicator.isHidden = true
            progressView.isHidden = false
            let clamped = Float(min(max(value, 0.0), 1.0))
            progressView.progress = clamped
        }
        #elseif canImport(AppKit)
        if isIndeterminate {
            progressIndicator.isHidden = false
            progressIndicator.style = .spinning
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.isHidden = false
            progressIndicator.stopAnimation(nil)
            progressIndicator.style = .bar
            progressIndicator.isIndeterminate = false
            progressIndicator.minValue = 0.0
            progressIndicator.maxValue = 1.0
            let clamped = min(max(value, 0.0), 1.0)
            progressIndicator.doubleValue = clamped
        }
        #endif
        setNeedsLayoutCompat()
    }
}
