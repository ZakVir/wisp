import SwiftUI
import WispCore

/// "Check Wisp": every part Wisp needs, tested in one place, each problem with the button that fixes it.
@MainActor
final class CheckupModel: ObservableObject {
    enum Status: Equatable {
        case checking
        case ok(String)
        case problem(String)
        case optional(String)
    }

    struct Fix {
        var title: String
        var action: () -> Void
    }

    struct Row: Identifiable {
        var id: String
        var symbol: String
        var title: String
        var status: Status
        var fix: Fix?
    }

    @Published var rows: [Row] = []
    @Published var running = false
    /// Builds the rows (synchronous checks) and runs the slow ones (the AI connection).
    var runChecks: ((CheckupModel) async -> Void)?
    var report: (() -> String)?

    func run() {
        guard !running else { return }
        running = true
        Task {
            await runChecks?(self)
            running = false
        }
    }

    func set(_ id: String, _ status: Status, fix: Fix? = nil) {
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].status = status; rows[i].fix = fix }
    }

    var summary: String {
        if running || rows.contains(where: { $0.status == .checking }) { return "Checking…" }
        let problems = rows.filter { if case .problem = $0.status { return true } else { return false } }.count
        return problems == 0 ? "Everything Wisp needs is working." : "\(problems) thing\(problems == 1 ? "" : "s") to fix."
    }
}

struct CheckupView: View {
    static let size = CGSize(width: 560, height: 780)
    @ObservedObject var model: CheckupModel
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(LinearGradient(colors: [WispStyle.accent, WispStyle.accentSecondary],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .accessibilityHidden(true)
                Text("Wisp Check-up").font(.system(size: 22, weight: .semibold))
                Text(model.summary).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.top, 26)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.rows) { row in
                        CheckRowView(row: row)
                    }
                }
                .padding(.horizontal, 24)
            }

            HStack {
                Button(copied ? "Copied" : "Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.report?() ?? "", forType: .string)
                    copied = true
                }
                .help("Versions and the results above, without anything personal. Paste it into an email for help.")
                Spacer()
                Button("Check Again") { copied = false; model.run() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.running)
            }
            .controlSize(.large)
            .padding(20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .tint(WispStyle.accent)
        .onAppear { model.run() }
    }
}

private struct CheckRowView: View {
    let row: CheckupModel.Row

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: row.symbol)
                .font(.system(size: 16))
                .frame(width: 24)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let fix = row.fix {
                Button(fix.title, action: fix.action).controlSize(.small)
            }
            badge
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(WispStyle.groupedRow, in: RoundedRectangle(cornerRadius: WispStyle.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch row.status {
        case .checking: return "Checking…"
        case .ok(let s), .problem(let s), .optional(let s): return s
        }
    }

    @ViewBuilder private var badge: some View {
        switch row.status {
        case .checking: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 17))
        case .problem: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 17))
        case .optional: Image(systemName: "minus.circle").foregroundStyle(.secondary).font(.system(size: 17))
        }
    }
}
