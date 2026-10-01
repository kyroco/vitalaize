#if UITEST
import AppKit

/// Drives the real app's window from a script, for macos/uitest/run.sh.
/// Built only into the test build (`-D UITEST`); the app people install
/// does not carry it.
///
/// The script is a text file named by VITALAIZE_UITEST, one step a line:
///
///   wait [SECONDS] "text"        until some text or control holds it (20 s)
///   gone [SECONDS] "text"        until none does
///   expect "text" / absent "text"
///   snap NAME                    NAME.png of the window, NAME.txt of its controls
///   click "Button" [N]           a real mouse click on the Nth such button
///   enabled "Button" / disabled "Button"
///   type "Label" "text"          into the field labelled so (or with that prompt)
///   toggle "Label"               a real mouse click on the switch
///   pick "Label" "value"         a picker; see `pick` below for what is not driven
///   value "Label" "text"         the field or picker labelled so shows it
///   folder "/path"               what the next folder picker answers ("" cancels)
///   opened "text"                something was opened whose address holds it
///   scroll top|bottom
///   sleep SECONDS
///
/// Everything is found the way VoiceOver finds it, through the window's
/// accessibility tree, and clicked with real mouse events at its place on
/// screen, so a button that cannot be reached by a person fails here too.
/// No permission is needed: an app may read and click its own windows.
/// Results go to results.txt in VITALAIZE_UITEST_OUT, one line a step,
/// and the app exits 0 only when every step passed.
enum UITest {
    static weak var state: AppState?
    static var out = URL(fileURLWithPath: ".")
    static var steps: [(number: Int, line: String)] = []
    static var results: [String] = []
    static var failed = false
    static var opened: [String] = []
    static var nextFolder: String? = nil

    static func arm() {
        let env = ProcessInfo.processInfo.environment
        guard let script = env["VITALAIZE_UITEST"], let text = try? String(contentsOfFile: script, encoding: .utf8) else { return }
        out = URL(fileURLWithPath: env["VITALAIZE_UITEST_OUT"] ?? ".")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty && !line.hasPrefix("#") { steps.append((i + 1, line)) }
        }
        // Nothing the run opens reaches the person's browser or Finder.
        Shell.opener = { opened.append($0.absoluteString) }
        Shell.folderPicker = { _, _ in nextFolder }
        after(1.0) {
            NSApp.setActivationPolicy(.accessory)
            // SwiftUI builds its accessibility tree only once something asks for it.
            _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
            if let w = windows().last { w.setContentSize(NSSize(width: 900, height: 760)) }
            after(0.5) { run(0) }
        }
        after(900) { record(0, "the whole run", false, "took more than 15 minutes"); finish() }
    }

    static func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: What is on screen

    struct Element {
        let object: NSObject
        let role: String
        let name: String
        let value: String
        let window: NSWindow
        var enabled: Bool { (object as AnyObject).isAccessibilityEnabled?() ?? true }
        var frame: NSRect { (object as AnyObject).accessibilityFrame?() ?? .zero }
        var holds: String { name + "\n" + value }
    }

    /// The app's windows a person can see, a sheet before the window under it.
    static func windows() -> [NSWindow] {
        let shown = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && !($0 is NSPanel && $0.sheetParent == nil) }
        let sheets = shown.filter { $0.sheetParent != nil }
        return sheets + shown.filter { $0.sheetParent == nil }
    }

    /// With a sheet up, only the sheet can be used, as for a person.
    static func front() -> [NSWindow] {
        let all = windows()
        if let sheet = all.first(where: { $0.sheetParent != nil }) { return [sheet] }
        return all
    }

    private static func text(_ object: NSObject, _ selector: String) -> String {
        let sel = NSSelectorFromString(selector)
        guard object.responds(to: sel), let value = object.perform(sel)?.takeUnretainedValue() else { return "" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let r = value as? NSAccessibility.Role { return r.rawValue }
        return "\(value)"
    }

    private static func children(_ object: NSObject) -> [NSObject] {
        let sel = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: sel) else { return [] }
        return (object.perform(sel)?.takeUnretainedValue() as? [NSObject]) ?? []
    }

    static func elements() -> [Element] {
        var found: [Element] = []
        func walk(_ object: NSObject, _ window: NSWindow, _ depth: Int) {
            let role = text(object, "accessibilityRole")
            if !role.isEmpty {
                let label = text(object, "accessibilityLabel")
                let name = label.isEmpty ? text(object, "accessibilityTitle") : label
                found.append(Element(object: object, role: role, name: name, value: text(object, "accessibilityValue"), window: window))
            }
            if depth < 40 { for child in children(object) { walk(child, window, depth + 1) } }
        }
        for window in front() { if let view = window.contentView { walk(view, window, 0) } }
        return found
    }

    static func onScreen(_ needle: String) -> Bool { elements().contains { $0.holds.contains(needle) } }

    static let pressable: Set<String> = ["AXButton", "AXRadioButton", "AXLink", "AXMenuButton"]

    static func buttons(_ label: String) -> [Element] {
        let all = elements().filter { pressable.contains($0.role) }
        let exact = all.filter { $0.name == label }
        return exact.isEmpty ? all.filter { $0.name.hasPrefix(label) } : exact
    }

    /// The control of one of `roles` that carries `label`, or the first one
    /// after the text that reads `label`: a form shows a field's label as
    /// text beside it.
    static func control(_ label: String, roles: Set<String>) -> Element? {
        let all = elements()
        if let direct = all.first(where: { roles.contains($0.role) && $0.name == label }) { return direct }
        guard let at = all.firstIndex(where: { $0.role == "AXStaticText" && ($0.value == label || $0.name == label) }) else {
            return all.first { roles.contains($0.role) && $0.name.hasPrefix(label) }
        }
        return all[(at + 1)...].first { roles.contains($0.role) }
    }

    // MARK: Using it

    private static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    /// Scrolls so the element shows, as a person would before clicking it.
    static func reveal(_ element: Element) {
        guard let content = element.window.contentView else { return }
        let rect = element.window.convertFromScreen(element.frame)
        for case let scroll as NSScrollView in views(content) {
            guard let doc = scroll.documentView, doc.convert(doc.bounds, to: nil).contains(NSPoint(x: rect.midX, y: rect.midY)) else { continue }
            if !scroll.convert(scroll.contentView.frame, to: nil).insetBy(dx: 0, dy: 8).contains(rect) {
                doc.scrollToVisible(doc.convert(rect, from: nil).insetBy(dx: 0, dy: -24))
            }
        }
    }

    /// A real click: mouse down and up at the middle of the element, through
    /// the app's own event queue.
    static func mouse(_ element: Element) -> Bool {
        let frame = element.frame
        guard frame.width > 0, frame.height > 0 else { return false }
        let point = element.window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        guard let content = element.window.contentView?.superview ?? element.window.contentView, content.frame.contains(point) else { return false }
        for (number, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: element.window.windowNumber, context: nil, eventNumber: number, clickCount: 1,
                                                 pressure: type == .leftMouseDown ? 1 : 0) else { return false }
            NSApp.postEvent(event, atStart: false)
        }
        return true
    }

    /// The text view behind a field the tree names: the one at its place.
    static func editor(for element: Element) -> NSView? {
        guard let content = element.window.contentView else { return nil }
        let rect = element.window.convertFromScreen(element.frame)
        let middle = NSPoint(x: rect.midX, y: rect.midY)
        let fields = views(content).filter { ($0 as? NSTextField)?.isEditable == true || ($0 as? NSTextView)?.isEditable == true }
        return fields.filter { $0.convert($0.bounds, to: nil).insetBy(dx: -4, dy: -4).contains(middle) }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    static func typeInto(_ element: Element, _ string: String) -> Bool {
        guard let view = editor(for: element) else { return false }
        element.window.makeFirstResponder(view)
        let target = (view as? NSTextView) ?? ((view as? NSTextField)?.currentEditor() as? NSTextView)
        guard let target else { return false }
        target.selectAll(nil)
        target.insertText(string, replacementRange: target.selectedRange())
        return true
    }

    /// The window's pickers, by the label a person reads, and the setting
    /// each one changes. A picker's menu runs macOS's own menu loop, which
    /// takes no events from inside the app, so the script cannot open it.
    /// `pick` checks the picker is there and can be used, then sets what
    /// choosing from it sets. Opening the menu itself is on the list of
    /// clicks for a person.
    static func choose(_ label: String, _ value: String) -> Bool {
        guard let state else { return false }
        switch label {
        case "Gate workflow (checks each change)": state.choices.gateWorkflow = value
        case "Dev deploy workflow": state.choices.devWorkflow = value
        case "Prod deploy workflow": state.choices.prodWorkflow = value
        case "Dev: awake or asleep": state.choices.devProfile = value
        case "Prod: same build as dev?": state.choices.prodProfile = value
        case "Send as": state.choices.textVia = value
        default:
            let fields = state.doc?.sections.flatMap { $0.fields } ?? []
            guard let field = fields.first(where: { $0.type == "choice" && ($0.label == label || $0.label + " (restarts)" == label) }),
                  field.options.contains(value) else { return false }
            state.edits[field.key] = value
        }
        return true
    }

    // MARK: Pictures and lists

    static func snap(_ name: String) -> Bool {
        guard let window = front().first, let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        try? png.write(to: out.appendingPathComponent(name + ".png"))
        let shown: Set<String> = ["AXButton", "AXRadioButton", "AXLink", "AXMenuButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXPopUpButton", "AXStaticText", "AXProgressIndicator"]
        let lines = elements().filter { shown.contains($0.role) }.map { e -> String in
            let kind = e.role.replacingOccurrences(of: "AX", with: "")
            let words = [e.name, e.value].filter { !$0.isEmpty }.joined(separator: " = ").replacingOccurrences(of: "\n", with: " ")
            return "\(kind)\t\(words)\(e.role == "AXStaticText" || e.enabled ? "" : "\t(off)")"
        }
        try? lines.joined(separator: "\n").appending("\n").write(to: out.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        return true
    }

    // MARK: The run

    /// A line's words: bare, or in double quotes.
    static func words(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        var open = false
        for ch in line {
            if ch == "\"" { quoted.toggle(); open = true; continue }
            if ch == " " && !quoted {
                if open || !current.isEmpty { out.append(current) }
                current = ""; open = false
                continue
            }
            current.append(ch)
        }
        if open || !current.isEmpty { out.append(current) }
        return out
    }

    static func record(_ number: Int, _ line: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failed = true }
        let entry = "\(ok ? "ok  " : "FAIL")\t\(number)\t\(line)\(ok || detail.isEmpty ? "" : "\t" + detail)"
        results.append(entry)
        print(entry)
        fflush(stdout)
    }

    static func finish() {
        try? results.joined(separator: "\n").appending("\n").write(to: out.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
        exit(failed ? 1 : 0)
    }

    /// Asks again every quarter second until `test` holds or time is up.
    static func poll(_ seconds: Double, _ test: @escaping () -> Bool, then: @escaping (Bool) -> Void) {
        if test() { return then(true) }
        if seconds <= 0 { return then(false) }
        after(0.25) { poll(seconds - 0.25, test, then: then) }
    }

    static func run(_ index: Int) {
        guard index < steps.count else { return finish() }
        let (number, line) = steps[index]
        let w = words(line)
        let args = Array(w.dropFirst())
        func done(_ ok: Bool, _ detail: String = "", settle: Double = 0.05) {
            record(number, line, ok, detail)
            after(settle) { run(index + 1) }
        }
        func timed() -> (Double, String) {
            if args.count > 1, let s = Double(args[0]) { return (s, args[1]) }
            return (20, args.first ?? "")
        }
        switch w.first ?? "" {
        case "wait":
            let (seconds, needle) = timed()
            poll(seconds, { onScreen(needle) }) { done($0, $0 ? "" : "never showed") }
        case "gone":
            let (seconds, needle) = timed()
            poll(seconds, { !onScreen(needle) }) { done($0, $0 ? "" : "still showing") }
        case "expect":
            done(onScreen(args[0]), "not on screen")
        case "absent":
            done(!onScreen(args[0]), "on screen")
        case "snap":
            done(snap(args[0]), "no window to picture")
        case "sleep":
            after(Double(args[0]) ?? 1) { done(true) }
        case "enabled", "disabled":
            guard let button = buttons(args[0]).first else { return done(false, "no such button") }
            let want = w[0] == "enabled"
            done(button.enabled == want, button.enabled ? "it can be pressed" : "it is greyed out")
        case "click":
            let nth = args.count > 1 ? (Int(args[1]) ?? 1) : 1
            let all = buttons(args[0])
            guard all.count >= nth else { return done(false, all.isEmpty ? "no such button" : "only \(all.count) of them") }
            guard all[nth - 1].enabled else { return done(false, "it is greyed out") }
            reveal(all[nth - 1])
            after(0.3) {
                let again = buttons(args[0])
                guard again.count >= nth else { return done(false, "gone after scrolling to it") }
                done(mouse(again[nth - 1]), "outside the window, so it cannot be clicked", settle: 0.5)
            }
        case "toggle":
            guard let box = control(args[0], roles: ["AXCheckBox"]) else { return done(false, "no such switch") }
            guard box.enabled else { return done(false, "it is greyed out") }
            reveal(box)
            after(0.3) {
                guard let again = control(args[0], roles: ["AXCheckBox"]) else { return done(false, "gone after scrolling to it") }
                let before = again.value
                guard mouse(again) else { return done(false, "outside the window, so it cannot be clicked") }
                after(0.5) {
                    let now = control(args[0], roles: ["AXCheckBox"])?.value
                    done(now != before, "the click did not change it")
                }
            }
        case "type":
            guard let field = control(args[0], roles: ["AXTextField", "AXTextArea"]) else { return done(false, "no such field") }
            reveal(field)
            after(0.3) {
                guard let again = control(args[0], roles: ["AXTextField", "AXTextArea"]) else { return done(false, "gone after scrolling to it") }
                done(typeInto(again, args.count > 1 ? args[1] : ""), "the field would not take text", settle: 0.4)
            }
        case "value":
            guard let field = control(args[0], roles: ["AXTextField", "AXTextArea", "AXPopUpButton", "AXCheckBox"]) else { return done(false, "no such control") }
            done(field.value.contains(args[1]), "it shows \"\(field.value)\"")
        case "pick":
            guard let picker = control(args[0], roles: ["AXPopUpButton"]) else { return done(false, "no such picker") }
            guard picker.enabled else { return done(false, "it is greyed out") }
            done(choose(args[0], args[1]), "no such choice", settle: 0.4)
        case "folder":
            nextFolder = args.first.flatMap { $0.isEmpty ? nil : $0 }
            done(true)
        case "opened":
            done(opened.contains { $0.contains(args[0]) }, "opened: \(opened.joined(separator: ", "))")
        case "scroll":
            for window in front() {
                for case let scroll as NSScrollView in views(window.contentView!) {
                    guard let doc = scroll.documentView else { continue }
                    let top = doc.isFlipped ? NSPoint.zero : NSPoint(x: 0, y: doc.bounds.maxY)
                    let bottom = doc.isFlipped ? NSPoint(x: 0, y: doc.bounds.maxY) : NSPoint.zero
                    doc.scroll(args.first == "bottom" ? bottom : top)
                }
            }
            done(true, settle: 0.3)
        default:
            done(false, "not a step this driver knows")
        }
    }
}
#endif
