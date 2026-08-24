import AppKit

enum StatusBarImage {
    static func make(codexRemaining: Double?) -> NSImage {
        let size = NSSize(width: 60, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSGraphicsContext.current?.imageInterpolation = .high
            BrandAssets.openAI(size: 14).draw(in: NSRect(x: 0, y: 2, width: 14, height: 14))
            drawProgress(remaining: codexRemaining, x: 18, y: 2, width: 40, height: 14)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Codex 账号池总剩余额度"
        return image
    }

    private static func drawProgress(remaining: Double?, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        let bodyRect = NSRect(x: x, y: y, width: width, height: height)
        let outline = NSBezierPath(roundedRect: bodyRect, xRadius: 3, yRadius: 3)
        outline.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.72).setStroke()
        outline.stroke()

        let fillWidth = max(0, (width - 4) * CGFloat(fillFraction(for: remaining)))
        if fillWidth > 0 {
            let fill = NSBezierPath(
                roundedRect: NSRect(x: x + 2, y: y + 2, width: fillWidth, height: height - 4),
                xRadius: 1.5,
                yRadius: 1.5
            )
            quotaColor(for: remaining).withAlphaComponent(0.62).setFill()
            fill.fill()
        }

        let value = displayText(for: remaining)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = value.size(withAttributes: attributes)
        value.draw(
            at: NSPoint(x: x + (width - textSize.width) / 2, y: y + (height - textSize.height) / 2 - 0.5),
            withAttributes: attributes
        )
    }

    static func fillFraction(for remaining: Double?) -> Double {
        min(1, max(0, (remaining ?? 0) / 100))
    }

    static func displayText(for remaining: Double?) -> String {
        remaining.map { "\(Int($0.rounded()))%" } ?? "--"
    }

    private static func quotaColor(for remaining: Double?) -> NSColor {
        guard let remaining else { return .secondaryLabelColor }
        if remaining < 20 { return .systemRed }
        if remaining < 50 { return .systemOrange }
        return .systemGreen
    }
}
