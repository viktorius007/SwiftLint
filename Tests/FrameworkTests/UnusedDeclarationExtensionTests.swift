import Foundation
import SwiftLintCore
import TestHelpers
import Testing

@testable import SwiftLintBuiltInRules
@testable import SwiftLintFramework

/// What the header of an extension names: the index lists it among the entities of the extension.
@Suite(.serialized, .rulesRegistered)
struct UnusedDeclarationExtensionTests {
    @Test(.temporaryDirectory)
    func extensionDoesNotUseTheTypeItExtends() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            struct ↓Plain {}
            extension Plain {
                func ↓leftover() {}
            }
            enum ↓Outer {
                struct ↓Inner {}
            }
            extension Outer.Inner {
                func ↓leftover() {}
            }
            struct ↓Box<Value> {}
            extension Box where Value: Equatable {
                func ↓leftover() {}
            }
            """,
        ])
    }

    // A limit: `Second` is not used. The index lists it before the position of the extension, like a generic
    // argument of a header that is written without the name of the extended type.
    @Test(.temporaryDirectory)
    func extensionUsesTheTypesBetweenTheFirstAndTheLastOfItsHeader() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            enum ↓First {
                enum Second {
                    enum ↓Third {}
                }
            }
            extension First.Second.Third {
                func ↓leftover() {}
            }
            """,
        ])
    }

    // The extension is of the type that the alias stands for, and it needs the alias to be written.
    @Test(.temporaryDirectory)
    func extensionUsesTheTypeAliasInItsHeader() throws {
        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                struct Checks {}
                typealias Cases = Checks
                typealias ↓Leftover = Checks
                extension Cases {
                    static func start() { print("started") }
                }
                enum Space {
                    typealias Short = Checks
                }
                extension Space.Short {
                    static func stop() { print("stopped") }
                }

                @main enum Entry {
                    static func main() {
                        Checks.start()
                        Checks.stop()
                    }
                }
                """,
            ],
            compilerFlags: ["-parse-as-library"]
        )
    }

    // The extension is of `Inner`, and it needs the alias for the type around `Inner` to be written.
    @Test(.temporaryDirectory)
    func extensionUsesATypeAliasThatQualifiesItsHeader() throws {
        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                enum Outer {
                    struct Inner {}
                }
                typealias Alias = Outer
                typealias ↓Leftover = Outer
                extension Alias.Inner {
                    static func start() { print("started") }
                }

                @main enum Entry {
                    static func main() { Outer.Inner.start() }
                }
                """,
            ],
            compilerFlags: ["-parse-as-library"]
        )
    }

    // A limit: the index lacks an extension without members, also without generated ones, if none of its inherited
    // types is a single protocol or class, and lists what its header names at file scope. There, the name that the
    // header starts with is no use unless it is a type alias, and every other name is one, also the last one, which
    // is the extended type.
    @Test(.temporaryDirectory)
    func headerOfAnExtensionThatTheIndexLacksUsesAllButATypeThatItStartsWith() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            struct ↓Plain {}
            extension Plain {}
            enum ↓First {
                enum Second {
                    enum Third {}
                }
            }
            extension First.Second.Third {}
            struct ↓Wrapped {}
            extension Wrapped? {}
            struct Element {}
            extension [Element] {}
            struct Actual {}
            typealias Alias = Actual
            extension Alias {}
            """,
        ])
    }

    // The index has an extension without members that inherits from a single protocol, and one for which the
    // compiler generates a member, as `==` for `Compared`.
    @Test(.temporaryDirectory)
    func extensionWithoutMembersThatTheIndexHasDoesNotUseTheTypeItExtends() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            protocol Marker {}
            enum ↓Outer {
                struct ↓Inner {}
            }
            extension Outer.Inner: Marker {}
            struct Wrapped {}
            extension Wrapped?: Marker {}
            struct ↓Compared {
                var field = 0
            }
            extension Compared: Equatable & Marker {}
            """,
        ])
    }

    // A limit: the index places the extension of `(Record)` at the parenthesis, before `Record`. So `Record`
    // counts as used, and `main()` is not known as a member of `Entry`.
    @Test(.temporaryDirectory)
    func headerInParenthesesUsesWhatItNamesAndTheTypeOfItsMembersIsNotKnown() throws {
        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                struct Record {}
                extension (Record) {
                    func ↓leftover() {}
                }

                @main enum Entry {}
                extension (Entry) {
                    static func ↓main() { print("started") }
                }
                """,
            ],
            compilerFlags: ["-parse-as-library"]
        )
    }

    // The index places the extension of `Record?` at the question mark, after `Record`.
    @Test(.temporaryDirectory, arguments: [
        ("Record?", "Optional"), ("[Record]", "Array"), ("[String: Record]", "Dictionary"),
    ])
    func extensionUsesTheTypesInAHeaderWrittenWithoutTheExtendedType(header: String, extended: String) throws {
        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                struct Record {}
                struct ↓Leftover {}

                extension \(header) {
                    static func start() { print("started") }
                }

                @main enum Entry {
                    static func main() { \(extended).start() }
                }
                """,
            ],
            compilerFlags: ["-parse-as-library"]
        )
    }

    // The index tells the kind of what an extension extends, and `Record` is of the same kind as `Box`.
    @Test(.temporaryDirectory, arguments: ["struct", "enum", "final class"], [
        "extension Box where Value == Record",
        "extension Box<Record>",
    ])
    func extensionUsesTheTypesThatConstrainIt(kind: String, header: String) throws {
        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                \(kind) Record {}
                \(kind) ↓Leftover {}
                \(kind) Box<Value> {}

                \(header) {
                    static func start() { print("started") }
                }

                @main enum Entry {
                    static func main() { Box.start() }
                }
                """,
            ],
            compilerFlags: ["-parse-as-library"]
        )
    }

    // The code that `@Test` expands to names the type of a test in an extension as the header of the extension
    // does. The index for analyzer rules lacks that code.
    @Test(.temporaryDirectory)
    func whatTheHeaderOfAnExtensionWithATestNamesIsUsedByIt() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            struct Checks {}
            typealias TestCases = Checks
            extension TestCases {
                @Test func runs() {}
            }
            enum Space {
                enum Group {}
                enum ↓Other {}
            }
            extension Space.Group {
                struct Cases {
                    @Test func runs() {}
                }
            }
            """,
        ])
    }

    // The index lists what an attribute of a member names among the entities of the extension, like the type
    // that the extension extends.
    @Test(.temporaryDirectory, arguments: [
        ("static let values = [1]", "Checks", "@Test(arguments: Options.values) func runs(value: Int) {}"),
        ("static let enabled = true", "↓Checks", "@Suite(.enabled(if: Options.enabled)) struct SuiteChecks {}"),
    ])
    func argumentOfAnAttributeInAnExtensionUsesWhatItNames(options: String, checks: String, member: String) throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            struct Options { \(options) }
            struct \(checks) {}

            extension Checks {
                \(member)
            }
            """,
        ])
    }

    // What declares `Inner` is compiled with the linted files and not linted itself, like generated code.
    @Test(.temporaryDirectory)
    func typeAroundTheTypeOfATestIsUsedWhereNoLintedFileDeclaresTheTypeOfTheTest() throws {
        let sources = [
            "Outer.swift": "enum Outer {}\nenum Unused {}\n",
            "Generated.swift": "extension Outer { struct Inner {} }\n",
            "Checks.swift": "import Testing\nextension Outer.Inner {\n    @Test func runs() {}\n}\n",
        ]
        for (name, source) in sources {
            try source.write(to: URL.cwd.appending(path: name), atomically: true, encoding: .utf8)
        }
        let linted = try ["Outer.swift", "Checks.swift"].map { name in
            try #require(SwiftLintFile(path: URL.cwd.appending(path: name), isTestFile: true))
        }
        let arguments = try #require(linted.first).makeCompilerArguments()
            + ["Checks.swift", "Generated.swift"].map { URL.cwd.appending(path: $0).filepath }
            + ["-module-name", "Sample"]
        let configuration = try Configuration(dict: ["only_rules": ["unused_declaration"]])
        let storage = RuleStorage()
        let linters = linted.map {
            Linter(file: $0, configuration: configuration, compilerArguments: arguments).collect(into: storage)
        }
        let reported = linters.flatMap { $0.styleViolations(using: storage) }.map(\.location.line)
        #expect(reported == [2])
    }

    @Test(.temporaryDirectory)
    func headerOfAnExtensionNamesWhatTheIndexListsUpToThePositionOfTheExtension() throws {
        let extended = try indexedExtension(of: "struct", in: """
            enum Outer {
                struct Box<Value> {}
            }
            struct Record {}
            extension Outer.Box where Value == Record {
                static func start() {}
            }
            """)
        let named = extended.entities.filter(extended.isExtension(namedWith:))
        #expect(Set(named.compactMap(\.name)) == ["Outer", "Box"])
        #expect(extended.entities.contains { $0.name == "Record" })
    }

    #if os(Linux)
    // An extension that a macro expands to has all its references at the position of the macro's attribute.
    @Test(.temporaryDirectory)
    func onlyTheReferenceOfItsKindIsTheExtendedTypeOfAnExtensionThatAMacroExpandsTo() throws {
        let expanded = try indexedExtension(of: "class", in: "import Observation\n\n@Observable final class Model {}\n")
        let references = expanded.entities.filter { $0.line == expanded.line && $0.column == expanded.column }
        #expect(references.contains { $0.kind == "source.lang.swift.ref.protocol" })
        #expect(references.filter(expanded.extends(reference:)).map(\.kind) == ["source.lang.swift.ref.class"])
    }
    #endif

    /// Returns the extension of a type of the given kind from the index of the source.
    private func indexedExtension(of kind: String, in source: String) throws -> SourceKittenDictionary {
        let path = URL.cwd.appending(path: "Extended.swift")
        try source.write(to: path, atomically: true, encoding: .utf8)
        let file = try #require(SwiftLintFile(path: path, isTestFile: true))
        let index = try #require(CurrentRule.$allowSourceKitRequestWithoutRule.withValue(true) {
            file.index(compilerArguments: file.makeCompilerArguments() + ["-module-name", "Sample"])
        })
        return try #require(index.entities.first { $0.kind == "source.lang.swift.decl.extension.\(kind)" })
    }
}
