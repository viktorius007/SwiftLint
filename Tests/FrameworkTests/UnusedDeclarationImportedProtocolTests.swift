import TestHelpers
import Testing

/// Conformances that the index leaves out, to protocols that the linted files do not declare.
@Suite(.serialized, .rulesRegistered)
struct UnusedDeclarationImportedProtocolTests {
    @Test(.temporaryDirectory)
    func operatorAtFileScopeThatSatisfiesAProtocolOfAnotherModuleIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            protocol Marker {}
            struct Age {}

            func == (lhs: Age, rhs: Age) -> Bool { true }

            extension Age: Equatable & Marker {}

            func equal<T: Equatable>(_ left: T, _ right: T) -> Bool { left == right }
            print(equal(Age(), Age()))
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func memberThatSatisfiesAProtocolOfAnotherModuleIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            protocol Marker {}
            struct Size {
                var description: String { "size" }
                var ↓leftover: Int { 0 }
            }

            extension Size: CustomStringConvertible & Marker {}

            func describe<T: CustomStringConvertible>(_ value: T) -> String { value.description }
            print(describe(Size()))
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func memberOfAnotherExtensionThatSatisfiesAProtocolOfAnotherModuleIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            protocol Marker {}
            struct Size {}
            extension Size {
                var description: String { "size" }
            }

            extension Size: CustomStringConvertible & Marker {}

            func describe<T: CustomStringConvertible>(_ value: T) -> String { value.description }
            print(describe(Size()))
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func memberOfAProtocolExtensionThatSatisfiesAProtocolOfAnotherModuleIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            protocol Described {}
            extension Described {
                var description: String { "described" }
            }
            struct Size {}

            extension Size: CustomStringConvertible & Described {}

            func describe<T: CustomStringConvertible>(_ value: T) -> String { value.description }
            print(describe(Size()))
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func memberOfASuperclassThatSatisfiesAProtocolOfAnotherModuleIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            protocol Marker {}
            class Base {
                var description: String { "base" }
            }
            final class Size: Base {}

            extension Size: CustomStringConvertible & Marker {}

            func describe<T: CustomStringConvertible>(_ value: T) -> String { value.description }
            print(describe(Size()))
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func protocolWithoutRequirementsKeepsNothing() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            protocol Named {
                var name: String { get }
            }
            extension Named {
                var ↓leftover: Int { 0 }
            }
            struct Label {
                var name: String { "label" }
            }

            extension Label: Named & Sendable {}

            func name<T: Named>(of value: T) -> String { value.name }
            print(name(of: Label()))
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func codingDeclaredBesideAnEmptyCodableExtensionIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Foundation

            protocol Stamped {}
            extension Stamped {
                var ↓stamp: Int { 0 }
            }

            struct Model: Stamped {
                var id = 0
                var ↓spare = 0

                init() {}
                init(from decoder: any Decoder) throws {
                    id = try decoder.singleValueContainer().decode(Int.self)
                }

                func encode(to encoder: any Encoder) throws {
                    var container = encoder.singleValueContainer()
                    try container.encode(id)
                }

                func ↓leftover() {}
            }

            extension Model: Codable {}

            let model = try JSONDecoder().decode(Model.self, from: try JSONEncoder().encode(Model()))
            print(model)
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func storedPropertyIsNotUsedByCodingDeclaredBesideAnExtensionMissingFromTheIndex() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Foundation

            protocol Marked {}

            struct Envelope {
                var ↓unused = 0

                func encode(to encoder: any Encoder) throws {
                    var value = encoder.singleValueContainer()
                    try value.encode(42)
                }
            }

            extension Envelope: Encodable & Marked {}

            struct Letter {
                var ↓unused = 0

                init(from decoder: any Decoder) throws {
                    _ = try decoder.singleValueContainer().decode(Int.self)
                }
            }

            extension Letter: Decodable & Marked {}

            let data = try JSONEncoder().encode(Envelope())
            print(try JSONDecoder().decode(Letter.self, from: data))
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func encodingOfAProtocolExtensionBesideAnEmptyCodableExtensionIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Foundation

            protocol EncodedAsNumber {}
            extension EncodedAsNumber {
                func encode(to encoder: any Encoder) throws {
                    var container = encoder.singleValueContainer()
                    try container.encode(42)
                }

                func ↓leftover() {}
            }

            struct Model: EncodedAsNumber {
                init() {}
                init(from decoder: any Decoder) throws {
                    _ = try decoder.singleValueContainer().decode(Int.self)
                }
            }

            extension Model: Codable {}

            print(try JSONDecoder().decode(Model.self, from: try JSONEncoder().encode(Model())))
            """,
        ])
    }
}
