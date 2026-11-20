import SwiftUI
import WispCore

/// The optional "better answers" permission: macOS Accessibility, so Wisp can read the front app's buttons and
/// menus with each question. Shown in setup's screen page and in Settings > Privacy.
struct AppDetailsRow: View {
    @ObservedObject var app: AppState
    var compact = false

    var body: some View {
        // Accessibility has no change notification: re-check once a second while this is on screen.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let allowed = UIContextReader.isAllowed
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: allowed ? "checkmark.circle.fill" : "sparkle.magnifyingglass")
                        .foregroundStyle(allowed ? Color.green : WispStyle.accent)
                        .font(.title3)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Better answers (Accessibility)").font(.body.weight(.medium))
                        Text(allowed ? "On. Wisp reads the buttons and menus of the app you ask about."
                             : "Optional. Lets Wisp read the app's buttons and menus and the text you've selected, so it knows what's greyed out, what's already on, which menu has the command you need, and what “this” means.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if !allowed {
                        Button("Allow…") {
                            UIContextReader.requestAccess()
                            UIContextReader.openSettings()
                        }
                        .fixedSize()
                    }
                }
                if !compact && allowed {
                    Toggle("Use it with each question", isOn: Binding(get: { app.config.vision.readAppControls },
                                                                      set: { v in app.update { $0.vision.readAppControls = v } }))
                        .disabled(app.isLocked("vision.readAppControls"))
                }
            }
        }
    }
}
