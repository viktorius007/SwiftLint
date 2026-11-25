import Foundation
import SourceKittenFramework
import SwiftLintCore
import TestHelpers
import Testing

@testable import SwiftLintFramework

/// Each test has declarations that are used in a way the index does not record as a reference, next to
/// declarations that nothing uses. A `↓` marks each declaration that is expected to be reported.
@Suite(.rulesRegistered)
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
                var projectedValue: Bool { wrappedValue == 10 }
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
