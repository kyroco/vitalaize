import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        switch state.screen {
        case .detecting: DetectingView()
        case .wizard: WizardView()
        case .working: WorkingView()
        case .status: StatusView()
        }
    }
}

// MARK: - Looking around

struct DetectingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Looking at this Mac to fill in the setup…").font(.headline)
            Text("Claude folders, the GitHub repository you work in, Korium, AWS profiles, and any board set up before.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The wizard

struct WizardView: View {
    @EnvironmentObject var state: AppState

    private var steps: [String] {
        state.choices.role.runsBoard
            ? ["What this Mac does", "Claude and folders", "GitHub", "What the board shows", "Review"]
            : ["What this Mac does", "Claude folders", "Your hub", "Review"]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(steps[min(state.step, steps.count - 1)]).font(.title2.bold())
                Spacer()
                Text("Step \(state.step + 1) of \(steps.count)").foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 12)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) { page }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                if state.step > 0 { Button("Back") { state.step -= 1 } }
                Spacer()
                if state.step < steps.count - 1 {
                    Button("Continue") { state.step += 1 }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                } else {
                    Button(state.choices.role.runsBoard ? "Install and start the board" : "Connect this Mac") { state.install() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!state.isAppleSilicon)
                }
            }
            .padding(16)
        }
    }

    private var canContinue: Bool {
        let c = state.choices
        switch (c.role.runsBoard, state.step) {
        case (_, 1): return !c.claudeFolders.isEmpty && (c.role == .collector || !c.dataFolder.isEmpty)
        case (true, 2): return c.repo.contains("/")
        case (false, 2): return c.hubURL.hasPrefix("http") && !c.hubKey.isEmpty
        default: return true
        }
    }

    @ViewBuilder private var page: some View {
        switch (state.choices.role.runsBoard, state.step) {
        case (_, 0): RolePage()
        case (_, 1): FoldersPage()
        case (true, 2): GitHubPage()
        case (true, 3): FeaturesPage()
        case (false, 2): HubPage()
        default: ReviewPage()
        }
    }
}

struct RolePage: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Text("VitalAIze shows your builds and Claude sessions on a screen, and keeps every session's numbers in a database. One Mac runs the board (the hub); other Macs can send it their sessions (collectors).")
            .foregroundStyle(.secondary)
        ForEach(Role.allCases) { role in
            Button { state.choices.role = role } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: state.choices.role == role ? "largecircle.fill.circle" : "circle")
                        .font(.title3).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(role.title + (role == .hubAndCollector ? " (recommended)" : "")).font(.headline)
                        Text(role.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(state.choices.role == role ? Color.accentColor : Color.gray.opacity(0.25)))
            }
            .buttonStyle(.plain)
        }
        if !state.isAppleSilicon {
            Label("This Mac has an Intel processor. VitalAIze runs on Apple silicon Macs only.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
        ToolsList()
    }
}

struct ToolsList: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        GroupBox("Found on this Mac") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(state.tools, id: \.0) { tool in
                    Label(tool.0, systemImage: tool.1 ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(tool.1 ? Color.green : Color.secondary)
                }
                Text("The board needs claude, and gh signed in for GitHub. aws and 1Password are only for the dev, prod and New Relic panels.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

struct FoldersPage: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        GroupBox("Claude folders to include") {
            VStack(alignment: .leading, spacing: 8) {
                let known = Array(Set(Detect.claudeFolders() + state.choices.claudeFolders)).sorted()
                ForEach(known, id: \.self) { folder in
                    Toggle(isOn: Binding(
                        get: { state.choices.claudeFolders.contains(folder) },
                        set: { on in
                            if on { state.choices.claudeFolders.append(folder) }
                            else { state.choices.claudeFolders.removeAll { $0 == folder } }
                        })) {
                        Text(folder.replacingOccurrences(of: Detect.home.path, with: "~"))
                    }
                }
                Button("Add another Claude folder…") {
                    if let url = pickFolder(start: Detect.home.path, message: "Pick a Claude folder, like ~/.claude") {
                        state.choices.claudeFolders.append(url)
                    }
                }
                Text("Each Claude account keeps its sessions in its own folder. Tick every account you use on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }

        if state.choices.role.runsBoard {
            GroupBox("Where the board keeps its files") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(state.choices.dataFolder.replacingOccurrences(of: Detect.home.path, with: "~"))
                            .textSelection(.enabled)
                        Spacer()
                        Button("Change…") {
                            if let url = pickFolder(start: state.choices.dataFolder, message: "Pick where the board keeps its settings, database and logs") {
                                state.choices.dataFolder = url
                            }
                        }
                    }
                    Text("Its settings, its database of sessions and runs, and incoming sessions from other Macs. The board itself stays inside this app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            if let imported = state.choices.importedSettings {
                GroupBox("A board you set up before") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Carry over its settings from \(imported.replacingOccurrences(of: Detect.home.path, with: "~"))",
                               isOn: Binding(get: { state.choices.importedSettings != nil },
                                             set: { if !$0 { state.choices.importedSettings = nil } }))
                        if Detect.oldLoginItemInstalled {
                            Toggle("Stop that board and run this one instead", isOn: $state.choices.replaceOldBoard)
                        }
                        Text("Its phone number, New Relic checks and anything else it holds stay; your answers here win where they differ. Its database is kept when you use the same folder.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
        }
    }
}

struct GitHubPage: View {
    @EnvironmentObject var state: AppState
    @State private var newRepo = ""

    private var others: [String] { state.choices.otherRepos ?? [] }

    var body: some View {
        Text("Found from the git remotes of your recent Claude sessions. Change them if the board should watch other repositories.")
            .foregroundStyle(.secondary)
        Form {
            HStack {
                TextField("Repository (owner/name)", text: $state.choices.repo)
                Button("Look up") { state.reloadWorkflows() }
            }
            TextField("Main branch", text: $state.choices.branch)
            workflowPicker("Gate workflow (checks each change)", $state.choices.gateWorkflow)
            workflowPicker("Dev deploy workflow", $state.choices.devWorkflow)
            workflowPicker("Prod deploy workflow", $state.choices.prodWorkflow)
            Section {
                ForEach(others, id: \.self) { repo in
                    HStack {
                        Text(repo)
                        Spacer()
                        Button("Remove") { state.choices.otherRepos = others.filter { $0 != repo } }
                    }
                }
                HStack {
                    TextField("Add another (owner/name)", text: $newRepo)
                    Button("Add") {
                        let repo = newRepo.trimmingCharacters(in: .whitespaces)
                        // owner/name, the only form the board accepts.
                        let ok = repo.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
                        if ok && repo != state.choices.repo && !others.contains(repo) {
                            state.choices.otherRepos = others + [repo]
                        }
                        newRepo = ""
                    }
                }
            } header: {
                Text("Other repositories")
            } footer: {
                Text("Each gets its own column on the board's Git tab, using the workflows above. Dev and Prod follow the first repository.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        if state.workflows.isEmpty {
            Text("No workflows found. Check the repository name, and that gh is signed in (gh auth login).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func workflowPicker(_ title: String, _ value: Binding<String>) -> some View {
        Picker(title, selection: value) {
            Text("None").tag("")
            ForEach(state.workflows, id: \.self) { Text($0).tag($0) }
            if !value.wrappedValue.isEmpty && !state.workflows.contains(value.wrappedValue) {
                Text(value.wrappedValue).tag(value.wrappedValue)
            }
        }
    }
}

struct FeaturesPage: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("The board") {
                TextField("Name at the top", text: $state.choices.boardName)
                TextField("Port", value: $state.choices.port, format: .number.grouping(.never))
            }
            Section("Korium") {
                Toggle("Show Korium numbers (searches, saves, indexing)", isOn: $state.choices.korium)
                Text(state.choices.korium ? "Your recent sessions use Korium." : "Your recent sessions do not seem to use Korium.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Codex") {
                Toggle("Show and save Codex sessions", isOn: Binding(
                    get: { state.choices.codex ?? false },
                    set: { state.choices.codex = $0 }))
                Text(Detect.usesCodex() ? "This Mac has Codex sessions in ~/.codex." : "No Codex sessions found on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AWS (read-only profiles)") {
                profilePicker("Dev: awake or asleep", $state.choices.devProfile)
                profilePicker("Prod: same build as dev?", $state.choices.prodProfile)
            }
            Section("New Relic") {
                Toggle("Show the New Relic page", isOn: $state.choices.newRelic)
                if state.choices.newRelic {
                    TextField("Account ID", text: $state.choices.newRelicAccount)
                    TextField("1Password reference for the API key (op://…)", text: $state.choices.newRelicKeyRef)
                    Text("The key is read from 1Password when the board starts and is never written to a file.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Texts when a session needs you") {
                TextField("Phone number (empty for no texts)", text: $state.choices.phone)
                Picker("Send as", selection: $state.choices.textVia) {
                    Text("iMessage").tag("iMessage")
                    Text("SMS").tag("SMS")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func profilePicker(_ title: String, _ value: Binding<String>) -> some View {
        Picker(title, selection: value) {
            Text("None").tag("")
            ForEach(state.awsProfiles, id: \.self) { Text($0).tag($0) }
        }
    }
}

struct HubPage: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var finder: HubFinder

    init() { _finder = ObservedObject(wrappedValue: HubFinderHolder.shared) }

    var body: some View {
        Text("Pick the hub this Mac sends its Claude sessions to, then paste its key. The key is on the hub's settings page, under Connect another Mac (Show key).")
            .foregroundStyle(.secondary)
        GroupBox("Hubs on your network") {
            VStack(alignment: .leading, spacing: 8) {
                if finder.hubs.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Looking…").foregroundStyle(.secondary) }
                }
                ForEach(finder.hubs) { hub in
                    Button { state.choices.hubURL = hub.url } label: {
                        HStack {
                            Image(systemName: state.choices.hubURL == hub.url ? "largecircle.fill.circle" : "circle")
                            Text(hub.name)
                            Text(hub.url).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        Form {
            TextField("Hub address", text: $state.choices.hubURL, prompt: Text("http://192.168.1.20:4747"))
            SecureField("Connect key", text: $state.choices.hubKey)
        }
        .formStyle(.grouped)
    }
}

/// Lets HubPage observe the app's finder for live updates.
enum HubFinderHolder { static var shared = HubFinder() }

struct ReviewPage: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let c = state.choices
        let home = Detect.home.path
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                row("This Mac", c.role.title)
                row("Claude folders", c.claudeFolders.map { $0.replacingOccurrences(of: home, with: "~") }.joined(separator: ", "))
                if c.role.runsBoard {
                    row("Files", c.dataFolder.replacingOccurrences(of: home, with: "~"))
                    row("Board", "\(c.boardName) at http://localhost:\(c.port)")
                    row("GitHub", "\(c.repo) (\(c.branch))")
                    row("Workflows", [c.gateWorkflow, c.devWorkflow, c.prodWorkflow].filter { !$0.isEmpty }.joined(separator: ", "))
                    row("Korium", c.korium ? "shown" : "hidden")
                    row("Codex", (c.codex ?? false) ? "shown" : "off")
                    row("New Relic", c.newRelic ? "on" : "off")
                    row("AWS", [c.devProfile.isEmpty ? nil : "dev \(c.devProfile)", c.prodProfile.isEmpty ? nil : "prod \(c.prodProfile)"].compactMap { $0 }.joined(separator: ", ").ifEmpty("none"))
                    row("Texts", c.phone.isEmpty ? "off" : "to \(c.phone) by \(c.textVia)")
                    if c.importedSettings != nil { row("Carried over", "your earlier settings file") }
                } else {
                    row("Hub", c.hubURL)
                    row("Codex", Detect.usesCodex() ? "sent too, from ~/.codex" : "not on this Mac")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        Text(c.role.runsBoard
             ? "The board starts now and again whenever you log in. You can change any of this later from the board's settings page, or here with Reconfigure."
             : "Each Claude and Codex session on this Mac is sent to the hub when a turn ends and when it closes, in the background. The hooks are added to each Claude folder's settings.json and to Codex's hooks.json, each backed up first. Codex runs a new hook only once you trust it with /hooks in Codex.")
            .foregroundStyle(.secondary)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }
}

// MARK: - Working

struct WorkingView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if state.failure == nil { ProgressView().controlSize(.small) }
                Text(state.failure == nil ? "Setting up…" : "That did not work").font(.title2.bold())
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(state.log.enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "checkmark").foregroundStyle(.primary)
                    }
                    if let failure = state.failure {
                        Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if state.failure != nil {
                HStack {
                    Button("Back to the setup") { state.failure = nil; state.screen = .wizard }
                    Button("Open the log") { NSWorkspace.shared.open(Setup.logFile) }
                }
            }
        }
        .padding(24)
    }
}

// MARK: - After setup

struct StatusView: View {
    @EnvironmentObject var state: AppState
    @State private var confirmRemove = false
    @State private var deleteData = false

    var body: some View {
        let c = state.choices
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading) {
                    Text("Kyroco VitalAIze").font(.title.bold())
                    Text(c.role.title).foregroundStyle(.secondary)
                }
            }

            if c.role.runsBoard {
                GroupBox {
                    HStack {
                        Circle().fill(state.running ? Color.green : Color.red).frame(width: 10, height: 10)
                        Text(state.running ? "The board is running at http://localhost:\(c.port)" : "The board is not answering")
                        Spacer()
                        Button("Check again") { state.refreshStatus() }
                    }
                    .padding(6)
                }
                HStack {
                    Button("Open the board") { state.open("/") }.keyboardShortcut(.defaultAction)
                    Button("Settings") { state.open("/settings") }
                    Button("Restart the board") {
                        Setup.restartBoard()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { state.refreshStatus() }
                    }
                    Button("Show the log") { NSWorkspace.shared.open(Setup.logFile) }
                }
                Text("Other Macs connect from the board's settings page (Connect another Mac), or by running this app there and picking Collector only.")
                    .foregroundStyle(.secondary)
            } else {
                GroupBox {
                    Text("This Mac sends its Claude sessions to \(c.hubURL).").padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer()
            Divider()
            HStack {
                Button("Reconfigure…") { state.reconfigure() }
                Spacer()
                Button("Remove VitalAIze…", role: .destructive) { confirmRemove = true }
            }
        }
        .padding(24)
        .sheet(isPresented: $confirmRemove) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Remove VitalAIze from this Mac?").font(.headline)
                Text("This stops the board and takes out the hooks it added. Your Claude settings otherwise stay as they are.")
                    .foregroundStyle(.secondary)
                Toggle("Also delete the database and settings in \(Setup.dataFolder ?? "")", isOn: $deleteData)
                HStack {
                    Spacer()
                    Button("Cancel") { confirmRemove = false }
                    Button("Remove", role: .destructive) { confirmRemove = false; state.uninstall(deleteData: deleteData) }
                }
            }
            .padding(24)
            .frame(width: 460)
        }
    }
}

// MARK: - Helpers

func pickFolder(start: String, message: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.showsHiddenFiles = true
    panel.message = message
    panel.directoryURL = URL(fileURLWithPath: start)
    return panel.runModal() == .OK ? panel.url?.path : nil
}

extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
