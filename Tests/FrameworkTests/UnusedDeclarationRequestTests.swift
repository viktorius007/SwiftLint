import Foundation
import SourceKittenFramework
import SwiftLintCore
import TestHelpers
import Testing

/// What the rule asks SourceKit about generated code. A `↓` marks each declaration that is expected to be
/// reported.
@Suite(.serialized, .rulesRegistered, .ownThreads)
struct UnusedDeclarationRequestTests {
    // The rule asks SourceKit about each declaration once. A second question about what a member satisfies is
    // for a type with a conformance that the index leaves out.
    @Test(.temporaryDirectory)
    func memberIsAskedAboutOnceWhereTheIndexHasTheConformancesOfItsType() throws {
        let requests = RequestLog()
        try SourceKitRequestObserver.$current.withValue({ requests.append($0.description) }, operation: {
            try expectOnlyMarkedDeclarationsReported(in: [
                """
                struct Loose {
                    init(from _: Int) {}

                    static func == (_: Loose, _: Loose) -> Bool { true }
                    func encode(to _: Int) {}
                    func ↓hash(into _: Int) {}
                }

                let loose = Loose(from: 1)
                print(loose == loose, loose.encode(to: 1))
                """,
            ])
        })

        let offsets = requests.all.filter { $0.contains("source.request.cursorinfo") }
            .compactMap { $0.firstMatch(of: #/key\.offset: (\d+)/#)?.output.1 }
        #expect(offsets.isNotEmpty)
        #expect(Set(offsets).count == offsets.count)
    }

    // SourceKit tells which module declares a macro. All attributes of a file that refer to one macro share
    // the answer.
    @Test(.temporaryDirectory)
    func macroOfSwiftTestingIsAskedAboutOnceInAFile() throws {
        let source = """
            import Testing

            @Test func first() {}
            @Test func second() {}
            @Test func third() {}
            """
        let requests = RequestLog()
        try SourceKitRequestObserver.$current.withValue({ requests.append($0.description) }, operation: {
            try expectOnlyMarkedDeclarationsReported(in: [source])
        })

        // The index has an attribute at the position of its name.
        let attributes = source.ranges(of: "@Test").map {
            source.utf8.distance(from: source.startIndex, to: $0.lowerBound) + 1
        }
        let asked = requests.all.filter { $0.contains("source.request.cursorinfo") }
            .compactMap { $0.firstMatch(of: #/key\.offset: (\d+)/#).flatMap { Int($0.output.1) } }
        #expect(attributes.count == 3)
        #expect(asked.filter(attributes.contains).count == 1)
    }

    #if !os(Windows)
    @Test(.temporaryDirectory)
    func sourceKitIsAskedAboutProtocolsAndTypeAliasesThatNoFileDeclares() throws {
        try compileModule(
            named: "Vendor",
            source: """
                open class Parent { public init() {} }
                public struct Wrapped<Value> { public init() {} }
                public protocol Inbound: Decodable {}
                public typealias Both = Inbound & Sendable
                public typealias Word = Int
                """
        )
        let sources = [
            """
            import Vendor

            protocol Local: Encodable {}
            """,
            """
            import Vendor

            struct Model: Local {
                var value = 1
                let ↓fixed = 2

                func encode(to _: any Encoder) throws {}
            }

            extension Model: Both {}

            typealias Mine = Both

            final class Child: Parent {}

            typealias Numbers = Wrapped<Model>

            typealias Count = Word

            @main
            struct Entry {
                static func main() { print(Model.self, Child(), Numbers(), Mine.self, Count.self) }
            }
            """,
        ]
        let requests = RequestLog()
        try SourceKitRequestObserver.$current.withValue({ requests.append($0.description) }, operation: {
            try expectOnlyMarkedDeclarationsReported(
                in: sources, compilerFlags: ["-parse-as-library", "-I", URL.cwd.filepath]
            )
        })

        // The index tells that `Parent` is a class and `Wrapped` a struct, and `Local` is declared by a file.
        // What `Encodable`, `Decodable` and `Sendable` inherit from is known. SourceKit tells that `Word` stands
        // for a struct.
        let asked = requests.all.filter { $0.contains("source.request.cursorinfo") && $0.contains("key.usr:") }
        #expect(asked.compactMap { $0.firstMatch(of: #/key\.usr: "([^"]*)"/#).map { String($0.output.1) } }.sorted()
                == ["s:6Vendor4Botha", "s:6Vendor4Worda", "s:6Vendor7InboundP"])
        // One file asks for all, and SourceKit is told to drop what it built for the questions.
        let askingFiles = Set(asked.compactMap { $0.firstMatch(of: #/key\.sourcefile: "([^"]*)"/#)?.output.1 })
        #expect(askingFiles.map { $0.hasSuffix("Input0.swift") } == [true])
        let lastQuestion = try #require(requests.all.lastIndex { asked.contains($0) })
        #expect(requests.all[lastQuestion...].dropFirst().prefix(2).map { request in
            request.contains("Input0.swift") ? request.firstMatch(of: #/source\.request\.[a-z.]+/#)?.output : nil
        } == ["source.request.editor.open", "source.request.editor.close"])
    }
    #endif
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log = [String]()

    var all: [String] {
        lock.withLock { log }
    }

    func append(_ request: String) {
        lock.withLock { log.append(request) }
    }
}
