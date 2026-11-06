import AppKit

enum Branding {
    /// A template counterpart to the app icon, optically simplified for 20 pt.
    static func mark() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setStroke()
            let eye = NSBezierPath()
            eye.move(to: NSPoint(x: 1.2, y: 10))
            eye.curve(to: NSPoint(x: 18.8, y: 10), controlPoint1: NSPoint(x: 6.5, y: 17.5), controlPoint2: NSPoint(x: 13.5, y: 17.5))
            eye.curve(to: NSPoint(x: 1.2, y: 10), controlPoint1: NSPoint(x: 13.5, y: 2.5), controlPoint2: NSPoint(x: 6.5, y: 2.5))
            eye.close(); eye.lineWidth = 1.8; eye.lineJoinStyle = .round; eye.stroke()
            let lens = NSBezierPath()
            lens.appendArc(withCenter: NSPoint(x: 10, y: 10), radius: 3.2, startAngle: -20, endAngle: 290)
            lens.lineWidth = 1.7; lens.lineCapStyle = .round; lens.stroke()
            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: 11.3, y: 8.7))
            handle.line(to: NSPoint(x: 13.2, y: 6.8))
            handle.lineWidth = 1.9; handle.lineCapStyle = .round; handle.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "千里眼"
        return image
    }
}
