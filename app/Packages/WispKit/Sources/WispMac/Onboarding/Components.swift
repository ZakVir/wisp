import SwiftUI
import WispCore

/// Shared visual language for Wisp's windows: calm, native, generous spacing. Accent colours follow the
/// selected companion theme, so the whole app matches the companion.
@MainActor
enum WispStyle {
    /// Set by `AppState` whenever the theme changes.
    static var theme: CompanionTheme = ThemeCatalog.theme(id: ThemeCatalog.defaultID)
    static var accent: Color { Color(.sRGB, red: theme.accent.r, green: theme.accent.g, blue: theme.accent.b) }
    static var accentSecondary: Color {
        Color(.sRGB, red: theme.accentSecondary.r, green: theme.accentSecondary.g, blue: theme.accentSecondary.b)
    }
    static let cornerRadius: CGFloat = 12
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    /// A row card that shows in both appearances (controlBackgroundColor is the window's own white in light mode).
    static let groupedRow = Color.primary.opacity(0.05)
}

/// Large, friendly title block at the top of each onboarding step.
struct StepHeader: View {
    var symbol: String
    var title: String
    var subtitle: String
    /// A smaller header for pages with a lot below it.
    var compact = false

    var body: some View {
        if compact {
            VStack(spacing: 6) {
                Label {
                    Text(title).font(.system(size: 22, weight: .semibold))
                } icon: {
                    Image(systemName: symbol)
                        .foregroundStyle(LinearGradient(colors: [WispStyle.accent, WispStyle.accentSecondary],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                        .accessibilityHidden(true)
                }
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
        } else {
            full
        }
    }

    private var full: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(LinearGradient(colors: [WispStyle.accent, WispStyle.accentSecondary],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(height: 52)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
    }
}

/// One line of the permission checklist with live status.
struct PermissionStatusRow: View {
    var kind: PermissionKind
    var state: PermissionState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(kind.friendlyName)
            Spacer()
            Text(label)
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .needsRelaunch: "arrow.clockwise.circle.fill"
        case .notDetermined: "circle.dashed"
        case .denied, .restricted: "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .granted: .green
        case .needsRelaunch: .orange
        case .notDetermined: .secondary
        case .denied, .restricted: .orange
        }
    }

    private var label: String {
        switch state {
        case .granted: "On"
        case .needsRelaunch: "Reopen needed"
        case .notDetermined: "Not set up"
        case .denied: "Off"
        case .restricted: "Managed"
        }
    }
}

/// A rounded bullet row used for explanations.
struct ExplainerRow: View {
    var symbol: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(WispStyle.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Renders a chord as keycaps, e.g. [⌃] [⌥].
struct KeycapsView: View {
    var modifiers: ModifierSet

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(modifiers.symbolList.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .frame(minWidth: 30, minHeight: 28)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.35)))
                    .shadow(color: .black.opacity(0.08), radius: 0, x: 0, y: 1)
            }
        }
        .accessibilityLabel(modifiers.names)
    }
}
