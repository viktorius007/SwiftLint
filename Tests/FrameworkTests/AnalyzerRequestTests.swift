import Foundation
import SourceKittenFramework
import SwiftLintCore
import TestHelpers
import Testing

@testable import SwiftLintFramework

@Suite(.serialized, .rulesRegistered, .ownThreads)
struct AnalyzerRequestTests {
    private static let typeCheckingRequests: Set = [
        "source.request.cursorinfo",
        "source.request.indexsource",
        "source.request.semantic_tokens",
    ]

    private static let contents = """
        import Foundation

        func sum(of values: [Int]) -> Int {
            var total = 0
            for value in values {
                total = total + value
                total = total + value
                total = total + value
            }
            return total
        }

        let first = sum(of: [1])
        let second = sum(of: [2])
        let third = sum(of: [3])

        """

    @Test
    func analyzerRulesAskSourceKitInOnePassAndThenReleaseTheSyntaxTree() throws {
        // The capture list gives `capture_variable` something to look up for its second set.
        let contents = Self.contents + "var counter = 0\nlet closure = { [counter] in counter }\n"
        let file = SwiftLintFile.testFile(withContents: contents, persistToDisk: true)
        let path = try #require(file.path?.filepath)
        let configuration = Configuration(
            rulesMode: .onlyConfiguration(["capture_variable", "unused_declaration", "unused_import"])
        )
        let compilerArguments = file.makeCompilerArguments() + ["-module-name", "ReleasedModule"]
        let linter = Linter(file: file, configuration: configuration, compilerArguments: compilerArguments)
        let storage = RuleStorage()

        var collectedLinter: CollectedLinter?
        let whileCollecting = requests { collectedLinter = linter.collect(into: storage) }
        let whileValidating = requests { _ = collectedLinter?.styleViolations(using: storage) }

        // All three rules read the index, and SourceKit type-checks the file again for every index request.
        #expect(whileCollecting.count { $0.name == "source.request.indexsource" } == 1)
        #expect(whileCollecting.contains { $0.name == "source.request.cursorinfo" })

        // Closing an editor document with the file's compiler arguments is what makes SourceKit drop the
        // type-checked syntax tree. It has to come after the last request that needs the tree.
        let release = whileCollecting.suffix(2)
        let namesOfRelease: [String] = release.map(\.name)
        #expect(namesOfRelease == ["source.request.editor.open", "source.request.editor.close"])
        #expect(release.allSatisfy { $0.description.contains(path) })
        // SourceKit finds the tree by the compiler arguments. Other arguments would release nothing.
        #expect(release.first?.description.contains("ReleasedModule") == true)

        // A request while validating would make SourceKit build the tree a second time.
        #expect(!whileValidating.contains { Self.typeCheckingRequests.contains($0.name) })
    }

    @Test(arguments: ["\n", "\r\n"])
    func unusedImportAsksOncePerDistinctDeclaration(lineEnding: String) {
        let contents = Self.contents.replacingOccurrences(of: "\n", with: lineEnding)
        let file = SwiftLintFile.testFile(withContents: contents, persistToDisk: true)
        let configuration = Configuration(rulesMode: .onlyConfiguration(["unused_import"]))
        let compilerArguments = file.makeCompilerArguments() + ["-module-name", "Sample"]
        let linter = Linter(file: file, configuration: configuration, compilerArguments: compilerArguments)

        let cursorInfoRequests = requests { _ = linter.collect(into: RuleStorage()) }
            .count { $0.name == "source.request.cursorinfo" }

        // The file has 36 tokens that can refer to a module. Only five of them need a request: `Foundation`, the
        // name `sum` in its declaration (which tells how SourceKit names the module being compiled), the first
        // `Int`, the first `+` and the first use of `sum`. Other declaration names, local variables, argument
        // labels and repeated references need none. The index tells what they refer to, by line and column.
        #expect(cursorInfoRequests == 5)
    }

    @Test
    func summaryOfCollectedInfoIsComputedOncePerCollection() {
        struct Spec: MockCollectingRule {
            var configuration = SeverityConfiguration<Self>(.warning)

            func collectInfo(for file: SwiftLintFile) -> String {
                file.contents
            }

            func validate(file _: SwiftLintFile, collectedInfo _: [SwiftLintFile: String]) -> [StyleViolation] {
                []
            }
        }

        let rule = Spec()
        let storage = RuleStorage()
        var computations = 0
        let summary = {
            storage.summary(for: rule) { collectedInfo -> [String] in
                computations += 1
                return collectedInfo.values.sorted()
            }
        }

        rule.collectInfo(for: SwiftLintFile(contents: "a"), into: storage, compilerArguments: [])
        rule.collectInfo(for: SwiftLintFile(contents: "b"), into: storage, compilerArguments: [])
        #expect(summary() == ["a", "b"])
        #expect(summary() == ["a", "b"])
        #expect(computations == 1)

        rule.collectInfo(for: SwiftLintFile(contents: "c"), into: storage, compilerArguments: [])
        #expect(summary() == ["a", "b", "c"])
        #expect(computations == 2)
    }

    /// Returns the requests that `body` sends to SourceKit, in order.
    private func requests(sentBy body: () -> Void) -> [SentRequest] {
        let log = RequestLog()
        SourceKitRequestObserver.$current.withValue({ log.append(SentRequest($0)) }, operation: body)
        return log.requests
    }
}

private struct SentRequest {
    let name: String
    let description: String

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

private protocol MockCollectingRule: CollectingRule {}
extension MockCollectingRule {
    @RuleConfigurationDescriptionBuilder
    var configurationDescription: some Documentable { RuleConfigurationOption.noOptions }
    static var description: RuleDescription {
        RuleDescription(identifier: "mock_test_rule_for_swiftlint_tests", name: "", description: "", kind: .lint)
    }

    init(configuration _: Any) { self.init() }
}
