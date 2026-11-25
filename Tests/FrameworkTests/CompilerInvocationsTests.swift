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

    // What the compiler reads from each line was established with `swiftc -typecheck @file` on Swift 6.4.2.
    private static let responseFileContents: [(String, [String])] = [
        (##"a\\\#b.swift"##, [##"a\#b.swift"##]),
        (#"a\ b.swift"#, ["a b.swift"]),
        (#""a b.swift" 'c d.swift'"#, ["a b.swift", "c d.swift"]),
        (#""a\"b.swift" 'c\'d.swift'"#, [#"a"b.swift"#, "c'd.swift"]),
        (#""a'b.swift""#, ["ab.swift"]),
        (#"a"b c"d.swift"#, ["ab cd.swift"]),
        ("a.swift\tb.swift  c.swift", ["a.swift", "b.swift", "c.swift"]),
        ("// a.swift\nb.swift", ["b.swift"]),
        (#"a\nb.swift"#, ["anb.swift"]),
        (#"a\\=b.swift"#, [#"a\=b.swift"#]),
        (#"a\\\ b.swift"#, [#"a\ b.swift"#]),
        ("a.swift\r\n// b.swift\r\n\"c d.swift\"", ["a.swift", "c d.swift"]),
        ("a.swift\r//b.swift", ["a.swift", "//b.swift"]),
        ("\"a\rb.swift\"", ["a\rb.swift"]),
        ("\"a\u{B}b.swift\"", ["a\u{B}b.swift"]),
        ("\"a\u{C}b.swift\"", ["a\u{C}b.swift"]),
        ("\"a\u{85}b.swift\"", ["a\u{85}b.swift"]),
        ("\"a\u{2028}b.swift\"", ["a\u{2028}b.swift"]),
        ("\"a\u{2029}b.swift\"", ["a\u{2029}b.swift"]),
    ]

    @Test(.temporaryDirectory, arguments: responseFileContents)
    func responseFileIsReadAsTheCompilerReadsIt(contents: String, arguments: [String]) throws {
        let responseFile = URL.cwd.appending(path: "arguments.rsp", directoryHint: .notDirectory)
        try contents.write(to: responseFile, atomically: true, encoding: .utf8)
        let log = "swiftc -module-name Sample @\(responseFile.filepath)"

        let invocations = CompilerArgumentsExtractor.allCompilerInvocations(compilerLogs: log)

        #expect(invocations.first?.filter { $0.hasSuffix(".swift") } == arguments)
    }

    // The compiler warns that the file "is recursively expanded" and goes on without it.
    @Test(.temporaryDirectory)
    func responseFileThatNamesItselfIsExpandedOnce() throws {
        let responseFile = URL.cwd.appending(path: "arguments.rsp", directoryHint: .notDirectory)
        try "A.swift\n@\(responseFile.filepath)\nB.swift\n".write(to: responseFile, atomically: true, encoding: .utf8)
        let log = "swiftc -module-name Sample @\(responseFile.filepath)"

        let invocations = CompilerArgumentsExtractor.allCompilerInvocations(compilerLogs: log)

        #expect(invocations.first?.filter { $0.hasSuffix(".swift") } == ["A.swift", "B.swift"])
    }

    // The compiler compares the paths without `.` and `..`.
    @Test(.temporaryDirectory)
    func responseFileThatNamesItselfByAnotherSpellingIsExpandedOnce() throws {
        let responseFile = URL.cwd.appending(path: "arguments.rsp", directoryHint: .notDirectory)
        try "A.swift\n@\(URL.cwd.filepath)/./arguments.rsp\nB.swift\n"
            .write(to: responseFile, atomically: true, encoding: .utf8)
        let log = "swiftc -module-name Sample @\(responseFile.filepath)"

        let invocations = CompilerArgumentsExtractor.allCompilerInvocations(compilerLogs: log)

        #expect(invocations.first?.filter { $0.hasSuffix(".swift") } == ["A.swift", "B.swift"])
    }

    // The compiler takes `.` and `..` out of the path and opens what is left. So it never looks for the
    // directory before `..`, and it does not follow that directory if it is a symbolic link.
    @Test(.temporaryDirectory, arguments: ["missing", "link"])
    func responseFileIsOpenedByItsPathWithoutParentDirectories(directory: String) throws {
        let linked = URL.cwd.appending(path: "linked/inner", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: URL.cwd.appending(path: "link"), withDestinationURL: linked)
        try "Named.swift\n".write(to: URL.cwd.appending(path: "arguments.rsp"), atomically: true, encoding: .utf8)
        try "Linked.swift\n"
            .write(to: URL.cwd.appending(path: "linked/arguments.rsp"), atomically: true, encoding: .utf8)
        let log = "swiftc -module-name Sample @\(URL.cwd.filepath)/\(directory)/../arguments.rsp"

        let invocations = CompilerArgumentsExtractor.allCompilerInvocations(compilerLogs: log)

        #expect(invocations.first?.filter { $0.hasSuffix(".swift") } == ["Named.swift"])
    }

    @Test(.temporaryDirectory)
    func lineWithItsModuleNameInAResponseFileIsAnInvocation() throws {
        let responseFile = URL.cwd.appending(path: "arguments.rsp", directoryHint: .notDirectory)
        try "-module-name\nSample\nA.swift\n".write(to: responseFile, atomically: true, encoding: .utf8)
        let log = """
            swiftc @\(responseFile.filepath)
            swiftc --version
            """

        let invocations = CompilerArgumentsExtractor.allCompilerInvocations(compilerLogs: log)

        #expect(invocations == [["-module-name", "Sample", "A.swift", "-D", "DEBUG"]])
    }

    @Test(.temporaryDirectory, arguments: ["-module-name=Sample\nA.swift\n", "-module-name\nSample\nA.swift\n"])
    func moduleNameOfAResponseFileGetsAnArgumentOfItsOwn(contents: String) throws {
        let responseFile = URL.cwd.appending(path: "arguments.rsp", directoryHint: .notDirectory)
        try contents.write(to: responseFile, atomically: true, encoding: .utf8)
        let log = "swiftc @\(responseFile.filepath)"

        let invocations = CompilerArgumentsExtractor.allCompilerInvocations(compilerLogs: log)

        #expect(invocations == [["-module-name", "Sample", "A.swift", "-D", "DEBUG"]])
    }

    @Test(arguments: ["swiftc -module-name=Sample A.swift", #"swiftc -module-name\=Sample A.swift"#])
    func moduleNameInTheArgumentOfItsOptionGetsAnArgumentOfItsOwn(log: String) {
        let invocations = CompilerArgumentsExtractor.allCompilerInvocations(compilerLogs: log)

        #expect(invocations == [["-module-name", "Sample", "A.swift", "-D", "DEBUG"]])
    }

    // The option counts in the text of a line only where it starts an argument outside of quotes.
    @Test(.temporaryDirectory, arguments: [
        #"swiftc -I "-module-name" A.swift"#,
        #"swiftc -I "-module-name=Sample" A.swift"#,
        "swiftc -Xfrontend=-module-name=Sample A.swift",
        "swiftc @missing.rsp A.swift",
    ])
    func lineThatNamesNoModuleInItsTextOrInAResponseFileIsNoInvocation(log: String) {
        #expect(CompilerArgumentsExtractor.allCompilerInvocations(compilerLogs: log).isEmpty)
    }

    // In a shell, `\=` is `=` and `\ ` is a space outside of quotes, and each is both characters inside of them.
    @Test
    func argumentOfABuildLogKeepsItsBackslashInsideQuotesOnly() {
        let log = #"swiftc -module-name Sample "A\=B.swift" C\=D.swift "E\ F.swift" G\ H.swift"#

        let invocations = CompilerArgumentsExtractor.allCompilerInvocations(compilerLogs: log)

        #expect(invocations.first?.filter { $0.hasSuffix(".swift") }
            == [#"A\=B.swift"#, "C=D.swift", #"E\ F.swift"#, "G H.swift"])
    }

    // In a shell, `\=` is `=` outside of quotes, and it is both characters inside of them.
    @Test(.temporaryDirectory, arguments: [
        (#"@%@/escaped\=arguments.rsp"#, "Unquoted.swift"),
        (#""@%@/escaped\=arguments.rsp""#, "Quoted.swift"),
    ])
    func pathOfAResponseFileKeepsItsBackslashInsideQuotesOnly(argument: String, file: String) throws {
        try "Unquoted.swift\n"
            .write(to: URL.cwd.appending(path: "escaped=arguments.rsp"), atomically: true, encoding: .utf8)
        try "Quoted.swift\n"
            .write(to: URL.cwd.appending(path: #"escaped\=arguments.rsp"#), atomically: true, encoding: .utf8)
        let log = "swiftc -module-name Sample " + argument.replacingOccurrences(of: "%@", with: URL.cwd.filepath)

        let invocations = CompilerArgumentsExtractor.allCompilerInvocations(compilerLogs: log)

        #expect(invocations.first?.filter { $0.hasSuffix(".swift") } == [file])
    }

    // The compiler keeps a byte order mark as part of the first argument, and it replaces bytes that are not
    // UTF-8.
    @Test(.temporaryDirectory, arguments: [
        (Data([0xEF, 0xBB, 0xBF, 0x61, 0x2E, 0x73, 0x77, 0x69, 0x66, 0x74]), "\u{FEFF}a.swift"),
        (Data([0x61, 0xFF, 0x2E, 0x73, 0x77, 0x69, 0x66, 0x74]), "a\u{FFFD}.swift"),
    ])
    func responseFileIsReadByteByByte(bytes: Data, argument: String) throws {
        let responseFile = URL.cwd.appending(path: "arguments.rsp", directoryHint: .notDirectory)
        try bytes.write(to: responseFile)
        let log = "swiftc -module-name Sample @\(responseFile.filepath)"

        let invocations = CompilerArgumentsExtractor.allCompilerInvocations(compilerLogs: log)

        #expect(invocations.first?.filter { $0.hasSuffix(".swift") } == [argument])
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
