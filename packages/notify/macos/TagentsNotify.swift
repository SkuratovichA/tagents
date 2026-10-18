import AppKit
import Foundation
import UserNotifications
import os

// The helper behind the tagents notify plugin. One process per verb, so nothing runs while idle.
// Every verb prints exactly one line of JSON on stdout and exits.
//
//   post                stdin: one Notice as JSON
//   withdraw <id>...    removes delivered and pending notices
//   authorize           asks for alert and badge, waits up to 60 s for the answer
//   status | delivered
//   terminal <pid>      the terminal app above a pid, the walk `post` uses
//   icon <in> <out>     draws the PNG <in> onto the app-icon plate and writes the PNG <out>; build.sh's tool,
//                       run before any NSApplication exists
//   (no arguments)      LaunchServices relaunching the app for a notification click

private let logger = Logger(subsystem: "io.github.skuratovicha.tagents-notify", category: "helper")
private let usage = "usage: tagents-notify post | withdraw <id>... | authorize | status | delivered | terminal <pid> | icon <in.png> <out.png> | (no arguments: handle a notification click)"
private let outputLock = NSLock()

// Prints one JSON line and exits. The lock is never released, so a second caller racing the first waits for the exit.
func finish(_ object: [String: Any], _ code: Int32 = 0) -> Never {
    outputLock.lock()
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
        ?? Data(#"{"ok":false,"error":"cannot encode the result"}"#.utf8)
    FileHandle.standardOutput.write(data + Data("\n".utf8))
    exit(code)
}

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    finish(["ok": false, "error": message], code)
}

struct ClickAction: Decodable {
    let argv: [String]
    let env: [String: String]
}

struct Notice: Decodable {
    let id: String
    let thread: String
    let title: String
    let subtitle: String
    let body: String
    let click: ClickAction
    let terminalPid: Int32?
    let skipIfFrontmost: Bool?
}

func describe(_ error: Error) -> String {
    guard let decoding = error as? DecodingError else { return error.localizedDescription }
    switch decoding {
    case .keyNotFound(let key, _):
        return "missing \"\(key.stringValue)\""
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
    @unknown default:
        return "undecodable"
    }
}

// `.ephemeral` does not exist on macOS, so the contract's fifth status is matched by its raw value.
func statusName(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .provisional: return "provisional"
    default: return status.rawValue == 4 ? "ephemeral" : "notDetermined"
    }
}

func styleName(_ style: UNAlertStyle) -> String {
    switch style {
    case .banner: return "banner"
    case .alert: return "alert"
    default: return "none"
    }
}

func canPost(_ status: UNAuthorizationStatus) -> Bool {
    status == .authorized || status == .provisional || status.rawValue == 4
}

// The parent of a process, from the kernel's process table.
func parentPid(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

// The terminal is the first ancestor that is a regular app; the pid passed in must belong to a tmux client,
// since a pane's own processes descend from the tmux server.
func terminalApp(above pid: pid_t) -> NSRunningApplication? {
    var seen = Set<pid_t>()
    var next: pid_t? = pid
    while let current = next, current > 1, seen.insert(current).inserted {
        if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular { return app }
        next = parentPid(of: current)
    }
    return nil
}

func isFrontmost(_ app: NSRunningApplication) -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
}

// MARK: icon

// The macOS app-icon grid: a 824 pt body inside the 1024 pt canvas, the rest transparent. macOS 26 puts an icon
// that is not this shape into a grey plate, so the owner's picture is drawn onto a plate of the right shape.
private let iconCanvas = 1024
private let iconBody = 824.0
// Apple's icon outline is a continuous-corner rounded square, which a superellipse of exponent 5 follows closely.
private let iconExponent = 5.0
// The picture fills this share of the plate's side, so it keeps a margin.
private let iconArtShare = 0.74

func plateOutline(side: Double, center: Double) -> NSBezierPath {
    let half = side / 2
    let steps = 720
    let path = NSBezierPath()
    for step in 0..<steps {
        let angle = 2 * Double.pi * Double(step) / Double(steps)
        let (c, s) = (cos(angle), sin(angle))
        let point = NSPoint(
            x: center + half * (c < 0 ? -1 : 1) * pow(abs(c), 2 / iconExponent),
            y: center + half * (s < 0 ? -1 : 1) * pow(abs(s), 2 / iconExponent))
        if step == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    return path
}

// Writes a 1024 x 1024 PNG: the input scaled to fit, aspect ratio kept, centred on a light plate.
func drawIcon(from input: String, to output: String) -> String? {
    guard let art = NSImage(contentsOfFile: input), art.size.width > 0, art.size.height > 0 else {
        return "cannot read an image from \(input)"
    }
    // The canvas is empty, so tagging it sRGB (no conversion) makes everything drawn on it, and the PNG that is
    // written, sRGB instead of whatever the display's profile is.
    guard let blank = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: iconCanvas, pixelsHigh: iconCanvas, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let canvas = blank.retagging(with: .sRGB),
        let context = NSGraphicsContext(bitmapImageRep: canvas)
    else { return "cannot create the icon canvas" }
    // One point is one pixel, whatever the density of the input.
    canvas.size = NSSize(width: iconCanvas, height: iconCanvas)
    let middle = Double(iconCanvas) / 2

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor(srgbRed: 0.97, green: 0.97, blue: 0.97, alpha: 1).setFill()
    plateOutline(side: iconBody, center: middle).fill()
    let room = iconBody * iconArtShare
    let scale = min(room / Double(art.size.width), room / Double(art.size.height))
    let size = NSSize(width: Double(art.size.width) * scale, height: Double(art.size.height) * scale)
    art.draw(in: NSRect(x: middle - size.width / 2, y: middle - size.height / 2, width: size.width, height: size.height),
             from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = canvas.representation(using: .png, properties: [:]) else { return "cannot encode the icon" }
    do {
        try png.write(to: URL(fileURLWithPath: output))
    } catch {
        return "cannot write \(output): \(error.localizedDescription)"
    }
    return nil
}

// MARK: click child's stderr

// The first 2 KB a click's child writes to stderr, the rest read and thrown away so a chatty child never blocks on a
// full pipe. Reads never wait: a grandchild (the tmux server a script starts) can keep the write end open for good,
// so the end of the stream is not something to wait for.
final class StderrTail {
    let pipe = Pipe()
    private let limit = 2048
    private let lock = NSLock()
    private var kept = Data()
    private var dropped = false

    init() {
        let reader = pipe.fileHandleForReading
        _ = fcntl(reader.fileDescriptor, F_SETFL, fcntl(reader.fileDescriptor, F_GETFL) | O_NONBLOCK)
        reader.readabilityHandler = { [weak self] handle in
            // At the end of the stream the handler would fire for ever.
            if self?.drain() == true { handle.readabilityHandler = nil }
        }
    }

    // Reads what the pipe holds now. True once the stream has ended.
    @discardableResult
    func drain() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(pipe.fileHandleForReading.fileDescriptor, &chunk, chunk.count)
            if count < 0 { return false }
            if count == 0 { return true }
            let room = max(0, limit - kept.count)
            kept.append(contentsOf: chunk[0..<min(count, room)])
            if count > room { dropped = true }
        }
    }

    // What the child wrote, after one last read; the pipe is not used again.
    func finish() -> String {
        drain()
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        let text = String(decoding: kept, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return dropped ? text + " [truncated]" : text
    }
}

final class Helper: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter { .current() }
    private var clickMode = false
    private var clickSeen = false

    // A delegate set before launch finishes, or the click that relaunched the app is lost.
    func applicationWillFinishLaunching(_ notification: Notification) {
        center.delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        run(Array(CommandLine.arguments.dropFirst()))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        let isClick = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            if isClick {
                self.click(info)
            } else {
                self.clickSeen = true
                if self.clickMode { finish(["ok": true, "click": false]) }
            }
        }
        handler()
    }

    private func run(_ args: [String]) {
        guard let verb = args.first else { return waitForClick() }
        let rest = Array(args.dropFirst())
        switch verb {
        case "post" where rest.isEmpty: post()
        case "withdraw" where !rest.isEmpty: withdraw(rest)
        case "authorize" where rest.isEmpty: authorize()
        case "status" where rest.isEmpty: settings { ["status": statusName($0.authorizationStatus), "alertStyle": styleName($0.alertStyle), "bundleId": Bundle.main.bundleIdentifier ?? ""] }
        case "delivered" where rest.isEmpty: delivered()
        case "terminal":
            guard rest.count == 1, let pid = Int32(rest[0]), pid > 0 else { fail(usage, 2) }
            terminal(pid)
        default: fail(usage, 2)
        }
    }

    private func settings(_ fields: @escaping (UNNotificationSettings) -> [String: Any]) {
        center.getNotificationSettings { settings in
            var result: [String: Any] = ["ok": true]
            result.merge(fields(settings)) { _, new in new }
            finish(result)
        }
    }

    // MARK: verbs

    private func post() {
        let notice: Notice
        do {
            notice = try JSONDecoder().decode(Notice.self, from: FileHandle.standardInput.readDataToEndOfFile())
        } catch {
            fail("bad notice: \(describe(error))")
        }
        center.getNotificationSettings { settings in
            guard canPost(settings.authorizationStatus) else {
                fail("not authorized: \(statusName(settings.authorizationStatus))")
            }
            DispatchQueue.main.async { self.deliver(notice) }
        }
    }

    private func deliver(_ notice: Notice) {
        let terminal = notice.terminalPid.flatMap { terminalApp(above: $0) }
        if notice.skipIfFrontmost == true, let terminal, isFrontmost(terminal) {
            finish(["ok": true, "shown": false, "why": "frontmost"])
        }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.subtitle
        content.body = notice.body
        content.threadIdentifier = notice.thread
        content.userInfo = ["argv": notice.click.argv, "env": notice.click.env, "app": terminal?.bundleURL?.path ?? ""]
        // The request id is the notice id, so a second post with the same id replaces the first.
        center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)) { error in
            if let error { fail("the notification center refused the notice: \(error.localizedDescription)") }
            finish(["ok": true, "shown": true])
        }
    }

    private func withdraw(_ ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
        awaitGone(ids, until: Date().addingTimeInterval(3))
    }

    // The removal calls have no completion, so the exit waits until the center no longer lists the ids.
    private func awaitGone(_ ids: [String], until deadline: Date) {
        center.getDeliveredNotifications { delivered in
            let left = delivered.map(\.request.identifier).filter(ids.contains)
            if left.isEmpty { finish(["ok": true]) }
            if Date() > deadline { fail("still delivered: \(left.joined(separator: ", "))") }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { self.awaitGone(ids, until: deadline) }
        }
    }

    private func delivered() {
        center.getDeliveredNotifications { finish(["ok": true, "ids": $0.map(\.request.identifier).sorted()]) }
    }

    // Alert and badge only: this helper never plays a tone.
    private func authorize() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            self.settings { ["status": statusName($0.authorizationStatus)] }
        }
        center.requestAuthorization(options: [.alert, .badge]) { _, error in
            if let error { fail("authorization failed: \(error.localizedDescription)") }
            self.settings { ["status": statusName($0.authorizationStatus)] }
        }
    }

    private func terminal(_ pid: pid_t) {
        let app = terminalApp(above: pid)
        finish(["ok": true, "app": app?.bundleURL?.path ?? "", "pid": Int(app?.processIdentifier ?? 0), "frontmost": app.map(isFrontmost) ?? false])
    }

    // MARK: click

    private func waitForClick() {
        clickMode = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if !self.clickSeen { finish(["ok": true, "click": false]) }
        }
    }

    // A click that lands on a verb process is acted on best-effort; that process exits when its own verb is done.
    private func click(_ info: [AnyHashable: Any]) {
        clickSeen = true
        let argv = info["argv"] as? [String] ?? []
        let env = info["env"] as? [String: String] ?? [:]
        let app = info["app"] as? String ?? ""
        // Default level (notice), which the unified log keeps and `log show` prints without --info: a click that went
        // wrong has to leave this behind.
        logger.notice("click: app=\(app, privacy: .public) argv=\(argv.joined(separator: " "), privacy: .public)")
        let work = DispatchGroup()
        if !app.isEmpty { bringForward(app, work) }
        if !argv.isEmpty { runChild(argv, env, work) }
        work.notify(queue: .main) {
            if self.clickMode { finish(["ok": true, "click": true]) }
        }
        // Child wait 8 s, then 2 s of grace after the terminate, so the helper never outlives about 10.5 s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.5) {
            if self.clickMode {
                logger.error("click handling timed out")
                fail("click handling timed out")
            }
        }
    }

    // macOS 14 made activation cooperative: yield to the target while this app is active, then ask LaunchServices,
    // which activates the way `open -a` does even for a caller that is not frontmost.
    private func bringForward(_ path: String, _ work: DispatchGroup) {
        let url = URL(fileURLWithPath: path)
        let running = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == url.path }
        if #available(macOS 14.0, *), let running { NSApp.yieldActivation(to: running) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        work.enter()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { opened, error in
            if let error { logger.error("activate failed: \(error.localizedDescription, privacy: .public)") }
            DispatchQueue.main.async {
                // A second, independent route in case LaunchServices did not bring the app forward.
                if #available(macOS 14.0, *), let target = opened ?? running, !target.isActive {
                    target.activate(from: NSRunningApplication.current, options: [])
                }
                let raised = opened ?? running
                // No `active` here: read right after the asynchronous activate it is usually still false.
                logger.notice("raised: \(path, privacy: .public) pid=\(raised?.processIdentifier ?? 0)")
                work.leave()
            }
        }
    }

    // The click's environment is launchd's bare one, so the notice's env is merged over it, env winning.
    private func runChild(_ argv: [String], _ env: [String: String], _ work: DispatchGroup) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, notice in notice }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = StderrTail()
        process.standardError = stderr.pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            logger.error("cannot run \(argv[0], privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Nothing will write to the pipe now: drop the readability handler first, then close both ends.
            _ = stderr.finish()
            try? stderr.pipe.fileHandleForWriting.close()
            try? stderr.pipe.fileHandleForReading.close()
            return
        }
        // The write end is the child's now; this process keeps no copy of it.
        try? stderr.pipe.fileHandleForWriting.close()
        logger.notice("child started: pid=\(process.processIdentifier) \(argv[0], privacy: .public)")
        work.enter()
        DispatchQueue.global().async {
            var ended = exited.wait(timeout: .now() + 8) == .success
            if !ended {
                logger.error("child still running after 8 s, terminating: \(argv[0], privacy: .public)")
                process.terminate()
                ended = exited.wait(timeout: .now() + 2) == .success
            }
            if ended {
                // A zero status with the reason `exit` is a success; a signal's number comes as the status with the
                // reason `uncaughtSignal`, and tells a crash or a terminate from a failure of the script itself.
                let reason = process.terminationReason == .exit ? "exit" : "uncaughtSignal"
                logger.notice("child ended: status=\(process.terminationStatus) reason=\(reason, privacy: .public) \(argv[0], privacy: .public)")
            } else {
                logger.error("child ignored the terminate: \(argv[0], privacy: .public)")
            }
            let text = stderr.finish()
            if !text.isEmpty { logger.notice("child stderr: \(text, privacy: .public)") }
            work.leave()
        }
    }
}

// The icon verb is a build step, not a notification verb: it needs no app, no notification center and no activation
// policy, so it runs before NSApplication exists and exits through finish like the others.
if CommandLine.arguments.dropFirst().first == "icon" {
    let rest = Array(CommandLine.arguments.dropFirst(2))
    guard rest.count == 2 else { fail(usage, 2) }
    if let problem = drawIcon(from: rest[0], to: rest[1]) { fail(problem) }
    finish(["ok": true])
}

let application = NSApplication.shared
let helper = Helper()
application.delegate = helper
application.setActivationPolicy(.accessory)
application.run()
