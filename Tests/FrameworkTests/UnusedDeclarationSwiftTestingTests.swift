import Foundation
import SwiftLintCore
import TestHelpers
import Testing

/// What Swift Testing runs has no reference in an index without macro expansions.
@Suite(.serialized, .rulesRegistered, .ownThreads)
struct UnusedDeclarationSwiftTestingTests {
    @Test(.temporaryDirectory)
    func testAtFileScopeIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            @Test func runs() {}
            @Test("With a name") func named() async throws {}
            func ↓leftover() {}
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func suiteAndItsTestsAreUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            @Suite struct Marked {
                @Test func runs() {}
                func ↓leftover() {}
            }
            @Suite(.serialized) final class Serial {}
            @Suite actor Isolated {}
            struct ↓Leftover {}
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func typeThatHoldsATestIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            struct HoldsInstanceTest {
                @Test func runs() {}
            }
            enum HoldsStaticTest {
                @Test static func runs() {}
                static func ↓leftover() {}
            }
            struct Extended {}
            extension Extended {
                @Test func runs() {}
            }
            """,
        ])
    }

    // The code that `@Test` expands to names the type that holds the test by the types around it:
    // `Outer.Inner.self`. The code that `@Suite` expands to names the suite alone: `Inner.self`.
    @Test(.temporaryDirectory)
    func typesAroundTheTypeThatHoldsATestAreUsedByIt() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            enum Outer {
                struct Inner {
                    @Test func runs() {}
                }
                struct ↓Sibling {}
            }
            enum First {
                enum Second {
                    struct Third {
                        @Test static func runs() {}
                    }
                }
            }
            enum AroundSuite {
                @Suite struct Held {
                    @Test func runs() {}
                }
            }
            enum Extended {}
            extension Extended {
                struct Inside {
                    @Test func runs() {}
                }
            }
            enum Same {
                struct Piece {}
            }
            extension Same.Piece {
                @Test func runs() {}
            }
            enum Split {
                struct Part {}
            }
            """,
            """
            import Testing

            extension Split.Part {
                @Test func runs() {}
            }
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func typesAroundASuiteWithoutATestAreNotUsedByIt() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            enum ↓Namespace {
                @Suite struct Nested {}
            }
            enum ↓First {
                enum ↓Second {
                    @Suite struct Leaf {
                        func ↓helper() {}
                    }
                }
            }
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func attributeDoesNotMarkADeclarationOfAnotherName() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            let cases = [1, 2]
            func condition() -> Bool { true }

            struct Holder {
                func ↓before() {}
                @Test(.enabled(if: condition()), arguments: cases)
                func runs(number: Int) {}
                func ↓after() {}
                var ↓leftover: Int { 0 }
            }
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func writtenCodeInsideMacrosIsRead() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            struct Failure: Error {}
            func value() -> Int? { 1 }
            func fails() throws { throw Failure() }
            func compared() -> Int { 1 }
            func ↓leftover() -> Int { 1 }

            extension Tag {
                @Tag static var quick: Self
                @Tag static var ↓slow: Self
            }

            @Test(.tags(.quick)) func runs() throws {
                let number = try #require(value())
                #expect(number == compared())
                #expect(throws: Failure.self) {
                    try fails()
                }
            }
            """,
        ])
    }

    // `#expect` expands to a call of `SourceLocation.__here()`, and the compiler chooses the one without
    // parameters that the extension declares.
    @Test(.temporaryDirectory)
    func memberOfATypeOfSwiftTestingThatAnExpansionCallsIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            extension SourceLocation {
                static func __here() -> Self {
                    Self(fileID: "Sample/Test.swift", filePath: "/Test.swift", line: 1, column: 1)
                }
                static func ↓leftover() {}
            }

            struct ↓Unrelated {
                static func ↓__here() {}
            }

            @Test func succeeds() {
                #expect(Bool(true))
            }
            """,
        ])
    }

    // `#require` expands to a call of `__required()` on a `Result`, and the compiler chooses the one that the
    // extension declares.
    @Test(.temporaryDirectory)
    func memberOfResultThatAnExpansionCallsIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            extension Result where Success == Int, Failure == any Error {
                func __required() throws -> Int { try get() }
                func ↓leftover() {}
            }
            extension Optional {
                func ↓__required() {}
            }

            @Test func succeeds() throws {
                let value: Int? = 1
                _ = try #require(value)
            }
            """,
        ])
    }

    // At the name of the type alias, SourceKit tells about the alias and its module. It is asked about the type.
    @Test(.temporaryDirectory)
    func memberAddedToATypeOfSwiftTestingThroughATypeAliasIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            typealias Location = SourceLocation

            extension Location {
                static func __here() -> Self {
                    Self(fileID: "Sample/Test.swift", filePath: "/Test.swift", line: 1, column: 1)
                }
                static func ↓leftover() {}
            }

            @Test func succeeds() {
                #expect(Location.self == SourceLocation.self)
            }
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func referenceToATypeOfSwiftTestingMarksNothing() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            struct ↓Holder {
                var ↓current: Test?
                func ↓leftover() {}
            }
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func attributeOfTheSameNameThatIsNoMacroOfSwiftTestingMarksNothing() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            @propertyWrapper
            struct Test {
                var wrappedValue: Int
            }
            @resultBuilder
            enum Suite {
                static func buildBlock(_ parts: Int...) -> Int { parts.count }
            }

            struct Holder {
                @Test var ↓number = 1
                @Suite func ↓built() -> Int { 1 }
            }
            print(Holder.self)
            """,
        ])
    }

    #if !os(Windows)
    // The Swift Testing of a toolchain for macOS names its symbols `Testing_toolchain`, and so do their USRs.
    @Test(.temporaryDirectory)
    func swiftTestingIsKnownByTheNameOfItsModuleWhereItsSymbolsHaveAnotherName() throws {
        try compileModule(named: "Testing", source: moduleWithMacros, flags: ["-module-abi-name", "Testing_toolchain"])
        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                import Testing

                @Test func runs() {}
                func ↓leftover() {}

                @Suite struct Checks {
                    @Test func runs() {}
                    func ↓leftover() {}
                }

                struct Holder {
                    @Test func runs() {}
                }

                extension SourceLocation {
                    static func __here() {}
                    static func ↓leftover() {}
                }
                """,
            ],
            compilerFlags: ["-I", URL.cwd.filepath]
        )
    }

    // With `Testing` as the name of its symbols, the USRs of the other module start like the ones of Swift
    // Testing.
    @Test(.temporaryDirectory, arguments: [[], ["-module-abi-name", "Testing"]])
    func macroAndTypeOfAnotherModuleWithTheNamesOfSwiftTestingMarkNothing(flags: [String]) throws {
        try compileModule(named: "Vendor", source: moduleWithMacros, flags: flags)
        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                import Vendor

                @Test func ↓runs() {}

                @Suite struct ↓Checks {
                    @Test func ↓runs() {}
                }

                extension SourceLocation {
                    static func ↓__here() {}
                }
                """,
            ],
            compilerFlags: ["-I", URL.cwd.filepath]
        )
    }
    #endif
}

#if !os(Windows)
/// A module that declares what the tests use of Swift Testing. No plugin implements its macros, so the compiler
/// expands none, as for Swift Testing in an analyzer rule.
private let moduleWithMacros = """
    @attached(peer) public macro Test() = #externalMacro(module: "NoPlugin", type: "NoMacro")
    @attached(peer) public macro Suite() = #externalMacro(module: "NoPlugin", type: "NoMacro")
    public struct SourceLocation {}
    """
#endif
