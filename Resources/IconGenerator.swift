import AppKit

// Original vector artwork. Run through the repository's generate-icon.sh script.
private func colour(_ rgb: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((rgb >> 16) & 255) / 255,
        green: CGFloat((rgb >> 8) & 255) / 255,
        blue: CGFloat(rgb & 255) / 255,
        alpha: 1
    )
}

private func drawIcon(in context: CGContext, small: Bool) {
    let tile = CGPath(roundedRect: CGRect(x: 52, y: 52, width: 920, height: 920),
                      cornerWidth: 208, cornerHeight: 208, transform: nil)
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [colour(0x8C2937), colour(0xD45A47)] as CFArray,
                              locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 75, y: 80),
                               end: CGPoint(x: 950, y: 950), options: [])
    context.restoreGState()

    // A saved transcript page with a microphone and waveform: purpose-drawn
    // artwork, kept legible at menu and Dock sizes.
    context.setFillColor(colour(0xF9EFE5))
    context.addPath(CGPath(roundedRect: CGRect(x: 248, y: 190, width: 528, height: 644),
                           cornerWidth: 68, cornerHeight: 68, transform: nil))
    context.fillPath()
    context.setFillColor(colour(0xD14F43))
    context.addPath(CGPath(roundedRect: CGRect(x: 455, y: 475, width: 114, height: 205),
                           cornerWidth: 57, cornerHeight: 57, transform: nil))
    context.fillPath()
    context.setStrokeColor(colour(0xA3313B))
    context.setLineWidth(small ? 42 : 36)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    let mic = CGMutablePath()
    mic.move(to: CGPoint(x: 398, y: 553))
    mic.addLine(to: CGPoint(x: 398, y: 523))
    mic.addCurve(to: CGPoint(x: 626, y: 523), control1: CGPoint(x: 398, y: 370), control2: CGPoint(x: 626, y: 370))
    mic.addLine(to: CGPoint(x: 626, y: 553))
    mic.move(to: CGPoint(x: 512, y: 410))
    mic.addLine(to: CGPoint(x: 512, y: 372))
    mic.move(to: CGPoint(x: 462, y: 372))
    mic.addLine(to: CGPoint(x: 562, y: 372))
    context.addPath(mic)
    context.strokePath()
    context.setStrokeColor(colour(0xD14F43))
    context.setLineWidth(small ? 27 : 22)
    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: 349, y: 288))
    wave.addLine(to: CGPoint(x: 410, y: 288))
    wave.addLine(to: CGPoint(x: 430, y: 317))
    wave.addLine(to: CGPoint(x: 460, y: 261))
    wave.addLine(to: CGPoint(x: 490, y: 307))
    wave.addLine(to: CGPoint(x: 514, y: 275))
    wave.addLine(to: CGPoint(x: 538, y: 297))
    wave.addLine(to: CGPoint(x: 560, y: 288))
    wave.addLine(to: CGPoint(x: 675, y: 288))
    context.addPath(wave)
    context.strokePath()
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: IconGenerator.swift <output.iconset or output.appiconset>\n", stderr)
    exit(2)
}
let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard ["iconset", "appiconset"].contains(destination.pathExtension) else {
    fputs("Output directory must end in .iconset or .appiconset\n", stderr)
    exit(2)
}
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let isCatalog = destination.pathExtension == "appiconset"
let colourSpace = CGColorSpace(name: CGColorSpace.sRGB)!

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: 0, space: colourSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            fatalError("Could not allocate a \(pixels)-pixel icon")
        }
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        drawIcon(in: context, small: pixels <= 32)
        guard let rendered = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else {
            fatalError("Could not encode a \(pixels)-pixel icon")
        }
        let suffix = scale == 2 ? "@2x" : ""
        let name = isCatalog
            ? "appicon-\(points)\(suffix).png"
            : "icon_\(points)x\(points)\(suffix).png"
        let target = destination.appendingPathComponent(name)
        if (try? Data(contentsOf: target)) != png {
            try png.write(to: target, options: .atomic)
        }
    }
}
