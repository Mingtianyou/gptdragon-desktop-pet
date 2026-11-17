import AppKit

let counts = [6,8,8,4,5,8,6,6,6]
let times:[[Double]] = [[1.68,0.66,0.66,0.84,0.84,1.92],[0.12,0.12,0.12,0.12,0.12,0.12,0.12,0.22],[0.12,0.12,0.12,0.12,0.12,0.12,0.12,0.22],[0.14,0.14,0.14,0.28],[0.14,0.14,0.14,0.14,0.28],[0.14,0.14,0.14,0.14,0.14,0.14,0.14,0.24],[0.15,0.15,0.15,0.15,0.15,0.26],[0.12,0.12,0.12,0.12,0.12,0.22],[0.15,0.15,0.15,0.15,0.15,0.28]]
let labels = ["待机","向右移动","向左移动","挥手","招手","受阻","等待","工作","完成"]
// The distorted generated gestures are temporarily retired.
let idleLabels: [String] = ["看尾巴", "理头发", "开心"]

// Head displacement measured from the original six 192×208 typing frames.
// Interpolate the original timing rather than distorting individual body parts.
func originalTypingOffset(elapsed: TimeInterval) -> CGPoint {
    let offsets: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: -1),
                              CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0),
                              CGPoint(x: 0, y: -1), CGPoint(x: 0, y: -1)]
    let durations = times[7]
    let cycle = durations.reduce(0, +)
    var phase = max(0, elapsed).truncatingRemainder(dividingBy: cycle)
    for index in offsets.indices {
        if phase < durations[index] {
            let t = phase / durations[index]
            let eased = t * t * (3 - 2 * t)
            let a = offsets[index], b = offsets[(index + 1) % offsets.count]
            return CGPoint(x: a.x + (b.x - a.x) * eased,
                           y: a.y + (b.y - a.y) * eased)
        }
        phase -= durations[index]
    }
    return .zero
}

func pixelAlignedTypingOffset(elapsed: TimeInterval, size: CGSize, backingScale: CGFloat) -> CGPoint {
    let offset = originalTypingOffset(elapsed: elapsed)
    let scale = max(1, backingScale)
    return CGPoint(x: (offset.x * size.width / 192 * scale).rounded() / scale,
                   y: (-offset.y * size.height / 208 * scale).rounded() / scale)
}

struct SpritePlacement {
    var scale: CGFloat = 1
    // Offset measured downwards from the top of the 384×416 source canvas.
    var top: CGFloat = 0
}

func alignedPlacement(row: Int, variant: Int?, frame: Int) -> SpritePlacement {
    func smooth(_ value: CGFloat) -> CGFloat {
        let t = max(0, min(1, value))
        return t * t * (3 - 2 * t)
    }
    if variant == 0 { return SpritePlacement(scale: 1.03, top: 387 * (1 - 1.03)) }
    if variant == 2 {
        // Preserve a constant character scale while leaving room for the jump.
        let f = CGFloat(frame)
        return SpritePlacement(scale: 1.03,
            top: -22 + 18 * smooth((f - 48) / 24) - 18 * smooth((f - 132) / 18))
    }
    guard variant == nil else { return SpritePlacement() }
    if row == 7 || row == 5 || row == 6 { return SpritePlacement(top: 10) }
    if row == 8 { return SpritePlacement(top: 10 * (1 - smooth((CGFloat(frame) - 132) / 60))) }
    if row == 1 { return SpritePlacement(top: 10) }
    if row == 2 { return SpritePlacement(top: 7) }
    return SpritePlacement()
}

final class PetView:NSView {
    private let sprites = SpriteRows()
    private let spriteLayer = CALayer()
    var row = 0, frameIndex = 0, look:Int? = nil
    var tracking:NSTrackingArea?
    var hovered = false, dragging = false
    var initialPoint = NSPoint.zero, windowOrigin = NSPoint.zero, lastDragX:CGFloat = 0
    var timer:Timer?
    private var frameDeadline: TimeInterval = 0
    private var actionStarted: TimeInterval = 0
    private var runStarted: TimeInterval = 0
    private var greetingStarted: TimeInterval = 0
    private var celebrationStarted: TimeInterval = 0
    private var workStateStarted: TimeInterval = 0
    private var workInitialFrame = 102
    private var greetingCooldownUntil: TimeInterval = 0
    private var greetingCooldownTimer: Timer?
    var isGreetingCoolingDown: Bool { ProcessInfo.processInfo.systemUptime < greetingCooldownUntil }
    private var actionFrameCount = 145
    private var singingEndStarted: TimeInterval?
    private var singingEndFrame = 0
    var isEndingSong: Bool { idleVariant == idleLabels.count && singingEndStarted != nil }
    var isReturningCarry: Bool { false }
    var idleVariant: Int?
    var nextIdle = Date().addingTimeInterval(Double.random(in: 20...45))
    var reduceMotion = false { didSet { if reduceMotion { idleVariant = nil; sprites.releaseIdle() }; frameIndex = row == 7 ? 102 : ((row == 5 || row == 6) ? 35 : 0); needsDisplay = true; schedule() } }
    var onClick:(()->Void)?
    var onRelease:(()->Void)?
    override var isFlipped:Bool { true }
    override init(frame:NSRect) {
        super.init(frame:frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.isGeometryFlipped = false
        spriteLayer.contentsGravity = .resize
        spriteLayer.magnificationFilter = .linear
        spriteLayer.minificationFilter = .linear
        layer?.addSublayer(spriteLayer)
        schedule()
    }
    override var wantsUpdateLayer: Bool { true }
    required init?(coder:NSCoder) { fatalError() }
    func setRow(_ value:Int) {
        guard value != 4 || !isGreetingCoolingDown else { return }
        if row != value || (value != 0 && idleVariant != nil) {
            let previousRow = row
            idleVariant = nil; sprites.releaseIdle(); row = value; frameIndex = 0; look = nil
            if value == 1 || value == 2 {
                runStarted = ProcessInfo.processInfo.systemUptime
                frameIndex = value == 1 ? 52 : 87
                sprites.prefetchAction("run", frame: frameIndex)
            }
            if value == 5 || value == 6 || value == 7 {
                workStateStarted = ProcessInfo.processInfo.systemUptime
                workInitialFrame = [5, 6, 7, 8].contains(previousRow) ? 102 : 0
                frameIndex = value == 7 ? (reduceMotion ? 102 : workInitialFrame) : 35
                sprites.prefetchAction(value == 7 ? "work" : "blocked", frame: frameIndex)
            }
            if value == 4 {
                greetingStarted = ProcessInfo.processInfo.systemUptime
                sprites.prefetchAction("greet", frame: 0)
            }
            if value == 8 {
                celebrationStarted = ProcessInfo.processInfo.systemUptime
                sprites.prefetchAction("celebrate", frame: 0)
            }
            needsDisplay = true; schedule()
        }
    }
    private func beginAction(_ variant: Int) {
        guard !reduceMotion else { return }
        singingEndStarted = nil
        row = 0; idleVariant = variant; frameIndex = 0; look = nil
        actionStarted = ProcessInfo.processInfo.systemUptime
        sprites.prefetchAction(actionName(variant), frame: 0)
        needsDisplay = true; schedule()
    }
    private func actionName(_ variant: Int) -> String {
        if variant == idleLabels.count + 1 { return "lift" }
        if variant == idleLabels.count { return "sing" }
        return ["tail", "hair", "happy"][variant]
    }
    func maybeIdle() {
        guard !reduceMotion, idleVariant == nil, row == 0, !hovered, !dragging, Date() >= nextIdle else { return }
        playIdleVariant(Int.random(in: 0..<idleLabels.count))
    }
    func playIdleVariant(_ value: Int) {
        guard idleLabels.indices.contains(value) else { return }
        beginAction(value)
    }
    func playCarry() { beginAction(idleLabels.count + 1) }
    func stopCarry() {
        // Drag release starts a fresh two-second greeting cooldown, including
        // when the system's Reduce Motion setting suppresses the lift sprite.
        greetingCooldownUntil = ProcessInfo.processInfo.systemUptime + 2
        greetingCooldownTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in
            guard let self, !self.isGreetingCoolingDown, !self.dragging, self.hovered else { return }
            self.onRelease?()
        }
        RunLoop.main.add(timer, forMode: .common)
        greetingCooldownTimer = timer
        if idleVariant == idleLabels.count + 1 { finishAction() }
        else if row == 4 { setRow(0) }
    }
    func playSinging() {
        if idleVariant == idleLabels.count {
            if singingEndStarted != nil {
                // Resume the singing loop if music starts again during the outro.
                let resumeFrame = min(frameIndex, 147)
                actionStarted = ProcessInfo.processInfo.systemUptime - Double(resumeFrame) / 24
                singingEndStarted = nil
            }
            return
        }
        beginAction(idleLabels.count)
    }
    func stopSinging() {
        guard idleVariant == idleLabels.count, singingEndStarted == nil else { return }
        singingEndFrame = frameIndex
        singingEndStarted = ProcessInfo.processInfo.systemUptime
    }
    private func finishAction() {
        singingEndStarted = nil
        idleVariant = nil; sprites.releaseIdle(); frameIndex = 0
        nextIdle = Date().addingTimeInterval(Double.random(in: 20...45))
        needsDisplay = true; schedule()
    }
    func schedule(reset: Bool = true) {
        timer?.invalidate()
        guard !reduceMotion else { return }
        let interval = stepInterval()
        let now = ProcessInfo.processInfo.systemUptime
        if reset || frameDeadline <= 0 { frameDeadline = now + interval }
        let tick = Timer(timeInterval: max(0.008, frameDeadline - now), repeats: false) { [weak self] _ in
            guard let s = self else { return }
            if let variant = s.idleVariant {
                let elapsed = max(0, ProcessInfo.processInfo.systemUptime - s.actionStarted)
                let ordinal = Int(elapsed * 24)
                let frameCount = (variant == 2 || variant == idleLabels.count) ? 241 : (variant == 1 ? 169 : s.actionFrameCount)
                if variant == idleLabels.count, let ending = s.singingEndStarted {
                    let endingFrame = s.singingEndFrame + Int(max(0, ProcessInfo.processInfo.systemUptime - ending) * 24)
                    if endingFrame >= frameCount { s.finishAction(); s.onRelease?(); return }
                    s.frameIndex = endingFrame
                    s.sprites.prefetchAction("sing", frame: min(frameCount - 1, endingFrame + 4))
                } else {
                if variant < idleLabels.count && ordinal >= frameCount {
                    s.finishAction(); s.onRelease?(); return
                }
                // The intro is played once; only the stable portion repeats.
                let loopStart = 81
                let loopEnd = variant == idleLabels.count + 1 ? 140 : 147
                if variant < idleLabels.count { s.frameIndex = min(ordinal, frameCount - 1) }
                else if ordinal > loopEnd { s.frameIndex = loopStart + (ordinal - loopStart) % (loopEnd - loopStart + 1) }
                else { s.frameIndex = min(ordinal, frameCount - 1) }
                s.sprites.prefetchAction(s.actionName(variant), frame: min(frameCount - 1, s.frameIndex + 4))
                if variant >= idleLabels.count && s.frameIndex >= loopEnd - 8 {
                    s.sprites.prefetchAction(s.actionName(variant), frame: loopStart)
                }
                }
            } else if s.row == 1 || s.row == 2 {
                // Both running directions use forward-only portions of the source.
                let start = s.row == 1 ? 52 : 87, end = s.row == 1 ? 64 : 103
                let length = end - start + 1
                let tick = Int(max(0, ProcessInfo.processInfo.systemUptime - s.runStarted) * 24)
                s.frameIndex = start + tick % length
                s.sprites.prefetchAction("run", frame: start + (tick + 4) % length)
            } else if s.row == 7 {
                let tick = Int(max(0, ProcessInfo.processInfo.systemUptime - s.workStateStarted) * 24)
                let ordinal = s.workInitialFrame + tick
                s.frameIndex = ordinal <= 138 ? ordinal : 102 + (ordinal - 102) % 37
                let ahead = ordinal + 4
                s.sprites.prefetchAction("work", frame: ahead <= 138 ? ahead : 102 + (ahead - 102) % 37)
            } else if s.row == 5 || s.row == 6 {
                let tick = Int(max(0, ProcessInfo.processInfo.systemUptime - s.workStateStarted) * 24)
                s.frameIndex = tick <= 96 ? 35 + tick : 107 + (tick - 72) % 25
                let ahead = tick + 4
                let next = ahead <= 96 ? 35 + ahead : 107 + (ahead - 72) % 25
                s.sprites.prefetchAction("blocked", frame: next)
            } else if s.row == 4 {
                s.frameIndex = min(240, Int(max(0, ProcessInfo.processInfo.systemUptime - s.greetingStarted) * 24))
                s.sprites.prefetchAction("greet", frame: min(240, s.frameIndex + 4))
            } else if s.row == 8 {
                s.frameIndex = min(240, Int(max(0, ProcessInfo.processInfo.systemUptime - s.celebrationStarted) * 24))
                s.sprites.prefetchAction("celebrate", frame: min(240, s.frameIndex + 4))
            } else if s.row == 0 {
                s.frameIndex = Int(ProcessInfo.processInfo.systemUptime * 24) % 241
                s.sprites.prefetchAction("idle", frame: (s.frameIndex + 4) % 241)
            } else { s.frameIndex = (s.frameIndex+1) % counts[s.row] }
            s.needsDisplay = true
            if (s.row == 4 || s.row == 8) && s.frameIndex == 240 { s.frameDeadline = 0; return }
            let next = s.stepInterval()
            s.frameDeadline += next
            if s.frameDeadline < ProcessInfo.processInfo.systemUptime - 0.5 { s.frameDeadline = ProcessInfo.processInfo.systemUptime + next }
            s.schedule(reset: false)
        }
        RunLoop.main.add(tick, forMode: .common); timer = tick
    }
    private func stepInterval() -> TimeInterval {
        if idleVariant != nil || [0,1,2,4,5,6,7,8].contains(row) { return 1.0 / 24.0 }
        return times[row][frameIndex % counts[row]]
    }
    // Align both edges in the actual backing coordinate space. A fractional
    // window size otherwise resamples an already-resampled transparent sprite.
    func pixelAlignedSpriteRect(_ rect: CGRect) -> CGRect {
        guard window != nil else { return rect }
        let viewRect = NSRect(x: rect.minX, y: bounds.height - rect.maxY,
                              width: rect.width, height: rect.height)
        let backing = convertToBacking(viewRect)
        let x0 = backing.minX.rounded(), y0 = backing.minY.rounded()
        let x1 = backing.maxX.rounded(), y1 = backing.maxY.rounded()
        guard x1 > x0, y1 > y0 else { return rect }
        let aligned = convertFromBacking(NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        return CGRect(x: aligned.minX, y: bounds.height - aligned.maxY,
                      width: aligned.width, height: aligned.height)
    }
    override func updateLayer() {
        let r = look.map { 9 + $0 / 8 } ?? row
        let c = look.map { $0 % 8 } ?? frameIndex
        let image: CGImage?
        if let variant = idleVariant { image = sprites.actionFrame(actionName(variant), frame: frameIndex) }
        else if row == 4 && look == nil { image = sprites.actionFrame("greet", frame: frameIndex) }
        else if row == 7 && look == nil { image = sprites.actionFrame("work", frame: frameIndex) }
        else if (row == 5 || row == 6) && look == nil { image = sprites.actionFrame("blocked", frame: frameIndex) }
        else if row == 8 && look == nil { image = sprites.actionFrame("celebrate", frame: frameIndex) }
        else if row == 0 && look == nil { image = sprites.actionFrame("idle", frame: frameIndex) }
        else if (row == 1 || row == 2) && look == nil { image = sprites.actionFrame("run", frame: frameIndex) }
        else { image = sprites.frame(row: r, column: c) }
        guard let crop = image else { return }
        var offset = CGPoint.zero
        if row == 7 && frameIndex >= 48 && idleVariant == nil && look == nil && !reduceMotion {
            offset = pixelAlignedTypingOffset(elapsed: ProcessInfo.processInfo.systemUptime - workStateStarted,
                                             size: bounds.size, backingScale: window?.backingScaleFactor ?? 1)
        }
        let placement = look == nil ? alignedPlacement(row: row, variant: idleVariant, frame: frameIndex) : SpritePlacement()
        let x = (192 - 192 * placement.scale) * bounds.width / 384
        let y = (416 - placement.top - 416 * placement.scale) * bounds.height / 416
        let destination = CGRect(x:x, y:y, width:bounds.width * placement.scale, height:bounds.height * placement.scale)
        let aligned = pixelAlignedSpriteRect(destination)
        // NSView is flipped; convert the original drawing coordinates into
        // the backing layer's coordinates without moving the character.
        let layerFrame = CGRect(x: aligned.minX + offset.x,
                                y: bounds.height - aligned.maxY - offset.y,
                                width: aligned.width, height: aligned.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        spriteLayer.frame = layerFrame
        spriteLayer.contentsScale = window?.backingScaleFactor ?? 1
        spriteLayer.contents = crop
        CATransaction.commit()
    }
    override func updateTrackingAreas() {
        if let tracking = tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(t); tracking=t
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event:NSEvent) {
        (NSApp.delegate as? AppDelegate)?.stopWander(); hovered=true
        if !dragging {
            if isGreetingCoolingDown || (NSApp.delegate as? AppDelegate)?.hasPendingReview == true { onRelease?() }
            else { setRow(4) }
        }
    }
    override func mouseExited(with event:NSEvent) { hovered=false; if !dragging { onRelease?() } }
    override func mouseDown(with event:NSEvent) { (NSApp.delegate as? AppDelegate)?.stopWander(); sprites.prefetchAction("lift", frame: 0); initialPoint=NSEvent.mouseLocation; windowOrigin=window?.frame.origin ?? .zero; lastDragX=initialPoint.x; dragging=false }
    override func mouseDragged(with event:NSEvent) {
        let p=NSEvent.mouseLocation, dx=p.x-initialPoint.x, dy=p.y-initialPoint.y
        if hypot(dx,dy)>4 && !dragging { dragging=true; playCarry() }
        guard dragging else { return }
        let movement = p.x-lastDragX
        if abs(movement)>1 { lastDragX=p.x }
        (NSApp.delegate as? AppDelegate)?.closePanelForDrag()
        window?.setFrameOrigin(NSPoint(x:windowOrigin.x+dx,y:windowOrigin.y+dy))
    }
    override func mouseUp(with event:NSEvent) {
        if dragging { dragging=false; stopCarry(); (NSApp.delegate as? AppDelegate)?.finishDrag(); onRelease?() }
        else { onClick?() }
    }
    override func rightMouseDown(with event:NSEvent) { if let d = NSApp.delegate as? AppDelegate { d.showMenu(event:event,view:self) } }
}

private struct TrackedQuota {
    var baseline: QuotaSnapshot?
    var endedAt: Int64?
}

private struct CompletedQuota {
    let turnID: String
    let snapshot: QuotaSnapshot?
    let estimated: Int?
    let isLoading: Bool
    let isStale: Bool
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let codexID = "com.openai.codex"
    var reader = ActivityReader.local()
    var sourceRevision = 0
    let readQueue = DispatchQueue(label: "local.codex.gptdragon.activity", qos: .utility)
    var window: FloatingGlassPanel!, pet: PetView!, root: HoverRegion!, bar: NSView!
    var railContent: NSView!, railButtons: RailButtons!, railHandle: NSButton!
    var railMotion: Timer?
    var headGlass: NSView!, head: ProcessCapsule!, featuredID: String?
    var headBack: TaskStackBack!, headBackGlass: NSView!
    private var headStacked = false
    var composer: InlineComposer?, railEditor: InlineComposer?
    var composerMode: InlineComposer.Mode = .task
    var chatDraft = "", chatSubmitted = ""
    var lastChatReply: String?
    var chatBubble: FloatingGlassPanel?
    private weak var chatBubbleText: NSTextView?
    private var chatBubbleDismissed = false
    var expanded = false, collapseTimer: Timer?
    var holdCollapsedUntilExit = false
    var panel: FloatingGlassPanel?
    var panelController: ActivityPanel?
    private var tasksExpanded = false
    private let extraTaskScroll = NSScrollView()
    private let extraTaskDocument = NSView()
    private var extraTaskCards: [String: (ProcessCapsule, NSView)] = [:]
    var chatController: PetChat?
    var reviewPanel: ReviewPanel?
    private var reviewGlass: NSView?
    private var shownReviewKeys: [String] = []
    private var reviewReveal: (start: TimeInterval, timer: Timer)?
    private var reviewDismiss: Timer?
    private var shownSuccessRevision = 0
    let reviewBridge = ReviewBridge()
    private var lastReviewConnectAttempt: Date?
    var bell: NSButton!, pencil: NSButton!
    private var quotaButton: QuotaButton!
    private let updater = MainActor.assumeIsolated { GitHubUpdater() }
    private var updateButton: NSButton!
    private var expandedRailWidth: CGFloat { updateButton?.isHidden == false ? 118 : 91 }
    private var completionTurnShown: String?
    private var completionCard = false
    private let quotaStore = QuotaStore()
    private let deepSeekBalance = DeepSeekBalanceStore()
    private let quotaDisplayKey = "quotaDisplayProviderV1"
    private var showsDeepSeekBalance: Bool {
        UserDefaults.standard.string(forKey: quotaDisplayKey) == "deepseek"
    }
    private var trackedQuotas: [String: TrackedQuota] = [:]
    private var completedQuota: CompletedQuota?
    var poll: Timer?, cursorPoll: Timer?
    var isReading = false, running = false, available = false
    var activity = ActivitySnapshot(chats: [])
    var lastRead: Date?, outcome: (row: Int, time: Date, chat: ChatActivity)?
    var unread: Set<String> = []
    var draft = ""
    var preview: (row: Int, until: Date)?
    var follow = false, controls = true, clearPanel = true, size: CGFloat = 160
    var stateText = "正在读取本机活动"
    let musicMonitor = MusicMonitor()
    private var optionsPanel: FloatingGlassPanel?
    private var optionsPage: Int?
    private var wanderTimer: Timer?
    private var wanderNext = Date().addingTimeInterval(Double.random(in: 45...90))
    private var wanderEnabled = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        follow = defaults.bool(forKey: "follow")
        wanderEnabled = defaults.object(forKey: "wanderEnabled") as? Bool ?? true
        if let path = defaults.string(forKey: "activityFolder"), path.hasPrefix("/") {
            reader = .local(override: URL(fileURLWithPath: path, isDirectory: true))
        }
        controls = defaults.object(forKey: "controls") as? Bool ?? true
        clearPanel = defaults.object(forKey: "clearPanel") as? Bool ?? true
        let savedSize = defaults.double(forKey: "size")
        if savedSize.isFinite && (120...240).contains(savedSize) { size = CGFloat(savedSize) }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let dimensions = layoutSize
        let saved = defaults.array(forKey: "position") as? [Double]
        var origin = NSPoint(x: screen.maxX - dimensions.width - 40, y: screen.minY + 40)
        if let p = saved, p.count == 2,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(NSRect(origin: NSPoint(x: p[0], y: p[1]), size: dimensions)) }) {
            origin = NSPoint(x: p[0], y: p[1])
        }
        window = FloatingGlassPanel(contentRect: NSRect(origin: origin, size: dimensions), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.keyAllowed = false
        window.delegate = self
        window.onCancel = { [weak self] in self?.closeComposer() }
        window.onDraftSubmit = { [weak self] in self?.composer?.submit() }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        root = HoverRegion()
        root.didEnter = { [weak self] in
            guard let self, !self.holdCollapsedUntilExit else { return }
            self.collapseTimer?.invalidate()
            self.setExpanded(true)
        }
        root.didExit = { [weak self] in
            self?.holdCollapsedUntilExit = false
            self?.scheduleCollapse()
        }
        window.contentView = root
        pet = PetView(frame: .zero)
        pet.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        pet.onClick = { [weak self] in
            guard let self else { return }
            if self.composer != nil { self.closeComposer() }
            else if !self.controls { self.toggleControls() }
            else if !self.expanded { self.setExpanded(true) }
            else { self.showActivity() }
        }
        pet.onRelease = { [weak self] in self?.refreshAnimation() }
        root.addSubview(pet)
        buildBar(in: root)
        head = ProcessCapsule(frame: .zero)
        head.onOpen = { [weak self] in
            guard let self, let id = self.featuredID else { return }
            if self.headStacked { self.showTaskPicker(); return }
            if self.reviewBridge.reviews.contains(where: { $0.thread == id }) { self.presentReview(automatically: false, thread: id) }
            else if let link = CodexLinks.chat(id) { self.handOff(link) }
        }
        head.onShowTasks = { [weak self] in self?.showTaskPicker() }
        headBack = TaskStackBack(frame: .zero)
        headBack.onClick = { [weak self] in self?.showTaskPicker() }
        headBackGlass = makeGlass(content: NSView(), radius: 19, clear: clearPanel, textSurface: true, tintStrength: 0)
        headBackGlass.autoresizingMask = [.width, .height]
        headBack.addSubview(headBackGlass)
        headBack.isHidden = true
        root.addSubview(headBack)
        headGlass = makeGlass(content: head, radius: 19, clear: clearPanel, textSurface: true, tintStrength: 0)
        headGlass.isHidden = true
        extraTaskScroll.drawsBackground = false
        extraTaskScroll.hasVerticalScroller = true
        extraTaskScroll.autohidesScrollers = true
        extraTaskScroll.scrollerStyle = .overlay
        extraTaskScroll.documentView = extraTaskDocument
        extraTaskScroll.isHidden = true
        root.addSubview(extraTaskScroll)
        root.addSubview(headGlass)
        layoutWindow()
        window.orderFrontRegardless()
        updateIndicators()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkStatus() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        poll = t
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(updateMotion), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
        reviewBridge.didChange = { [weak self] in self?.reviewChanged() }
        quotaStore.didChange = { [weak self] in
            self?.updateQuotaButton()
            if self?.head != nil { self?.updateProgress() }
        }
        deepSeekBalance.didChange = { [weak self] in self?.updateQuotaButton() }
        updateQuotaButton()
        quotaStore.refresh()
        if showsDeepSeekBalance { deepSeekBalance.refresh() }
        musicMonitor.didChange = { [weak self] _ in self?.refreshAnimation() }
        if defaults.bool(forKey: "musicSingingEnabled") { musicMonitor.start() }
        updater.changed = { [weak self] state in self?.updateDownloadButton(state) }
        updater.checked = { [weak self] message in
            self?.updateButton.toolTip = message
            self?.updateButton.setAccessibilityLabel(message)
        }
        updater.start()
        configureCursorTimer()
        checkStatus()
    }

    private var layoutSize: NSSize { NSSize(width: size, height: size * 208 / 192 + (controls ? 31 : 0)) }

    private var petAnchor: NSPoint {
        if pet.frame.width > 0 {
            return NSPoint(x: window.frame.minX + pet.frame.midX, y: window.frame.minY + pet.frame.minY)
        }
        return NSPoint(x: window.frame.midX, y: window.frame.minY + (controls ? 31 : 0))
    }

    private func layoutWindow(animateRail: Bool = false) {
        let anchor = petAnchor
        let animate = window.isVisible && !pet.reduceMotion && (animateRail || railMotion != nil)
        let old = window.frame
        let oldRail = bar.frame.offsetBy(dx: old.minX, dy: old.minY)
        let composerHeight = composer?.preferredHeight ?? 0
        let restHeight: CGFloat = controls ? 31 : 0
        // Keep room for the outgoing surface until it finishes shrinking.
        let reservedHeight: CGFloat = animate && railEditor != nil ? bar.frame.height + 3 : 0
        let bottom = max(restHeight, composerHeight > 0 ? composerHeight + 3 : 0, reservedHeight)
        let petHeight = size * 208 / 192
        let display = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let availableAbove = max(0, display.maxY - anchor.y - petHeight - 44)
        let extraHeight = tasksExpanded ? min(CGFloat(extraTaskCards.count) * 44, max(44, availableAbove)) : 0
        let headHeight: CGFloat = completionCard ? 54 : 38
        let stageHeight: CGFloat = featuredID == nil ? 0 : headHeight + (headStacked ? 9 : 2) + (availableAbove >= 44 ? extraHeight : 0)
        let width = max(size, composer != nil || (animate && railEditor != nil) ? 334 : 0, featuredID == nil ? 0 : (headStacked ? 228 : 220))
        let dimensions = NSSize(width: width, height: petHeight + bottom + stageHeight)
        let origin = constrained(NSPoint(x: anchor.x - width / 2, y: anchor.y - bottom), size: dimensions)
        let center = min(max(anchor.x - origin.x, size / 2), width - size / 2)
        let frame = NSRect(origin: origin, size: dimensions)
        if old != frame { window.setFrame(frame, display: false) }
        pet.frame = NSRect(x: center - size / 2, y: bottom, width: size, height: petHeight)
        headGlass.frame = NSRect(x: min(max(center - 108, 0), width - 216), y: bottom + petHeight + 1, width: 216, height: headHeight)
        headBack.frame = headGlass.frame.offsetBy(dx: 5, dy: 6)
        headBackGlass.frame = headBack.bounds
        let scrollY = availableAbove < 44 ? headGlass.frame.minY - extraHeight - 5 : headGlass.frame.maxY + 5
        extraTaskScroll.frame = NSRect(x: headGlass.frame.minX, y: scrollY, width: 216, height: extraHeight)
        extraTaskDocument.frame = NSRect(x: 0, y: 0, width: 216, height: CGFloat(extraTaskCards.count) * 44)
        syncHeadVisibility()
        positionReviewCard()
        positionChatBubble()
        repositionOptionsPanel()
        if animate, old != frame {
            // A larger input window changes local coordinates, not the starting
            // screen position of the visible capsule.
            bar.frame = oldRail.offsetBy(dx: -origin.x, dy: -origin.y)
        }
        layoutBar(center: center, bottom: bottom, animate: animate)
    }

    private func syncHeadVisibility() {
        let hidden = featuredID == nil || reviewPanel != nil || chatBubble != nil
        headGlass?.isHidden = hidden
        headBack?.isHidden = hidden || !headStacked || tasksExpanded
        extraTaskScroll.isHidden = hidden || !headStacked || !tasksExpanded
    }

    private func layoutBar(center: CGFloat, bottom: CGFloat, animate: Bool) {
        railMotion?.invalidate()
        railMotion = nil
        let typing = composer != nil
        let visible = controls || typing
        let showButtons = controls && expanded && !typing
        let baseline = max(0, bottom - 31)
        let target: NSRect
        if let composer {
            target = NSRect(x: 1, y: bottom - composer.preferredHeight - 2,
                            width: window.frame.width - 2, height: composer.preferredHeight)
        } else if showButtons {
            target = NSRect(x: center - expandedRailWidth / 2, y: baseline + 1, width: expandedRailWidth, height: 28)
        } else {
            target = NSRect(x: center - 11, y: baseline + 8, width: 22, height: 7)
        }

        let start = bar.frame
        let oldButtons = railButtons.alphaValue
        let oldEditor = railEditor?.alphaValue ?? 0
        let buttonsAlpha: CGFloat = showButtons ? 1 : 0
        let editorAlpha: CGFloat = typing ? 1 : 0
        railButtons.acceptsClicks = showButtons
        quotaButton?.hoverEnabled = showButtons
        railEditor?.acceptsClicks = typing
        railHandle.isHidden = !visible || showButtons || typing
        railHandle.frame = NSRect(x: target.midX - 17, y: baseline + 1, width: 34, height: 23)

        if !visible || !animate || start.isEmpty || (start == target && oldButtons == buttonsAlpha && oldEditor == editorAlpha) {
            bar.isHidden = !visible
            applyRail(target, buttons: buttonsAlpha, editor: editorAlpha)
            removeRetiredEditor()
            return
        }

        bar.isHidden = false
        let epoch = ProcessInfo.processInfo.systemUptime
        let duration: TimeInterval = typing || oldEditor > 0 ? 0.27 : showButtons ? 0.20 : 0.19
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] tick in
            guard let self else { tick.invalidate(); return }
            let t = min(1, CGFloat((ProcessInfo.processInfo.systemUptime - epoch) / duration))
            let eased = t * t * (3 - 2 * t)
            func mix(_ a: CGFloat, _ b: CGFloat, _ p: CGFloat) -> CGFloat { a + (b - a) * p }
            func fade(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
                // Fade old controls before they clip; reveal new controls as the surface opens.
                let p = to < from ? min(1, t / 0.55) : max(0, min(1, (t - 0.25) / 0.65))
                return mix(from, to, p * p * (3 - 2 * p))
            }
            let current = NSRect(x: mix(start.minX, target.minX, eased), y: mix(start.minY, target.minY, eased),
                                 width: mix(start.width, target.width, eased), height: mix(start.height, target.height, eased))
            self.applyRail(current, buttons: fade(oldButtons, buttonsAlpha), editor: fade(oldEditor, editorAlpha))
            if t >= 1 {
                tick.invalidate()
                self.railMotion = nil
                self.removeRetiredEditor()
                self.layoutWindow()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        railMotion = timer
    }

    private func applyRail(_ rect: NSRect, buttons: CGFloat, editor: CGFloat) {
        if bar.frame != rect { bar.frame = rect }
        setGlassRadius(bar, radius: min(19, rect.height / 2))
        railButtons.frame = NSRect(x: (rect.width - expandedRailWidth) / 2, y: (rect.height - 28) / 2,
                                  width: expandedRailWidth, height: 28)
        railButtons.alphaValue = buttons
        railButtons.isHidden = buttons <= 0
        if let view = railEditor {
            let width: CGFloat = 332
            let height = view.preferredHeight
            let editorFrame = NSRect(x: (rect.width - width) / 2, y: (rect.height - height) / 2, width: width, height: height)
            if view.frame != editorFrame { view.frame = editorFrame }
            view.alphaValue = editor
        }
    }

    private func removeRetiredEditor() {
        if composer == nil {
            railEditor?.removeFromSuperview()
            railEditor = nil
        }
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        if composer == nil { layoutWindow(animateRail: true) }
    }

    private func scheduleCollapse() {
        collapseTimer?.invalidate()
        let timer = Timer(timeInterval: 0.32, repeats: false) { [weak self] _ in
            guard let self, self.composer == nil, self.panel?.isVisible != true, !self.pet.dragging,
                  !self.window.frame.contains(NSEvent.mouseLocation) else { return }
            self.setExpanded(false)
        }
        RunLoop.main.add(timer, forMode: .common)
        collapseTimer = timer
    }

    @objc private func expandControls() {
        holdCollapsedUntilExit = false
        collapseTimer?.invalidate()
        setExpanded(true)
    }

    private func constrained(_ p: NSPoint, size: NSSize) -> NSPoint {
        let point = NSPoint(x: p.x + size.width / 2, y: p.y + size.height / 2)
        guard let display = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return p }
        let visible = display.visibleFrame
        return NSPoint(x: min(max(p.x, visible.minX), visible.maxX - size.width),
                       y: min(max(p.y, visible.minY), visible.maxY - size.height))
    }

    private func buildBar(in root: NSView) {
        railContent = NSView()
        railContent.wantsLayer = true
        railContent.layer?.masksToBounds = true
        let buttons = RailButtons(frame: NSRect(x: 0, y: 0, width: 91, height: 28))
        railButtons = buttons
        railContent.addSubview(buttons)
        bar = makeGlass(content: railContent, radius: 14, clear: clearPanel, textSurface: true, tintStrength: 0)
        root.addSubview(bar)
        railHandle = NSButton(title: "", target: self, action: #selector(expandControls))
        railHandle.isBordered = false
        railHandle.setAccessibilityLabel("展开桌宠控制栏")
        railHandle.toolTip = "展开桌宠控制栏"
        root.addSubview(railHandle)
        func icon(_ symbol: String, _ label: String, _ action: Selector, _ index: Int) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                                  target: self, action: action)
            button.isBordered = false
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.frame = NSRect(x: 5 + 27 * index, y: 2, width: 27, height: 24)
            buttons.addSubview(button)
            return button
        }
        pencil = icon("square.and.pencil", "快捷输入", #selector(showDraft), 0)
        quotaButton = QuotaButton(frame: NSRect(x: 32, y: 2, width: 27, height: 24))
        quotaButton.target = self
        quotaButton.action = #selector(refreshQuota)
        quotaButton.onHover = { [weak self] in
            guard let self else { return }
            if self.showsDeepSeekBalance {
                if self.deepSeekBalance.snapshot.map({ Date().timeIntervalSince($0.observedAt) >= 60 }) ?? true {
                    self.deepSeekBalance.refresh()
                }
            } else if self.quotaStore.snapshot.map({ Date().timeIntervalSince($0.observedAt) >= 60 }) ?? true {
                self.quotaStore.refresh()
            }
        }
        buttons.addSubview(quotaButton)
        bell = icon("bell", "Codex 活动", #selector(showActivity), 2)
        updateButton = icon("arrow.down.circle", "下载新版", #selector(downloadUpdate), 3)
        updateButton.isHidden = true
    }

    private func updateDownloadButton(_ state: GitHubUpdater.State) {
        let visible = state.label != nil
        let changed = updateButton.isHidden == visible
        updateButton.isHidden = !visible
        updateButton.isEnabled = state.acceptsClick
        updateButton.toolTip = state.label
        updateButton.setAccessibilityLabel(state.label)
        let symbol: String
        switch state {
        case .downloaded: symbol = "folder"
        case .retry: symbol = "exclamationmark.circle"
        default: symbol = "arrow.down.circle"
        }
        updateButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: state.label)
        if changed, expanded, composer == nil { layoutWindow(animateRail: true) }
    }

    @MainActor @objc private func downloadUpdate() { updater.activate() }
    @MainActor @objc private func checkForUpdate() { updater.check(manual: true) }
    @objc private func showProject() {
        NSWorkspace.shared.open(URL(string: "https://github.com/\(DownloadRelease.repository)")!)
    }

    func checkStatus() {
        guard !isReading else { return }
        isReading = true
        let stamp = Date()
        let process = codexProcess
        let launchedAt = process?.launchDate ?? (process == nil ? nil : stamp.addingTimeInterval(-7200))
        let revision = sourceRevision
        readQueue.async { [weak self, reader] in
            let result = Result { try reader.read(launchedAt: launchedAt) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sourceRevision == revision else { return }
                self.apply(result, stamp: stamp, running: process != nil)
            }
        }
    }

    private func apply(_ result: Result<ActivitySnapshot, Error>, stamp: Date, running: Bool) {
        isReading = false
        let wasRunning = self.running
        self.running = running
        let previous = activity
        let previousLabel = stateText
        switch result {
        case .success(var snapshot):
            if !snapshot.catalogAvailable {
                let names = Dictionary(uniqueKeysWithValues: previous.chats.map { ($0.id, $0.title) })
                for index in snapshot.chats.indices {
                    let row = snapshot.chats[index]
                    if let name = names[row.id] {
                        snapshot.chats[index] = ChatActivity(id: row.id, title: name, turn: row.turn, stage: row.stage)
                    }
                }
                let visibleIDs = Set(snapshot.chats.map(\.id))
                snapshot.chats.append(contentsOf: previous.chats.filter { !visibleIDs.contains($0.id) }.map {
                    ChatActivity(id: $0.id, title: $0.title, turn: nil)
                })
            }
            if snapshot.turnsAvailable && running {
                trackStartingTurns(snapshot.working, previously: previous.working)
            }
            if snapshot.turnsAvailable, running, wasRunning, let lastRead {
                let since = max(Int64(lastRead.timeIntervalSince1970) - 1, Int64(stamp.timeIntervalSince1970) - 120)
                let old = Dictionary(uniqueKeysWithValues: previous.chats.map { ($0.id, $0.turn) })
                let ended = snapshot.chats.compactMap { chat -> Turn? in
                    guard let turn = chat.turn, turn.status != .inProgress, turn.ended >= since,
                          old[chat.id].flatMap({ $0 }) != turn else { return nil }
                    return turn
                }
                if !ended.isEmpty {
                    if panelController?.page != .activity || panel?.isVisible != true {
                        unread.formUnion(ended.map(\.id))
                        if unread.count > 99 { unread = Set(unread.prefix(99)) }
                    }
                    let terminal = ended.first(where: { $0.status != .completed }) ?? ended[0]
                    for turn in ended where turn.id != terminal.id || turn.status != .completed {
                        trackedQuotas.removeValue(forKey: turn.id)
                    }
                    if let chat = snapshot.chats.first(where: { $0.turn?.id == terminal.id }) {
                        outcome = (terminal.status == .completed ? 8 : 5, stamp, chat)
                        if terminal.status == .completed { trackCompletedTurn(terminal) }
                    }
                }
            }
            available = snapshot.turnsAvailable
            activity = snapshot
            if snapshot.turnsAvailable { lastRead = stamp }
        case .failure:
            available = false
        }
        if !available {
            stateText = activity.chats.isEmpty ? "读不到本机活动 · 可选择数据文件夹" : "实时状态暂不可读 · 显示最近对话"
        } else if !running { stateText = "Codex 未运行 · 显示最近对话" }
        else if !activity.catalogAvailable { stateText = "标题暂不可读 · 显示任务状态" }
        else if activity.working.isEmpty { stateText = "暂无进行中的任务" }
        else { stateText = "\(activity.working.count) 个任务进行中" }
        // Subscribe to a few recent chats before the turn projection catches up.
        if running, case .success = result {
            let activeIDs = activity.working.map(\.id)
            let activeSet = Set(activeIDs)
            let recent = activity.chats.lazy.filter { !activeSet.contains($0.id) }.prefix(2).map(\.id)
            reviewBridge.watch(activeIDs + recent)
        } else if !running {
            reviewBridge.watch([])
        }
        maintainReviewConnection()
        updateProgress()
        refreshAnimation()
        if activity != previous || stateText != previousLabel { updatePanel() }
        updateIndicators()
    }

    private func trackStartingTurns(_ current: [ChatActivity], previously: [ChatActivity]) {
        let oldIDs = Set(previously.compactMap { $0.turn?.id })
        let started = current.compactMap(\.turn).filter { !oldIDs.contains($0.id) }
        guard !started.isEmpty else { return }
        for turn in started {
            let cached = (quotaStore.isRestoredSnapshot ? nil : quotaStore.snapshot).flatMap { value -> QuotaSnapshot? in
                abs(value.observedAt.timeIntervalSince1970 - Double(turn.started)) <= 5 ? value : nil
            }
            trackedQuotas[turn.id] = TrackedQuota(baseline: cached, endedAt: nil)
        }
        let ids = started.map(\.id)
        quotaStore.refresh(afterCurrent: true) { [weak self] snapshot in
            guard let self, let snapshot else { return }
            for id in ids {
                guard var tracked = self.trackedQuotas[id] else { continue }
                if let end = tracked.endedAt, snapshot.observedAt.timeIntervalSince1970 > Double(end) + 1 { continue }
                tracked.baseline = snapshot
                self.trackedQuotas[id] = tracked
            }
        }
        if trackedQuotas.count > 64 {
            let active = Set(current.compactMap { $0.turn?.id })
            trackedQuotas = trackedQuotas.filter { active.contains($0.key) || $0.value.endedAt != nil }
        }
    }

    private func trackCompletedTurn(_ turn: Turn) {
        if var tracked = trackedQuotas[turn.id] {
            tracked.endedAt = turn.ended
            trackedQuotas[turn.id] = tracked
        }
        completedQuota = CompletedQuota(turnID: turn.id, snapshot: quotaStore.snapshot, estimated: nil, isLoading: true, isStale: true)
        quotaStore.refresh(afterCurrent: true) { [weak self] snapshot in
            guard let self else { return }
            let baseline = self.trackedQuotas.removeValue(forKey: turn.id)?.baseline
            guard self.outcome?.chat.turn?.id == turn.id else { return }
            let estimated = snapshot.flatMap { now in baseline.flatMap { now.estimatedConsumption(since: $0) } }
            self.completedQuota = CompletedQuota(turnID: turn.id, snapshot: snapshot ?? self.quotaStore.snapshot,
                                                 estimated: estimated, isLoading: false, isStale: snapshot == nil)
            self.updateProgress()
        }
    }

    private func updateProgress() {
        let wasVisible = featuredID != nil
        let wasStacked = headStacked
        let oldCount = extraTaskCards.count
        let wasCompletion = completionCard
        completionCard = false
        head.setCompletion(false, quota: nil)
        let active = available && running ? activity.working : []
        let pending = reviewBridge.reviews.first
        if let pending {
            featuredID = pending.thread
            let title = activity.chats.first { $0.id == pending.thread }?.title ?? "Codex"
            let question = pending.isQuestion
            head.set(title: title, phase: question ? "等待选择" : "等待审批",
                     symbol: question ? "questionmark.circle" : "checkmark.shield", extra: max(0, active.count - 1))
        } else if available, running, let outcome, Date().timeIntervalSince(outcome.time) < TaskCompletionNotice.visibleDuration,
                  !active.contains(where: { $0.id == outcome.chat.id && $0.turn?.id != outcome.chat.turn?.id }) {
            featuredID = outcome.chat.id
            let status = outcome.chat.turn?.status
            let phase = status == .completed ? "任务完成" : (status?.label ?? "任务已结束")
            var quotaText: String?
            if let quota = completedQuota, quota.turnID == outcome.chat.turn?.id {
                if let window = quota.snapshot?.preferred {
                    let consumption = quota.isLoading ? "统计中" : quota.estimated.map { "期间约耗\($0)%" } ?? "无法估算"
                    let windowLabel = window.minutes == 300 ? "5h" : window.label
                    quotaText = (quota.isStale ? "上次" : "") + "\(windowLabel)余\(window.remaining)% · " + consumption
                } else { quotaText = quota.isLoading ? "额度读取中" : "额度不可用" }
            }
            head.set(title: outcome.chat.title, phase: phase,
                     symbol: outcome.chat.turn?.status.symbol ?? "checkmark.circle", extra: active.count)
            completionCard = status == .completed
            head.setCompletion(completionCard, quota: quotaText)
        } else if let chat = active.first {
            featuredID = chat.id
            head.set(title: chat.title, phase: chat.stage?.label ?? "思考中", symbol: "waveform.path", extra: active.count - 1)
        } else { featuredID = nil }
        headStacked = active.filter { $0.id != featuredID }.count > 0 && featuredID != nil
        if !headStacked { tasksExpanded = false }
        head.setProviderIcon(ProviderIcon.codex)
        refreshExtraTaskCards(active)
        if wasVisible != (featuredID != nil) || wasStacked != headStacked || oldCount != extraTaskCards.count || wasCompletion != completionCard { layoutWindow() }
        else { syncHeadVisibility() }
        if completionCard, reviewPanel == nil, chatBubble == nil, let turn = outcome?.chat.turn?.id,
           completionTurnShown != turn {
            completionTurnShown = turn
            emphasizeCompletion()
        }
    }

    private func emphasizeCompletion() {
        guard !pet.reduceMotion else { return }
        headGlass.wantsLayer = true
        let arrival = CAKeyframeAnimation(keyPath: "transform.translation.y")
        arrival.values = [-6, 1, 0]
        arrival.keyTimes = [0, 0.7, 1]
        arrival.duration = 0.32
        arrival.timingFunction = CAMediaTimingFunction(name: .easeOut)
        headGlass.layer?.add(arrival, forKey: "completionArrival")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.35
        fade.toValue = 1
        fade.duration = 0.22
        headGlass.layer?.add(fade, forKey: "completionFade")
    }

    var hasPendingReview: Bool { !reviewBridge.reviews.isEmpty }

    func refreshAnimation() {
        guard pet != nil else { return }
        let currentPreview = preview.flatMap { Date() < $0.until ? $0.row : nil }
        let currentOutcome = outcome.flatMap { value in
            available && running && Date().timeIntervalSince(value.time) < (value.row == 8 ? 10.1 : 4) ? value.row : nil
        }
        let decision = chooseAnimation(dragging: pet.dragging, pendingReview: hasPendingReview,
            hovered: pet.hovered, greetingCoolingDown: pet.isGreetingCoolingDown,
            preview: currentPreview, working: available && running && !activity.working.isEmpty,
            outcome: currentOutcome, musicPlaying: musicMonitor.state == .playingSong)
        switch decision {
        case .dragging: stopWander(); return
        case .review: stopWander(); pet.setRow(6); return
        case .greeting:
            stopWander()
            if pet.row != 4 || pet.idleVariant != nil { pet.setRow(4) }
            return
        default: break
        }
        if wanderTimer != nil {
            if !mayWander { stopWander() } else { return }
        }
        switch decision {
        case .preview(let row), .outcome(let row): pet.setRow(row)
        case .working: pet.setRow(7)
        case .singing: if !pet.isReturningCarry { pet.playSinging() }
        case .idle:
            pet.stopSinging()
            if pet.isEndingSong { return }
            pet.setRow(0)
            if mayWander && Date() >= wanderNext && pet.idleVariant == nil { startWander() } else { pet.maybeIdle() }
        case .dragging, .review, .greeting: break
        }
    }

    @objc func updateMotion() {
        pet.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if pet.reduceMotion && railMotion != nil { layoutWindow() }
        if pet.reduceMotion && reviewReveal != nil { positionReviewCard() }
        configureCursorTimer()
    }

    func configureCursorTimer() {
        cursorPoll?.invalidate()
        cursorPoll = nil
        if follow && !pet.reduceMotion {
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.updateCursor() }
            timer.tolerance = 0.04
            RunLoop.main.add(timer, forMode: .common)
            cursorPoll = timer
        }
        updateCursor()
    }

    func updateCursor() {
        guard follow, !pet.reduceMotion, !pet.hovered, !pet.dragging, pet.row == 0 else {
            if pet.look != nil { pet.look = nil; pet.needsDisplay = true }
            return
        }
        let p = NSEvent.mouseLocation, frame = window.frame
        let angle = atan2(p.x - frame.midX, p.y - frame.midY)
        let index = (Int((angle / (Double.pi / 8)).rounded()) + 16) % 16
        if pet.look != index { pet.look = index; pet.needsDisplay = true }
    }

    private func updateIndicators() {
        let hasPending = !reviewBridge.reviews.isEmpty
        let hasUnread = !unread.isEmpty
        let disconnected = running && reviewConnectionWanted && !reviewBridge.isReady
        let image = disconnected ? "exclamationmark.circle" : (hasPending || hasUnread ? "bell.badge.fill" : "bell")
        if bell.image?.accessibilityDescription != image {
            bell.image = NSImage(systemSymbolName: image, accessibilityDescription: image)
        }
        bell.contentTintColor = disconnected ? .systemOrange : (hasUnread ? .controlAccentColor : .labelColor)
        let note = hasPending ? "Codex 活动 · 有待处理审批" : disconnected ? reviewBridge.status : (hasUnread ? "Codex 活动 · \(unread.count) 条新结果" : "Codex 活动")
        bell.toolTip = note
        bell.setAccessibilityLabel(note)
    }

    private var displayedChats: [ChatActivity] {
        available ? activity.chats : activity.chats.map { ChatActivity(id: $0.id, title: $0.title, turn: nil) }
    }

    private func updatePanel() {
        guard let panel, let controller = panelController, controller.page == .activity, panel.isVisible else { return }
        controller.update(displayedChats, note: stateText)
        panel.setFrame(panelFrame(for: controller.preferredContentSize), display: true)
    }

    private func refreshExtraTaskCards(_ active: [ChatActivity]) {
        let others = tasksExpanded ? active.filter { $0.id != featuredID } : []
        let ids = Set(others.map(\.id))
        for id in Array(extraTaskCards.keys) where !ids.contains(id) {
            extraTaskCards.removeValue(forKey: id)?.1.removeFromSuperview()
        }
        for (index, task) in others.enumerated() {
            if extraTaskCards[task.id] == nil {
                let card = ProcessCapsule(frame: .zero)
                card.onOpen = { [weak self] in
                    if let url = CodexLinks.chat(task.id) { self?.handOff(url) }
                }
                let glass = makeGlass(content: card, radius: 19, clear: clearPanel, textSurface: true, tintStrength: 0)
                extraTaskDocument.addSubview(glass)
                extraTaskCards[task.id] = (card, glass)
            }
            guard let (card, glass) = extraTaskCards[task.id] else { continue }
            card.set(title: task.title, phase: task.stage?.label ?? "思考中", symbol: "waveform.path", extra: 0)
            card.setProviderIcon(ProviderIcon.codex)
            glass.frame = NSRect(x: 0, y: 44 * CGFloat(index), width: 216, height: 38)
        }
    }

    private func showTaskPicker() {
        guard headStacked else { return }
        tasksExpanded.toggle()
        if !tasksExpanded && !pet.reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                extraTaskScroll.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                DispatchQueue.main.async {
                    guard let self, !self.tasksExpanded else { return }
                    self.updateProgress()
                    self.layoutWindow()
                }
            }
            return
        }
        updateProgress()
        layoutWindow()
        guard tasksExpanded else { return }
        extraTaskScroll.contentView.scroll(to: .zero)
        extraTaskScroll.reflectScrolledClipView(extraTaskScroll.contentView)
        guard !pet.reduceMotion else { extraTaskScroll.alphaValue = 1; return }
        let resting = extraTaskScroll.frame
        extraTaskScroll.frame = resting.offsetBy(dx: 0, dy: -8)
        extraTaskScroll.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            extraTaskScroll.animator().frame = resting
            extraTaskScroll.animator().alphaValue = 1
        }
    }

    private func panelFrame(for size: NSSize) -> NSRect {
        let display = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let petRect = pet.frame.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        return PetPlacement.frame(size: size, pet: petRect, visible: display)
    }

    private func show(_ page: ActivityPanel.Page) {
        if let panel, panel.isVisible, panelController?.page == page {
            panel.close()
            return
        }
        closeComposer()
        panel?.close()
        setExpanded(true)
        let controller = ActivityPanel(page)
        controller.didChooseChat = { [weak self] id in if let link = CodexLinks.chat(id) { self?.handOff(link) } }
        controller.didSwitchToDraft = { [weak self] in self?.composerMode = .task; self?.showDraft() }
        controller.didOpenCodex = { [weak self] in self?.openCodex() }
        controller.didOpenApprovals = { [weak self] _ in self?.showReview() }
        controller.didResize = { [weak self, weak controller] in
            guard let self, let controller, self.panelController === controller, let panel = self.panel else { return }
            panel.setFrame(self.panelFrame(for: controller.preferredContentSize), display: true)
        }
        controller.didRequestFiles = { [weak self, weak controller] request in
            guard let self else { return }
            let reader = self.reader
            let revision = self.sourceRevision
            self.readQueue.async { [weak self, weak controller] in
                let files = reader.recentDeliveryFiles()
                DispatchQueue.main.async { [weak self, weak controller] in
                    guard let self, let controller, self.panelController === controller else { return }
                    controller.receiveFiles(self.sourceRevision == revision ? files : [], request: request)
                }
            }
        }
        let content = controller.view
        if page == .activity {
            unread.removeAll()
            controller.update(displayedChats, note: stateText)
            updateIndicators()
        }
        let fit = content.fittingSize
        content.frame = NSRect(origin: .zero, size: fit)
        let floating = FloatingGlassPanel(contentRect: panelFrame(for: fit),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        floating.isReleasedWhenClosed = false
        floating.isOpaque = false
        floating.backgroundColor = .clear
        floating.hasShadow = true
        floating.level = .floating
        floating.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        floating.contentView = makeGlass(content: content, radius: 21, clear: clearPanel, textSurface: true)
        floating.delegate = self
        floating.title = page == .activity ? "Codex 活动" : "原版 Mini"
        panel = floating
        panelController = controller
        floating.makeKeyAndOrderFront(nil)

    }

    @objc private func refreshQuota() {
        if showsDeepSeekBalance { deepSeekBalance.refresh() } else { quotaStore.refresh() }
    }

    private func updateQuotaButton() {
        if showsDeepSeekBalance {
            quotaButton?.updateDeepSeek(snapshot: deepSeekBalance.snapshot, refreshing: deepSeekBalance.refreshing,
                                        error: deepSeekBalance.error, restored: deepSeekBalance.restored)
        } else {
            quotaButton?.update(snapshot: quotaStore.snapshot, refreshing: quotaStore.isRefreshing,
                                failed: quotaStore.failed, restored: quotaStore.isRestoredSnapshot)
        }
    }

    private func reviewCardFrame(for size: NSSize) -> NSRect {
        let display = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let petRect = pet.frame.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        return PetPlacement.frame(size: size, pet: petRect, visible: display, above: true)
    }

    private func positionReviewCard() {
        guard let controller = reviewPanel, let panel else { return }
        var frame = reviewCardFrame(for: controller.preferredContentSize)
        var opacity: CGFloat = 1
        if let reveal = reviewReveal {
            let progress = CGFloat((ProcessInfo.processInfo.systemUptime - reveal.start) / 0.24)
            if progress >= 1 || pet.reduceMotion {
                reveal.timer.invalidate()
                reviewReveal = nil
            } else {
                let remaining = 1 - progress * progress * (3 - 2 * progress)
                let bottom = window.screen?.visibleFrame.minY ?? frame.minY - 10
                frame.origin.y = max(bottom, frame.minY - 10 * remaining)
                opacity = 1 - 0.90 * remaining
            }
        }
        if frame != panel.frame { panel.setFrame(frame, display: frame.size != panel.frame.size) }
        if opacity != panel.alphaValue { panel.alphaValue = opacity }
    }

    private func reviewChanged() {
        let reviews = reviewBridge.reviews
        refreshAnimation()
        if !reviews.isEmpty { dismissChatBubble() }
        if !reviews.isEmpty || reviewBridge.status != "已提交到 Codex" || reviewBridge.inFlightCount > 0 || reviewBridge.isRefreshingRequests {
            if reviewDismiss != nil { shownSuccessRevision = 0 }
            reviewDismiss?.invalidate()
            reviewDismiss = nil
            panel?.alphaValue = 1
        }
        reviewPanel?.update(reviews, enabled: reviewBridge.isEnabled, status: reviewBridge.status)
        if head != nil { updateProgress() }
        updateIndicators()
        if reviewPanel != nil {
            rememberShownReviews(reviews)
            positionReviewCard()
            if reviews.isEmpty, reviewBridge.inFlightCount == 0, !reviewBridge.isRefreshingRequests, reviewBridge.status == "已提交到 Codex",
               reviewBridge.successRevision != shownSuccessRevision, let current = panel {
                shownSuccessRevision = reviewBridge.successRevision
                reviewDismiss?.invalidate()
                let revision = shownSuccessRevision
                let timer = Timer(timeInterval: 2.5, repeats: false) { [weak self, weak current] _ in
                    guard let self, let current, self.panel === current, self.reviewPanel != nil,
                          self.reviewBridge.reviews.isEmpty, self.reviewBridge.inFlightCount == 0, !self.reviewBridge.isRefreshingRequests,
                          self.reviewBridge.status == "已提交到 Codex", self.reviewBridge.successRevision == revision else { return }
                    if self.pet.reduceMotion { current.close(); return }
                    let start = ProcessInfo.processInfo.systemUptime
                    let origin = current.frame.origin
                    let fade = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak current] tick in
                        guard let self, let current, self.panel === current, self.reviewBridge.reviews.isEmpty,
                              self.reviewBridge.inFlightCount == 0, !self.reviewBridge.isRefreshingRequests, self.reviewBridge.successRevision == revision,
                              self.reviewBridge.status == "已提交到 Codex" else { tick.invalidate(); return }
                        let p = min(1, CGFloat((ProcessInfo.processInfo.systemUptime - start) / 0.22))
                        let eased = p * p * (3 - 2 * p)
                        current.alphaValue = 1 - eased
                        current.setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 8 * eased))
                        if p >= 1 { tick.invalidate(); current.close() }
                    }
                    self.reviewDismiss = fade
                    RunLoop.main.add(fade, forMode: .common)
                }
                reviewDismiss = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        } else {
            presentPendingReview()
        }
    }

    private func rememberShownReviews(_ reviews: [LiveReview]) {
        let keys = reviews.map(presentationKey)
        // A refresh can temporarily remove a pending request before it reappears.
        shownReviewKeys.removeAll { keys.contains($0) }
        shownReviewKeys.append(contentsOf: keys)
        if shownReviewKeys.count > 96 { shownReviewKeys.removeFirst(shownReviewKeys.count - 96) }
    }

    private func presentPendingReview() {
        guard window.isVisible, panel == nil, !pet.dragging,
              reviewBridge.reviews.contains(where: { !shownReviewKeys.contains(presentationKey($0)) }) else { return }
        presentReview(automatically: true)
    }

    private func presentationKey(_ review: LiveReview) -> String {
        let turn = review.payload["turnId"] as? String ?? ""
        return review.owner + ":" + turn + ":" + review.key
    }

    @objc private func showReview() { presentReview(automatically: false) }

    private func presentReview(automatically: Bool, thread: String? = nil) {
        if reviewPanel != nil, panel?.isVisible == true {
            if let thread {
                reviewPanel?.selectThread(thread, reviews: reviewBridge.reviews)
                reviewPanel?.update(reviewBridge.reviews, enabled: reviewBridge.isEnabled, status: reviewBridge.status)
                positionReviewCard()
            }
            if !automatically {
                panel?.keyAllowed = true
                panel?.makeKeyAndOrderFront(nil)
            }
            return
        }
        if !automatically {
            closeComposer()
            panel?.close()
            setExpanded(true)
        }
        let controller = ReviewPanel()
        controller.threadTitle = { [weak self] id in self?.activity.chats.first { $0.id == id }?.title ?? "" }
        controller.onConnect = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(true, forKey: "reviewConnectionEnabled")
            self.lastReviewConnectAttempt = nil
            self.maintainReviewConnection()
        }
        controller.onClose = { [weak self] in self?.panel?.close() }
        controller.onOpenNative = { [weak self] id in
            if let id, let link = CodexLinks.chat(id) { self?.handOff(link) }
            else { self?.openCodex() }
        }
        controller.onDecision = { [weak self] review, decision in self?.reviewBridge.submit(review, decision: decision) }
        controller.onAnswers = { [weak self] review, answers in self?.reviewBridge.submit(review, answers: answers) }
        controller.onRefresh = { [weak self] in self?.reviewChanged() }
        let reviews = reviewBridge.reviews
        if let thread { controller.selectThread(thread, reviews: reviews) }
        controller.update(reviews, enabled: reviewBridge.isEnabled, status: reviewBridge.status)
        let content = controller.view
        content.frame.size = controller.preferredContentSize
        let floating = FloatingGlassPanel(contentRect: reviewCardFrame(for: controller.preferredContentSize),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        floating.isReleasedWhenClosed = false
        floating.isOpaque = false
        floating.backgroundColor = .clear
        floating.hasShadow = true
        floating.hidesOnDeactivate = false
        floating.animationBehavior = .none
        floating.level = .floating
        floating.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let surface = makeGlass(content: content, radius: 21, clear: clearPanel, textSurface: true)
        let host = NSView(frame: NSRect(origin: .zero, size: controller.preferredContentSize))
        surface.frame = host.bounds
        surface.autoresizingMask = [.width, .height]
        host.addSubview(surface)
        floating.contentView = host
        floating.delegate = self
        floating.title = "审批与提问"
        floating.keyAllowed = !automatically || composer == nil
        panel = floating
        reviewPanel = controller
        reviewGlass = surface
        rememberShownReviews(reviews)
        syncHeadVisibility()
        if !pet.reduceMotion {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] tick in
                guard let self else { tick.invalidate(); return }
                self.positionReviewCard()
            }
            reviewReveal = (ProcessInfo.processInfo.systemUptime, timer)
            positionReviewCard()
            RunLoop.main.add(timer, forMode: .common)
        }
        window.addChildWindow(floating, ordered: .above)
        if automatically { floating.orderFrontRegardless() }
        else { floating.makeKeyAndOrderFront(nil) }
    }

    private var reviewConnectionWanted: Bool {
        UserDefaults.standard.object(forKey: "reviewConnectionEnabled") as? Bool ?? true
    }

    private func maintainReviewConnection() {
        guard running, reviewConnectionWanted, !reviewBridge.isEnabled else { return }
        if let lastReviewConnectAttempt, Date().timeIntervalSince(lastReviewConnectAttempt) < 10 { return }
        lastReviewConnectAttempt = Date()
        let root = ActivityReader.local().root
        reviewBridge.start(path: root.appendingPathComponent("ipc/ipc.sock").path)
    }

    @objc private func disconnectReview() {
        UserDefaults.standard.set(false, forKey: "reviewConnectionEnabled")
        reviewBridge.stop()
    }

    func windowDidResignKey(_ notification: Notification) {
        if let previous = notification.object as? FloatingGlassPanel, previous === optionsPanel { previous.close() }
        if let previous = notification.object as? FloatingGlassPanel, previous === panel, reviewPanel == nil { previous.close() }
        if let previous = notification.object as? FloatingGlassPanel, previous === window, composer != nil { closeComposer() }
    }

    func windowWillClose(_ notification: Notification) {
        if let previous = notification.object as? FloatingGlassPanel, previous === optionsPanel { optionsPanel = nil; optionsPage = nil }
        if let previous = notification.object as? FloatingGlassPanel, previous === panel {
            let wasReview = reviewPanel != nil
            if reviewPanel != nil { window.removeChildWindow(previous) }
            reviewReveal?.timer.invalidate()
            reviewReveal = nil
            reviewDismiss?.invalidate()
            reviewDismiss = nil
            panel = nil
            panelController = nil
            reviewPanel = nil
            reviewGlass = nil
            syncHeadVisibility()
            scheduleCollapse()
            DispatchQueue.main.async { [weak self] in self?.presentPendingReview() }
            if wasReview, composerMode == .chat, let reply = lastChatReply, reviewBridge.reviews.isEmpty { showChatBubble(reply) }
        }
    }

    private func sendChat(_ text: String) {
        let controller = chatController ?? PetChat()
        chatController = controller
        controller.onState = { [weak self] message, busy in
            guard let self else { return }
            self.composer?.setChatBusy(busy)
            if !busy && !message.isEmpty && self.composerMode == .chat { self.showChatBubble(message) }
        }
        controller.onPartial = { [weak self] partial in
            guard let self, !partial.isEmpty else { return }
            self.lastChatReply = partial
            if self.composerMode == .chat && !self.chatBubbleDismissed { self.showChatBubble(partial) }
        }
        controller.onReply = { [weak self] reply in
            guard let self else { return }
            if self.chatDraft == self.chatSubmitted {
                self.chatDraft = ""
                if self.composerMode == .chat { self.composer?.restoreDraft("") }
            }
            self.lastChatReply = reply
            if self.composerMode == .chat && !self.chatBubbleDismissed { self.showChatBubble(reply) }
        }
        controller.onSuccess = { [weak self] in
            guard let self, self.showsDeepSeekBalance else { return }
            self.deepSeekBalance.refresh()
        }
        chatSubmitted = text
        chatBubbleDismissed = false
        dismissChatBubble()
        _ = controller.sendMessage(text)
    }

    private func chatBubbleFrame(for size: NSSize) -> NSRect {
        let display = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let petRect = pet.frame.offsetBy(dx: window.frame.minX, dy: window.frame.minY)
        return PetPlacement.headFrame(size: size, pet: petRect, visible: display)
    }

    private func showChatBubble(_ text: String) {
        guard !text.isEmpty, reviewPanel == nil, reviewBridge.reviews.isEmpty, window != nil else { return }
        if chatBubble != nil, let chatBubbleText {
            if chatBubbleText.string != text {
                chatBubbleText.string = text
                chatBubbleText.scrollToEndOfDocument(nil)
            }
            return
        }
        dismissChatBubble()
        let size = NSSize(width: 272, height: 112)
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let close = NSButton(title: "×", target: self, action: #selector(closeChatBubble))
        close.isBordered = false
        close.frame = NSRect(x: size.width - 26, y: size.height - 27, width: 20, height: 20)
        close.autoresizingMask = [.minXMargin, .minYMargin]
        close.setAccessibilityLabel("关闭闲聊回复")
        content.addSubview(close)
        let scroll = NSScrollView(frame: NSRect(x: 10, y: 10, width: size.width - 35, height: size.height - 20))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let body = NSTextView(frame: NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: scroll.contentSize.height))
        body.isEditable = false
        body.isSelectable = true
        body.drawsBackground = false
        body.font = .systemFont(ofSize: 12)
        body.textColor = .labelColor
        body.isVerticallyResizable = true
        body.textContainer?.widthTracksTextView = true
        body.string = text
        chatBubbleText = body
        scroll.documentView = body
        content.addSubview(scroll)
        let bubble = FloatingGlassPanel(contentRect: chatBubbleFrame(for: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bubble.isReleasedWhenClosed = false
        bubble.keyAllowed = false
        bubble.isOpaque = false
        bubble.backgroundColor = .clear
        bubble.hasShadow = true
        bubble.level = .floating
        bubble.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        bubble.contentView = makeGlass(content: content, radius: 19, clear: clearPanel, textSurface: true)
        chatBubble = bubble
        syncHeadVisibility()
        window.addChildWindow(bubble, ordered: .above)
        bubble.orderFrontRegardless()
    }
    private func positionChatBubble() {
        guard let bubble = chatBubble else { return }
        let frame = chatBubbleFrame(for: bubble.frame.size)
        if frame != bubble.frame { bubble.setFrame(frame, display: false) }
    }
    private func dismissChatBubble() {
        guard let bubble = chatBubble else { return }
        chatBubble = nil
        chatBubbleText = nil
        window?.removeChildWindow(bubble)
        bubble.close()
        if headGlass != nil { syncHeadVisibility() }
    }
    @objc private func closeChatBubble() {
        chatBubbleDismissed = true
        lastChatReply = nil
        dismissChatBubble()
    }

    @objc func showActivity() { show(.activity); checkStatus() }
    @objc func showDraft() {
        if let composer {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(composer.editor)
            return
        }
        panel?.close()
        if composerMode == .chat {
            let chat = chatController ?? PetChat(); chatController = chat; chat.prewarm()
        }
        let view = railEditor ?? InlineComposer(draft: draft)
        view.setMode(composerMode)
        view.setChatBusy(chatController?.isBusy == true)
        view.restoreDraft(composerMode == .chat ? chatDraft : draft)
        view.didChange = { [weak self, weak view] text in
            guard let self, self.composer === view else { return }
            if self.composerMode == .chat { self.chatDraft = text } else { self.draft = text }
            if self.railEditor?.frame.height != self.composer?.preferredHeight { self.layoutWindow(animateRail: true) }
        }
        view.didSubmit = { [weak self, weak view] text in
            guard let self, self.composer === view else { return }
            if self.composerMode == .chat { self.sendChat(text) }
            else if let link = CodexLinks.draft(text) { self.handOff(link, submittedDraft: text) }
        }
        view.didSwitchMode = { [weak self, weak view] next in
            guard let self, let view, self.composer === view else { return }
            if self.composerMode == .chat { self.chatDraft = view.editor.string } else { self.draft = view.editor.string }
            self.composerMode = next
            if next == .chat {
                let chat = self.chatController ?? PetChat(); self.chatController = chat; chat.prewarm()
            } else { self.chatController?.releaseIfIdle() }
            view.setMode(next)
            view.restoreDraft(next == .chat ? self.chatDraft : self.draft)
            if next == .task { self.dismissChatBubble() }
            else if let reply = self.lastChatReply { self.showChatBubble(reply) }
            self.layoutWindow(animateRail: true)
            self.window.makeFirstResponder(view.editor)
        }
        view.didStopChat = { [weak self] in self?.chatController?.cancel() }
        view.didCancel = { [weak self, weak view] in
            if self?.composer === view { self?.closeComposer() }
        }
        if railEditor == nil {
            view.alphaValue = 0
            railContent.addSubview(view)
            railEditor = view
        }
        composer = view
        layoutWindow(animateRail: true)
        window.keyAllowed = true
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view.editor)
    }

    private func closeComposer() {
        guard composer != nil else { return }
        composer = nil
        chatController?.releaseIfIdle()
        dismissChatBubble()
        window.keyAllowed = false
        if window.isKeyWindow { window.resignKey() }
        holdCollapsedUntilExit = true
        expanded = false
        layoutWindow(animateRail: true)
        DispatchQueue.main.async { [weak self] in self?.presentPendingReview() }
    }
    @objc func showNative() { show(.native) }
    @objc func toggleControls() {
        closeComposer()
        panel?.close()
        controls.toggle()
        UserDefaults.standard.set(controls, forKey: "controls")
        layoutWindow()
    }

    private var codexURL: URL? {
        // Prefer the normal installation if a test copy shares its bundle identifier.
        let installed = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        if Bundle(url: installed)?.bundleIdentifier == codexID { return installed }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: codexID)
    }

    private var codexProcess: NSRunningApplication? {
        guard let target = codexURL?.resolvingSymlinksInPath().standardizedFileURL.path else { return nil }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: codexID).filter { !$0.isTerminated }
        return apps.first { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == target }
            ?? apps.first
    }

    private func handOff(_ link: URL, submittedDraft: String? = nil) {
        guard let url = codexURL else { showOpenError(); return }
        let options = NSWorkspace.OpenConfiguration()
        options.activates = true
        options.createsNewApplicationInstance = false
        let openedPanel = panel
        NSWorkspace.shared.open([link], withApplicationAt: url, configuration: options) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error != nil { self.showOpenError(); return }
                if let submittedDraft, self.draft == submittedDraft {
                    self.draft = ""
                    self.closeComposer()
                }
                if self.panel === openedPanel { self.panel?.close() }
            }
        }
    }

    private func showOpenError() {
        let alert = NSAlert()
        alert.messageText = "无法打开 Codex"
        alert.informativeText = "请确认 ChatGPT 桌面应用已安装，然后重试。"
        alert.runModal()
    }

    @objc func openCodex() {
        panel?.close()
        if let app = codexProcess { app.activate(options: []) }
        else if let url = codexURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                if error != nil { DispatchQueue.main.async { self?.showOpenError() } }
            }
        } else { showOpenError() }
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        if reviewBridge.isEnabled {
            menu.addItem(withTitle: "断开本机审批连接", action: #selector(disconnectReview), keyEquivalent: "")
        }
        menu.addItem(withTitle: controls ? "隐藏控制栏" : "显示控制栏", action: #selector(toggleControls), keyEquivalent: "")
        let material = menu.addItem(withTitle: "面板透明玻璃", action: #selector(toggleGlass), keyEquivalent: "")
        material.state = clearPanel ? .on : .off
        let gaze = menu.addItem(withTitle: "鼠标方向跟随", action: #selector(toggleFollow), keyEquivalent: "")
        gaze.state = follow ? .on : .off
        let quotaName = showsDeepSeekBalance ? "DeepSeek" : "Codex"
        for (tag, title) in ["大小", "动作展示", "数据管理", "额度显示：\(quotaName)", "闲聊设置"].enumerated() {
            let item = menu.addItem(withTitle: title + "…", action: #selector(showOptionsPage(_:)), keyEquivalent: "")
            item.target = self; item.tag = tag
        }
        let wander = menu.addItem(withTitle: "自主移动", action: #selector(toggleWander), keyEquivalent: "")
        wander.target = self; wander.state = wanderEnabled ? .on : .off
        let music = menu.addItem(withTitle: "随 Apple Music 唱歌", action: #selector(toggleMusic), keyEquivalent: "")
        music.target = self; music.state = musicMonitor.enabled ? .on : .off
        if musicMonitor.enabled && musicMonitor.state == .unavailable {
            let status = menu.addItem(withTitle: "音乐连接不可用，关闭后重试", action: nil, keyEquivalent: "")
            status.isEnabled = false
        }
        menu.addItem(withTitle: "恢复位置", action: #selector(resetPosition), keyEquivalent: "")
        menu.addItem(withTitle: "检查更新…", action: #selector(checkForUpdate), keyEquivalent: "")
        menu.addItem(withTitle: "项目与原形象作者", action: #selector(showProject), keyEquivalent: "")
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "退出 GPT 娘桌宠", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        for item in menu.items where item.action != nil && item.target == nil { item.target = self }
        return menu
    }

    private func approvalsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "在 Codex 按 ⌘⌥A 查找待处理对话", action: nil, keyEquivalent: "")
        if available && running {
            for chat in activity.working.prefix(7) {
                let item = menu.addItem(withTitle: chat.title, action: #selector(openApprovalThread(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = chat.id
            }
            if !activity.working.isEmpty { menu.addItem(.separator()) }
        }
        let app = menu.addItem(withTitle: "打开 Codex", action: #selector(openCodex), keyEquivalent: "")
        app.target = self
        return menu
    }

    @objc private func openApprovalThread(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String, let link = CodexLinks.chat(id) { handOff(link) }
    }

    private var mayWander: Bool {
        let hasRecentOutcome = available && running && (outcome.map { Date().timeIntervalSince($0.time) < ($0.row == 8 ? 10.1 : 4) } ?? false)
        return wanderEnabled && !pet.reduceMotion && !pet.dragging && !pet.hovered && composer == nil && optionsPanel?.isVisible != true && panel?.isVisible != true && chatBubble?.isVisible != true && reviewBridge.reviews.isEmpty && activity.working.isEmpty && !hasRecentOutcome && musicMonitor.state != .playingSong && (preview == nil || Date() >= preview!.until)
    }
    @objc private func toggleWander() {
        wanderEnabled.toggle(); UserDefaults.standard.set(wanderEnabled, forKey: "wanderEnabled")
        if !wanderEnabled { stopWander() }
    }
    func stopWander() {
        guard let timer = wanderTimer else { return }
        timer.invalidate(); wanderTimer = nil
        wanderNext = Date().addingTimeInterval(Double.random(in: 45...90))
        if !pet.dragging { pet.setRow(0); savePosition() }
    }
    private func startWander() {
        guard mayWander, wanderTimer == nil else { return }
        let origin = window.frame.origin
        let centre = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(centre) }) ?? window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame,
              let plan = PetWanderPlan.make(origin: origin, size: window.frame.size, visible: visible,
                                            angle: Double.random(in: 0...(2 * .pi)), distance: CGFloat.random(in: 25...48))
        else { wanderNext = Date().addingTimeInterval(45); return }
        let dx = plan.delta.x, dy = plan.delta.y
        let duration = plan.duration, started = ProcessInfo.processInfo.systemUptime
        pet.setRow(dx < 0 ? 2 : 1)
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, self.mayWander else { self?.stopWander(); return }
            let t = min(1, max(0, (ProcessInfo.processInfo.systemUptime - started) / duration))
            let eased = t * t * (3 - 2 * t)
            self.window.setFrameOrigin(NSPoint(x: origin.x + dx * eased, y: origin.y + dy * eased))
            if t >= 1 { self.stopWander(); self.refreshAnimation() }
        }
        timer.tolerance = 0.01; wanderTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func toggleMusic() {
        if musicMonitor.enabled { musicMonitor.stop(); UserDefaults.standard.set(false, forKey: "musicSingingEnabled") }
        else { UserDefaults.standard.set(true, forKey: "musicSingingEnabled"); musicMonitor.start() }
        refreshAnimation()
    }

    @objc private func selectQuotaDisplay(_ sender: NSControl) {
        optionsPanel?.close(); optionsPanel = nil
        UserDefaults.standard.set(sender.tag == 1 ? "deepseek" : "codex", forKey: quotaDisplayKey)
        updateQuotaButton()
        if showsDeepSeekBalance { deepSeekBalance.refresh() }
    }

    @objc private func editPersona() {
        optionsPanel?.close(); optionsPanel = nil
        DispatchQueue.main.async { [weak self] in
            guard self != nil else { return }
            let alert = NSAlert(); alert.messageText = "龙娘闲聊人设"
            alert.informativeText = "修改后，从下一条闲聊开始生效。"
            alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "恢复默认"); alert.addButton(withTitle: "取消")
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 230))
            scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
            let editor = NSTextView(frame: scroll.bounds); editor.isRichText = false
            editor.font = .systemFont(ofSize: 13); editor.string = PetPersona.current
            editor.textContainerInset = NSSize(width: 8, height: 8)
            editor.isVerticallyResizable = true; editor.autoresizingMask = [.width]
            editor.textContainer?.widthTracksTextView = true; scroll.documentView = editor
            alert.accessoryView = scroll
            NSApp.activate(ignoringOtherApps: true)
            while true {
                let choice = alert.runModal()
                if choice == .alertFirstButtonReturn {
                    let text = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty || text.count > 6000 {
                        alert.informativeText = "人设需要 1 至 6000 个字符，请调整后保存。"; continue
                    }
                    UserDefaults.standard.set(text, forKey: PetPersona.key)
                } else if choice == .alertSecondButtonReturn {
                    UserDefaults.standard.removeObject(forKey: PetPersona.key)
                }
                break
            }
        }
    }

    @objc private func configureDeepSeekKey() {
        optionsPanel?.close(); optionsPanel = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let alert = NSAlert(); alert.messageText = "DeepSeek API Key"
            alert.informativeText = "密钥保存在 macOS 钥匙串，仅用于 DeepSeek 闲聊和余额查询。"
            alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "移除密钥"); alert.addButton(withTitle: "取消")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
            field.placeholderString = "输入或粘贴 DeepSeek API Key"
            alert.accessoryView = field
            NSApp.activate(ignoringOtherApps: true)
            while true {
                let choice = alert.runModal()
                guard choice == .alertFirstButtonReturn || choice == .alertSecondButtonReturn else { break }
                do {
                    if choice == .alertFirstButtonReturn { try DeepSeekKeychain.save(field.stringValue) }
                    else { try DeepSeekKeychain.remove() }
                    field.stringValue = ""
                    self.chatController?.cancel(); self.deepSeekBalance.clear()
                    if self.showsDeepSeekBalance { self.deepSeekBalance.refresh() }
                    break
                } catch {
                    alert.informativeText = (error is DeepSeekError) ? "请输入有效的 API Key。" : "无法保存到钥匙串，请检查钥匙串权限后重试。"
                }
            }
        }
    }

    @objc private func showOptionsPage(_ sender: NSMenuItem) {
        // A context-menu action runs while the native menu is still tracking.
        // Open the panel after the menu has fully dismissed so it keeps focus.
        let page = sender.tag
        DispatchQueue.main.async { [weak self] in self?.presentOptionsPage(page) }
    }
    private func presentOptionsPage(_ page: Int) {
        optionsPanel?.close(); optionsPanel = nil
        optionsPage = page
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let width: CGFloat = min(236, max(120, visible.width - 20))
        let items: [String]
        switch page {
        case 1: items = labels + idleLabels
        case 2: items = ["立即刷新", "选择本机数据文件夹…", "使用自动检测", "配置 DeepSeek API Key…"]
        case 3: items = [showsDeepSeekBalance ? "Codex 额度" : "✓ Codex 额度", showsDeepSeekBalance ? "✓ DeepSeek 余额" : "DeepSeek 余额"]
        case 4: items = ["编辑龙娘人设…"]
        default: items = []
        }
        let height: CGFloat = min(page == 0 ? 52 : CGFloat(items.count * 30 + 16), max(52, min(340, visible.height - 20)))
        let outer = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        if page == 0 {
            let slider = NSSlider(value: Double(size), minValue: 120, maxValue: 240, target: self, action: #selector(resizeSlider(_:)))
            slider.isContinuous = true; slider.frame = NSRect(x: 14, y: 14, width: width - 28, height: 24)
            slider.setAccessibilityLabel("桌宠大小"); outer.addSubview(slider)
        } else {
            let scroll = NSScrollView(frame: NSRect(x: 6, y: 6, width: width - 12, height: height - 12))
            scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            let contentHeight = max(height - 12, CGFloat(items.count * 30))
            let content = NSView(frame: NSRect(x: 0, y: 0, width: width - 24, height: contentHeight))
            for (index, title) in items.enumerated() {
                let action: Selector
                switch page {
                case 1: action = #selector(previewAnimation(_:))
                case 2: action = [#selector(refreshSource), #selector(chooseSource), #selector(resetSource), #selector(configureDeepSeekKey)][index]
                case 3: action = #selector(selectQuotaDisplay(_:))
                default: action = #selector(editPersona)
                }
                let button = NSButton(title: title, target: self, action: action)
                button.tag = index; button.isBordered = false; button.alignment = .left
                button.frame = NSRect(x: 8, y: contentHeight - CGFloat(index + 1) * 30, width: width - 40, height: 28)
                content.addSubview(button)
            }
            scroll.documentView = content; outer.addSubview(scroll)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, contentHeight - scroll.contentSize.height)))
        }
        let floating = FloatingGlassPanel(contentRect: panelFrame(for: NSSize(width: width, height: height)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        floating.isReleasedWhenClosed = false; floating.isOpaque = false; floating.backgroundColor = .clear; floating.hasShadow = true
        floating.level = .floating; floating.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        floating.contentView = makeGlass(content: outer, radius: 16, clear: clearPanel, textSurface: true, tintStrength: 0)
        floating.onCancel = { [weak floating] in floating?.close() }; floating.delegate = self; optionsPanel = floating
        floating.makeKeyAndOrderFront(nil)
    }

    func showMenu(event: NSEvent, view: NSView) {
        let menu = makeMenu()
        menu.update()
        let pointer = view.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: pointer.x, y: pointer.y, width: 800, height: 600)
        let anchor = PetPlacement.menuAnchor(size: menu.size, pointer: pointer, visible: visible)
        menu.popUp(positioning: nil, at: anchor, in: nil)
    }

    @objc func previewAnimation(_ sender: Any) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag ?? -1
        optionsPanel?.close(); optionsPanel = nil
        guard (0..<labels.count + idleLabels.count).contains(tag) else { return }
        let duration = tag == 4 || tag == 8 || tag == labels.count + 2 ? 10.1 : (tag < labels.count ? 8 : 6.1)
        preview = (tag < labels.count ? tag : 0, Date().addingTimeInterval(duration))
        pet.hovered = false
        if tag >= labels.count { pet.playIdleVariant(tag - labels.count) } else { refreshAnimation() }
    }
    @objc private func refreshSource() { checkStatus() }
    @objc private func chooseSource() {
        let dialog = NSOpenPanel()
        dialog.title = "选择 Codex 本机数据文件夹"
        dialog.prompt = "选择"
        dialog.canChooseDirectories = true
        dialog.canChooseFiles = false
        dialog.allowsMultipleSelection = false
        dialog.showsHiddenFiles = true
        dialog.directoryURL = reader.root
        NSApp.activate(ignoringOtherApps: true)
        dialog.begin { [weak self] result in
            guard result == .OK, let url = dialog.url else { return }
            self?.setSource(url)
        }
    }
    @objc private func resetSource() { setSource(nil) }
    private func setSource(_ url: URL?) {
        UserDefaults.standard.set(url?.path, forKey: "activityFolder")
        reader = .local(override: url)
        sourceRevision += 1
        isReading = false
        lastRead = nil
        available = false
        outcome = nil
        completedQuota = nil
        trackedQuotas.removeAll()
        unread.removeAll()
        activity = ActivitySnapshot(chats: [])
        stateText = "正在读取本机活动"
        updateProgress()
        updatePanel()
        checkStatus()
    }

    @objc func toggleGlass() {
        clearPanel.toggle()
        UserDefaults.standard.set(clearPanel, forKey: "clearPanel")
        setGlassStyle(bar, clear: clearPanel)
        setGlassStyle(headGlass, clear: clearPanel)
        setGlassStyle(headBackGlass, clear: clearPanel)
        for (_, glass) in extraTaskCards.values { setGlassStyle(glass, clear: clearPanel) }
        if let reviewGlass { setGlassStyle(reviewGlass, clear: clearPanel) }
        if let page = panelController?.page {
            panel?.close()
            show(page)
        }
    }

    @objc func toggleFollow() {
        follow.toggle()
        UserDefaults.standard.set(follow, forKey: "follow")
        configureCursorTimer()
    }
    @objc func resizePet(_ sender: NSMenuItem) {
        panel?.close()
        size = CGFloat(sender.tag)
        UserDefaults.standard.set(sender.tag, forKey: "size")
        layoutWindow()
        savePosition()
    }
    @objc private func resizeSlider(_ sender: NSSlider) {
        let next = CGFloat(min(240, max(120, sender.doubleValue)))
        guard next != size else { return }
        size = next
        UserDefaults.standard.set(Double(next), forKey: "size")
        layoutWindow()
        savePosition()
    }
    @objc func resetPosition() {
        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.maxX - window.frame.width - 40, y: screen.minY + 40))
            savePosition()
        }
    }
    func closePanelForDrag() { panel?.close() }
    func windowDidMove(_ notification: Notification) {
        guard let changed = notification.object as? NSWindow, changed === window else { return }
        // Options panels are separate windows; keep them attached to the pet
        // and inside the current screen while the user drags or it wanders.
        repositionOptionsPanel()
        positionReviewCard(); positionChatBubble()
    }
    private func repositionOptionsPanel(force: Bool = false) {
        guard let optionsPanel, optionsPanel.isVisible else { return }
        // The size slider must remain under the pointer as its value changes.
        // A genuine pet drag or a display change may still reanchor it.
        guard force || optionsPage != 0 || pet.dragging else { return }
        optionsPanel.setFrame(panelFrame(for: optionsPanel.frame.size), display: false)
    }
    func applicationDidChangeScreenParameters(_ notification: Notification) {
        guard window != nil else { return }; layoutWindow()
        repositionOptionsPanel(force: true)
        if let panel, panel.isVisible, reviewPanel == nil { panel.setFrame(panelFrame(for: panel.frame.size), display: true) }
    }
    func windowDidChangeScreen(_ notification: Notification) {
        guard let changed = notification.object as? NSWindow, changed === window else { return }
        positionReviewCard(); positionChatBubble()
        if let panel, panel.isVisible, reviewPanel == nil { panel.setFrame(panelFrame(for: panel.frame.size), display: true) }
        repositionOptionsPanel()
    }
    func finishDrag() {
        window.setFrameOrigin(constrained(window.frame.origin, size: window.frame.size))
        savePosition()
        presentPendingReview()
    }
    func savePosition() {
        let anchor = petAnchor
        UserDefaults.standard.set([anchor.x - size / 2, anchor.y - (controls ? 31 : 0)], forKey: "position")
    }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
