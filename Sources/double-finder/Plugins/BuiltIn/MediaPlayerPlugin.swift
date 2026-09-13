import AppKit
import AVKit
import AVFoundation
import DoubleFinderPluginKit
#if HAS_VLCKIT
import VLCKit
#endif

/// Built-in view plugin: video and audio under F3's Plugin segment and in the
/// Quick View pane. Decoding is done in-process by **libVLC** (the VLCKit
/// framework, fetched by `Tools/fetch-vlckit.sh`), so MKV / WebM / AVI / WMV /
/// FLV / TS and OGG / Opus / WMA / APE / WavPack play like MP4 and MP3 do —
/// nothing is converted, nothing external is called. The controls (play /
/// pause, scrubber, times, volume) are the plugin's own. A build without the
/// framework falls back to AVKit's player for the formats macOS decodes and
/// says so for the rest. Quick Look (Preview, 3) stays available either way.
final class MediaPlayerPlugin: NSObject, DFPlugin {
    static let identifier = "net.qian.double-finder.media"

    var info: PluginInfo {
        MainActor.assumeIsolated { PluginInfo(identifier: Self.identifier, name: tr("Media Player"), version: "2.0",
                   summary: tr("Plays video and audio in the Lister (built-in VLC decoders: MKV / WebM / AVI / WMV / FLAC / OGG / APE…)"),
                   author: "Double Finder") }
    }

    private let viewer = MediaViewer()

    override init() { super.init() }

    func activate(host: PluginHost) throws {}

    var viewers: [ViewerPlugin] { [viewer] }
}

final class MediaViewer: ViewerPlugin, Sendable {
    let identifier = "media"
    var displayName: String { MainActor.assumeIsolated { tr("Media Player") } }

    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "3gp", "3g2", "mpg", "mpeg", "m2v", "ts", "m2ts", "mts", "vob",
        "avi", "mkv", "webm", "wmv", "asf", "flv", "f4v", "rm", "rmvb", "ogv", "divx", "mxf",
    ]
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "aiff", "aif", "aifc", "flac", "alac", "caf", "ac3", "eac3",
        "ogg", "oga", "opus", "spx", "wma", "ape", "wv", "tta", "tak", "mka", "mp2", "amr", "dsf", "dff", "mid", "midi",
    ]

    func canView(url: URL, sample: Data) -> Bool {
        let ext = url.pathExtension.lowercased()
        return Self.videoExtensions.contains(ext) || Self.audioExtensions.contains(ext)
    }

    @MainActor func makeView(for url: URL) throws -> NSView {
        let video = Self.videoExtensions.contains(url.pathExtension.lowercased())
        #if HAS_VLCKIT
        return VLCMediaContainer(url: url, expectsVideo: video)
        #else
        return AVKitMediaContainer(url: url, expectsVideo: video)
        #endif
    }
}

// MARK: - Shared pieces

/// "m:ss" / "h:mm:ss" from milliseconds (negative or unknown → "–:––").
enum MediaTime {
    static func format(milliseconds ms: Int) -> String {
        guard ms >= 0 else { return "–:––" }
        let s = ms / 1000
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// Artwork square + title / artist–album lines for audio files; shared by both
/// player backends so audio looks the same whichever decodes it.
final class MediaAudioHeader: NSView {
    let artwork = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.imageAlignment = .alignCenter
        artwork.contentTintColor = .tertiaryLabelColor
        artwork.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 96, weight: .light))
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byTruncatingTail
        [artwork, titleLabel, detailLabel].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        let textH: CGFloat = 44
        detailLabel.frame = NSRect(x: 16, y: 8, width: b.width - 32, height: 16)
        titleLabel.frame = NSRect(x: 16, y: 26, width: b.width - 32, height: 20)
        let side = max(0, min(min(b.width - 48, b.height - textH - 32), 360))
        artwork.frame = NSRect(x: (b.width - side) / 2, y: textH + max(0, (b.height - textH - side) / 2),
                               width: side, height: side)
    }

    func set(title: String?, artist: String?, album: String?, image: NSImage?) {
        if let title, !title.isEmpty { titleLabel.stringValue = title }
        let detail = [artist, album].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " — ")
        if !detail.isEmpty { detailLabel.stringValue = detail }
        if let image {
            artwork.contentTintColor = nil
            artwork.image = image
        }
    }
}

/// Play / pause · elapsed · scrubber · duration · volume. Pure UI: the owner
/// wires the callbacks and pushes state in.
final class MediaControlBar: NSView {
    static let height: CGFloat = 40
    var onTogglePlay: (() -> Void)?
    var onSeek: ((Double) -> Void)?        // 0…1
    var onVolume: ((Int) -> Void)?         // 0…100

    private let playButton = NSButton()
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let scrubber = NSSlider()
    private let duration = NSTextField(labelWithString: "–:––")
    private let speaker = NSImageView()
    private let volume = NSSlider()
    private(set) var isScrubbing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playButton.bezelStyle = .texturedRounded
        playButton.isBordered = false
        playButton.imagePosition = .imageOnly
        playButton.imageScaling = .scaleProportionallyDown
        playButton.target = self
        playButton.action = #selector(playTapped)
        setPlaying(false)
        for label in [elapsed, duration] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        elapsed.alignment = .right
        scrubber.minValue = 0; scrubber.maxValue = 1
        scrubber.controlSize = .small
        scrubber.isContinuous = true
        scrubber.target = self
        scrubber.action = #selector(scrubbed(_:))
        speaker.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
        speaker.contentTintColor = .secondaryLabelColor
        volume.minValue = 0; volume.maxValue = 100; volume.doubleValue = 100
        volume.controlSize = .mini
        volume.isContinuous = true
        volume.target = self
        volume.action = #selector(volumeChanged(_:))
        [playButton, elapsed, scrubber, duration, speaker, volume].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height, w = bounds.width
        playButton.frame = NSRect(x: 8, y: (h - 24) / 2, width: 28, height: 24)
        elapsed.frame = NSRect(x: 40, y: (h - 16) / 2, width: 56, height: 16)
        let volW: CGFloat = w > 420 ? 80 : 0
        speaker.frame = NSRect(x: w - 8 - volW - 20, y: (h - 16) / 2, width: 16, height: 16)
        speaker.isHidden = volW == 0
        volume.frame = NSRect(x: w - 8 - volW, y: (h - 16) / 2, width: volW, height: 16)
        volume.isHidden = volW == 0
        let durX = speaker.frame.minX - 8 - 56
        duration.frame = NSRect(x: durX, y: (h - 16) / 2, width: 56, height: 16)
        scrubber.frame = NSRect(x: 100, y: (h - 16) / 2, width: max(20, durX - 108), height: 16)
    }

    func setPlaying(_ playing: Bool) {
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
    }

    func setTime(elapsedMs: Int, durationMs: Int) {
        elapsed.stringValue = MediaTime.format(milliseconds: elapsedMs)
        duration.stringValue = MediaTime.format(milliseconds: durationMs > 0 ? durationMs : -1)
        if !isScrubbing, durationMs > 0 {
            scrubber.doubleValue = min(1, max(0, Double(elapsedMs) / Double(durationMs)))
        }
    }

    func setProgress(_ fraction: Double) {
        if !isScrubbing { scrubber.doubleValue = min(1, max(0, fraction)) }
    }

    /// Labels read on a dark (video) or standard (audio) backdrop.
    func setDarkChrome(_ dark: Bool) {
        layer?.backgroundColor = dark ? NSColor(white: 0.08, alpha: 1).cgColor : nil
        let text: NSColor = dark ? NSColor(white: 0.85, alpha: 1) : .secondaryLabelColor
        elapsed.textColor = text; duration.textColor = text
        speaker.contentTintColor = text
        playButton.contentTintColor = dark ? .white : .labelColor
    }

    @objc private func playTapped() { onTogglePlay?() }
    @objc private func scrubbed(_ sender: NSSlider) {
        // NSSlider sends its action continuously while dragging and once on release.
        let dragging = NSApp.currentEvent.map { $0.type == .leftMouseDragged || $0.type == .leftMouseDown } ?? false
        isScrubbing = dragging
        onSeek?(sender.doubleValue)
    }
    @objc private func volumeChanged(_ sender: NSSlider) { onVolume?(Int(sender.doubleValue.rounded())) }
}

#if HAS_VLCKIT

// MARK: - libVLC backend

/// One libVLC instance for the whole app; players are cheap, the library is not.
enum VLCEngine {
    static let library: VLCLibrary = {
        let lib = VLCLibrary(options: [
            "--no-video-title-show",   // no filename overlay when a video starts
            "--no-osd",
            "--no-lua",                // no playlist / extension scripts to scan
            "--no-stats",
            "--quiet",
        ])
        lib.loggers = nil
        return lib
    }()
}

/// What the host mounts when VLCKit is linked: a `VLCVideoView` (video) or the
/// audio header, over the control bar. Playback starts on its own and stops
/// when the view leaves the window; the Lister hiding it (other mode) pauses.
final class VLCMediaContainer: NSView, VLCMediaPlayerDelegate, VLCMediaDelegate {
    private let url: URL
    private var showsVideo: Bool
    private let videoView = VLCVideoView()
    private let header = MediaAudioHeader()
    private let bar = MediaControlBar()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var player: VLCMediaPlayer?
    private var media: VLCMedia?
    private var started = false
    private var modeSettled = false

    init(url: URL, expectsVideo: Bool) {
        self.url = url
        self.showsVideo = expectsVideo
        super.init(frame: .zero)
        wantsLayer = true
        videoView.backColor = .black
        videoView.fillScreen = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.alignment = .center
        statusLabel.isHidden = true
        header.titleLabel.stringValue = url.deletingPathExtension().lastPathComponent
        [videoView, header, bar, statusLabel].forEach(addSubview)
        bar.onTogglePlay = { [weak self] in self?.togglePlay() }
        bar.onSeek = { [weak self] f in self?.player?.position = Float(f) }
        bar.onVolume = { [weak self] v in self?.player?.audio?.volume = Int32(v) }
        applyMode()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Host hooks

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else if !started { started = true; start() }
    }
    override func viewDidHide() { super.viewDidHide(); if player?.isPlaying == true { player?.pause() } }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: togglePlay()                                   // space
        case 123: seek(by: -10_000)                             // ←
        case 124: seek(by: 10_000)                              // →
        default: super.keyDown(with: event)
        }
    }

    private func applyMode() {
        layer?.backgroundColor = showsVideo ? NSColor.black.cgColor : nil
        videoView.isHidden = !showsVideo
        header.isHidden = showsVideo
        bar.setDarkChrome(showsVideo)
        statusLabel.textColor = showsVideo ? .white : .secondaryLabelColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        bar.frame = NSRect(x: 0, y: 0, width: b.width, height: MediaControlBar.height)
        let content = NSRect(x: 0, y: MediaControlBar.height, width: b.width, height: max(0, b.height - MediaControlBar.height))
        videoView.frame = content
        header.frame = content
        statusLabel.frame = NSRect(x: 24, y: content.midY - 10, width: b.width - 48, height: 40)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyMode()
    }

    // MARK: Playback

    private func start() {
        let m = VLCMedia(url: url)
        m.delegate = self
        media = m
        let p = VLCMediaPlayer(library: VLCEngine.library)
        p.delegate = self
        p.drawable = videoView
        p.media = m
        player = p
        _ = m.parse(options: .fetchLocal)      // local parse + cover art → mediaDidFinishParsing
        p.play()
        bar.setPlaying(true)
    }

    private func stop() {
        guard let p = player else { return }
        p.delegate = nil
        media?.delegate = nil
        p.stop()
        p.drawable = nil
        player = nil
        media = nil
    }

    private func togglePlay() {
        guard let p = player else { return }
        switch p.state {
        case .ended, .stopped, .error:
            p.stop(); p.play()                                  // libVLC 3: restart from the top
        default:
            p.isPlaying ? p.pause() : p.play()
        }
    }

    private func seek(by deltaMs: Int) {
        guard let p = player, let length = p.media?.length.value?.intValue, length > 0 else { return }
        let target = min(length - 500, max(0, Int(p.time.intValue) + deltaMs))
        p.time = VLCTime(int: Int32(target))
    }

    // MARK: VLCMediaPlayerDelegate (main thread)

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let p = player else { return }
        switch p.state {
        case .playing:
            bar.setPlaying(true)
            statusLabel.isHidden = true
            refreshMode()
        case .esAdded:
            refreshMode()
        case .paused, .stopped, .ended:
            bar.setPlaying(false)
            if p.state == .ended { bar.setProgress(1) }
        case .error:
            bar.setPlaying(false)
            statusLabel.stringValue = tr("Cannot play this file")
            statusLabel.isHidden = false
        default:
            break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard let p = player else { return }
        bar.setTime(elapsedMs: Int(p.time.intValue), durationMs: p.media?.length.value?.intValue ?? -1)
        bar.setPlaying(p.isPlaying)          // state events can arrive out of order; the clock is the truth
        if !modeSettled { refreshMode() }
    }

    /// The extension was only a guess (audio in .mkv, a video in .ogg): once
    /// libVLC has read the streams, follow them. The video output appears a
    /// moment after `.playing`, so video is confirmed by track count or vout;
    /// "no video after all" is only concluded after 1.5 s of playback.
    private func refreshMode() {
        guard let p = player else { return }
        if p.numberOfVideoTracks > 0 || p.hasVideoOut {
            if !showsVideo { showsVideo = true; applyMode() }
            modeSettled = true
        } else if showsVideo, Int(p.time.intValue) > 1500 {
            showsVideo = false; applyMode()
            modeSettled = true
        } else if !showsVideo, Int(p.time.intValue) > 1500 {
            modeSettled = true
        }
    }

    // MARK: VLCMediaDelegate

    func mediaDidFinishParsing(_ aMedia: VLCMedia) {
        guard aMedia === media, !showsVideo else { return }
        let meta = aMedia.metaData
        header.set(title: meta.title, artist: meta.artist ?? meta.albumArtist, album: meta.album, image: meta.artwork)
    }
}

#else

// MARK: - AVKit fallback (build without VLCKit)

/// AVKit's player for what macOS decodes; everything else gets a hint. Used
/// only when the project was built without `vendor/VLCKit`.
final class AVKitMediaContainer: NSView {
    private let url: URL
    private var showsVideo: Bool
    private let playerView = AVPlayerView()
    private let header = MediaAudioHeader()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var player: AVPlayer?
    private var started = false

    init(url: URL, expectsVideo: Bool) {
        self.url = url
        self.showsVideo = expectsVideo
        super.init(frame: .zero)
        wantsLayer = true
        playerView.controlsStyle = .floating
        playerView.showsSharingServiceButton = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.isHidden = true
        header.titleLabel.stringValue = url.deletingPathExtension().lastPathComponent
        [playerView, header, statusLabel].forEach(addSubview)
        applyMode()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(playerView) ?? false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else if !started { started = true; start() }
    }
    override func viewDidHide() { super.viewDidHide(); player?.pause() }

    private func applyMode() {
        layer?.backgroundColor = showsVideo ? NSColor.black.cgColor : nil
        header.isHidden = showsVideo
        playerView.controlsStyle = showsVideo ? .floating : .inline
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        if showsVideo {
            playerView.frame = b
        } else {
            let strip: CGFloat = 56
            playerView.frame = NSRect(x: 0, y: 0, width: b.width, height: strip)
            header.frame = NSRect(x: 0, y: strip, width: b.width, height: max(0, b.height - strip))
        }
        statusLabel.frame = NSRect(x: 24, y: b.midY - 10, width: b.width - 48, height: 40)
    }

    private func start() {
        let asset = AVURLAsset(url: url)
        Task { @MainActor [weak self] in
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard let self, self.window != nil else { return }
            guard playable else {
                self.statusLabel.stringValue = tr("macOS cannot decode this format")
                self.statusLabel.isHidden = false
                return
            }
            let tracks = (try? await asset.load(.tracks)) ?? []
            let hasVideo = tracks.contains { $0.mediaType == .video }
            if hasVideo != self.showsVideo { self.showsVideo = hasVideo; self.applyMode() }
            if !hasVideo { await self.loadTags(asset) }
            guard self.window != nil else { return }
            let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            self.player = p
            self.playerView.player = p
            p.play()
        }
    }

    private func stop() {
        player?.pause()
        playerView.player = nil
        player = nil
    }

    private func loadTags(_ asset: AVURLAsset) async {
        guard let items = try? await asset.load(.commonMetadata) else { return }
        var title: String?, artist: String?, album: String?, image: NSImage?
        for item in items {
            guard let id = item.identifier else { continue }
            switch id {
            case .commonIdentifierTitle: title = try? await item.load(.stringValue)
            case .commonIdentifierArtist: artist = try? await item.load(.stringValue)
            case .commonIdentifierAlbumName: album = try? await item.load(.stringValue)
            case .commonIdentifierArtwork:
                if let data = try? await item.load(.dataValue) { image = NSImage(data: data) }
            default: break
            }
        }
        header.set(title: title, artist: artist, album: album, image: image)
    }
}

#endif
