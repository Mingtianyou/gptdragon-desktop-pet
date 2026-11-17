import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: split <atlas> <existing output directory>")
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let atlas = CGImageSourceCreateImageAtIndex(source, 0, nil),
      atlas.width == 1536, atlas.height == 2288 else { fatalError("Invalid animation atlas") }
let widths = [6,8,8,4,5,8,6,6,6,8,8]
for (row, frames) in widths.enumerated() {
    let path = output.appendingPathComponent("row-\(row).png")
    let region = CGRect(x: 0, y: row * 208, width: 192 * frames, height: 208)
    guard let strip = atlas.cropping(to: region),
          let file = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Unable to write row \(row)") }
    CGImageDestinationAddImage(file, strip, nil)
    guard CGImageDestinationFinalize(file) else { fatalError("Unable to encode row \(row)") }
}
