import SwiftLintCore
import SwiftSyntax
import Testing

@Suite
struct IdentifierDeclarationTests {
    @Test(arguments: [
        ("value", "value", true),
        ("value", "other", false),
        ("value", "valu", false),
        ("`class`", "class", true),
        ("class", "`class`", true),
        ("``class``", "`class`", true),
        ("cl`ass", "class", false),
        ("$value", "value", true),
        ("$value", "$value", true),
        ("value", "$value", false),
        ("`$value`", "`value`", true),
        ("$", "", true),
        ("é", "e\u{301}", true),
        ("_", "_", false),
        ("$_", "$_", false),
        ("value", "_", false),
    ])
    func declaresIdentifiersDisregardingBackticks(name: String, id: String, expected: Bool) {
        #expect(IdentifierDeclaration.implicitVariable(name: name).declares(id: id) == expected)
    }

    @Test(arguments: [
        ("`class`", "class", false),
        ("`class`", "`class`", true),
        ("$value", "value", true),
        ("$`value`", "`value`", true),
    ])
    func declaresIdentifiersRespectingBackticks(name: String, id: String, expected: Bool) {
        let declaration = IdentifierDeclaration.implicitVariable(name: name)
        #expect(declaration.declares(id: id, disregardBackticks: false) == expected)
    }

    @Test
    func wildcardDeclaresNothing() {
        #expect(!IdentifierDeclaration.wildcard.declares(id: "_"))
        #expect(!IdentifierDeclaration.wildcard.declares(id: "value"))
    }
}
