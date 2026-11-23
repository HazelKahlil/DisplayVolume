import AppKit
import CoreGraphics

/// Renders a crisp Apple-native template menu bar icon:
/// a sleek monitor frame housing speaker waves / volume bars — unmistakably audio volume,
/// yet immediately distinguishable from macOS's built-in standalone speaker icon.
enum MenuBarIconRenderer {
    static func makeIcon(volume: Int, muted: Bool, active: Bool) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let ink = NSColor.black
            let mainAlpha: CGFloat = active ? 0.95 : 0.45

            ctx.saveGState()

            // 1. Sleek external display frame (distinct from Apple's standalone speaker icon)
            let frameRect = CGRect(x: 1.5, y: 4.5, width: 19.0, height: 11.5)
            let framePath = CGPath(roundedRect: frameRect, cornerWidth: 2.3, cornerHeight: 2.3, transform: nil)
            ctx.setLineWidth(1.35)
            ctx.setStrokeColor(ink.withAlphaComponent(mainAlpha).cgColor)
            ctx.addPath(framePath)
            ctx.strokePath()

            // Minimal monitor stand base
            ctx.setLineCap(.round)
            ctx.setLineWidth(1.3)
            ctx.move(to: CGPoint(x: 11.0, y: 4.5))
            ctx.addLine(to: CGPoint(x: 11.0, y: 2.4))
            ctx.move(to: CGPoint(x: 7.4, y: 2.2))
            ctx.addLine(to: CGPoint(x: 14.6, y: 2.2))
            ctx.strokePath()

            // 2. Crisp speaker cone inside the left of the display
            let cone = CGMutablePath()
            cone.move(to: CGPoint(x: 4.8, y: 9.1))
            cone.addLine(to: CGPoint(x: 6.4, y: 9.1))
            cone.addLine(to: CGPoint(x: 8.6, y: 7.3))
            cone.addLine(to: CGPoint(x: 8.6, y: 13.2))
            cone.addLine(to: CGPoint(x: 6.4, y: 11.4))
            cone.addLine(to: CGPoint(x: 4.8, y: 11.4))
            cone.closeSubpath()
            ctx.setFillColor(ink.withAlphaComponent(mainAlpha).cgColor)
            ctx.addPath(cone)
            ctx.fillPath()

            // 3. Volume waves / mute X inside the right of the display
            if muted && active {
                ctx.setLineWidth(1.3)
                ctx.setLineCap(.round)
                ctx.setStrokeColor(ink.withAlphaComponent(mainAlpha).cgColor)
                ctx.move(to: CGPoint(x: 11.4, y: 8.4))
                ctx.addLine(to: CGPoint(x: 15.2, y: 12.1))
                ctx.move(to: CGPoint(x: 15.2, y: 8.4))
                ctx.addLine(to: CGPoint(x: 11.4, y: 12.1))
                ctx.strokePath()
            } else {
                let level = active ? volume : 60
                let waveOrigin = CGPoint(x: 9.2, y: 10.25)
                let arcs: [(radius: CGFloat, threshold: Int)] = [
                    (2.3, 1),
                    (4.4, 34),
                    (6.5, 68)
                ]
                for arcSpec in arcs {
                    let on = level >= arcSpec.threshold
                    ctx.setLineWidth(1.25)
                    ctx.setLineCap(.round)
                    ctx.setStrokeColor(ink.withAlphaComponent(on ? mainAlpha : mainAlpha * 0.25).cgColor)
                    let arc = CGMutablePath()
                    arc.addArc(center: waveOrigin, radius: arcSpec.radius, startAngle: -0.62, endAngle: 0.62, clockwise: false)
                    ctx.addPath(arc)
                    ctx.strokePath()
                }
            }

            ctx.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }
}
