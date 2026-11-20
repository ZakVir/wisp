import SwiftUI
import WispCore

/// "What's New in Wisp": the changes since the version the user last saw, newest first.
struct WhatsNewView: View {
    static let size = CGSize(width: 520, height: 540)
    let entries: [WhatsNew.Entry]
    var onClose: () -> Void
    /// Many updates at once: the newest few first, the rest on request.
    @State private var showAll = false
    private static let firstCount = 10
    private var shown: [WhatsNew.Entry] { showAll ? entries : Array(entries.prefix(Self.firstCount)) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(LinearGradient(colors: [WispStyle.accent, WispStyle.accentSecondary],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .accessibilityHidden(true)
                Text("What's New in Wisp").font(.system(size: 22, weight: .semibold))
                if let newest = entries.first {
                    Text("Version \(newest.version)").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 34)
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(shown, id: \.version) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.title).font(.system(size: 15, weight: .semibold))
                                Spacer()
                                Text(entry.version).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            ForEach(entry.points, id: \.self) { point in
                                Text(point)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(WispStyle.groupedRow, in: RoundedRectangle(cornerRadius: WispStyle.cornerRadius, style: .continuous))
                    }
                }
                .padding(.horizontal, 28)
                if !showAll && entries.count > Self.firstCount {
                    Button("Show \(entries.count - Self.firstCount) earlier updates") { showAll = true }
                        .buttonStyle(.link)
                        .padding(.vertical, 10)
                }
            }

            HStack {
                Spacer()
                Button("Got It", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .padding(20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .tint(WispStyle.accent)
    }
}
