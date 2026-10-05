import SwiftUI
import HermesKit

/// Everything Hermes has learned, visible and deletable: USER.md, MEMORY.md, skills and
/// scheduled jobs. Hermes' memory is plain files; this is the phone's `cat ~/.hermes/...`.
struct MemoryView: View {
    @State private var user: [String] = []
    @State private var notes: [String] = []
    @State private var skills: [SkillStore.Summary] = []
    @State private var jobs: [CronJob] = []

    var body: some View {
        NavigationStack {
            List {
                Section("About you (USER.md)") {
                    if user.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) }
                    ForEach(user, id: \.self) { Text($0) }
                        .onDelete { remove(.user, from: user, at: $0) }
                }
                Section("Hermes' notes (MEMORY.md)") {
                    if notes.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) }
                    ForEach(notes, id: \.self) { Text($0) }
                        .onDelete { remove(.memory, from: notes, at: $0) }
                }
                Section("Skills") {
                    ForEach(skills, id: \.name) { skill in
                        NavigationLink {
                            SkillDetailView(name: skill.name)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(skill.name).font(.body.monospaced())
                                Text(skill.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteSkills)
                }
                Section("Scheduled jobs") {
                    if jobs.isEmpty { Text("None. Ask Hermes to do something every morning.").foregroundStyle(.secondary) }
                    ForEach(jobs) { job in
                        VStack(alignment: .leading) {
                            Text(job.name)
                            Text(job.scheduleDescription + (job.enabled ? "" : " · paused"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: deleteJobs)
                }
            }
            .navigationTitle("Memory")
            .task { await reload() }
            .refreshable { await reload() }
        }
    }

    private func reload() async {
        guard let agent = try? await HermesRuntime.ready() else { return }
        user = await agent.memory.entries(.user)
        notes = await agent.memory.entries(.memory)
        skills = await agent.skills.list()
        jobs = await agent.cron.all()
    }

    private func remove(_ target: MemoryStore.Target, from list: [String], at offsets: IndexSet) {
        let doomed = offsets.map { list[$0] }
        Task {
            guard let agent = try? await HermesRuntime.ready() else { return }
            for entry in doomed { _ = await agent.memory.remove(target, oldText: entry) }
            await reload()
        }
    }

    private func deleteSkills(at offsets: IndexSet) {
        let doomed = offsets.map { skills[$0].name }
        Task {
            guard let agent = try? await HermesRuntime.ready() else { return }
            for name in doomed { _ = await agent.skills.delete(name: name) }
            await reload()
        }
    }

    private func deleteJobs(at offsets: IndexSet) {
        let doomed = offsets.map { jobs[$0].id }
        Task {
            guard let agent = try? await HermesRuntime.ready() else { return }
            for id in doomed { _ = try? await agent.cron.remove(id: id) }
            await reload()
        }
    }
}

struct SkillDetailView: View {
    let name: String
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text).font(.callout.monospaced()).textSelection(.enabled).padding()
        }
        .navigationTitle(name)
        .task {
            guard let agent = try? await HermesRuntime.ready() else { return }
            text = await agent.skills.view(name, maxChars: 50_000)
        }
    }
}
