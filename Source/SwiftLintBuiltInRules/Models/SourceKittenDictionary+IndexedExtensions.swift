import SourceKittenFramework
import SwiftSyntax

extension SourceKittenDictionary {
    var isExtension: Bool {
        kind?.starts(with: "source.lang.swift.decl.extension") == true
    }

    /// Whether this is an extension whose header names the type it extends with the given reference among its
    /// entities: the type, a type alias for it, or a type around it. The index lists these at the extension's
    /// position or before it. Every other reference among the entities is a use: a generic argument, a type
    /// after `where`, an argument of an attribute of a member.
    ///
    /// A header in parentheses, `extension (T)`, is not read: the index has such an extension at the opening
    /// parenthesis and everything that the header names after it. So that header uses what it names, and the
    /// type that it extends is not known.
    func isExtension(namedWith reference: SourceKittenDictionary) -> Bool {
        guard isExtension, reference.isReference,
              let line, let column, let referenceLine = reference.line, let referenceColumn = reference.column else {
            return false
        }
        return (referenceLine, referenceColumn) <= (line, column)
    }

    /// Whether this is an extension and the given reference among its entities stands for the type it extends,
    /// which is no use of that type: the reference at the extension's position that is of the extension's kind.
    /// The position alone does not tell: an extension that a macro expands to has all its references at the
    /// position of the macro's attribute, also the ones to what it inherits from.
    func extends(reference: SourceKittenDictionary) -> Bool {
        guard isExtension(namedWith: reference), reference.line == line, reference.column == column,
              let kind, let referenceKind = reference.kind else {
            return false
        }
        // `.struct` of `source.lang.swift.decl.extension.struct` and of `source.lang.swift.ref.struct`.
        return kind.dropFirst("source.lang.swift.decl.extension".count)
            == referenceKind.dropFirst("source.lang.swift.ref".count)
    }

    /// Whether this is an extension whose header is written without the name of the type it extends, and names
    /// the given reference among its entities. Such a header is written with a type alias, or as `T?`, `[T]` or
    /// `[K: V]`, and it uses everything that it names. For the extended type, the index then has a reference
    /// without a name.
    func isExtensionWrittenWithoutItsType(namedWith reference: SourceKittenDictionary) -> Bool {
        isExtension(namedWith: reference) && entities.contains { $0.name == nil && isExtension(namedWith: $0) }
    }
}

extension SwiftLintFile {
    /// Finds the extensions with inherited types that the file has and its index lacks.
    ///
    /// - returns: For each extended type, the inherited types of these extensions.
    func conformancesMissingFromIndex(_ index: SourceKittenDictionary) -> [String: Set<String>] {
        // Without the extension, the index has the references to its types at the top level. Apart from the
        // modules of its imports, few files have references there, and only those are walked.
        let topLevelEntities = index.entities
        guard topLevelEntities.contains(where: { $0.isReference && !$0.isModuleReference }) else {
            return [:]
        }
        let extensions = ExtensionCollector(viewMode: .sourceAccurate).walk(tree: syntaxTree, handler: \.extensions)
            .filter { $0.inheritanceClause != nil }
        let converter = locationConverter
        var offsetsOfIndexedExtensions = Set<Int>()
        var referencesByOffset = [Int: [SourceKittenDictionary]]()
        for entity in topLevelEntities {
            guard let line = entity.line, let column = entity.column else {
                continue
            }
            // The converter ends a line where the index does, also at a carriage return that a line feed follows.
            let offset = converter.position(ofLine: Int(line), column: Int(column)).utf8Offset
            if entity.isExtension {
                offsetsOfIndexedExtensions.insert(offset)
            } else if entity.isReference {
                referencesByOffset[offset, default: []].append(entity)
            }
        }
        var conformances = [String: Set<String>]()
        for node in extensions {
            // The index places an extension at the name of the extended type: at `B` for `A.B<C>`.
            guard let offset = node.extendedType.nameTokens.first?.positionAfterSkippingLeadingTrivia.utf8Offset,
                  !offsetsOfIndexedExtensions.contains(offset),
                  let extended = referencesByOffset[offset],
                  let type = (extended.first { !$0.isTypeAliasReference } ?? extended.first)?.usr,
                  let inheritance = node.inheritanceClause else {
                continue
            }
            // The names only: a generic argument of an inherited type is referenced, and not inherited.
            let inherited = inheritance.inheritedTypes.flatMap(\.type.nameTokens)
                .flatMap { referencesByOffset[$0.positionAfterSkippingLeadingTrivia.utf8Offset] ?? [] }
                .compactMap(\.usr)
            conformances[type, default: []].formUnion(inherited)
        }
        return conformances
    }
}

extension SwiftLintFile {
    /// Returns a function that tells whether a reference of the file's index is at a type that the `where` clause
    /// of a protocol constrains the protocol to: at `Q` and at `R` for `protocol P where Self: Q & R`. The file is
    /// walked when the function is called for the first time.
    func selfConstraintFinder() -> (SourceKittenDictionary) -> Bool {
        var offsetsOfConstraints: Set<Int>?
        let converter = locationConverter
        return { [self] reference in
            guard let line = reference.line, let column = reference.column else {
                return false
            }
            let offsets = offsetsOfConstraints
                ?? SelfConstraintCollector(viewMode: .sourceAccurate).walk(tree: syntaxTree, handler: \.offsets)
            offsetsOfConstraints = offsets
            // The converter ends a line where the index does, also at a carriage return that a line feed follows.
            return offsets.contains(converter.position(ofLine: Int(line), column: Int(column)).utf8Offset)
        }
    }
}

private extension SourceKittenDictionary {
    var isReference: Bool {
        kind?.starts(with: "source.lang.swift.ref.") == true
    }

    var isModuleReference: Bool {
        kind == "source.lang.swift.ref.module"
    }

    var isTypeAliasReference: Bool {
        kind == "source.lang.swift.ref.typealias"
    }

    var usr: String? {
        value["key.usr"] as? String
    }
}

private extension TypeSyntax {
    /// The tokens that name the types this type is made of, without their qualifiers and generic arguments:
    /// `B` for `A.B<C>`, `P` and `Q` for `P & Q`.
    var nameTokens: [TokenSyntax] {
        if let type = `as`(IdentifierTypeSyntax.self) {
            return [type.name]
        }
        if let type = `as`(MemberTypeSyntax.self) {
            return [type.name]
        }
        if let type = `as`(CompositionTypeSyntax.self) {
            return type.elements.flatMap(\.type.nameTokens)
        }
        if let type = `as`(AttributedTypeSyntax.self) {
            return type.baseType.nameTokens
        }
        if let type = `as`(SomeOrAnyTypeSyntax.self) {
            return type.constraint.nameTokens
        }
        if let type = `as`(TupleTypeSyntax.self), type.elements.count == 1, let element = type.elements.first {
            return element.type.nameTokens
        }
        return []
    }
}

/// Collects the offsets of the names of the types that protocols are constrained to in their `where` clauses.
private final class SelfConstraintCollector: SyntaxVisitor {
    private(set) var offsets = Set<Int>()

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        for requirement in node.genericWhereClause?.requirements ?? [] {
            if case let .conformanceRequirement(conformance) = requirement.requirement,
               let constrained = conformance.leftType.as(IdentifierTypeSyntax.self)?.name.text,
               constrained == "Self" || constrained == "`Self`" {
                let names = conformance.rightType.nameTokens
                offsets.formUnion(names.map(\.positionAfterSkippingLeadingTrivia.utf8Offset))
            }
        }
        return .skipChildren
    }
}

private final class ExtensionCollector: SyntaxVisitor {
    private(set) var extensions = [ExtensionDeclSyntax]()

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        extensions.append(node)
        return .skipChildren
    }
}
