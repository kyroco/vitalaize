import Foundation

/// Works out as much of the setup as it can from this Mac, so the person
/// mostly confirms rather than types. Nothing here changes anything.
enum Detect {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    // MARK: Claude folders

    /// ~/.claude and every ~/.claude-something that holds Claude sessions.
    static func claudeFolders() -> [String] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: home.path)) ?? []
        return names
            .filter { $0 == ".claude" || $0.hasPrefix(".claude-") }
            .map { home.appendingPathComponent($0).path }
            .filter { fm.fileExists(atPath: "\($0)/projects") || fm.fileExists(atPath: "\($0)/settings.json") }
            .sorted { a, b in a.hasSuffix("/.claude") || (!b.hasSuffix("/.claude") && a < b) }
    }

    /// The newest session transcripts across the given folders.
    static func recentTranscripts(in folders: [String], limit: Int = 40) -> [URL] {
        let fm = FileManager.default
        var found: [(URL, Date)] = []
        for folder in folders {
            let projects = URL(fileURLWithPath: folder).appendingPathComponent("projects")
            guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { continue }
            for dir in dirs {
                guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                for f in files where f.pathExtension == "jsonl" {
                    let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    found.append((f, date))
                }
            }
        }
        return found.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    private static func head(_ url: URL, bytes: Int) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: bytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: GitHub

    /// Every GitHub repository the recent Claude sessions worked in, from the
    /// git remotes of the folders they ran in, as "owner/name": the one most
    /// sessions used first.
    static func githubRepos(folders: [String]) -> [String] {
        let cwdPattern = try! NSRegularExpression(pattern: #""cwd":"([^"]+)""#)
        var cwds = Set<String>()
        for t in recentTranscripts(in: folders) {
            let text = head(t, bytes: 64 * 1024)
            if let m = cwdPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text) {
                cwds.insert(String(text[r]))
            }
        }
        var counts: [String: Int] = [:]
        for cwd in cwds where FileManager.default.fileExists(atPath: cwd) {
            let r = Shell.run("/usr/bin/git", ["-C", cwd, "remote", "get-url", "origin"], timeout: 10)
            if r.ok, let repo = parseGitHub(r.output) { counts[repo, default: 0] += 1 }
        }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    /// "git@github.com:owner/name.git" or "https://github.com/owner/name" to "owner/name".
    static func parseGitHub(_ url: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: #"github\.com[:/]([\w.-]+)/([\w.-]+?)(\.git)?/?$"#)
        guard let m = pattern.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              let o = Range(m.range(at: 1), in: url), let n = Range(m.range(at: 2), in: url) else { return nil }
        return "\(url[o])/\(url[n])"
    }

    static func ghSignedIn() -> Bool { Shell.tool("gh", ["auth", "status"], timeout: 20).ok }

    /// The repository's workflow files, like "gate.yml".
    static func workflows(repo: String) -> [String] {
        let r = Shell.tool("gh", ["api", "repos/\(repo)/actions/workflows?per_page=100", "--jq", ".workflows[].path"], timeout: 30)
        guard r.ok else { return [] }
        return r.output.split(separator: "\n").map { ($0 as NSString).lastPathComponent }.sorted()
    }

    static func defaultBranch(repo: String) -> String? {
        let r = Shell.tool("gh", ["repo", "view", repo, "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"], timeout: 30)
        return r.ok && !r.output.isEmpty ? r.output : nil
    }

    /// Best guesses for the Gate, dev deploy and prod deploy workflows.
    static func guessWorkflows(_ files: [String]) -> (gate: String, dev: String, prod: String) {
        // The closest match wins: "gate.yml" before "gate-build.yml".
        func find(_ test: (String) -> Bool) -> String {
            files.filter(test).min { $0.count == $1.count ? $0 < $1 : $0.count < $1.count } ?? ""
        }
        let gate = find { $0.contains("gate") }
        let gateOrCI = gate.isEmpty ? find { $0.hasPrefix("ci") || $0.contains("test") } : gate
        let dev = find { $0.contains("dev") && ($0.contains("deploy") || $0.contains("app")) }
        let prod = find { $0.contains("prod") && !$0.contains("promote") }
        return (gateOrCI, dev, prod)
    }

    // MARK: Korium, AWS

    /// True when this Mac has Codex sessions to read.
    static func usesCodex() -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/sessions").path)
    }

    /// True when recent Claude sessions called Korium tools.
    static func usesKorium(folders: [String]) -> Bool {
        recentTranscripts(in: folders, limit: 25).contains { head($0, bytes: 2 * 1024 * 1024).contains("korium__") }
    }

    /// Profile names from ~/.aws/config: only the [section] names are read.
    static func awsProfiles() -> [String] {
        let url = home.appendingPathComponent(".aws/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line -> String? in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("["), l.hasSuffix("]") else { return nil }
            let inner = l.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            if inner == "default" { return "default" }
            if inner.hasPrefix("profile ") { return String(inner.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
            return nil
        }
    }

    static func guessDevProfile(_ profiles: [String]) -> String {
        profiles.first { $0.contains("dev") && ($0.contains("ops") || $0.contains("read")) }
            ?? profiles.first { $0.contains("dev") } ?? ""
    }

    static func guessProdProfile(_ profiles: [String]) -> String {
        profiles.first { $0.contains("prod") && $0.contains("read") } ?? profiles.first { $0.contains("prod") } ?? ""
    }

    // MARK: A board set up by hand before

    /// The settings file of a board started with scripts/login-item.sh, if any.
    static func existingSettingsFile() -> String? {
        let plist = home.appendingPathComponent("Library/LaunchAgents/local.wallboard.plist")
        if let dict = NSDictionary(contentsOf: plist),
           let env = dict["EnvironmentVariables"] as? [String: String],
           let path = env["WALLBOARD_SETTINGS"], FileManager.default.fileExists(atPath: path) {
            return path
        }
        let guess = home.appendingPathComponent("projects/wallboard/settings.exs").path
        return FileManager.default.fileExists(atPath: guess) ? guess : nil
    }

    /// Reads the values the wizard asks about from an earlier settings file,
    /// using the board inside this app to read it (it is Elixir). Returns
    /// nil when it cannot be read.
    static func importSettings(_ path: String) -> [String: Any]? {
        let bin = Setup.release.appendingPathComponent("bin/wallboard").path
        guard FileManager.default.isExecutableFile(atPath: bin) else { return nil }
        let code = """
        {s, _} = Code.eval_file(System.fetch_env!("WB_FILE"))
        g = fn p -> get_in(s, p) end
        IO.puts("WB_JSON" <> Jason.encode!(%{
          brand: g.([:brand, :name]), port: g.([:port]),
          phone: g.([:alerts, :phone]), via: g.([:alerts, :via]),
          repo: g.([:github, :repo]), branch: g.([:github, :branch]),
          repos: Enum.map(List.wrap(g.([:github, :repos])), fn %{repo: r} -> r; r -> r end),
          gate: g.([:github, :gate_workflow]), dev: g.([:github, :dev_deploy]),
          prod: g.([:github, :prod_deploy]),
          dev_profile: g.([:dev_power, :aws_profile]), prod_profile: g.([:builds, :prod_profile]),
          new_relic: g.([:new_relic, :enabled]), nr_account: g.([:new_relic, :account_id]),
          nr_key: g.([:new_relic, :api_key_ref]), korium: g.([:korium, :enabled]),
          codex: g.([:codex, :enabled]),
          dirs: g.([:claude, :config_dirs])
        }))
        """
        let tmp = NSTemporaryDirectory() + "wallboard-import"
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let r = Shell.run(bin, ["eval", code],
                          env: ["WB_FILE": path, "RELEASE_DISTRIBUTION": "none", "RELEASE_TMP": tmp], timeout: 60)
        guard let line = r.output.split(separator: "\n").last(where: { $0.hasPrefix("WB_JSON") }),
              let data = line.dropFirst(7).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    static var oldLoginItemInstalled: Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/LaunchAgents/local.wallboard.plist").path)
    }
}
