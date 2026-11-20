import SwiftUI
import WispCore

/// History: past questions and answers, searchable, with Copy / Say Again / Delete.
@MainActor
final class HistoryModel: ObservableObject {
    @Published var history = History()
    @Published var query = ""
    @Published var keep = false
    var onSayAgain: ((History.Entry) -> Void)?
    var onChange: ((History) -> Void)?
    var onKeepChanged: ((Bool) -> Void)?

    var shown: [History.Entry] { history.search(query) }

    func remove(_ id: UUID) { history.remove(id); onChange?(history) }
    func clear() { history.clear(); onChange?(history) }
}

struct HistoryView: View {
    static let size = CGSize(width: 620, height: 640)
    @ObservedObject var model: HistoryModel
    @State private var copiedID: UUID?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History").font(.system(size: 20, weight: .semibold))
                Spacer()
                TextField("Search", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 22)
            .padding(.top, 34)
            .padding(.bottom, 12)

            if model.shown.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(model.history.entries.isEmpty ? "Your questions and Wisp's answers will appear here." : "Nothing matches.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.shown) { entry in row(entry) }
                    }
                    .padding(.horizontal, 22)
                }
            }

            Divider()
            HStack(spacing: 12) {
                Toggle("Keep history on this Mac", isOn: Binding(get: { model.keep }, set: { model.keep = $0; model.onKeepChanged?($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Text(model.keep ? "Text only, saved on this Mac." : "Cleared when Wisp quits.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Clear History", role: .destructive) { model.clear() }
                    .disabled(model.history.entries.isEmpty)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .tint(WispStyle.accent)
        .onAppear { searchFocused = !model.history.entries.isEmpty }
    }

    private func row(_ entry: History.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: entry.typed ? "keyboard" : "mic")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityLabel(entry.typed ? "Typed" : "Spoken")
                Text(entry.question.prefix(1).uppercased() + entry.question.dropFirst())
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(meta(entry)).font(.caption).foregroundStyle(.tertiary)
            }
            Text(entry.answer)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button(copiedID == entry.id ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.answer, forType: .string)
                    copiedID = entry.id
                }
                Button("Say Again") { model.onSayAgain?(entry) }
                Button("Delete") { model.remove(entry.id) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(WispStyle.groupedRow, in: RoundedRectangle(cornerRadius: WispStyle.cornerRadius, style: .continuous))
    }

    private func meta(_ entry: History.Entry) -> String {
        let when = Calendar.current.isDateInToday(entry.date)
            ? entry.date.formatted(date: .omitted, time: .shortened)
            : entry.date.formatted(date: .abbreviated, time: .shortened)
        return [entry.app, when].compactMap { $0 }.joined(separator: " · ")
    }
}
