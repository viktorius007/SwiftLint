import Foundation
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
        // What comes before the colon or the equals sign is the name with its primary associated types or its
        // generic parameters.
        (
            "protocol",
            #"<Declaration>protocol Boxes&lt;<Type usr="s:6Vendor5BoxesP4ItemQa">Item</Type>&gt;</Declaration>"#,
            []
        ),
        (
            "protocol",
            #"<Declaration>protocol Tray&lt;<Type usr="s:6Vendor3BoxP4ItemQa">Item</Type>&gt; : "#
                + #"<Type usr="s:6Vendor3BoxP">Box</Type> where <Type usr="s:6Vendor4TrayP4Selfxmfp">Self</Type>."#
                + #"<Type usr="s:6Vendor3BoxP4ItemQa">Item</Type> : \#(sendable)</Declaration>"#,
            ["s:6Vendor3BoxP"]
        ),
        (
            "protocol",
            #"<Declaration>protocol Hashable : <Type usr="s:SQ">Equatable</Type>, ~Copyable, ~Escapable"#
                + "</Declaration>",
            ["s:SQ"]
        ),
        (
            "typealias",
            #"<Declaration>typealias Keyed&lt;Key&gt; = [<Type usr="s:6Vendor5Keyeda3Keyxmfp">Key</Type> : "#
                + #"<Type usr="s:Si">Int</Type>] where <Type usr="s:6Vendor5Keyeda3Keyxmfp">Key</Type> : "#
                + #"<Type usr="s:SH">Hashable</Type></Declaration>"#,
            ["s:6Vendor5Keyeda3Keyxmfp", "s:Si"]
        ),
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
    func typesThatNoFileDeclaresAreAskedOnceForAllFilesWithTheSameCompilerArguments() {
        let local = "s:6Sample5LocalP", outer = "s:6Vendor5OuterP", middle = "s:6Vendor3MidP"
        let alias = "s:6Vendor5AliasA", hashable = "s:SH", equatable = "s:SQ"
        // What these inherit from is known without a question.
        let encodable = "s:SE", sendable = "s:s8SendableP"
        // The USR of a declaration of C starts with the name of its file if no other file can see it.
        let declarationsOfC: Set = ["c:objc(pl)NSCoding", "c:1Header.h@T@Name"]
        let collectedInfo = [
            file("/B.swift"): info(inherited: [outer, alias, local], compiledWith: ["-D", "FIRST"]),
            file("/A.swift"): info(inherited: [local, outer, equatable, sendable], compiledWith: ["-D", "FIRST"]),
            file("/C.swift"): info(inherited: declarationsOfC.union([outer]), compiledWith: ["-D", "SECOND"]),
            file("/D.swift"): info(inherited: declarationsOfC.union([local]), compiledWith: ["-D", "THIRD"]),
            // A file without a path cannot ask.
            SwiftLintFile(contents: ""): info(inherited: [outer], compiledWith: ["-D", "FIRST"]),
        ]
        let answers: [String: Set<String>] = [
            outer: [middle, hashable, local],
            middle: [encodable, outer],
            hashable: [equatable],
        ]
        var asked = [Question](), released = [Question]()
        let sourceKit = UnusedDeclarationUsage.InheritanceSource(
            inheritedTypes: { usr, file, compilerArguments in
                asked.append(Question(usr: usr, path: file.path?.filepath, compilerArguments: compilerArguments))
                return answers[usr] ?? []
            },
            release: { file, compilerArguments in
                released.append(Question(usr: "", path: file.path?.filepath, compilerArguments: compilerArguments))
            }
        )

        let inherited = UnusedDeclarationUsage.inheritanceOfTypesDeclaredElsewhere(
            collectedInfo, ["s:6Sample5ModelV", local], sourceKit: sourceKit
        )

        // The first file in the order of the paths asks for all files that are compiled like it. It asks
        // neither about what a file declares nor about a declaration of C.
        let first = [outer, middle, alias, hashable, equatable]
            .map { Question(usr: $0, path: "/A.swift", compilerArguments: ["-D", "FIRST"]) }
        let second = [outer, middle, hashable, equatable]
            .map { Question(usr: $0, path: "/C.swift", compilerArguments: ["-D", "SECOND"]) }
        #expect(asked.sorted() == (first + second).sorted())
        #expect(released.sorted() == [
            Question(usr: "", path: "/A.swift", compilerArguments: ["-D", "FIRST"]),
            Question(usr: "", path: "/C.swift", compilerArguments: ["-D", "SECOND"]),
        ])
        #expect(inherited == answers)
    }

    private func file(_ path: String) -> SwiftLintFile {
        SwiftLintFile(pathDeferringReading: URL(filePath: path, directoryHint: .notDirectory))
    }

    private func info(inherited: Set<String>, compiledWith compilerArguments: [String])
        -> UnusedDeclarationRule.FileUSRs {
        var facts = UnusedDeclarationUsage.TypeFacts()
        facts.inheritedProtocolsAndTypeAliases = inherited
        return UnusedDeclarationRule.FileUSRs(
            referenced: [], declared: [], typeFacts: facts, compilerArguments: compilerArguments
        )
    }
}

private struct Question: Comparable {
    let usr: String
    let path: String?
    let compilerArguments: [String]

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.path ?? "", lhs.usr) < (rhs.path ?? "", rhs.usr)
    }
}
