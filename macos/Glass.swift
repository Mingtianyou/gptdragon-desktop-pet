import AppKit

@available(macOS 26.0, *)
private final class TintedGlassView: NSGlassEffectView {
    var tintStrength: CGFloat = 1

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTint()
    }

    func updateTint() {
        guard style == .clear, tintStrength > 0 else { tintColor = nil; return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        tintColor = NSColor(white: dark ? 0.12 : 0.96, alpha: (dark ? 0.24 : 0.27) * tintStrength)
    }
}

func makeGlass(content: NSView, radius: CGFloat, clear: Bool, textSurface: Bool = false, tintStrength: CGFloat = 1) -> NSView {
    content.autoresizingMask = [.width, .height]
    if #available(macOS 26.0, *) {
        let glass: NSGlassEffectView = textSurface ? TintedGlassView() : NSGlassEffectView()
        glass.cornerRadius = radius
        glass.style = clear ? .clear : .regular
        glass.contentView = content
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) { glass.effectIsInteractive = textSurface }
        #endif
        if let tinted = glass as? TintedGlassView {
            tinted.tintStrength = tintStrength
            tinted.updateTint()
        }
        return glass
    }
    let blur = NSVisualEffectView()
    blur.material = clear ? .hudWindow : .popover
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.wantsLayer = true
    blur.layer?.cornerRadius = radius
    blur.layer?.masksToBounds = true
    blur.addSubview(content)
    return blur
}

final class FloatingGlassPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onDraftSubmit: (() -> Void)?
    var keyAllowed = true

    override var canBecomeKey: Bool { keyAllowed }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == 53, (firstResponder as? NSTextView)?.hasMarkedText() != true {
                cancelOperation(nil)
                return
            }
            if let text = firstResponder as? NSTextView, !text.hasMarkedText(),
               (event.keyCode == 36 || event.keyCode == 76),
               event.modifierFlags.intersection([.shift, .option, .control]).isEmpty,
               let onDraftSubmit {
                onDraftSubmit()
                return
            }
            if let text = firstResponder as? NSTextView, handleEditingShortcut(event, text: text) { return }
        }
        super.sendEvent(event)
    }

    private func handleEditingShortcut(_ event: NSEvent, text: NSTextView) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        if flags == [.command, .shift], key == "z" {
            text.undoManager?.redo()
            return true
        }
        guard flags == .command else { return false }
        switch key {
        case "v": text.paste(nil)
        case "c": text.copy(nil)
        case "x": text.cut(nil)
        case "a": text.selectAll(nil)
        case "z": text.undoManager?.undo()
        default: return false
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) { if let onCancel { onCancel() } else { close() } }
}

func setGlassRadius(_ view: NSView, radius: CGFloat) {
    if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
        if glass.cornerRadius != radius { glass.cornerRadius = radius }
    } else { view.layer?.cornerRadius = radius }
}

func setGlassStyle(_ view: NSView, clear: Bool) {
    if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
        glass.style = clear ? .clear : .regular
        (glass as? TintedGlassView)?.updateTint()
    } else if let blur = view as? NSVisualEffectView {
        blur.material = clear ? .hudWindow : .popover
    }
}
