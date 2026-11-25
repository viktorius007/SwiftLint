import Testing

@testable import SwiftLintBuiltInRules

/// The declarations are given as SourceKit annotates them in full for a cursor info request.
@Suite
struct UnusedDeclarationObjectiveCTests {
    private static let attribute = "<syntaxtype.attribute.builtin><syntaxtype.attribute.name>@objc"
        + "</syntaxtype.attribute.name></syntaxtype.attribute.builtin>"
    private static let attributeWithName = "<syntaxtype.attribute.builtin><syntaxtype.attribute.name>@objc"
        + "</syntaxtype.attribute.name>(name)</syntaxtype.attribute.builtin>"
    private static let function = "<syntaxtype.keyword>func</syntaxtype.keyword> <decl.name>run</decl.name>"
    /// The USR of a class of the module that Objective-C sees has `@objc(` in it, like the attribute.
    private static let classOfTheModule = #"<ref.class usr="c:@M@Sample@objc(cs)Foo">Foo</ref.class>"#
    /// A default argument of `"@objc(name) <name>@objc</name>"`.
    private static let defaultArgument = "&quot;@objc(name) &lt;name&gt;@objc&lt;/name&gt;&quot;"

    @Test(arguments: [
        "<decl.function.method.instance>\(attribute) \(function)()</decl.function.method.instance>",
        "<decl.function.method.instance>\(attributeWithName) \(function)()</decl.function.method.instance>",
        "<decl.function.method.instance>\(attributeWithName) <syntaxtype.keyword>dynamic</syntaxtype.keyword> "
            + "\(function)(_ sender: \(classOfTheModule))</decl.function.method.instance>",
        "<decl.class>\(attributeWithName) <syntaxtype.keyword>class</syntaxtype.keyword> "
            + "<decl.name>Provider</decl.name></decl.class>",
    ])
    func declarationWithTheAttributeIsMarkedForObjectiveC(declaration: String) {
        #expect(UnusedDeclarationUsage.isMarkedForObjectiveC(fullyAnnotatedDeclaration: declaration))
    }

    @Test(arguments: [
        "<decl.function.free>\(function)()</decl.function.free>",
        "<decl.function.free>\(function)() -&gt; \(classOfTheModule)</decl.function.free>",
        "<decl.function.free>\(function)(text: String = \(defaultArgument))</decl.function.free>",
        "<decl.class><syntaxtype.attribute.builtin><syntaxtype.attribute.name>@objcMembers"
            + "</syntaxtype.attribute.name></syntaxtype.attribute.builtin> <syntaxtype.keyword>class"
            + "</syntaxtype.keyword> <decl.name>Foo</decl.name></decl.class>",
    ])
    func declarationWithoutTheAttributeIsNotMarkedForObjectiveC(declaration: String) {
        #expect(!UnusedDeclarationUsage.isMarkedForObjectiveC(fullyAnnotatedDeclaration: declaration))
    }
}
