import AppKit
import Foundation

// Crop the top-left WxH region of an image (qlmanage pads SVGs to a square;
// this recovers the exact background dimensions). Env: IN, OUT, W, H.

func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] }
guard let inPath = env("IN"), let outPath = env("OUT"),
      let w = Int(env("W") ?? ""), let h = Int(env("H") ?? ""),
      let src = NSImage(contentsOfFile: inPath) else {
    FileHandle.standardError.write("set IN, OUT, W, H\n".data(using: .utf8)!)
    exit(1)
}

let srcRep = src.representations.first as? NSBitmapImageRep
let srcW = srcRep?.pixelsWide ?? Int(src.size.width)
let srcH = srcRep?.pixelsHigh ?? Int(src.size.height)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
rep.size = NSSize(width: w, height: h)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high
// Draw the source so its top-left aligns with the output's top-left.
src.draw(in: NSRect(x: 0, y: CGFloat(h - srcH), width: CGFloat(srcW), height: CGFloat(srcH)),
         from: .zero, operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
do { try png.write(to: URL(fileURLWithPath: outPath)) } catch { exit(1) }
print("wrote \(outPath) (\(w)x\(h))")
