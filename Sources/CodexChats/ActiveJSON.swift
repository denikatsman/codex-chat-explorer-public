import Foundation
import CActiveJSON

// Only lifecycle metadata is decoded. Conversation/tool text is skipped in-place.
struct ActiveJSONReader {
    let bytes: Data
    var position = 0
    mutating func whitespace() { while position < bytes.count && [9,10,13,32].contains(bytes[position]) { position += 1 } }
    mutating func skip() throws -> Range<Int> {
        whitespace()
        let start = position
        let end = bytes.withUnsafeBytes { raw in active_json_skip(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, start) }
        guard end > start, end <= bytes.count else { throw StoreError(message: "Malformed live-status frame.") }
        position = end
        return start..<end
    }
    mutating func raw() throws -> Any {
        let range = try skip()
        return try JSONSerialization.jsonObject(with: bytes.subdata(in: range), options: [.fragmentsAllowed])
    }
    mutating func object(_ field: (String, inout ActiveJSONReader) throws -> Any?) throws -> [String: Any] {
        whitespace()
        guard position < bytes.count, bytes[position] == 123 else { _ = try skip(); return [:] }
        position += 1
        var result = [String: Any]()
        while true {
            whitespace()
            guard position < bytes.count else { throw StoreError(message: "Incomplete live-status object.") }
            if bytes[position] == 125 { position += 1; return result }
            guard bytes[position] == 34, let key = try raw() as? String else { throw StoreError(message: "Invalid live-status key.") }
            whitespace()
            guard position < bytes.count, bytes[position] == 58 else { throw StoreError(message: "Invalid live-status colon.") }
            position += 1
            if let value = try field(key, &self) { result[key] = value }
            whitespace()
            guard position < bytes.count else { throw StoreError(message: "Incomplete live-status object.") }
            let separator = bytes[position]; position += 1
            if separator == 125 { return result }
            guard separator == 44 else { throw StoreError(message: "Invalid live-status separator.") }
        }
    }
    mutating func array(_ item: (inout ActiveJSONReader) throws -> Any) throws -> [Any] {
        whitespace()
        guard position < bytes.count, bytes[position] == 91 else { _ = try skip(); return [] }
        position += 1
        var result = [Any]()
        while true {
            whitespace()
            guard position < bytes.count else { throw StoreError(message: "Incomplete live-status array.") }
            if bytes[position] == 93 { position += 1; return result }
            result.append(try item(&self))
            whitespace()
            guard position < bytes.count else { throw StoreError(message: "Incomplete live-status array.") }
            let separator = bytes[position]; position += 1
            if separator == 93 { return result }
            guard separator == 44 else { throw StoreError(message: "Invalid live-status separator.") }
        }
    }
    mutating func turn() throws -> Any {
        try object { key, reader in
            if ["id", "turnId", "status"].contains(key) { return try reader.raw() }
            _ = try reader.skip(); return nil
        }
    }
    mutating func requests() throws -> Any {
        whitespace()
        if position < bytes.count, bytes[position] == 91 { return try array { reader in _ = try reader.skip(); return NSNull() } }
        return try object { _, reader in _ = try reader.skip(); return NSNull() }
    }
    mutating func state() throws -> [String: Any] {
        try object { key, reader in
            switch key {
            case "threadRuntimeStatus": return try reader.raw()
            case "turns": return try reader.array { try $0.turn() }
            case "requests": return try reader.requests()
            default: _ = try reader.skip(); return nil
            }
        }
    }
    mutating func patch() throws -> Any {
        var valueSpan: Range<Int>?
        var patch = try object { key, reader in
            if key == "value" { valueSpan = try reader.skip(); return nil }
            if key == "op" || key == "path" { return try reader.raw() }
            _ = try reader.skip(); return nil
        }
        guard let span = valueSpan else { return patch }
        let end = position; position = span.lowerBound
        let path = patch["path"] as? [Any] ?? []
        let first = path.first as? String
        if path.isEmpty { patch["value"] = try state() }
        else if first == "turns", path.count == 1 { patch["value"] = try array { try $0.turn() } }
        else if first == "turns", path.count == 2 { patch["value"] = try turn() }
        else if first == "requests", path.count == 1 { patch["value"] = try requests() }
        else if first == "threadRuntimeStatus" || (first == "turns" && path.count == 3 && ["id", "turnId", "status"].contains(path[2] as? String ?? "")) { patch["value"] = try raw() }
        position = end
        return patch
    }
    mutating func change() throws -> Any {
        try object { key, reader in
            switch key {
            case "type", "revision", "baseRevision": return try reader.raw()
            case "conversationState": return try reader.state()
            case "patches": return try reader.array { try $0.patch() }
            default: _ = try reader.skip(); return nil
            }
        }
    }
    static func decode(_ bytes: Data, clientID: String?) throws -> [String: Any] {
        var reader = ActiveJSONReader(bytes: bytes)
        var params: Range<Int>?
        var message = try reader.object { key, reader in
            if ["type", "method", "version", "sourceClientId", "targetClientIds", "requestId"].contains(key) { return try reader.raw() }
            if key == "params" { params = try reader.skip(); return nil }
            if key == "result" { return try reader.object { key, reader in
                if key == "clientId" { return try reader.raw() }; _ = try reader.skip(); return nil
            } }
            _ = try reader.skip(); return nil
        }
        reader.whitespace()
        guard reader.position == bytes.count else { throw StoreError(message: "Trailing bytes in live-status frame.") }
        if let clientID, let targets = message["targetClientIds"] as? [String], !targets.contains(clientID) { return [:] }
        if let params {
            reader.position = params.lowerBound
            message["params"] = try reader.object { key, reader in
                if ["hostId", "conversationId", "following", "clientId", "clientType", "status"].contains(key) { return try reader.raw() }
                if key == "change" { return try reader.change() }
                _ = try reader.skip(); return nil
            }
        }
        return message
    }
}
