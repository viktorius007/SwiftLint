// The index holds no reference for some uses of a declaration. This file finds the ones that follow from facts
// about the declaration's type:
//
// * `main()` is called by the language if a type marked `@main` finds it by member lookup. Which one it calls
//   if the type finds several is not known here, so each of them counts as used.
// * `wrappedValue` and `projectedValue` are read by the properties that a property wrapper is applied to.
// * The stored properties of a type are written by the `init(from:)` and read by the `encode(to:)` that the
//   compiler generates for `Decodable` and `Encodable`. The index does not list a generated one. It marks a
//   declared one, and one that a subclass inherits, as satisfying the protocol's requirement. Where it leaves
//   the conformance out (see below), a declared one is known by its name and the type of its parameter.
// * A conformance uses the members that satisfy the protocol's requirements. The index lists these witnesses
//   under the conforming declaration (see `isWitnessDeclaredElsewhere`), with one exception: the compiler leaves
//   an extension without members out of the index if none of its inherited types is a single protocol or class,
//   as in `extension T: P & Q {}` or with a type alias of such a composition. For these extensions, a member
//   counts as a witness if a requirement of one of the protocols has its name, and if the type could find it:
//   in itself, in what it inherits from, or at file scope for an operator. The requirements of a protocol that
//   no linted file declares are not known. Then everything the type inherits and every operator at file scope
//   counts as a witness. The type's own members do not: SourceKit tells for each of them whether it satisfies
//   a requirement.
//
// The entry points, the values of a property wrapper and the witnesses of an extension that the index leaves
// out are decided by name. A name tells nothing about types and constraints, so an unused member is kept if it
// shares its name and labels with a used one of the same type, also where a constraint of its extension rules
// it out. Whatever a type alias mentions counts as inherited by it, also the generic argument in
// `typealias A = B<C>`.

/// Everything that all files together use.
struct UnusedDeclarationUsage {
    /// A member of a type, as far as its name tells.
    struct Member: Hashable {
        /// USR of the type that declares the member, or that the member's extension extends. Empty for an
        /// operator at file scope.
        let type: String
        let name: Name

        /// Stands for the type of an operator at file scope.
        static let fileScope = ""
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
        /// For each type: the USRs of its stored instance properties that are not lazy.
        var storedProperties = [String: Set<String>]()
        /// Types with a declaration that satisfies `Decodable`'s `init(from:)`.
        var typesWithOwnDecoding = Set<String>()
        /// Types with a declaration that satisfies `Encodable`'s `encode(to:)`.
        var typesWithOwnEncoding = Set<String>()
        /// The types, protocols, type aliases and generic parameters that the file declares.
        var declaredTypes = Set<String>()
    }

    static let decodable = "s:Se"
    static let encodable = "s:SE"
    static let codable = "s:s7Codablea"
    static let decodingRequirement = "s:Se4fromxs7Decoder_p_tKcfc"
    static let encodingRequirement = "s:SE6encode2toys7Encoder_p_tKF"
    /// What ends the USR of every `init(from: any Decoder) throws`.
    static let decodingWitnessSuffix = "s7Decoder_p_tKcfc"
    /// What ends the USR of every `func encode(to: any Encoder) throws`.
    static let encodingWitnessSuffix = "6encode2toys7Encoder_p_tKF"
    /// Protocols of the standard library that cannot have requirements.
    private static let markerProtocols: Set = ["s:s8SendableP", "s:s16SendableMetatypeP", "s:s15BitwiseCopyableP"]

    private let referenced: Set<String>
    private let usedMembers: Set<Member>
    /// For each type that can hold a witness of a conformance missing from the index: the requirements of
    /// these conformances.
    private let witnessNames: [String: Set<Name>]
    /// The types that can hold a witness of a conformance missing from the index to a protocol with unknown
    /// requirements.
    private let ownersOfUnknownWitnesses: Set<String>

    init(of collectedInfo: [SwiftLintFile: UnusedDeclarationRule.FileUSRs]) {
        let facts = collectedInfo.values.map(\.typeFacts)
        let missingConformances = facts.reduce(into: [String: Set<String>]()) { all, facts in
            all.merge(facts.conformancesMissingFromIndex) { $0.union($1) }
        }
        var inherited = facts.reduce(into: missingConformances) { all, facts in
            all.merge(facts.inherited) { $0.union($1) }
        }
        // `Codable` and its two protocols are the ones of the standard library that this file knows.
        inherited[Self.codable, default: []].formUnion([Self.decodable, Self.encodable])
        let inheritance = Inheritance(inherited)

        referenced = collectedInfo.values.reduce(into: Self.propertiesUsedByGeneratedCoding(facts, inheritance)) {
            $0.formUnion($1.referenced)
        }

        var usedMembers = Set<Member>()
        for owner in inheritance.withInherited(facts.flatMap(\.entryPoints)) {
            usedMembers.insert(Member(type: owner, name: Name(name: "main()", kind: .static)))
        }
        for type in facts.flatMap(\.propertyWrappers) {
            usedMembers.insert(Member(type: type, name: Name(name: "wrappedValue", kind: .instance)))
            usedMembers.insert(Member(type: type, name: Name(name: "projectedValue", kind: .instance)))
        }
        self.usedMembers = usedMembers

        var requirements = facts.reduce(into: [String: Set<Name>]()) { all, facts in
            all.merge(facts.requirements) { $0.union($1) }
        }
        requirements[Self.encodable, default: []].insert(Name(name: "encode(to:)", kind: .instance))
        let typesWithKnownRequirements = facts.reduce(
            into: Self.markerProtocols.union([Self.codable, Self.decodable, Self.encodable])
        ) { $0.formUnion($1.declaredTypes) }
        var witnessNames = [String: Set<Name>]()
        var ownersOfUnknownWitnesses = Set<String>()
        for (type, protocols) in missingConformances {
            let protocols = inheritance.withInherited(protocols)
            // A witness can come from the type, a superclass, an extension of a protocol or the file scope.
            let owners = inheritance.withInherited([type]).union([Member.fileScope])
            if !protocols.isSubset(of: typesWithKnownRequirements) {
                ownersOfUnknownWitnesses.formUnion(owners.subtracting([type]))
            }
            let names = protocols.flatMap { requirements[$0] ?? [] }
            guard names.isNotEmpty else {
                continue
            }
            for owner in owners {
                witnessNames[owner, default: []].formUnion(names)
            }
        }
        self.witnessNames = witnessNames
        self.ownersOfUnknownWitnesses = ownersOfUnknownWitnesses
    }

    /// The stored properties of the types for which the compiler generates `init(from:)` or `encode(to:)`.
    private static func propertiesUsedByGeneratedCoding(_ facts: [TypeFacts], _ inheritance: Inheritance)
        -> Set<String> {
        let typesWithGeneratedDecoding = facts.reduce(into: inheritance.withHeirs(decodable)) {
            $0.subtract($1.typesWithOwnDecoding)
        }
        let typesWithGeneratedEncoding = facts.reduce(into: inheritance.withHeirs(encodable)) {
            $0.subtract($1.typesWithOwnEncoding)
        }
        var properties = Set<String>()
        for (type, stored) in facts.flatMap(\.storedProperties)
        where typesWithGeneratedDecoding.contains(type) || typesWithGeneratedEncoding.contains(type) {
            properties.formUnion(stored)
        }
        return properties
    }

    func contains(_ declaration: UnusedDeclarationRule.DeclaredUSR) -> Bool {
        if referenced.contains(declaration.usr) {
            return true
        }
        guard let member = declaration.member else {
            return false
        }
        return usedMembers.contains(member)
            || ownersOfUnknownWitnesses.contains(member.type)
            || witnessNames[member.type]?.contains(member.name) == true
    }
}

/// Which type inherits from which, as all files together tell.
private struct Inheritance {
    /// For each type, protocol or type alias: what it inherits from, conforms to or stands for.
    private let inherited: [String: Set<String>]
    /// For each of these: what inherits from it, conforms to it or stands for it.
    private let heirs: [String: [String]]

    init(_ inherited: [String: Set<String>]) {
        self.inherited = inherited
        heirs = inherited.reduce(into: [:]) { heirs, entry in
            for type in entry.value {
                heirs[type, default: []].append(entry.key)
            }
        }
    }

    /// The given types with everything they inherit from, directly or not.
    func withInherited(_ types: some Sequence<String>) -> Set<String> {
        Self.closure(of: types) { inherited[$0] ?? [] }
    }

    /// The given type with everything that inherits from it, directly or not.
    func withHeirs(_ type: String) -> Set<String> {
        Self.closure(of: [type]) { heirs[$0] ?? [] }
    }

    private static func closure<Next: Sequence<String>>(of types: some Sequence<String>, next: (String) -> Next)
        -> Set<String> {
        var result = Set<String>()
        var typesToVisit = Array(types)
        while let type = typesToVisit.popLast() {
            if result.insert(type).inserted {
                typesToVisit.append(contentsOf: next(type))
            }
        }
        return result
    }
}
