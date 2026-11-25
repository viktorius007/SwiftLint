import SourceKittenFramework
import SwiftSyntax

// The index holds no reference for some uses of a declaration. This file finds the ones that follow from facts
// about the declaration's type:
//
// * `main()` is called by the language if a type marked `@main` finds it by member lookup. Which one it calls
//   if the type finds several is not known here, so each of them counts as used.
// * `wrappedValue` and `projectedValue` are read by the properties that a property wrapper is applied to.
// * A conformance uses the members that satisfy the protocol's requirements. The index lists these witnesses
//   under the conforming declaration (see `isWitnessDeclaredElsewhere`), with one exception: the compiler leaves
//   an extension without members out of the index if none of its inherited types is a single protocol or class,
//   as in `extension T: P & Q {}` or with a type alias of such a composition. For these extensions, a member
//   counts as a witness if a requirement of one of the protocols has its name, and if the type could find it:
//   in itself, in what it inherits from, or at file scope for an operator.
//
// All of this except the witnesses of the index is decided by name. A name tells nothing about types and
// constraints, so an unused member is kept if it shares its name and labels with a used one of the same type,
// also where a constraint of its extension rules it out. Whatever a type alias mentions counts as inherited
// by it, also the generic argument in `typealias A = B<C>`.

/// Everything that all files together use.
struct UnusedDeclarationUsage {
    /// A member of a type, as far as its name tells.
    struct Member: Hashable {
        /// USR of the type that declares the member, or that the member's extension extends. Empty for an
        /// operator at file scope.
        let type: String
        let name: Name
    }

    struct Name: Hashable {
        /// Base name with argument labels, as the index spells it: `copy(to:)`, `count`.
        let name: String
        let kind: NameKind
    }

    /// What can stand for each other under one name: a type alias satisfies an associated type, a static
    /// method never an instance method.
    enum NameKind {
        case instance
        case `static`
        case type
    }

    /// What one file tells about types, each named by USR.
    struct TypeFacts: Hashable {
        /// Types marked `@main`.
        var entryPoints = Set<String>()
        /// Types marked `@propertyWrapper`.
        var propertyWrappers = Set<String>()
        /// For each type, protocol or type alias: what it inherits from, conforms to or stands for.
        var inherited = [String: Set<String>]()
        /// For each protocol: its requirements.
        var requirements = [String: Set<Name>]()
        /// For each type: the inherited types of its extensions that the index leaves out.
        var conformancesMissingFromIndex = [String: Set<String>]()
    }

    private let referenced: Set<String>
    private let usedMembers: Set<Member>
    /// For each type that can hold a witness of a conformance missing from the index: the requirements of
    /// each such conformance.
    private let witnessNames: [String: [Set<Name>]]

    init(of collectedInfo: [SwiftLintFile: UnusedDeclarationRule.FileUSRs]) {
        referenced = collectedInfo.values.reduce(into: Set()) { $0.formUnion($1.referenced) }
        let facts = collectedInfo.values.map(\.typeFacts)
        let missingConformances = facts.reduce(into: [String: Set<String>]()) { all, facts in
            all.merge(facts.conformancesMissingFromIndex) { $0.union($1) }
        }
        let inherited = facts.reduce(into: missingConformances) { all, facts in
            all.merge(facts.inherited) { $0.union($1) }
        }
        let requirements = facts.reduce(into: [String: Set<Name>]()) { all, facts in
            all.merge(facts.requirements) { $0.union($1) }
        }
        /// The given types with everything they inherit from, directly or not.
        func withInherited(_ types: some Sequence<String>) -> Set<String> {
            var result = Set<String>()
            var typesToVisit = Array(types)
            while let type = typesToVisit.popLast() {
                if result.insert(type).inserted {
                    typesToVisit.append(contentsOf: inherited[type] ?? [])
                }
            }
            return result
        }

        var usedMembers = Set<Member>()
        for owner in withInherited(facts.flatMap(\.entryPoints)) {
            usedMembers.insert(Member(type: owner, name: Name(name: "main()", kind: .static)))
        }
        for type in facts.flatMap(\.propertyWrappers) {
            usedMembers.insert(Member(type: type, name: Name(name: "wrappedValue", kind: .instance)))
            usedMembers.insert(Member(type: type, name: Name(name: "projectedValue", kind: .instance)))
        }
        self.usedMembers = usedMembers

        var witnessNames = [String: [Set<Name>]]()
        for (type, protocols) in missingConformances {
            let names = Set(withInherited(protocols).flatMap { requirements[$0] ?? [] })
            guard names.isNotEmpty else {
                continue
            }
            // A witness can come from the type, a superclass, an extension of a protocol or the file scope.
            for owner in withInherited([type]).union([Member.fileScope]) {
                witnessNames[owner, default: []].append(names)
            }
        }
        self.witnessNames = witnessNames
    }

    func contains(_ declaration: UnusedDeclarationRule.DeclaredUSR) -> Bool {
        if referenced.contains(declaration.usr) {
            return true
        }
        guard let member = declaration.member else {
            return false
        }
        return usedMembers.contains(member)
            || witnessNames[member.type]?.contains { $0.contains(member.name) } == true
    }
}

extension UnusedDeclarationUsage {
    /// Gathers the type facts of one file from the entities of its index, visited in any order.
    struct TypeFactsCollector {
        private(set) var facts = TypeFacts()
        /// The type that the entity at a line and column declares or extends. Looking it up for an extension
        /// reads all its entities, so it is done once and not for every member.
        private var types = [Position: String?]()

        /// Notes what the entity tells about types.
        ///
        /// - returns: The entity as a member of the type that its parent declares or extends, if it is one.
        mutating func visit(_ entity: SourceKittenDictionary, in parent: SourceKittenDictionary) -> Member? {
            guard entity.declarationKind != nil else {
                if parent.declarationKind == .typealias, entity.isReference, let alias = parent.usr,
                   let usr = entity.usr {
                    facts.inherited[alias, default: []].insert(usr)
                }
                return nil
            }
            if let type = declaredOrExtendedType(of: entity) {
                noteType(type, declaredOrExtendedBy: entity)
            }
            guard let name = entity.memberName else {
                return nil
            }
            guard let type = declaredOrExtendedType(of: parent) else {
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
            let related = (entity.value["key.related"] as? [[String: any SourceKitRepresentable]])?
                .compactMap { $0["key.usr"] as? String } ?? []
            if related.isNotEmpty {
                facts.inherited[type, default: []].formUnion(related)
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

    var usr: String? {
        value["key.usr"] as? String
    }
}

private extension UnusedDeclarationUsage.Member {
    static let fileScope = ""
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
