import Foundation
import SwiftLintCore
import TestHelpers
import Testing

// A type marked `@main` can find its `main()` in an extension of a type that no linted file declares, through
// what that type inherits from. That is known in part only, so every such `main()` counts as an entry point.

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
