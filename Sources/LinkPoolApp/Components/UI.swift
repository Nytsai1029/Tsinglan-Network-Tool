import LinkPoolCore
import SwiftUI
import AppKit

enum Theme {
    static let corner: CGFloat = 16
    static let accent = Color(red: 0.16, green: 0.47, blue: 0.96)
    static let teal = Color(red: 0.11, green: 0.72, blue: 0.66)
    static let heroGradient = LinearGradient(
        colors: [Color(red: 0.10, green: 0.30, blue: 0.62), Color(red: 0.12, green: 0.55, blue: 0.78)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

struct SectionTitle: View {
    let text: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text).font(.headline)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct PhaseDot: View {
    let phase: SessionPhase
    var pulsing = false

    private var color: Color {
        switch phase {
        case .online: return .green
        case .authenticating: return .orange
        case .failed: return .red
        case .offline: return .secondary
        case .disabled: return .gray.opacity(0.5)
        case .unknown: return .secondary
        case .unverified: return .orange.opacity(0.6)
        case .unverified: return .orange
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(color.opacity(0.25), lineWidth: 4))
            .shadow(color: color.opacity(phase == .online ? 0.7 : 0), radius: 4)
    }
}

struct PhaseBadge: View {
    let phase: SessionPhase

    private var text: String { phase.displayName }
    private var color: Color {
        switch phase {
        case .online: return .green
        case .authenticating: return .orange
        case .failed: return .red
        case .offline: return .secondary
        case .disabled: return .gray
        case .unknown: return .secondary
        case .unverified: return .orange
        }
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var subtitle: String?
    var icon: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.caption2) }
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IconBubble: View {
    let systemName: String
    var tint: Color = Theme.accent
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(tint.opacity(0.13)))
    }
}

extension View {
    func cardStyle() -> some View {
        self
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}
