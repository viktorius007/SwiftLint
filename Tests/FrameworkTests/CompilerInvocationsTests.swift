import Foundation
import TestHelpers
import Testing

@testable import SwiftLintFramework

@Suite
struct CompilerInvocationsTests {
    private static let directory = URL(filePath: "/tmp/swiftlint-compiler-invocations", directoryHint: .isDirectory)
    private static let invocation = ["-module-name", "Sample", "/tmp/swiftlint-compiler-invocations/Sources/A.swift"]

    @Test(arguments: [
        URL(filePath: "/tmp/swiftlint-compiler-invocations/Sources/A.swift"),
        URL(filePath: "Sources/A.swift", relativeTo: directory),
        URL(filePath: "Sources/../Sources/./A.swift", relativeTo: directory),
    ])
    func buildLogInvocationIsFoundForAnySpellingOfTheFilePath(path: URL) {
        let invocations = CompilerInvocations.buildLog(compilerInvocations: [Self.invocation])

        #expect(invocations.arguments(forFile: path) == Self.invocation)
    }

    @Test
    func macroPluginPathKeepsItsModuleSeparatorWithoutTheEscapeOfTheBuildLog() {
        let log = ##"swiftc -module-name Sample -external-plugin-path /plugins/testing\#/bin/plugin-server A.swift"##

        let invocations = CompilerArgumentsExtractor.allCompilerInvocations(compilerLogs: log)

        #expect(invocations.first?.contains("/plugins/testing#/bin/plugin-server") == true)
    }

    @Test
    func quotedPathOfABuildLogKeepsItsBackslash() {
        let log = ##"swiftc -module-name Sample "Sources/With\#Hash.swift""##

        let invocations = CompilerArgumentsExtractor.allCompilerInvocations(compilerLogs: log)

        #expect(invocations.first?.contains(##"Sources/With\#Hash.swift"##) == true)
    }

    @Test(.temporaryDirectory)
    func macroPluginPathOfAResponseFileLosesItsEscape() throws {
        let responseFile = URL.cwd.appending(path: "arguments.rsp", directoryHint: .notDirectory)
        try ##"""
            -external-plugin-path
            /plugins/testing\#/bin/plugin-server
            """##.write(to: responseFile, atomically: true, encoding: .utf8)
        let log = "swiftc -module-name Sample @\(responseFile.filepath) A.swift"

        let invocations = CompilerArgumentsExtractor.allCompilerInvocations(compilerLogs: log)

        #expect(invocations.first?.contains("/plugins/testing#/bin/plugin-server") == true)
    }

    @Test
    func argumentThatIsNoPartOfABuildLogKeepsItsBackslash() {
        let path = ##"Sources/With\#Hash.swift"##

        #expect(["-module-name", "Sample", path].filteringCompilerArguments.contains(path))
    }

    @Test
    func buildLogInvocationIsNotFoundForAnotherFile() {
        let invocations = CompilerInvocations.buildLog(compilerInvocations: [Self.invocation])

        #expect(invocations.arguments(forFile: URL(filePath: "Sources/B.swift", relativeTo: Self.directory)).isEmpty)
    }
}
