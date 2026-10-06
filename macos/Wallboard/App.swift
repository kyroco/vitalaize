import AppKit
import SwiftUI

/// Starts the window, or with arguments works from the command line:
///
///   VitalAIze --detect                print what setup would fill in (JSON)
///   VitalAIze --install FILE.json     install from saved choices
///   VitalAIze --uninstall             remove it again (keeps the data)
///   VitalAIze --settings              print this Mac's settings (JSON)
///   VitalAIze --save FILE.json        save settings: {"values": {"port": "4800"}}
///   VitalAIze --pair [ADDRESS]        pair this Mac with a hub by code
///   VitalAIze --mend                  check how VitalAIze starts here, and mend it
///
/// The command line is for setting up Macs by script, and for testing.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.count > 1, let code = CLI.run(Array(args.dropFirst())) { exit(code) }
        #if UITEST
        UITest.arm()
        #endif
        WallboardApp.main()
    }
}

enum CLI {
    static func run(_ args: [String]) -> Int32? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        switch args.first {
        case "--detect":
            let c = Setup.detect()
            print(String(decoding: try! enc.encode(c), as: UTF8.self))
            return 0
        case "--install":
            guard args.count > 1, let data = FileManager.default.contents(atPath: args[1]),
                  let c = try? JSONDecoder().decode(Choices.self, from: data) else {
                print("Usage: VitalAIze --install choices.json (as printed by --detect)")
                return 2
            }
            do {
                try Setup.install(c) { print($0) }
                return 0
            } catch {
                print("Failed: \(error.localizedDescription)")
                return 1
            }
        case "--uninstall":
            do {
                try Setup.uninstall(deleteData: args.contains("--delete-data")) { print($0) }
                return 0
            } catch {
                print("Failed: \(error.localizedDescription)")
                return 1
            }
        case "--settings":
            guard let doc = Setup.settingsDoc() else {
                print("Could not read the settings.")
                return 1
            }
            print(String(decoding: try! enc.encode(doc), as: UTF8.self))
            return 0
        case "--save":
            guard args.count > 1, let data = FileManager.default.contents(atPath: args[1]),
                  let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let values = body["values"] as? [String: String] else {
                print("Usage: VitalAIze --save FILE.json, holding {\"values\": {\"port\": \"4800\"}}")
                return 2
            }
            let answer = Setup.save(values)
            for line in answer.lines ?? [] { print(line) }
            for (key, message) in (answer.errors ?? [:]).sorted(by: { $0.key < $1.key }) { print("\(key): \(message)") }
            return answer.ok ? 0 : 1
        case "--pair":
            let answer = Setup.pair(hub: args.count > 1 ? args[1] : "") { code in
                print("Approve this code in the mailbox on \(code.hub.isEmpty ? "the hub" : code.hub)'s board: \(code.code)")
            }
            print(answer.message)
            return answer.ok ? 0 : 1
        case "--mend":
            guard let record = Setup.installed() else {
                print("VitalAIze is not set up on this Mac.")
                return 1
            }
            guard let fault = Setup.startFault(record) else {
                print("Nothing to mend.")
                return 0
            }
            print(fault)
            do {
                try Setup.mend(record) { print($0) }
                return 0
            } catch {
                print("Failed: \(error.localizedDescription)")
                return 1
            }
        default:
            return nil
        }
    }
}

struct WallboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("VitalAIze") {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 720, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Which screen shows, and the work behind each.
final class AppState: ObservableObject {
    enum Screen { case detecting, wizard, working, status, settings }

    @Published var screen: Screen = .detecting
    @Published var choices = Choices()
    @Published var step = 0
    @Published var log: [String] = []
    @Published var failure: String?
    /// What runs on this Mac after a setup that failed.
    @Published var failureAfter: String?
    /// While Remove is working, and what it left behind once it is done.
    @Published var removing = false
    @Published var removed: String?
    @Published var running = false
    @Published var workflows: [String] = []
    /// Look up on the wizard's GitHub step: whether it is asking now, and
    /// what it found or why it found nothing.
    @Published var lookingUp = false
    @Published var lookupNote: Note?
    @Published var awsProfiles: [String] = []
    @Published var tools: [(String, Bool)] = []
    /// Whether the recent sessions were found to use Korium, when this run
    /// looked (a first setup does; Reconfigure does not).
    @Published var koriumFound: Bool?

    /// The New Relic key typed in the wizard. Never one of the choices:
    /// those are written to install.json. It goes to the board's own code,
    /// which keeps it in the keychain, and is emptied once the setup ends.
    @Published var newRelicKey = ""

    /// True when the settings in use have a New Relic key kept.
    var newRelicKeySet: Bool {
        doc?.sections.flatMap { $0.fields }.first { $0.key == "new_relic.api_key" }.map { !$0.value.isEmpty } ?? false
    }

    /// The settings as the board's own code gives them, and what has been
    /// typed over them on the Settings screen (by setting key).
    @Published var doc: SettingsDoc?
    @Published var edits: [String: String] = [:]
    @Published var saveLines: [String] = []
    @Published var saveErrors: [String: String] = [:]
    /// Said in red under a save: the board did not come back after it.
    @Published var saveFailure: String?
    @Published var busy = false

    /// Pairing with a hub: the code to show while the hub's owner decides,
    /// and how it ended.
    @Published var pairCode: PairCode?
    @Published var pairMessage: String?
    @Published var pairing = false

    /// What the app found wrong with how VitalAIze starts on this Mac and
    /// did about it, for the first screen; and what it could not mend.
    @Published var mendLines: [String] = []
    @Published var mendFailure: String?
    @Published var mendDone: String?
    @Published var mending = false
    private var ticks = 0

    /// Said on the wizard's second step when the earlier settings file the
    /// setup carried over before is gone.
    @Published var importNote: String?
    /// Said under the board's folder when it already holds a board's settings.
    @Published var folderNote: String?
    /// Where "Back" goes after a failure: the setup, or the first screen
    /// when it was Remove that stopped.
    @Published var failureBack: Screen = .wizard
    /// The earlier settings file the wizard offered to carry over, kept
    /// while its switch is off.
    @Published var offeredImport: String?

    let finder = HubFinderHolder.shared

    init() {
        #if UITEST
        UITest.state = self
        #endif
        if let record = Setup.installed() {
            let checked = Setup.checkedImport(record.choices)
            choices = checked.choices
            importNote = checked.note
            screen = .status
            checkStart()
        } else {
            detect()
        }
    }

    /// Looks at how VitalAIze starts on this Mac and mends it when it
    /// cannot: an app installed over an older one finds a login item that
    /// names the older app. With nothing to mend, it restarts what runs
    /// when `restart` asks for it, or when what runs is older than this
    /// app. Each thing it does is a line on the first screen.
    func checkStart(restart: Bool = false) {
        mending = true
        mendFailure = nil
        mendDone = nil
        mendLines = []
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            var failure: String?
            var done: String?
            func say(_ line: String) {
                lines.append(line)
                let now = lines
                DispatchQueue.main.async { self.mendLines = now }
            }
            if let record = Setup.installed() {
                let board = record.choices.role.runsBoard
                let what = board ? "The board" : "The collector"
                if let fault = Setup.startFault(record) {
                    say(fault)
                    do {
                        try Setup.mend(record, say: say)
                        done = "Mended. Your settings and database are where they were."
                    } catch {
                        failure = error.localizedDescription
                    }
                } else {
                    let older = !restart && Setup.runningIsOlder()
                    if restart || older {
                        say(older
                            ? "\(what) that was running was started before this version of the app was installed. Restarting it…"
                            : "Restarting \(what.lowercased())…")
                        Setup.restartBoard()
                        // Time to stop before asking whether it is back.
                        sleep(4)
                        let back = board ? Setup.waitForBoard(port: Setup.currentPort(record.choices), seconds: 60) : Setup.waitForService(seconds: 30)
                        if back {
                            done = board ? "The board restarted and is answering." : "The collector restarted and is running."
                        } else {
                            failure = "\(what) did not come back within a minute. Its log is at \(Setup.logFile.path)."
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                self.mending = false
                self.mendFailure = failure
                self.mendDone = done
                self.refreshStatus()
            }
        }
    }

    /// True when the wizard is set to leave a paired collector's pairing as
    /// it is: no hub address was given, and it is paired already.
    var keepsPairing: Bool {
        !choices.role.runsBoard && choices.hubURL.trimmingCharacters(in: .whitespaces).isEmpty && doc?.paired != nil
    }

    var isAppleSilicon: Bool {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        return machine.hasPrefix("arm64")
    }

    /// Fills in the wizard from this Mac, off the main thread.
    func detect() {
        screen = .detecting
        DispatchQueue.global(qos: .userInitiated).async {
            var found = Setup.detect()
            // A folder kept by Remove still holds its settings: the setup
            // starts from them, as Reconfigure does, so they are not lost.
            if FileManager.default.fileExists(atPath: found.dataFolder + "/settings.exs"),
               let doc = Setup.settingsDoc(dataFolder: found.dataFolder) {
                found = Setup.prefill(found, from: doc)
                found.settingsReadFrom = found.dataFolder
            }
            let flows = found.repo.isEmpty ? [] : Detect.workflows(repo: found.repo)
            let profiles = Detect.awsProfiles()
            let tools = [("claude", Shell.which("claude") != nil),
                         ("gh (signed in)", Shell.which("gh") != nil && Detect.ghSignedIn()),
                         ("aws", Shell.which("aws") != nil),
                         ("op (1Password)", Shell.which("op") != nil)]
            DispatchQueue.main.async {
                self.choices = found
                self.importNote = nil
                self.folderNote = found.settingsReadFrom == nil ? nil : AppState.keptNote
                self.offeredImport = nil
                self.lookupNote = nil
                self.koriumFound = found.korium
                self.workflows = flows
                self.awsProfiles = profiles
                self.tools = tools
                self.step = 0
                self.screen = .wizard
                self.finder.start()
            }
        }
    }

    static let keptNote = "This folder holds a board's settings. The setup is filled in from them, so they are kept unless you change an answer."

    /// Takes the folder picked for the board's files. One that already
    /// holds a board's settings fills the setup in from the settings in
    /// use there, as the usual folder does when the app opens: the answers
    /// then start from what that board has, and nothing it saved is lost.
    func useFolder(_ folder: String) {
        choices.dataFolder = folder
        choices.settingsReadFrom = nil
        folderNote = nil
        guard FileManager.default.fileExists(atPath: folder + "/settings.exs") else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let doc = Setup.settingsDoc(dataFolder: folder) else { return }
            DispatchQueue.main.async {
                // Another folder may have been picked meanwhile.
                guard self.screen == .wizard, self.choices.dataFolder == folder else { return }
                // What this Mac does was picked on the first step.
                let role = self.choices.role
                var filled = Setup.prefill(self.choices, from: doc)
                filled.role = role
                filled.settingsReadFrom = folder
                self.choices = filled
                self.folderNote = AppState.keptNote
            }
        }
    }

    /// Opens the wizard on what is installed, with the lists it offers. It
    /// starts from the settings in use now, so what was changed in
    /// Settings since the first setup shows, and is not put back.
    func reconfigure() {
        let checked = Setup.checkedImport(choices)
        choices = checked.choices
        if let note = checked.note { importNote = note }
        step = 0
        screen = .detecting
        lookupNote = nil
        folderNote = nil
        koriumFound = nil
        finder.start()
        let before = choices
        DispatchQueue.global().async {
            let doc = Setup.settingsDoc()
            var now = before
            // Without the settings the wizard starts from the setup's own
            // record, and an answer left empty changes nothing saved.
            now.settingsRead = nil
            now.settingsReadFrom = nil
            if let doc {
                now = Setup.prefill(now, from: doc)
                now.settingsReadFrom = now.dataFolder
            }
            // A paired collector stays paired unless a hub is picked again.
            if now.role == .collector, doc?.paired != nil { now.hubURL = "" }
            let repo = now.repo
            let flows = repo.isEmpty ? [] : Detect.workflows(repo: repo)
            let profiles = Detect.awsProfiles()
            let tools = [("claude", Shell.which("claude") != nil),
                         ("gh (signed in)", Shell.which("gh") != nil && Detect.ghSignedIn()),
                         ("aws", Shell.which("aws") != nil),
                         ("op (1Password)", Shell.which("op") != nil)]
            DispatchQueue.main.async {
                self.choices = now
                if let doc { self.doc = doc }
                self.workflows = flows
                self.awsProfiles = profiles
                self.tools = tools
                self.screen = .wizard
            }
        }
    }

    /// Looks up the workflows again after the repository changes.
    func reloadWorkflows() {
        let repo = choices.repo.trimmingCharacters(in: .whitespaces)
        guard repo.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else {
            lookupNote = Note(ok: false, text: repo.isEmpty
                ? "Type the repository as owner/name in the box, then press Look up."
                : "\"\(repo)\" is not a repository name. Write it as owner/name, like kyroco/vitalaize.")
            return
        }
        choices.repo = repo
        lookingUp = true
        lookupNote = nil
        DispatchQueue.global().async {
            let found = Detect.lookUp(repo: repo)
            let flows = found.workflows
            let branch = found.branch
            DispatchQueue.main.async {
                self.lookingUp = false
                self.lookupNote = found.note
                // A look up that failed found nothing out: what was
                // picked stays.
                guard found.note.ok else { return }
                self.workflows = flows
                let g = Detect.guessWorkflows(flows)
                if self.choices.gateWorkflow.isEmpty || !flows.contains(self.choices.gateWorkflow) { self.choices.gateWorkflow = g.gate }
                if self.choices.devWorkflow.isEmpty || !flows.contains(self.choices.devWorkflow) { self.choices.devWorkflow = g.dev }
                if self.choices.prodWorkflow.isEmpty || !flows.contains(self.choices.prodWorkflow) { self.choices.prodWorkflow = g.prod }
                if let branch { self.choices.branch = branch }
            }
        }
    }

    func install() {
        log = []
        failure = nil
        failureBack = .wizard
        failureAfter = nil
        removing = false
        removed = nil
        screen = .working
        let c = choices
        let key = newRelicKey
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let pairing = try Setup.install(c, newRelicKey: key,
                                                onCode: { code in DispatchQueue.main.async { self.pairCode = code } },
                                                say: { line in DispatchQueue.main.async { self.log.append(line) } })
                DispatchQueue.main.async {
                    self.newRelicKey = ""
                    // Why the hub did not pair stays on the first screen:
                    // the setup's own lines are gone once it shows.
                    if let pairing, !pairing.ok {
                        self.pairMessage = "The collector is set up, but it did not pair. \(pairing.message) Use Pair with a hub… to try again."
                    } else {
                        self.pairMessage = nil
                    }
                    self.finder.stop()
                    // The setup ended with it running, so the first screen
                    // does not say otherwise while it looks again.
                    self.running = true
                    self.screen = .status
                    self.refreshStatus()
                }
            } catch {
                // Said with the failure: whether VitalAIze runs on this Mac
                // now, so nobody has to go and find out.
                let after = Setup.runningNow(c)
                DispatchQueue.main.async {
                    self.failure = error.localizedDescription
                    self.failureAfter = after
                }
            }
        }
    }

    /// Removes VitalAIze from this Mac, and then says so: the screen stays
    /// on what was done until the person goes on.
    func uninstall(deleteData: Bool) {
        log = []
        failure = nil
        removing = true
        removed = nil
        screen = .working
        let folder = Setup.dataFolder
        let c = choices
        DispatchQueue.global().async {
            do {
                try Setup.uninstall(deleteData: deleteData) { line in DispatchQueue.main.async { self.log.append(line) } }
            } catch {
                // Nothing was removed: say so, and what runs.
                let after = Setup.runningNow(c)
                DispatchQueue.main.async {
                    self.removing = false
                    self.failure = error.localizedDescription
                    self.failureAfter = after
                    self.failureBack = .status
                }
                return
            }
            DispatchQueue.main.async {
                self.removing = false
                self.running = false
                self.doc = nil
                self.mendLines = []
                self.mendDone = nil
                self.mendFailure = nil
                let kept = folder.map { "Its database and settings are still in \($0). Setting up again with the same folder picks them up." }
                self.removed = deleteData ? "Its database and settings were deleted too, and any key typed in Settings was taken out of the keychain." : (kept ?? "")
            }
        }
    }

    /// Looks again at what runs here: the board answering on its port or
    /// the collector's login item, and the settings as they are now.
    func refreshStatus() {
        let wizardRunsBoard = choices.role.runsBoard
        let knownPort = choices.port
        DispatchQueue.global().async {
            let doc = Setup.settingsDoc()
            let runsBoard = doc.map { $0.role != "collector" } ?? wizardRunsBoard
            // The port may have been changed here or with vitalaize setup.
            let port = doc?.sections.flatMap { $0.fields }.first { $0.key == "port" }.flatMap { Int($0.value) }
            let up = runsBoard ? Setup.boardRunning(port: port ?? knownPort) : Setup.serviceRunning()
            DispatchQueue.main.async {
                // Not while the setup is open: there the port is the person's to type.
                if let port, self.screen == .status || self.screen == .settings { self.choices.port = port }
                if let doc { self.take(doc) }
                self.running = up
            }
        }
    }

    /// Keeps the settings as read, and with them what this Mac does now:
    /// the role may have been changed with `vitalaize setup` since the
    /// wizard ran.
    func take(_ doc: SettingsDoc) {
        self.doc = doc
        let role: Role = doc.role == "collector" ? .collector : (doc.role == "hub" ? .hub : .hubAndCollector)
        // Not while the wizard is open: there the role is the person's to pick.
        if role != choices.role && (screen == .status || screen == .settings) { choices.role = role }
    }

    // MARK: Settings, saved here with no browser

    func openSettings() {
        saveLines = []
        saveErrors = [:]
        saveFailure = nil
        mendLines = []
        mendDone = nil
        mendFailure = nil
        screen = .settings
        loadSettings()
    }

    func loadSettings() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let doc = Setup.settingsDoc()
            DispatchQueue.main.async {
                self.busy = false
                if let doc { self.take(doc) } else { self.doc = nil }
                self.edits = [:]
                if doc == nil { self.saveLines = ["The settings could not be read. The log is at \(Setup.logFile.path)."] }
            }
        }
    }

    /// What the Settings screen shows for a setting: what was typed, or
    /// its saved value.
    func value(_ field: SettingsField) -> String { edits[field.key] ?? field.value }

    /// Saves what was changed. The board's own code writes the file and
    /// restarts the board or the collector only when a change needs it; the
    /// lines it answers say which.
    func saveSettings() {
        let fields = doc?.sections.flatMap { $0.fields } ?? []
        let changed = edits.filter { key, text in fields.first { $0.key == key }?.value != text }
        guard !changed.isEmpty else { saveLines = ["Nothing changed."]; return }
        busy = true
        saveLines = []
        saveErrors = [:]
        saveFailure = nil
        let runsBoard = choices.role.runsBoard
        let knownPort = choices.port
        DispatchQueue.global(qos: .userInitiated).async {
            let answer = Setup.save(changed)
            let doc = answer.ok ? Setup.settingsDoc() : nil
            DispatchQueue.main.async {
                self.saveLines = answer.lines ?? []
                self.saveErrors = answer.errors ?? [:]
                if answer.ok {
                    if let doc { self.take(doc) }
                    self.edits = [:]
                } else {
                    self.busy = false
                }
            }
            // Only a save that restarted the board or the collector has
            // anything to wait for.
            guard answer.ok, (answer.lines ?? []).contains(where: { $0.hasPrefix("Restarted ") }) else {
                DispatchQueue.main.async { self.busy = false; self.refreshStatus() }
                return
            }
            // Say whether it came back, so nobody leaves this screen with
            // it down and unsaid. A restart takes a few seconds to begin.
            sleep(3)
            let port = doc?.sections.flatMap { $0.fields }.first { $0.key == "port" }.flatMap { Int($0.value) }
            let board = doc.map { $0.role != "collector" } ?? runsBoard
            let back = board ? Setup.waitForBoard(port: port ?? knownPort, seconds: 60) : Setup.waitForService(seconds: 30)
            DispatchQueue.main.async {
                self.busy = false
                if back {
                    self.saveLines.append(board ? "The board is answering at http://localhost:\(String(port ?? knownPort))." : "The collector is running.")
                } else {
                    self.saveFailure = "\(board ? "The board has not answered for a minute" : "The collector has not started for half a minute") since the save. Go back and use Show the log to see why; your settings are saved."
                }
                self.refreshStatus()
            }
        }
    }

    /// A light look at whether the board answers or the collector runs,
    /// for the first screen to keep itself true while it shows.
    func quickCheck() {
        guard screen == .status, !mending else { return }
        let board = choices.role.runsBoard
        let port = choices.port
        // A collector's link to its hub comes and goes without the
        // collector stopping, so its line is read again every half minute.
        ticks += 1
        if !board, ticks % 6 == 0 { return refreshStatus() }
        DispatchQueue.global(qos: .utility).async {
            let up = board ? Setup.boardRunning(port: port) : Setup.serviceRunning()
            DispatchQueue.main.async { if self.screen == .status, self.running != up { self.refreshStatus() } }
        }
    }

    // MARK: Pairing with a hub

    /// Asks a hub to pair and shows the code until its owner decides.
    /// `hub` is its address, or empty to look for one on the network.
    func pair(hub: String) {
        pairing = true
        pairCode = nil
        pairMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let answer = Setup.pair(hub: hub) { code in DispatchQueue.main.async { self.pairCode = code } }
            DispatchQueue.main.async {
                self.pairing = false
                self.pairCode = nil
                self.pairMessage = answer.message
                self.refreshStatus()
            }
        }
    }

    /// True when the board asks for a password. The password itself is
    /// never handed to the app, only that there is one.
    var hasPassword: Bool {
        doc?.sections.flatMap { $0.fields }.first { $0.key == "token" }?.value.isEmpty == false
    }

    func open(_ path: String) {
        // By number: the board listens there, and "localhost" could be
        // answered by another program at ::1.
        if let url = URL(string: "http://127.0.0.1:\(choices.port)\(path)") { Shell.open(url) }
    }
}
