import SwiftUI

/// A brief reflection on the search field. Only this small canvas redraws.
struct NewTabLight: View {
    let startedAt: Date
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            Canvas { context, size in
                let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
                let travel = min(1, max(0, (elapsed - 0.04) / 0.60))
                let progress = 1 - pow(1 - travel, 3)
                let opacity = min(1, elapsed / 0.09) * min(1, max(0, (0.9 - elapsed) / 0.26))
                let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 12, dy: 12)
                guard bounds.width > 32, bounds.height > 32, opacity > 0 else { return }

                for side in [-1.0, 1.0] {
                    let edge = LightEdge(rect: bounds, side: side)
                    let tail = min(0.22, 64 / edge.length)
                    let start = max(0, progress - tail)
                    let segment = edge.path.trimmedPath(from: start, to: progress)
                    let head = edge.point(at: progress)
                    let end = edge.point(at: start)
                    let tint = colorScheme == .dark
                        ? Color(red: 0.62, green: 0.83, blue: 0.95)
                        : Color(red: 0.22, green: 0.42, blue: 0.56)
                    let highlight = colorScheme == .dark ? Color.white : tint.opacity(0.9)
                    let light = GraphicsContext.Shading.linearGradient(
                        Gradient(stops: [.init(color: .clear, location: 0),
                                         .init(color: tint.opacity(0.55), location: 0.45),
                                         .init(color: highlight, location: 1)]),
                        startPoint: end, endPoint: head)

                    var bloom = context
                    bloom.opacity = opacity * (colorScheme == .dark ? 0.32 : 0.16)
                    bloom.addFilter(.blur(radius: 6))
                    bloom.stroke(segment, with: light, style: StrokeStyle(lineWidth: 7, lineCap: .round))

                    var rim = context
                    rim.opacity = opacity * 0.9
                    rim.stroke(segment, with: light, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    rim.fill(Path(ellipseIn: CGRect(x: head.x - 1, y: head.y - 1,
                                                   width: 2, height: 2)), with: .color(highlight))
                }
            }
        }
    }
}

/// Each half starts at the bottom midpoint and ends at the top midpoint.
private struct LightEdge {
    let rect: CGRect
    let side: Double
    private var radius: CGFloat { min(16, rect.height / 2) }
    private var horizontal: CGFloat { rect.width / 2 - radius }
    private var vertical: CGFloat { rect.height - 2 * radius }
    private var quarter: CGFloat { .pi * radius / 2 }
    var length: CGFloat { horizontal * 2 + vertical + quarter * 2 }

    var path: Path {
        Path { path in
            path.move(to: point(at: 0))
            // The short sampled path avoids platform-dependent trim origins.
            for step in 1...96 { path.addLine(to: point(at: CGFloat(step) / 96)) }
        }
    }

    func point(at fraction: CGFloat) -> CGPoint {
        var distance = min(1, max(0, fraction)) * length
        let x: CGFloat
        let y: CGFloat
        if distance <= horizontal {
            x = distance; y = rect.maxY
        } else if distance <= horizontal + quarter {
            distance -= horizontal
            let angle = distance / radius
            x = horizontal + sin(angle) * radius
            y = rect.maxY - radius + cos(angle) * radius
        } else if distance <= horizontal + quarter + vertical {
            distance -= horizontal + quarter
            x = rect.width / 2; y = rect.maxY - radius - distance
        } else if distance <= horizontal + 2 * quarter + vertical {
            distance -= horizontal + quarter + vertical
            let angle = distance / radius
            x = horizontal + cos(angle) * radius
            y = rect.minY + radius - sin(angle) * radius
        } else {
            distance -= horizontal + 2 * quarter + vertical
            x = horizontal - distance; y = rect.minY
        }
        return CGPoint(x: rect.midX + side * x, y: y)
    }
}
