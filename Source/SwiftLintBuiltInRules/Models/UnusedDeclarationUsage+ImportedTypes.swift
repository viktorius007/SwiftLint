import SourceKittenFramework

// The index of a file tells what a type inherits from, and not what these inherited types inherit from
// themselves. For a protocol or a type alias that another linted file declares, that file's index tells. For one
// of another module, SourceKit is asked: it prints the declaration with the USR of each type in it.

extension UnusedDeclarationUsage.TypeFacts {
    /// Adds what the protocols and type aliases inherit from that the file's types inherit from and that the file
    /// does not declare, and so on for what these inherit from.
    ///
    /// - parameter inheritedTypes: Returns the USRs of what the protocol or type alias with the given USR
    ///                             inherits from or stands for.
    mutating func noteInheritanceOfTypesDeclaredElsewhere(inheritedTypes: (String) -> Set<String>) {
        var typesToAsk = Set(inherited.values.joined()).union(conformancesMissingFromIndex.values.joined())
        var askedTypes = Set<String>()
        while let type = typesToAsk.popFirst() {
            guard askedTypes.insert(type).inserted, !declaredTypes.contains(type),
                  UnusedDeclarationUsage.isSwiftDeclarationOutsideTheStandardLibrary(usr: type) else {
                continue
            }
            let ancestors = inheritedTypes(type)
            if ancestors.isNotEmpty {
                inherited[type, default: []].formUnion(ancestors)
                typesToAsk.formUnion(ancestors)
            }
        }
    }
}

extension UnusedDeclarationUsage {
    /// Whether the USR names a declaration of Swift in another module than the standard library. Such a USR
    /// starts with the length of the module's name. The standard library has no protocol that inherits from
    /// `Decodable` or `Encodable`, and its type alias `Codable` is known here. A declaration of Objective-C
    /// cannot inherit from a protocol of Swift.
    static func isSwiftDeclarationOutsideTheStandardLibrary(usr: String) -> Bool {
        usr.hasPrefix("s:") && usr.dropFirst(2).first?.isNumber == true
    }

    /// Reads what a protocol inherits from, or what a type alias stands for, from SourceKit's cursor info about
    /// it. SourceKit annotates the declaration: each type is in a tag with the type's USR, and a requirement on
    /// `Self` is listed among the inherited types.
    ///
    /// - returns: The USRs of these types. None for any other kind of declaration: a class passes its coding on
    ///            to a subclass as it is, without the stored properties of the subclass.
    static func inheritedTypes(inCursorInfo cursorInfo: [String: any SourceKitRepresentable]) -> Set<String> {
        guard let kind = cursorInfo["key.kind"] as? String,
              kind == "source.lang.swift.decl.protocol" || kind == "source.lang.swift.decl.typealias",
              let declaration = cursorInfo["key.annotated_decl"] as? String else {
            return []
        }
        // A requirement after `where` is one on an associated type or a generic parameter.
        let header = declaration[..<(declaration.firstRange(of: " where ")?.lowerBound ?? declaration.endIndex)]
        return Set(header.matches(of: #/ usr="([^"]*)"/#).map { String($0.output.1) })
    }
}

extension SwiftLintFile {
    /// Asks SourceKit what the protocol or type alias with the given USR inherits from or stands for.
    ///
    /// - returns: The USRs of these types.
    func typesInherited(byDeclarationWithUSR usr: String, compilerArguments: [String]) -> Set<String> {
        guard let path else {
            return []
        }
        let request = Request.cursorInfoWithoutSymbolGraph(file: path.filepath, usr: usr, arguments: compilerArguments)
        return (try? request.sendIfNotDisabled()).map(UnusedDeclarationUsage.inheritedTypes(inCursorInfo:)) ?? []
    }
}
