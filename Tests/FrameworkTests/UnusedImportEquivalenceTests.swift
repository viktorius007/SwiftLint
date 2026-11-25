import Foundation
import SourceKittenFramework
import SwiftLintCore
import TestHelpers
import Testing

@testable import SwiftLintFramework

@Suite(.serialized, .rulesRegistered)
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

    @Test(.temporaryDirectory)
    func fileWithOnlyInactiveCodeUsesNoModule() throws {
        let linters = try makeLinters(
            sources: ["let example = 42\n", "#if NEVER_DEFINED\nlet example = 42\n#endif\n"],
            compilerFlags: ["-Xfrontend", "-public-module-name", "-Xfrontend", "Advertised"],
            requireExplicitImports: true
        )
        let findings = linters.map { linter in
            let storage = RuleStorage()
            return linter.collect(into: storage).styleViolations(using: storage).map(\.reason)
        }

        #expect(findings == [["Missing import for referenced module 'Advertised'"], []])
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

    @Test(.temporaryDirectory)
    func modulesAreToldApartAcrossClientsEvenIfOneTakesTheABINameOfTheOther() throws {
        // Both modules give their `answer()` the USR that names the first module.
        let canonical = "UnusedImportCanonicalLib"
        let alias = "UnusedImportAliasLib"
        try compileModule(named: canonical, source: "public func answer() -> Int { 1 }")
        try compileModule(
            named: alias,
            source: "public func answer() -> Int { 1 }",
            flags: ["-Xfrontend", "-module-abi-name", "-Xfrontend", canonical]
        )

        // The two clients are compiled with different arguments, like the files of two modules.
        for moduleName in [canonical, alias] {
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

    @Test(.temporaryDirectory)
    func filesOfOneModuleCanUseModulesWithTheSameABIName() throws {
        let abiName = ["-Xfrontend", "-module-abi-name", "-Xfrontend", "UnusedImportSharedABIInOneModule"]
        let moduleNames = ["UnusedImportFirstLib", "UnusedImportSecondLib"]
        for moduleName in moduleNames {
            try compileModule(named: moduleName, source: "public func answer() -> Int { 1 }", flags: abiName)
        }

        let linters = try makeLinters(
            sources: moduleNames.map { "import \($0)\n\npublic func use\($0)() -> Int { answer() }\n" },
            compilerFlags: ["-I", URL.cwd.filepath],
            requireExplicitImports: true
        )
        for linter in linters {
            let storage = RuleStorage()
            #expect(linter.collect(into: storage).styleViolations(using: storage).isEmpty)
        }
    }

    @Test(.temporaryDirectory)
    func oneFileCanUseModulesWithTheSameABIName() throws {
        let abiName = ["-Xfrontend", "-module-abi-name", "-Xfrontend", "UnusedImportSharedABIInOneFile"]
        try compileModule(
            named: "UnusedImportDisfavoredLib",
            source: "@_disfavoredOverload public func answer() -> Int { 1 }",
            flags: abiName
        )
        try compileModule(named: "UnusedImportFavoredLib", source: "public func answer() -> Int { 2 }", flags: abiName)

        let linter = try makeLinter(
            source: """
                import UnusedImportDisfavoredLib
                import UnusedImportFavoredLib

                public func answers() -> (Int, Int) {
                    (UnusedImportDisfavoredLib.answer(), answer())
                }

                """,
            compilerFlags: ["-I", URL.cwd.filepath]
        )
        let storage = RuleStorage()

        #expect(linter.collect(into: storage).styleViolations(using: storage).isEmpty)
    }

    @Test(.temporaryDirectory)
    func systemExtensionInitializerCanBeMissingFromTheIndex() throws {
        let moduleName = "UnusedImportSystemExtension"
        try compileModule(named: moduleName, source: Self.hiddenInitializer)

        let linter = try makeLinter(
            source: """
                import \(moduleName)
                public let prior: Int = 0
                public let answer = Int((20, 22))

                """,
            compilerFlags: ["-Xfrontend", "-Isystem", "-Xfrontend", URL.cwd.filepath]
        )
        let storage = RuleStorage()

        #expect(linter.collect(into: storage).styleViolations(using: storage).isEmpty)
    }

    @Test(.temporaryDirectory)
    func indexedTypeReferenceDoesNotInheritAnInitializerFromAnotherFile() throws {
        let moduleName = "UnusedImportSystemInitializers"
        try compileModule(named: moduleName, source: Self.hiddenInitializer)

        let linters = try makeLinters(
            sources: [
                "import \(moduleName)\npublic let answer = Int((20, 22))\n",
                "import \(moduleName)\npublic let annotated: Int = 0\n",
                "public let noImport: Int = 0\n",
            ],
            compilerFlags: ["-Xfrontend", "-Isystem", "-Xfrontend", URL.cwd.filepath],
            requireExplicitImports: true
        )
        let storage = RuleStorage()

        let findings = linters.map { $0.collect(into: storage) }.map { linter in
            linter.styleViolations(using: storage).map(\.reason)
        }
        #expect(findings == [[], ["All imported modules should be required to make the file compile"], []])
    }

    @Test(.temporaryDirectory)
    func functionNameCanContainAnExtensionModuleMangle() throws {
        let first = "LibOne"
        let second = "LibTwo"
        let name = "x6LibOneE"
        let abiName = ["-Xfrontend", "-module-abi-name", "-Xfrontend", "UnusedSharedABI"]
        try compileModule(
            named: first,
            source: "@_disfavoredOverload public func \(name)() -> Int { 1 }",
            flags: abiName
        )
        try compileModule(named: second, source: "public func \(name)() -> Int { 2 }", flags: abiName)

        let linter = try makeLinter(
            source: """
                import \(first)
                import \(second)

                public func answers() -> (Int, Int) { (\(first).\(name)(), \(name)()) }

                """,
            compilerFlags: ["-I", URL.cwd.filepath]
        )
        let storage = RuleStorage()

        #expect(linter.collect(into: storage).styleViolations(using: storage).isEmpty)
    }

    /// The index of SourceKit leaves out declarations of system modules whose names start with an underscore.
    private static let hiddenInitializer = """
        public extension Int {
            init(_ _parts: (Int, Int)) { self = _parts.0 + _parts.1 }
        }
        """
    #endif

    private func makeLinter(
        source: String,
        compilerFlags: [String] = [],
        requireExplicitImports: Bool = false,
        fileName: String = "Input.swift"
    ) throws -> Linter {
        try makeLinters(
            sources: [source],
            compilerFlags: compilerFlags,
            requireExplicitImports: requireExplicitImports,
            fileNames: [fileName]
        )[0]
    }

    /// Returns one linter per source. All sources belong to one module and share its compiler arguments.
    private func makeLinters(
        sources: [String],
        compilerFlags: [String] = [],
        requireExplicitImports: Bool = false,
        fileNames: [String]? = nil
    ) throws -> [Linter] {
        let files = try zip(sources, fileNames ?? sources.indices.map { "Input\($0).swift" }).map { source, name in
            let path = URL.cwd.appending(path: name)
            try source.write(to: path, atomically: true, encoding: .utf8)
            return try #require(SwiftLintFile(path: path, isTestFile: true))
        }
        let configuration = try Configuration(dict: [
            "only_rules": ["unused_import"],
            "unused_import": ["require_explicit_imports": requireExplicitImports],
        ])
        let arguments = try #require(files.first).makeCompilerArguments()
            + files.dropFirst().compactMap { $0.path?.filepath }
            + ["-module-name", "UnusedImportEquivalence"]
            + compilerFlags
        return files.map { Linter(file: $0, configuration: configuration, compilerArguments: arguments) }
    }
}

#if !os(Windows)
/// Compiles the source into a module in the current directory.
func compileModule(named moduleName: String, source: String, flags: [String] = []) throws {
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
