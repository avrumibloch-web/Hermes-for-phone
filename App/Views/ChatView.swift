import SwiftUI
import HermesKit

struct ChatLine: Identifiable, Equatable {
    enum Role { case user, assistant, notice }
    let id = UUID()
    let role: Role
    let text: String
    var detail: String?
}

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var lines: [ChatLine] = []
    @Published var draft = ""
    @Published var isThinking = false
    private var sessionID: String?

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        draft = ""
        if text == "/new" {
            newChat()
            return
        }
        lines.append(ChatLine(role: .user, text: text))
        isThinking = true
        Task {
            defer { isThinking = false }
            do {
                let agent = try await HermesRuntime.ready()
                if let problem = await agent.availabilityProblem() {
                    lines.append(ChatLine(role: .notice, text: problem))
                    return
                }
                let id: String
                if let sessionID {
                    id = sessionID
                } else {
                    id = try await agent.newSession(source: .app)
                    sessionID = id
                }
                let reply = try await agent.send(text, sessionID: id)
                var detail: [String] = []
                if reply.tier == .privateCloud { detail.append("Private Cloud Compute") }
                if reply.compressedHistory { detail.append("compressed earlier messages") }
                detail += reply.activity.map { "\($0.tool): \($0.summary)" }
                lines.append(ChatLine(role: .assistant, text: reply.text, detail: detail.isEmpty ? nil : detail.joined(separator: "\n")))
            } catch {
                lines.append(ChatLine(role: .notice, text: error.localizedDescription))
            }
        }
    }

    /// Hermes' `/new`: a session boundary, so new memories load into the next prompt.
    func newChat() {
        sessionID = nil
        lines = [ChatLine(role: .notice, text: "New conversation")]
    }
}

struct ChatView: View {
    @ObservedObject var model: ChatViewModel
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.lines) { line in
                            bubble(line).id(line.id)
                        }
                        if model.isThinking {
                            ProgressView().padding(.leading, 8).id("thinking")
                        }
                    }
                    .padding()
                }
                .onChange(of: model.lines) { _, lines in
                    withAnimation { proxy.scrollTo(lines.last?.id, anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Hermes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.newChat() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New conversation")
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ line: ChatLine) -> some View {
        switch line.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(line.text)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(line.text)).textSelection(.enabled)
                if let detail = line.detail {
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        case .notice:
            Text(line.text).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message, /think, /new or /skill-name", text: $model.draft, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .onSubmit { model.send() }
            Button { model.send() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30))
            }
            .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty || model.isThinking)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
