import Foundation
import SwiftLintCore
import TestHelpers
import Testing

@testable import SwiftLintFramework

// A type marked `@main` that inherits from a type that no linted file declares can find its `main()` through
// what that type inherits from. That is known in part only, so every `main()` counts as an entry point then.

#if !os(Windows)
@Suite(.serialized, .rulesRegistered)
struct UnusedDeclarationImportedEntryPointTests {
    @Test(.temporaryDirectory)
    func entryPointIsFoundThroughTheSuperclassOfAClassThatNoFileDeclares() throws {
        try compileModule(named: "Vendor", source: """
            open class Root { public init() {} }
            open class Middle: Root {}
            """)

        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                import Vendor

                extension Root {
                    static func main() { print("started") }
                    static func ↓leftover() {}
                }

                @main final class Entry: Middle {}
                """,
            ],
            compilerFlags: ["-parse-as-library", "-I", URL.cwd.filepath]
        )
    }

    @Test(.temporaryDirectory)
    func entryPointIsFoundThroughAProtocolThatAnExtensionMissingFromTheIndexNames() throws {
        try compileModule(named: "Vendor", source: """
            public protocol Startable {}
            public protocol Tool: Startable {}
            """)

        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                import Vendor

                protocol Marker {}

                extension Startable {
                    static func main() { print("started") }
                    static func ↓leftover() {}
                }

                @main struct Entry {}
                extension Entry: Tool & Marker {}
                """,
            ],
            compilerFlags: ["-parse-as-library", "-I", URL.cwd.filepath]
        )
    }

    // `Middle` inherits from `Root`, and no linted file tells so.
    @Test(.temporaryDirectory)
    func entryPointIsFoundInATypeOfALintedFileThroughAClassThatNoFileDeclares() throws {
        try compileModule(named: "Base", source: "open class Root { public init() {} }")
        let searchPath = ["-I", URL.cwd.filepath]
        try compileModule(named: "Vendor", source: """
            import Base
            open class Middle: Root {}
            """, flags: searchPath)
        let appPath = URL.cwd.appending(path: "App.swift")
        try """
            import Base
            import Vendor

            extension Root {
                static func main() { print("started") }
                static func leftover() {}
            }

            @main final class Entry: Middle {}
            """.write(to: appPath, atomically: true, encoding: .utf8)
        let base = try #require(SwiftLintFile(path: URL.cwd.appending(path: "Base.swift"), isTestFile: true))
        let app = try #require(SwiftLintFile(path: appPath, isTestFile: true))

        let configuration = try Configuration(dict: ["only_rules": ["unused_declaration"]])
        let storage = RuleStorage()
        let flags = ["-parse-as-library", "-module-name"]
        let linters = [
            Linter(file: base, configuration: configuration,
                   compilerArguments: base.makeCompilerArguments() + flags + ["Base"]),
            Linter(file: app, configuration: configuration,
                   compilerArguments: app.makeCompilerArguments() + flags + ["App"] + searchPath),
        ].map { $0.collect(into: storage) }
        let reported = linters.flatMap { $0.styleViolations(using: storage) }.map(\.location.line)
        #expect(reported == [6])
    }

    // A limit: `Other` is unused, and whether `Middle` inherits from it is not known.
    @Test(.temporaryDirectory)
    func mainOfEveryTypeCountsAsEntryPointWhereTheMainTypeInheritsFromATypeThatNoFileDeclares() throws {
        try compileModule(named: "Vendor", source: "open class Middle { public init() {} }")

        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                import Vendor

                enum ↓Other {
                    static func main() {}
                    static func ↓leftover() {}
                    static func ↓main(twice: Bool) {}
                }

                @main final class Entry: Middle {
                    static func main() { print("started") }
                }
                """,
            ],
            compilerFlags: ["-parse-as-library", "-I", URL.cwd.filepath]
        )
    }

    // Of `Sendable` and the other protocols that the compiler knows, nothing is inherited that could be `main()`.
    @Test(.temporaryDirectory)
    func mainOfAnotherTypeIsReportedWhereTheMainTypeInheritsFromDeclaredAndKnownTypesOnly() throws {
        try compileModule(named: "Vendor", source: "open class Middle { public init() {} }")

        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                import Vendor

                protocol Tool: Sendable {}

                enum ↓Other {
                    static func ↓main() {}
                }

                extension Middle {
                    static func ↓main() {}
                }

                @main struct Entry: Tool, Codable {
                    static func main() { print("started") }
                }
                """,
            ],
            compilerFlags: ["-parse-as-library", "-I", URL.cwd.filepath]
        )
    }

    @Test(.temporaryDirectory)
    func mainOfATypeThatNoFileDeclaresIsNoEntryPointWithoutAMainType() throws {
        try compileModule(named: "Vendor", source: "open class Root { public init() {} }")

        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                import Vendor

                extension Root {
                    static func ↓main() {}
                }

                final class ↓Entry: Root {}
                """,
            ],
            compilerFlags: ["-parse-as-library", "-I", URL.cwd.filepath]
        )
    }
}
#endif
