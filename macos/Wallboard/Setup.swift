import Foundation

/// What this Mac does.
enum Role: String, Codable, CaseIterable, Identifiable {
    case hubAndCollector, hub, collector
    var id: String { rawValue }

    var title: String {
        switch self {
        case .hubAndCollector: return "Hub and collector"
        case .hub: return "Hub only"
        case .collector: return "Collector only"
        }
    }

    var detail: String {
        switch self {
        case .hubAndCollector:
            return "Runs the board and its database here, and saves this Mac's Claude sessions. Pick this for your main Mac."
        case .hub:
            return "Runs the board and its database, and keeps only what other Macs send."
        case .collector:
            return "Watches this Mac's Claude and Codex sessions and streams them to a hub on your network. No board runs here."
        }
    }

    var runsBoard: Bool { self != .collector }
}

/// Everything the wizard asks, with what could be found filled in.
struct Choices: Codable {
    var role: Role = .hubAndCollector
    var dataFolder: String = Setup.defaultDataFolder
    var claudeFolders: [String] = []
    var boardName: String = "Kyroco"
    var port: Int = 4747
    var repo: String = ""
    /// The other repositories the board follows, after `repo`. Optional so
    /// choices saved before several repositories still load.
    var otherRepos: [String]? = nil
    /// The repositories an earlier settings file listed. While the list stays
    /// the same, that file's own entries (and any settings of their own) stay.
    var importedRepos: [String]? = nil
    var branch: String = "main"
    var gateWorkflow: String = ""
    var devWorkflow: String = ""
    var prodWorkflow: String = ""
    var korium: Bool = false
    // Optional so choices saved before Codex support still load.
    var codex: Bool? = nil
    var newRelic: Bool = false
    var newRelicAccount: String = ""
    var newRelicKeyRef: String = ""
    var devProfile: String = ""
    var prodProfile: String = ""
    var phone: String = ""
    var textVia: String = "iMessage"
    var hubURL: String = ""
    var importedSettings: String? = nil
    /// The Gate, dev and prod workflows the earlier file had. While these
    /// stay the same, its own timeline rows and deploy list are kept.
    var importedWorkflows: [String]? = nil
    var replaceOldBoard: Bool = true
}

/// What was installed, kept in the data folder so the app can show it,
/// change it and take it away again.
struct Installed: Codable {
    var choices: Choices
    /// The Claude folders, and the Codex folder, an earlier version added
    /// upload hooks to. The board's own code reads them from this record
    /// to take those hooks out (Wallboard.Setup.OldHooks).
    var hookedFolders: [String]
    // Optional so records saved before Codex uploads still load.
    var hookedCodex: String? = nil
    var installedAt: Date
}

/// One setting, as the board's own code describes it (`vitalaize setup
/// --json show`). The app draws its Settings screen from these, so the app
/// and the terminal command always offer the same settings.
struct SettingsField: Codable, Identifiable {
    var key: String
    var label: String
    /// string, integer, port, boolean, secret, choice, lines, repos or folders.
    var type: String
    var options: [String]
    /// True when a change restarts the board or the collector.
    var restart: Bool
    var help: String?
    var value: String
    var id: String { key }
}

struct SettingsSection: Codable, Identifiable {
    var title: String
    var fields: [SettingsField]
    var id: String { title }
}

struct Paired: Codable {
    var host: String
    var port: Int
    var machine: String
}

struct SettingsDoc: Codable {
    var role: String
    /// The file the settings are saved in.
    var path: String
    /// running, stopped, or none when no login item is set up.
    var service: String
    var paired: Paired?
    var sections: [SettingsSection]
}

struct SaveAnswer: Codable {
    var ok: Bool
    /// What the save did, to show the person.
    var lines: [String]?
    /// What is wrong, by setting key.
    var errors: [String: String]?
    var service: String?
}

struct PairCode: Codable {
    var code: String
    var hub: String
    var machine: String
    var expires_in: Int
}

struct PairAnswer: Codable {
    var ok: Bool
    var message: String
    var machine: String?
}

enum Setup {
    static let label = ProcessInfo.processInfo.environment["WALLBOARD_LABEL"] ?? "ai.kyroco.wallboard"
    static let fm = FileManager.default
    static let home = fm.homeDirectoryForCurrentUser

    static var defaultDataFolder: String {
        home.appendingPathComponent("Library/Application Support/VitalAIze").path
    }

    static var agentPlist: URL { home.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    static var logFile: URL { home.appendingPathComponent("Library/Logs/VitalAIze/board.log") }

    /// The board itself, inside this app. VITALAIZE_RELEASE names another
    /// copy, for running the app's command line from a build folder.
    static var release: URL {
        if let path = ProcessInfo.processInfo.environment["VITALAIZE_RELEASE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return Bundle.main.resourceURL!.appendingPathComponent("board")
    }

    /// Where the data folder is, remembered between launches.
    /// VITALAIZE_DATA names one for this run only, for scripts and tests.
    static var dataFolder: String? {
        get {
            if let path = ProcessInfo.processInfo.environment["VITALAIZE_DATA"], !path.isEmpty { return path }
            return UserDefaults.standard.string(forKey: "dataFolder")
        }
        set { UserDefaults.standard.set(newValue, forKey: "dataFolder") }
    }

    static func installed() -> Installed? {
        guard let folder = dataFolder,
              let data = try? Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent("install.json")) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Installed.self, from: data)
    }

    // MARK: Pre-filling

    /// Fills in everything that can be found on this Mac. Slow parts (git
    /// and GitHub) run here, off the main thread.
    static func detect() -> Choices {
        var c = installed()?.choices ?? Choices()
        if installed() != nil { return c }

        c.claudeFolders = Detect.claudeFolders()
        c.korium = Detect.usesKorium(folders: c.claudeFolders)
        c.codex = Detect.usesCodex()
        let profiles = Detect.awsProfiles()
        c.devProfile = Detect.guessDevProfile(profiles)
        c.prodProfile = Detect.guessProdProfile(profiles)
        c.importedSettings = Detect.existingSettingsFile()

        // A board set up before: its values are the starting answers, so
        // carrying it over never blanks what it had.
        if let path = c.importedSettings, let old = Detect.importSettings(path) {
            func str(_ key: String) -> String? {
                switch old[key] {
                case let s as String where !s.isEmpty: return s
                case let n as NSNumber where !(old[key] is Bool): return n.stringValue
                default: return nil
                }
            }
            if let v = str("brand") { c.boardName = v }
            if let v = old["port"] as? Int { c.port = v }
            if let v = str("phone") { c.phone = v }
            if let v = str("via") { c.textVia = v }
            if let v = str("dev_profile") { c.devProfile = v }
            if let v = str("prod_profile") { c.prodProfile = v }
            if let v = old["new_relic"] as? Bool { c.newRelic = v }
            if let v = str("nr_account") { c.newRelicAccount = v }
            if let v = str("nr_key") { c.newRelicKeyRef = v }
            if let v = old["korium"] as? Bool { c.korium = v }
            if let v = old["codex"] as? Bool { c.codex = v }
            if let dirs = old["dirs"] as? [String], !dirs.isEmpty { c.claudeFolders = dirs }
            // A file lists several repositories in `repos`, or names one in `repo`.
            let listed = (old["repos"] as? [String] ?? []).filter { !$0.isEmpty }
            if let repo = listed.first ?? str("repo") {
                c.repo = repo
                c.otherRepos = Array(listed.dropFirst())
                c.importedRepos = listed.isEmpty ? [repo] : listed
                c.branch = str("branch") ?? c.branch
                c.gateWorkflow = str("gate") ?? ""
                c.devWorkflow = str("dev") ?? ""
                c.prodWorkflow = str("prod") ?? ""
                c.importedWorkflows = [c.gateWorkflow, c.devWorkflow, c.prodWorkflow]
                return c
            }
        }

        // The repositories the sessions work in: the busiest first, and its
        // workflows fill in the questions; the rest follow it. Six at most,
        // since each costs about 600 GitHub calls an hour of the 5,000 allowed.
        let found = Detect.githubRepos(folders: c.claudeFolders)
        if let repo = found.first {
            c.repo = repo
            c.otherRepos = Array(found.dropFirst().prefix(5))
            c.branch = Detect.defaultBranch(repo: repo) ?? "main"
            let guess = Detect.guessWorkflows(Detect.workflows(repo: repo))
            c.gateWorkflow = guess.gate
            c.devWorkflow = guess.dev
            c.prodWorkflow = guess.prod
        }
        return c
    }

    // MARK: The settings file

    /// An Elixir string literal. `#` is escaped so nothing interpolates.
    static func ex(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    static func exOrNil(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "nil" : ex(t)
    }

    /// settings.exs for the board. With an imported file, that file is the
    /// base and these answers are laid over it, so anything the wizard does
    /// not ask about (New Relic checks, the theme) carries over.
    static func settingsFile(_ c: Choices) -> String {
        if c.role == .collector { return collectorSettingsFile(c) }
        let data = c.dataFolder
        let lanes = [("Gate", c.gateWorkflow), ("Dev deploy", c.devWorkflow), ("Prod", c.prodWorkflow)]
            .filter { !$0.1.isEmpty }
            .map { "%{label: \(ex($0.0)), workflows: [\(ex($0.1))]}" }
            .joined(separator: ", ")
        let deploys = [c.devWorkflow, c.prodWorkflow].filter { !$0.isEmpty }.map(ex).joined(separator: ", ")

        var github = ["repo: \(ex(c.repo))", "branch: \(ex(c.branch))"]
        if !c.gateWorkflow.isEmpty { github.append("gate_workflow: \(ex(c.gateWorkflow))") }
        if !c.devWorkflow.isEmpty { github.append("dev_deploy: \(ex(c.devWorkflow))") }
        if !c.prodWorkflow.isEmpty { github.append("prod_deploy: \(ex(c.prodWorkflow))") }
        let keepOldRows = c.importedSettings != nil &&
            c.importedWorkflows == [c.gateWorkflow, c.devWorkflow, c.prodWorkflow]
        if !keepOldRows {
            github.append("deploy_workflows: [\(deploys)]")
            github.append("lanes: [\(lanes)]")
        }
        // Every repository goes in `repos`, even one: the board keeps the
        // settings an imported file gave a repository only while its name is
        // still in the list. An imported file's own list is kept while it
        // stays the same.
        let repos = [c.repo] + (c.otherRepos ?? []).filter { !$0.isEmpty && $0 != c.repo }
        if !(c.importedSettings != nil && c.importedRepos == repos) {
            github.append("repos: [\(repos.map(ex).joined(separator: ", "))]")
        }

        let answers = """
        %{
            role: \(ex(c.role == .hub ? "hub" : "both")),
            port: \(c.port),
            brand: %{name: \(ex(c.boardName))},
            claude: %{config_dirs: [\(c.claudeFolders.map(ex).joined(separator: ", "))]},
            github: %{\(github.joined(separator: ", "))},
            korium: %{enabled: \(c.korium)},
            codex: %{enabled: \(c.codex ?? false)},
            new_relic: %{enabled: \(c.newRelic), account_id: \(exOrNil(c.newRelicAccount)), api_key_ref: \(exOrNil(c.newRelicKeyRef))},
            dev_power: %{aws_profile: \(exOrNil(c.devProfile))},
            builds: %{prod_profile: \(exOrNil(c.prodProfile))},
            alerts: %{phone: \(exOrNil(c.phone)), via: \(ex(c.textVia))},
            archive: %{
              path: \(ex(data + "/wallboard.db")),
              collect_local: \(c.role == .hubAndCollector)
            }
          }
        """

        let header = settingsHeader

        if c.importedSettings != nil {
            return header + """
            # Your earlier settings file is the base; the answers below win.
            # A repository the base gives settings of its own keeps them.
            {base, _} = Code.eval_file(Path.join(__DIR__, "settings.imported.exs"))

            Wallboard.Settings.apply_overrides(
              base,
              \(answers)
            )

            """
        }
        return header + answers + "\n"
    }

    /// What every settings.exs the app writes starts with.
    static let settingsHeader = """
        # Written by the VitalAIze app when it set this Mac up. Change settings
        # in the app (Settings) or with `vitalaize setup` in a terminal: both
        # save to settings.json beside this file, and what is saved there wins
        # over this file. Reconfigure in the app writes this file again.

        """

    /// settings.exs for a collector: its role, and where it keeps its place
    /// and its certificate. It finds the Claude and Codex folders itself;
    /// they are listed only when the wizard's choice differs from that.
    static func collectorSettingsFile(_ c: Choices) -> String {
        var collector = ["dir: \(ex(c.dataFolder + "/collector"))"]
        if !c.claudeFolders.isEmpty && Set(c.claudeFolders) != Set(Detect.claudeFolders()) {
            collector.append("claude_dirs: [\(c.claudeFolders.map(ex).joined(separator: ", "))]")
        }
        // `role:` starts its own line: the board's start script reads it there
        // to run a collector small.
        return settingsHeader + """
        %{
          role: "collector",
          collector: %{\(collector.joined(separator: ", "))}
        }

        """
    }

    /// The settings the wizard asks about, by key. Before the wizard writes
    /// settings.exs again, these are taken out of the saved settings
    /// (settings.json): a value saved earlier, in the app or with `vitalaize
    /// setup`, would otherwise win over the wizard's new answer. What the
    /// wizard does not ask about stays saved.
    ///
    /// The three workflows and the two New Relic values are named only when
    /// the wizard has an answer for them. Left empty they are no answer:
    /// `settingsFile` then leaves the workflow out and writes nil for the
    /// account and the key address, so one saved in the app would be taken
    /// out with nothing to replace it. Kept, the saved one goes on winning
    /// over that nil; it is cleared in the app's Settings. Empty is tested
    /// here the way `settingsFile` tests it.
    static func wizardKeys(_ c: Choices) -> [String] {
        if c.role == .collector { return ["role", "collector.claude_dirs"] }
        let answered = [("github.gate_workflow", c.gateWorkflow),
                        ("github.dev_deploy", c.devWorkflow),
                        ("github.prod_deploy", c.prodWorkflow),
                        ("new_relic.account_id", c.newRelicAccount.trimmingCharacters(in: .whitespaces)),
                        ("new_relic.api_key_ref", c.newRelicKeyRef.trimmingCharacters(in: .whitespaces))]
            .filter { !$0.1.isEmpty }
            .map { $0.0 }
        return ["role", "port", "brand.name", "claude.config_dirs", "github.repos", "github.branch",
                "korium.enabled", "codex.enabled", "new_relic.enabled",
                "dev_power.aws_profile", "builds.prod_profile",
                "alerts.phone", "alerts.via", "archive.collect_local"] + answered
    }

    /// Takes the wizard's settings out of the saved ones. No value is
    /// checked, so no answer can stop it; when the board's program cannot
    /// be run at all, the install stops before anything is written.
    static func forgetWizardKeys(_ c: Choices) throws {
        guard let body = try? JSONSerialization.data(withJSONObject: ["keys": wizardKeys(c)]),
              let data = engine(["forget"], input: String(decoding: body, as: UTF8.self), dataFolder: c.dataFolder),
              let answer = try? JSONDecoder().decode(SaveAnswer.self, from: data), answer.ok else {
            throw Failure.step("The saved settings could not be read. The log is at \(logFile.path).")
        }
    }

    // MARK: Installing

    enum Failure: Error, LocalizedError {
        case step(String)
        var errorDescription: String? { if case .step(let s) = self { return s }; return nil }
    }

    /// Installs everything the choices ask for. `say` reports each step.
    static func install(_ c: Choices, onCode: @escaping (PairCode?) -> Void = { _ in }, say: @escaping (String) -> Void) throws {
        // Kept from an earlier setup, so the hooks it added are still found
        // when this run could not take them out. The earlier record stays
        // where Uninstall looks until this run has written its own: the
        // remembered data folder moves only at the end.
        let earlier = installed()
        let hookedCodex: String? = earlier?.hookedCodex
        let hooked: [String] = earlier?.hookedFolders ?? []
        let data = URL(fileURLWithPath: c.dataFolder)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        // Where the board's code looks for the folders an earlier setup
        // hooked. A reinstall into another data folder carries it along.
        if let earlier, let folder = dataFolder, folder != c.dataFolder {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            try? enc.encode(earlier).write(to: data.appendingPathComponent("install.json"))
        }

        if c.role.runsBoard {
            if let imported = c.importedSettings {
                say("Copying your earlier settings from \(imported)")
                let copy = data.appendingPathComponent("settings.imported.exs")
                try? fm.removeItem(at: copy)
                try fm.copyItem(at: URL(fileURLWithPath: imported), to: copy)
            }
            say("Writing the board's settings")
            // Before the file is written: if this cannot be done, nothing
            // has changed yet.
            try forgetWizardKeys(c)
            try settingsFile(c).write(to: data.appendingPathComponent("settings.exs"), atomically: true, encoding: .utf8)
            retireOldHooks(dataFolder: c.dataFolder, say: say)

            if c.replaceOldBoard && Detect.oldLoginItemInstalled {
                say("Stopping the board you started by hand before")
                let uid = getuid()
                Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/local.wallboard"])
                try? fm.removeItem(at: home.appendingPathComponent("Library/LaunchAgents/local.wallboard.plist"))
            }

            say("Starting the board, and setting it to start when you log in")
            try startBoard(c)

            say("Waiting for the board to answer")
            guard waitForBoard(port: c.port, seconds: 90) else {
                throw Failure.step("The board did not start. Its log is at \(logFile.path).")
            }
            say("The board is up at http://localhost:\(c.port)")
        }

        if c.role == .collector {
            say("Writing the collector's settings")
            try forgetWizardKeys(c)
            try settingsFile(c).write(to: data.appendingPathComponent("settings.exs"), atomically: true, encoding: .utf8)
            // Before the collector starts, so it never runs beside the hooks
            // an earlier version sent sessions with.
            retireOldHooks(dataFolder: c.dataFolder, say: say)

            say("Starting the collector, and setting it to start when you log in")
            try startBoard(c)
            guard waitForService(seconds: 30) else {
                throw Failure.step("The collector did not start. Its log is at \(logFile.path).")
            }
            say("The collector is running")

            if c.hubURL.isEmpty && paired(dataFolder: c.dataFolder) != nil {
                say("This Mac is already paired with its hub")
            } else {
                say("Asking the hub to pair")
                let answer = pair(hub: c.hubURL, dataFolder: c.dataFolder) { code in
                    say("Approve this code in the mailbox on \(code.hub.isEmpty ? "the hub" : code.hub)'s board: \(code.code)")
                    onCode(code)
                }
                onCode(nil)
                // The collector is set up either way; pairing can be done
                // again from the app's first screen.
                say(answer.ok ? answer.message : "Not paired yet. \(answer.message) Pair from this app when the hub is ready.")
            }
        }

        let record = Installed(choices: c, hookedFolders: hooked, hookedCodex: hookedCodex, installedAt: Date())
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .prettyPrinted
        try enc.encode(record).write(to: data.appendingPathComponent("install.json"))
        dataFolder = c.dataFolder
        say("Done")
    }

    /// The login item that runs the board from inside this app.
    static func startBoard(_ c: Choices) throws {
        let data = c.dataFolder
        try fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(atPath: data + "/tmp", withIntermediateDirectories: true)
        try fm.createDirectory(at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [release.appendingPathComponent("bin/wallboard").path, "start"],
            "EnvironmentVariables": [
                "WALLBOARD_SETTINGS": data + "/settings.exs",
                "RELEASE_TMP": data + "/tmp",
                "RELEASE_DISTRIBUTION": "none",
                "PATH": Shell.pathValue,
                "HOME": home.path
            ],
            "WorkingDirectory": data,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 30,
            "StandardOutPath": logFile.path,
            "StandardErrorPath": logFile.path
        ]
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try xml.write(to: agentPlist)

        let domain = "gui/\(getuid())"
        Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let r = Shell.run("/bin/launchctl", ["bootstrap", domain, agentPlist.path])
        if !r.ok { throw Failure.step("Could not start the board: \(r.output)") }
    }

    /// Asks the board or the collector to stop; the login item starts it
    /// again. A plain stop, not a kill, so a hub gets to tell its collectors
    /// it will be back soon before it goes.
    static func restartBoard() {
        let target = "gui/\(getuid())/\(label)"
        Shell.run("/bin/launchctl", ["kill", "SIGTERM", target])
        // In case it was not running at all.
        Shell.run("/bin/launchctl", ["kickstart", target])
    }

    /// Whether the login item is running, as launchd sees it.
    static func serviceRunning() -> Bool {
        let r = Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"], timeout: 5)
        return r.ok && r.output.contains("state = running")
    }

    static func waitForService(seconds: Int) -> Bool {
        for _ in 0..<seconds {
            if serviceRunning() { return true }
            sleep(1)
        }
        return false
    }

    // MARK: Settings and pairing, through the board's own code

    /// What the board's `vitalaize setup --json` needs to find this Mac's
    /// settings: the same file and login item the app set up.
    static func engineEnv(dataFolder folder: String? = nil) -> [String: String] {
        let data = folder ?? dataFolder ?? defaultDataFolder
        try? fm.createDirectory(atPath: data + "/tmp", withIntermediateDirectories: true)
        return ["WALLBOARD_SETTINGS": data + "/settings.exs",
                "RELEASE_TMP": data + "/tmp",
                "RELEASE_DISTRIBUTION": "none",
                "WALLBOARD_LABEL": label,
                "HOME": home.path]
    }

    /// Runs one `vitalaize setup --json` command and gives back its answer:
    /// the line that starts with VITALAIZE_JSON. `onLine` sees every line as
    /// it is printed, for the pairing code that comes before the answer.
    static func engine(_ args: [String], input: String? = nil, dataFolder folder: String? = nil,
                       timeout: TimeInterval = 60, onLine: ((String) -> Void)? = nil) -> Data? {
        let bin = release.appendingPathComponent("bin/wallboard").path
        guard fm.isExecutableFile(atPath: bin) else { return nil }
        var env = engineEnv(dataFolder: folder)
        env["VITALAIZE_ARGS"] = (["--json"] + args).joined(separator: " ")
        var answer: Data?
        Shell.stream(bin, ["eval", "Wallboard.Setup.main()"], env: env, input: input, timeout: timeout) { line in
            if line.hasPrefix("VITALAIZE_JSON") { answer = line.dropFirst(14).data(using: .utf8) }
            onLine?(line)
        }
        return answer
    }

    /// The settings this Mac's role uses, with their values, and whether it
    /// is paired and running.
    static func settingsDoc(dataFolder folder: String? = nil) -> SettingsDoc? {
        guard let data = engine(["show"], dataFolder: folder) else { return nil }
        return try? JSONDecoder().decode(SettingsDoc.self, from: data)
    }

    /// Saves the given values (text by key). The board's code checks them,
    /// writes settings.json and restarts the login item only when a change
    /// needs it.
    static func save(_ values: [String: String], dataFolder folder: String? = nil) -> SaveAnswer {
        let failed = SaveAnswer(ok: false, lines: ["The settings could not be saved. The log is at \(logFile.path)."], errors: nil, service: nil)
        guard let body = try? JSONSerialization.data(withJSONObject: ["values": values]),
              let data = engine(["save"], input: String(decoding: body, as: UTF8.self), dataFolder: folder),
              let answer = try? JSONDecoder().decode(SaveAnswer.self, from: data) else { return failed }
        return answer
    }

    /// The hub this Mac is paired with, or nil.
    static func paired(dataFolder folder: String? = nil) -> Paired? {
        settingsDoc(dataFolder: folder)?.paired
    }

    /// Pairs this Mac with a hub by code. `hub` is its address, or empty to
    /// look for one on the network. `onCode` gets the code to show as soon
    /// as there is one; the call returns when the owner has approved or
    /// refused it on the hub, or the code ran out (ten minutes).
    static func pair(hub: String, dataFolder folder: String? = nil, onCode: @escaping (PairCode) -> Void) -> PairAnswer {
        // The address goes in as one word; an address has no spaces, tabs or
        // line ends.
        let address = hub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return PairAnswer(ok: false, message: "That is not a board's address.", machine: nil) }
        let data = engine(["pair"] + (address.isEmpty ? [] : [address]), dataFolder: folder, timeout: 660) { line in
            if line.hasPrefix("VITALAIZE_CODE"), let json = line.dropFirst(14).data(using: .utf8),
               let code = try? JSONDecoder().decode(PairCode.self, from: json) {
                onCode(code)
            }
        }
        guard let data, let answer = try? JSONDecoder().decode(PairAnswer.self, from: data) else {
            return PairAnswer(ok: false, message: "Pairing stopped before the hub answered.", machine: nil)
        }
        return answer
    }

    static func boardRunning(port: Int) -> Bool {
        let r = Shell.run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "2", "http://localhost:\(port)/"], timeout: 5)
        return r.output == "200"
    }

    static func waitForBoard(port: Int, seconds: Int) -> Bool {
        for _ in 0..<seconds {
            if boardRunning(port: port) { return true }
            sleep(1)
        }
        return false
    }

    // MARK: Hooks from before the streaming collector

    // The app no longer adds upload hooks: a collector is a login item now,
    // and the hub takes no uploads. What an earlier version added is taken
    // out by the board's own code (Wallboard.Setup.OldHooks), the same code
    // `vitalaize setup` runs: only VitalAIze's upload hooks go, every other
    // hook stays as it was, and each file changed is copied first.

    /// Takes the upload hooks an earlier version added out of this Mac's
    /// Claude and Codex settings, and says what it did.
    static func retireOldHooks(dataFolder folder: String? = nil, say: (String) -> Void) {
        guard let data = engine(["retire"], dataFolder: folder),
              let answer = try? JSONDecoder().decode(SaveAnswer.self, from: data), answer.ok else {
            say("Could not look for upload hooks from an earlier version. The log is at \(logFile.path).")
            return
        }
        answer.lines?.forEach(say)
    }

    // MARK: Uninstalling

    static func uninstall(deleteData: Bool, say: (String) -> Void) {
        say("Stopping VitalAIze")
        Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? fm.removeItem(at: agentPlist)
        // The old upload hooks and this Mac's certificate for its hub, by
        // the board's own code, while the data folder is still there.
        if let data = engine(["remove"]),
           let answer = try? JSONDecoder().decode(SaveAnswer.self, from: data), answer.ok {
            answer.lines?.forEach(say)
        } else {
            say("Could not take out this Mac's certificate or look for old upload hooks. The log is at \(logFile.path).")
        }
        if deleteData, let folder = dataFolder {
            say("Deleting \(folder)")
            try? fm.removeItem(atPath: folder)
        } else if let folder = dataFolder {
            try? fm.removeItem(atPath: folder + "/install.json")
        }
        dataFolder = nil
        say("Removed")
    }
}
