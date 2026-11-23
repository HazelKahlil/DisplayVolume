import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((rgb >> 16) & 255) / 255,
        green: CGFloat((rgb >> 8) & 255) / 255,
        blue: CGFloat(rgb & 255) / 255,
        alpha: alpha
    )
}

func drawLinear(_ ctx: CGContext, colors: [CGColor], locations: [CGFloat]? = nil, from: CGPoint, to: CGPoint) {
    let grad = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(grad, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func drawRadial(_ ctx: CGContext, colors: [CGColor], locations: [CGFloat]? = nil, center: CGPoint, startRadius: CGFloat, endRadius: CGFloat) {
    let grad = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
    ctx.drawRadialGradient(grad, startCenter: center, startRadius: startRadius, endCenter: center, endRadius: endRadius, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func renderIcon(size: Int, to url: URL) throws {
    let isCompact = size <= 48
    let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    // Apple macOS 1024x1024 grid: 824x824 squircle
    let squircleRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: squircleRect, cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)

    // 1. Ambient Dock drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 34, color: color(0x020612, alpha: 0.42))
    ctx.setFillColor(color(0x11151C))
    ctx.addPath(squircle)
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Neutral Graphite-Obsidian Studio Glass Enclosure (matches macOS Tahoe monochrome glass)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    drawLinear(
        ctx,
        colors: [color(0x2D333E), color(0x181C24), color(0x0C0F14)],
        locations: [0.0, 0.50, 1.0],
        from: CGPoint(x: 200, y: 924),
        to: CGPoint(x: 824, y: 100)
    )

    // Soft top-left Fresnel sheen
    drawRadial(
        ctx,
        colors: [color(0xFFFFFF, alpha: 0.14), color(0x94A3B8, alpha: 0.04), color(0x000000, alpha: 0.0)],
        locations: [0.0, 0.52, 1.0],
        center: CGPoint(x: 310, y: 850),
        startRadius: 10,
        endRadius: 620
    )

    // Subtle external monitor glass frame outline inside the icon (tells the story: Display + Volume!)
    if !isCompact {
        let bezelRect = CGRect(x: 192, y: 274, width: 640, height: 472)
        let bezel = CGPath(roundedRect: bezelRect, cornerWidth: 52, cornerHeight: 52, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(color(0x0A0D12, alpha: 0.48))
        ctx.addPath(bezel)
        ctx.fillPath()

        ctx.setLineWidth(7)
        ctx.setStrokeColor(color(0xE2E8F0, alpha: 0.22))
        ctx.addPath(bezel)
        ctx.strokePath()
        ctx.restoreGState()

        // Minimal Studio Display stand neck & base
        ctx.saveGState()
        let stand = CGMutablePath()
        stand.addRoundedRect(in: CGRect(x: 478, y: 204, width: 68, height: 70), cornerWidth: 10, cornerHeight: 10)
        stand.addRoundedRect(in: CGRect(x: 386, y: 184, width: 252, height: 22), cornerWidth: 11, cornerHeight: 11)
        ctx.setFillColor(color(0x94A3B8, alpha: 0.34))
        ctx.addPath(stand)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 3. Bold Sculpted Liquid-Glass Speaker Cone + Sound Waves (Centered in display)
    let centerY: CGFloat = isCompact ? 536 : 538
    let speakerLeftX: CGFloat = isCompact ? 260 : 302

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x000000, alpha: 0.45))

    let cone = CGMutablePath()
    if isCompact {
        cone.move(to: CGPoint(x: speakerLeftX, y: centerY - 64))
        cone.addLine(to: CGPoint(x: speakerLeftX + 94, y: centerY - 64))
        cone.addLine(to: CGPoint(x: speakerLeftX + 216, y: centerY - 168))
        cone.addLine(to: CGPoint(x: speakerLeftX + 216, y: centerY + 168))
        cone.addLine(to: CGPoint(x: speakerLeftX + 94, y: centerY + 64))
        cone.addLine(to: CGPoint(x: speakerLeftX, y: centerY + 64))
        cone.closeSubpath()
    } else {
        cone.move(to: CGPoint(x: speakerLeftX + 14, y: centerY - 46))
        cone.addLine(to: CGPoint(x: speakerLeftX + 86, y: centerY - 46))
        cone.addLine(to: CGPoint(x: speakerLeftX + 186, y: centerY - 134))
        cone.addQuadCurve(to: CGPoint(x: speakerLeftX + 196, y: centerY - 126), control: CGPoint(x: speakerLeftX + 196, y: centerY - 136))
        cone.addLine(to: CGPoint(x: speakerLeftX + 196, y: centerY + 126))
        cone.addQuadCurve(to: CGPoint(x: speakerLeftX + 186, y: centerY + 134), control: CGPoint(x: speakerLeftX + 196, y: centerY + 136))
        cone.addLine(to: CGPoint(x: speakerLeftX + 86, y: centerY + 46))
        cone.addLine(to: CGPoint(x: speakerLeftX + 14, y: centerY + 46))
        cone.addQuadCurve(to: CGPoint(x: speakerLeftX, y: centerY + 32), control: CGPoint(x: speakerLeftX, y: centerY + 46))
        cone.addLine(to: CGPoint(x: speakerLeftX, y: centerY - 32))
        cone.addQuadCurve(to: CGPoint(x: speakerLeftX + 14, y: centerY - 46), control: CGPoint(x: speakerLeftX, y: centerY - 46))
        cone.closeSubpath()
    }

    ctx.saveGState()
    ctx.addPath(cone)
    ctx.clip()
    drawLinear(
        ctx,
        colors: [color(0xFFFFFF), color(0xE2E8F0), color(0x94A3B8)],
        locations: [0.0, 0.55, 1.0],
        from: CGPoint(x: speakerLeftX, y: centerY + 140),
        to: CGPoint(x: speakerLeftX + 200, y: centerY - 140)
    )
    ctx.restoreGState()
    ctx.restoreGState()

    // Crisp luminous acoustic wave arcs
    let waveOrigin = CGPoint(x: speakerLeftX + (isCompact ? 228 : 210), y: centerY)
    let waves: [(radius: CGFloat, width: CGFloat, alpha: CGFloat)] = isCompact
        ? [(96, 38, 0.96), (186, 38, 0.85)]
        : [(72, 26, 0.96), (134, 26, 0.84), (196, 26, 0.62)]

    for (i, wave) in waves.enumerated() {
        let arc = CGMutablePath()
        arc.addArc(center: waveOrigin, radius: wave.radius, startAngle: -0.68, endAngle: 0.68, clockwise: false)

        ctx.saveGState()
        if i == 0 {
            ctx.setShadow(offset: .zero, blur: 16, color: color(0x38BDF8, alpha: 0.45))
        }
        ctx.setLineCap(.round)
        ctx.setLineWidth(wave.width)
        ctx.setStrokeColor(i == 0 ? color(0xF8FAFC, alpha: wave.alpha) : color(0x7DD3FC, alpha: wave.alpha))
        ctx.addPath(arc)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // 4. Sleek Integrated Volume Level Pill at bottom of screen
    let barRect = isCompact
        ? CGRect(x: 248, y: 204, width: 528, height: 52)
        : CGRect(x: 280, y: 326, width: 464, height: 34)
    let barTrack = CGPath(roundedRect: barRect, cornerWidth: barRect.height / 2, cornerHeight: barRect.height / 2, transform: nil)
    ctx.saveGState()
    ctx.setFillColor(color(0xFFFFFF, alpha: 0.14))
    ctx.addPath(barTrack)
    ctx.fillPath()

    let fillWidth = barRect.width * 0.72
    let fillRect = CGRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barRect.height)
    let fillPath = CGPath(roundedRect: fillRect, cornerWidth: barRect.height / 2, cornerHeight: barRect.height / 2, transform: nil)
    ctx.addPath(fillPath)
    ctx.clip()
    drawLinear(
        ctx,
        colors: [color(0x38BDF8), color(0xBAE6FD), color(0xFFFFFF)],
        locations: [0.0, 0.6, 1.0],
        from: CGPoint(x: fillRect.minX, y: fillRect.midY),
        to: CGPoint(x: fillRect.maxX, y: fillRect.midY)
    )
    ctx.restoreGState()

    // 5. Outer Titanium-Glass Rim Bevel
    ctx.saveGState()
    let rimPath = CGPath(roundedRect: squircleRect.insetBy(dx: 2, dy: 2), cornerWidth: 183.4, cornerHeight: 183.4, transform: nil)
    let strokedRim = rimPath.copy(strokingWithWidth: 4.5, lineCap: .round, lineJoin: .round, miterLimit: 4)
    ctx.addPath(strokedRim)
    ctx.clip()
    drawLinear(
        ctx,
        colors: [color(0xFFFFFF, alpha: 0.56), color(0xCBD5E1, alpha: 0.18), color(0x64748B, alpha: 0.12), color(0xE2E8F0, alpha: 0.36)],
        locations: [0.0, 0.35, 0.70, 1.0],
        from: CGPoint(x: 120, y: 924),
        to: CGPoint(x: 904, y: 100)
    )
    ctx.restoreGState()
    ctx.restoreGState()

    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil),
          let image = ctx.makeImage() else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        throw CocoaError(.fileWriteUnknown)
    }
}

for pointSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let filename = "icon_\(pointSize)x\(pointSize)\(suffix).png"
        try renderIcon(size: pointSize * scale, to: directory.appendingPathComponent(filename))
    }
}
