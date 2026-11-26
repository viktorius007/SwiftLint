import TestHelpers
import Testing

/// A protocol inherits from what its `where` clause constrains it to, as from `Shared` in `protocol Linked where
/// Self: Shared`. The index does not relate the two.
@Suite(.serialized, .rulesRegistered)
struct UnusedDeclarationSelfConstraintTests {
    // `Item: Other` constrains the associated type, and `Linked` does not inherit from `Other`. `Self` can be
    // written in backticks.
    @Test(.temporaryDirectory)
    func testStandsForItsNameInWhatAProtocolConstrainsItselfTo() throws {
        try expectOnlyMarkedDeclarationsReported(in: [
            """
            import Testing

            protocol Shared {}
            protocol Other {}
            extension Shared {
                func runs() async {}
                func ↓leftover() async {}
            }
            extension Other {
                func ↓runs() async {}
            }
            protocol Linked where Self: Shared, Item: Other {
                associatedtype Item
            }
            struct Element: Other {}
            struct Checks: Linked {
                typealias Item = Element
                @Test func runs() {}
            }

            protocol Quoted where `Self`: Marked {}
            protocol Marked {}
            extension Marked {
                func quoted() async {}
            }
            struct More: Quoted {
                @Test func quoted() {}
            }
            """,
        ])
    }

    @Test(.temporaryDirectory)
    func mainOfWhatAProtocolConstrainsItselfToIsUsed() throws {
        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                protocol Running where Self: Marker & Executable {}
                protocol Marker {}
                protocol Executable {}
                extension Executable {
                    static func main() { print("started") }
                    static func ↓leftover() {}
                }

                @main struct Entry: Running {}
                """,
            ],
            compilerFlags: ["-parse-as-library"]
        )
    }

    @Test(.temporaryDirectory)
    func storedPropertyIsUsedByCodeGeneratedForWhatAProtocolConstrainsItselfTo() throws {
        try expectOnlyMarkedDeclarationsReported(
            in: [
                """
                protocol Model where Self: Equatable {}
                struct Row: Model {
                    var number = 0
                }
                protocol Coded where Self: Codable {}
                struct Saved: Coded {
                    var text = ""
                }

                @main enum Entry {
                    static func main() {
                        print(Row() == Row(), Saved())
                    }
                }
                """,
            ],
            compilerFlags: ["-parse-as-library"]
        )
    }
}
