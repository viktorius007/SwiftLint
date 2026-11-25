import Foundation
import SourceKittenFramework
import SwiftLintCore
import TestHelpers
import Testing

@testable import SwiftLintFramework

@Suite(.rulesRegistered)
struct UnusedImportEquivalenceTests {
    @Test(.temporaryDirectory)
    func cacheUsesSourceKitCoordinatesAfterCRLF() throws {
        let linter = try makeLinter(
            source: "import Dispatch\nfunc example() {\r\n"
                + "    print(0)\n    print(1)\n     dispatchMain()\n     print(2)\n}\n"
        )
        let storage = RuleStorage()

        #expect(linter.collect(into: storage).styleViolations(using: storage).isEmpty)
    }

    @Test(.temporaryDirectory)
    func declarationUsesSourceKitsPublicModuleName() throws {
        let linter = try makeLinter(
            source: "let value = 1\n",
            compilerFlags: ["-Xfrontend", "-public-module-name", "-Xfrontend", "Advertised"],
            requireExplicitImports: true
        )
        let storage = RuleStorage()

        let findings = linter.collect(into: storage).styleViolations(using: storage)
        #expect(findings.map(\.reason) == ["Missing import for referenced module 'Advertised'"])
    }

    #if !os(Windows)
    @Test(.temporaryDirectory)
    func argumentLabelCanReferToAnExtensionOnAnEnumCaseValue() throws {
        let moduleName = "UnusedImportCallableExtensions"
        try compileModule(
            named: moduleName,
            source: """
                public extension Optional {
                    func callAsFunction(value: Int) -> Int { value }
                }
                """
        )

        let linter = try makeLinter(
            source: "import \(moduleName)\n\nlet output = Optional<Int>.none(value: 42)\n",
            compilerFlags: ["-I", URL.cwd.filepath]
        )
        let storage = RuleStorage()

        #expect(linter.collect(into: storage).styleViolations(using: storage).isEmpty)
    }

    @Test(.temporaryDirectory)
    func modulesWithTheSameABINameAreToldApart() throws {
        // Both modules give their `answer()` the same USR.
        let abiName = ["-Xfrontend", "-module-abi-name", "-Xfrontend", "UnusedImportSharedABI"]
        for moduleName in ["UnusedImportLibOne", "UnusedImportLibTwo"] {
            try compileModule(named: moduleName, source: "public func answer() -> Int { 1 }", flags: abiName)
        }

        for moduleName in ["UnusedImportLibOne", "UnusedImportLibTwo"] {
            let linter = try makeLinter(
                source: "import \(moduleName)\n\npublic func use() -> Int { answer() }\n",
                compilerFlags: ["-I", URL.cwd.filepath],
                requireExplicitImports: true,
                fileName: "\(moduleName)Client.swift"
            )
            let storage = RuleStorage()

            #expect(linter.collect(into: storage).styleViolations(using: storage).isEmpty, "\(moduleName)")
        }
    }

    private func compileModule(named moduleName: String, source: String, flags: [String] = []) throws {
        let sourcePath = URL.cwd.appending(path: "\(moduleName).swift")
        try source.write(to: sourcePath, atomically: true, encoding: .utf8)
        let module = URL.cwd.appending(path: "\(moduleName).swiftmodule")
        let compiler = Process()
        compiler.executableURL = URL(filePath: "/usr/bin/env")
        compiler.arguments = [
            "swiftc", "-emit-module", "-module-name", moduleName,
            "-emit-module-path", module.filepath, sourcePath.filepath,
        ] + flags
        try compiler.run()
        compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)
    }
    #endif

    private func makeLinter(
        source: String,
        compilerFlags: [String] = [],
        requireExplicitImports: Bool = false,
        fileName: String = "Input.swift"
    ) throws -> Linter {
        let path = URL.cwd.appending(path: fileName)
        try source.write(to: path, atomically: true, encoding: .utf8)
        let file = try #require(SwiftLintFile(path: path, isTestFile: true))
        let configuration = try Configuration(dict: [
            "only_rules": ["unused_import"],
            "unused_import": ["require_explicit_imports": requireExplicitImports],
        ])
        let arguments = file.makeCompilerArguments() + ["-module-name", "UnusedImportEquivalence"] + compilerFlags
        return Linter(file: file, configuration: configuration, compilerArguments: arguments)
    }
}
