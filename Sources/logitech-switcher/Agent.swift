import Foundation
import LogiCore
import LogiHID

private var links: [String: Link] = [:]
private var present: Set<String> = []
private var busy = false
private var quietUntil = Date.distantPast

// Linked handles also receive input during a switch's own exchanges, so a
// press arriving then, or within a second after, is dropped.
private func fire() {
    if busy || Date() < quietUntil {
        logEvent("trigger_ignored")
        return
    }
    busy = true
    logEvent("trigger", ["linked": links.keys.sorted()])
    let result = performSwitch(nil, [], links: links)
    logEvent("switch_done", ["exit": Int(result.rawValue)])
    quietUntil = Date().addingTimeInterval(1)
    busy = false
}

// Devices reconnect on every return to this Mac, and the keyboard forgets the
// analytics setting with the old link, so linking and arming repeat on arrival.
private func link(_ name: String, _ settings: SwitchSettings) {
    guard present.contains(name), links[name] == nil else { return }
    do {
        let link = try connect(name, reply: 2.0)
        if name == "keyboard" {
            let cid = settings.trigger
            let index = try armTrigger(cid) { try link.device.exchange($0, timeout: 2.0) }
            link.device.onReport = { bytes in
                if isPress(bytes, featureIndex: index, cid: cid) { fire() }
            }
            logEvent("trigger_armed", ["control": controlLabel(cid)])
        }
        if !settings.hostName.isEmpty {
            do {
                if let written = try syncHostName(settings.hostName, report: link.report, { try link.device.exchange($0, timeout: 2.0) }) {
                    logEvent("host_name_set", ["device": name, "name": written])
                }
            } catch {
                logEvent("host_name_failed", ["device": name, "reason": classify(error).1])
            }
        }
        link.device.onRemoved = {
            links[name] = nil
            logEvent("link_lost", ["device": name])
        }
        links[name] = link
        logEvent("linked", ["device": name, "current": link.report.currentHost])
    } catch {
        // A grant given while this process runs does not reach its device opens;
        // exiting lets launchd (KeepAlive) start a process that has it.
        if case TransportError.open(0xE00002E2) = error, HIDPPDevice.hasAccess() {
            logEvent("restart_for_grant")
            exit(Exit.tccDenied.rawValue)
        }
        logEvent("link_failed", ["device": name, "reason": classify(error).1, "retryIn": 5])
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { link(name, settings) }
    }
}

func agent() -> Never {
    let settings: SwitchSettings
    let specs: [(String, ResolvedDevice)]
    do {
        settings = try switchSettings()
        specs = try deviceNames().map { ($0, try resolveDevice($0)) }
    } catch {
        let (code, reason) = classify(error)
        die(code, reason)
    }
    let granted = HIDPPDevice.requestAccess()
    let watchers = specs.map { name, spec in
        Presence(spec) { arrived in
            logEvent(arrived ? "arrived" : "left", ["device": name])
            if arrived {
                present.insert(name)
                link(name, settings)
            } else {
                present.remove(name)
                links[name] = nil
            }
        }
    }
    logEvent("agent_ready", [
        "trigger": controlLabel(settings.trigger), "binary": CommandLine.arguments[0],
        "inputMonitoring": granted ? "granted" : "missing",
    ])
    if !granted {
        notify("logitech-switcher", "Allow Input Monitoring for logitech-switcher in System Settings, then press Scroll Lock")
    }
    withExtendedLifetime(watchers) { CFRunLoopRun() }
    exit(Exit.ok.rawValue)
}
