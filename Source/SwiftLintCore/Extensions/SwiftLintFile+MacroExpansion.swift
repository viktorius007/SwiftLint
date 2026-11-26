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
    /// Expanding the macros of Swift Testing and type-checking what they expand to takes several times as long as
    /// type-checking the test file as written, and the compiler has no option that turns a macro off. No macro of
    /// Swift Testing declares a name, so the written code cannot refer to anything in an expansion. An expansion
    /// refers to written code that is no argument of its macro in these ways: it names the suite; it calls the
    /// test by its name and labels; it writes the types of the parameters of the test as the test does, and
    /// `Void`; for a test in a type or in an extension, it names that type as the source around the test does,
    /// with the types it is nested in or as the header of the extension spells it, and calls its `init()` if the
    /// test is an instance method; and it calls members of the types of Swift Testing whose names start with
    /// `__`, of which an extension of such a type can declare one (see `UnusedDeclarationUsage`).
    /// With the returned arguments, the compiler reports an error at every use of such a macro and goes on, and
    /// SourceKit prints these errors for an index request.
    ///
    /// Whether the file imports `Testing` is read from its text, so an import under a compiler condition that is
    /// off counts too. A file without such an import that gets Swift Testing through another module that exports
    /// it keeps its arguments.
    ///
    /// - parameter compilerArguments: The compiler arguments needed to compile this file.
    ///
    /// - returns: The given arguments, preceded by `argumentsThatKeepTestingMacrosUnexpanded` if the text of this
    ///            file imports `Testing`.
    func compilerArgumentsWithoutTestingMacros(_ compilerArguments: [String]) -> [String] {
        guard compilerArguments.isNotEmpty, contents.contains("Testing"), syntaxTree.statements.importsTesting else {
            return compilerArguments
        }
        return Self.argumentsThatKeepTestingMacrosUnexpanded + compilerArguments
    }
}

private extension CodeBlockItemListSyntax {
    /// Whether one of these statements imports `Testing` or something from it, also under a compiler condition,
    /// whether that is on or off.
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
