import SwiftSyntax

public extension SwiftLintFile {
    /// What makes the compiler leave the macros of Swift Testing unexpanded: it names a plugin for their module
    /// that cannot be loaded. The compiler takes the first plugin named for a module, and it reads the options
    /// passed with `-Xfrontend` before all others.
    static let argumentsThatKeepTestingMacrosUnexpanded = [
        "-Xfrontend", "-load-plugin-executable",
        "-Xfrontend", "/dev/null/no-expansion#TestingMacros",
    ]

    /// Returns the compiler arguments that analyzer rules pass to SourceKit for this file.
    ///
    /// Expanding the macros of Swift Testing and type-checking what they expand to takes several times as long
    /// as type-checking the test file as written, and the compiler has no option that turns a macro off. No macro
    /// of Swift Testing declares a name, so the written code cannot refer to anything in an expansion. An
    /// expansion refers to written code that is no argument of its macro in these ways: it names the declaration
    /// that carries the attribute; for a test in a type, it names that type by all types it is nested in, and
    /// calls its `init()` if the test is an instance method; and it calls members of the types of Swift Testing
    /// whose names start with `__`, of which an extension of such a type can declare one (see
    /// `UnusedDeclarationUsage`). With the returned arguments, the compiler reports an error at every use of such
    /// a macro and goes on, and SourceKit prints these errors for an index request.
    ///
    /// A file that gets Swift Testing without importing it, through another module that exports it, keeps its
    /// arguments.
    ///
    /// - parameter compilerArguments: The compiler arguments needed to compile this file.
    ///
    /// - returns: The given arguments, preceded by `argumentsThatKeepTestingMacrosUnexpanded` if this file
    ///            imports `Testing`.
    func compilerArgumentsWithoutTestingMacros(_ compilerArguments: [String]) -> [String] {
        guard compilerArguments.isNotEmpty, contents.contains("Testing"), syntaxTree.statements.importsTesting else {
            return compilerArguments
        }
        return Self.argumentsThatKeepTestingMacrosUnexpanded + compilerArguments
    }
}

private extension CodeBlockItemListSyntax {
    /// Whether one of these statements imports `Testing` or something from it, also under a compiler condition.
    var importsTesting: Bool {
        contains { statement in
            if let importDeclaration = statement.item.as(ImportDeclSyntax.self) {
                // The name without the backticks that it can be written in.
                return importDeclaration.path.first?.name.identifier?.name == "Testing"
            }
            return statement.item.as(IfConfigDeclSyntax.self)?.clauses.contains { clause in
                clause.elements?.as(Self.self)?.importsTesting == true
            } == true
        }
    }
}
