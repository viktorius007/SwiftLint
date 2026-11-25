import SourceKittenFramework
import SwiftSyntax

extension UnusedDeclarationUsage {
    /// Gathers the type facts of one file from the entities of its index, visited in any order.
    struct TypeFactsCollector {
        private(set) var facts = TypeFacts()
        /// The type that the entity at a line and column declares or extends. Looking it up for an extension
        /// reads all its entities, so it is done once and not for every member.
        private var types = [Position: String?]()
        /// Asks SourceKit for the USRs of what a declaration overrides or satisfies.
        private let overridden: (SourceKittenDictionary) -> [String]

        init(overridden: @escaping (SourceKittenDictionary) -> [String]) {
            self.overridden = overridden
        }

        /// Notes what the entity tells about types.
        ///
        /// - returns: The entity as a member of the type that its parent declares or extends, if it is one.
        mutating func visit(_ entity: SourceKittenDictionary, in parent: SourceKittenDictionary) -> Member? {
            guard entity.declarationKind != nil else {
                if parent.declarationKind == .typealias, entity.isReference, let alias = parent.usr,
                   let usr = entity.usr {
                    facts.inherited[alias, default: []].insert(usr)
                }
                noteSwiftTesting(attribute: entity, in: parent)
                return nil
            }
            if let type = declaredOrExtendedType(of: entity) {
                noteType(type, declaredOrExtendedBy: entity)
            }
            if entity.declaresType, let usr = entity.usr {
                facts.declaredTypes.insert(usr)
            }
            let owner = declaredOrExtendedType(of: parent)
            if let owner, parent.declarationKind != .protocol {
                noteCoding(of: owner, by: entity)
            }
            guard let name = entity.memberName else {
                return nil
            }
            guard let type = owner else {
                return entity.isOperator ? Member(type: Member.fileScope, name: name) : nil
            }
            if parent.declarationKind == .protocol {
                // What a protocol declares in its body is a requirement and no witness. Its type aliases are
                // neither.
                if entity.declarationKind != .typealias {
                    facts.requirements[type, default: []].insert(name)
                }
                return nil
            }
            return Member(type: type, name: name)
        }

        private mutating func noteType(_ type: String, declaredOrExtendedBy entity: SourceKittenDictionary) {
            let attributes = entity.enclosedSwiftAttributes
            if attributes.contains(.main) {
                facts.entryPoints.insert(type)
            }
            if attributes.contains(.propertyWrapper) {
                facts.propertyWrappers.insert(type)
            }
            let related = entity.relatedUSRs
            if related.isNotEmpty {
                facts.inherited[type, default: []].formUnion(related)
            }
        }

        private mutating func noteCoding(of type: String, by member: SourceKittenDictionary) {
            let requirements = [UnusedDeclarationUsage.decodingRequirement, UnusedDeclarationUsage.encodingRequirement]
            var satisfied = member.relatedUSRs.filter(requirements.contains)
            // Where the index leaves the conformance out, it relates no declaration to a requirement.
            if satisfied.isEmpty, member.name == "init(from:)" || member.name == "encode(to:)" {
                satisfied = overridden(member)
            }
            if satisfied.contains(UnusedDeclarationUsage.decodingRequirement) {
                facts.typesWithOwnDecoding.insert(type)
            }
            if satisfied.contains(UnusedDeclarationUsage.encodingRequirement) {
                facts.typesWithOwnEncoding.insert(type)
            }
            // The compiler generates the getter of a stored property. Generated coding leaves out a lazy one.
            if member.declarationKind == .varInstance, let usr = member.usr,
               member.entities.contains(where: { $0.declarationKind == .functionAccessorGetter && $0.isImplicit }),
               !member.enclosedSwiftAttributes.contains(.lazy) {
                facts.storedProperties[type, default: []].insert(usr)
            }
        }

        /// Notes what Swift Testing runs, if the entity is the reference of an attribute to `@Test` or `@Suite`.
        private mutating func noteSwiftTesting(attribute: SourceKittenDictionary, in parent: SourceKittenDictionary) {
            guard attribute.kind == "source.lang.swift.ref.macro", let macro = attribute.usr,
                  case let marksTest = macro.hasPrefix(UnusedDeclarationUsage.testMacroPrefix),
                  marksTest || macro.hasPrefix(UnusedDeclarationUsage.suiteMacroPrefix),
                  let marked = parent.declaration(following: attribute) else {
                return
            }
            if let usr = marked.usr {
                facts.runBySwiftTesting.insert(usr)
            }
            if marksTest, let owner = declaredOrExtendedType(of: parent) {
                facts.runBySwiftTesting.insert(owner)
            }
        }

        /// USR of the type that the entity declares or extends.
        private mutating func declaredOrExtendedType(of entity: SourceKittenDictionary) -> String? {
            switch entity.declarationKind {
            case .actor, .class, .enum, .protocol, .struct:
                return entity.usr
            case .extension, .extensionClass, .extensionEnum, .extensionProtocol, .extensionStruct:
                break
            default:
                return nil
            }
            guard let line = entity.line, let column = entity.column else {
                return nil
            }
            let position = Position(line: line, column: column)
            if let type = types[position] {
                return type
            }
            // An extension's own USR names its first member. The extended type is the reference at its position;
            // for an extension of a type alias, the alias comes first and what it stands for second.
            let references = entity.entities.filter { $0.isReference && $0.line == line && $0.column == column }
            let type = (references.first { !$0.isTypeAliasReference } ?? references.first)?.usr
            types[position] = type
            return type
        }
    }
}

extension SwiftLintFile {
    /// Finds the extensions with inherited types that the file has and its index lacks.
    ///
    /// - returns: For each extended type, the inherited types of these extensions.
    func conformancesMissingFromIndex(_ index: SourceKittenDictionary) -> [String: Set<String>] {
        // Without the extension, the index has the references to its types at the top level. Apart from the
        // modules of its imports, few files have references there, and only those are parsed.
        let topLevelEntities = index.entities
        guard topLevelEntities.contains(where: { $0.isReference && $0.kind != "source.lang.swift.ref.module" }) else {
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
            // The converter counts lines like the compiler does, also for files with carriage returns.
            let offset = converter.position(ofLine: Int(line), column: Int(column)).utf8Offset
            if entity.kind?.starts(with: "source.lang.swift.decl.extension") == true {
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

private extension SourceKittenDictionary {
    /// The name by which a type would find this declaration as its member.
    var memberName: UnusedDeclarationUsage.Name? {
        guard let kind = declarationKind, let name else {
            return nil
        }
        switch kind {
        case .functionMethodInstance, .varInstance:
            return UnusedDeclarationUsage.Name(name: name, kind: .instance)
        case .functionMethodClass, .functionMethodStatic, .varClass, .varStatic,
             .functionOperator, .functionOperatorInfix, .functionOperatorPostfix, .functionOperatorPrefix:
            return UnusedDeclarationUsage.Name(name: name, kind: .static)
        case .actor, .associatedtype, .class, .enum, .struct, .typealias:
            return UnusedDeclarationUsage.Name(name: name, kind: .type)
        default:
            return nil
        }
    }

    /// The first declaration among this entity's entities that comes after the given one of them.
    func declaration(following entity: SourceKittenDictionary) -> SourceKittenDictionary? {
        entities.drop { $0.line != entity.line || $0.column != entity.column || $0.kind != entity.kind }
            .dropFirst()
            .first { $0.kind?.starts(with: "source.lang.swift.decl.") == true }
    }

    var declaresType: Bool {
        switch declarationKind {
        case .actor, .associatedtype, .class, .enum, .genericTypeParam, .protocol, .struct, .typealias: true
        default: false
        }
    }

    var isOperator: Bool {
        switch declarationKind {
        case .functionOperator, .functionOperatorInfix, .functionOperatorPostfix, .functionOperatorPrefix: true
        default: false
        }
    }

    var isReference: Bool {
        kind?.starts(with: "source.lang.swift.ref.") == true
    }

    var isTypeAliasReference: Bool {
        kind == "source.lang.swift.ref.typealias"
    }

    var isImplicit: Bool {
        value["key.is_implicit"] as? Bool == true
    }

    var relatedUSRs: [String] {
        (value["key.related"] as? [[String: any SourceKitRepresentable]])?.compactMap { $0["key.usr"] as? String }
            ?? []
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

private struct Position: Hashable {
    let line: Int64
    let column: Int64
}

private final class ExtensionCollector: SyntaxVisitor {
    private(set) var extensions = [ExtensionDeclSyntax]()

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        extensions.append(node)
        return .skipChildren
    }
}
