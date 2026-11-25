import Foundation

/// Reads the start of a mangled Swift name, as far as needed to tell which module it names.
struct MangledName {
    private let bytes: [UInt8]
    private var position = 0

    private init(usr: String) {
        bytes = Array(usr.utf8.dropFirst(2))
    }

    /// Whether a Swift USR names a module the way the USR of a declaration of that module does: at its start, or
    /// as the module of an extension of a top-level type. Only these positions count. The name of a declaration
    /// can contain any text, also text that looks like a module.
    static func usr(_ usr: String, names module: String) -> Bool {
        switch module {
        case "Swift":
            // The standard library and its common types are abbreviated. `So` and `SC` stand for C modules.
            return usr.hasPrefix("s:s") || usr.hasPrefix("s:S") && !usr.hasPrefix("s:So") && !usr.hasPrefix("s:SC")
        case "_Concurrency":
            return usr.hasPrefix("s:Sc")
        default:
            var name = Self(usr: usr)
            if name.readIdentifier() == module {
                return true
            }
            name = Self(usr: usr)
            return name.skipTopLevelType() && name.readIdentifier() == module && name.read("E")
        }
    }

    /// Reads an identifier, which is written as its length followed by its text.
    private mutating func readIdentifier() -> String? {
        var length = 0
        let start = position
        while position < bytes.count, bytes[position] >= 0x30, bytes[position] <= 0x39, length <= bytes.count {
            // A leading zero marks an identifier with substituted words, which is not read here.
            if position == start, bytes[position] == 0x30 {
                return nil
            }
            length = length * 10 + Int(bytes[position] - 0x30)
            position += 1
        }
        guard position > start, position + length <= bytes.count else {
            return nil
        }
        defer { position += length }
        return String(bytes: bytes[position..<position + length], encoding: .utf8)
    }

    private mutating func read(_ text: String) -> Bool {
        guard bytes.dropFirst(position).starts(with: text.utf8) else {
            return false
        }
        position += text.utf8.count
        return true
    }

    /// Skips a type that an extension can extend: an abbreviated standard library type, or a type declared at the
    /// top level of a module.
    private mutating func skipTopLevelType() -> Bool {
        if read("So") || read("SC") || read("s") || readIdentifier() != nil {
            return readIdentifier() != nil && ["V", "C", "O", "P"].contains { read($0) }
        }
        guard read("S"), position < bytes.count else {
            return false
        }
        position += 1
        return true
    }
}
