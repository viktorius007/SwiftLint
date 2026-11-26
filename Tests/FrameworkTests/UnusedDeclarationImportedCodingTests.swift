import TestHelpers
import Testing

/// Coding that the compiler generates for a type which gets `Decodable` or `Encodable` through a protocol of
/// another module. In Foundation, `ParseableFormatStyle` inherits from `FormatStyle`, and that one and
/// `ParseStrategy` inherit from `Codable`.
@Suite(.serialized, .rulesRegistered, .ownThreads)
struct UnusedDeclarationImportedCodingTests {
    @Test(.temporaryDirectory)
    func storedPropertyIsUsedByCodingGeneratedThroughAProtocolOfAnotherModule() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Foundation

            struct Doubled: ParseableFormatStyle {
                var label = "doubled"
                var ↓computed: Int { 1 }
                var parseStrategy: Halved { Halved() }
                func format(_ value: Int) -> String { String(value * 2) }
                func ↓leftover() {}
            }

            struct Halved: ParseStrategy {
                var note = "halved"
                func parse(_ value: String) throws -> Int { (Int(value) ?? 0) / 2 }
            }

            print(String(decoding: try JSONEncoder().encode(Doubled()), as: UTF8.self))
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func storedPropertyIsUsedByCodingGeneratedThroughAProtocolOfAnotherModuleInAnExtensionMissingFromTheIndex()
        throws {
        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                import Foundation

                struct Plain {
                    var label = "plain"
                    var ↓computed: Int { 1 }
                    func format(_ value: Int) -> String { String(value) }
                }
                extension Plain: FormatStyle & Sendable {}

                @main
                struct Entry {
                    static func main() { print(5.formatted(Plain())) }
                }
                """,
            ],
            compilerFlags: ["-parse-as-library"]
        )
    }

    @Test(.temporaryDirectory)
    func storedPropertyIsNotUsedThroughAProtocolOfAnotherModuleWithoutCoding() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Foundation

            struct Failure: LocalizedError {
                var ↓code = 1
            }

            print(Failure())
            """,
        ])
    }
}
