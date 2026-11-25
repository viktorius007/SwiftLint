import Testing

@testable import SwiftLintBuiltInRules

/// The declarations are given as SourceKit annotates them: each type is in a tag with the type's USR.
@Suite
struct UnusedDeclarationObjectiveCTests {
    private static let classOfTheSystem = #"<Type usr="c:objc(cs)NSObject">NSObject</Type>"#
    /// The USR of a class of the module that Objective-C sees has `@objc(` in it, like the attribute.
    private static let classOfTheModule = #"<Type usr="c:@M@Sample@objc(cs)Foo">Foo</Type>"#

    @Test(arguments: [
        "<Declaration>@objc func plain()</Declaration>",
        "<Declaration>@objc(renamedObject) func renamed() -&gt; \(classOfTheSystem)?</Declaration>",
        "<Declaration>@IBAction @objc(tap:) func tap(_ sender: \(classOfTheModule))</Declaration>",
        "<Declaration>@objc(RenamedProvider) final class Provider : \(classOfTheSystem)</Declaration>",
    ])
    func declarationWithTheAttributeIsMarkedForObjectiveC(annotatedDeclaration: String) {
        #expect(UnusedDeclarationUsage.isMarkedForObjectiveC(annotatedDeclaration: annotatedDeclaration))
    }

    @Test(arguments: [
        "<Declaration>var foo: \(classOfTheModule)</Declaration>",
        "<Declaration>func make() -&gt; \(classOfTheModule)</Declaration>",
        "<Declaration>func plain()</Declaration>",
        "<Declaration>@objcMembers final class Foo : \(classOfTheSystem)</Declaration>",
    ])
    func declarationWithoutTheAttributeIsNotMarkedForObjectiveC(annotatedDeclaration: String) {
        #expect(!UnusedDeclarationUsage.isMarkedForObjectiveC(annotatedDeclaration: annotatedDeclaration))
    }
}
