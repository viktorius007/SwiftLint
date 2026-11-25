import Foundation
import SourceKittenFramework
import SwiftLintCore
import TestHelpers
import Testing

@testable import SwiftLintFramework

@Suite(.serialized, .rulesRegistered)
struct TestingMacroArgumentsTests {
    /// What names a plugin that cannot be loaded for the macros of Swift Testing.
    private static let marker = "/dev/null/no-expansion#TestingMacros"
    private static let argumentsWithoutExpansion = ["-Xfrontend", "-load-plugin-executable", "-Xfrontend", marker]

    // Each rule finds something to ask SourceKit about: a captured variable, a member used without `self`, an
    // array made with `map`, and tokens that can refer to a module.
    private static let contents = """
        import Testing

        struct Counter {
            var count = 0
            func current() -> Int { count }
        }

        @Test func example() {
            var counter = Counter().current()
            let closure = { [counter] in counter }
            counter += closure()
            #expect([Int](repeating: counter, count: 1).map { $0 } == [0])
        }

        """

    @Test(arguments: [
        "import Testing\n",
        "@testable import Testing\n",
        "import struct Testing.Tag\n",
        "import Foundation\n#if canImport(Testing)\nimport Testing\n#endif\n",
        "#if os(Linux)\nimport Foundation\n#else\nimport Testing\n#endif\n",
        "#if DEBUG\n#if canImport(Testing)\nimport Testing\n#endif\n#endif\n",
    ])
    func fileThatImportsTestingGetsArgumentsThatKeepItsMacrosUnexpanded(contents: String) {
        let file = SwiftLintFile(contents: contents)
        let arguments = file.compilerArgumentsWithoutTestingMacros(["-module-name", "Sample"])
        // The compiler takes the first plugin named for a module, so the arguments have to come first.
        #expect(arguments == Self.argumentsWithoutExpansion + ["-module-name", "Sample"])
    }

    @Test(arguments: [
        "import Foundation\n",
        "import TestingSupport\n",
        "import XCTest.Testing\n",
        "// import Testing\nimport Foundation\n",
        "let text = \"\"\"\n    import Testing\n    \"\"\"\n",
        "struct Testing {}\n",
    ])
    func fileThatDoesNotImportTestingKeepsItsArguments(contents: String) {
        let file = SwiftLintFile(contents: contents)
        #expect(file.compilerArgumentsWithoutTestingMacros(["-module-name", "Sample"]) == ["-module-name", "Sample"])
    }

    @Test
    func lintingWithoutCompilerArgumentsStaysWithoutThem() {
        #expect(SwiftLintFile(contents: "import Testing\n").compilerArgumentsWithoutTestingMacros([]).isEmpty)
    }

    @Test
    func analyzerRulesAskWithoutMacroExpansion() {
        let rules = ["capture_variable", "explicit_self", "typesafe_array_init", "unused_declaration", "unused_import"]
        let (whileCollecting, whileValidating) = requests(sentBy: rules, analyzing: Self.contents)

        let typeChecks = (whileCollecting + whileValidating).filter(\.needsTypeCheck)
        #expect(typeChecks.contains { $0.name == "source.request.cursorinfo" })
        let typeChecksWithExpansion: [String] = typeChecks.filter { !$0.keepsMacrosUnexpanded }.map(\.name)
        #expect(typeChecksWithExpansion.isEmpty)
        // The rules that read the index share one, as they do for a file without macros.
        #expect(whileCollecting.count { $0.name == "source.request.indexsource" } == 1)
        #expect(!whileValidating.contains { $0.name == "source.request.indexsource" })
    }

    @Test
    func syntaxTreeIsReleasedWithTheArgumentsItWasBuiltWith() {
        let (whileCollecting, whileValidating) = requests(sentBy: ["explicit_self", "unused_import"],
                                                          analyzing: Self.contents)

        // SourceKit finds a tree by the compiler arguments it was built with. Closing an editor document that
        // was opened with them is what drops it.
        for requests in [whileCollecting, whileValidating] {
            let release = requests.suffix(2)
            let namesOfRelease: [String] = release.map(\.name)
            #expect(namesOfRelease == ["source.request.editor.open", "source.request.editor.close"])
            #expect(release.first?.keepsMacrosUnexpanded == true)
            #expect(release.first?.description.contains("ReleasedModule") == true)
        }
    }

    @Test
    func correctingAsksWithoutMacroExpansion() {
        let file = SwiftLintFile.testFile(withContents: Self.contents, persistToDisk: true)
        let configuration = Configuration(rulesMode: .onlyConfiguration(["explicit_self"]))
        let compilerArguments = file.makeCompilerArguments() + ["-module-name", "ReleasedModule"]
        let linter = Linter(file: file, configuration: configuration, compilerArguments: compilerArguments)
        let storage = RuleStorage()
        let collectedLinter = linter.collect(into: storage)

        let whileCorrecting = requests { _ = collectedLinter.correct(using: storage) }

        let cursorInfoRequests = whileCorrecting.filter { $0.name == "source.request.cursorinfo" }
        #expect(cursorInfoRequests.isNotEmpty)
        let requestsWithExpansion: [String] = cursorInfoRequests.filter { !$0.keepsMacrosUnexpanded }.map(\.name)
        #expect(requestsWithExpansion.isEmpty)
        let release = whileCorrecting.suffix(2)
        let namesOfRelease: [String] = release.map(\.name)
        #expect(namesOfRelease == ["source.request.editor.open", "source.request.editor.close"])
        #expect(release.first?.keepsMacrosUnexpanded == true)
    }

    @Test
    func fileWithoutTestingIsAnalyzedWithItsArguments() {
        let contents = Self.contents.replacingOccurrences(of: "import Testing", with: "import Foundation")
        let rules = ["capture_variable", "typesafe_array_init", "unused_declaration", "unused_import"]
        let (whileCollecting, whileValidating) = requests(sentBy: rules, analyzing: contents)

        #expect(whileCollecting.contains { $0.name == "source.request.indexsource" })
        let requestsWithoutExpansion: [String] = (whileCollecting + whileValidating)
            .filter(\.keepsMacrosUnexpanded)
            .map(\.name)
        #expect(requestsWithoutExpansion.isEmpty)
    }

    #if os(Linux)
    // On Linux, the compiler finds Swift Testing and its macros without further arguments.
    @Test
    func argumentsKeepTheCompilerFromExpandingTestingMacros() throws {
        let file = SwiftLintFile.testFile(withContents: Self.contents, persistToDisk: true)
        let arguments = file.makeCompilerArguments() + ["-module-name", "Sample"]

        // `@Test` expands to code that calls the test. So a reference to the test tells that it was expanded.
        let reduced = file.compilerArgumentsWithoutTestingMacros(arguments)
        let references = try referencesToExample(in: file, compilerArguments: arguments)
        let referencesWithoutExpansion = try referencesToExample(in: file, compilerArguments: reduced)
        #expect(references == 1)
        #expect(referencesWithoutExpansion == 0)
    }

    private func referencesToExample(in file: SwiftLintFile, compilerArguments: [String]) throws -> Int {
        let index = try #require(CurrentRule.$allowSourceKitRequestWithoutRule.withValue(true) {
            file.index(compilerArguments: compilerArguments)
        })
        let usrOfExample = "s:6Sample7exampleyyF"
        return index.traverseEntitiesDepthFirst { _, entity in
            entity.kind == "source.lang.swift.ref.function.free" && entity.value["key.usr"] as? String == usrOfExample
                ? entity : nil
        }.count
    }
    #endif

    /// Returns the requests that the given analyzer rules send to SourceKit for a file with the given contents:
    /// first while they collect, then while they validate.
    private func requests(sentBy rules: [String], analyzing contents: String) -> ([SentRequest], [SentRequest]) {
        let file = SwiftLintFile.testFile(withContents: contents, persistToDisk: true)
        let configuration = Configuration(rulesMode: .onlyConfiguration(Set(rules)))
        let compilerArguments = file.makeCompilerArguments() + ["-module-name", "ReleasedModule"]
        let linter = Linter(file: file, configuration: configuration, compilerArguments: compilerArguments)
        let storage = RuleStorage()

        var collectedLinter: CollectedLinter?
        let whileCollecting = requests { collectedLinter = linter.collect(into: storage) }
        let whileValidating = requests { _ = collectedLinter?.styleViolations(using: storage) }
        return (whileCollecting, whileValidating)
    }

    private func requests(sentBy body: () -> Void) -> [SentRequest] {
        let log = RequestLog()
        SourceKitRequestObserver.$current.withValue({ log.append(SentRequest($0)) }, operation: body)
        return log.requests
    }
}

private struct SentRequest {
    let name: String
    let description: String

    /// Whether SourceKit type-checks the file to answer the request.
    var needsTypeCheck: Bool {
        name == "source.request.cursorinfo" || name == "source.request.indexsource"
    }

    var keepsMacrosUnexpanded: Bool {
        description.contains("/dev/null/no-expansion#TestingMacros")
    }

    init(_ request: Request) {
        description = request.description
        name = description.firstMatch(of: #/source\.request\.[a-z_.]+/#).map { String($0.output) } ?? ""
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log = [SentRequest]()

    var requests: [SentRequest] {
        lock.withLock { log }
    }

    func append(_ request: SentRequest) {
        lock.withLock { log.append(request) }
    }
}
