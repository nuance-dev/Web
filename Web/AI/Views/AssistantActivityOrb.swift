import Combine
import SwiftUI

/// A small globe for real assistant work. Its surface moves; its footprint never does.
struct AssistantActivityOrb: View {
    enum Activity: Equatable {
        case loading
        case thinking
        case writing

        var speed: Double {
            switch self {
            case .loading: 0.45
            case .thinking: 0.65
            case .writing: 0.8
            }
        }
    }

    let activity: Activity
    let isWindowActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var elapsed: TimeInterval = 0
    @State private var startedAt: Date?
    @State private var speed = Activity.thinking.speed

    private var canAnimate: Bool {
        isWindowActive && scenePhase == .active && !reduceMotion && !lowPowerMode
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !canAnimate)) { timeline in
            Canvas { context, size in
                let phase = elapsed + (startedAt.map { timeline.date.timeIntervalSince($0) * speed } ?? 0)
                draw(in: context, size: size, phase: max(0, phase))
            }
        }
        .frame(width: 18, height: 18)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            speed = activity.speed
            updateClock()
        }
        .onChange(of: canAnimate) { _, _ in updateClock() }
        .onChange(of: activity) { _, _ in
            pauseClock()
            speed = activity.speed
            updateClock()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onDisappear { pauseClock() }
    }

    private func updateClock() {
        if canAnimate {
            if startedAt == nil { startedAt = Date() }
        } else {
            pauseClock()
        }
    }

    private func pauseClock() {
        guard let startedAt else { return }
        elapsed += max(0, Date().timeIntervalSince(startedAt)) * speed
        self.startedAt = nil
    }

    private func draw(in context: GraphicsContext, size: CGSize, phase: Double) {
        let diameter = min(size.width, size.height) - 1
        let radius = diameter / 2
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let bounds = CGRect(x: center.x - radius, y: center.y - radius,
                            width: diameter, height: diameter)
        let circle = Path(ellipseIn: bounds)
        let dark = colorScheme == .dark

        // A quiet glass body and a moving reflection beneath the meridians.
        context.fill(circle, with: .radialGradient(
            Gradient(stops: [
                .init(color: Color(red: 0.83, green: 0.91, blue: 0.98).opacity(dark ? 0.82 : 0.94), location: 0),
                .init(color: Color(red: 0.38, green: 0.51, blue: 0.64).opacity(dark ? 0.6 : 0.55), location: 0.48),
                .init(color: Color(red: 0.11, green: 0.19, blue: 0.27).opacity(dark ? 0.82 : 0.72), location: 1)
            ]),
            center: CGPoint(x: center.x - radius * 0.32, y: center.y - radius * 0.4),
            startRadius: 0, endRadius: diameter * 0.92))

        var surface = context
        surface.clip(to: circle)
        let reflection = CGPoint(x: center.x + cos(phase * 0.7) * radius * 0.45,
                                 y: center.y + sin(phase * 0.9) * radius * 0.35)
        surface.fill(circle, with: .radialGradient(
            Gradient(colors: [Color(red: 0.68, green: 0.88, blue: 1).opacity(0.7), .clear]),
            center: reflection, startRadius: 0, endRadius: radius * 1.25))

        // Project an original dot mesh onto a sphere. The rear hemisphere stays dim.
        for latitude in -3...3 {
            let elevation = Double(latitude) * .pi / 8
            for meridian in 0..<10 {
                let angle = Double(meridian) * .pi / 5 + phase
                let depth = cos(elevation) * cos(angle)
                let x = cos(elevation) * sin(angle)
                let y = sin(elevation)
                let dotRadius = 0.3 + (depth + 1) * 0.12
                let point = CGPoint(x: center.x + x * radius * 0.82,
                                    y: center.y + y * radius * 0.82)
                let dot = CGRect(x: point.x - dotRadius, y: point.y - dotRadius,
                                 width: dotRadius * 2, height: dotRadius * 2)
                let opacity = depth > 0 ? 0.32 + depth * 0.58 : 0.08
                surface.fill(Path(ellipseIn: dot), with: .color(.white.opacity(opacity)))
            }
        }

        context.stroke(circle, with: .linearGradient(
            Gradient(colors: [.white.opacity(dark ? 0.58 : 0.85), .white.opacity(0.03),
                              Color(red: 0.12, green: 0.2, blue: 0.3).opacity(0.3)]),
            startPoint: bounds.origin, endPoint: CGPoint(x: bounds.maxX, y: bounds.maxY)),
            lineWidth: 0.5)
    }
}
