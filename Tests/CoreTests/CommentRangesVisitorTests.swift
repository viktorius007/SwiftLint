import SwiftIDEUtils
import SwiftLintCore
import SwiftSyntax
import Testing

@Suite
struct CommentRangesVisitorTests {
    private struct Comment: Equatable {
        let kind: SyntaxClassification
        let range: Range<Int>
    }

    @Test(arguments: [
        "",
        "let a = 1 // trailing\n",
        "// line\n/// doc line\n/* block */\n/** doc block */\nlet a = 1\n",
        "// first\n// second\nlet a = 1",
        "/* a *//* b */ let a = 1",
        "/* a *//** b *//* c */ let a = 1",
        "/// a\n/// b\nfunc f() { /* c */ }\n// end",
        "func f(/* a */ b: Int /* c */) {}",
        "@Foo</* a */Int> /* b */ var x = 1",
        "@Outer<@Inner /* a */ () -> Void> /* b */ var x = 1",
        "@/* a *//* b */\nvar x = 1",
        "@available(*, /* a */ deprecated) // b\nfunc f() {}",
        "let s = \"\"\"\n    // not a comment\n    \"\"\" // comment",
        "let s = \"\" /* a */",
        "#if DEBUG // a\n/* b */\n#endif /* c */",
        "func f( { // a\n/* b */ ) ] /* c */ }",
        "/* unterminated",
        "let a = 1 /* a */ /* b */\n/* c */",
    ])
    func equalsCommentsInClassifications(code: String) {
        let file = SwiftLintFile(contents: code)
        let expected = file.syntaxClassifications
            .filter(\.kind.isComment)
            .map { Comment(kind: $0.kind, range: $0.range.lowerBound.utf8Offset..<$0.range.upperBound.utf8Offset) }
        #expect(comments(in: file) == expected)
    }

    @Test
    func mergesAdjacentCommentsOfTheSameKind() {
        let file = SwiftLintFile(contents: "/* a *//* b */ /* c */\n// d\n// e")
        #expect(comments(in: file) == [
            Comment(kind: .blockComment, range: 0..<14),
            Comment(kind: .blockComment, range: 15..<22),
            Comment(kind: .lineComment, range: 23..<27),
            Comment(kind: .lineComment, range: 28..<32),
        ])
    }

    @Test
    func skipsCommentsInsideAttributeNames() {
        let file = SwiftLintFile(contents: "@Foo</* a */Int> /* b */ var x = 1")
        #expect(comments(in: file) == [Comment(kind: .blockComment, range: 17..<24)])
    }

    private func comments(in file: SwiftLintFile) -> [Comment] {
        file.commentRanges.map {
            Comment(kind: $0.kind, range: $0.range.lowerBound.utf8Offset..<$0.range.upperBound.utf8Offset)
        }
    }
}
