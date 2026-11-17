import AppKit
import Accelerate

// Fixed per-action lookup tables preserve frame geometry and alpha.
private func toneTable(_ points: [(Int, Int)]) -> [UInt8] {
    (0...255).map { v in
        for i in 0..<(points.count-1) where v <= points[i+1].0 {
            let (x0,y0)=points[i], (x1,y1)=points[i+1]
            let t=Double(v-x0)/Double(x1-x0)
            return UInt8(clamping:Int((Double(y0)+t*Double(y1-y0)).rounded()))
        }
        return 255
    }
}
private struct ToneTables {
    let r:[UInt8], g:[UInt8], b:[UInt8]
}
private let identityTable = (0...255).map { UInt8($0) }
private let workTone = ToneTables(
    r:toneTable([(0,0),(130,130),(191,196),(215,228),(255,255)]),
    g:toneTable([(0,0),(130,130),(182,186),(208,222),(255,255)]),
    b:toneTable([(0,0),(140,140),(204,209),(217,229),(255,255)]))
private let liftTone = ToneTables(
    r:toneTable([(0,0),(140,140),(199,196),(237,228),(255,248)]),
    g:toneTable([(0,0),(130,130),(188,186),(230,222),(255,246)]),
    b:toneTable([(0,0),(140,140),(217,209),(244,229),(255,245)]))
private let celebrationTone = ToneTables(
    r:toneTable([(0,0),(130,130),(191,196),(224,228),(255,255)]),
    g:toneTable([(0,0),(130,130),(181,186),(218,222),(255,255)]),
    b:toneTable([(0,0),(140,140),(205,209),(226,229),(255,255)]))

// Restore faint pixels along the existing lift silhouette. This changes no
// alpha or geometry, and leaves already-dark outline pixels untouched.
private func repairLiftContour(_ buffer: vImage_Buffer) {
    let base = buffer.data.assumingMemoryBound(to: UInt8.self)
    let rowBytes = buffer.rowBytes
    let width = Int(buffer.width), height = Int(buffer.height)
    guard width % 384 == 0, height >= 3 else { return }
    for y in 1..<(height - 1) {
        let row = y * rowBytes
        for x in 1..<(width - 1) {
            // Separate four adjacent frames; never borrow another frame's edge.
            if x % 384 == 0 || x % 384 == 383 { continue }
            let i = row + x * 4
            let alpha = Int(base[i + 3])
            guard alpha >= 80 else { continue }
            if base[i - 1] >= 80 && base[i + 7] >= 80 &&
               base[i - rowBytes + 3] >= 80 && base[i + rowBytes + 3] >= 80 { continue }
            let r = Int(base[i]), g = Int(base[i+1]), b = Int(base[i+2])
            let light = (77*r + 150*g + 29*b) / 256
            guard light > 105 else { continue }
            let weight = min(0.88, Double(light - 105) / 115.0 * 0.88)
            base[i] = UInt8(clamping: Int((Double(r) * (1-weight) + 62 * weight).rounded()))
            base[i+1] = UInt8(clamping: Int((Double(g) * (1-weight) + 57 * weight).rounded()))
            base[i+2] = UInt8(clamping: Int((Double(b) * (1-weight) + 72 * weight).rounded()))
        }
    }
}

func colorBalancedSprite(_ image: CGImage, action: String) -> CGImage? {
    let tables: ToneTables
    switch action {
    case "work", "blocked": tables = workTone
    case "lift": tables = liftTone
    case "celebrate": tables = celebrationTone
    default: return image
    }
    let w=image.width,h=image.height
    guard let space=CGColorSpace(name:CGColorSpace.sRGB),
          let ctx=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:space,
            bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
          let data=ctx.data else { return nil }
    ctx.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
    var src=vImage_Buffer(data:data,height:vImagePixelCount(h),width:vImagePixelCount(w),rowBytes:ctx.bytesPerRow)
    var dst=src
    guard vImageUnpremultiplyData_RGBA8888(&src,&dst,0)==kvImageNoError else { return nil }
    guard vImageTableLookUp_ARGB8888(&src,&dst,tables.r,tables.g,tables.b,identityTable,0)==kvImageNoError else { return nil }
    if action == "lift" { repairLiftContour(src) }
    guard vImagePremultiplyData_RGBA8888(&src,&dst,0)==kvImageNoError else { return nil }
    return ctx.makeImage()
}
