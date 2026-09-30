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
            return "Sends this Mac's Claude sessions to a hub on your network. No board runs here."
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
    var hubKey: String = ""
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
    var hookedFolders: [String]
    var installedAt: Date
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

    /// The board itself, inside this app.
    static var release: URL { Bundle.main.resourceURL!.appendingPathComponent("board") }

    /// Where the data folder is, remembered between launches.
    static var dataFolder: String? {
        get { UserDefaults.standard.string(forKey: "dataFolder") }
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
        // Several repositories go in `repos`; with one, `repos` is empty and
        // the board follows `repo`. An imported file's own list is kept while
        // it stays the same, since its entries may carry settings of their own.
        let repos = [c.repo] + (c.otherRepos ?? []).filter { !$0.isEmpty && $0 != c.repo }
        if !(c.importedSettings != nil && c.importedRepos == repos) {
            github.append("repos: [\(repos.count > 1 ? repos.map(ex).joined(separator: ", ") : "")]")
        }

        let answers = """
        %{
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

        let header = """
        # Written by the VitalAIze app. Change the board from its settings page
        # (Settings, at the top beside the clock), or run the app
        # again and pick Reconfigure. Edits here are kept until the next
        # Reconfigure.

        """

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

    // MARK: Installing

    enum Failure: Error, LocalizedError {
        case step(String)
        var errorDescription: String? { if case .step(let s) = self { return s }; return nil }
    }

    /// Installs everything the choices ask for. `say` reports each step.
    static func install(_ c: Choices, say: (String) -> Void) throws {
        let data = URL(fileURLWithPath: c.dataFolder)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        dataFolder = c.dataFolder
        var hooked: [String] = []

        if c.role.runsBoard {
            if let imported = c.importedSettings {
                say("Copying your earlier settings from \(imported)")
                let copy = data.appendingPathComponent("settings.imported.exs")
                try? fm.removeItem(at: copy)
                try fm.copyItem(at: URL(fileURLWithPath: imported), to: copy)
            }
            say("Writing the board's settings")
            try settingsFile(c).write(to: data.appendingPathComponent("settings.exs"), atomically: true, encoding: .utf8)

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
            say("Checking the hub and its key")
            let script = try fetchUploadScript(hub: c.hubURL, key: c.hubKey)
            for folder in c.claudeFolders {
                say("Connecting \(folder) to the hub")
                try hookUp(folder: folder, script: script)
                hooked.append(folder)
            }
        }

        let record = Installed(choices: c, hookedFolders: hooked, installedAt: Date())
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .prettyPrinted
        var saved = record
        saved.choices.hubKey = ""   // the key lives in the upload script, not here
        try enc.encode(saved).write(to: data.appendingPathComponent("install.json"))
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

    static func restartBoard() {
        Shell.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"])
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

    // MARK: Collector

    /// The hub's upload script. A wrong address or key fails here, before
    /// anything on this Mac changes.
    static func fetchUploadScript(hub: String, key: String) throws -> String {
        let base = hub.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let r = Shell.run("/usr/bin/curl", ["-sS", "-w", "\n%{http_code}", "--max-time", "15",
                                           "-H", "Authorization: Bearer \(key)", "\(base)/ingest/upload.sh"], timeout: 20)
        let lines = r.output.components(separatedBy: "\n")
        let code = lines.last ?? ""
        let body = lines.dropLast().joined(separator: "\n")
        switch code {
        case "200": return body + "\n"
        case "401": throw Failure.step("The hub turned down that key. Copy it again from the hub's settings page.")
        case "404": throw Failure.step("That board has its archive turned off, so it cannot take sessions.")
        default: throw Failure.step("Could not reach a hub at \(base). Is the board running there?")
        }
    }

    /// Saves the upload script in a Claude folder and adds the two hooks to
    /// that folder's settings.json, after backing it up.
    static func hookUp(folder: String, script: String) throws {
        let dir = URL(fileURLWithPath: folder)
        let scriptURL = dir.appendingPathComponent("wallboard-upload.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)

        let settingsURL = dir.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL), !data.isEmpty {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.step("\(settingsURL.path) is not a settings object, so it was left alone.")
            }
            settings = obj
            let backup = dir.appendingPathComponent("settings.json.before-wallboard")
            if !fm.fileExists(atPath: backup.path) { try data.write(to: backup) }
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let hook: [String: Any] = ["type": "command", "command": scriptURL.path, "async": true, "timeout": 120]
        for event in ["Stop", "SessionEnd"] {
            var list = hooks[event] as? [[String: Any]] ?? []
            let has = list.contains { m in ((m["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String) == scriptURL.path } }
            if !has { list.append(["hooks": [hook]]) }
            hooks[event] = list
        }
        settings["hooks"] = hooks
        let out = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try out.write(to: settingsURL, options: .atomic)
    }

    /// Takes the hooks back out; everything else in settings.json stays.
    static func unhook(folder: String) {
        let dir = URL(fileURLWithPath: folder)
        let scriptURL = dir.appendingPathComponent("wallboard-upload.sh")
        let settingsURL = dir.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           var settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           var hooks = settings["hooks"] as? [String: Any] {
            for event in ["Stop", "SessionEnd"] {
                let list = (hooks[event] as? [[String: Any]] ?? []).filter { m in
                    !((m["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String) == scriptURL.path }
                }
                hooks[event] = list.isEmpty ? nil : list
            }
            settings["hooks"] = hooks.isEmpty ? nil : hooks
            if let out = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                try? out.write(to: settingsURL, options: .atomic)
            }
        }
        try? fm.removeItem(at: scriptURL)
    }

    // MARK: Uninstalling

    static func uninstall(deleteData: Bool, say: (String) -> Void) {
        let record = installed()
        say("Stopping the board")
        Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try? fm.removeItem(at: agentPlist)
        for folder in record?.hookedFolders ?? [] {
            say("Disconnecting \(folder)")
            unhook(folder: folder)
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
