import SourceKittenFramework

// The index of a file tells what a type inherits from, and not what these inherited types inherit from
// themselves. For a protocol or a type alias that a linted file declares, that file's index tells. For any
// other, SourceKit is asked once all files are collected: it prints the declaration with the kind and the USR
// of each type in it.

extension UnusedDeclarationUsage {
    /// What a protocol inherits from, or what a type alias stands for, each by its USR.
    struct InheritedTypes: Equatable {
        var all = Set<String>()
        /// The protocols and type aliases among them. SourceKit is asked about these in turn.
        var protocolsAndTypeAliases = Set<String>()
    }

    /// What tells about declarations that no linted file declares.
    struct InheritanceSource {
        /// Returns what the protocol or type alias with the given USR inherits from or stands for, as the given
        /// file with its compiler arguments sees it.
        var inheritedTypes: (_ usr: String, _ file: SwiftLintFile, _ compilerArguments: [String]) -> InheritedTypes
        /// Called after the last question that is asked through the given file.
        var release: (_ file: SwiftLintFile, _ compilerArguments: [String]) -> Void

        static var sourceKit: Self {
            Self(
                inheritedTypes: { $1.typesInherited(byDeclarationWithUSR: $0, compilerArguments: $2) },
                release: { file, compilerArguments in
                    if let path = file.path?.filepath {
                        Request.releaseCachedSyntaxTree(file: path, arguments: compilerArguments)
                    }
                }
            )
        }
    }

    /// Finds what the protocols and type aliases inherit from that the files' types inherit from and that no
    /// file declares, and so on for what these inherit from.
    ///
    /// Files that are compiled with the same arguments see the same declarations, so one of them asks for all
    /// of them, and it asks once about each declaration. To answer, SourceKit type-checks the file that asks
    /// and keeps the result, which holds the whole module. So it is told to drop it after the last question.
    ///
    /// - parameter collectedInfo: What each file tells.
    /// - parameter declaredTypes: The types, protocols and type aliases that the files declare.
    /// - parameter sourceKit:     Asks SourceKit.
    ///
    /// - returns: For each protocol or type alias that inherits from something: the USRs of that.
    static func inheritanceOfTypesDeclaredElsewhere(
        _ collectedInfo: [SwiftLintFile: UnusedDeclarationRule.FileUSRs],
        _ declaredTypes: Set<String>,
        sourceKit: InheritanceSource
    ) -> [String: Set<String>] {
        let typesNotToAsk = declaredTypes.union(knownTypes)
        var askers = [[String]: (file: SwiftLintFile, types: Set<String>)]()
        // In the order of their paths, so that the file that asks is the same in every run.
        for file in collectedInfo.keys.sorted(by: { ($0.path?.filepath ?? "") < ($1.path?.filepath ?? "") }) {
            if let info = collectedInfo[file], file.path != nil {
                askers[info.compilerArguments, default: (file, [])].types
                    .formUnion(info.typeFacts.inheritedProtocolsAndTypeAliases)
            }
        }
        var inherited = [String: Set<String>]()
        for (compilerArguments, asker) in askers {
            var typesToAsk = asker.types
            var seenTypes = Set<String>()
            var hasAsked = false
            while let type = typesToAsk.popFirst() {
                guard seenTypes.insert(type).inserted, !typesNotToAsk.contains(type),
                      isDeclarationOfSwift(usr: type) else {
                    continue
                }
                hasAsked = true
                let ancestors = sourceKit.inheritedTypes(type, asker.file, compilerArguments)
                if ancestors.all.isNotEmpty {
                    inherited[type, default: []].formUnion(ancestors.all)
                    typesToAsk.formUnion(ancestors.protocolsAndTypeAliases)
                }
            }
            if hasAsked {
                sourceKit.release(asker.file, compilerArguments)
            }
        }
        return inherited
    }

    /// Whether the USR names a declaration of Swift. A declaration of C or Objective-C cannot inherit from a
    /// protocol of Swift.
    static func isDeclarationOfSwift(usr: String) -> Bool {
        usr.hasPrefix("s:")
    }

    /// Reads what a protocol inherits from, or what a type alias stands for, from SourceKit's cursor info about
    /// it. SourceKit annotates the declaration: each type is in a tag with the type's kind and USR, and a
    /// requirement on `Self` is listed among the inherited types.
    ///
    /// - returns: These types. None for any other kind of declaration: a class passes its coding on to a
    ///            subclass as it is, without the stored properties of the subclass.
    static func inheritedTypes(inCursorInfo cursorInfo: [String: any SourceKitRepresentable]) -> InheritedTypes {
        let separators = ["source.lang.swift.decl.protocol": " : ", "source.lang.swift.decl.typealias": " = "]
        guard let kind = cursorInfo["key.kind"] as? String, let separator = separators[kind],
              let declaration = cursorInfo["key.fully_annotated_decl"] as? String else {
            return InheritedTypes()
        }
        // A requirement after `where` is one on an associated type or a generic parameter.
        let header = declaration[..<(declaration.firstRange(of: whereKeyword)?.lowerBound ?? declaration.endIndex)]
        // What comes before the separator is attributes, the keyword, the type that the declaration is nested in,
        // and the name with the primary associated types or the generic parameters.
        guard let start = header.firstRange(of: separator)?.upperBound else {
            return InheritedTypes()
        }
        var types = InheritedTypes()
        for reference in header[start...].matches(of: #/<ref\.([^ >]+) usr="([^"]*)"/#) {
            let usr = String(reference.output.2)
            types.all.insert(usr)
            if reference.output.1 == "protocol" || reference.output.1 == "typealias" {
                types.protocolsAndTypeAliases.insert(usr)
            }
        }
        return types
    }

    /// The keyword `where` as SourceKit annotates it.
    private static let whereKeyword = " <syntaxtype.keyword>where</syntaxtype.keyword> "
}

extension SwiftLintFile {
    /// Asks SourceKit what the protocol or type alias with the given USR inherits from or stands for.
    func typesInherited(byDeclarationWithUSR usr: String, compilerArguments: [String])
        -> UnusedDeclarationUsage.InheritedTypes {
        cursorInfo(ofDeclarationWithUSR: usr, compilerArguments: compilerArguments)
            .map(UnusedDeclarationUsage.inheritedTypes(inCursorInfo:)) ?? UnusedDeclarationUsage.InheritedTypes()
    }

    /// Asks SourceKit for the name of the module that declares the type with the given USR.
    func moduleName(ofTypeWithUSR usr: String, compilerArguments: [String]) -> String? {
        cursorInfo(ofDeclarationWithUSR: usr, compilerArguments: compilerArguments)?["key.modulename"] as? String
    }

    private func cursorInfo(ofDeclarationWithUSR usr: String, compilerArguments: [String])
        -> [String: any SourceKitRepresentable]? {
        guard let path else {
            return nil
        }
        let request = Request.cursorInfoWithoutSymbolGraph(file: path.filepath, usr: usr, arguments: compilerArguments)
        return try? request.sendIfNotDisabled()
    }
}
