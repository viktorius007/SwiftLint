import Foundation
import SwiftLintCore
import TestHelpers
import Testing

/// What the code names that `@Test` expands to, apart from the type of the test: the index for analyzer rules
/// lacks that code.
@Suite(.serialized, .rulesRegistered, .ownThreads)
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

    // Of a test at file scope and a variable of its name whose value can be called, the call chooses the
    // variable where the test fits less, here because the value is `async`.
    @Test(.temporaryDirectory)
    func variableAtFileScopeThatTheCallOfATestCanChooseIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            private let runs: (Int) async -> Void = { _ in }
            @Test(arguments: [1]) func runs(_ number: Int) {}
            private let ↓leftover: (Int) async -> Void = { _ in }
            """,
        ])
    }

    // The code that `@Test` expands to makes the value that it calls the test on by calling the name of the type
    // of the test. Here that call chooses the function of that name at file scope, and the test that then runs
    // is the one of `Other`. A limit: the type that such a function returns is not known, so the test stands for
    // its name in every type. Another limit: `Outer.Nested()` cannot choose a function at file scope, and the
    // function `Nested` counts like the others. The call of a static test starts with `Checks.`, which names
    // the type.
    @Test(.temporaryDirectory)
    func functionWithTheNameOfTheTypeOfATestCanMakeTheValueThatTheTestIsCalledOn() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            struct Checks {
                @Test func runs() {}
                @Test static func shared() {}
            }
            private func Checks(_ number: Int = 1) async -> Other { Other() }
            struct Other {
                func runs() {}
                func stored() {}
                func nests() {}
                func ↓leftover() {}
                func ↓Plain() async {}
                static func ↓runs() {}
                static func ↓shared() {}
            }
            struct Split {}
            extension Split {
                @Test func stored() {}
            }
            struct Plain {
                @Test func leftover() {}
            }
            struct Fixed {
                @Test static func fixes() {}
            }
            struct Outer {
                struct Nested {
                    @Test func nests() {}
                }
            }
            """,
            """
            func Split(_ number: Int = 1) async -> Other { Other() }
            func ↓Plane() async -> Other { Other() }
            func ↓Fixed() async -> Other { Other() }
            func Nested() async -> Other { Other() }
            """,
        ])
    }

    // The name that the call starts with is the one that the source around the test has for the type: in an
    // extension, the one of its header, here a type alias. The function can be public, and its name can hold
    // parentheses. A variable at file scope can have the name of a nested type only, and `Outer.Inner()` cannot
    // choose it.
    @Test(.temporaryDirectory)
    func functionThatMakesTheValueHasTheNameOfTheTypeAsTheSourceAroundTheTestHasIt() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            struct Original {}
            typealias Alias = Original
            extension Alias {
                @Test func runs() {}
            }
            private func Alias(_ number: Int = 1) async -> Other { Other() }
            func ↓Original() async -> Other { Other() }

            struct Open {
                @Test func stored() {}
            }
            struct `Quoted(name)` {
                @Test func quotes() {}
            }
            struct Outer {
                struct Inner {
                    @Test func nests() {}
                }
            }
            private let ↓Inner: () -> Other = { Other() }
            """,
            """
            public func Open(_ number: Int = 1) async -> Other { Other() }
            func `Quoted(name)`(_ number: Int = 1) async -> Other { Other() }

            public struct Other {
                func runs() {}
                func stored() {}
                func quotes() {}
                func ↓nests() {}
                func ↓leftover() {}
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

    // A limit: the code that `@Test` expands to calls the value of the property `runs` here. What the value of a
    // property runs when it is called is not known.
    @Test(.temporaryDirectory)
    func whatAPropertyWithTheNameOfATestRunsWhenItIsCalledIsNotKnown() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            struct Run {
                func ↓callAsFunction(_ number: Int) async {}
            }
            struct Checks {
                private let runs = Run()
                @Test(arguments: [1]) func runs(_ number: Int) {}
            }
            """,
        ])
    }
}
