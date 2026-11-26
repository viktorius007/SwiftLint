import Foundation
import SwiftLintCore
import TestHelpers
import Testing

/// A limit: the code that the macros of Swift Testing expand to writes names of modules (`Swift.Never`,
/// `_Concurrency.Actor`, `Testing.Tag`). The index for analyzer rules lacks that code, and what takes the place of a
/// module there is not looked for: it is reported, with what the code finds in it.
@Suite(.serialized, .rulesRegistered, .ownThreads)
struct UnusedDeclarationTestModuleNameTests {
    // The code of `@Test` writes `_Concurrency.Actor` and finds the two type aliases of `Checks`. The code of `@Tag`
    // writes `Testing.Tag` and finds the type alias `Testing`, and in it the type alias `Tag`, which counts as used
    // by its name.
    @Test(.temporaryDirectory)
    func memberThatTakesThePlaceOfAModuleInTheCodeOfATestOrTagIsReported() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            enum Checks {
                typealias ↓_Concurrency = Checks
                typealias ↓Actor = Swift.Actor

                @Test static func runs() {}
            }
            """,
            """
            import Testing

            typealias OriginalTag = Tag

            extension Tag {
                typealias ↓Testing = OriginalTag
                typealias Tag = OriginalTag

                @Tag static var smoke: Self
            }

            @Test(.tags(.smoke)) func other() {}
            """,
        ])
    }

    // The code of `@Test` for a test at file scope writes `Swift.Never` and finds the enum and its type alias.
    @Test(.temporaryDirectory)
    func typeThatTakesThePlaceOfTheStandardLibraryInTheCodeOfATestIsReported() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            enum ↓Swift {
                typealias ↓Never = OriginalNever
            }
            typealias OriginalNever = Never

            @Test func runs() {}
            """,
        ])
    }

    // The code of `#expect` writes `Testing.__checkValue` and finds the function of the enum, and through it the two
    // other functions.
    @Test(.temporaryDirectory)
    func typeThatTakesThePlaceOfSwiftTestingInTheCodeOfAnExpectationIsReported() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            typealias OriginalLocation = SourceLocation

            public func check(_ flag: Bool) {
                #expect(flag)
            }

            enum ↓Testing {
                typealias SourceLocation = OriginalLocation
                struct Expression {
                    static func ↓__fromSyntaxNode(_ text: String) -> Self { Self() }
                }
                struct Outcome {
                    func ↓__expected() {}
                }
                static func ↓__checkValue(
                    _ value: Bool, expression: Expression, comments: [String], isRequired: Bool,
                    sourceLocation: SourceLocation
                ) -> Outcome { Outcome() }
            }
            """,
        ])
    }
}
