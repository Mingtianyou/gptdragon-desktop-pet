import AppKit

private func caption(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular,
                     color: NSColor = .secondaryLabelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    return field
}

enum ProviderIcon {
    static let codex: NSImage? = {
        let apps = [URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")].compactMap { $0 }
        for app in apps where Bundle(url: app)?.bundleIdentifier == "com.openai.codex" {
            if let url = Bundle(url: app)?.url(forResource: "chatgptTemplate", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                image.isTemplate = true
                return image
            }
        }
        return NSImage(systemSymbolName: "terminal", accessibilityDescription: "Codex")
    }()
}

final class ActivityPanel: NSViewController {
    enum Page { case activity, native }
    let page: Page
    private let outer = NSStackView()
    private let body = NSStackView()
    private let fileBody = NSStackView()
    private let width: CGFloat = 328
    private var files: [URL] = []
    private var fileGroups: [RecentChatFiles] = []
    private var openFileGroups = Set<String>()
    private var filesRequest: UUID?
    var didChooseChat: ((String) -> Void)?
    var didOpenCodex: (() -> Void)?
    var didSwitchToDraft: (() -> Void)?
    var didOpenApprovals: ((NSView) -> Void)?
    var didRequestFiles: ((UUID) -> Void)?
    var didResize: (() -> Void)?

    init(_ page: Page) {
        self.page = page
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 9
        outer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            outer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            outer.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            outer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            view.widthAnchor.constraint(equalToConstant: width)
        ])

        let title: String
        switch page {
        case .activity: title = "Codex 活动"
        case .native: title = "在原版 Mini 中继续"
        }
        let heading = caption(title, size: 15, weight: .semibold, color: .labelColor)
        if page == .activity {
            let button = NSButton(title: "新建", target: self, action: #selector(newDraft))
            button.bezelStyle = .inline
            let review = NSButton(image: NSImage(systemSymbolName: "checkmark.shield", accessibilityDescription: "审批与提问") ?? NSImage(),
                                  target: self, action: #selector(openApprovals(_:)))
            review.isBordered = false
            review.toolTip = "审批与提问"
            review.setAccessibilityLabel("审批与提问")
            let documents = NSButton(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage(),
                                     target: self, action: #selector(toggleFiles(_:)))
            documents.isBordered = false
            documents.toolTip = "最近文件"
            documents.setAccessibilityLabel("最近文件")
            let header = NSStackView(views: [heading, NSView(), documents, review, button])
            header.spacing = 6
            add(header)
        } else { add(heading) }
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 5
        add(body)
        switch page {
        case .activity:
            fileBody.orientation = .vertical
            fileBody.alignment = .leading
            fileBody.spacing = 6
            fileBody.isHidden = true
            add(fileBody)
            update([], note: "正在读取本机活动…")
        case .native:
            addLine("语音、审批和 Appshots 在 Codex 内完成。")
            addLine("默认按 ⌥ 空格可打开原版 Mini。")
            add(NSButton(title: "打开 Codex", target: self, action: #selector(openCodex)))
        }
    }

    private func add(_ child: NSView, to stack: NSStackView? = nil) {
        let container = stack ?? outer
        container.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
    }

    private func addLine(_ title: String, to stack: NSStackView? = nil) { add(caption(title), to: stack) }

    func update(_ chats: [ChatActivity], note: String) {
        guard page == .activity else { return }
        _ = view
        for child in body.arrangedSubviews { body.removeArrangedSubview(child); child.removeFromSuperview() }
        addLine(note, to: body)
        for chat in chats.prefix(7) {
            let status = chat.turn?.status
            let phase = status == .inProgress ? (chat.stage?.label ?? "思考中") : (status?.label ?? "最近对话")
            let row = ProcessCapsule(frame: .zero)
            row.pillBackground = true
            row.set(title: chat.title, phase: phase, symbol: status?.symbol ?? "bubble.left", extra: 0)
            row.onOpen = { [weak self] in self?.didChooseChat?(chat.id) }
            row.heightAnchor.constraint(equalToConstant: 38).isActive = true
            add(row, to: body)
        }
        preferredContentSize = view.fittingSize
    }

    @objc private func openCodex() { didOpenCodex?() }
    @objc private func newDraft() { didSwitchToDraft?() }
    @objc private func openApprovals(_ sender: NSButton) { didOpenApprovals?(sender) }

    @objc private func toggleFiles(_ sender: NSButton) {
        fileBody.isHidden.toggle()
        body.isHidden = !fileBody.isHidden
        let showingFiles = !fileBody.isHidden
        let label = showingFiles ? "返回活动列表" : "最近文件"
        sender.image = NSImage(systemSymbolName: showingFiles ? "folder.fill" : "folder", accessibilityDescription: label)
        sender.setAccessibilityLabel(label)
        sender.toolTip = label
        filesRequest = showingFiles ? UUID() : nil
        if let filesRequest {
            openFileGroups.removeAll()
            renderFiles(nil)
            didRequestFiles?(filesRequest)
        } else {
            preferredContentSize = view.fittingSize
            didResize?()
        }
    }

    func receiveFiles(_ urls: [RecentChatFiles], request: UUID) {
        guard filesRequest == request else { return }
        renderFiles(urls)
    }

    @objc private func toggleFileGroup(_ sender: NSButton) {
        guard fileGroups.indices.contains(sender.tag) else { return }
        let id = fileGroups[sender.tag].id
        if !openFileGroups.insert(id).inserted { openFileGroups.remove(id) }
        renderFiles(fileGroups)
    }

    private func renderFiles(_ groups: [RecentChatFiles]?) {
        fileGroups = groups ?? []
        files = []

        for row in fileBody.arrangedSubviews { fileBody.removeArrangedSubview(row); row.removeFromSuperview() }
        addLine("最近文件", to: fileBody)
        if fileGroups.isEmpty { addLine(groups == nil ? "正在读取…" : "暂无可查看的本机文件", to: fileBody) }
        for (groupIndex, group) in fileGroups.enumerated() {
            let isOpen = openFileGroups.contains(group.id)
            let button = NSButton(title: group.title, target: self, action: #selector(toggleFileGroup(_:)))
            button.bezelStyle = .inline
            button.alignment = .left
            button.tag = groupIndex
            button.lineBreakMode = .byTruncatingTail
            button.font = .systemFont(ofSize: 12, weight: .semibold)
            button.setAccessibilityLabel((isOpen ? "收起 " : "展开 ") + group.title + "，Codex")
            let disclosure = NSImageView(image: NSImage(systemSymbolName: isOpen ? "chevron.down" : "chevron.right", accessibilityDescription: nil) ?? NSImage())
            let appIcon = NSImageView(image: ProviderIcon.codex ?? NSImage())
            appIcon.contentTintColor = .labelColor
            appIcon.widthAnchor.constraint(equalToConstant: 15).isActive = true
            appIcon.heightAnchor.constraint(equalToConstant: 15).isActive = true
            add(NSStackView(views: [disclosure, appIcon, button]), to: fileBody)
            guard isOpen else { continue }
            for url in group.files {
                let index = files.count
                files.append(url)
                let canOpen = DeliveryFiles.canOpen(url)
                let file = NSButton(title: url.lastPathComponent, target: self,
                                    action: canOpen ? #selector(openFile(_:)) : #selector(revealFile(_:)))
                file.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
                file.imagePosition = .imageLeading
                file.bezelStyle = .inline
                file.lineBreakMode = .byTruncatingMiddle
                file.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                file.tag = index
                file.toolTip = (canOpen ? "打开 " : "在访达中显示 ") + url.lastPathComponent
                let row = NSStackView(views: [file, NSView()])
                if canOpen {
                    let label = "在访达中显示 " + url.lastPathComponent
                    let reveal = NSButton(image: NSImage(systemSymbolName: "folder", accessibilityDescription: label) ?? NSImage(),
                                          target: self, action: #selector(revealFile(_:)))
                    reveal.isBordered = false
                    reveal.toolTip = label
                    reveal.setAccessibilityLabel(label)
                    reveal.tag = index
                    row.addArrangedSubview(reveal)
                }
                let indent = NSView()
                indent.widthAnchor.constraint(equalToConstant: 19).isActive = true
                add(NSStackView(views: [indent, row]), to: fileBody)
            }
        }
        preferredContentSize = view.fittingSize
        didResize?()
    }

    @objc private func openFile(_ sender: NSButton) {
        guard files.indices.contains(sender.tag) else { return }
        let url = files[sender.tag]
        if DeliveryFiles.canOpen(url), NSWorkspace.shared.open(url) { return }
        revealFile(sender)
    }

    @objc private func revealFile(_ sender: NSButton) {
        guard files.indices.contains(sender.tag) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([files[sender.tag]])
    }
}

private final class PlaceholderEditor: NSTextView {
    var placeholder = "开始新任务…" { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: 5, y: 6), withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.placeholderTextColor
            ])
        }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

final class RailButtons: NSView {
    var acceptsClicks = false
    override func hitTest(_ point: NSPoint) -> NSView? { acceptsClicks ? super.hitTest(point) : nil }
}

final class InlineComposer: NSView, NSTextViewDelegate {
    enum Mode { case task, chat }
    private(set) var mode: Mode = .task
    private var chatBusy = false
    var acceptsClicks = false
    override func hitTest(_ point: NSPoint) -> NSView? { acceptsClicks ? super.hitTest(point) : nil }

    func restoreDraft(_ text: String) {
        if editor.string != text {
            editor.string = text
            editor.needsDisplay = true
            sync()
        }
    }

    let editor: NSTextView = PlaceholderEditor()
    private let scroll = NSScrollView()
    private let back = NSButton()
    private let modeButton = NSButton()
    private let send = NSButton()
    var didChange: ((String) -> Void)?
    var didSubmit: ((String) -> Void)?
    var didCancel: (() -> Void)?
    var didSwitchMode: ((Mode) -> Void)?
    var didStopChat: (() -> Void)?

    init(draft: String) {
        super.init(frame: .zero)
        for (button, icon, name, action) in [
            (back, "chevron.left", "收起输入框", #selector(cancel)),
            (send, "arrow.up.circle.fill", "在 Codex 打开草稿", #selector(submit))
        ] {
            button.image = NSImage(systemSymbolName: icon, accessibilityDescription: name)
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.target = self
            button.action = action
            button.toolTip = name
            button.setAccessibilityLabel(name)
            addSubview(button)
        }
        send.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 23, weight: .medium)
        modeButton.bezelStyle = .inline
        modeButton.target = self
        modeButton.action = #selector(toggleMode)
        modeButton.font = .systemFont(ofSize: 10, weight: .medium)
        addSubview(modeButton)
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        editor.isRichText = false
        editor.drawsBackground = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 0, height: 6)
        editor.textContainer?.widthTracksTextView = true
        editor.font = .systemFont(ofSize: 13)
        editor.allowsUndo = true
        editor.string = draft
        editor.delegate = self
        editor.setAccessibilityLabel("Codex 草稿")
        scroll.documentView = editor
        addSubview(scroll)
        setMode(.task)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        back.frame = NSRect(x: 5, y: 5, width: 25, height: 27)
        send.frame = NSRect(x: bounds.width - 35, y: 4, width: 30, height: 30)
        modeButton.frame = NSRect(x: 31, y: 6, width: 42, height: 25)
        scroll.frame = NSRect(x: 76, y: 3, width: max(40, bounds.width - 114), height: bounds.height - 6)
        editor.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(scroll.contentSize.height, editor.frame.height)))
    }

    var preferredHeight: CGFloat {
        let lines = editor.string.split(separator: "\n", omittingEmptySubsequences: false)
        let estimate = lines.reduce(0) { $0 + max(1, ($1.count + 30) / 31) }
        return CGFloat(max(38, min(86, 38 + (estimate - 1) * 16)))
    }

    func textDidChange(_ notification: Notification) {
        sync()
        didChange?(editor.string)
    }

    private var canSubmit: Bool {
        !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && editor.string.utf8.count <= 4000
    }
    private func sync() {
        let busy = mode == .chat && chatBusy
        send.isEnabled = canSubmit || busy
        send.image = NSImage(systemSymbolName: busy ? "stop.circle.fill" : "arrow.up.circle.fill", accessibilityDescription: nil)
        send.contentTintColor = send.isEnabled ? .controlAccentColor : .tertiaryLabelColor
        send.toolTip = busy ? "停止闲聊" : (mode == .chat ? "发送闲聊" : "在 Codex 打开草稿（回车）")
        send.setAccessibilityLabel(send.toolTip)
    }
    func setMode(_ value: Mode) {
        mode = value
        modeButton.title = value == .chat ? "闲聊" : "任务"
        modeButton.toolTip = value == .chat ? "切换到任务输入" : "切换到闲聊"
        modeButton.setAccessibilityLabel(modeButton.toolTip)
        (editor as? PlaceholderEditor)?.placeholder = value == .chat ? "和龙娘说点什么…" : "开始新任务…"
        editor.setAccessibilityLabel(value == .chat ? "闲聊输入" : "Codex 草稿")
        sync()
    }
    func setChatBusy(_ value: Bool) { chatBusy = value; sync() }
    @objc private func toggleMode() { didSwitchMode?(mode == .task ? .chat : .task) }
    @objc func submit() {
        if mode == .chat && chatBusy { didStopChat?(); return }
        if canSubmit { didSubmit?(editor.string) }
    }
    @objc private func cancel() { didCancel?() }
}

final class HoverRegion: NSView {
    var didEnter: (() -> Void)?
    var didExit: (() -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { didEnter?() }
    override func mouseExited(with event: NSEvent) { didExit?() }
}

// The visible rim behind the main capsule remains clickable.
final class TaskStackBack: NSView {
    var onClick: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

final class ProcessCapsule: NSView {
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let completionQuota = NSTextField(labelWithString: "")
    private let count = NSButton()
    private let button = NSButton()
    var onOpen: (() -> Void)?
    var onShowTasks: (() -> Void)?
    var pillBackground = false
    private var current: [String] = []
    private var completed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.isBordered = false
        button.title = ""
        button.target = self
        button.action = #selector(open)
        addSubview(button)
        for item in [icon, name, detail, completionQuota, count] { addSubview(item) }
        completionQuota.font = .systemFont(ofSize: 10, weight: .medium)
        completionQuota.textColor = .secondaryLabelColor
        completionQuota.lineBreakMode = .byTruncatingTail
        completionQuota.isHidden = true
        completionQuota.setAccessibilityElement(false)
        count.isBordered = false
        count.target = self
        count.action = #selector(showTasks)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        detail.font = .systemFont(ofSize: 10, weight: .medium)
        detail.textColor = .secondaryLabelColor
        count.font = .systemFont(ofSize: 10, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        name.setAccessibilityElement(false)
        detail.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    func set(title: String, phase: String, symbol: String, extra: Int) {
        let next = [title, phase, symbol, String(extra)]
        guard next != current else { return }
        current = next
        name.stringValue = title
        detail.stringValue = phase
        count.title = extra > 0 ? "\(extra + 1)" : ""
        count.isHidden = extra <= 0
        count.setAccessibilityLabel("切换任务，共 \(extra + 1) 个")
        count.toolTip = "切换任务"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        button.setAccessibilityLabel(title + "，" + phase)
        button.toolTip = title + " · " + phase
        needsLayout = true
    }
    func setProviderIcon(_ image: NSImage?) {
        guard !completed else { return }
        guard let image else { return }
        if icon.image !== image { icon.image = image }
        icon.contentTintColor = .labelColor
    }
    func setCompletion(_ value: Bool, quota: String?) {
        completed = value
        completionQuota.stringValue = quota ?? ""
        button.setAccessibilityValue(value ? quota : nil)
        completionQuota.isHidden = !value || quota == nil
        detail.font = .systemFont(ofSize: value ? 11 : 10, weight: value ? .semibold : .medium)
        detail.textColor = value ? .systemGreen : .secondaryLabelColor
        if value {
            icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "任务完成")
            icon.contentTintColor = .systemGreen
        }
        needsDisplay = true
        needsLayout = true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === count && onShowTasks != nil ? count : button
    }
    override func draw(_ dirtyRect: NSRect) {
        guard pillBackground || completed else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 15, yRadius: 15)
        (completed ? NSColor.systemGreen.withAlphaComponent(0.065) : NSColor.labelColor.withAlphaComponent(0.055)).setFill()
        shape.fill()
        (completed ? NSColor.systemGreen.withAlphaComponent(0.32) : NSColor.labelColor.withAlphaComponent(0.075)).setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
    }
    override func layout() {
        super.layout()
        button.frame = bounds
        icon.frame = NSRect(x: 10, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let trailing: CGFloat = count.title.isEmpty ? 10 : 30
        name.frame = NSRect(x: 34, y: bounds.height - 18, width: bounds.width - 34 - trailing, height: 15)
        detail.frame = NSRect(x: 34, y: completed ? 21 : 6, width: bounds.width - 34 - trailing, height: 14)
        completionQuota.frame = NSRect(x: 34, y: 5, width: bounds.width - 44, height: 13)
        count.frame = NSRect(x: bounds.width - 31, y: 5, width: 27, height: 28)
    }
    @objc private func open() { onOpen?() }
    @objc private func showTasks() { onShowTasks?() }
}

private final class ReviewDocument: NSView {
    override var isFlipped: Bool { true }
}

final class ReviewPanel: NSViewController, NSTextFieldDelegate {
    private let scroll = NSScrollView()
    private var document = ReviewDocument()
    private var signature = ""
    private var choices: [String: String] = [:]
    private var typedChoices: Set<String> = []
    private var submittedKey: String?
    private var fields: [String: NSTextField] = [:]
    private var radios: [String: [NSButton]] = [:]
    private var submitButton: NSButton?
    private var activeReview: LiveReview?
    private var selectedKey: String?
    private let cardWidth: CGFloat = 288
    private let inset: CGFloat = 8
    var onConnect: (() -> Void)?
    var onClose: (() -> Void)?
    var onOpenNative: ((String?) -> Void)?
    var onDecision: ((LiveReview, String) -> Void)?
    var onAnswers: ((LiveReview, [String: String]) -> Void)?
    var threadTitle: ((String) -> String)?

    func selectThread(_ id: String, reviews: [LiveReview]) {
        guard let review = reviews.first(where: { $0.thread == id }) else { return }
        selectedKey = review.key
        signature = ""
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: cardWidth, height: 110))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        // On unusually small displays the card can be narrower than its
        // content; keep every decision reachable instead of clipping it.
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.frame = view.bounds.insetBy(dx: inset, dy: inset)
        scroll.autoresizingMask = [.width, .height]
        view.addSubview(scroll)
    }

    func update(_ reviews: [LiveReview], enabled: Bool, status: String) {
        _ = view
        let selected = reviews.first { $0.key == selectedKey } ?? reviews.first
        let keys = reviews.map(\.key).joined(separator: "|")
        let next = "\(enabled):\(status):\(keys):\(selected?.key ?? "")"
        if signature == next,
           NSDictionary(dictionary: activeReview?.payload ?? [:]).isEqual(to: selected?.payload ?? [:]) { return }
        let same = selected?.key == activeReview?.key && NSDictionary(dictionary: activeReview?.payload ?? [:]).isEqual(to: selected?.payload ?? [:])
        signature = next
        activeReview = selected
        selectedKey = selected?.key
        if !same { choices = [:]; typedChoices = []; submittedKey = nil }
        fields = [:]
        radios = [:]
        submitButton = nil

        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 5
        body.translatesAutoresizingMaskIntoConstraints = false
        document = ReviewDocument()
        document.addSubview(body)
        let width = cardWidth - 2 * inset
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalToConstant: width)
        ])

        func line(_ text: String, heading: Bool = false) {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: heading ? 13 : 12, weight: heading ? .semibold : .regular)
            label.textColor = heading ? .labelColor : .secondaryLabelColor
            label.maximumNumberOfLines = 0
            label.preferredMaxLayoutWidth = width
            label.isSelectable = !heading
            add(label, to: body)
        }

        let title: String
        switch selected?.kind {
        case let .decision(heading, _, _, _): title = heading
        case .permissions: title = "允许本轮使用以下权限？"
        case .questions: title = "请选择"
        case .computerUse: title = "允许使用应用？"
        case .native: title = "需要处理的请求"
        case nil: title = "审批与提问"
        }
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        let native = iconButton("arrow.up.right.square", label: "在 Codex 查看", action: #selector(openNative))
        let collapse = iconButton("chevron.down", label: "收起审批卡片", action: #selector(closeCard))
        let header = NSStackView(views: [heading, NSView(), native, collapse])
        header.spacing = 4
        add(header, to: body)
        if let selected, let title = threadTitle?(selected.thread), !title.isEmpty {
            line(title)
        }

        if reviews.count > 1 {
            let picker = NSPopUpButton()
            picker.controlSize = .small
            for (index, review) in reviews.enumerated() {
                let label = review.isQuestion ? "提问" : "审批"
                let title = threadTitle?(review.thread) ?? ""
                picker.addItem(withTitle: "\(index + 1). \(label)" + (title.isEmpty ? "" : " · " + title))
                picker.lastItem?.representedObject = review.key
            }
            if let index = reviews.firstIndex(where: { $0.key == selectedKey }) { picker.selectItem(at: index) }
            picker.target = self
            picker.action = #selector(selectReview(_:))
            add(picker, to: body)
        }
        if selected != nil && (status.contains("未确认") || status.contains("未获确认") || status.contains("已更新")) {
            line(status)
        }
        if let selected {
            switch selected.kind {
            case let .decision(_, detail, allowed, _):
                line(detail)
                addDecisions(allowed, to: body)
            case let .permissions(detail, _):
                line(detail)
                addDecisions(["accept", "decline"], to: body)
            case let .questions(questions):
                if questions.count > 1 { line("选完即提交；填写其他答案后请点提交。") }
                for question in questions {
                    if !question.title.isEmpty, question.title != question.text { line(question.title) }
                    line(question.text, heading: true)
                    addQuestion(question, to: body)
                }
                let button = smallButton("提交答案", action: #selector(submit))
                button.isEnabled = activeReview?.response(answers: choices) != nil
                button.isHidden = typedChoices.isEmpty
                submitButton = button
                addActionRow([button], to: body)
            case let .computerUse(message, detail):
                line(message, heading: true)
                line(detail)
                addDecisions(["acceptForSession", "decline"], to: body)
            case .native:
                let kind: String
                switch selected.method {
                case "item/commandExecution/requestApproval": kind = "终端命令审批"
                case "item/fileChange/requestApproval": kind = "文件修改审批"
                case "mcpServer/elicitation/request": kind = "连接工具的确认或表单"
                case "item/tool/requestOptionPicker": kind = "选项选择"
                default: kind = "此类请求"
                }
                line(kind + "需要在 Codex 查看完整内容并处理。")
            }
        } else {
            line(status)
            if !enabled {
                addActionRow([smallButton("连接本机 Codex", action: #selector(connect))], to: body)
            }
        }
        let height = ceil(document.fittingSize.height)
        document.frame.size = NSSize(width: width, height: height)
        preferredContentSize = NSSize(width: cardWidth, height: min(height, 284) + 2 * inset)
        scroll.documentView = document
    }

    private func add(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func smallButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private func iconButton(_ name: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    private func addActionRow(_ buttons: [NSButton], to stack: NSStackView) {
        let row = NSStackView(views: [NSView()] + buttons)
        row.spacing = 5
        add(row, to: stack)
    }

    private func addDecisions(_ decisions: [String], to stack: NSStackView) {
        let captions = ["accept": "允许本次", "acceptForSession": "本次会话允许", "decline": "拒绝", "cancel": "取消"]
        let buttons = decisions.reversed().map { decision in
            let button = smallButton(captions[decision] ?? decision, action: #selector(decide(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(decision)
            if decision == "accept" || decision == "acceptForSession" { button.bezelColor = .systemBlue }
            return button
        }
        addActionRow(buttons, to: stack)
    }

    private func addQuestion(_ q: ReviewQuestion, to stack: NSStackView) {
        for option in q.options {
            let button = NSButton(radioButtonWithTitle: option.label, target: self, action: #selector(selectOption(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(q.id)
            button.toolTip = option.detail
            button.state = choices[q.id] == option.label && !typedChoices.contains(q.id) ? .on : .off
            radios[q.id, default: []].append(button)
            add(button, to: stack)
            if !option.detail.isEmpty {
                let label = NSTextField(wrappingLabelWithString: option.detail)
                label.font = .systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
                add(label, to: stack)
            }
        }
        if q.allowsOther {
            let field = q.secret ? NSSecureTextField() : NSTextField()
            field.placeholderString = q.options.isEmpty ? "输入答案" : "其他答案"
            field.identifier = NSUserInterfaceItemIdentifier(q.id)
            field.delegate = self
            if typedChoices.contains(q.id) { field.stringValue = choices[q.id] ?? "" }
            fields[q.id] = field
            add(field, to: stack)
        }
    }

    private func refreshSubmit() {
        submitButton?.isEnabled = activeReview?.response(answers: choices) != nil
        submitButton?.isHidden = typedChoices.isEmpty
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let id = field.identifier?.rawValue else { return }
        radios[id]?.forEach { $0.state = .off }
        choices[id] = field.stringValue
        typedChoices.insert(id)
        refreshSubmit()
    }

    @objc private func selectOption(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        choices[id] = sender.title
        typedChoices.remove(id)
        radios[id]?.forEach { $0.state = $0 === sender ? .on : .off }
        fields[id]?.stringValue = ""
        refreshSubmit()
        if typedChoices.isEmpty, let review = activeReview, submittedKey != review.key,
           review.response(answers: choices) != nil {
            submittedKey = review.key
            onAnswers?(review, choices)
        }
    }

    @objc private func selectReview(_ sender: NSPopUpButton) {
        selectedKey = sender.selectedItem?.representedObject as? String
        signature = ""
        onRefresh?()
    }

    var onRefresh: (() -> Void)?
    @objc private func connect() { onConnect?() }
    @objc private func closeCard() { onClose?() }
    @objc private func openNative() { onOpenNative?(activeReview?.thread) }
    @objc private func decide(_ sender: NSButton) {
        if let review = activeReview, let decision = sender.identifier?.rawValue { onDecision?(review, decision) }
    }
    @objc private func submit() { if let review = activeReview { onAnswers?(review, choices) } }
}
