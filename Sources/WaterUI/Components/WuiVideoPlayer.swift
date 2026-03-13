// WuiVideoPlayer.swift
// Full-featured video player with native playback controls
//
// # Layout Behavior
// Video player expands to fill available space in both dimensions.
// Maintains aspect ratio using platform-native video player controls.
//
// # Platform Implementation
// - iOS/tvOS: Uses AVPlayerViewController for standard iOS controls
// - macOS: Uses AVPlayerView with inline controls
//
// # Volume Control
// The volume system uses a special encoding:
// - Positive values (> 0): Audible volume level
// - Negative values (< 0): Muted state that preserves the original volume level
// - When unmuting, the absolute value is restored

import AVFoundation
import AVKit
import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(AppKit)
private final class WuiVideoPlayerPictureInPictureDelegateProxy: NSObject, AVPlayerViewPictureInPictureDelegate {
    private let owner: Unmanaged<WuiVideoPlayer>

    init(owner: WuiVideoPlayer) {
        self.owner = Unmanaged.passUnretained(owner)
    }

    func playerViewDidStartPicture(inPicture playerView: AVPlayerView) {
        let owner = owner.takeUnretainedValue()
        MainActor.assumeIsolated {
            owner.emitPictureInPictureChanged(true)
        }
    }

    func playerViewDidStopPicture(inPicture playerView: AVPlayerView) {
        let owner = owner.takeUnretainedValue()
        MainActor.assumeIsolated {
            owner.emitPictureInPictureChanged(false)
        }
    }

    func playerView(
        _ playerView: AVPlayerView,
        failedToStartPictureInPictureWithError error: Error
    ) {
        let owner = owner.takeUnretainedValue()
        MainActor.assumeIsolated {
            owner.emitEvent(
                eventType: CWaterUI.WuiVideoEventType_Error,
                errorMessage: error.localizedDescription
            )
        }
    }
}
#endif

#if canImport(UIKit)
private final class WuiVideoPlayerViewControllerDelegateProxy: NSObject, AVPlayerViewControllerDelegate {
    private let owner: Unmanaged<WuiVideoPlayer>

    init(owner: WuiVideoPlayer) {
        self.owner = Unmanaged.passUnretained(owner)
    }

    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        let owner = owner.takeUnretainedValue()
        MainActor.assumeIsolated {
            owner.emitPictureInPictureChanged(true)
        }
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        let owner = owner.takeUnretainedValue()
        MainActor.assumeIsolated {
            owner.emitPictureInPictureChanged(false)
        }
    }

    func playerViewController(
        _ playerViewController: AVPlayerViewController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        let owner = owner.takeUnretainedValue()
        MainActor.assumeIsolated {
            owner.emitEvent(
                eventType: CWaterUI.WuiVideoEventType_Error,
                errorMessage: error.localizedDescription
            )
        }
    }
}
#endif

extension AVLayerVideoGravity {
    static func from(_ aspect: WuiAspectRatio) -> AVLayerVideoGravity {
        switch aspect {
        case WuiAspectRatio_Fit: return .resizeAspect
        case WuiAspectRatio_Fill: return .resizeAspectFill
        case WuiAspectRatio_Stretch: return .resize
        default: return .resizeAspect
        }
    }
}

@MainActor
final class WuiVideoPlayer: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_video_player_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let player: AVPlayer
    private let showControls: Bool

    #if canImport(AppKit)
    private var playerView: AVPlayerView?
    private var pictureInPictureDelegateProxy: WuiVideoPlayerPictureInPictureDelegateProxy?
    #elseif canImport(UIKit)
    private var playerViewController: AVPlayerViewController?
    private var playerViewControllerDelegateProxy: WuiVideoPlayerViewControllerDelegateProxy?
    #endif

    private var sourceComputed: WuiComputed<WuiStr>
    private var titleComputed: WuiComputed<WuiStr>
    private var artistComputed: WuiComputed<WuiStr>
    private var albumComputed: WuiComputed<WuiStr>
    private var artworkURLComputed: WuiComputed<WuiStr>
    private var durationSecondsComputed: WuiComputed<Double>
    private var hasNextBinding: WuiBinding<Bool>
    private var hasPreviousBinding: WuiBinding<Bool>
    private var volumeBinding: WuiBinding<Float>
    private var playbackRateBinding: WuiBinding<Float>
    private var preservePitchBinding: WuiBinding<Bool>
    private var onEvent: CWaterUI.WuiFn_WuiVideoEvent
    private var sourceWatcher: WatcherGuard?
    private var titleWatcher: WatcherGuard?
    private var artistWatcher: WatcherGuard?
    private var albumWatcher: WatcherGuard?
    private var artworkURLWatcher: WatcherGuard?
    private var durationSecondsWatcher: WatcherGuard?
    private var hasNextWatcher: WatcherGuard?
    private var hasPreviousWatcher: WatcherGuard?
    private var volumeWatcher: WatcherGuard?
    private var playbackRateWatcher: WatcherGuard?
    private var preservePitchWatcher: WatcherGuard?
    private var statusObserver: NSKeyValueObservation?
    private var bufferEmptyObserver: NSKeyValueObservation?
    private var likelyToKeepUpObserver: NSKeyValueObservation?
    private var currentURL: URL?
    private var isBuffering = false
    private var reportedPictureInPictureActive: Bool?
    private var requestedVolume: Float = 0.5
    private var requestedPlaybackRate: Float = 1.0
    private var preservePitch = true
    private var isDucked = false
    private var mediaSessionBridge: WuiWaterKitMediaSessionBridge?

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let ffiVideoPlayer: CWaterUI.WuiVideoPlayer = waterui_force_as_video_player(anyview)

        let sourceComputed = WuiComputed<WuiStr>(ffiVideoPlayer.source!)
        let titleComputed = WuiComputed<WuiStr>(ffiVideoPlayer.title!)
        let artistComputed = WuiComputed<WuiStr>(ffiVideoPlayer.artist!)
        let albumComputed = WuiComputed<WuiStr>(ffiVideoPlayer.album!)
        let artworkURLComputed = WuiComputed<WuiStr>(ffiVideoPlayer.artwork_url!)
        let durationSecondsComputed = WuiComputed<Double>(ffiVideoPlayer.duration_seconds!)
        let hasNextBinding = WuiBinding<Bool>(ffiVideoPlayer.has_next!)
        let hasPreviousBinding = WuiBinding<Bool>(ffiVideoPlayer.has_previous!)
        let volumeBinding = WuiBinding<Float>(ffiVideoPlayer.volume!)
        let playbackRateBinding = WuiBinding<Float>(ffiVideoPlayer.playback_rate!)
        let preservePitchBinding = WuiBinding<Bool>(ffiVideoPlayer.preserve_pitch!)
        let aspectRatio = AVLayerVideoGravity.from(ffiVideoPlayer.aspect_ratio)
        let showControls = ffiVideoPlayer.show_controls
        let onEvent = ffiVideoPlayer.on_event

        self.init(
            stretchAxis: stretchAxis,
            source: sourceComputed,
            title: titleComputed,
            artist: artistComputed,
            album: albumComputed,
            artworkURL: artworkURLComputed,
            durationSeconds: durationSecondsComputed,
            hasNext: hasNextBinding,
            hasPrevious: hasPreviousBinding,
            volume: volumeBinding,
            playbackRate: playbackRateBinding,
            preservePitch: preservePitchBinding,
            aspectRatio: aspectRatio,
            showControls: showControls,
            onEvent: onEvent
        )
    }

    init(
        stretchAxis: WuiStretchAxis,
        source: WuiComputed<WuiStr>,
        title: WuiComputed<WuiStr>,
        artist: WuiComputed<WuiStr>,
        album: WuiComputed<WuiStr>,
        artworkURL: WuiComputed<WuiStr>,
        durationSeconds: WuiComputed<Double>,
        hasNext: WuiBinding<Bool>,
        hasPrevious: WuiBinding<Bool>,
        volume: WuiBinding<Float>,
        playbackRate: WuiBinding<Float>,
        preservePitch: WuiBinding<Bool>,
        aspectRatio: AVLayerVideoGravity,
        showControls: Bool,
        onEvent: CWaterUI.WuiFn_WuiVideoEvent
    ) {
        self.stretchAxis = stretchAxis
        self.sourceComputed = source
        self.titleComputed = title
        self.artistComputed = artist
        self.albumComputed = album
        self.artworkURLComputed = artworkURL
        self.durationSecondsComputed = durationSeconds
        self.hasNextBinding = hasNext
        self.hasPreviousBinding = hasPrevious
        self.volumeBinding = volume
        self.playbackRateBinding = playbackRate
        self.preservePitchBinding = preservePitch
        self.onEvent = onEvent
        self.player = AVPlayer()
        self.showControls = showControls

        super.init(frame: .zero)

        #if canImport(AppKit)
        wantsLayer = true
        if layer == nil {
            layer = CALayer()
        }
        #endif

        configurePlayerView(aspectRatio: aspectRatio)
        updatePreservePitch(preservePitchBinding.value)
        updatePlaybackRate(playbackRateBinding.value)
        updateSource(sourceComputed.value)
        updateVolume(volumeBinding.value)
        startWatchers()
        mediaSessionBridge = WuiWaterKitMediaSessionBridge(host: self)
        emitPictureInPictureChanged(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configurePlayerView(aspectRatio: AVLayerVideoGravity) {
        #if canImport(AppKit)
        let pv = AVPlayerView()
        pv.player = player
        pv.controlsStyle = showControls ? .inline : .none
        pv.showsFullScreenToggleButton = showControls
        pv.allowsPictureInPicturePlayback = true
        pv.translatesAutoresizingMaskIntoConstraints = false

        let pictureInPictureDelegateProxy = WuiVideoPlayerPictureInPictureDelegateProxy(owner: self)
        pv.pictureInPictureDelegate = pictureInPictureDelegateProxy

        switch aspectRatio {
        case .resizeAspect:
            pv.videoGravity = .resizeAspect
        case .resizeAspectFill:
            pv.videoGravity = .resizeAspectFill
        case .resize:
            pv.videoGravity = .resize
        default:
            pv.videoGravity = .resizeAspect
        }

        addSubview(pv)
        NSLayoutConstraint.activate([
            pv.topAnchor.constraint(equalTo: topAnchor),
            pv.leadingAnchor.constraint(equalTo: leadingAnchor),
            pv.trailingAnchor.constraint(equalTo: trailingAnchor),
            pv.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let layer = pv.layer {
            applyResolvedDynamicRange(to: layer, for: self)
        }
        playerView = pv
        self.pictureInPictureDelegateProxy = pictureInPictureDelegateProxy

        #elseif canImport(UIKit)
        let pvc = AVPlayerViewController()
        pvc.player = player
        let delegateProxy = WuiVideoPlayerViewControllerDelegateProxy(owner: self)
        pvc.delegate = delegateProxy
        pvc.showsPlaybackControls = showControls
        pvc.allowsPictureInPicturePlayback = true
        pvc.canStartPictureInPictureAutomaticallyFromInline = true
        pvc.view.translatesAutoresizingMaskIntoConstraints = true
        pvc.view.insetsLayoutMarginsFromSafeArea = false
        pvc.videoGravity = aspectRatio

        addSubview(pvc.view)
        applyResolvedDynamicRange(to: pvc.view.layer, for: self)
        playerViewController = pvc
        playerViewControllerDelegateProxy = delegateProxy

        if !showControls {
            pvc.view.isUserInteractionEnabled = false
        }
        #endif

        setupEndNotification()
    }

    #if canImport(UIKit)
    override func didMoveToWindow() {
        super.didMoveToWindow()

        guard let pvc = playerViewController else { return }

        if window != nil {
            if let parentVC = findParentViewController(), pvc.parent == nil {
                parentVC.addChild(pvc)
                pvc.didMove(toParent: parentVC)
            }
        } else {
            player.pause()
            mediaSessionBridge?.playbackDidChange()

            if pvc.parent != nil {
                pvc.willMove(toParent: nil)
                pvc.removeFromParent()
            }
        }
    }

    private func findParentViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let nextResponder = responder?.next {
            if let viewController = nextResponder as? UIViewController {
                return viewController
            }
            responder = nextResponder
        }
        return nil
    }
    #endif

    private func setupEndNotification() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let defaultWidth: CGFloat = 320
        let defaultHeight: CGFloat = 180

        let width = proposal.width.map { CGFloat($0) } ?? defaultWidth
        let height = proposal.height.map { CGFloat($0) } ?? defaultHeight

        return CGSize(width: width, height: height)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        playerViewController?.view.frame = bounds
        if let layer = playerViewController?.view.layer {
            applyResolvedDynamicRange(to: layer, for: self)
        }
    }
    #elseif canImport(AppKit)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window == nil {
            player.pause()
            mediaSessionBridge?.playbackDidChange()
        }
    }

    override func layout() {
        super.layout()
        if let layer = playerView?.layer {
            applyResolvedDynamicRange(to: layer, for: self)
        }
    }

    override var isFlipped: Bool { true }

    override var wantsLayer: Bool {
        get { true }
        set { }
    }
    #endif

    @objc private func playerItemDidReachEnd(_ notification: Notification) {
        guard let playerItem = notification.object as? AVPlayerItem, playerItem == player.currentItem
        else { return }

        emitEvent(eventType: CWaterUI.WuiVideoEventType_Ended)
        mediaSessionBridge?.playbackDidChange()
        mediaSessionBridge?.metadataDidChange()
    }

    private func startWatchers() {
        sourceWatcher = sourceComputed.watch { [weak self] source, _ in
            self?.updateSource(source)
            self?.mediaSessionBridge?.metadataDidChange()
            self?.mediaSessionBridge?.playbackDidChange()
        }

        titleWatcher = titleComputed.watch { [weak self] _, _ in
            self?.mediaSessionBridge?.metadataDidChange()
        }
        artistWatcher = artistComputed.watch { [weak self] _, _ in
            self?.mediaSessionBridge?.metadataDidChange()
        }
        albumWatcher = albumComputed.watch { [weak self] _, _ in
            self?.mediaSessionBridge?.metadataDidChange()
        }
        artworkURLWatcher = artworkURLComputed.watch { [weak self] _, _ in
            self?.mediaSessionBridge?.metadataDidChange()
        }
        durationSecondsWatcher = durationSecondsComputed.watch { [weak self] _, _ in
            self?.mediaSessionBridge?.metadataDidChange()
        }
        hasNextWatcher = hasNextBinding.watch { [weak self] _, _ in
            self?.mediaSessionBridge?.playbackDidChange()
        }
        hasPreviousWatcher = hasPreviousBinding.watch { [weak self] _, _ in
            self?.mediaSessionBridge?.playbackDidChange()
        }
        volumeWatcher = volumeBinding.watch { [weak self] volume, _ in
            self?.updateVolume(volume)
        }
        playbackRateWatcher = playbackRateBinding.watch { [weak self] rate, _ in
            self?.updatePlaybackRate(rate)
        }
        preservePitchWatcher = preservePitchBinding.watch { [weak self] preservePitch, _ in
            self?.updatePreservePitch(preservePitch)
        }
    }

    private func updateSource(_ source: WuiStr) {
        let urlString = source.toString()

        guard let url = URL(string: urlString) else {
            currentURL = nil
            player.pause()
            player.replaceCurrentItem(with: nil)
            emitEvent(
                eventType: CWaterUI.WuiVideoEventType_Error,
                errorMessage: "Invalid video URL"
            )
            mediaSessionBridge?.metadataDidChange()
            mediaSessionBridge?.playbackDidChange()
            return
        }

        guard url != currentURL else {
            return
        }
        currentURL = url
        isBuffering = false

        let playerItem = AVPlayerItem(url: url)
        applyPitchAlgorithm(to: playerItem)

        statusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch item.status {
                case .failed:
                    let errorMessage = item.error?.localizedDescription
                        ?? "Failed to load video. Check network access and sandbox permissions."
                    self.emitEvent(
                        eventType: CWaterUI.WuiVideoEventType_Error,
                        errorMessage: errorMessage
                    )
                case .readyToPlay:
                    self.emitEvent(eventType: CWaterUI.WuiVideoEventType_ReadyToPlay)
                    self.mediaSessionBridge?.metadataDidChange()
                    self.mediaSessionBridge?.playbackDidChange()
                case .unknown:
                    break
                @unknown default:
                    fatalError("Unsupported AVPlayerItem status")
                }
            }
        }

        bufferEmptyObserver = playerItem.observe(\.isPlaybackBufferEmpty, options: [.new]) {
            [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if item.isPlaybackBufferEmpty && !self.isBuffering {
                    self.isBuffering = true
                    self.emitEvent(eventType: CWaterUI.WuiVideoEventType_Buffering)
                    self.mediaSessionBridge?.playbackDidChange()
                }
            }
        }

        likelyToKeepUpObserver = playerItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) {
            [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if item.isPlaybackLikelyToKeepUp && self.isBuffering {
                    self.isBuffering = false
                    self.emitEvent(eventType: CWaterUI.WuiVideoEventType_BufferingEnded)
                    self.mediaSessionBridge?.playbackDidChange()
                }
            }
        }

        player.replaceCurrentItem(with: playerItem)
        updatePlaybackRate(playbackRateBinding.value)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.mediaSessionPlay()
        }
    }

    private func updateVolume(_ volume: Float) {
        requestedVolume = volume
        applyEffectiveVolume()
    }

    private func applyEffectiveVolume() {
        let baseVolume = abs(requestedVolume)
        player.isMuted = requestedVolume < 0
        player.volume = isDucked ? (baseVolume * 0.2) : baseVolume
        mediaSessionBridge?.playbackDidChange()
    }

    private func updatePlaybackRate(_ rate: Float) {
        precondition(rate.isFinite && rate > 0, "video playback rate must be finite and positive")
        requestedPlaybackRate = rate
        if currentMediaPlaybackSnapshot.status == .playing {
            player.rate = requestedPlaybackRate
        }
        mediaSessionBridge?.playbackDidChange()
    }

    private func updatePreservePitch(_ enabled: Bool) {
        preservePitch = enabled
        applyPitchAlgorithm(to: player.currentItem)
    }

    private func applyPitchAlgorithm(to item: AVPlayerItem?) {
        guard let item else { return }
        item.audioTimePitchAlgorithm = preservePitch ? .spectral : .varispeed
    }

    private func resolvedDurationSeconds() -> Double {
        let configuredDuration = durationSecondsComputed.value
        if configuredDuration >= 0 {
            return configuredDuration
        }

        let actualDuration = player.currentItem?.duration.seconds ?? -1
        if actualDuration.isFinite && actualDuration >= 0 {
            return actualDuration
        }
        return -1
    }

    fileprivate func emitEvent(
        eventType: CWaterUI.WuiVideoEventType,
        errorMessage: String = "",
        bufferedMs: UInt32 = 0,
        avDriftMs: Float = 0,
        droppedVideoFrames: UInt64 = 0,
        pictureInPictureActive: Bool = false
    ) {
        let event = CWaterUI.WuiVideoEvent(
            event_type: eventType,
            error_message: WuiStr(string: errorMessage).intoInner(),
            buffered_ms: bufferedMs,
            av_drift_ms: avDriftMs,
            dropped_video_frames: droppedVideoFrames,
            picture_in_picture_active: pictureInPictureActive
        )
        onEvent.call(onEvent.data, event)
    }

    fileprivate func emitPictureInPictureChanged(_ active: Bool) {
        guard reportedPictureInPictureActive != active else {
            return
        }
        reportedPictureInPictureActive = active
        emitEvent(
            eventType: CWaterUI.WuiVideoEventType_PictureInPictureChanged,
            pictureInPictureActive: active
        )
    }

    deinit {
        MainActor.assumeIsolated {
            mediaSessionBridge = nil
            NotificationCenter.default.removeObserver(self)
            sourceWatcher = nil
            titleWatcher = nil
            artistWatcher = nil
            albumWatcher = nil
            artworkURLWatcher = nil
            durationSecondsWatcher = nil
            hasNextWatcher = nil
            hasPreviousWatcher = nil
            volumeWatcher = nil
            playbackRateWatcher = nil
            preservePitchWatcher = nil
            statusObserver?.invalidate()
            bufferEmptyObserver?.invalidate()
            likelyToKeepUpObserver?.invalidate()
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }
}

@MainActor
extension WuiVideoPlayer: WuiMediaSessionHost {
    var currentMediaMetadataSnapshot: WuiMediaMetadataSnapshot {
        let currentURL = self.currentURL
        let fallbackTitle = currentURL?.lastPathComponent.isEmpty == false
            ? currentURL?.lastPathComponent ?? ""
            : currentURL?.absoluteString ?? ""
        let configuredTitle = titleComputed.value.toString()

        return WuiMediaMetadataSnapshot(
            title: configuredTitle.isEmpty ? fallbackTitle : configuredTitle,
            artist: artistComputed.value.toString(),
            album: albumComputed.value.toString(),
            artworkURL: artworkURLComputed.value.toString(),
            durationSeconds: resolvedDurationSeconds()
        )
    }

    var currentMediaPlaybackSnapshot: WuiMediaPlaybackSnapshot {
        let status: WuiMediaPlaybackStatus
        if player.currentItem == nil {
            status = .stopped
        } else {
            switch player.timeControlStatus {
            case .paused:
                status = .paused
            case .waitingToPlayAtSpecifiedRate, .playing:
                status = .playing
            @unknown default:
                fatalError("Unsupported AVPlayer time control status")
            }
        }

        let positionSeconds = max(0, player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0)
        let playbackRate = status == .playing ? Double(requestedPlaybackRate) : 0.0

        return WuiMediaPlaybackSnapshot(
            status: status,
            positionSeconds: positionSeconds,
            rate: playbackRate,
            nextEnabled: hasNextBinding.value,
            previousEnabled: hasPreviousBinding.value
        )
    }

    func mediaSessionPlay() {
        guard player.currentItem != nil else { return }
        player.play()
        player.rate = requestedPlaybackRate
        mediaSessionBridge?.playbackDidChange()
    }

    func mediaSessionPause() {
        player.pause()
        mediaSessionBridge?.playbackDidChange()
    }

    func mediaSessionStop() {
        player.pause()
        player.seek(to: .zero)
        mediaSessionBridge?.playbackDidChange()
    }

    func mediaSessionSeek(to seconds: Double) {
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        mediaSessionBridge?.playbackDidChange()
    }

    func mediaSessionSetDucked(_ ducked: Bool) {
        isDucked = ducked
        applyEffectiveVolume()
    }

    func mediaSessionEmitNextRequested() {
        emitEvent(eventType: CWaterUI.WuiVideoEventType_NextRequested)
    }

    func mediaSessionEmitPreviousRequested() {
        emitEvent(eventType: CWaterUI.WuiVideoEventType_PreviousRequested)
    }
}
