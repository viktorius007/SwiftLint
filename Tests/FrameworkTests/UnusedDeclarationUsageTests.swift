import Foundation
import SourceKittenFramework
import SwiftLintCore
import TestHelpers
import Testing

@testable import SwiftLintFramework

/// Each test has declarations that the language uses without a reference in the index, next to declarations
/// that nothing uses. A `↓` marks each declaration that is expected to be reported.
@Suite(.serialized, .rulesRegistered)
struct UnusedDeclarationUsageTests {
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

    // Which `main()` the language calls is not known, so the one of the main type is kept as well.
    @Test(.temporaryDirectory)
    func entryPointIsFoundAlthoughTheMainTypeDeclaresAMainThatCannotBeOne() throws {
        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                protocol Startable {}

                extension Startable {
                    static func main() {}
                    static func ↓stop() {}
                }

                @main
                struct Entry: Startable {
                    static func main() -> Int { 1 }
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
}

/// Expects `unused_declaration` to report the declarations that follow a `↓` in the sources, and no other.
/// All sources belong to one module.
func expectOnlyMarkedDeclarationsReported(
    in sources: [String],
    compilerFlags: [String] = [],
    sourceLocation: Testing.SourceLocation = #_sourceLocation
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
