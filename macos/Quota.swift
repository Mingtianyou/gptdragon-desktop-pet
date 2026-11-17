import AppKit
import CoreFoundation

struct QuotaWindow: Codable {
    let remaining: Int
    let minutes: Int
    let reset: Date?

    init?(_ object: Any?) {
        guard let data = object as? [String: Any],
              let number = data["usedPercent"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              let minutes = data["windowDurationMins"] as? Int, minutes > 0 else { return nil }
        let used = number.doubleValue
        remaining = Int((100 - min(100, max(0, used))).rounded())
        self.minutes = minutes
        if let epoch = data["resetsAt"] as? NSNumber,
           CFGetTypeID(epoch) != CFBooleanGetTypeID(), epoch.doubleValue.isFinite, epoch.doubleValue > 0 {
            reset = Date(timeIntervalSince1970: epoch.doubleValue)
        } else { reset = nil }
    }

    var label: String {
        if minutes == 300 { return "5 小时" }
        if minutes == 10080 { return "每周" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) 天" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }
}

struct QuotaSnapshot: Codable {
    let windows: [QuotaWindow]
    let observedAt: Date

    var preferred: QuotaWindow? { windows.first { $0.minutes == 300 } ?? windows.first }

    func estimatedConsumption(since earlier: QuotaSnapshot) -> Int? {
        guard let now = preferred,
              let before = earlier.windows.first(where: { $0.minutes == now.minutes }),
              let nowReset = now.reset, let beforeReset = before.reset,
              nowReset == beforeReset, nowReset > observedAt,
              earlier.observedAt <= observedAt, before.remaining >= now.remaining else { return nil }
        return before.remaining - now.remaining
    }
}

final class QuotaReader {
    private let executable: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var requestSent = false
    private var token = UUID()
    var completion: ((Result<[QuotaWindow], Error>) -> Void)?

    init(executable: URL = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")) {
        self.executable = executable
    }

    private enum Failure: Error { case unavailable }

    func start() {
        stop()
        let id = UUID()
        token = id
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            completion?(.failure(Failure.unavailable))
            return
        }
        let child = Process()
        let toChild = Pipe()
        let fromChild = Pipe()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gptdragon-quota-" + id.uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { completion?(.failure(error)); return }
        child.executableURL = executable
        child.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_SQLITE_HOME"] = directory.path
        child.environment = environment
        child.standardInput = toChild
        child.standardOutput = fromChild
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] _ in
            try? FileManager.default.removeItem(at: directory)
            DispatchQueue.main.async { [weak self] in self?.failIfCurrent(id) }
        }
        do { try child.run() } catch {
            try? FileManager.default.removeItem(at: directory)
            completion?(.failure(error))
            return
        }
        process = child
        input = toChild.fileHandleForWriting
        output = fromChild.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in self?.receive(data, token: id) }
        }
        send(["id": 1, "method": "initialize",
              "params": ["clientInfo": ["name": "gptdragon", "version": "0.7.6"]]])
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.failIfCurrent(id) }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let input else { return }
        do { try input.write(contentsOf: data + Data([10])) } catch { failIfCurrent(token) }
    }

    private func receive(_ data: Data, token id: UUID) {
        guard token == id else { return }
        buffer.append(data)
        guard buffer.count < 1_048_576 else { failIfCurrent(id); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let messageID = message["id"] as? Int else { continue }
            if messageID == 1 && !requestSent {
                guard message["result"] != nil else { failIfCurrent(id); return }
                requestSent = true
                send(["method": "initialized", "params": [:]])
                send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
            } else if messageID == 2 {
                guard let response = message["result"] as? [String: Any] else { failIfCurrent(id); return }
                let byID = response["rateLimitsByLimitId"] as? [String: Any]
                let legacy = response["rateLimits"] as? [String: Any]
                let legacyID = legacy?["limitId"] as? String
                let snapshot = (byID?["codex"] as? [String: Any])
                    ?? ((legacyID == nil || legacyID == "codex") ? legacy : nil)
                let windows = [QuotaWindow(snapshot?["primary"]), QuotaWindow(snapshot?["secondary"])].compactMap { $0 }
                guard !windows.isEmpty else { failIfCurrent(id); return }
                let callback = completion
                stop()
                callback?(.success(windows))
                return
            }
        }
    }

    private func failIfCurrent(_ id: UUID) {
        guard token == id, process != nil else { return }
        let callback = completion
        stop()
        callback?(.failure(Failure.unavailable))
    }

    func stop() {
        token = UUID()
        output?.readabilityHandler = nil
        if let child = process, child.isRunning { child.terminate() }
        try? input?.close()
        try? output?.close()
        process = nil
        input = nil
        output = nil
        buffer.removeAll()
        requestSent = false
    }
}

final class QuotaStore {
    private let reader: QuotaReader
    private let defaults: UserDefaults?
    private let cacheKey = "lastQuotaSnapshotV1"
    private(set) var snapshot: QuotaSnapshot?
    private(set) var isRestoredSnapshot = false
    private(set) var isRefreshing = false
    private(set) var failed = false
    private var callbacks: [(QuotaSnapshot?) -> Void] = []
    private var nextCallbacks: [(QuotaSnapshot?) -> Void] = []
    var didChange: (() -> Void)?

    init(reader: QuotaReader = QuotaReader(), defaults: UserDefaults? = .standard) {
        self.reader = reader
        self.defaults = defaults
        if let data = defaults?.data(forKey: cacheKey),
           let saved = try? JSONDecoder().decode(QuotaSnapshot.self, from: data),
           !saved.windows.isEmpty, saved.windows.count <= 2,
           saved.windows.allSatisfy({ (0...100).contains($0.remaining) && $0.minutes > 0 }),
           saved.observedAt <= Date() {
            snapshot = saved
            isRestoredSnapshot = true
        }
        reader.completion = { [weak self] result in self?.received(result) }
    }

    func refresh(afterCurrent: Bool = false, completion: ((QuotaSnapshot?) -> Void)? = nil) {
        if isRefreshing {
            if afterCurrent, let completion { nextCallbacks.append(completion) }
            else if let completion { callbacks.append(completion) }
            return
        }
        if let completion { callbacks.append(completion) }
        isRefreshing = true
        failed = false
        didChange?()
        reader.start()
    }

    private func received(_ result: Result<[QuotaWindow], Error>) {
        let latest: QuotaSnapshot?
        switch result {
        case .success(let windows):
            let value = QuotaSnapshot(windows: windows, observedAt: Date())
            snapshot = value
            isRestoredSnapshot = false
            if let data = try? JSONEncoder().encode(value) { defaults?.set(data, forKey: cacheKey) }
            failed = false
            latest = value
        case .failure:
            failed = true
            latest = nil
        }
        isRefreshing = false
        let finished = callbacks
        callbacks.removeAll()
        didChange?()
        for callback in finished { callback(latest) }
        if !nextCallbacks.isEmpty {
            callbacks = nextCallbacks
            nextCallbacks.removeAll()
            refresh()
        }
    }
}



final class QuotaButton: NSButton {
    private var tracking: NSTrackingArea?
    private var primary: Int?
    private var secondary: Int?
    private var deepSeekMode = false
    private var balanceGlyph = "DS"
    private var balanceWarning = false
    private var hoverDelay: Timer?
    private var hoverHint: FloatingGlassPanel?
    private(set) var hoverText = "额度暂不可用，点击重试"
    var onHover: (() -> Void)?
    var hoverEnabled = false {
        didSet { if !hoverEnabled { dismissHoverHint() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        title = ""
        setAccessibilityLabel("Codex 剩余额度")
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard hoverEnabled, hoverDelay == nil, hoverHint == nil else { return }
        onHover?()
        let delay = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.hoverDelay = nil
            self.showHoverHint()
        }
        hoverDelay = delay
        RunLoop.main.add(delay, forMode: .common)
    }

    override func mouseExited(with event: NSEvent) { dismissHoverHint() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { dismissHoverHint() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func showHoverHint() {
        guard hoverEnabled, let host = window, host.isVisible,
              !isHiddenOrHasHiddenAncestor, let screen = host.screen else { return }
        let label = NSTextField(wrappingLabelWithString: hoverText)
        label.font = .systemFont(ofSize: 11)
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 220
        let fit = label.fittingSize
        let size = NSSize(width: min(220, ceil(fit.width)) + 18, height: ceil(fit.height) + 12)
        label.frame = NSRect(x: 9, y: 6, width: size.width - 18, height: size.height - 12)

        let visible = screen.visibleFrame
        let anchor = host.convertToScreen(convert(bounds, to: nil))
        let gap: CGFloat = 6
        let above = anchor.maxY + gap
        let y = above + size.height <= visible.maxY ? above : anchor.minY - gap - size.height
        let frame = NSRect(x: min(max(anchor.midX - size.width / 2, visible.minX), visible.maxX - size.width),
                           y: max(visible.minY, y), width: size.width, height: size.height)
        let hint: FloatingGlassPanel
        if let hoverHint {
            hint = hoverHint
        } else {
            hint = FloatingGlassPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: false)
            hint.keyAllowed = false
            hint.isReleasedWhenClosed = false
            hint.hidesOnDeactivate = false
            hint.ignoresMouseEvents = true
            hint.isOpaque = false
            hint.backgroundColor = .clear
            hint.hasShadow = true
            hint.level = host.level
            hint.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            let backdrop = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            backdrop.material = .toolTip
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            backdrop.wantsLayer = true
            backdrop.layer?.cornerRadius = 8
            backdrop.layer?.masksToBounds = true
            hint.contentView = backdrop
            hoverHint = hint
            host.addChildWindow(hint, ordered: .above)
        }
        hint.setFrame(frame, display: true)
        hint.contentView?.subviews = [label]
        hint.orderFrontRegardless()
    }

    private func dismissHoverHint() {
        hoverDelay?.invalidate()
        hoverDelay = nil
        if let hint = hoverHint {
            hint.parent?.removeChildWindow(hint)
            hint.orderOut(nil)
            hoverHint = nil
        }
    }

    func update(snapshot: QuotaSnapshot?, refreshing: Bool, failed: Bool, restored: Bool) {
        deepSeekMode = false
        primary = snapshot?.windows.first { $0.minutes == 300 }?.remaining
        secondary = snapshot?.windows.first { $0.minutes == 10080 }?.remaining
        if let snapshot {
            let five = primary.map { "\($0)%" } ?? "不可用"
            let week = secondary.map { "\($0)%" } ?? "不可用"
            let time = DateFormatter.localizedString(from: snapshot.observedAt, dateStyle: .short, timeStyle: .short)
            let note = refreshing ? "更新中，" : failed ? "更新失败，" : restored ? "上次数据，" : ""
            let details = "5 小时剩余：\(five)\n每周剩余：\(week)"
            hoverText = note.isEmpty ? details : details + "\n" + note + "更新于 \(time)"
        } else {
            hoverText = refreshing ? "正在读取 Codex 额度…" : "额度暂不可用，点击重试"
        }
        setAccessibilityLabel(hoverText)
        if hoverHint != nil { showHoverHint() }
        needsDisplay = true
    }

    func updateDeepSeek(snapshot: DeepSeekBalance?, refreshing: Bool, error: String?, restored: Bool) {
        deepSeekMode = true
        balanceGlyph = snapshot?.symbol ?? "DS"
        balanceWarning = error != nil || snapshot?.available == false
        if let snapshot {
            let time = DateFormatter.localizedString(from: snapshot.observedAt, dateStyle: .short, timeStyle: .short)
            let note = refreshing ? "更新中" : error != nil ? "更新失败" : restored ? "上次数据" : "更新于"
            hoverText = "DeepSeek 余额：\(snapshot.summary)\n\(note) \(time)"
            if snapshot.available == false { hoverText += "\n余额不可用于调用" }
        } else {
            hoverText = refreshing ? "正在读取 DeepSeek 余额…" : (error ?? "DeepSeek 余额暂不可用")
        }
        setAccessibilityLabel(hoverText)
        if hoverHint != nil { showHoverHint() }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        if deepSeekMode {
            let glyph = balanceGlyph as NSString
            let font = NSFont.systemFont(ofSize: balanceGlyph.count > 1 ? 9 : 15, weight: .semibold)
            let color = balanceWarning ? NSColor.systemOrange : NSColor.labelColor.withAlphaComponent(0.78)
            let attrs: [NSAttributedString.Key:Any] = [.font:font, .foregroundColor:color]
            let size = glyph.size(withAttributes:attrs)
            glyph.draw(at:NSPoint(x:center.x-size.width/2,y:center.y-size.height/2),withAttributes:attrs)
            return
        }
        func ring(radius: CGFloat, remaining: Int?) {
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 2
            NSColor.labelColor.withAlphaComponent(0.17).setStroke()
            track.stroke()
            guard let remaining, remaining > 0 else { return }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                          endAngle: 90 - 360 * CGFloat(remaining) / 100, clockwise: true)
            arc.lineWidth = 2
            arc.lineCapStyle = .round
            let color: NSColor = remaining <= 20 ? .systemOrange : .labelColor
            color.withAlphaComponent(0.8).setStroke()
            arc.stroke()
        }
        ring(radius: 10, remaining: primary)
        ring(radius: 6.5, remaining: secondary)
        let diamond = NSBezierPath()
        diamond.move(to: NSPoint(x: center.x, y: center.y + 2.3))
        diamond.line(to: NSPoint(x: center.x + 2.3, y: center.y))
        diamond.line(to: NSPoint(x: center.x, y: center.y - 2.3))
        diamond.line(to: NSPoint(x: center.x - 2.3, y: center.y))
        diamond.close()
        NSColor.labelColor.withAlphaComponent(0.6).setFill()
        diamond.fill()
    }
}
