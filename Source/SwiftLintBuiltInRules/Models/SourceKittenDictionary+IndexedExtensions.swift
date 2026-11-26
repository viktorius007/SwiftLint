import Foundation
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

/// Where the lines and columns that the index gives are in a file.
///
/// The index ends a line at a line feed, also at one that follows a carriage return, like the converter.
/// `stringView` ends a line at each of the two. SourceKit reads the file from disk. Where reading it for `contents`
/// removed a byte order mark, SourceKit still counts the bytes of the mark, in the columns of the first line and
/// in every offset. Where `contents` has the mark, the converter counts them too.
struct IndexedPositions {
    private let converter: SourceLocationConverter
    private let byteOrderMarkLength: Int

    init(of file: SwiftLintFile) {
        converter = file.locationConverter
        byteOrderMarkLength = file.lengthOfByteOrderMarkMissingFromContents()
    }

    /// The offset in `contents` of a line and column, if they are in the file.
    func offset(ofLine line: Int64, column: Int64) -> ByteCount? {
        let column = Int(column) - (line == 1 ? byteOrderMarkLength : 0)
        guard converter.isValid(line: Int(line), column: column) else {
            return nil
        }
        return ByteCount(converter.position(ofLine: Int(line), column: column).utf8Offset)
    }

    /// The offset that SourceKit has for an offset in `contents`.
    func offsetForSourceKit(of offset: ByteCount) -> ByteCount {
        offset + ByteCount(byteOrderMarkLength)
    }
}

extension SwiftLintFile {
    /// The number of bytes of a byte order mark that the file on disk starts with and `contents` lacks: the file
    /// is longer than `contents` by them.
    fileprivate func lengthOfByteOrderMarkMissingFromContents() -> Int {
        let lengthOfMark = 3
        guard let path, let length = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return 0
        }
        return length - contents.utf8.count == lengthOfMark ? lengthOfMark : 0
    }

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
        let positions = IndexedPositions(of: self)
        var offsetsOfIndexedExtensions = Set<Int>()
        var referencesByOffset = [Int: [SourceKittenDictionary]]()
        for entity in topLevelEntities {
            guard let line = entity.line, let column = entity.column,
                  let offset = positions.offset(ofLine: line, column: column)?.value else {
                continue
            }
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
        let positions = IndexedPositions(of: self)
        return { [self] reference in
            guard let line = reference.line, let column = reference.column,
                  let offset = positions.offset(ofLine: line, column: column)?.value else {
                return false
            }
            let offsets = offsetsOfConstraints
                ?? SelfConstraintCollector(viewMode: .sourceAccurate).walk(tree: syntaxTree, handler: \.offsets)
            offsetsOfConstraints = offsets
            return offsets.contains(offset)
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

extension SwiftLintFile {
    /// Returns a function that tells whether the file declares the property of an entity of its index with `let`
    /// and an initial value. The file is walked when the function is called for the first time.
    func initializedConstantFinder() -> (SourceKittenDictionary) -> Bool {
        var offsetsOfConstants: Set<Int>?
        let positions = IndexedPositions(of: self)
        return { [self] property in
            guard let line = property.line, let column = property.column,
                  let offset = positions.offset(ofLine: line, column: column)?.value else {
                return false
            }
            let offsets = offsetsOfConstants
                ?? InitializedConstantCollector(viewMode: .sourceAccurate).walk(tree: syntaxTree, handler: \.offsets)
            offsetsOfConstants = offsets
            return offsets.contains(offset)
        }
    }
}

private final class InitializedConstantCollector: SyntaxVisitor {
    private(set) var offsets = Set<Int>()

    override func visitPost(_ node: VariableDeclSyntax) {
        guard node.bindingSpecifier.tokenKind == .keyword(.let) else {
            return
        }
        for binding in node.bindings where binding.initializer != nil {
            // A pattern can name several properties: `let (first, second) = (1, 2)`.
            for token in binding.pattern.tokens(viewMode: .sourceAccurate) {
                if case .identifier = token.tokenKind {
                    offsets.insert(token.positionAfterSkippingLeadingTrivia.utf8Offset)
                }
            }
        }
    }
}
