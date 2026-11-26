// The index holds no reference for some uses of a declaration. This file finds the ones that follow from facts
// about the declaration's type:
//
// * `main()` is called by the language if a type marked `@main` finds it by member lookup. What that lookup
//   finds and which one it calls is not known here, so every static `main()` without parameters counts as used
//   that the type, an extension of it or something it inherits from declares, also one that the type cannot
//   reach, like a private one of its superclass. Of a type that no linted file declares, the inherited types
//   are known in part only: SourceKit is asked about protocols and type aliases, and not about classes. So
//   where a type marked `@main` inherits, as far as known, from a type that no linted file declares, every
//   static `main()` without parameters counts as used, whatever type declares it. The protocols of
//   `knownTypes` are no such type: nothing that could declare a `main()` is inherited through them.
// * `wrappedValue` and `projectedValue` are read by the properties that a property wrapper is applied to.
// * The stored properties of a type are written by the `init(from:)` and read by the `encode(to:)` that the
//   compiler generates for `Decodable` and `Encodable`, and the ones of a struct are read by the `==` and the
//   `hash(into:)` that it generates for `Equatable` and `Hashable` (see `GeneratedCode`), also where a type
//   gets one of these protocols through a protocol or a type alias that no linted file declares (see
//   `inheritanceOfTypesDeclaredElsewhere`). The index does not list generated code. It marks a declaration
//   that takes its place, also one that a subclass inherits or that is declared outside of the type, as
//   satisfying the protocol's requirement. Where it leaves the conformance out (see below), SourceKit tells
//   whether a declared one satisfies the requirement, in the file that declares the conformance. In another
//   file a declared one is not known, and the stored properties count as used.
// * A conformance uses the members that satisfy the protocol's requirements. The index lists these witnesses
//   under the conforming declaration (see `isWitnessDeclaredElsewhere`), with one exception: the compiler leaves
//   an extension out of the index if it has no members, also none that the compiler generates for it, and if
//   none of its inherited types is a single protocol or class, as in `extension T: P & Q {}` or with a type
//   alias of such a composition. For these extensions, a member counts as a witness if a requirement of one of
//   the protocols has its name, and if the type could find it: in itself, in what it inherits from, or at file
//   scope for an operator. The requirements of a protocol that no linted file declares are not known. Then
//   everything the type inherits and every operator at file scope counts as a witness. The type's own members do
//   not: SourceKit tells for each of them whether it satisfies a requirement. It tells so in the file that
//   declares the conformance only. In all other files, the type's members count as witnesses too.
// * A test and a suite of Swift Testing are run by the code that `@Test` and `@Suite` expand to. The code of
//   `@Test` also names the type of the test as the source around the test does: `Outer.Inner.self` in the body
//   of `Inner` in the body or in an extension of `Outer`, and what the header of the extension names for a test
//   in an extension (see `typeFacts`). The index has that code only if the compiler expanded the macros, and
//   analyzer rules get an index without these expansions (see `AnalyzerRule`). So a declaration counts as run if
//   it carries one of the two attributes. The index tells which macro an attribute refers to, and it lists that
//   reference right before the declaration that carries the attribute. SourceKit tells which module declares the
//   macro (see `isDeclaredBySwiftTesting`). For an attribute that another macro attaches, the index has a
//   reference without a name, and such a test or suite is not known. The code of `@Test` calls the test by its
//   name, and the compiler chooses what that call runs among everything of that name that the call can reach. It
//   can choose another declaration than the test: a function marked `async`, one with further parameters that
//   have default values, one that the type of the test inherits, a property whose value can be
//   called, for a static test the initializer of an inherited type. So a test stands for every declaration that
//   has its name, whatever its labels, and is of its kind, a method or property of an instance for a test that
//   is a method of an instance, and for a static test a static one or a nested struct, enum, class, actor or
//   type alias, in the type of the test, in everything that it inherits from, and in the protocols that a type
//   can conform to without naming them (see `impliedProtocols`). A test at file scope stands for every function
//   and variable of its name at file scope, in whatever file and module. Where the type of a test is not known,
//   or is or inherits from, as far as known, a type that no linted file declares, the test stands for its name
//   in every type (see `namedLikeTests`). The call of a test that is a method of an instance starts with the
//   name of its type, and a function at file scope can have that name: then the function counts as used and
//   the test stands for its name in every type. What the value of a property or variable runs when it is
//   called, its `callAsFunction`, is not known. The code of `@Test` also writes `Void`, so every type and type
//   alias of that name counts as used where a linted file has a test. Where a nested type or type alias, in the
//   type of a test or in what it inherits from, has the name of the type of the test or of a type around it,
//   the code of `@Test` names the nested one. That is not known. The code that the macros of Swift Testing
//   expand to calls members of its types and of `Swift.Result` whose names start with `__`. An extension of
//   such a type can declare a member that these calls choose, so each of its members with such a name counts as
//   used.
//
// The entry points, the values of a property wrapper and the witnesses of an extension that the index leaves out
// are decided by name. A name tells nothing about types and constraints, so an unused member is kept if it shares
// its name and labels with a used one of the same type, also where a constraint of its extension rules it out.
// What a test of Swift Testing stands for is decided by its name without labels (see above).
//
// A type alias that a linted file declares counts as standing for every type that its declaration mentions, also
// for a generic argument as in `typealias A = B<C>` and for a type after `where`. A type inherits from the alias
// where the index or the syntax names the alias as inherited. For a superclass that is written as an alias, the
// index names the class instead. An extension uses every type alias that its header names. Where the alias
// stands for the extended type, it also uses the types around the alias (see
// `isExtensionWrittenWithoutItsType`). A protocol inherits from what its `where` clause constrains it to, as
// from `Q` in `protocol P where Self: Q`. The index does not relate the two, and the source tells (see
// `selfConstraintFinder`). A protocol or a type alias that no linted file declares counts as inheriting from
// every type that SourceKit prints after its colon or equals sign and before `where`, also from a generic
// argument of a superclass, as in `protocol P: B<C>` with a class `B`.
//
// A declaration is known by its USR in all files together, so two declarations with one USR are one. Two
// modules with one name, each seen by other files of one run, have the same USRs: what SourceKit tells about a
// protocol of the one counts for the other too. So has a module that is compiled with the `-module-abi-name` of
// another. SourceKit is asked about a declaration by its USR. Where a file sees two declarations with one USR,
// SourceKit tells about one of them, and which one can change with the order of the file's imports.
//
// Swift Testing is known by the name of its module, `Testing`. Another module of that name counts as it.

/// Everything that all files together use.
struct UnusedDeclarationUsage {
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
        /// What of `inherited` the index refers to as a protocol or as a type alias. SourceKit is asked about the
        /// ones that no file declares. The inherited types of an extension that the index leaves out are not
        /// among them: the index has every extension that holds generated code.
        var inheritedProtocolsAndTypeAliases = Set<String>()
        /// For each type: the USRs of its stored instance properties that are not lazy.
        var storedProperties = [String: Set<String>]()
        /// The USRs of the stored instance properties declared with `let` and an initial value.
        var initializedConstants = Set<String>()
        /// For each kind of generated code: the types with a declaration that takes its place.
        var typesWithOwnCode = [GeneratedCode: Set<String>]()
        /// The structs that the file declares.
        var structs = Set<String>()
        /// The types, protocols, type aliases and generic parameters that the file declares.
        var declaredTypes = Set<String>()
        /// The tests and suites of Swift Testing, the types that the expansions of its macros name, and what
        /// they can call.
        var runBySwiftTesting = Set<String>()
        /// The tests of Swift Testing, each as a member of its type, or of `Member.unknownType`, and named
        /// without its labels, a static one also as a type of its name: the code that runs a test calls it by
        /// its name, and the compiler chooses what that call runs.
        var tests = Set<Member>()
        /// For the type of each test that is a method of an instance: the name of the type as the index has it,
        /// without the types around it. The code that runs such a test calls that name to make the value it
        /// calls the test on. The type that is not known can have several names.
        var namesOfTypesOfTests = [String: Set<String>]()
        /// The types and type aliases named `Void`: the code that runs a test writes that name.
        var typesNamedVoid = Set<String>()
    }

    static let decodable = "s:Se"
    static let encodable = "s:SE"
    static let codable = "s:s7Codablea"
    /// Name of the module of Swift Testing.
    static let swiftTesting = "Testing"
    /// Declarations of the standard library whose requirements and inherited types are known here: the ones of
    /// coding, and the protocols that cannot have requirements.
    static let knownTypes: Set = [
        codable, decodable, encodable, "s:s8SendableP", "s:s16SendableMetatypeP", "s:s15BitwiseCopyableP",
    ]

    /// The protocols that a type can conform to without naming them, and that an extension can give members to:
    /// `Equatable`, `Hashable` and `RawRepresentable` for an enum, `Actor` for an actor.
    static let impliedProtocols: Set = ["s:SQ", "s:SH", "s:SY", "s:ScA"]

    private let referenced: Set<String>
    private let usedMembers: Set<Member>
    /// What the calls can choose with which the code of `@Test` runs the tests (see `namedLikeTests`).
    private let namedLikeTests: (members: Set<Member>, names: Set<Name>)
    /// For each type that can hold a witness of a conformance missing from the index: the requirements of
    /// these conformances.
    private let witnessNames: [String: Set<Name>]
    /// The types that can hold a witness of a conformance missing from the index to a protocol with unknown
    /// requirements.
    private let ownersOfUnknownWitnesses: Set<String>

    /// - parameter collectedInfo: What each file tells.
    /// - parameter sourceKit:     Tells about declarations that no file declares.
    init(of collectedInfo: [SwiftLintFile: UnusedDeclarationRule.FileUSRs],
         sourceKit: InheritanceSource = .sourceKit) {
        let facts = collectedInfo.values.map(\.typeFacts)
        let missingConformances = facts.reduce(into: [String: Set<String>]()) { all, facts in
            all.merge(facts.conformancesMissingFromIndex) { $0.union($1) }
        }
        var inherited = facts.reduce(into: missingConformances) { all, facts in
            all.merge(facts.inherited) { $0.union($1) }
        }
        let declaredTypes = facts.reduce(into: Set<String>()) { $0.formUnion($1.declaredTypes) }
        inherited.merge(
            Self.inheritanceOfTypesDeclaredElsewhere(collectedInfo, declaredTypes, sourceKit: sourceKit)
        ) { $0.union($1) }
        inherited[Self.codable, default: []].formUnion([Self.decodable, Self.encodable])
        let inheritance = Inheritance(inherited)

        var referenced = collectedInfo.values.reduce(into: Self.propertiesUsedByGeneratedCode(facts, inheritance)) {
            $0.formUnion($1.referenced)
            $0.formUnion($1.typeFacts.runBySwiftTesting)
        }

        var usedMembers = Self.entryPoints(collectedInfo, inheritance, declaredTypes)
        for type in facts.flatMap(\.propertyWrappers) {
            usedMembers.insert(Member(type: type, name: Name(name: "wrappedValue", kind: .instance)))
            usedMembers.insert(Member(type: type, name: Name(name: "projectedValue", kind: .instance)))
        }
        self.usedMembers = usedMembers
        namedLikeTests = Self.namedLikeTests(collectedInfo, inheritance, declaredTypes)
        if facts.contains(where: \.tests.isNotEmpty) {
            referenced.formUnion(facts.flatMap(\.typesNamedVoid))
        }

        var requirements = facts.reduce(into: [String: Set<Name>]()) { all, facts in
            all.merge(facts.requirements) { $0.union($1) }
        }
        requirements[Self.encodable, default: []].insert(Name(name: "encode(to:)", kind: .instance))
        let typesWithKnownRequirements = declaredTypes.union(Self.knownTypes)
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
        referenced.formUnion(Self.membersInOtherFilesThanTheirConformance(collectedInfo) {
            !inheritance.withInherited($0).isSubset(of: typesWithKnownRequirements)
        })
        self.referenced = referenced
    }

    /// The members of a type in other files than the one that declares a conformance of the type which is
    /// missing from the index, and whose requirements are not known.
    private static func membersInOtherFilesThanTheirConformance(
        _ collectedInfo: [SwiftLintFile: UnusedDeclarationRule.FileUSRs],
        hasUnknownRequirements: (Set<String>) -> Bool
    ) -> Set<String> {
        var filesOfConformances = [String: Set<SwiftLintFile>]()
        for (file, info) in collectedInfo {
            for (type, protocols) in info.typeFacts.conformancesMissingFromIndex
            where hasUnknownRequirements(protocols) {
                filesOfConformances[type, default: []].insert(file)
            }
        }
        guard filesOfConformances.isNotEmpty else {
            return []
        }
        var members = Set<String>()
        for (file, info) in collectedInfo {
            for declaration in info.declared {
                if let type = declaration.member?.type, let files = filesOfConformances[type], files != [file] {
                    members.insert(declaration.usr)
                }
            }
        }
        return members
    }

    /// What the calls can choose with which the code of `@Test` runs the tests, by name without labels: the
    /// members of the type of a test, of everything that it inherits from and of `impliedProtocols`. Of a type
    /// that no linted file declares, the inherited types are known in part only. So where the type of a test is
    /// not known, or is such a type or inherits from one, as far as known, the test stands for its name in every
    /// type. For a test at file scope, that is every function and variable of its name at file scope: nothing
    /// else is of its kind. The call of a test that is a method of an instance starts with the name of its
    /// type. Where a function at file scope has that name, the call can choose it, and the type of what it
    /// returns is not known: the function counts as used, and the test stands for its name in every type.
    private static func namedLikeTests(_ collectedInfo: [SwiftLintFile: UnusedDeclarationRule.FileUSRs],
                                       _ inheritance: Inheritance,
                                       _ declaredTypes: Set<String>) -> (members: Set<Member>, names: Set<Name>) {
        let typesKnownInFull = declaredTypes.union(knownTypes)
        let namesOfTypes = collectedInfo.values.reduce(into: Set<String>()) {
            $0.formUnion($1.typeFacts.namesOfTypesOfTests.values.joined())
        }
        var functions = Set<String>()
        if namesOfTypes.isNotEmpty {
            for declaration in collectedInfo.values.flatMap(\.declared) {
                if let name = declaration.member?.name.withoutLabels, name.kind == .function,
                   namesOfTypes.contains(name.name) {
                    functions.insert(name.name)
                }
            }
        }
        var members = Set<Member>()
        var names = Set(functions.map { Name(name: $0, kind: .function) })
        for facts in collectedInfo.values.map(\.typeFacts) {
            for test in facts.tests {
                let owners = inheritance.withInherited([test.type])
                let isMadeByFunction = test.name.kind == .instance
                    && facts.namesOfTypesOfTests[test.type]?.isDisjoint(with: functions) == false
                if owners.isSubset(of: typesKnownInFull), !isMadeByFunction {
                    members.formUnion(owners.union(impliedProtocols).map { Member(type: $0, name: test.name) })
                } else {
                    names.insert(test.name)
                }
            }
        }
        return (members, names)
    }

    /// Every `main()` that a type marked `@main` can find.
    private static func entryPoints(_ collectedInfo: [SwiftLintFile: UnusedDeclarationRule.FileUSRs],
                                    _ inheritance: Inheritance,
                                    _ declaredTypes: Set<String>) -> Set<Member> {
        let name = Name(name: "main()", kind: .static)
        let owners = inheritance.withInherited(collectedInfo.values.flatMap(\.typeFacts.entryPoints))
        var entryPoints = Set(owners.map { Member(type: $0, name: name) })
        guard !owners.isSubset(of: declaredTypes.union(knownTypes)) else {
            return entryPoints
        }
        // What a type that no file declares inherits from is known in part only, so any type can be among it.
        for declaration in collectedInfo.values.flatMap(\.declared) {
            if let member = declaration.member, member.name == name {
                entryPoints.insert(member)
            }
        }
        return entryPoints
    }

    /// The stored properties that the code reads or writes which the compiler generates for a conformance.
    private static func propertiesUsedByGeneratedCode(_ facts: [TypeFacts], _ inheritance: Inheritance)
        -> Set<String> {
        let structs = facts.reduce(into: Set<String>()) { $0.formUnion($1.structs) }
        var properties = Set<String>()
        for code in GeneratedCode.allCases {
            var types = facts.reduce(into: inheritance.withHeirs(code.conformance)) {
                $0.subtract($1.typesWithOwnCode[code] ?? [])
            }
            if code.isForStructsOnly {
                types.formIntersection(structs)
            }
            for facts in facts {
                for (type, stored) in facts.storedProperties where types.contains(type) {
                    properties.formUnion(
                        code.skipsInitializedConstants ? stored.subtracting(facts.initializedConstants) : stored
                    )
                }
            }
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
            || isNamedLikeTest(member)
            || ownersOfUnknownWitnesses.contains(member.type)
            || witnessNames[member.type]?.contains(member.name) == true
    }
}

private extension UnusedDeclarationUsage {
    func isNamedLikeTest(_ member: Member) -> Bool {
        guard namedLikeTests.members.isNotEmpty || namedLikeTests.names.isNotEmpty else {
            return false
        }
        let name = member.name.withoutLabels
        return namedLikeTests.names.contains(name)
            || namedLikeTests.members.contains(Member(type: member.type, name: name))
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
