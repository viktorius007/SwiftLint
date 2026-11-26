import Foundation
import SourceKittenFramework
import SwiftLintCore
import TestHelpers
import Testing

@testable import SwiftLintFramework

/// Each test has declarations that the language uses without a reference in the index, next to declarations
/// that nothing uses. A `↓` marks each declaration that is expected to be reported.
@Suite(.serialized, .rulesRegistered, .ownThreads)
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

    // The language calls the entry from code that the index does not have.
    @Test(.temporaryDirectory, arguments: ["", " async", " throws", " async throws"])
    func entryPointThatTheMainTypeDeclaresIsUsed(effects: String) throws {
        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                @main
                enum Tool {
                    static func main()\(effects) {
                        print(helper())
                    }

                    static func helper() -> Int { 1 }

                    static func ↓leftover() {}
                }
                """,
                """
                enum ↓Other {
                    static func ↓main()\(effects) {}
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
    func storedPropertiesAreUsedByTheCodingThatTheCompilerGenerates() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            struct ↓Reading: Decodable {
                let level: Int
                var unit: String
                var ↓doubled: Int { 2 }
                static let ↓limit = 10
            }

            struct ↓Receipt: Encodable {
                var total: Int
                lazy var ↓doubled = 2
            }

            struct ↓Packet: Payload {
                var size: Int
            }

            struct ↓Label {
                var text: String
            }

            extension Label: Codable {}

            struct ↓Plain {
                var ↓size: Int
            }
            """,
            """
            protocol Payload: Codable {}

            struct ↓Parsed: Decodable {
                let digits: Int

                init(from _: String) {
                    digits = 1
                }
            }
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func storedPropertiesAreNotUsedByCodingThatIsDeclared() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            struct ↓Manual: Decodable {
                let first: Int
                let ↓spare = 0
            }

            struct ↓Written: Codable {
                var ↓count = 0

                init(from _: any Decoder) throws {}

                func encode(to _: any Encoder) throws {}
            }

            struct ↓Half: Codable {
                var count = 0

                func encode(to _: any Encoder) throws {}
            }

            class Base: Codable {
                var id = 0
            }

            final class ↓Derived: Base {
                var ↓extra = 0
            }
            """,
            """
            extension Manual {
                init(from _: any Decoder) throws {
                    first = 1
                }
            }

            protocol Fixed: Decodable {}

            extension Fixed {
                init(from _: any Decoder) throws {
                    fatalError("not decoded")
                }
            }

            struct ↓Constant: Fixed {
                var ↓value = 0
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

    @Test(.temporaryDirectory)
    func declarationWithANameForObjectiveCIsUsedThroughThatName() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Foundation

            final class Backing: NSObject {
                @objc func plain() {}
                @objc(renamedObject) func renamed() {}
                @objc(setValue:forName:) func set(value _: Int, name _: String) {}
                @objc(storedCount) var count = 0
                func ↓leftover() {}
            }

            @objc(RenamedProvider) final class Provider: NSObject {}

            func ↓mentions(text _: String = "@objc(name) @objc and <name>@objc</name>") {}

            _ = Backing()
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
