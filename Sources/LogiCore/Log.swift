import Foundation

public func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

public func logEvent(_ event: String, _ fields: [String: Any] = [:]) {
    var line = fields
    line["event"] = event
    line["ts"] = Date().timeIntervalSince1970
    guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
    FileHandle.standardError.write(data + Data("\n".utf8))
}

public func emitJSON(_ fields: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
