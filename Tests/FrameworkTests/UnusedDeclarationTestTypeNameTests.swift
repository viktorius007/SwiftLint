import Foundation
import SwiftLintCore
import TestHelpers
import Testing

/// What can take the place of a name that the code of `@Test` or `@Tag` writes for the type of a test or tag: the
/// index for analyzer rules lacks that code.
@Suite(.serialized, .rulesRegistered, .ownThreads)
struct UnusedDeclarationTestTypeNameTests {
    // The code that `@Test` expands to names the type of the test as the source around the test does, and it finds
    // a static member, a nested type or a type alias of that name before the type: in the types whose bodies are
    // around the test, and in the type that the extension around them extends.
    @Test(.temporaryDirectory)
    func memberThatTakesThePlaceOfTheTypeOfATestIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            class Base {
                class func runs(_ number: Int = 1) async {}
            }
            final class Checks: Base {
                static let Checks = Base.self
                static let ↓Leftover = Base.self
                @Test static func runs() {}
            }
            struct ↓Unrelated {
                static let ↓Checks = Base.self
                typealias ↓Outer = Module
            }

            enum Outer {
                typealias Outer = Module
                struct Inner {
                    @Test static func runs() {}
                }
            }

            enum Space {
                typealias Space = Module
            }
            extension Space {
                struct Inner {
                    @Test static func runs() {}
                }
            }
            """,
            module,
        ])
    }

    // For a test in an extension, the names are the ones of the header. The code also finds such a member in what
    // the type of the test inherits from. A name is compared up to its first parenthesis.
    @Test(.temporaryDirectory)
    func memberThatTakesThePlaceOfANameOfTheHeaderOrIsInheritedIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            enum Wide {
                struct Deep {}
            }
            extension Wide.Deep {
                typealias Wide = Module
                static var ↓Leftover: Module.Deep.Type { Module.Deep.self }
                @Test static func runs() {}
            }
            enum ↓Apart {
                typealias ↓Wide = Module
            }

            protocol Marker {}
            extension Marker {
                static var Marked: Module.Inner.Type { Module.Inner.self }
                static var ↓Leftover: Module.Inner.Type { Module.Inner.self }
            }
            struct Marked: Marker {
                @Test static func runs() {}
            }

            struct `Quoted(name)` {
                static let `Quoted(name)` = Module.Inner.self
                @Test static func runs() {}
            }
            """,
            module,
        ])
    }

    // A limit: what such a member stands for is not known. The code that `@Test` expands to calls
    // `Module.Inner.runs()` here.
    @Test(.temporaryDirectory)
    func whatAMemberThatTakesThePlaceOfTheTypeOfATestStandsForIsNotKnown() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            enum Outer {
                typealias Outer = Module
                struct Inner {
                    @Test static func runs() {}
                }
            }
            enum Module {
                struct ↓Inner {
                    static func ↓runs() {}
                }
            }
            """,
        ])
    }

    // A limit: the names that a header in parentheses has are not known. The code that `@Test` expands to reads the
    // property `Wrapped` here.
    @Test(.temporaryDirectory)
    func namesOfAHeaderInParenthesesAreNotKnown() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            struct Wrapped {}
            extension (Wrapped) {
                @Test static func runs() {}
            }
            extension Wrapped {
                static var ↓Wrapped: Module.Type { Module.self }
            }
            public enum Module {
                public static func runs() {}
            }
            """,
        ])
    }

    // The code that `@Tag` expands to names the type of the tag as the source around the tag does. A limit: no
    // linted file declares `Testing.Tag`, so what it inherits from is not known, and a static member, a nested type
    // or a type alias with one of these names counts as used in every type.
    @Test(.temporaryDirectory)
    func memberThatTakesThePlaceOfATypeAroundATagIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            extension Tag {
                enum Feature {
                    typealias Tag = Testing.Tag
                    typealias ↓Leftover = Testing.Tag
                    @Testing.Tag static var integration: Testing.Tag
                }
            }
            @Test(.tags(.Feature.integration)) func example() {}

            struct ↓Elsewhere {
                static let Tag = 1
                typealias Feature = Int
                static let ↓Leftover = 1
            }
            """,
            """
            import Testing

            public enum Namespace {}
            extension Tag {
                static let Tag = Namespace.self
                static let ↓Leftover = Namespace.self
                @Testing.Tag static var smoke: Testing.Tag
            }
            @Test(.tags(.smoke)) func other() {}
            """,
        ])
    }

    // A limit: a tag with the name of its type or of a type around it counts as used like any static member of that
    // name, also where nothing names it. The code that `@Tag` expands to finds the enum `Feature` here.
    @Test(.temporaryDirectory)
    func tagWithTheNameOfATypeAroundItIsKeptWhereNothingNamesIt() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            extension Tag {
                enum Feature {
                    @Tag static var Feature: Tag
                    @Tag static var ↓other: Tag
                }
            }
            """,
        ])
    }

    // A limit: a protocol is not among what can take the place of such a name. The code that `@Tag` expands to names
    // the protocol here.
    @Test(.temporaryDirectory)
    func protocolThatTakesThePlaceOfTheTypeOfATagIsReported() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            extension Tag {
                protocol ↓Tag {}
                @Testing.Tag static var ↓smoke: Self
            }
            """,
        ])
    }
}

private let module = """
    public enum Module {
        public struct Inner {
            public static func runs() {}
        }
        public struct Deep {
            public static func runs() {}
        }
    }
    """
