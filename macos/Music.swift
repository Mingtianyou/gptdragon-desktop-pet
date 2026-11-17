import AppKit

// All AppleScript execution is serialized off the UI thread. No player is opened by the pet.
final class MusicMonitor {
    enum State { case stopped, playingSong, unavailable }
    enum Sample { case song, other, failure(Int?) }
    var didChange: ((State) -> Void)?
    private let queue = DispatchQueue(label: "local.codex.gptdragon.music", qos: .utility)
    private let isMusicRunning: () -> Bool
    private let readSample: () -> Sample
    private var timer: Timer?
    private var musicObserver: NSObjectProtocol?
    private var refreshPending = false
    private var generation = 0
    private var busy = false
    private var denied = false
    private(set) var enabled = false
    private(set) var state: State = .stopped
    init(isMusicRunning: @escaping () -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty },
         readSample: @escaping () -> Sample = MusicMonitor.readMusic) {
        self.isMusicRunning = isMusicRunning; self.readSample = readSample
    }
    func start() {
        stop(); enabled = true; denied = false
        // Music broadcasts playback changes. Treat them only as a hint: the
        // Apple Events query below still verifies that the item is a song.
        musicObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] _ in self?.playbackDidChange() }
        // Notifications make normal changes prompt; a relaxed backstop covers
        // macOS versions that omit them without frequent Apple Events.
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = 0.8; RunLoop.main.add(t, forMode: .common); timer = t
        refresh()
    }
    func stop() {
        generation += 1; enabled = false; timer?.invalidate(); timer = nil
        if let musicObserver { DistributedNotificationCenter.default().removeObserver(musicObserver) }
        musicObserver = nil; busy = false; refreshPending = false; set(.stopped)
    }
    func playbackDidChange() {
        guard enabled, !denied else { return }
        if busy { refreshPending = true } else { refresh() }
    }
    func refresh() {
        guard enabled else { return }
        guard isMusicRunning() else { if busy { generation += 1; busy = false }; refreshPending = false; set(.stopped); return }
        guard !busy, !denied else { return }
        // Each poll needs its own token: a completed poll's timeout must not
        // cancel a later poll that happens to be in flight at the deadline.
        generation += 1
        busy = true; let request = generation, read = readSample
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.enabled, self.busy, self.generation == request else { return }
            // A first Apple Events request may wait for the system consent
            // dialog. Report the delay, but keep the one request in flight:
            // its eventual result must be able to restore monitoring.
            self.set(.unavailable)
        }
        queue.async { [weak self] in
            let sample = read()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == request, self.enabled else { return }
                self.busy = false
                guard self.isMusicRunning() else { self.refreshPending = false; self.set(.stopped); return }
                // A newer playback event makes this sample stale. Query again
                // before publishing it, without starting overlapping scripts.
                if self.refreshPending {
                    self.refreshPending = false
                    if case .failure(-1743) = sample { self.denied = true; self.set(.unavailable) }
                    else { self.refresh() }
                    return
                }
                switch sample {
                case .song: self.set(.playingSong)
                case .other: self.set(.stopped)
                case .failure(let number):
                    if number == -1743 { self.denied = true }
                    self.set(.unavailable)
                }
            }
        }
    }
    static func readMusic() -> Sample {
        let source = """
        if application id "com.apple.Music" is not running then return "stopped"
        tell application id "com.apple.Music"
            if player state is not playing then return "stopped"
            if media kind of current track is song then return "song"
            return "stopped"
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failure(nil) }
        let value = script.executeAndReturnError(&error).stringValue
        if let error { return .failure(error[NSAppleScript.errorNumber] as? Int) }
        switch value { case "song": return .song; case "stopped": return .other; default: return .failure(nil) }
    }
    private func set(_ value: State) { if state != value { state = value; didChange?(value) } }
}
