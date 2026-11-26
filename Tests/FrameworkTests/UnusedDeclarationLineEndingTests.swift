import Foundation
import SourceKittenFramework
import SwiftLintCore
import TestHelpers
import Testing

@testable import SwiftLintBuiltInRules
@testable import SwiftLintFramework

/// The index ends a line at a line feed, also at one that follows a carriage return. SourceKit reads a file from
/// disk and counts the bytes of a byte order mark at its start, in the columns of the first line and in every
/// offset. The text of the file that the rule works on can lack these bytes.
///
/// A limit: after a carriage return that no line feed follows, the index keeps the number of the line and starts
/// its columns again, so two declarations can have one position.
@Suite(.serialized, .rulesRegistered, .ownThreads)
struct UnusedDeclarationLineEndingTests {
    // The rule looks at the place of `Other` and of `Mark` for the name of an extension, and asks SourceKit about
    // the access level of `exported()`, about the attribute of the test and about what the second `area()`
    // overrides, each at its position in the file. If a carriage return and a line feed ended a line each, the
    // fourth line would be the third, which has the name of an extension at the place of `Other`. With a byte
    // order mark, the index has `first()` three columns further right, and SourceKit has every name three bytes
    // further on: it has `A` where the rule has `Mark`.
    @Test(.temporaryDirectory, arguments: ["\n", "\r\n"], ["", "\u{FEFF}"])
    func declarationsAreFoundAtTheirPositions(lineEnding: String, mark: String) throws {
        let lines = [
            "func first() {}",
            "import Testing",
            "extension Plain { func member() {} }",
            "let val = Other()",
            "@Test func runs() {}",
            "public func exported() {}",
            "struct Plain {}",
            "struct Other {}",
            "func leftover() {}",
            "protocol Mark {}",
            "extension A: Mark {}",
            "struct A {}",
            "protocol Shape { func area() }",
            "extension Shape { func area() {} }",
        ]
        let names = ["first", "member", "val", "Plain {}", "leftover", "A {}", "Shape { func area() }", "area() }"]
        let (reported, expected) = try reportedAndNamed(names, in: lines, lineEnding: lineEnding, mark: mark)
        #expect(reported == expected)
    }

    // The rule reads four things from the syntax and compares the place of each with a position of the index:
    // that `extension Lone {}` names `Lone` in the header of an extension, which is no use of it; that `Linked`
    // constrains itself to `Shared`, whose `runs()` the test of that name then calls; that the conformance of
    // `Rack` to `Shelf` is in an extension that the index lacks, so `take()` of its superclass is a witness; and
    // that `fixed` has an initial value, so decoding does not write it.
    @Test(.temporaryDirectory, arguments: ["\n", "\r\n"], ["", "\u{FEFF}"])
    func whatTheSyntaxTellsIsFoundAtThePositionsOfTheIndex(lineEnding: String, mark: String) throws {
        let lines = [
            "extension Lone {}",
            "import Testing",
            "struct Lone {}",
            "protocol Shared {}",
            "extension Shared { func runs() async {} }",
            "protocol Linked where Self: Shared {}",
            "struct Checks: Linked { @Test func runs() {} }",
            "protocol Shelf { func take() -> Int }",
            "protocol Tagged {}",
            "class Frame { func take() -> Int { 1 } }",
            "final class Rack: Frame {}",
            "extension Rack: Shelf & Tagged {}",
            "struct Inbound: Decodable { let fixed = 1 }",
            "print(Rack(), Inbound.self)",
        ]
        let names = ["Lone {}\(lineEnding)protocol", "take() -> Int }", "fixed"]
        let (reported, expected) = try reportedAndNamed(names, in: lines, lineEnding: lineEnding, mark: mark)
        #expect(reported == expected)
    }

    @Test
    func positionThatIsNotInTheFileHasNoOffset() {
        let positions = IndexedPositions(of: SwiftLintFile(contents: "first\r\nsecond\n"))
        #expect(positions.offset(ofLine: 2, column: 3) == 9)
        #expect(positions.offset(ofLine: 0, column: 1) == nil)
        #expect(positions.offset(ofLine: 4, column: 1) == nil)
        #expect(positions.offset(ofLine: 1, column: 0) == nil)
        #expect(positions.offset(ofLine: 1, column: 8) == nil)
        #expect(positions.offsetForSourceKit(of: 9) == 9)
    }

    // The file on disk has `first` after the three bytes of the mark, and `second` at byte 9. Reading the file can
    // remove the mark from the text or keep it.
    @Test(.temporaryDirectory, arguments: [false, true])
    func byteOrderMarkCountsInTheColumnsOfTheFirstLineAndInTheOffsetsOfSourceKit(textKeepsTheMark: Bool) throws {
        let path = URL.cwd.appending(path: "Input.swift")
        let source = "\u{FEFF}first\nsecond\n"
        try source.write(to: path, atomically: true, encoding: .utf8)
        let file = SwiftLintFile(pathDeferringReading: path)
        file.file.contents = textKeepsTheMark ? source : String(source.dropFirst())
        let positions = IndexedPositions(of: file)
        let first = try #require(positions.offset(ofLine: 1, column: 4))
        let second = try #require(positions.offset(ofLine: 2, column: 1))
        let bytes = Array(file.contents.utf8)
        #expect(bytes.dropFirst(first.value).starts(with: "first".utf8))
        #expect(bytes.dropFirst(second.value).starts(with: "second".utf8))
        #expect(positions.offsetForSourceKit(of: first) == 3)
        #expect(positions.offsetForSourceKit(of: second) == 9)
    }

    /// Writes the lines to a file, with the mark before them, and runs the rule on it.
    ///
    /// - returns: The places of the reported declarations, and the places where the text of the file has each of
    ///   the names for the first time, both sorted.
    private func reportedAndNamed(_ names: [String],
                                  in lines: [String],
                                  lineEnding: String,
                                  mark: String) throws -> (reported: [Location], named: [Location]) {
        let path = URL.cwd.appending(path: "Input.swift")
        try (mark + lines.joined(separator: lineEnding)).write(to: path, atomically: true, encoding: .utf8)
        #expect(try Data(contentsOf: path).starts(with: [0xEF, 0xBB, 0xBF]) == mark.isNotEmpty)
        let file = try #require(SwiftLintFile(path: path, isTestFile: true))
        let configuration = try Configuration(dict: ["only_rules": ["unused_declaration"]])
        let storage = RuleStorage()
        let arguments = file.makeCompilerArguments() + ["-module-name", "Sample"]
        let linter = Linter(file: file, configuration: configuration, compilerArguments: arguments)
            .collect(into: storage)
        let reported = linter.styleViolations(using: storage).map(\.location)
        let contents = file.contents
        let named = try names.map { name in
            let start = try #require(contents.range(of: name)).lowerBound
            let offset = contents.utf8.distance(from: contents.startIndex, to: start)
            return Location(file: file, byteOffset: ByteCount(offset))
        }
        return (reported.sorted(), named.sorted())
    }
}
