import Carbon
import Foundation
import LogiCore
import LogiHID

private let signature = OSType(0x4C47_5357) // 'LGSW'

// Exported by HIToolbox but missing from the Swift overlay. It is the loop that
// dispatches hotkey events to the application target; CFRunLoopRun may not.
@_silgen_name("RunApplicationEventLoop") func RunApplicationEventLoop()

private var busy = false
private var ignoreBefore: EventTime = 0
var onHotKey: (UInt32) -> Void = { _ in }

func listen(_ keyCodes: [UInt32]) -> [UInt32: OSStatus] {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var id = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        // Presses queued while a switch ran arrive afterwards; drop them so a
        // double-tap never becomes a second switch.
        if busy || GetEventTime(event) < ignoreBefore {
            logEvent("hotkey_ignored", ["keyCode": id.id])
            return noErr
        }
        busy = true
        onHotKey(id.id)
        ignoreBefore = GetCurrentEventTime()
        busy = false
        return noErr
    }, 1, &spec, nil, nil)

    var results: [UInt32: OSStatus] = [:]
    for code in keyCodes {
        var ref: EventHotKeyRef?
        results[code] = RegisterEventHotKey(code, 0, EventHotKeyID(signature: signature, id: code),
                                            GetApplicationEventTarget(), 0, &ref)
    }
    return results
}

// F13-F20. PC keyboards send Print Screen, Scroll Lock and Pause as F13, F14 and F15.
private let probeKeys: [UInt32: String] = [105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]

private let watchStart = Date()

private func say(_ line: String) {
    print(String(format: "+%7.3fs  ", Date().timeIntervalSince(watchStart)) + line)
}

// Passive unless --analytics: that asks the keyboard to report Easy-Switch presses
// as HID++ notifications, and turns it back off on Ctrl-C.
func keys(_ args: [String]) -> Never {
    setvbuf(stdout, nil, _IOLBF, 0)
    onHotKey = { code in say("hotkey   keyCode \(code) (\(probeKeys[code] ?? "?"))") }
    for (code, status) in listen(Array(probeKeys.keys)).sorted(by: { $0.key < $1.key }) where status != noErr {
        warn("\(probeKeys[code]!) not registered (OSStatus \(status))")
    }

    var held: [Any] = []
    do {
        held.append(try KeyWatch(onPress: { page, usage, value, product in
            say(String(format: "raw      %@ page 0x%02X usage 0x%02X value %d", product, page, usage, value))
        }, onPresence: { product, arrived in
            say("\(arrived ? "arrived " : "left    ") \(product)")
        }))
    } catch {
        warn("raw key watch off: \(classify(error).1)")
    }
    for name in (try? deviceNames()) ?? [] {
        do {
            let device = try open(name)
            device.onReport = { bytes in say("hidpp    \(name) \(hexString(bytes))") }
            device.onRemoved = { say("hidpp    \(name) collection removed") }
            held.append(device)
            if name == "keyboard", args.contains("--analytics") {
                let exchange: Exchange = { try device.exchange($0, timeout: 1.0) }
                let (index, lines) = try setAnalytics(true, exchange)
                for line in lines { say("setup    \(line)") }
                device.onReport = { bytes in
                    if let index, bytes.count > 4, bytes[2] == index, bytes[3] & 0x0F == 0 {
                        let events = analyticsEvents(Array(bytes[4...])).map { "\(controlLabel($0.cid)) event \($0.event)" }
                        say("hidpp    keyboard fn \(bytes[3] >> 4) \(events.joined(separator: ", ")) [\(hexString(bytes))]")
                    } else {
                        say("hidpp    keyboard \(hexString(bytes))")
                    }
                }
                let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
                interrupt.setEventHandler {
                    let lines = (try? setAnalytics(false, exchange).lines) ?? ["keyboard gone, analytics resets when it reconnects"]
                    for line in lines { say("cleanup  \(line)") }
                    exit(Exit.ok.rawValue)
                }
                signal(SIGINT, SIG_IGN)
                interrupt.resume()
                held.append(interrupt)
            }
        } catch {
            warn("\(name) hidpp watch off: \(classify(error).1)")
        }
    }
    _ = held

    say("watching. Press Scroll Lock, then each Easy-Switch key, then Ctrl-C")
    RunApplicationEventLoop()
    exit(Exit.ok.rawValue)
}

func controls(_ args: [String]) -> Never {
    let names = args.isEmpty ? ((try? deviceNames()) ?? []) : args
    var results: [[String: Any]] = []
    for name in names {
        do {
            let device = try open(name)
            let (feature, list) = try readControls { try device.exchange($0, timeout: 1.0) }
            results.append([
                "device": name,
                "feature": feature.map { ["index": Int($0.index), "version": Int($0.version)] } as Any,
                "controls": list.map(\.json),
            ])
        } catch {
            results.append(["device": name, "error": classify(error).1])
        }
    }
    emitJSON(["devices": results])
    exit(Exit.ok.rawValue)
}
