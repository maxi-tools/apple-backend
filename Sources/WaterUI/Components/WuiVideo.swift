// WuiVideo.swift
// Raw video view without native controls - uses AVPlayerLayer directly
//
// # Layout Behavior
// Video view expands based on aspect ratio setting.
// Uses AVPlayerLayer for direct video rendering without controls.
//
// # Volume Control
// The volume system uses a special encoding:
// - Positive values (> 0): Audible volume level
// - Negative values (< 0): Muted state that preserves the original volume level
// - When unmuting, the absolute value is restored

import AVFoundation
import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiVideo: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_video_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let player: AVPlayer
    private let playerLayer: AVPlayerLayer
    private let loops: Bool

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
    private var requestedVolume: Float = 0.5
    private var requestedPlaybackRate: Float = 1.0
    private var preservePitch = true
    private var isDucked = false
    private var playbackShouldStartWhenReady = false
    private var mediaSessionBridge: WuiWaterKitMediaSessionBridge?

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let ffiVideo: CWaterUI.WuiVideo = waterui_force_as_video(anyview)

        let sourceComputed = WuiComputed<WuiStr>(ffiVideo.source!)
        let titleComputed = WuiComputed<WuiStr>(ffiVideo.title!)
        let artistComputed = WuiComputed<WuiStr>(ffiVideo.artist!)
        let albumComputed = WuiComputed<WuiStr>(ffiVideo.album!)
        let artworkURLComputed = WuiComputed<WuiStr>(ffiVideo.artwork_url!)
        let durationSecondsComputed = WuiComputed<Double>(ffiVideo.duration_seconds!)
        let hasNextBinding = WuiBinding<Bool>(ffiVideo.has_next!)
        let hasPreviousBinding = WuiBinding<Bool>(ffiVideo.has_previous!)
        let volumeBinding = WuiBinding<Float>(ffiVideo.volume!)
        let playbackRateBinding = WuiBinding<Float>(ffiVideo.playback_rate!)
        let preservePitchBinding = WuiBinding<Bool>(ffiVideo.preserve_pitch!)
        let aspectRatio = AVLayerVideoGravity.from(ffiVideo.aspect_ratio)
        let loops = ffiVideo.loops
        let onEvent = ffiVideo.on_event

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
            loops: loops,
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
        loops: Bool,
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
        self.loops = loops
        self.onEvent = onEvent
        self.player = AVPlayer()

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = aspectRatio
        layer.isHidden = false
        layer.backgroundColor = nil
        self.playerLayer = layer

        super.init(frame: .zero)

        #if canImport(AppKit)
        wantsLayer = true
        if self.layer == nil {
            self.layer = CALayer()
        }
        self.layer?.addSublayer(playerLayer)
        #elseif canImport(UIKit)
        self.layer.addSublayer(playerLayer)
        #endif

        applyResolvedDynamicRange(to: playerLayer, for: self)
        setupEndNotification()
        updatePreservePitch(preservePitchBinding.value)
        updatePlaybackRate(playbackRateBinding.value)
        updateSource(sourceComputed.value)
        updateVolume(volumeBinding.value)
        startWatchers()
        mediaSessionBridge = WuiWaterKitMediaSessionBridge(host: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        applyResolvedDynamicRange(to: playerLayer, for: self)
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
        applyResolvedDynamicRange(to: playerLayer, for: self)
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

        if loops {
            player.seek(to: .zero)
            mediaSessionPlay()
        }

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
            playbackShouldStartWhenReady = false
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
        playbackShouldStartWhenReady = true

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
                    self.startPlaybackIfReady(for: item)
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

    private func startPlaybackIfReady(for item: AVPlayerItem) {
        guard item == player.currentItem else { return }
        guard playbackShouldStartWhenReady else { return }
        playbackShouldStartWhenReady = false
        startPlaybackImmediately()
    }

    private func startPlaybackImmediately() {
        player.play()
        player.rate = requestedPlaybackRate
        mediaSessionBridge?.playbackDidChange()
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

    private func emitEvent(
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
extension WuiVideo: WuiMediaSessionHost {
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

        let currentTimeSeconds = player.currentTime().seconds
        let positionSeconds = max(0, currentTimeSeconds.isFinite ? currentTimeSeconds : 0)
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
        guard player.currentItem?.status == .readyToPlay else {
            playbackShouldStartWhenReady = true
            mediaSessionBridge?.playbackDidChange()
            return
        }
        playbackShouldStartWhenReady = false
        startPlaybackImmediately()
    }

    func mediaSessionPause() {
        playbackShouldStartWhenReady = false
        player.pause()
        mediaSessionBridge?.playbackDidChange()
    }

    func mediaSessionStop() {
        playbackShouldStartWhenReady = false
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
