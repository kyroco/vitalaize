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
        case .settings: SettingsView()
        }
    }
}

// MARK: - Looking around

struct DetectingView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Looking at this Mac to fill in the setup…").font(.headline)
            Text(state.choices.settingsRead == nil && Setup.installed() != nil
                 ? "Reading the settings in use now, so the setup starts from them."
                 : "Claude folders, the GitHub repository you work in, Korium, AWS profiles, and any board set up before.")
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
                    Button(state.choices.role.runsBoard ? "Install and start the board" : (state.keepsPairing ? "Start the collector" : "Start the collector and pair")) { state.install() }
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
        case (false, 2): return !c.hubURL.trimmingCharacters(in: .whitespaces).isEmpty || state.doc?.paired != nil
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
                                state.useFolder(url)
                            }
                        }
                    }
                    Text("Its settings, its database of sessions and runs, and incoming sessions from other Macs. The board itself stays inside this app.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let note = state.folderNote {
                        Label(note, systemImage: "info.circle").fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            // Turned off, the switch stays so it can be turned on again.
            if let imported = state.choices.importedSettings ?? state.offeredImport {
                GroupBox("A board you set up before") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Carry over its settings from \(imported.replacingOccurrences(of: Detect.home.path, with: "~"))",
                               isOn: Binding(get: { state.choices.importedSettings != nil },
                                             set: { on in
                                                 state.offeredImport = imported
                                                 state.choices.importedSettings = on ? imported : nil
                                             }))
                        if Detect.oldLoginItemInstalled {
                            Toggle("Stop that board and run this one instead", isOn: $state.choices.replaceOldBoard)
                        }
                        Text("Its phone number, New Relic checks and anything else it holds stay; your answers here win where they differ. Its database is kept when you use the same folder.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            if let note = state.importNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct GitHubPage: View {
    @EnvironmentObject var state: AppState
    @State private var newRepo = ""
    @State private var addNote: Note?

    private var others: [String] { state.choices.otherRepos ?? [] }

    var body: some View {
        Text("Found from the git remotes of your recent Claude sessions. Change them if the board should watch other repositories.")
            .foregroundStyle(.secondary)
        Form {
            HStack {
                TextField("Repository", text: $state.choices.repo, prompt: Text("owner/name"))
                    .onSubmit { state.reloadWorkflows() }
                Button("Look up") { state.reloadWorkflows() }
                    .disabled(state.lookingUp)
            }
            if state.lookingUp {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Asking GitHub about \(state.choices.repo)…").foregroundStyle(.secondary)
                }
            } else if let note = state.lookupNote {
                Label(note.text, systemImage: note.ok ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(note.ok ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
                        Button("Remove") {
                            state.choices.otherRepos = others.filter { $0 != repo }
                            addNote = Note(ok: true, text: "Removed \(repo).")
                        }
                    }
                }
                HStack {
                    TextField("Add another", text: $newRepo, prompt: Text("owner/name"))
                        .onSubmit(add)
                    Button("Add", action: add)
                }
                if let note = addNote {
                    Label(note.text, systemImage: note.ok ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(note.ok ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Other repositories")
            } footer: {
                Text("Each gets its own column on the board's Git tab and shows its own workflow runs. The workflows above are the first repository's, and Dev and Prod follow it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
    }

    /// Adds the typed repository to the list, or says why it was not added.
    /// What was typed stays in the field when it is refused, to be fixed.
    private func add() {
        let repo = newRepo.trimmingCharacters(in: .whitespaces)
        // owner/name, the only form the board accepts.
        let ok = repo.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
        if repo.isEmpty {
            addNote = Note(ok: false, text: "Type a repository as owner/name in the box, then press Add.")
        } else if !ok {
            addNote = Note(ok: false, text: "\"\(repo)\" is not a repository name. Write it as owner/name, like kyroco/vitalaize. Nothing was added.")
        } else if repo == state.choices.repo.trimmingCharacters(in: .whitespaces) {
            addNote = Note(ok: false, text: "\(repo) is already the first repository above. Nothing was added.")
        } else if others.contains(repo) {
            addNote = Note(ok: false, text: "\(repo) is already in the list. Nothing was added.")
        } else {
            state.choices.otherRepos = others + [repo]
            addNote = Note(ok: true, text: "Added \(repo).")
            newRepo = ""
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
                if let found = state.koriumFound {
                    Text(found ? "Your recent sessions use Korium." : "Your recent sessions do not seem to use Korium.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                    SecureField("New Relic API key", text: $state.newRelicKey,
                                prompt: Text(state.newRelicKeySet ? "set; type a new one to replace it" : "NRAK-…"))
                    Text("Paste the User key (it starts with NRAK-). It is kept in your keychain, never in a file.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Or where it is in 1Password", text: $state.choices.newRelicKeyRef, prompt: Text("op://…"))
                    Text("Read with 1Password's op command. Used when no key is typed above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Texts when a session needs you") {
                TextField("Phone number", text: $state.choices.phone, prompt: Text("empty for no texts"))
                Picker("Send as", selection: $state.choices.textVia) {
                    Text("iMessage").tag("iMessage")
                    Text("SMS").tag("SMS")
                }
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
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
        Text("Pick the hub this Mac streams its Claude and Codex sessions to. This Mac then shows a short code; approve the same code in the mailbox on the hub's board. Nothing is typed or pasted.")
            .foregroundStyle(.secondary)
        if let hub = state.doc?.paired {
            Label("This Mac is paired with the hub at \(hub.host) as \(hub.machine). Leave the address empty to keep that, or pick a hub to pair again.", systemImage: "checkmark.circle")
                .fixedSize(horizontal: false, vertical: true)
        }
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
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        Form {
            TextField("Hub address", text: $state.choices.hubURL, prompt: Text(verbatim: "http://192.168.1.20:4747"))
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        Text("The hub must take collectors: on the hub, turn on Collectors on other machines in its settings.")
            .font(.caption).foregroundStyle(.secondary)
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
                    row("Hub", state.keepsPairing ? "stays paired with \(state.doc?.paired?.host ?? "its hub")" : c.hubURL)
                    row("Codex", Detect.usesCodex() ? "watched too, in ~/.codex" : "not on this Mac")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        Text(c.role.runsBoard
             ? "The board starts now and again whenever you log in. You can change any of this later in this app, under Settings."
             : "A small collector starts now and again whenever you log in. It watches this Mac's Claude and Codex sessions and streams them to the hub as they happen. It adds nothing to Claude's or Codex's own settings." + (state.keepsPairing ? "" : " After it starts, this Mac shows a code to approve on the hub."))
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
                if state.failure == nil && state.removed == nil { ProgressView().controlSize(.small) }
                Text(title).font(.title2.bold())
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(state.log.enumerated()), id: \.offset) { _, line in
                        Label(line, systemImage: "checkmark").foregroundStyle(.primary)
                    }
                    if let failure = state.failure {
                        Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        if let after = state.failureAfter {
                            Text(after).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let code = state.pairCode { PairCodeView(code: code) }
            if state.failure != nil {
                HStack {
                    Button(state.failureBack == .wizard ? "Back to the setup" : "Back") {
                        state.failure = nil
                        state.screen = state.failureBack
                        if state.failureBack == .status { state.refreshStatus() }
                    }
                    Button("Open the log") { Shell.open(Setup.logFile) }
                }
            }
            if let removed = state.removed {
                if !removed.isEmpty {
                    Text(removed).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                Text("The app itself is still in Applications. Drag it to the Trash to take it off this Mac.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Set up again") { state.removed = nil; state.detect() }
            }
        }
        .padding(24)
    }

    private var title: String {
        if state.failure != nil { return "That did not work" }
        if state.removed != nil { return "VitalAIze was removed from this Mac" }
        return state.removing ? "Removing VitalAIze…" : "Setting up…"
    }
}

// MARK: - After setup

struct StatusView: View {
    @EnvironmentObject var state: AppState
    @State private var confirmRemove = false
    @State private var deleteData = false
    @State private var showPair = false

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
                        // verbatim: a Text made from a literal writes a number the
                        // way the Mac's region does, and a port is not "4,747".
                        Text(verbatim: state.running ? "The board is running at http://localhost:\(c.port)" : "The board is not answering")
                        Spacer()
                        Button("Check again") { state.refreshStatus() }
                    }
                    .padding(6)
                }
                HStack {
                    Button("Open the board") { state.open("/") }.keyboardShortcut(.defaultAction)
                    Button("Settings") { state.openSettings() }
                    Button("Restart the board") { state.checkStart(restart: true) }
                        .disabled(state.mending)
                    Button("Show the log") { Shell.open(Setup.logFile) }
                }
                if state.hasPassword {
                    Text("This board has a password. The first time a browser opens it, add ?token= and the password to the end of the address.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Other machines connect by running this app there (or vitalaize setup on Linux) and picking Collector only. Each shows a code; approve it in the mailbox on the board.")
                    .foregroundStyle(.secondary)
            } else {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Circle().fill(state.running ? Color.green : Color.red).frame(width: 10, height: 10)
                            Text(state.running ? "The collector is running" : "The collector is not running")
                            Spacer()
                            Button("Check again") { state.refreshStatus() }
                        }
                        if let hub = state.doc?.paired {
                            LinkLine(hub: hub, link: state.running ? state.doc?.link : nil)
                        } else if state.doc != nil {
                            Text("Not paired with a hub yet, so nothing is sent.").foregroundStyle(.red)
                        }
                        if let message = state.pairMessage {
                            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button(state.doc?.paired == nil ? "Pair with a hub…" : "Pair again…") { showPair = true }
                        .keyboardShortcut(.defaultAction)
                    Button("Settings") { state.openSettings() }
                    Button("Restart the collector") { state.checkStart(restart: true) }
                        .disabled(state.mending)
                    Button("Show the log") { Shell.open(Setup.logFile) }
                }
            }

            if state.mending || !state.mendLines.isEmpty || state.mendFailure != nil { MendBox() }

            Spacer()
            Divider()
            HStack {
                Button("Reconfigure…") { state.reconfigure() }
                Spacer()
                Button("Remove VitalAIze…", role: .destructive) { confirmRemove = true }
            }
        }
        .padding(24)
        // Keeps the first line true while the screen shows: a board that
        // stops, or comes back after a restart, is seen without a click.
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in state.quickCheck() }
        .sheet(isPresented: $showPair) { PairSheet(shown: $showPair) }
        .sheet(isPresented: $confirmRemove) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Remove VitalAIze from this Mac?").font(.headline)
                Text("This stops VitalAIze on this Mac and takes away its login item and its certificate for its hub. Upload hooks an earlier version added to Claude or Codex are taken out too, with a copy of each file kept beside it. Your Claude and Codex settings otherwise stay as they are.")
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

/// What the app found wrong with how VitalAIze starts here, and what it
/// did about it.
struct MendBox: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if state.mending {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(state.mendLines.isEmpty ? "Checking how VitalAIze starts on this Mac…" : "Working on it…")
                    }
                }
                ForEach(Array(state.mendLines.enumerated()), id: \.offset) { _, line in
                    Text(line).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if let failure = state.mendFailure {
                    Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Use Show the log to see why, then Reconfigure to set it up again. Your settings and database are where they were.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if !state.mending, let done = state.mendDone {
                    Label(done, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Whether a paired collector is in touch with its hub right now.
struct LinkLine: View {
    let hub: Paired
    let link: LinkState?

    var body: some View {
        switch link?.state {
        case "up":
            Text("Connected to the hub at \(hub.host) as \(hub.machine).")
        case "down":
            Text("Paired with the hub at \(hub.host) as \(hub.machine), but the hub is not answering right now. What this Mac reads is kept, and sent when the hub answers again.")
                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case "back_soon":
            Text("Paired with the hub at \(hub.host) as \(hub.machine). The hub is restarting; sending goes on when it is back.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case "removed":
            Text("The hub at \(hub.host) removed this machine, so nothing is sent. Use Pair again… to connect it again.")
                .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        default:
            Text("Paired with the hub at \(hub.host) as \(hub.machine).")
        }
    }
}

// MARK: - Pairing

/// The code to approve on the hub, as large as mockup 8 shows it.
struct PairCodeView: View {
    let code: PairCode

    var body: some View {
        VStack(spacing: 8) {
            Text("Connect to \(code.hub.isEmpty ? "the hub" : code.hub)").font(.headline)
            Text("Open the mailbox on the board and approve this code. It matches only this machine and expires in \(code.expires_in / 60) minutes.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text(code.code).font(.system(size: 44, weight: .bold, design: .monospaced)).textSelection(.enabled)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for the hub to approve…").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

/// Picks a hub and pairs with it, from the collector's first screen.
struct PairSheet: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var finder: HubFinder
    @Binding var shown: Bool
    @State private var address = ""

    init(shown: Binding<Bool>) {
        _shown = shown
        _finder = ObservedObject(wrappedValue: HubFinderHolder.shared)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pair with a hub").font(.headline)
            if let code = state.pairCode {
                PairCodeView(code: code)
            } else if state.pairing {
                HStack { ProgressView().controlSize(.small); Text("Asking the hub…").foregroundStyle(.secondary) }
            } else {
                Text("Pick the hub, or type its address. This Mac then shows a code to approve in the mailbox on the hub's board.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(finder.hubs) { hub in
                    Button { address = hub.url } label: {
                        HStack {
                            Image(systemName: address == hub.url ? "largecircle.fill.circle" : "circle")
                            Text(hub.name)
                            Text(hub.url).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text("Hub address")
                TextField("Hub address", text: $address, prompt: Text(verbatim: "http://192.168.1.20:4747"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit { if !address.trimmingCharacters(in: .whitespaces).isEmpty { state.pair(hub: address) } }
                if let message = state.pairMessage { Text(message).foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button(state.pairing ? "Hide" : "Close") { shown = false }
                if !state.pairing {
                    Button("Pair") { state.pair(hub: address) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { finder.start() }
    }
}

// MARK: - Settings

/// This Mac's settings, shown and saved here with no browser. The list of
/// settings comes from the board's own code, the same one `vitalaize setup`
/// asks about, and both save to the same file.
struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings").font(.title2.bold())
                Spacer()
                if state.busy { ProgressView().controlSize(.small) }
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 12)
            Divider()

            if let doc = state.doc {
                Form {
                    // What this Mac does is changed with Reconfigure, which
                    // also writes the files that go with a role.
                    ForEach(doc.sections.filter { $0.title != "This machine" }) { section in
                        Section(section.title) {
                            ForEach(section.fields) { field in SettingRow(field: field) }
                        }
                    }
                    Section {
                        Text("To change what this Mac does (board, collector or both), go back and use Reconfigure.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .textFieldStyle(.roundedBorder)
            } else {
                Spacer()
                Text(state.busy ? "Reading the settings…" : "The settings could not be read.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(state.saveLines, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                if !state.saveErrors.isEmpty {
                    Text("Nothing was saved. Fix these and save again:").foregroundStyle(.red)
                    // Named here too: the setting itself may be scrolled out of sight.
                    ForEach(state.saveErrors.sorted { $0.key < $1.key }, id: \.key) { key, message in
                        // The board's message may name the setting already.
                        Text(message.hasPrefix(label(key) + ":") ? message : "\(label(key)): \(message)")
                            .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let failure = state.saveFailure {
                    Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Back") { state.screen = .status; state.refreshStatus() }
                    Spacer()
                    Text("A change that needs it restarts \(state.choices.role.runsBoard ? "the board" : "the collector"); the rest apply by themselves.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Save") { state.saveSettings() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(state.busy || state.doc == nil)
                }
            }
            .padding(16)
        }
    }
}

extension SettingsView {
    /// A setting's name as the screen shows it, for a message about it.
    func label(_ key: String) -> String {
        state.doc?.sections.flatMap { $0.fields }.first { $0.key == key }?.label ?? key
    }
}

/// One setting, drawn by its kind.
struct SettingRow: View {
    @EnvironmentObject var state: AppState
    let field: SettingsField

    private var text: Binding<String> {
        Binding(get: { state.value(field) }, set: { state.edits[field.key] = $0 })
    }

    private var title: String { field.label + (field.restart ? " (restarts)" : "") }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch field.type {
            case "boolean":
                Toggle(title, isOn: Binding(get: { state.value(field) == "true" },
                                            set: { state.edits[field.key] = $0 ? "true" : "false" }))
            case "choice":
                Picker(title, selection: text) {
                    ForEach(field.options, id: \.self) { Text($0).tag($0) }
                }
            case "secret":
                SecureField(title, text: text)
            case "lines", "repos", "folders":
                Text(title)
                TextEditor(text: text)
                    .font(.body.monospaced())
                    .frame(minHeight: field.type == "repos" ? 90 : 54)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.25)))
            default:
                TextField(title, text: text)
            }
            if let help = field.help {
                Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = state.saveErrors[field.key] {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Helpers

func pickFolder(start: String, message: String) -> String? {
    Shell.folderPicker(start, message)
}

/// One line said under a control after it was used: what it did, or why
/// it did nothing.
struct Note: Equatable {
    var ok: Bool
    var text: String
}

extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
