import Foundation
import SwiftLintCore
import TestHelpers
import Testing

@testable import SwiftLintFramework

/// Each test has declarations that satisfy a requirement of a protocol without a reference in the index, next
/// to declarations that nothing uses. A `↓` marks each declaration that is expected to be reported.
@Suite(.serialized, .rulesRegistered)
struct UnusedDeclarationWitnessTests {
    @Test(.temporaryDirectory)
    func witnessCanBeDeclaredInAnotherFileThanItsConformance() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            protocol Shelf {
                func take() -> Int
                var label: String { get }
                var ↓depth: Int { get }
            }

            struct Rack {}

            func ↓inspect(_ shelf: some Shelf) -> Int { shelf.take() + shelf.label.count + Rack().take() }
            """,
            """
            extension Rack {
                func take() -> Int { 1 }
                var label: String { "rack" }
                var depth: Int { 2 }
                func ↓dust() {}
            }
            """,
            "extension Rack: Shelf {}\n",
        ])
    }

    @Test(.temporaryDirectory)
    func defaultImplementationCanSatisfyARequirementOfAnotherProtocol() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            protocol Shelf {
                func take() -> Int
            }

            protocol Labelled {}

            extension Labelled where Self: Shelf {
                func take() -> Int { 1 }
                var ↓caption: String { "caption" }
            }

            func ↓inspect(_ shelf: some Shelf) -> Int { shelf.take() }
            """,
            "struct ↓Jar: Shelf, Labelled {}\n",
        ])
    }

    @Test(.temporaryDirectory)
    func equalityAndHashingCanBeDeclaredInAnotherFileThanTheirConformance() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            struct Card: Hashable {
                var rank: Int
            }
            """,
            """
            extension Card {
                static func == (lhs: Self, rhs: Self) -> Bool { lhs.rank == rhs.rank }
                func hash(into hasher: inout Hasher) { hasher.combine(rank) }
                func ↓flipped() -> Card { self }
            }
            """,
        ])
    }

    // The compiler leaves an extension without members out of the index if it conforms through a composition.
    @Test(.temporaryDirectory, arguments: ["Shelf & Tagged", "TaggedShelf"])
    func witnessCanSatisfyAConformanceThatIsMissingFromTheIndex(inherited: String) throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            protocol Shelf {
                func take() -> Int
                static var capacity: Int { get }
            }

            protocol Tagged: Named {}

            protocol Named {
                var label: String { get }
            }

            typealias TaggedShelf = Shelf & Tagged

            func ↓inspect(_ shelf: some TaggedShelf) -> Int {
                shelf.take() + shelf.label.count + type(of: shelf).capacity + Rack().take() + Crate().label.count
            }
            """,
            """
            extension Rack {
                func take() -> Int { 1 }
                static var capacity: Int { 2 }
                var label: String { "rack" }
                func ↓dust() {}
                var ↓capacity: Int { 3 }
            }

            extension Crate {
                func ↓take() -> Int { 4 }
                var label: String { "crate" }
            }
            """,
            """
            struct Rack {}

            struct Crate {}

            extension Rack: \(inherited) {}
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func witnessOfAMissingConformanceCanComeFromASuperclassOrAProtocolExtension() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            protocol Shelf {
                func ↓take() -> Int
                var ↓label: String { get }
            }

            protocol Tagged {}

            extension Tagged {
                var label: String { "tagged" }
                var ↓colour: String { "red" }
            }

            class Frame {
                func take() -> Int { 1 }
                func ↓fold() {}
            }

            final class ↓Rack: Frame {}

            extension Rack: Shelf & Tagged {}
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func witnessOfAMissingConformanceCanBeAnOperatorAtFileScope() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            infix operator <+>
            infix operator <->

            protocol Joined {
                static func ↓<+> (lhs: Self, rhs: Self) -> Self
            }

            protocol Tagged {}

            struct Label {}

            func <+> (lhs: Label, rhs: Label) -> Label { lhs }

            func ↓<-> (lhs: Label, rhs: Label) -> Label { rhs }

            extension Label: Joined & Tagged {}
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func witnessOfAMissingConformanceCanBeDeclaredInAnExtensionOfATypeAlias() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            protocol Shelf {
                func ↓take() -> Int
            }

            protocol Tagged {}

            typealias Marked = Tagged

            extension Marked {
                func take() -> Int { 1 }
                func ↓dust() {}
            }

            struct ↓Rack {}

            extension Rack: Shelf & Tagged {}
            """,
        ])
    }

    @Test(.temporaryDirectory, arguments: ["Rack<Int>", "IntRack"])
    func missingConformanceCanBeDeclaredForASpecializedType(extended: String) throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            protocol Shelf {
                func ↓take() -> Int
            }

            protocol Tagged {}

            struct Rack<Item> {
                func take() -> Int { 1 }
                func ↓dust() {}
            }

            typealias IntRack = Rack<Int>

            func ↓inspect(_ rack: IntRack) {}
            """,
            "extension \(extended): Shelf & Tagged {}\n",
        ])
    }

    @Test(.temporaryDirectory)
    func typeCanSatisfyAnAssociatedTypeOfAMissingConformance() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            protocol Shelf {
                associatedtype ↓Item
                typealias ↓Depth = Int
            }

            protocol Tagged {}

            struct ↓Rack {}

            extension Rack: Shelf & Tagged {}
            """,
            """
            extension Rack {
                struct Item {}
                struct ↓Depth {}
            }
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func genericArgumentOfAnInheritedTypeIsNotInherited() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            protocol Shelf {}

            protocol Tagged {}

            protocol Priced {
                func ↓price() -> Int
            }

            typealias Stock<Unit> = Shelf & Tagged

            struct ↓Rack {
                func ↓price() -> Int { 1 }
            }

            extension Rack: Stock<Priced> {}
            """,
        ])
    }
}
