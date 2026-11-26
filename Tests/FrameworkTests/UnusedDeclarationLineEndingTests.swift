import Foundation
import SourceKittenFramework
import SwiftLintCore
import TestHelpers
import Testing

@testable import SwiftLintBuiltInRules
@testable import SwiftLintFramework

/// The index ends a line at a line feed, also at one that follows a carriage return. A limit: after a carriage
/// return that no line feed follows, the index keeps the number of the line and starts its columns again, so two
/// declarations can have one position.
@Suite(.serialized, .rulesRegistered)
struct UnusedDeclarationLineEndingTests {
    // SourceKit is asked about the attribute of the test and about the access level of `exported()`, and the name
    // of an extension is looked for at the place of `Other`, each at its position in the file. If a carriage
    // return and a line feed ended a line each, the third line would be the second, which has the name of an
    // extension at that place.
    @Test(.temporaryDirectory, arguments: ["\n", "\r\n"])
    func declarationsAreFoundAtTheirPositionsWithEitherLineEnding(lineEnding: String) throws {
        let lines = [
            "import Testing",
            "extension Plain { func member() {} }",
            "let val = Other()",
            "@Test func runs() {}",
            "public func exported() {}",
            "struct Plain {}",
            "struct Other {}",
            "func leftover() {}",
        ]
        let source = lines.joined(separator: lineEnding)
        let path = URL.cwd.appending(path: "Input.swift")
        try source.write(to: path, atomically: true, encoding: .utf8)
        let file = try #require(SwiftLintFile(path: path, isTestFile: true))
        let configuration = try Configuration(dict: ["only_rules": ["unused_declaration"]])
        let storage = RuleStorage()
        let arguments = file.makeCompilerArguments() + ["-module-name", "Sample"]
        let linter = Linter(file: file, configuration: configuration, compilerArguments: arguments)
            .collect(into: storage)
        let reported = linter.styleViolations(using: storage).map(\.location)
        let expected = try ["member", "val", "Plain {}", "leftover"].map { name in
            let offset = try #require(source.range(of: name)).lowerBound.utf16Offset(in: source)
            return Location(file: file, byteOffset: ByteCount(offset))
        }
        #expect(reported.sorted() == expected.sorted())
    }

    @Test
    func positionThatIsNotInTheFileHasNoOffset() {
        let file = SwiftLintFile(contents: "first\r\nsecond\n")
        #expect(file.byteOffset(ofIndexedLine: 2, column: 3) == 9)
        #expect(file.byteOffset(ofIndexedLine: 0, column: 1) == nil)
        #expect(file.byteOffset(ofIndexedLine: 4, column: 1) == nil)
        #expect(file.byteOffset(ofIndexedLine: 1, column: 0) == nil)
        #expect(file.byteOffset(ofIndexedLine: 1, column: 8) == nil)
    }
}
