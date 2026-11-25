import SourceKittenFramework
import Testing

@testable import SwiftLintBuiltInRules

@Suite
struct UnusedDeclarationImportedTypesTests {
    private static let sendable = #"<Type usr="s:s8SendableP">Sendable</Type>"#
    private static let decodable = #"<Type usr="s:Se">Decodable</Type>"#
    private static let element = #"<Type usr="s:6Vendor6SourceP4Selfxmfp">Self</Type>."#
        + #"<Type usr="s:ST7ElementQa">Element</Type>"#
    // Each declaration is what SourceKit prints for it on Swift 6.4.2.
    private static let declarations: [(String, String, [String])] = [
        ("protocol", #"<Declaration>protocol Mid : <Type usr="s:SE">Encodable</Type></Declaration>"#, ["s:SE"]),
        (
            "protocol",
            #"<Declaration>protocol Outer : \#(sendable), <Type usr="s:6Vendor3MidP">Mid</Type></Declaration>"#,
            ["s:s8SendableP", "s:6Vendor3MidP"]
        ),
        (
            "typealias",
            "<Declaration>typealias Coding = \(decodable) &amp; \(sendable)</Declaration>",
            ["s:Se", "s:s8SendableP"]
        ),
        (
            "protocol",
            #"<Declaration>protocol Source : <Type usr="s:ST">Sequence</Type> where \#(element) : \#(decodable)"#
                + "</Declaration>",
            ["s:ST"]
        ),
        ("protocol", "<Declaration>protocol Empty</Declaration>", []),
        // A class passes its coding on to a subclass as it is, without the stored properties of the subclass.
        ("class", #"<Declaration>class Base : <Type usr="s:s7Codablea">Codable</Type></Declaration>"#, []),
        ("struct", "<Declaration>struct Value : \(decodable)</Declaration>", []),
    ]

    @Test(arguments: declarations)
    func inheritedTypesAreTheOnesOfAProtocolOrATypeAliasBeforeItsRequirements(
        kind: String, declaration: String, inherited: [String]
    ) {
        let cursorInfo = ["key.kind": "source.lang.swift.decl.\(kind)", "key.annotated_decl": declaration]
        #expect(UnusedDeclarationUsage.inheritedTypes(inCursorInfo: cursorInfo) == Set(inherited))
    }

    @Test
    func typesOfOtherModulesThanTheStandardLibraryAreAskedOnceAndSoAreTheirInheritedTypes() {
        var facts = UnusedDeclarationUsage.TypeFacts()
        facts.declaredTypes = ["s:6Sample5ModelV", "s:6Sample5LocalP"]
        facts.inherited = [
            "s:6Sample5ModelV": ["s:6Sample5LocalP", "s:6Vendor5OuterP", "s:SQ", "c:objc(pl)NSCoding"],
            // The USR of a declaration of C starts with the name of its file if no other file can see it.
            "s:6Sample5LocalP": ["s:s8SendableP", "s:6Vendor5OuterP", "c:1Header.h@T@Name"],
        ]
        facts.conformancesMissingFromIndex = ["s:6Sample5ModelV": ["s:6Vendor5AliasA"]]
        let answers: [String: Set<String>] = [
            "s:6Vendor5OuterP": ["s:6Vendor3MidP", "s:SH"],
            "s:6Vendor3MidP": ["s:SE", "s:6Vendor5OuterP"],
        ]
        var asked = [String]()

        facts.noteInheritanceOfTypesDeclaredElsewhere {
            asked.append($0)
            return answers[$0] ?? []
        }

        #expect(asked.sorted() == ["s:6Vendor3MidP", "s:6Vendor5AliasA", "s:6Vendor5OuterP"])
        #expect(facts.inherited["s:6Vendor5OuterP"] == ["s:6Vendor3MidP", "s:SH"])
        #expect(facts.inherited["s:6Vendor3MidP"] == ["s:SE", "s:6Vendor5OuterP"])
        #expect(facts.inherited["s:6Vendor5AliasA"] == nil)
    }
}
