import Foundation
import SourceKittenFramework
import SwiftLintCore
import TestHelpers
import Testing

@testable import SwiftLintFramework

/// Each test has declarations that are used in a way the index does not record as a reference, next to
/// declarations that nothing uses. A `↓` marks each declaration that is expected to be reported.
@Suite(.serialized, .rulesRegistered)
struct UnusedDeclarationUsageTests {
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
    func defaultImplementationCanSatisfyARequirementOfAnotherModule() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            protocol Labelled: CustomStringConvertible {}

            extension Labelled {
                var description: String { "labelled" }
                var ↓caption: String { "caption" }
            }
            """,
            "struct ↓Jar: Labelled {}\n",
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

    @Test(.temporaryDirectory)
    func entryPointIsFoundInWhatTheMainTypeInheritsFrom() throws {
        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                protocol Tool: Startable {}

                protocol Startable {
                    static func start()
                }

                extension Startable {
                    static func main() { start() }
                    static func ↓stop() {}
                }
                """,
                """
                @main
                struct Entry: Tool {
                    static func start() {}
                }

                enum ↓Other {
                    static func ↓main() {}
                }
                """,
            ],
            compilerFlags: ["-parse-as-library"]
        )
    }

    @Test(.temporaryDirectory)
    func entryPointCanBeDeclaredInAnExtensionOfTheMainType() throws {
        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                @main
                struct Entry {}
                """,
                """
                extension Entry {
                    static func main() {}
                    func ↓main(twice: Bool) {}
                }
                """,
            ],
            compilerFlags: ["-parse-as-library"]
        )
    }

    @Test(.temporaryDirectory)
    func entryPointOfTheMainTypeHidesAnInheritedOne() throws {
        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                protocol Startable {}

                extension Startable {
                    static func ↓main() {}
                }

                @main
                struct Entry: Startable {
                    static func main() {}
                }
                """,
            ],
            compilerFlags: ["-parse-as-library"]
        )
    }

    @Test(.temporaryDirectory, arguments: ["Startable & Tagged", "TaggedTool"])
    func entryPointIsFoundThroughAConformanceThatIsMissingFromTheIndex(inherited: String) throws {
        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                protocol Startable {}

                protocol Tagged {}

                extension Startable {
                    static func main() {}
                    static func ↓stop() {}
                }

                typealias TaggedTool = Startable & Tagged

                func ↓inspect(_ tool: some TaggedTool) {}
                """,
                """
                @main
                struct Entry {}

                extension Entry: \(inherited) {}
                """,
            ],
            compilerFlags: ["-parse-as-library"]
        )
    }

    @Test(.temporaryDirectory)
    func valuesOfAPropertyWrapperAreUsedByTheLanguage() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            @propertyWrapper
            struct Clamped {
                private var stored = 0

                var wrappedValue: Int {
                    get { stored }
                    set { stored = min(max(newValue, 0), 10) }
                }

                var ↓limit: Int { 10 }
            }

            extension Clamped {
                var projectedValue: Bool { true }
                static var ↓wrappedValue: Int { 0 }
            }
            """,
            """
            struct ↓Dial {
                @Clamped var ↓level: Int
                var ↓wrappedValue: Int { 0 }
            }
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func typeNamedLikeAValueOfAPropertyWrapperIsNoSuchValue() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            @propertyWrapper
            struct ↓Clamped {
                var wrappedValue: Int

                struct ↓projectedValue {}
            }
            """,
        ])
    }

    /// Expects `unused_declaration` to report the declarations that follow a `↓` in the sources, and no other.
    /// All sources belong to one module.
    private func expectOnlyMarkedDeclarationsReported(
        in sources: [String],
        compilerFlags: [String] = [],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let files = try sources.enumerated().map { index, source in
            let path = URL.cwd.appending(path: "Input\(index).swift")
            try source.replacingOccurrences(of: "↓", with: "").write(to: path, atomically: true, encoding: .utf8)
            return try #require(SwiftLintFile(path: path, isTestFile: true))
        }
        let configuration = try Configuration(dict: ["only_rules": ["unused_declaration"]])
        let arguments = try #require(files.first).makeCompilerArguments()
            + files.dropFirst().compactMap { $0.path?.filepath }
            + ["-module-name", "UnusedDeclarationUsage"]
            + compilerFlags
        let storage = RuleStorage()
        let collected = files
            .map { Linter(file: $0, configuration: configuration, compilerArguments: arguments) }
            .map { $0.collect(into: storage) }

        let reported = try collected.map { linter in
            var lines = linter.file.lines.map(\.content)
            let locations = linter.styleViolations(using: storage).map(\.location)
            for location in locations.sorted().reversed() {
                let line = try #require(location.line) - 1
                let column = try #require(location.character) - 1
                lines[line].insert("↓", at: lines[line].index(lines[line].startIndex, offsetBy: column))
            }
            return lines.joined(separator: "\n")
        }

        let expected = sources.map { $0.trimmingCharacters(in: .newlines) }
        #expect(reported == expected, sourceLocation: sourceLocation)
    }
}
