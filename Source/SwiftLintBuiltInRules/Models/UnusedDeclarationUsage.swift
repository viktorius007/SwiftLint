import SourceKittenFramework

// The index holds no reference for some uses of a declaration. This file finds the ones that follow from facts
// about the declaration's type:
//
// * `main()` is called by the language if a type marked `@main` finds it by member lookup.
// * `wrappedValue` and `projectedValue` are read by every property that a property wrapper is applied to.

/// Everything that all files together use.
struct UnusedDeclarationUsage {
    /// A member of a type, as far as its name tells.
    struct Member: Hashable {
        /// USR of the type that declares the member, or that the member's extension extends.
        let type: String
        let name: Name
    }

    struct Name: Hashable {
        /// Base name with argument labels, as the index spells it: `copy(to:)`, `count`.
        let name: String
        let isStatic: Bool
    }

    /// What one file tells about types, each named by USR.
    struct TypeFacts: Hashable {
        /// Types marked `@main`.
        var entryPoints = Set<String>()
        /// Types marked `@propertyWrapper`.
        var propertyWrappers = Set<String>()
        /// For each type, protocol or type alias: what it inherits from, conforms to or stands for.
        var inherited = [String: Set<String>]()
    }

    private let referenced: Set<String>
    private let usedMembers: Set<Member>

    init(of collectedInfo: [SwiftLintFile: UnusedDeclarationRule.FileUSRs]) {
        referenced = collectedInfo.values.reduce(into: Set()) { $0.formUnion($1.referenced) }
        let facts = collectedInfo.values.map(\.typeFacts)
        let inherited = facts.reduce(into: [String: Set<String>]()) { all, facts in
            all.merge(facts.inherited) { $0.union($1) }
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
        for type in withInherited(facts.flatMap(\.entryPoints)) {
            usedMembers.insert(Member(type: type, name: Name(name: "main()", isStatic: true)))
        }
        for type in facts.flatMap(\.propertyWrappers) {
            usedMembers.insert(Member(type: type, name: Name(name: "wrappedValue", isStatic: false)))
            usedMembers.insert(Member(type: type, name: Name(name: "projectedValue", isStatic: false)))
        }
        self.usedMembers = usedMembers
    }

    func contains(_ declaration: UnusedDeclarationRule.DeclaredUSR) -> Bool {
        referenced.contains(declaration.usr) || declaration.member.map(usedMembers.contains) == true
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
            guard let name = entity.memberName, let type = declaredOrExtendedType(of: parent) else {
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
            // An extension's own USR names its first member. The extended type is the reference at its position.
            let type = entity.entities.first { $0.isReference && $0.line == line && $0.column == column }?.usr
            types[position] = type
            return type
        }
    }
}

private extension SourceKittenDictionary {
    /// The name by which a type would find this declaration as its member.
    var memberName: UnusedDeclarationUsage.Name? {
        guard let kind = declarationKind, let name else {
            return nil
        }
        switch kind {
        case .functionMethodClass, .functionMethodStatic, .varClass, .varStatic:
            return UnusedDeclarationUsage.Name(name: name, isStatic: true)
        default:
            return UnusedDeclarationUsage.Name(name: name, isStatic: false)
        }
    }

    var isReference: Bool {
        kind?.starts(with: "source.lang.swift.ref.") == true
    }

    var usr: String? {
        value["key.usr"] as? String
    }
}

private struct Position: Hashable {
    let line: Int64
    let column: Int64
}
