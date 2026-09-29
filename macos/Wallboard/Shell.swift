import Foundation

/// Runs command-line tools for the app. Everything the installer does to the
/// Mac goes through here, so it is easy to see what it runs.
enum Shell {
    struct Result {
        let status: Int32
        let output: String
        var ok: Bool { status == 0 }
    }

    /// Folders the tools usually live in. An app opened from Finder gets a
    /// bare PATH, so these are searched and passed on to the board too.
    static let searchPath: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }()

    static var pathValue: String { searchPath.joined(separator: ":") }

    /// Where a tool is, or nil when it is not installed.
    static func which(_ tool: String) -> String? {
        for dir in searchPath {
            let path = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Runs a program and waits for it. `input` is written to its stdin.
    @discardableResult
    static func run(_ program: String, _ args: [String], env: [String: String] = [:],
                    input: String? = nil, timeout: TimeInterval = 60) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = pathValue
        for (k, v) in env { environment[k] = v }
        process.environment = environment

        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        let stdin = Pipe()
        process.standardInput = stdin

        do {
            try process.run()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()

        var data = Data()
        let reader = DispatchQueue(label: "shell-read")
        let group = DispatchGroup()
        group.enter()
        reader.async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        group.wait()
        return Result(status: process.terminationStatus,
                      output: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs a tool found on the search path.
    @discardableResult
    static func tool(_ name: String, _ args: [String], timeout: TimeInterval = 60) -> Result {
        guard let path = which(name) else { return Result(status: -1, output: "\(name) is not installed") }
        return run(path, args, timeout: timeout)
    }
}
