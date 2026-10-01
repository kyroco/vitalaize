import AppKit
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

    /// Runs a program and hands over each line it prints as it is printed,
    /// for a program that says something useful before it is done.
    @discardableResult
    static func stream(_ program: String, _ args: [String], env: [String: String] = [:],
                       input: String? = nil, timeout: TimeInterval = 60,
                       onLine: @escaping (String) -> Void) -> Result {
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

        var all = Data()
        var rest = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue(label: "shell-stream").async {
            while true {
                let chunk = out.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                all.append(chunk)
                rest.append(chunk)
                while let end = rest.firstIndex(of: 0x0A) {
                    onLine(String(decoding: rest[rest.startIndex..<end], as: UTF8.self))
                    rest.removeSubrange(rest.startIndex...end)
                }
            }
            if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
            group.leave()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        group.wait()
        return Result(status: process.terminationStatus,
                      output: String(decoding: all, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Opens a page or a file for the person, in their browser or its own
    /// app. A test build puts its own in place, so a test run opens nothing.
    static var opener: (URL) -> Void = { NSWorkspace.shared.open($0) }
    static func open(_ url: URL) { opener(url) }

    /// Asks the person for a folder; nil when they cancel. A test build
    /// answers in the panel's place.
    static var folderPicker: (_ start: String, _ message: String) -> String? = { start, message in
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.message = message
        panel.directoryURL = URL(fileURLWithPath: start)
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Runs a tool found on the search path.
    @discardableResult
    static func tool(_ name: String, _ args: [String], timeout: TimeInterval = 60) -> Result {
        guard let path = which(name) else { return Result(status: -1, output: "\(name) is not installed") }
        return run(path, args, timeout: timeout)
    }
}
