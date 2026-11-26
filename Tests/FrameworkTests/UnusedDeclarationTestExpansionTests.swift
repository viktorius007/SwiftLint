import Foundation
import SwiftLintCore
import TestHelpers
import Testing

/// What the code names that `@Test` expands to, apart from the type of the test: the index for analyzer rules
/// lacks that code.
@Suite(.serialized, .rulesRegistered)
struct UnusedDeclarationTestExpansionTests {
    // The code that `@Test` expands to calls the test by its name, and the compiler chooses what that call runs: it
    // can be a function marked `async`, one with a parameter that has a default value, or an inherited member. A
    // limit: which one it chooses is not known, so every declaration with the name of a test and of its kind
    // counts as used, whatever its labels, in the type of the test and in what it inherits from.
    @Test(.temporaryDirectory)
    func declarationThatTheCallOfATestCanChooseIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            @Test func example() {}
            func example(times: Int = 1) async {}
            @Test func elsewhere() {}
            func ↓leftover() async {}

            class Base {
                func runs() async {}
                var stored: () async -> Void = {}
                class func shared() async {}
                static func ↓runs() {}
                func ↓leftover() async {}
            }
            final class Checks: Base {
                @Test func runs() {}
                @Test func stored() {}
                @Test static func shared() {}
            }

            protocol Shared {}
            extension Shared {
                func runs(times: Int = 1) async {}
                func ↓stored() async {}
                var ↓leftover: Int { 0 }
            }
            struct Split: Shared {
                @Test func runs() {}
            }
            """,
            """
            func elsewhere() async {}
            func ↓runs() async {}
            func ↓shared() async {}

            extension Split {
                func runs(times: Int) async {}
                static func ↓runs(times: Int) async {}
            }
            struct ↓Other {
                func ↓runs() async {}
                var ↓stored: () async -> Void { {} }
            }
            """,
        ])
    }

    // Of a static test and an inherited type or type alias of its name, the call chooses the initializer of the
    // type.
    @Test(.temporaryDirectory)
    func typeThatTheCallOfAStaticTestCanChooseIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            class Base {
                struct shared {
                    init() async {}
                }
                struct ↓runs {
                    init() async {}
                }
                struct ↓leftover {}
            }
            final class Checks: Base {
                @Test static func shared() {}
                @Test func runs() {}
            }
            struct ↓Other {
                struct ↓shared {}
            }

            protocol Shared {
                typealias build = Builder
                typealias ↓leftover = Builder
            }
            struct Builder {
                init() async {}
            }
            struct Split: Shared {
                @Test static func build() {}
            }
            """,
        ])
    }

    // An enum is `Hashable` and an actor is an `Actor` without naming these protocols, and the index does not
    // list them as inherited.
    @Test(.temporaryDirectory)
    func memberOfAProtocolThatATypeConformsToWithoutNamingItIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            extension Hashable {
                static func runs() async {}
                static func ↓leftover() async {}
            }
            extension Actor {
                func runs() async {}
                func ↓leftover() async {}
            }
            enum Cases {
                case first
                @Test static func runs() {}
            }
            actor Isolated {
                @Test func runs() {}
            }
            """,
        ])
    }

    #if !os(Windows)
    // A limit: what a type that no linted file declares inherits from is known in part only, here not that
    // `Middle` inherits from `Root`. So the test stands for its name in every type.
    @Test(.temporaryDirectory)
    func testStandsForItsNameInEveryTypeWhereItsTypeInheritsFromATypeThatNoFileDeclares() throws {
        try compileModule(named: "Vendor", source: """
            open class Root { public init() {} }
            open class Middle: Root {}
            """)

        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                import Testing
                import Vendor

                extension Root {
                    func runs() async {}
                    func ↓leftover() async {}
                }
                final class Checks: Middle {
                    @Test func runs() {}
                }
                struct ↓Other {
                    func runs(times: Int) {}
                    static func ↓runs() {}
                }
                """,
            ],
            compilerFlags: ["-parse-as-library", "-I", URL.cwd.filepath]
        )
    }
    #endif

    // A limit: the type that an extension with a header in parentheses extends is not known.
    @Test(.temporaryDirectory)
    func testStandsForItsNameInEveryTypeWhereItsTypeIsNotKnown() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            struct Checks {}
            extension (Checks) {
                @Test func runs() {}
            }
            struct ↓Other {
                func runs(times: Int) {}
                static func ↓runs() {}
            }
            """,
        ])
    }

    // The code that `@Test` expands to writes `Void`. A limit: what that name reaches from the place of a test is
    // not known, so every type and type alias of that name counts as used where a linted file has a test.
    @Test(.temporaryDirectory, arguments: [
        ("@Test func runs() {}", "Checks", "Void"),
        ("func ↓runs() {}", "↓Checks", "↓Void"),
    ])
    func typeNamedVoidIsUsedWhereALintedFileHasATest(member: String, checks: String, void: String) throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            struct \(checks) {
                typealias \(void) = ()
                \(member)
            }
            """,
            """
            typealias \(void) = ()
            typealias ↓Leftover = ()
            """,
        ])
    }
}
