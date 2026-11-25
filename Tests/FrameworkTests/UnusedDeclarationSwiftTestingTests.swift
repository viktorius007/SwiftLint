import TestHelpers
import Testing

/// What Swift Testing runs has no reference in an index without macro expansions.
@Suite(.serialized, .rulesRegistered)
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

    // The code that the macros expand to names the suite or the type that holds the test, and no type around it.
    @Test(.temporaryDirectory)
    func typeAroundTheTypeThatHoldsATestIsNotUsedByIt() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            enum ↓Outer {
                struct Inner {
                    @Test func runs() {}
                }
            }
            enum ↓Namespace {
                @Suite struct Nested {}
            }
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func attributeMarksTheDeclarationThatCarriesItOnly() throws {
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
}
