import Foundation
import LogiCore
import LogiHID

func die(_ code: Exit, _ reason: String) -> Never {
    FileHandle.standardError.write(Data("logitech-switcher: \(reason)\n".utf8))
    exit(code.rawValue)
}

func classify(_ error: Error) -> (Exit, String) {
    switch error {
    case let e as ConfigError: return (e.exit, e.description)
    case let e as TransportError: return (e.exit, e.description)
    case let e as DiscoveryError: return (e.exit, e.description)
    case let e as SwitchError: return (e.exit, e.description)
    case let e as HostNameError: return (.deviceError, e.description)
    case let e as ExchangeTimeout: return (.timeout, e.description)
    default: return (.openFailed, "\(error)")
    }
}

func open(_ name: String) throws -> HIDPPDevice {
    try HIDPPDevice(try resolveDevice(name))
}

func ping(_ name: String) -> Never {
    do {
        let device = try open(name)
        guard let (index, answer) = try findDeviceIndex({ try device.exchange($0, timeout: 1.0) }) else {
            die(.timeout, "\(name): \(DiscoveryError.noAnswer)")
        }
        let at = String(format: "0x%02X", index)
        switch answer {
        case let .reply(reply):
            let pong = Pong(reply)
            emitJSON([
                "device": name, "kind": "reply", "deviceIndex": at,
                "protocol": pong.map { "\($0.major).\($0.minor)" } ?? "unparsed",
                "echoOK": pong?.echo == 0xA5,
                "params": hexString(reply.params),
            ])
            exit(Exit.ok.rawValue)
        case let .error(error):
            emitJSON(["device": name, "kind": "error", "deviceIndex": at, "code": error.code, "reason": HIDPP.errorName(error.code)])
            exit(Exit.deviceError.rawValue)
        }
    } catch {
        let (code, reason) = classify(error)
        die(code, "\(name): \(reason)")
    }
}

func discover(_ args: [String]) -> Never {
    var args = args
    var recordPath: String?
    if let i = args.firstIndex(of: "--record") {
        guard i + 1 < args.count else { die(.usage, "--record needs a file path") }
        recordPath = args[i + 1]
        args.removeSubrange(i...(i + 1))
    }

    let names: [String]
    do {
        names = args.isEmpty ? try deviceNames() : args
    } catch {
        let (code, reason) = classify(error)
        die(code, reason)
    }

    var recorder: FileHandle?
    if let path = recordPath {
        FileManager.default.createFile(atPath: path, contents: nil)
        recorder = FileHandle(forWritingAtPath: path)
    }

    var results: [[String: Any]] = []
    var firstFailure: Exit?
    for name in names {
        do {
            let device = try open(name)
            device.onExchange = { tx, rx in
                let line: [String: Any] = ["device": name, "tx": hexString(tx), "rx": rx.map(hexString) ?? NSNull()]
                if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
                    recorder?.write(data + Data("\n".utf8))
                }
            }
            let report = try discoverDevice { try device.exchange($0, timeout: 1.0) }
            results.append(report.json(name: name))
        } catch {
            let (code, reason) = classify(error)
            results.append(["device": name, "error": reason, "exit": Int(code.rawValue)])
            firstFailure = firstFailure ?? code
        }
    }
    emitJSON(["host": ProcessInfo.processInfo.hostName, "devices": results])
    exit((firstFailure ?? .ok).rawValue)
}

func describe(_ outcome: Outcome) -> [String: Any] {
    switch outcome {
    case let .moved(after): return ["result": "moved", "seconds": after]
    case .already: return ["result": "already"]
    case let .stayed(after): return ["result": "stayed", "seconds": after]
    case let .refused(code): return ["result": "refused", "code": Int(code), "reason": HIDPP.errorName(code)]
    case let .slept(seconds): return ["result": "slept", "seconds": seconds]
    case let .late(after): return ["result": "late", "seconds": after]
    case .skipped: return ["result": "skipped"]
    }
}

// osascript, not UNUserNotificationCenter: that needs an app bundle and a CLI binary has none.
func notify(_ title: String, _ body: String) {
    let script = Process()
    script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    script.arguments = ["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)", "-e", "end run", title, body]
    do {
        try script.run()
        script.waitUntilExit()
    } catch {
        logEvent("notify_failed", ["reason": "\(error)"])
    }
}

func warn(_ reason: String) {
    FileHandle.standardError.write(Data("logitech-switcher: \(reason)\n".utf8))
}

func open(_ spec: ResolvedDevice) throws -> HIDPPDevice {
    try retrying([0.25, 0.5, 1, 2], sleep: Clock.wall.sleep, when: {
        if case TransportError.noMatch = $0 { return true }
        return false
    }) { try HIDPPDevice(spec) }
}

struct Link {
    let spec: ResolvedDevice
    let device: HIDPPDevice
    let report: DeviceReport
}

// The first write on a freshly opened BLE handle costs 160-930ms, so the agent
// connects on arrival and hands its links in; the CLI connects per run.
func connect(_ name: String, reply: TimeInterval) throws -> Link {
    let spec = try resolveDevice(name)
    let device = try open(spec)
    let report = try discoverDevice { try device.exchange($0, timeout: reply) }
    return Link(spec: spec, device: device, report: report)
}

func performSwitch(_ arg: String?, _ only: [String], links: [String: Link] = [:]) -> Exit {
    let started = Date()
    var notifyLevel = NotifyLevel.all
    func fail(_ code: Exit, _ reason: String) -> Exit {
        if notifyLevel != .off { notify("logitech-switcher failed", reason) }
        warn(reason)
        return code
    }

    let settings: SwitchSettings
    let names: [String]
    do {
        settings = try switchSettings()
        names = switchOrder(only.isEmpty ? try deviceNames() : only)
    } catch {
        let (code, reason) = classify(error)
        return fail(code, reason)
    }
    notifyLevel = settings.notify
    var target = Target(arg ?? settings.target, hosts: settings.hosts)

    var devices: [(name: String, spec: ResolvedDevice, device: HIDPPDevice, report: DeviceReport)] = []
    for name in names {
        do {
            let link = try links[name] ?? connect(name, reply: settings.reply)
            devices.append((name, link.spec, link.device, link.report))
        } catch {
            let (code, reason) = classify(error)
            return fail(code, "\(name): \(reason), nothing moved")
        }
    }
    if target == .next {
        do {
            target = .slot(try nextSlot(devices.map(\.report)))
        } catch {
            let (code, reason) = classify(error)
            return fail(code, "\(reason), nothing moved")
        }
    }

    var pushes: [Push] = []
    for (name, spec, device, report) in devices {
        do {
            let leg = try plan(target, device: name, report: report)
            logEvent("plan", ["device": name, "from": leg.current, "to": leg.slot, "host": leg.hostName as Any])
            // The link drops before ChangeHost is answered; only an error reply (~15ms) matters.
            let send: Exchange = { try device.exchange($0, timeout: 0.1) }
            pushes.append(Push(device: name, leg: leg, exchange: send, isPresent: {
                let present = HIDPPDevice.isPresent(spec)
                logEvent("presence", ["device": name, "present": present])
                return present
            }))
        } catch {
            let (code, reason) = classify(error)
            return fail(code, "\(name): \(reason), nothing moved")
        }
    }

    let outcomes = run(pushes, started: started, backoff: Backoff(budget: settings.confirm, window: settings.window))
    emitJSON([
        "host": ProcessInfo.processInfo.hostName,
        "target": arg ?? settings.target ?? "next",
        "devices": zip(pushes, outcomes).map { push, outcome in
            describe(outcome).merging([
                "device": push.device, "from": push.leg.current, "to": push.leg.slot,
                "name": push.leg.hostName as Any,
            ]) { a, _ in a }
        },
    ])
    let (code, reason) = verdict(names, outcomes)
    if code != .ok { return fail(code, reason) }
    if settings.notify == .all { notify("logitech-switcher", switchedMessage(pushes, outcomes)) }
    return .ok
}

func name(_ args: [String]) -> Never {
    var results: [[String: Any]] = []
    var firstFailure: Exit?
    do {
        let settings = try switchSettings()
        let wanted = args.first ?? settings.hostName
        guard !wanted.isEmpty else { die(.usage, "no host name: pass one or set \"hostName\" in config") }
        for device in args.count > 1 ? Array(args.dropFirst()) : try deviceNames() {
            do {
                let link = try connect(device, reply: settings.reply)
                let before = link.report.slots.first { $0.slot == link.report.currentHost }?.name
                let written = try syncHostName(wanted, report: link.report) { try link.device.exchange($0, timeout: settings.reply) }
                results.append(["device": device, "slot": link.report.currentHost, "before": before as Any,
                                "after": written ?? before as Any, "changed": written != nil])
            } catch {
                let (code, reason) = classify(error)
                results.append(["device": device, "error": reason])
                firstFailure = firstFailure ?? code
            }
        }
    } catch {
        let (code, reason) = classify(error)
        die(code, reason)
    }
    emitJSON(["devices": results])
    exit((firstFailure ?? .ok).rawValue)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "ping": ping(args.dropFirst().first ?? "mouse")
case "discover": discover(Array(args.dropFirst()))
case "to": exit(performSwitch(args.dropFirst().first, Array(args.dropFirst(2))).rawValue)
case "agent": agent()
case "keys": keys(Array(args.dropFirst()))
case "controls": controls(Array(args.dropFirst()))
case "name": name(Array(args.dropFirst()))
default: die(.usage, "usage: logitech-switcher ping [device] | discover [--record file] [device...] | to [host] [device...] | agent | keys [--analytics] | controls [device...] | name [name] [device...]")
}
