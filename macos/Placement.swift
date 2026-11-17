import AppKit

enum PetPlacement {
    // NSMenu positions its top-left corner at the supplied point. Keep the
    // whole menu within the usable display whenever it fits; on short screens
    // AppKit can still scroll a menu taller than the visible area.
    static func menuAnchor(size: NSSize, pointer: NSPoint, visible: NSRect) -> NSPoint {
        let bounds = visible.insetBy(dx: 8, dy: 8)
        let x = size.width <= bounds.width
            ? min(max(pointer.x, bounds.minX), bounds.maxX - size.width) : bounds.minX
        let y = size.height <= bounds.height
            ? min(max(pointer.y, bounds.minY + size.height), bounds.maxY) : bounds.maxY
        return NSPoint(x: x, y: y)
    }
    static func fit(_ size: NSSize, in visible: NSRect, margin: CGFloat = 6) -> NSSize {
        NSSize(width: min(max(1, size.width), max(1, visible.width - margin * 2)),
               height: min(max(1, size.height), max(1, visible.height - margin * 2)))
    }
    static func headFrame(size: NSSize, pet: NSRect, visible: NSRect) -> NSRect {
        let margin: CGFloat = 8
        let fitted = fit(size, in: visible, margin: margin)
        let bounds = visible.insetBy(dx: margin, dy: margin)
        let x = min(max(pet.midX - fitted.width / 2, bounds.minX), bounds.maxX - fitted.width)
        let y = min(max(pet.maxY + 1, bounds.minY), bounds.maxY - fitted.height)
        return NSRect(x: x, y: y, width: fitted.width, height: fitted.height).integral
    }

    static func frame(size: NSSize, pet: NSRect, visible: NSRect, above: Bool = false) -> NSRect {
        let gap: CGFloat = 8, fitted = fit(size, in: visible, margin: gap)
        let candidates: [NSPoint] = above ? [
            NSPoint(x: pet.midX - fitted.width / 2, y: pet.maxY + gap),
            NSPoint(x: pet.midX - fitted.width / 2, y: pet.minY - fitted.height - gap),
            NSPoint(x: pet.maxX + gap, y: pet.midY - fitted.height / 2),
            NSPoint(x: pet.minX - fitted.width - gap, y: pet.midY - fitted.height / 2)
        ] : [
            NSPoint(x: pet.maxX + gap, y: pet.midY - fitted.height / 2),
            NSPoint(x: pet.minX - fitted.width - gap, y: pet.midY - fitted.height / 2),
            NSPoint(x: pet.midX - fitted.width / 2, y: pet.maxY + gap),
            NSPoint(x: pet.midX - fitted.width / 2, y: pet.minY - fitted.height - gap)
        ]
        let inset = visible.insetBy(dx: gap, dy: gap)
        func clip(_ p: NSPoint) -> NSRect {
            NSRect(x: min(max(p.x, inset.minX), inset.maxX - fitted.width), y: min(max(p.y, inset.minY), inset.maxY - fitted.height), width: fitted.width, height: fitted.height).integral
        }
        let fits = candidates.map { NSRect(origin: $0, size: fitted) }
        if let found = fits.first(where: { inset.contains($0) }) { return found.integral }
        return candidates.map(clip).min { a, b in
            let ia = a.intersection(pet), ib = b.intersection(pet)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        } ?? clip(candidates[0])
    }
}

struct PetWanderPlan {
    let origin: NSPoint
    let target: NSPoint
    let duration: TimeInterval
    var delta: NSPoint { NSPoint(x: target.x - origin.x, y: target.y - origin.y) }
    static func make(origin: NSPoint, size: NSSize, visible: NSRect, angle: Double, distance: CGFloat) -> PetWanderPlan? {
        guard visible.width >= size.width, visible.height >= size.height, (0...48).contains(distance), angle.isFinite else { return nil }
        let maxX = visible.maxX - size.width, maxY = visible.maxY - size.height
        guard origin.x >= visible.minX, origin.y >= visible.minY, origin.x <= maxX, origin.y <= maxY else { return nil }
        let target = NSPoint(x: min(max(origin.x + cos(angle) * distance, visible.minX), maxX),
                             y: min(max(origin.y + sin(angle) * distance, visible.minY), maxY))
        let length = hypot(target.x - origin.x, target.y - origin.y)
        guard length > 5 else { return nil }
        return PetWanderPlan(origin: origin, target: target, duration: max(2.2, Double(length / 15)))
    }
}
