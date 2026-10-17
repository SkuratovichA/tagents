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
//   (no arguments)      LaunchServices relaunching the app for a notification click

private let logger = Logger(subsystem: "io.github.skuratovicha.tagents-notify", category: "helper")
private let usage = "usage: tagents-notify post | withdraw <id>... | authorize | status | delivered | terminal <pid> | (no arguments: handle a notification click)"
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
        case "status" where rest.isEmpty: settings { ["status": statusName($0.authorizationStatus), "alertStyle": styleName($0.alertStyle)] }
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
        logger.info("click: app=\(app, privacy: .public) argv=\(argv.joined(separator: " "), privacy: .public)")
        let work = DispatchGroup()
        if !app.isEmpty { bringForward(app, work) }
        if !argv.isEmpty { runChild(argv, env, work) }
        work.notify(queue: .main) {
            if self.clickMode { finish(["ok": true, "click": true]) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
            if self.clickMode { fail("click handling timed out") }
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
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            logger.error("cannot run \(argv[0], privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        work.enter()
        DispatchQueue.global().async {
            if exited.wait(timeout: .now() + 10) == .timedOut {
                logger.error("child still running after 10 s, terminating: \(argv[0], privacy: .public)")
                process.terminate()
                _ = exited.wait(timeout: .now() + 2)
            } else {
                logger.info("child exited with status \(process.terminationStatus)")
            }
            work.leave()
        }
    }
}

let application = NSApplication.shared
let helper = Helper()
application.delegate = helper
application.setActivationPolicy(.accessory)
application.run()
