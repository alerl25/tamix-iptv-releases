import AVFoundation
import MobileVLCKit
import UIKit

/// Full-screen VLC player for Tamix on iPhone: plays what the iPhone's own
/// player cannot (MPEG-TS live channels, MKV films), reports `started`,
/// `time`, `ended`, `error` and `closed` to the web app like the Android
/// player does, and closes with the ✕ (or by swiping down).
final class TamixPlayerViewController: UIViewController, VLCMediaPlayerDelegate {
    typealias Emit = (String, [String: Any]) -> Void

    private let request: TamixPlayRequest
    private let emit: Emit
    private let player = VLCMediaPlayer()
    private let videoView = UIView()
    private let controls = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let slider = UISlider()
    private let timeLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)

    private var started = false
    private var closed = false
    private var seekedToStart = false
    private var lastTimeEvent = Date.distantPast
    private var playingSince: Date?
    private var playedMs: Double = 0
    private var hideTimer: Timer?
    private var sliding = false

    // Live channels: how many times a VLC error is retried before giving up.
    private static let maxLiveRetries = 2
    private static let retryDelay: TimeInterval = 1.5
    private var retryCount = 0
    private var retryPending = false

    // Last values painted on the controls, so a tick that changes nothing
    // visible does no UI work.
    private var lengthMs: Double = 0
    private var shownSecond = -1
    private var shownDuration: Double = 0

    private var backgroundObserver: NSObjectProtocol?
    private var dismissed = false
    private var dismissWaiters: [() -> Void] = []

    init(request: TamixPlayRequest, emit: @escaping Emit) {
        self.request = request
        self.emit = emit
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { removeBackgroundObserver() }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        layout()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.pauseForBackground() }
        start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Playback

    private func makeMedia() -> VLCMedia {
        let media = VLCMedia(url: request.url)
        if let agent = request.userAgent, !agent.isEmpty {
            media.addOption(":http-user-agent=\(agent)")
        }
        if let referer = request.headers.first(where: { $0.key.lowercased() == "referer" })?.value {
            media.addOption(":http-referrer=\(referer)")
        }
        // A steadier start on live channels, a quicker one on films.
        media.addOption(":network-caching=\(request.isLive ? 2000 : 1200)")
        media.addOption(":http-reconnect")
        return media
    }

    private func start() {
        activateAudioSession()
        player.delegate = self
        player.drawable = videoView
        player.media = makeMedia()
        spinner.startAnimating()
        player.play()
    }

    /// Plays with the silent switch on and tells other apps' audio to step
    /// aside. A failure here must never stop the video, so errors are ignored.
    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
        } catch {}
        do {
            try session.setActive(true)
        } catch {}
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {}
    }

    func close(reason: String) {
        guard !closed else { return }
        closed = true
        hideTimer?.invalidate()
        removeBackgroundObserver()
        accumulatePlayed()
        let position = Double(player.time.intValue)
        refreshLength()
        let duration = durationMs()
        player.stop()
        player.delegate = nil
        deactivateAudioSession()
        emit("closed", [
            "reason": reason,
            "positionMs": max(0, position),
            "durationMs": duration,
            "playedMs": playedMs,
        ])
        if presentingViewController != nil {
            dismiss(animated: true) { self.finishDismiss() }
        } else {
            finishDismiss()
        }
    }

    /// Runs `block` once this player is off screen (right away if it already is).
    func whenDismissed(_ block: @escaping () -> Void) {
        if dismissed { block() } else { dismissWaiters.append(block) }
    }

    private func finishDismiss() {
        dismissed = true
        let waiters = dismissWaiters
        dismissWaiters = []
        waiters.forEach { $0() }
    }

    private func removeBackgroundObserver() {
        if let token = backgroundObserver {
            NotificationCenter.default.removeObserver(token)
            backgroundObserver = nil
        }
    }

    /// Films pause when the app goes to the background; coming back does nothing
    /// by itself. Live channels are left alone.
    private func pauseForBackground() {
        guard !closed, !request.isLive, player.isPlaying else { return }
        player.pause()
        updatePlayButton()
    }

    private func refreshLength() {
        if request.isLive { return }
        lengthMs = max(0, Double(player.media?.length.intValue ?? 0))
    }

    private func durationMs() -> Double {
        if request.isLive { return -1 }
        if lengthMs <= 0 { refreshLength() }
        return lengthMs > 0 ? lengthMs : -1
    }

    private func accumulatePlayed() {
        if let since = playingSince {
            playedMs += Date().timeIntervalSince(since) * 1000
            playingSince = nil
        }
    }

    /// VLC may call its delegate off the main thread; everything that touches
    /// UIKit or emits events to the web runs on the main thread.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async { work() }
        }
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        // Read the state now: by the time a queued block runs it may have moved on.
        let state = player.state
        onMain { [weak self] in self?.handleState(state) }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let position = Double(player.time.intValue)
        onMain { [weak self] in self?.handleTime(position) }
    }

    private func handleState(_ state: VLCMediaPlayerState) {
        guard !closed else { return }
        switch state {
        case .playing:
            // Playing again after a retry: the next error gets its full retries.
            retryCount = 0
            spinner.stopAnimating()
            if playingSince == nil { playingSince = Date() }
            if !started {
                started = true
                emit("started", [:])
                if request.startMs > 0, !request.isLive, !seekedToStart {
                    seekedToStart = true
                    player.time = VLCTime(int: Int32(clamping: request.startMs))
                }
                scheduleHide()
            }
            updatePlayButton()
        case .buffering, .opening:
            if !started { spinner.startAnimating() }
        case .paused:
            accumulatePlayed()
            updatePlayButton()
        case .ended:
            emit("ended", [:])
            close(reason: "ended")
        case .error:
            handleError()
        case .stopped:
            // VLC stops at the end of some streams without `.ended`.
            if started && !closed && !request.isLive {
                emit("ended", [:])
                close(reason: "ended")
            }
        default:
            break
        }
    }

    /// A live channel gets a couple of quiet retries before the error is real;
    /// a film keeps the old behaviour (report and close at once).
    private func handleError() {
        if retryPending { return }
        if request.isLive && retryCount < TamixPlayerViewController.maxLiveRetries {
            retryCount += 1
            retryPending = true
            accumulatePlayed()
            spinner.startAnimating()
            DispatchQueue.main.asyncAfter(deadline: .now() + TamixPlayerViewController.retryDelay) { [weak self] in
                guard let self = self else { return }
                self.retryPending = false
                guard !self.closed else { return }
                self.player.stop()
                self.player.media = self.makeMedia()
                self.player.play()
            }
            return
        }
        emit("error", ["kind": "unknown", "code": "VLC_ERROR"])
        close(reason: "error")
    }

    private func handleTime(_ position: Double) {
        guard !closed else { return }
        let now = Date()
        let emitDue = now.timeIntervalSince(lastTimeEvent) >= 1
        if emitDue { refreshLength() }
        let duration = durationMs()
        if duration > 0 {
            // Repaint only when the shown second (or the length) changed.
            let second = Int(position / 1000)
            if second != shownSecond || duration != shownDuration {
                shownSecond = second
                shownDuration = duration
                if !sliding {
                    slider.value = Float(position / duration)
                }
                timeLabel.text = "\(format(position)) / \(format(duration))"
            }
        } else if shownDuration != -1 {
            shownDuration = -1
            shownSecond = -1
            timeLabel.text = "EN DIRECTO"
        }
        if emitDue {
            lastTimeEvent = now
            emit("time", [
                "positionMs": position,
                "durationMs": duration,
                "playing": player.isPlaying,
            ])
        }
    }

    // MARK: - Controls

    private func layout() {
        videoView.backgroundColor = .black
        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)

        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        view.addSubview(controls)

        titleLabel.text = request.title
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .white
        closeButton.accessibilityLabel = "Cerrar"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        playButton.tintColor = .white
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 44, weight: .regular), forImageIn: .normal
        )
        updatePlayButton()

        slider.minimumTrackTintColor = UIColor(red: 0.9, green: 0.04, blue: 0.08, alpha: 1)
        slider.isHidden = request.isLive
        slider.addTarget(self, action: #selector(sliderBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        slider.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.textColor = .white
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        [titleLabel, closeButton, playButton, slider, timeLabel].forEach(controls.addSubview)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            controls.topAnchor.constraint(equalTo: view.topAnchor),
            controls.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            closeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            closeButton.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -16),

            playButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            timeLabel.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
            timeLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),

            slider.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            slider.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -12),
        ])

        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleControls)))
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(closeTapped))
        swipe.direction = .down
        view.addGestureRecognizer(swipe)
    }

    private func updatePlayButton() {
        let name = player.isPlaying ? "pause.fill" : "play.fill"
        playButton.setImage(UIImage(systemName: name), for: .normal)
    }

    private func scheduleHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            UIView.animate(withDuration: 0.25) { self?.controls.alpha = 0 }
        }
    }

    @objc private func toggleControls() {
        let show = controls.alpha < 0.5
        UIView.animate(withDuration: 0.2) { self.controls.alpha = show ? 1 : 0 }
        if show { scheduleHide() }
    }

    @objc private func closeTapped() { close(reason: "user") }

    @objc private func playTapped() {
        if player.isPlaying { player.pause() } else { player.play() }
        updatePlayButton()
        scheduleHide()
    }

    @objc private func sliderBegan() {
        sliding = true
        hideTimer?.invalidate()
    }

    @objc private func sliderEnded() {
        sliding = false
        let duration = durationMs()
        if duration > 0 {
            player.time = VLCTime(int: Int32(clamping: Int64(Double(slider.value) * duration)))
        }
        scheduleHide()
    }

    private func format(_ ms: Double) -> String {
        let total = Int(ms / 1000)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
