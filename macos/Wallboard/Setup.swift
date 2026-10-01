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
    /// The folder whose settings in use filled in the setup, when one did.
    var settingsReadFrom: String? = nil
    /// True when the wizard started from the settings as they are now: a
    /// first setup, or a Reconfigure that read what is saved. An answer
    /// left empty is then the person's choice, not a question nobody
    /// asked. Optional so choices saved before this still load.
    var settingsRead: Bool? = nil
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

/// How a collector's link to its hub stands, as the collector last wrote
/// it: up, down, back_soon or removed, and when (seconds since 1970).
struct LinkState: Codable {
    var state: String
    var at: Int
}

struct SettingsDoc: Codable {
    var role: String
    /// The file the settings are saved in.
    var path: String
    /// running, stopped, or none when no login item is set up.
    var service: String
    var paired: Paired?
    /// Nil when the collector has not said: not paired, or not run since.
    var link: LinkState?
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

        c.settingsRead = true
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

        // "None" is written as nil only when it is the person's choice (see
        // `settingsRead`); else a workflow left empty is left out, and the
        // base file's or the board's own stays.
        let all = c.settingsRead == true
        var github = ["repo: \(ex(c.repo))", "branch: \(ex(c.branch))"]
        if all || !c.gateWorkflow.isEmpty { github.append("gate_workflow: \(exOrNil(c.gateWorkflow))") }
        if all || !c.devWorkflow.isEmpty { github.append("dev_deploy: \(exOrNil(c.devWorkflow))") }
        if all || !c.prodWorkflow.isEmpty { github.append("prod_deploy: \(exOrNil(c.prodWorkflow))") }
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
    ///
    /// When the wizard started from the settings as they are now
    /// (`settingsRead`), every one of them is named: what the person sees
    /// in the wizard is what is saved, so an empty answer is theirs.
    static func wizardKeys(_ c: Choices) -> [String] {
        if c.role == .collector { return ["role", "collector.claude_dirs"] }
        let all = c.settingsRead == true
        let answered = [("github.gate_workflow", c.gateWorkflow),
                        ("github.dev_deploy", c.devWorkflow),
                        ("github.prod_deploy", c.prodWorkflow),
                        ("new_relic.account_id", c.newRelicAccount.trimmingCharacters(in: .whitespaces)),
                        ("new_relic.api_key_ref", c.newRelicKeyRef.trimmingCharacters(in: .whitespaces))]
            .filter { all || !$0.1.isEmpty }
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
            throw Failure.step("The saved settings (settings.json in \(c.dataFolder)) could not be changed. Check that the folder can be written to. The settings were left as they were.")
        }
    }

    // MARK: Installing

    enum Failure: Error, LocalizedError {
        case step(String)
        var errorDescription: String? { if case .step(let s) = self { return s }; return nil }
    }

    /// Installs everything the choices ask for. `say` reports each step.
    /// Gives back how pairing went when it asked a hub to pair: a collector
    /// is set up whether or not the hub said yes, so the caller has that to
    /// tell the person.
    @discardableResult
    static func install(_ c: Choices, onCode: @escaping (PairCode?) -> Void = { _ in }, say: @escaping (String) -> Void) throws -> PairAnswer? {
        // A setup that stops after the settings were written says so: what
        // it says about the file it stopped on is not the whole of it.
        var saved = false
        do {
            return try steps(c, saved: &saved, onCode: onCode, say: say)
        } catch Failure.step(let message) where saved {
            throw Failure.step(message + " The settings from this setup were already saved, and the copies from before are in the backups folder.")
        }
    }

    private static func steps(_ c: Choices, saved: inout Bool, onCode: @escaping (PairCode?) -> Void, say: @escaping (String) -> Void) throws -> PairAnswer? {
        if let fault = awayFault() { throw Failure.step(fault + " Nothing was changed.") }
        // Kept from an earlier setup, so the hooks it added are still found
        // when this run could not take them out. The earlier record stays
        // where Uninstall looks until this run has written its own: the
        // remembered data folder moves only at the end.
        let earlier = installed()
        let hookedCodex: String? = earlier?.hookedCodex
        let hooked: [String] = earlier?.hookedFolders ?? []
        var c = c
        c.hubURL = c.hubURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = URL(fileURLWithPath: c.dataFolder)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        let backups = backupFolder(data)
        // Where the board's code looks for the folders an earlier setup
        // hooked. A reinstall into another data folder carries it along.
        if let earlier, let folder = dataFolder, folder != c.dataFolder {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            if let record = try? enc.encode(earlier) {
                try? replace(data.appendingPathComponent("install.json"), with: record, backups: backups)
            }
        }
        var pairing: PairAnswer?

        if c.role.runsBoard {
            // Before anything is written: a board that cannot have its port
            // would only be found out a minute and a half later.
            // A board started by hand that is about to be stopped may be
            // what holds the port, so the port is looked at after that.
            let oldItem = home.appendingPathComponent("Library/LaunchAgents/local.wallboard.plist")
            let stopsOld = c.replaceOldBoard && Detect.oldLoginItemInstalled
            if !stopsOld && portTakenByAnother(c.port) {
                let byHand = Detect.oldLoginItemInstalled
                    ? " The board you started by hand may be what uses it: turn on Stop that board on the second step, or pick another port."
                    : ""
                throw Failure.step("Port \(c.port) is already used by another program on this Mac, so the board cannot answer there. Go back and pick another port on the fourth step; 4748 to 4999 are usually free.\(byHand) Nothing was changed.")
            }
            c = try carryOver(c, backups: backups, say: say)
            say("Writing the board's settings")
            // Before the file is written: if this cannot be done, nothing
            // has changed yet.
            try writeSettings(c, backups: backups)
            saved = true
            agree(c, say: say)
            retireOldHooks(dataFolder: c.dataFolder, say: say)

            if stopsOld {
                say("Stopping the board you started by hand before")
                try keep(oldItem, in: backups)
                let uid = getuid()
                Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/local.wallboard"])
                try? fm.removeItem(at: oldItem)
                say("Its login item is kept in \(backups.path)")
                // It lets go of the port a moment after it is told to stop.
                var taken = portTakenByAnother(c.port)
                for _ in 0..<10 where taken {
                    sleep(1)
                    taken = portTakenByAnother(c.port)
                }
                if taken {
                    throw Failure.step("Port \(c.port) is still used by another program on this Mac after the board you started by hand was stopped, so the board cannot answer there. Go back and pick another port on the fourth step; 4748 to 4999 are usually free. The board you started by hand is stopped; its login item is in \(backups.path).")
                }
            }

            say("Starting the board, and setting it to start when you log in")
            try startBoard(c, backups: backups)

            say("Waiting for the board to answer")
            guard waitForBoard(port: c.port, seconds: 90) else {
                throw Failure.step("The board did not start. Its log is at \(logFile.path).")
            }
            say("The board is up at http://localhost:\(c.port)")
        }

        if c.role == .collector {
            say("Writing the collector's settings")
            try writeSettings(c, backups: backups)
            saved = true
            // Before the collector starts, so it never runs beside the hooks
            // an earlier version sent sessions with.
            retireOldHooks(dataFolder: c.dataFolder, say: say)

            say("Starting the collector, and setting it to start when you log in")
            try startBoard(c, backups: backups)
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
                pairing = answer
            }
        }

        let record = Installed(choices: c, hookedFolders: hooked, hookedCodex: hookedCodex, installedAt: Date())
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .prettyPrinted
        try replace(data.appendingPathComponent("install.json"), with: try enc.encode(record), backups: backups)
        dataFolder = c.dataFolder
        say("Done")
        return pairing
    }

    // MARK: Keeping what was there

    /// Where one run keeps its copies of the files it changes: a folder
    /// named for the time, under `backups` in the data folder.
    static func backupFolder(_ data: URL, now: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return data.appendingPathComponent("backups/\(f.string(from: now))")
    }

    /// Copies a file into this run's backup folder before it is changed.
    /// The first copy of a run stays: it is the file as it was before the
    /// run. A file that is not there needs no copy.
    static func keep(_ url: URL, in backups: URL) throws {
        guard fm.fileExists(atPath: url.path) else { return }
        let copy = backups.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: copy.path) { return }
        do {
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: copy)
        } catch {
            throw Failure.step("Could not keep a copy of \(url.path) before changing it (\(error.localizedDescription)), so it was left as it was.")
        }
    }

    /// Puts `contents` at `url`. A file already there is copied to the
    /// backup folder first, and goes only when the new one is fully written
    /// beside it: a write that fails leaves the old file as it was.
    static func replace(_ url: URL, with contents: Data, backups: URL) throws {
        if let old = try? Data(contentsOf: url), old == contents { return }
        try keep(url, in: backups)
        do {
            try contents.write(to: url, options: .atomic)
        } catch {
            throw Failure.step("Could not write \(url.path) (\(error.localizedDescription)). The file that was there is unchanged.")
        }
    }

    /// Writes settings.exs from the wizard's answers, after taking those
    /// answers' keys out of the saved settings (settings.json) so the new
    /// answers win. The two go together: when settings.exs cannot be
    /// written, the saved settings are put back as they were, so the board
    /// that is running keeps the values it had.
    static func writeSettings(_ c: Choices, backups: URL) throws {
        let data = URL(fileURLWithPath: c.dataFolder)
        let saved = data.appendingPathComponent("settings.json")
        try keep(saved, in: backups)
        try forgetWizardKeys(c)
        do {
            try replace(data.appendingPathComponent("settings.exs"), with: Data(settingsFile(c).utf8), backups: backups)
        } catch {
            let copy = backups.appendingPathComponent(saved.lastPathComponent)
            // Only when forgetting the answers did change the file.
            if let before = fm.contents(atPath: copy.path), fm.contents(atPath: saved.path) != before {
                do { try before.write(to: saved, options: .atomic) } catch {
                    throw Failure.step("Could not write settings.exs, and the saved settings (\(saved.path)) could not be put back as they were. The copy from before is at \(copy.path).")
                }
            }
            throw error
        }
    }

    /// The setup's answers as the settings screen writes them, by key.
    static func wizardValues(_ c: Choices) -> [String: String] {
        func flag(_ on: Bool) -> String { on ? "true" : "false" }
        return [
            "port": String(c.port),
            "brand.name": c.boardName,
            "claude.config_dirs": c.claudeFolders.joined(separator: "\n"),
            "github.repos": ([c.repo] + (c.otherRepos ?? [])).filter { !$0.isEmpty }.joined(separator: "\n"),
            "github.branch": c.branch,
            "github.gate_workflow": c.gateWorkflow,
            "github.dev_deploy": c.devWorkflow,
            "github.prod_deploy": c.prodWorkflow,
            "korium.enabled": flag(c.korium),
            "codex.enabled": flag(c.codex ?? false),
            "new_relic.enabled": flag(c.newRelic),
            "new_relic.account_id": c.newRelicAccount,
            "new_relic.api_key_ref": c.newRelicKeyRef,
            "dev_power.aws_profile": c.devProfile,
            "builds.prod_profile": c.prodProfile,
            "alerts.phone": c.phone,
            "alerts.via": c.textVia,
        ]
    }

    /// Makes the settings in use agree with the setup's answers. A board
    /// from before the app had a settings page that saved in the database,
    /// and what it saved there wins over settings.exs: an answer changed
    /// in the setup would otherwise not take. Any answer that is not what
    /// is in use once settings.exs is written is saved the way the Settings
    /// screen saves, which wins over both.
    static func agree(_ c: Choices, say: (String) -> Void) {
        // Only when the setup started from the settings in use in this
        // folder: then an answer that differs is one the person changed.
        guard c.settingsReadFrom == c.dataFolder, let doc = settingsDoc(dataFolder: c.dataFolder) else { return }
        func plain(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let now = Dictionary(doc.sections.flatMap { $0.fields }.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        let differ = wizardValues(c).filter { key, value in now[key].map { plain($0) != plain(value) } ?? false }
        guard !differ.isEmpty else { return }
        say("Saving the answers that differ from what an earlier board saved")
        _ = save(differ, dataFolder: c.dataFolder)
    }

    /// The copy this app keeps of an earlier settings file, beside settings.exs.
    static func importedCopy(_ dataFolder: String) -> URL {
        URL(fileURLWithPath: dataFolder).appendingPathComponent("settings.imported.exs")
    }

    /// The choices with the earlier settings file they name checked. A
    /// record can name one that has since been moved or deleted: then the
    /// copy this app took of it stands in, and with no copy either nothing
    /// is carried over. `note` says so in words for the person.
    static func checkedImport(_ c: Choices) -> (choices: Choices, note: String?) {
        guard let imported = c.importedSettings, !fm.fileExists(atPath: imported) else { return (c, nil) }
        var c = c
        let copy = importedCopy(c.dataFolder)
        if fm.fileExists(atPath: copy.path) {
            c.importedSettings = copy.path
            return (c, "Your earlier settings file, \(imported), is gone. The copy taken when it was first carried over is used instead.")
        }
        c.importedSettings = nil
        c.importedRepos = nil
        c.importedWorkflows = nil
        return (c, "Your earlier settings file, \(imported), is gone, and so is the copy of it at \(copy.path). Settings beyond the ones this setup asks about were not carried over. If you have a backup of that file, put it back there and use Reconfigure.")
    }

    /// Copies the earlier settings file beside settings.exs, which loads it
    /// from there. Gives back the choices to go on with: without the
    /// earlier file when it is gone and no copy was kept.
    static func carryOver(_ c: Choices, backups: URL, say: (String) -> Void) throws -> Choices {
        let (checked, note) = checkedImport(c)
        if let note { say(note) }
        let copy = importedCopy(c.dataFolder)
        guard let imported = checked.importedSettings, imported != copy.path else { return checked }
        say("Copying your earlier settings from \(imported)")
        guard let contents = fm.contents(atPath: imported) else {
            throw Failure.step("Could not read your earlier settings file, \(imported). Nothing was changed. Check the file, or turn off carrying it over on the second step.")
        }
        try replace(copy, with: contents, backups: backups)
        // It can hold a password; a new file is otherwise readable by all.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        return checked
    }

    /// The choices as the settings in use now have them, for Reconfigure:
    /// the wizard then starts from what the board uses, with whatever was
    /// changed in Settings or with `vitalaize setup` since the first setup,
    /// and not from the first setup's answers.
    static func prefill(_ c: Choices, from doc: SettingsDoc) -> Choices {
        var c = c
        let values = Dictionary(doc.sections.flatMap { $0.fields }.map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        func lines(_ key: String) -> [String]? {
            values[key].map { $0.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        }
        c.role = doc.role == "collector" ? .collector : (doc.role == "hub" ? .hub : .hubAndCollector)
        if c.role == .collector {
            if let dirs = lines("collector.claude_dirs"), !dirs.isEmpty { c.claudeFolders = dirs }
            c.settingsRead = true
            return c
        }
        if let v = values["port"].flatMap({ Int($0) }) { c.port = v }
        if let v = values["brand.name"] { c.boardName = v }
        if let dirs = lines("claude.config_dirs"), !dirs.isEmpty { c.claudeFolders = dirs }
        if let repos = lines("github.repos"), let first = repos.first {
            // A line can carry a repository's own workflows after its name
            // ("owner/name gate=ci.yml"). The first repository's are the
            // three pickers, so only its name is taken; the others keep
            // their lines as they are.
            c.repo = first.split(separator: " ").first.map(String.init) ?? first
            c.otherRepos = Array(repos.dropFirst())
        }
        if let v = values["github.branch"] { c.branch = v }
        if let v = values["github.gate_workflow"] { c.gateWorkflow = v }
        if let v = values["github.dev_deploy"] { c.devWorkflow = v }
        if let v = values["github.prod_deploy"] { c.prodWorkflow = v }
        if let v = values["korium.enabled"] { c.korium = v == "true" }
        if let v = values["codex.enabled"] { c.codex = v == "true" }
        if let v = values["new_relic.enabled"] { c.newRelic = v == "true" }
        if let v = values["new_relic.account_id"] { c.newRelicAccount = v }
        if let v = values["new_relic.api_key_ref"] { c.newRelicKeyRef = v }
        if let v = values["dev_power.aws_profile"] { c.devProfile = v }
        if let v = values["builds.prod_profile"] { c.prodProfile = v }
        if let v = values["alerts.phone"] { c.phone = v }
        if let v = values["alerts.via"] { c.textVia = v }
        c.settingsRead = true
        return c
    }

    // MARK: Mending how it starts

    /// True when the board or collector that is running was started before
    /// the copy of it inside this app was put in place: a new version of
    /// the app was installed over the old one, and what runs is still the
    /// old one, with its files replaced under it.
    static func runningIsOlder() -> Bool {
        let print = Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"], timeout: 5)
        guard print.ok, let match = print.output.range(of: #"\bpid = (\d+)"#, options: .regularExpression) else { return false }
        let pid = print.output[match].filter { $0.isNumber }
        // The process's age in seconds, which needs no date to be read.
        let age = Shell.run("/bin/ps", ["-o", "etime=", "-p", String(pid)], timeout: 5)
        guard age.ok, let seconds = elapsed(age.output) else { return false }
        var info = stat()
        guard stat(release.appendingPathComponent("bin/wallboard").path, &info) == 0 else { return false }
        // When the file was put there (its change time), not when it was built.
        let placed = Date(timeIntervalSince1970: TimeInterval(info.st_ctimespec.tv_sec))
        return Date().addingTimeInterval(-seconds) < placed
    }

    /// Seconds from ps's elapsed time, [[days-]hours:]minutes:seconds.
    static func elapsed(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let dayParts = trimmed.split(separator: "-")
        let days = dayParts.count == 2 ? Double(dayParts[0]) : 0
        let clock = (dayParts.last ?? "").split(separator: ":").map { Double($0) }
        guard let days, !clock.isEmpty, clock.count <= 3, !clock.contains(where: { $0 == nil }) else { return nil }
        let seconds = clock.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return days * 86400 + seconds
    }

    /// What stops VitalAIze from starting on this Mac as it was set up, in
    /// words for the person, or nil when nothing does. An app installed
    /// over an older one finds the older one's login item: it can name a
    /// copy of the app that is gone, or a settings file that loads a file
    /// that is gone.
    static func startFault(_ record: Installed) -> String? {
        let c = record.choices
        let program = release.appendingPathComponent("bin/wallboard").path
        guard let item = NSDictionary(contentsOf: agentPlist) else {
            return "The login item that starts \(c.role.runsBoard ? "the board" : "the collector") was missing."
        }
        let was = (item["ProgramArguments"] as? [String])?.first ?? ""
        if was != program {
            // Another copy of the app that is still there keeps the login
            // item: two copies would take it from each other every time
            // one of them is opened.
            if fm.isExecutableFile(atPath: was) { return nil }
            return "The login item started VitalAIze from \(was), which is gone."
        }
        let settings = c.dataFolder + "/settings.exs"
        if (item["EnvironmentVariables"] as? [String: String])?["WALLBOARD_SETTINGS"] != settings {
            return "The login item named another settings file than \(settings)."
        }
        if let fault = settingsFault(c) { return fault }
        if !Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"], timeout: 5).ok {
            return "The login item was not loaded."
        }
        return nil
    }

    /// What is wrong with settings.exs itself, or nil: it is missing, or it
    /// loads the copy of an earlier settings file and that copy is gone.
    static func settingsFault(_ c: Choices) -> String? {
        let path = c.dataFolder + "/settings.exs"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "The settings file, \(path), was missing."
        }
        let copy = importedCopy(c.dataFolder)
        if text.contains("settings.imported.exs") && !fm.fileExists(atPath: copy.path) {
            return "The settings file loads \(copy.path), which is gone."
        }
        return nil
    }

    /// Makes the login item start VitalAIze from this app again, with the
    /// data folder where it is: the settings, the database and what was
    /// saved in Settings all stay. settings.exs is written again only when
    /// it cannot load as it is, from the answers the setup recorded. Every
    /// file changed is copied to the backup folder first.
    static func mend(_ record: Installed, say: @escaping (String) -> Void) throws {
        if let fault = awayFault() { throw Failure.step(fault) }
        var c = record.choices
        let data = URL(fileURLWithPath: c.dataFolder)
        let backups = backupFolder(data)
        if settingsFault(c) != nil {
            if c.importedSettings == nil {
                // settings.exs loads a copy the record knows nothing of.
                say("Settings beyond the ones this setup asks about were not carried over. If you have a backup of \(importedCopy(c.dataFolder).path), put it back there and use Reconfigure.")
            }
            c = try carryOver(c, backups: backups, say: say)
            say("Writing the settings file again from your setup answers")
            try replace(data.appendingPathComponent("settings.exs"), with: Data(settingsFile(c).utf8), backups: backups)
        }
        say("Setting the login item to start VitalAIze from this app")
        try startBoard(c, backups: backups)
        if c.role.runsBoard {
            guard waitForBoard(port: currentPort(c), seconds: 90) else {
                throw Failure.step("The board did not start. Its log is at \(logFile.path).")
            }
        } else if !waitForService(seconds: 30) {
            throw Failure.step("The collector did not start. Its log is at \(logFile.path).")
        }
        if fm.fileExists(atPath: backups.path) { say("The files as they were are in \(backups.path)") }
        // An older install kept its log somewhere else, and that one stops here.
        say("The log is at \(logFile.path)")
    }

    /// The port the board answers on now: the one saved in Settings when
    /// there is one, else the setup's.
    static func currentPort(_ c: Choices) -> Int {
        let saved = URL(fileURLWithPath: c.dataFolder).appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: saved),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let port = json["port"] as? Int { return port }
            if let port = (json["port"] as? String).flatMap({ Int($0) }) { return port }
        }
        return c.port
    }

    /// Why this copy of the app must not be what the login item starts,
    /// or nil: macOS runs an app opened from a download or a disk image
    /// from a place that is gone after a restart or an eject.
    static func awayFault() -> String? {
        let path = release.path
        guard path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") else { return nil }
        return "This copy of VitalAIze runs from a place that will not be there after a restart (\(path)). Move VitalAIze into the Applications folder and open it from there."
    }

    /// The login item that runs the board from inside this app.
    static func startBoard(_ c: Choices, backups: URL) throws {
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
        try replace(agentPlist, with: xml, backups: backups)

        let domain = "gui/\(getuid())"
        Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        // launchd can still be letting go of the item it just stopped.
        var r = Shell.run("/bin/launchctl", ["bootstrap", domain, agentPlist.path])
        for _ in 0..<5 where !r.ok {
            sleep(1)
            r = Shell.run("/bin/launchctl", ["bootstrap", domain, agentPlist.path])
        }
        if !r.ok { throw Failure.step("Could not start \(c.role.runsBoard ? "the board" : "the collector"): \(r.output)") }
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

    /// What runs on this Mac right now, as one sentence for the person,
    /// after a setup with these choices stopped part way.
    static func runningNow(_ c: Choices) -> String {
        guard let record = installed() else {
            return serviceRunning()
                ? "VitalAIze was started, but its setup did not finish. Fix what is said above and run the setup again."
                : "Nothing of VitalAIze is running on this Mac."
        }
        if record.choices.role.runsBoard {
            let port = currentPort(record.choices)
            return boardRunning(port: port)
                ? "The board that was set up before is still running at http://localhost:\(String(port))."
                : "The board is not running now. Use Open the log to see why, then Back to the setup."
        }
        return serviceRunning()
            ? "The collector that was set up before is still running."
            : "The collector is not running now. Use Open the log to see why, then Back to the setup."
    }

    /// True when a program other than this Mac's own board listens on the
    /// port. The board that already runs there is about to be restarted,
    /// so it is not in the way.
    static func portTakenByAnother(_ port: Int) -> Bool {
        guard Shell.run("/usr/bin/nc", ["-z", "-G", "1", "127.0.0.1", String(port)], timeout: 4).ok else { return false }
        guard serviceRunning() else { return true }
        // With no record, a setup stopped part way and what it started is
        // still running: that is what a new try is about to restart.
        guard let record = installed() else { return false }
        return !(record.choices.role.runsBoard && currentPort(record.choices) == port)
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
        let place = folder ?? dataFolder ?? "the folder the board keeps its files in"
        let failed = SaveAnswer(ok: false, lines: ["The settings could not be saved, and are as they were. Check that \(place) can be written to. The log is at \(logFile.path)."], errors: nil, service: nil)
        // The saved settings as they were, kept before the board's code
        // writes the file again.
        var kept: (file: URL, copy: URL)?
        if let dir = (folder ?? dataFolder).map({ URL(fileURLWithPath: $0) }) {
            let file = dir.appendingPathComponent("settings.json")
            let backups = backupFolder(dir)
            do { try keep(file, in: backups) } catch {
                return SaveAnswer(ok: false, lines: [error.localizedDescription], errors: nil, service: nil)
            }
            if fm.fileExists(atPath: file.path) { kept = (file, backups.appendingPathComponent(file.lastPathComponent)) }
        }
        // True when the save wrote the file; when it did not, there is
        // nothing to keep and the copy goes again.
        func wrote() -> Bool {
            guard let kept else { return false }
            if !fm.contentsEqual(atPath: kept.file.path, andPath: kept.copy.path) { return true }
            try? fm.removeItem(at: kept.copy)
            let folder = kept.copy.deletingLastPathComponent()
            if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? fm.removeItem(at: folder) }
            return false
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["values": values]),
              let data = engine(["save"], input: String(decoding: body, as: UTF8.self), dataFolder: folder),
              var answer = try? JSONDecoder().decode(SaveAnswer.self, from: data) else {
            guard wrote(), let kept else { return failed }
            return SaveAnswer(ok: false, lines: ["The settings were saved, but the save did not finish, so a change that needs a restart may not be in use yet. Go back and use Restart. The settings as they were before are in \(kept.copy.deletingLastPathComponent().path). The log is at \(logFile.path)."], errors: nil, service: nil)
        }
        if wrote(), answer.ok, let kept {
            answer.lines = (answer.lines ?? []) + ["The settings as they were before this save are in \(kept.copy.deletingLastPathComponent().path)."]
        }
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

    /// Asked at 127.0.0.1, where the board listens: "localhost" is tried
    /// at ::1 first, where another program could be the one to answer.
    static func boardRunning(port: Int) -> Bool {
        let r = Shell.run("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "2", "http://127.0.0.1:\(port)/"], timeout: 5)
        // A board with a password answers 401 until the password is given:
        // it is running all the same.
        return r.output == "200" || r.output == "401"
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

    static func uninstall(deleteData: Bool, say: (String) -> Void) throws {
        let record = installed()
        // Kept in the backup folder unless everything is being deleted, so
        // a Remove by mistake can be put back by hand. When they cannot be
        // kept, nothing is removed: it is still set up, and still starts
        // when you log in.
        if !deleteData, let folder = dataFolder {
            let backups = backupFolder(URL(fileURLWithPath: folder))
            do {
                try keep(agentPlist, in: backups)
                try keep(URL(fileURLWithPath: folder + "/install.json"), in: backups)
            } catch {
                throw Failure.step("\(error.localizedDescription) Nothing was removed. Check that \(folder) can be written to and use Remove again, or turn on deleting the database and settings too.")
            }
        }
        say(record?.choices.role.runsBoard == false ? "Stopping the collector" : "Stopping the board")
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
