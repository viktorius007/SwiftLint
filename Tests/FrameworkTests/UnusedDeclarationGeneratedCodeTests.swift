import Foundation
import SwiftLintCore
import TestHelpers
import Testing

/// Code that the compiler generates for a conformance reads or writes stored properties without a reference in
/// the index. A `↓` marks each declaration that is expected to be reported.
@Suite(.serialized, .rulesRegistered)
struct UnusedDeclarationGeneratedCodeTests {
    @Test(.temporaryDirectory)
    func storedPropertyOfAStructIsReadByGeneratedEqualityAndHashing() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            struct Key: Hashable {
                var name = "a"
                var ↓computed: Int { 1 }
                static let ↓shared = 2
                lazy var ↓cached = 3
            }

            struct Point: Equatable {
                var column = 1
            }

            // What `Comparable` inherits from is told by SourceKit only.
            struct Ordered: Comparable {
                var rank = 1
                var note = ""

                static func < (lhs: Ordered, rhs: Ordered) -> Bool { lhs.rank < rhs.rank }
            }

            print(Set([Key(), Key()]).count, Point() == Point(), Ordered() == Ordered())
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func storedPropertyIsNotReadByEqualityOrHashingThatADeclarationReplaces() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            struct Own: Equatable {
                var ↓spare = 1

                static func == (_: Own, _: Own) -> Bool { true }
            }

            struct AtFileScope: Equatable {
                var ↓spare = 1
            }

            func == (_: AtFileScope, _: AtFileScope) -> Bool { true }

            protocol Entity: Equatable {
                var id: Int { get }
            }

            extension Entity {
                static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
            }

            struct User: Entity {
                var id = 1
                var ↓spare = ""
            }

            struct OldHash: Hashable {
                var ↓spare = 1
                var hashValue: Int { 0 }

                static func == (_: OldHash, _: OldHash) -> Bool { true }
            }

            struct OwnBoth: Hashable {
                var ↓spare = 1

                static func == (_: OwnBoth, _: OwnBoth) -> Bool { true }
                func hash(into _: inout Hasher) {}
            }

            print(Own() == Own(), AtFileScope() == AtFileScope(), User() == User(), OldHash() == OldHash(),
                  OwnBoth() == OwnBoth())
            """,
        ])
    }

    // The standard library declares how values with a raw value compare and hash.
    @Test(.temporaryDirectory)
    func storedPropertyIsNotReadByEqualityOrHashingThatAnotherModuleDeclares() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            struct Flag: RawRepresentable, Equatable {
                var rawValue: Int
                var ↓spare = 1

                init(rawValue: Int) { self.rawValue = rawValue }
            }

            struct Coded: Hashable {
                var rawValue: Int
                var ↓spare = 1

                init(rawValue: Int) { self.rawValue = rawValue }
            }

            extension Coded: RawRepresentable {}

            print(Flag(rawValue: 1) == Flag(rawValue: 1), Coded(rawValue: 1) == Coded(rawValue: 1))
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func storedPropertyIsReadByTheOneOfEqualityAndHashingThatIsGenerated() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            struct OwnHashing: Hashable {
                var spare = 1

                func hash(into _: inout Hasher) {}
            }

            struct OwnEquality: Hashable {
                var spare = 1

                static func == (_: OwnEquality, _: OwnEquality) -> Bool { true }
            }

            print(OwnHashing() == OwnHashing(), OwnEquality() == OwnEquality())
            """,
        ])
    }

    // The compiler generates neither for a class. A subclass inherits what its superclass declares. For `Node`
    // and `Entry`, neither the index nor SourceKit tells which declaration satisfies the requirement.
    @Test(.temporaryDirectory)
    func storedPropertyOfAClassIsNotReadByEqualityOrHashing() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            class Base: Equatable {
                static func == (_: Base, _: Base) -> Bool { true }
            }

            final class Leaf: Base {
                var ↓spare = 1
            }

            protocol Marker {}
            protocol Keyed {}

            extension Keyed {
                var hashValue: Int { 0 }

                func hash(into _: inout Hasher) {}
            }

            final class Node {
                var ↓spare = 1
            }

            func == (_: Node, _: Node) -> Bool { true }

            extension Node: Equatable & Marker {}

            final class Entry: Keyed {
                var ↓spare = 1

                static func == (_: Entry, _: Entry) -> Bool { true }
            }

            extension Entry: Hashable & Marker {}

            print(Leaf() == Leaf(), Node() == Node(), Entry() == Entry())
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func equalityAndHashingAreFoundForAnExtensionMissingFromTheIndex() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            struct Pair {
                var ↓spare = 1

                static func == (_: Pair, _: Pair) -> Bool { true }
            }

            extension Pair: Equatable & Sendable {}

            struct Hashed {
                var spare = 1
                var hashValue: Int { 0 }

                func hash(into _: inout Hasher) {}
            }

            extension Hashed: Hashable & Sendable {}

            struct Tagged {
                var ↓spare = 1
                var hashValue: Int { 0 }

                static func == (_: Tagged, _: Tagged) -> Bool { true }
            }

            extension Tagged: Hashable & Sendable {}

            struct Mixed {
                var ↓spare = 1

                static func == (_: Mixed, _: Mixed) -> Bool { true }
                func hash(into _: inout Hasher) {}
            }

            extension Mixed: Hashable & Sendable {}

            struct Generated {
                var value = 1
            }

            extension Generated: Hashable & Sendable {}

            print(Pair() == Pair(), Hashed() == Hashed(), Tagged() == Tagged(), Mixed() == Mixed(),
                  Generated() == Generated())
            """,
        ])
    }

    // With one of `hash(into:)` and `hashValue` declared, the compiler generates the other one in the extension,
    // and the index has the extension. It leaves the extension out if a protocol gives the other one.
    @Test(.temporaryDirectory)
    func eachDeclarationOfHashingIsFoundForAnExtensionMissingFromTheIndex() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            protocol Keyed {}
            protocol Valued {}

            extension Keyed {
                func hash(into _: inout Hasher) {}
            }

            extension Valued {
                var hashValue: Int { 0 }
            }

            struct Slot: Keyed {
                var ↓spare = 1
                var hashValue: Int { 0 }

                static func == (_: Slot, _: Slot) -> Bool { true }
            }

            extension Slot: Hashable & Sendable {}

            struct Dial: Valued {
                var ↓spare = 1

                static func == (_: Dial, _: Dial) -> Bool { true }
                func hash(into _: inout Hasher) {}
            }

            extension Dial: Hashable & Sendable {}

            print(Slot() == Slot(), Dial() == Dial())
            """,
        ])
    }

    // The compiler warns that such a constant "will not be decoded because it is declared with an initial value
    // which cannot be overwritten".
    @Test(.temporaryDirectory)
    func constantWithAnInitialValueIsNotWrittenByGeneratedDecoding() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            struct Inbound: Decodable {
                let ↓fixed = 1
                let ↓typed: Int = 2, ↓other = 3
                let given: Int
                var changed = 4
            }

            struct Outbound: Encodable {
                let fixed = 1
            }

            struct Both: Codable {
                let fixed = 1
            }

            final class Reference: Decodable {
                let (↓first, ↓second) = (1, 2)
            }

            print(Inbound.self, Outbound(), Both(), Reference.self)
            """,
        ])
    }

    #if !os(Windows)
    @Test(.temporaryDirectory)
    func constantWithAnInitialValueIsNotWrittenByDecodingGeneratedThroughAProtocolOfAnotherModule() throws {
        try compileModule(named: "Vendor", source: "public protocol Inbound: Decodable {}")
        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                import Vendor

                struct Blank: Inbound {
                    let ↓fixed = 1
                    var changed = 2
                }

                print(Blank.self)
                """,
            ],
            compilerFlags: ["-I", URL.cwd.filepath]
        )
    }
    #endif
}
