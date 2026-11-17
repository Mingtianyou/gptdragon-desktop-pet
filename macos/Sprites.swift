import AppKit
import ImageIO

// Source videos contain isolated chroma corruption at these frames.  Holding
// the closest intact neighbor keeps the original timing and avoids warping.
private let videoFrameRepairs: [String: [Int: Int]] = [
    "idle": [10:11, 60:59, 110:111, 160:161, 210:211],
    "work": [10:11, 60:59, 110:111],
    "blocked": [60:59, 110:111],
    // Three additional frames briefly jump away from their neighbors.
    "celebrate": [10:11, 60:59, 110:111, 143:142, 160:161, 178:179, 182:183, 210:209],
    "greet": [10:9, 60:59, 110:111, 160:159, 210:211],
    "hair": [10:11, 60:59, 110:111, 160:159],
    "happy": [10:9, 60:61, 110:111, 160:159, 210:211],
    "run": [10:11, 60:59, 110:111],
    "lift": [10:11, 60:61, 110:111],
    "tail": [10:9, 60:61, 110:111]
]

func stableVideoFrame(_ name: String, frame: Int) -> Int {
    videoFrameRepairs[name]?[frame] ?? frame
}

// Only the original, hand-drawn sprite rows are loaded.
final class SpriteRows {
    private let cache = NSCache<NSNumber, CGImage>()
    init() {
        cache.countLimit = 2
        cache.totalCostLimit = 3 * 1024 * 1024
    }
    func releaseIdle() {}

    func frame(row: Int, column: Int) -> CGImage? {
        let key = NSNumber(value: row)
        let image: CGImage
        if let cached = cache.object(forKey: key) { image = cached }
        else {
            guard let path = Bundle.main.url(forResource: "row-\(row)", withExtension: "png", subdirectory: "Rows"),
                  let source = CGImageSourceCreateWithURL(path as CFURL, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { return nil }
            image = decoded
            cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        }
        return image.cropping(to: CGRect(x: column * 192, y: 0, width: 192, height: 208))
    }
}

// Four-frame transparent strips are decoded on demand. Only a small bounded
// set stays resident; the next strip is prepared away from the UI thread.
extension SpriteRows {
    private static let actionCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 10 * 1024 * 1024
        cache.countLimit = 4
        return cache
    }()
    private static let actionQueue = DispatchQueue(label: "local.codex.gptdragon.actions", qos: .userInitiated)
    private static let actionLock = NSLock()
    private static var queued: Set<String> = []

    private func loadActionStrip(_ name: String, index: Int) -> CGImage? {
        let key = "\(name)/\(index)" as NSString
        if let cached = Self.actionCache.object(forKey: key) { return cached }
        guard let url = Bundle.main.url(forResource: String(format: "%03d", index), withExtension: "png", subdirectory: "Actions/\(name)"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        // These animations were processed once at build time using the same
        // fixed color and contour functions. Avoid recalculating them every
        // time a strip falls out of the bounded cache.
        let image = decoded
        Self.actionCache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
    func actionFrame(_ name: String, frame: Int) -> CGImage? {
        let selected = stableVideoFrame(name, frame: frame)
        guard selected >= 0, let image = loadActionStrip(name, index: selected / 4) else { return nil }
        return image.cropping(to: CGRect(x: (selected % 4) * 384, y: 0, width: 384, height: 416))
    }
    func prefetchAction(_ name: String, frame: Int) {
        let index = frame / 4, key = "\(name)/\(index)"
        if Self.actionCache.object(forKey: key as NSString) != nil { return }
        Self.actionLock.lock()
        let inserted = Self.queued.insert(key).inserted
        Self.actionLock.unlock()
        guard inserted else { return }
        Self.actionQueue.async { [weak self] in
            _ = self?.loadActionStrip(name, index: index)
            Self.actionLock.lock(); Self.queued.remove(key); Self.actionLock.unlock()
        }
    }
}
