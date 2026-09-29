import AppKit
import SwiftUI

/// Starts the window, or with arguments works from the command line:
///
///   VitalAIze --detect                print what setup would fill in (JSON)
///   VitalAIze --install FILE.json     install from saved choices
///   VitalAIze --uninstall             remove it again (keeps the data)
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
    enum Screen { case detecting, wizard, working, status }

    @Published var screen: Screen = .detecting
    @Published var choices = Choices()
    @Published var step = 0
    @Published var log: [String] = []
    @Published var failure: String?
    @Published var running = false
    @Published var workflows: [String] = []
    @Published var awsProfiles: [String] = []
    @Published var tools: [(String, Bool)] = []

    let finder = HubFinderHolder.shared

    init() {
        if Setup.installed() != nil {
            choices = Setup.installed()!.choices
            screen = .status
            refreshStatus()
        } else {
            detect()
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
                try Setup.install(c) { line in DispatchQueue.main.async { self.log.append(line) } }
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

    func refreshStatus() {
        let c = choices
        guard c.role.runsBoard else { running = false; return }
        DispatchQueue.global().async {
            let up = Setup.boardRunning(port: c.port)
            DispatchQueue.main.async { self.running = up }
        }
    }

    func open(_ path: String) {
        if let url = URL(string: "http://localhost:\(choices.port)\(path)") { NSWorkspace.shared.open(url) }
    }
}
