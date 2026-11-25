import Foundation
import SourceKittenFramework
import Testing

@testable import SwiftLintBuiltInRules

@Suite
struct UnusedDeclarationImportedTypesTests {
    private static let sendable = #"<ref.protocol usr="s:s8SendableP">Sendable</ref.protocol>"#
    private static let decodable = #"<ref.protocol usr="s:Se">Decodable</ref.protocol>"#
    private static let item = #"<ref.associatedtype usr="s:6Vendor3BoxP4ItemQa">Item</ref.associatedtype>"#
    private static let key = #"<ref.generic_type_param usr="s:6Vendor5Keyeda3Keyxmfp">Key</ref.generic_type_param>"#
    /// What SourceKit refers to as a class, a struct or a generic parameter in the declarations below.
    private static let otherKinds: Set = ["s:6Vendor4RootC", "s:Si", "s:6Vendor5Keyeda3Keyxmfp"]
    // Each declaration is what SourceKit prints for it on Swift 6.4.2, between the tags of its kind.
    private static let declarations: [(String, String, [String])] = [
        (
            "protocol",
            #"\#(keyword("protocol")) <decl.name>Mid</decl.name> : <ref.protocol usr="s:SE">Encodable</ref.protocol>"#,
            ["s:SE"]
        ),
        (
            "protocol",
            "\(keyword("protocol")) <decl.name>Outer</decl.name> : \(sendable), "
                + #"<ref.protocol usr="s:6Vendor3MidP">Mid</ref.protocol>"#,
            ["s:s8SendableP", "s:6Vendor3MidP"]
        ),
        (
            "typealias",
            "\(keyword("typealias")) <decl.name>Coding</decl.name> = \(decodable) &amp; \(sendable)",
            ["s:Se", "s:s8SendableP"]
        ),
        (
            "protocol",
            #"\#(keyword("protocol")) <decl.name>Source</decl.name> : "#
                + #"<ref.protocol usr="s:ST">Sequence</ref.protocol>\#(whereSelf(of: "6SourceP"))"#
                + #"<ref.associatedtype usr="s:ST7ElementQa">Element</ref.associatedtype> : "#
                + "\(decodable)</decl.generic_type_requirement>",
            ["s:ST"]
        ),
        ("protocol", "\(keyword("protocol")) <decl.name>Empty</decl.name>", []),
        // What comes before the colon or the equals sign is the name with its primary associated types or its
        // generic parameters.
        (
            "protocol",
            #"\#(keyword("protocol")) <decl.name>Boxes</decl.name>&lt;<decl.generic_type_param "#
                + #"usr="s:6Vendor5BoxesP4ItemQa"><ref.associatedtype usr="s:6Vendor5BoxesP4ItemQa">Item"#
                + "</ref.associatedtype></decl.generic_type_param>&gt;",
            []
        ),
        (
            "protocol",
            #"\#(keyword("protocol")) <decl.name>Tray</decl.name>&lt;<decl.generic_type_param "#
                + #"usr="s:6Vendor3BoxP4ItemQa">\#(item)</decl.generic_type_param>&gt; : "#
                + #"<ref.protocol usr="s:6Vendor3BoxP">Box</ref.protocol>\#(whereSelf(of: "4TrayP"))\#(item) : "#
                + "\(sendable)</decl.generic_type_requirement>",
            ["s:6Vendor3BoxP"]
        ),
        (
            "protocol",
            #"\#(keyword("protocol")) <decl.name>Hashable</decl.name> : "#
                + #"<ref.protocol usr="s:SQ">Equatable</ref.protocol>, ~Copyable, ~Escapable"#,
            ["s:SQ"]
        ),
        // An attribute and the type that the declaration is nested in come before the name.
        (
            "protocol",
            #"<syntaxtype.attribute.builtin><syntaxtype.attribute.name>@<ref.class usr="s:ScM">MainActor"#
                + "</ref.class></syntaxtype.attribute.name></syntaxtype.attribute.builtin> "
                + #"\#(keyword("protocol")) <decl.name>Main</decl.name> : \#(sendable)"#,
            ["s:s8SendableP"]
        ),
        (
            "typealias",
            #"\#(keyword("typealias")) <ref.struct usr="s:6Vendor5OuterV">Outer</ref.struct>."#
                + #"<decl.name>Inner</decl.name> = <ref.protocol usr="s:SH">Hashable</ref.protocol> &amp; "#
                + sendable,
            ["s:SH", "s:s8SendableP"]
        ),
        // A struct, a class or a generic parameter that a type alias stands for is no protocol or type alias.
        (
            "typealias",
            #"\#(keyword("typealias")) <decl.name>Keyed</decl.name>&lt;<decl.generic_type_param "#
                + #"usr="s:6Vendor5Keyeda3Keyxmfp"><decl.generic_type_param.name>Key</decl.generic_type_param.name>"#
                + #"</decl.generic_type_param>&gt; = [\#(key) : <ref.struct usr="s:Si">Int</ref.struct>] "#
                + #"\#(keyword("where")) <decl.generic_type_requirement>\#(key) : "#
                + #"<ref.protocol usr="s:SH">Hashable</ref.protocol></decl.generic_type_requirement>"#,
            ["s:6Vendor5Keyeda3Keyxmfp", "s:Si"]
        ),
        (
            "typealias",
            #"\#(keyword("typealias")) <decl.name>Rooted</decl.name> = <ref.class usr="s:6Vendor4RootC">Root"#
                + #"</ref.class> &amp; <ref.protocol usr="s:6Vendor3MidP">Mid</ref.protocol>"#,
            ["s:6Vendor4RootC", "s:6Vendor3MidP"]
        ),
        (
            "typealias",
            #"\#(keyword("typealias")) <decl.name>Qualified</decl.name> = "#
                + #"<ref.typealias usr="s:s7Codablea">Codable</ref.typealias>"#,
            ["s:s7Codablea"]
        ),
        // A class passes its coding on to a subclass as it is, without the stored properties of the subclass.
        (
            "class",
            #"\#(keyword("class")) <decl.name>Base</decl.name> : "#
                + #"<ref.typealias usr="s:s7Codablea">Codable</ref.typealias>"#,
            []
        ),
        ("struct", "\(keyword("struct")) <decl.name>Value</decl.name> : \(decodable)", []),
    ]

    @Test(arguments: declarations)
    func inheritedTypesAreTheOnesOfAProtocolOrATypeAliasBeforeItsRequirements(
        kind: String, declaration: String, inherited: [String]
    ) {
        let cursorInfo = [
            "key.kind": "source.lang.swift.decl.\(kind)",
            "key.fully_annotated_decl": "<decl.\(kind)>\(declaration)</decl.\(kind)>",
        ]
        let expected = UnusedDeclarationUsage.InheritedTypes(
            all: Set(inherited), protocolsAndTypeAliases: Set(inherited).subtracting(Self.otherKinds)
        )
        #expect(UnusedDeclarationUsage.inheritedTypes(inCursorInfo: cursorInfo) == expected)
    }

    private static func keyword(_ keyword: String) -> String {
        "<syntaxtype.keyword>\(keyword)</syntaxtype.keyword>"
    }

    private static func whereSelf(of mangledProtocol: String) -> String {
        " \(keyword("where")) <decl.generic_type_requirement><ref.generic_type_param "
            + #"usr="s:6Vendor\#(mangledProtocol)4Selfxmfp">Self</ref.generic_type_param>."#
    }

    @Test
    func typesThatNoFileDeclaresAreAskedOnceForAllFilesWithTheSameCompilerArguments() {
        let local = "s:6Sample5LocalP", outer = "s:6Vendor5OuterP", middle = "s:6Vendor3MidP"
        let alias = "s:6Vendor5Aliasa", hashable = "s:SH", equatable = "s:SQ"
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
            // What these inherit from is not asked.
            alias: Self.otherKinds,
        ]
        var asked = [Question](), released = [Question]()
        let sourceKit = UnusedDeclarationUsage.InheritanceSource(
            inheritedTypes: { usr, file, compilerArguments in
                asked.append(Question(usr: usr, path: file.path?.filepath, compilerArguments: compilerArguments))
                let all = answers[usr] ?? []
                return UnusedDeclarationUsage.InheritedTypes(
                    all: all, protocolsAndTypeAliases: all.subtracting(Self.otherKinds)
                )
            },
            release: { file, compilerArguments in
                released.append(Question(usr: "", path: file.path?.filepath, compilerArguments: compilerArguments))
            }
        )

        let inherited = UnusedDeclarationUsage.inheritanceOfTypesDeclaredElsewhere(
            collectedInfo, ["s:6Sample5ModelV", local], sourceKit: sourceKit
        )

        // The first file in the order of the paths asks for all files that are compiled like it. It asks
        // neither about what a file declares nor about a declaration of C, and of what an answer names only
        // about protocols and type aliases.
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
