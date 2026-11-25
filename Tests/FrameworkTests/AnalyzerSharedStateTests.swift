import Dispatch
import Foundation
import SourceKittenFramework
import SwiftLintCore
import TestHelpers
import Testing

@testable import SwiftLintFramework

@Suite(.rulesRegistered)
struct AnalyzerSharedStateTests {
    @Test
    func summaryReadAfterCollectionIncludesNewFile() {
        let storage = SendableStorage()
        storage.collect("first")
        let snapshotTaken = DispatchSemaphore(value: 0)
        let collectionFinished = DispatchSemaphore(value: 0)
        let firstSummaryFinished = DispatchGroup()

        DispatchQueue.global().async(group: firstSummaryFinished) {
            _ = storage.value.summary(for: storage.rule) { info in
                snapshotTaken.signal()
                #expect(collectionFinished.wait(timeout: .now() + 10) == .success)
                return info.values.sorted()
            }
        }

        #expect(snapshotTaken.wait(timeout: .now() + 10) == .success)
        storage.collect("second")
        #expect(storage.summary() == ["first", "second"])
        collectionFinished.signal()
        #expect(firstSummaryFinished.wait(timeout: .now() + 10) == .success)
        #expect(storage.summary() == ["first", "second"])
    }

    @Test
    func concurrentPerFileReadsSeeTheirOwnCollectedInfo() {
        let storage = SendableStorage()
        let files = (0..<32).map { SwiftLintFile(contents: String($0)) }
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            let file = files[index]
            #expect(storage.value.collectedInfo(for: storage.rule, file: file) == nil)
            storage.rule.collectInfo(for: file, into: storage.value, compilerArguments: [])
            #expect(storage.value.collectedInfo(for: storage.rule, file: file) == String(index))
        }
        #expect(storage.value.collectedInfo(for: storage.rule, file: SwiftLintFile(contents: "0")) == nil)
        for (index, file) in files.enumerated() {
            #expect(storage.value.collectedInfo(for: storage.rule, file: file) == String(index))
        }
    }

    @Test(.temporaryDirectory)
    func concurrentIndexesUseTheirOwnCompilerArguments() throws {
        let file = try makeIndexFile()
        let flags = file.makeCompilerArguments() + ["-module-name", "SharedStateIndex"]
        let configurations = [
            (arguments: flags + ["-D", "FIRST"], expected: "first"),
            (arguments: flags, expected: "second"),
        ]
        let path = try #require(file.path)
        for configuration in configurations {
            let freshFile = try #require(SwiftLintFile(path: path, isTestFile: true))
            #expect(indexedFunctions(in: freshFile, arguments: configuration.arguments) == [configuration.expected])
        }

        DispatchQueue.concurrentPerform(iterations: configurations.count) { index in
            let configuration = configurations[index]
            #expect(indexedFunctions(in: file, arguments: configuration.arguments) == [configuration.expected])
        }
    }

    @Test(.temporaryDirectory)
    func concurrentIndexesWithIdenticalArgumentsShareOneRequest() throws {
        let file = try makeIndexFile()
        let arguments = file.makeCompilerArguments() + ["-module-name", "SharedStateIndex", "-D", "FIRST"]
        let requests = RequestCounter()
        let recordIndex: @Sendable (Request) -> Void = { requests.recordIndex($0) }
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            SourceKitRequestObserver.$current.withValue(recordIndex) {
                #expect(indexedFunctions(in: file, arguments: arguments) == ["first"])
            }
        }
        #expect(requests.count == 1)

        file.invalidateCache()
        SourceKitRequestObserver.$current.withValue(recordIndex) {
            #expect(indexedFunctions(in: file, arguments: arguments) == ["first"])
        }
        #expect(requests.count == 2)
    }

    @Test(.temporaryDirectory)
    func invalidationKeepsAnInFlightIndexFromReplacingTheNewValue() throws {
        let file = try makeIndexFile()
        let arguments = file.makeCompilerArguments() + ["-module-name", "SharedStateIndex"]
        let oldRequestStarted = DispatchSemaphore(value: 0)
        let newIndexCached = DispatchSemaphore(value: 0)
        let oldRequestFinished = DispatchGroup()
        let waitDuringIndexRequest: @Sendable (Request) -> Void = { request in
            if request.description.contains("source.request.indexsource") {
                oldRequestStarted.signal()
                #expect(newIndexCached.wait(timeout: .now() + 10) == .success)
            }
        }
        DispatchQueue.global().async(group: oldRequestFinished) {
            SourceKitRequestObserver.$current.withValue(waitDuringIndexRequest) {
                #expect(indexedFunctions(in: file, arguments: arguments + ["-D", "FIRST"]) == ["first"])
            }
        }

        #expect(oldRequestStarted.wait(timeout: .now() + 10) == .success)
        file.invalidateCache()
        #expect(indexedFunctions(in: file, arguments: arguments) == ["second"])
        newIndexCached.signal()
        #expect(oldRequestFinished.wait(timeout: .now() + 10) == .success)
        #expect(indexedFunctions(in: file, arguments: arguments) == ["second"])
    }

    @Test
    func concurrentSwiftTasksHaveIsolatedRequestObservers() async {
        let outer = RequestCounter()
        let scoped = [RequestCounter(), RequestCounter()]
        let recordOuter: @Sendable (Request) -> Void = { outer.record($0) }
        await SourceKitRequestObserver.$current.withValue(recordOuter) {
            await withTaskGroup(of: Void.self) { group in
                for counter in scoped {
                    group.addTask {
                        let recordScoped: @Sendable (Request) -> Void = { counter.record($0) }
                        SourceKitRequestObserver.$current.withValue(recordScoped) {
                            sendEditorRequest()
                        }
                        sendEditorRequest()
                    }
                }
            }
        }
        #expect(scoped.map(\.count) == [1, 1])
        #expect(outer.count == 2)
    }

    private func makeIndexFile() throws -> SwiftLintFile {
        let path = URL.cwd.appending(path: "Input.swift")
        try """
            #if FIRST
            public func first() {}
            #else
            public func second() {}
            #endif

            """.write(to: path, atomically: true, encoding: .utf8)
        return try #require(SwiftLintFile(path: path, isTestFile: true))
    }

    private func indexedFunctions(in file: SwiftLintFile, arguments: [String]) -> [String]? {
        CurrentRule.$allowSourceKitRequestWithoutRule.withValue(true) {
            let index = file.index(compilerArguments: arguments)
            return index?.traverseEntitiesDepthFirst { _, entity in
                entity.kind == "source.lang.swift.decl.function.free"
                    ? entity.name?.components(separatedBy: "(").first : nil
            }
        }
    }

    private func sendEditorRequest() {
        CurrentRule.$allowSourceKitRequestWithoutRule.withValue(true) {
            do {
                let file = File(contents: "// \(UUID())\nlet value = 1")
                _ = try Request.editorOpen(file: file).sendIfNotDisabled()
            } catch {
                Issue.record(error)
            }
        }
    }
}

private final class SendableStorage: @unchecked Sendable {
    let value = RuleStorage()
    let rule = SharedStateCollectingRule()

    func collect(_ text: String) {
        rule.collectInfo(for: SwiftLintFile(contents: text), into: value, compilerArguments: [])
    }

    func summary() -> [String] {
        value.summary(for: rule) { $0.values.sorted() }
    }
}

private struct SharedStateCollectingRule: CollectingRule {
    var configuration = SeverityConfiguration<Self>(.warning)

    @RuleConfigurationDescriptionBuilder
    var configurationDescription: some Documentable { RuleConfigurationOption.noOptions }

    static var description: RuleDescription {
        RuleDescription(identifier: "mock_test_rule_for_swiftlint_tests", name: "", description: "", kind: .lint)
    }

    init() { /* Nothing to configure. */ }
    init(configuration _: Any) { /* Nothing to configure. */ }

    func collectInfo(for file: SwiftLintFile) -> String { file.contents }

    func validate(file _: SwiftLintFile, collectedInfo _: [SwiftLintFile: String]) -> [StyleViolation] { [] }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    var count: Int { lock.withLock { total } }

    func record(_: Request) {
        lock.withLock { total += 1 }
    }

    func recordIndex(_ request: Request) {
        if request.description.contains("source.request.indexsource") {
            record(request)
        }
    }
}
