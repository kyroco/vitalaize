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
        WallboardApp.main()
    }
}

enum CLI {
    static func run(_ args: [String]) -> Int32? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        switch args.first {
        case "--detect":
            var c = Setup.detect()
            c.hubKey = ""
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
            Setup.uninstall(deleteData: args.contains("--delete-data")) { print($0) }
            return 0
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
    @Published var running = false
    @Published var workflows: [String] = []
    @Published var awsProfiles: [String] = []
    @Published var tools: [(String, Bool)] = []

    /// The settings as the board's own code gives them, and what has been
    /// typed over them on the Settings screen (by setting key).
    @Published var doc: SettingsDoc?
    @Published var edits: [String: String] = [:]
    @Published var saveLines: [String] = []
    @Published var saveErrors: [String: String] = [:]
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
    @Published var mending = false

    /// Said on the wizard's second step when the earlier settings file the
    /// setup carried over before is gone.
    @Published var importNote: String?

    let finder = HubFinderHolder.shared

    init() {
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
    /// names the older app. `restart` asks for a restart when nothing
    /// needed mending.
    func checkStart(restart: Bool = false) {
        mending = true
        mendFailure = nil
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            var failure: String?
            if let record = Setup.installed(), let fault = Setup.startFault(record) {
                lines.append(fault)
                DispatchQueue.main.async { self.mendLines = lines }
                do {
                    try Setup.mend(record) { line in
                        lines.append(line)
                        let now = lines
                        DispatchQueue.main.async { self.mendLines = now }
                    }
                } catch {
                    failure = error.localizedDescription
                }
            } else if restart {
                Setup.restartBoard()
                sleep(6)
            }
            DispatchQueue.main.async {
                self.mending = false
                self.mendFailure = failure
                self.refreshStatus()
            }
        }
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
            let found = Setup.detect()
            let flows = found.repo.isEmpty ? [] : Detect.workflows(repo: found.repo)
            let profiles = Detect.awsProfiles()
            let tools = [("claude", Shell.which("claude") != nil),
                         ("gh (signed in)", Shell.which("gh") != nil && Detect.ghSignedIn()),
                         ("aws", Shell.which("aws") != nil),
                         ("op (1Password)", Shell.which("op") != nil)]
            DispatchQueue.main.async {
                self.choices = found
                self.workflows = flows
                self.awsProfiles = profiles
                self.tools = tools
                self.step = 0
                self.screen = .wizard
                self.finder.start()
            }
        }
    }

    /// Opens the wizard on what is installed, with the lists it offers.
    func reconfigure() {
        let checked = Setup.checkedImport(choices)
        choices = checked.choices
        if let note = checked.note { importNote = note }
        step = 0
        screen = .wizard
        finder.start()
        let repo = choices.repo
        DispatchQueue.global().async {
            let flows = repo.isEmpty ? [] : Detect.workflows(repo: repo)
            let profiles = Detect.awsProfiles()
            let tools = [("claude", Shell.which("claude") != nil),
                         ("gh (signed in)", Shell.which("gh") != nil && Detect.ghSignedIn()),
                         ("aws", Shell.which("aws") != nil),
                         ("op (1Password)", Shell.which("op") != nil)]
            DispatchQueue.main.async {
                self.workflows = flows
                self.awsProfiles = profiles
                self.tools = tools
            }
        }
    }

    /// Looks up the workflows again after the repository changes.
    func reloadWorkflows() {
        let repo = choices.repo
        DispatchQueue.global().async {
            let flows = Detect.workflows(repo: repo)
            let branch = Detect.defaultBranch(repo: repo)
            DispatchQueue.main.async {
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
        screen = .working
        let c = choices
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Setup.install(c, onCode: { code in DispatchQueue.main.async { self.pairCode = code } },
                                  say: { line in DispatchQueue.main.async { self.log.append(line) } })
                DispatchQueue.main.async {
                    self.finder.stop()
                    self.screen = .status
                    self.refreshStatus()
                }
            } catch {
                DispatchQueue.main.async { self.failure = error.localizedDescription }
            }
        }
    }

    func uninstall(deleteData: Bool) {
        log = []
        screen = .working
        DispatchQueue.global().async {
            Setup.uninstall(deleteData: deleteData) { line in DispatchQueue.main.async { self.log.append(line) } }
            DispatchQueue.main.async { self.detect() }
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
                if let port { self.choices.port = port }
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
        DispatchQueue.global(qos: .userInitiated).async {
            let answer = Setup.save(changed)
            let doc = answer.ok ? Setup.settingsDoc() : nil
            DispatchQueue.main.async {
                self.busy = false
                self.saveLines = answer.lines ?? []
                self.saveErrors = answer.errors ?? [:]
                if answer.ok {
                    if let doc { self.take(doc) }
                    self.edits = [:]
                    // A restarted board takes a few seconds to answer again.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.refreshStatus() }
                }
            }
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

    func open(_ path: String) {
        if let url = URL(string: "http://localhost:\(choices.port)\(path)") { NSWorkspace.shared.open(url) }
    }
}
