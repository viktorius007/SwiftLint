import SourceKittenFramework

extension UnusedDeclarationUsage {
    /// Gathers the type facts of one file from the entities of its index, visited in any order.
    struct TypeFactsCollector {
        private var facts = TypeFacts()
        /// The type that the entity at a line and column declares or extends. Looking it up for an extension
        /// reads all its entities, so it is done once and not for every member.
        private var types = [Position: String?]()
        /// Asks SourceKit for the USRs of what a declaration overrides or satisfies.
        private let overridden: (SourceKittenDictionary) -> [String]
        /// Tells whether the source declares a property with `let` and an initial value.
        private let isInitializedConstant: (SourceKittenDictionary) -> Bool
        /// Asks SourceKit for the name of the module that declares what is referred to at the entity's position.
        private let moduleName: (SourceKittenDictionary) -> String?
        /// Asks SourceKit for the name of the module that declares the type with the given USR.
        private let moduleNameOfType: (String) -> String?
        /// Tells whether the source constrains a protocol to the type of a reference: `where Self: Q`.
        private let constrainsSelf: (SourceKittenDictionary) -> Bool
        /// `Swift.Result`. The code that the macros of Swift Testing expand to calls members of it whose names
        /// start with `__`, like members of the types of Swift Testing.
        private static let result = "s:s6ResultO"
        /// For each USR that SourceKit was asked about: whether Swift Testing declares it.
        private var declaredBySwiftTesting = [String: Bool]()
        /// For each type that the body of a type declares: that type.
        private var typeAround = [String: String]()
        /// For each type that the body of an extension declares: the extended type, if it is known, and what the
        /// header of the extension names.
        private var extensionAround = [String: (type: String?, header: Header)]()
        /// The name of each type that the file declares.
        private var namesOfTypes = [String: String]()
        /// The types with a test or a tag of Swift Testing in their body.
        private var typesHoldingTests = Set<String>()
        /// What the header of the extension at a line and column names. Like `types`, it is read once for an
        /// extension and not for every member.
        private var namedByHeaders = [Position: Header]()

        /// The facts of all visited entities.
        var typeFacts: TypeFacts {
            // The code that `@Test` or `@Tag` expands to names the type of the test or tag as the source around
            // it does: `Outer.Inner.self` in the body of `Inner` in `Outer`, also where an extension of `Outer`
            // declares `Inner`. For a test or tag in an extension, it names what the header of the extension does.
            // It finds the first of these names in the types whose bodies are around it, the innermost first,
            // then in the type that the extension around them extends, and only then at file scope, and each
            // further name in what the name before it stands for. Each name is noted for each of these types;
            // a generic argument of the header, as in `extension Outer.Box<Int>`, is not.
            var facts = facts
            for holder in typesHoldingTests {
                var types = [String]()
                var names = Set<String>()
                var type: String? = holder
                while let current = type {
                    facts.runBySwiftTesting.insert(current)
                    types.append(current)
                    names.formUnion([namesOfTypes[current]].compactMap(\.self))
                    if let around = extensionAround[current] {
                        types += [around.type].compactMap(\.self)
                        names.formUnion(around.header.names)
                        facts.runBySwiftTesting.formUnion(around.header.usrs)
                    }
                    type = typeAround[current]
                }
                facts.note(names: names, writtenInTypes: types)
            }
            return facts
        }

        /// - parameter conformancesMissingFromIndex: For each type, the inherited types of its extensions that
        ///                                           the file has and its index lacks.
        init(conformancesMissingFromIndex: [String: Set<String>],
             overridden: @escaping (SourceKittenDictionary) -> [String],
             isInitializedConstant: @escaping (SourceKittenDictionary) -> Bool,
             moduleName: @escaping (SourceKittenDictionary) -> String?,
             moduleNameOfType: @escaping (String) -> String?,
             constrainsSelf: @escaping (SourceKittenDictionary) -> Bool) {
            facts.conformancesMissingFromIndex = conformancesMissingFromIndex
            self.overridden = overridden
            self.isInitializedConstant = isInitializedConstant
            self.moduleName = moduleName
            self.moduleNameOfType = moduleNameOfType
            self.constrainsSelf = constrainsSelf
        }

        /// Notes what the entity tells about types.
        ///
        /// - returns: The entity as a member of the type that its parent declares or extends, if it is one.
        mutating func visit(_ entity: SourceKittenDictionary, in parent: SourceKittenDictionary) -> Member? {
            guard entity.declarationKind != nil else {
                noteTypeAlias(standingFor: entity, declaredBy: parent)
                noteSwiftTesting(attribute: entity, in: parent)
                return nil
            }
            let owner = declaredOrExtendedType(of: parent)
            if let type = declaredOrExtendedType(of: entity) {
                noteType(type, declaredOrExtendedBy: entity)
            }
            noteDeclaredType(entity, in: parent)
            if let owner, parent.declarationKind != .protocol {
                noteGeneratedCode(of: owner, replacedBy: entity)
            }
            if let owner, entity.name?.hasPrefix("__") == true, let usr = entity.usr,
               owner == Self.result || isDeclaredBySwiftTesting(owner, referredToAtPositionOf: nil) {
                facts.runBySwiftTesting.insert(usr)
            }
            guard let name = entity.memberName else {
                return nil
            }
            guard let type = owner else {
                if entity.declarationKind == .functionFree, let usr = entity.usr {
                    facts.functionsAtFileScope[name.withoutLabels.name, default: []].insert(usr)
                }
                return memberAtFileScope(entity, named: name)
            }
            if parent.declarationKind == .protocol, entity.declarationKind != .typealias {
                // What a protocol declares in its body is a requirement and no witness. A type alias there is a
                // member, like one in an extension of the protocol.
                facts.requirements[type, default: []].insert(name)
                return nil
            }
            return Member(type: type, name: name)
        }

        /// Notes the entity and what is around it, if it declares a type.
        private mutating func noteDeclaredType(_ entity: SourceKittenDictionary, in parent: SourceKittenDictionary) {
            guard entity.declaresType, let usr = entity.usr else {
                return
            }
            facts.declaredTypes.insert(usr)
            if entity.name == "Void" {
                facts.typesNamedVoid.insert(usr)
            }
            namesOfTypes[usr] = entity.name
            if parent.declaresType {
                typeAround[usr] = parent.usr
            } else {
                extensionAround[usr] = (declaredOrExtendedType(of: parent), namedByHeader(of: parent))
            }
        }

        /// The entity as what file scope declares under the given name, if it is an operator, or what a call can
        /// choose there by its name: a function or a variable.
        private func memberAtFileScope(_ entity: SourceKittenDictionary, named name: Name) -> Member? {
            if entity.isOperator {
                return Member(type: Member.fileScope, name: name)
            }
            return name.kind == .function ? Member(type: Member.functions, name: name) : nil
        }

        /// Notes what a type alias stands for, if the parent declares one and the entity is a reference of it.
        private mutating func noteTypeAlias(standingFor entity: SourceKittenDictionary,
                                            declaredBy parent: SourceKittenDictionary) {
            // A type alias can name the module of a type: `typealias A = Module.P`.
            guard parent.declarationKind == .typealias, entity.isReference, !entity.isModuleReference,
                  let alias = parent.usr, let usr = entity.usr else {
                return
            }
            facts.inherited[alias, default: []].insert(usr)
            if entity.isProtocolOrTypeAliasReference {
                facts.inheritedProtocolsAndTypeAliases.insert(usr)
            }
        }

        private mutating func noteType(_ type: String, declaredOrExtendedBy entity: SourceKittenDictionary) {
            if entity.declarationKind == .struct {
                facts.structs.insert(type)
            }
            let attributes = entity.enclosedSwiftAttributes
            if attributes.contains(.main) {
                facts.entryPoints.insert(type)
            }
            if attributes.contains(.propertyWrapper) {
                facts.propertyWrappers.insert(type)
            }
            var related = entity.related
            if entity.declarationKind == .protocol {
                // The index does not relate a protocol to what its `where` clause constrains it to. The source
                // is asked about the references that the protocol has beside the related ones.
                let known = Set(related.compactMap(\.usr))
                related += entity.entities.filter { reference in
                    reference.isReference && reference.usr.map(known.contains) == false && constrainsSelf(reference)
                }
            }
            if related.isNotEmpty {
                facts.inherited[type, default: []].formUnion(related.compactMap(\.usr))
                facts.inheritedProtocolsAndTypeAliases.formUnion(
                    related.filter(\.isProtocolOrTypeAliasReference).compactMap(\.usr)
                )
            }
        }

        /// Notes whether the member takes the place of code that the compiler would generate for the type, and
        /// whether it is a stored property that such code reads or writes.
        private mutating func noteGeneratedCode(of type: String, replacedBy member: SourceKittenDictionary) {
            var satisfied = member.relatedUSRs.filter(GeneratedCode.allRequirements.contains)
            // Where the index leaves the conformance out, it relates no declaration to a requirement. SourceKit
            // tells whether one satisfies a requirement, in the file that declares the conformance only.
            if satisfied.isEmpty, facts.conformancesMissingFromIndex[type] != nil, let name = member.name,
               GeneratedCode.namesOfRequirements.contains(name) {
                satisfied = overridden(member)
            }
            for code in GeneratedCode.allCases where satisfied.contains(where: code.requirements.contains) {
                facts.typesWithOwnCode[code, default: []].insert(type)
            }
            // The compiler generates the getter of a stored property. Generated code leaves out a lazy one.
            if member.declarationKind == .varInstance, let usr = member.usr,
               member.entities.contains(where: { $0.declarationKind == .functionAccessorGetter && $0.isImplicit }),
               !member.enclosedSwiftAttributes.contains(.lazy) {
                facts.storedProperties[type, default: []].insert(usr)
                if isInitializedConstant(member) {
                    facts.initializedConstants.insert(usr)
                }
            }
        }

        /// Notes what Swift Testing runs, if the entity is the reference of an attribute to `@Test` or `@Suite`.
        private mutating func noteSwiftTesting(attribute: SourceKittenDictionary, in parent: SourceKittenDictionary) {
            // The name of a macro ends with its parameters: `Test(_:)`.
            guard attribute.kind == "source.lang.swift.ref.macro", let macro = attribute.usr,
                  let name = attribute.name?.prefix(while: { $0 != "(" }),
                  case let marksTest = name == "Test", case let marksTag = name == "Tag",
                  marksTest || marksTag || name == "Suite",
                  let marked = parent.declaration(following: attribute),
                  isDeclaredBySwiftTesting(macro, referredToAtPositionOf: attribute) else {
                return
            }
            // Nothing runs a tag. It counts as used where something names it; its name can keep it too (`typeFacts`).
            if !marksTag, let usr = marked.usr {
                facts.runBySwiftTesting.insert(usr)
            }
            if marksTest, let name = marked.memberName?.withoutLabels {
                let type = declaredOrExtendedType(of: parent) ?? Member.unknownType
                facts.tests.insert(Member(type: type, name: name))
                // The call of a static test can choose the initializer of a type of its name.
                if name.kind == .static {
                    facts.tests.insert(Member(type: type, name: Name(name: name.name, kind: .type)))
                }
                // The call of a test that is a method of an instance starts with the name of its type as the
                // source around the test has it: in an extension, as its header names the type.
                if name.kind == .instance {
                    let names = parent.declaresType ? Set([parent.name].compactMap(\.self))
                        : namedByHeader(of: parent).names
                    facts.namesOfTypesOfTests[type, default: []].formUnion(names.map {
                        Name(name: $0, kind: .type).withoutLabels.name
                    })
                }
            }
            if marksTest || marksTag, parent.declaresType, let usr = parent.usr {
                typesHoldingTests.insert(usr)
            } else if marksTest || marksTag {
                let header = namedByHeader(of: parent)
                facts.runBySwiftTesting.formUnion(header.usrs)
                facts.note(names: header.names, writtenInTypes: [declaredOrExtendedType(of: parent)].compactMap(\.self))
            }
        }

        /// What the header of the entity names, if it is an extension.
        private mutating func namedByHeader(of entity: SourceKittenDictionary) -> Header {
            guard entity.isExtension, let line = entity.line, let column = entity.column else {
                return ([], [])
            }
            let position = Position(line: line, column: column)
            if let named = namedByHeaders[position] {
                return named
            }
            let references = entity.entities.filter(entity.isExtension(namedWith:))
            let named = (usrs: Set(references.compactMap(\.usr)), names: Set(references.compactMap(\.name)))
            namedByHeaders[position] = named
            return named
        }

        /// Whether Swift Testing declares what has the given USR. The USR does not tell: it names the module as
        /// the symbols of the module do, and a module can be compiled with another name for its symbols, as the
        /// Swift Testing of a toolchain for macOS is. SourceKit tells the module's own name.
        ///
        /// - parameter usr:    USR of a macro or a type.
        /// - parameter entity: For a macro, an entity at the position of a reference to it: SourceKit finds no
        ///                     macro by its USR. Nil for a type: at the position of a reference to it, SourceKit
        ///                     can tell about a type alias that stands for it instead.
        private mutating func isDeclaredBySwiftTesting(_ usr: String,
                                                       referredToAtPositionOf entity: SourceKittenDictionary?) -> Bool {
            if let known = declaredBySwiftTesting[usr] {
                return known
            }
            let module = if let entity { moduleName(entity) } else { moduleNameOfType(usr) }
            let isDeclared = module == UnusedDeclarationUsage.swiftTesting
            declaredBySwiftTesting[usr] = isDeclared
            return isDeclared
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

private extension SourceKittenDictionary {
    /// The name by which a type would find this declaration as its member, or by which a call would find it as a
    /// function or a variable at file scope.
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
        case .functionFree, .varGlobal:
            return UnusedDeclarationUsage.Name(name: name, kind: .function)
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

    var isModuleReference: Bool {
        kind == "source.lang.swift.ref.module"
    }

    var isTypeAliasReference: Bool {
        kind == "source.lang.swift.ref.typealias"
    }

    var isImplicit: Bool {
        value["key.is_implicit"] as? Bool == true
    }

    var relatedUSRs: [String] {
        related.compactMap(\.usr)
    }

    /// What the index relates the declaration to: what it inherits from, overrides or satisfies.
    var related: [SourceKittenDictionary] {
        (value["key.related"] as? [[String: any SourceKitRepresentable]])?.map(Self.init) ?? []
    }

    var isProtocolOrTypeAliasReference: Bool {
        kind == "source.lang.swift.ref.protocol" || isTypeAliasReference
    }

    var usr: String? {
        value["key.usr"] as? String
    }
}

/// What the header of an extension names, and by which names.
private typealias Header = (usrs: Set<String>, names: Set<String>)

private struct Position: Hashable {
    let line: Int64
    let column: Int64
}
