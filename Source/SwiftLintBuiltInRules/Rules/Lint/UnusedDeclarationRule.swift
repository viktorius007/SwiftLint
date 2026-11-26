import Foundation
import SourceKittenFramework

struct UnusedDeclarationRule: AnalyzerRule, CollectingRule {
    struct FileUSRs: Hashable {
        var referenced: Set<String>
        var declared: Set<DeclaredUSR>
        /// What the file tells about the types whose members are used without a reference in the index.
        var typeFacts = UnusedDeclarationUsage.TypeFacts()
        /// What the file is compiled with. SourceKit is asked with it about declarations that no file declares.
        var compilerArguments = [String]()

        fileprivate static var empty: Self { Self(referenced: [], declared: []) }
    }

    struct DeclaredUSR: Hashable {
        let usr: String
        let nameOffset: ByteCount
        /// Set if the declaration is a member of a type or of an extension.
        var member: UnusedDeclarationUsage.Member?
    }

    typealias FileInfo = FileUSRs

    var configuration = UnusedDeclarationConfiguration()

    static let description = RuleDescription(
        identifier: "unused_declaration",
        name: "Unused Declaration",
        description: "Declarations should be referenced at least once within all files linted",
        kind: .lint,
        nonTriggeringExamples: UnusedDeclarationRuleExamples.nonTriggeringExamples,
        triggeringExamples: UnusedDeclarationRuleExamples.triggeringExamples,
        requiresFileOnDisk: true
    )

    func collectInfo(for file: SwiftLintFile, compilerArguments: [String]) -> Self.FileUSRs {
        guard compilerArguments.isNotEmpty else {
            Issue.missingCompilerArguments(path: file.path, ruleID: Self.identifier).print()
            return .empty
        }

        guard let index = file.index(compilerArguments: compilerArguments), index.value.isNotEmpty else {
            Issue.indexingError(path: file.path, ruleID: Self.identifier).print()
            return .empty
        }

        guard let editorOpen = (try? Request.editorOpen(file: file.file).sendIfNotDisabled())
                .map(SourceKittenDictionary.init) else {
            Issue.fileNotReadable(path: file.path, ruleID: Self.identifier).print()
            return .empty
        }

        let (declared, typeFacts) = file.declaredUSRs(index: index,
                                                      editorOpen: editorOpen,
                                                      compilerArguments: compilerArguments,
                                                      configuration: configuration)
        return FileUSRs(
            referenced: file.referencedUSRs(index: index, editorOpen: editorOpen),
            declared: declared,
            typeFacts: typeFacts,
            compilerArguments: compilerArguments
        )
    }

    func validate(file: SwiftLintFile,
                  collectedInfo: [SwiftLintFile: Self.FileUSRs],
                  compilerArguments _: [String]) -> [StyleViolation] {
        violations(in: file,
                   declaredUSRs: collectedInfo[file]?.declared ?? [],
                   usage: UnusedDeclarationUsage(of: collectedInfo))
    }

    func validate(file: SwiftLintFile, using storage: RuleStorage, compilerArguments _: [String]) -> [StyleViolation] {
        // What all files use is the same for every file and large. Building it for every file would take time
        // that grows with the square of the number of files.
        violations(in: file,
                   declaredUSRs: storage.collectedInfo(for: self, file: file)?.declared ?? [],
                   usage: storage.summary(for: self) { UnusedDeclarationUsage(of: $0) })
    }

    private func violations(in file: SwiftLintFile,
                            declaredUSRs: Set<DeclaredUSR>,
                            usage: UnusedDeclarationUsage) -> [StyleViolation] {
        // Unused declarations are:
        // 1. all declarations
        // 2. minus all references
        // 3. minus what the language uses on its own
        declaredUSRs
            .filter { !usage.contains($0) }
            .map(\.nameOffset)
            .sorted()
            .map {
                StyleViolation(ruleDescription: Self.description,
                               severity: configuration.severityConfiguration.severity,
                               location: Location(file: file, byteOffset: $0))
            }
    }
}

// MARK: - File Extensions

private extension SwiftLintFile {
    func referencedUSRs(index: SourceKittenDictionary, editorOpen: SourceKittenDictionary) -> Set<String> {
        Set(index.traverseEntitiesDepthFirst { parent, entity -> String? in
            if entity.isWitnessDeclaredElsewhere {
                return entity.usr
            }

            if let usr = entity.usr,
               let kind = entity.kind,
               kind.starts(with: "source.lang.swift.ref"),
               !parent.extends(reference: entity),
               let line = entity.line,
               let column = entity.column,
               let nameOffset = stringView.byteOffset(forLine: line, bytePosition: column),
               // A header needs every type alias in it to be written, so it uses the alias.
               kind == "source.lang.swift.ref.typealias"
                || parent.isExtensionWrittenWithoutItsType(namedWith: entity)
                || editorOpen.propertyAtOffset(nameOffset, property: \.kind) != "source.lang.swift.decl.extension" {
                return usr
            }

            return nil
        })
    }

    func declaredUSRs(index: SourceKittenDictionary,
                      editorOpen: SourceKittenDictionary,
                      compilerArguments: [String],
                      configuration: UnusedDeclarationConfiguration)
        -> (declared: Set<UnusedDeclarationRule.DeclaredUSR>, typeFacts: UnusedDeclarationUsage.TypeFacts) {
        var collector = UnusedDeclarationUsage.TypeFactsCollector(
            conformancesMissingFromIndex: conformancesMissingFromIndex(index),
            overridden: { [self] in overriddenUSRs(of: $0, compilerArguments: compilerArguments) },
            isInitializedConstant: initializedConstantFinder(),
            moduleName: { [self] in cursorInfo(atPositionOf: $0, compilerArguments: compilerArguments)?.moduleName },
            moduleNameOfType: { [self] in moduleName(ofTypeWithUSR: $0, compilerArguments: compilerArguments) }
        )
        let declared = index.traverseEntitiesDepthFirst { parent, indexEntity in
            let member = collector.visit(indexEntity, in: parent)
            var declared = self.declaredUSR(indexEntity: indexEntity,
                                            editorOpen: editorOpen,
                                            compilerArguments: compilerArguments,
                                            configuration: configuration)
            declared?.member = member
            return declared
        }
        return (Set(declared), collector.typeFacts)
    }

    func declaredUSR(indexEntity: SourceKittenDictionary,
                     editorOpen: SourceKittenDictionary,
                     compilerArguments: [String],
                     configuration: UnusedDeclarationConfiguration) -> UnusedDeclarationRule.DeclaredUSR? {
        // Skip initializers, deinit, enum cases and subscripts since we can't reliably detect if they're used.
        let declarationKindsToSkip: Set<SwiftDeclarationKind> = [
            .enumelement,
            .extensionProtocol,
            .extension,
            .extensionEnum,
            .extensionClass,
            .extensionStruct,
            .functionConstructor,
            .functionDestructor,
            .functionSubscript,
            .genericTypeParam,
        ]

        guard let stringKind = indexEntity.kind,
              stringKind.starts(with: "source.lang.swift.decl."),
              !stringKind.contains(".accessor."),
              let usr = indexEntity.usr,
              let line = indexEntity.line,
              let column = indexEntity.column,
              let kind = indexEntity.declarationKind,
              !declarationKindsToSkip.contains(kind)
        else {
            return nil
        }

        if shouldIgnoreEntity(indexEntity, relatedUSRsToSkip: configuration.relatedUSRsToSkip) {
            return nil
        }

        guard let nameOffset = stringView.byteOffset(forLine: line, bytePosition: column) else {
            return nil
        }

        if !configuration.includePublicAndOpen,
           [.public, .open].contains(editorOpen.propertyAtOffset(nameOffset, property: \.accessibility)) {
            return nil
        }

        // Skip CodingKeys as they are used for Codable generation
        if kind == .enum,
           indexEntity.name == "CodingKeys",
           case let allRelatedUSRs = indexEntity.traverseEntitiesDepthFirst(traverseBlock: { $1.usr }),
           allRelatedUSRs.contains("s:s9CodingKeyP") {
            return nil
        }

        // Skip `static var allTests` members since those are used for Linux test discovery.
        if kind == .varStatic, indexEntity.name == "allTests" {
            let allTestCandidates = indexEntity.traverseEntitiesDepthFirst { _, subEntity -> Bool in
                subEntity.value["key.is_test_candidate"] as? Bool == true
            }

            if allTestCandidates.contains(true) {
                return nil
            }
        }

        let cursorInfo = cursorInfo(at: nameOffset, compilerArguments: compilerArguments)

        if let declaration = cursorInfo?.value["key.fully_annotated_decl"] as? String,
           UnusedDeclarationUsage.isMarkedForObjectiveC(fullyAnnotatedDeclaration: declaration) {
            return nil
        }

        // This works for both subclass overrides & protocol extension overrides.
        if cursorInfo?.value["key.overrides"] != nil {
            return nil
        }

        // Sometimes default protocol implementations don't have `key.overrides` set but they do have
        // `key.related_decls`. The apparent exception is that related declarations also includes declarations
        // with "related names", which appears to be similarly named declarations (i.e. overloads) that are
        // programmatically unrelated to the current cursor-info declaration. Those similarly named declarations
        // aren't in `key.related` so confirm that that one is also populated.
        if cursorInfo?.value["key.related_decls"] != nil, indexEntity.value["key.related"] != nil {
            return nil
        }

        return .init(usr: usr, nameOffset: nameOffset)
    }

    /// USRs of what SourceKit says the declaration overrides, or satisfies as a requirement of a protocol.
    private func overriddenUSRs(of indexEntity: SourceKittenDictionary, compilerArguments: [String]) -> [String] {
        let overrides = cursorInfo(atPositionOf: indexEntity, compilerArguments: compilerArguments)?
            .value["key.overrides"] as? [[String: any SourceKitRepresentable]]
        return overrides?.compactMap { $0["key.usr"] as? String } ?? []
    }

    /// What SourceKit tells about the declaration at the entity's position, or about the one referred to there.
    private func cursorInfo(atPositionOf indexEntity: SourceKittenDictionary, compilerArguments: [String])
        -> SourceKittenDictionary? {
        guard let line = indexEntity.line, let column = indexEntity.column,
              let offset = stringView.byteOffset(forLine: line, bytePosition: column) else {
            return nil
        }
        return cursorInfo(at: offset, compilerArguments: compilerArguments)
    }

    func cursorInfo(at byteOffset: ByteCount, compilerArguments: [String]) -> SourceKittenDictionary? {
        let request = Request.cursorInfoWithoutSymbolGraph(
            file: path!.filepath, offset: byteOffset, arguments: compilerArguments
        )
        return (try? request.sendIfNotDisabled()).map(SourceKittenDictionary.init)
    }

    private func shouldIgnoreEntity(_ indexEntity: SourceKittenDictionary, relatedUSRsToSkip: Set<String>) -> Bool {
        let declarationAttributesToSkip: Set<SwiftDeclarationAttributeKind> = [
            .ibsegueaction,
            .ibaction,
            .main,
            .nsApplicationMain,
            .override,
            .uiApplicationMain,
        ]

        if indexEntity.shouldSkipIndexEntityToWorkAroundSR11985() ||
            indexEntity.shouldSkipRelated(relatedUSRsToSkip: relatedUSRsToSkip) ||
            indexEntity.enclosedSwiftAttributes.contains(where: declarationAttributesToSkip.contains) ||
            indexEntity.isImplicit ||
            indexEntity.value["key.is_test_candidate"] as? Bool == true ||
            indexEntity.shouldSkipResultBuilder() {
            return true
        }

        if !Set(indexEntity.enclosedSwiftAttributes).isDisjoint(with: [.ibinspectable, .iboutlet]) {
            if let getter = indexEntity.entities.first(where: { $0.declarationKind == .functionAccessorGetter }),
               !getter.isImplicit {
                return true
            }

            if let setter = indexEntity.entities.first(where: { $0.declarationKind == .functionAccessorSetter }),
               !setter.isImplicit {
                return true
            }

            if !Set(indexEntity.entities.compactMap(\.declarationKind))
                .isDisjoint(with: [.functionAccessorWillset, .functionAccessorDidset]) {
                return true
            }
        }

        return false
    }
}

private extension SourceKittenDictionary {
    var usr: String? {
        value["key.usr"] as? String
    }

    var isImplicit: Bool {
        value["key.is_implicit"] as? Bool == true
    }

    /// Where a type conforms to a protocol and a requirement's witness is declared elsewhere (in another
    /// extension, another file, a superclass or a protocol extension), the index lists the witness under the
    /// conforming declaration: as an implicit declaration with the witness's USR that is related to the
    /// requirement. It is the only trace of that use in the index. A witness inside the conforming declaration
    /// is related to the requirement itself and is not reported for that reason.
    var isWitnessDeclaredElsewhere: Bool {
        isImplicit
            && kind?.starts(with: "source.lang.swift.decl.") == true
            && (value["key.related"] as? [any SourceKitRepresentable])?.isEmpty == false
    }

    func propertyAtOffset<T>(_ offset: ByteCount, property: KeyPath<Self, T?>) -> T? {
        if let nameOffset,
           nameOffset == offset,
           let field = self[keyPath: property] {
            return field
        }
        for child in substructure {
            if let acl = child.propertyAtOffset(offset, property: property) {
                return acl
            }
        }
        return nil
    }

    func shouldSkipRelated(relatedUSRsToSkip: Set<String>) -> Bool {
        (value["key.related"] as? [[String: any SourceKitRepresentable]])?
            .compactMap { SourceKittenDictionary($0).usr }
            .contains(where: relatedUSRsToSkip.contains) == true
    }

    func shouldSkipIndexEntityToWorkAroundSR11985() -> Bool {
        guard enclosedSwiftAttributes.contains(.objcName), let name else {
            return false
        }

        // Not a comprehensive list. Add as needed.
        let functionsToSkipForSR11985 = [
            "navigationBar(_:didPop:)",
            "scrollViewDidEndDecelerating(_:)",
            "scrollViewDidEndDragging(_:willDecelerate:)",
            "scrollViewDidScroll(_:)",
            "scrollViewDidScrollToTop(_:)",
            "scrollViewWillBeginDragging(_:)",
            "scrollViewWillEndDragging(_:withVelocity:targetContentOffset:)",
            "tableView(_:canEditRowAt:)",
            "tableView(_:commit:forRowAt:)",
            "tableView(_:editingStyleForRowAt:)",
            "tableView(_:willDisplayHeaderView:forSection:)",
            "tableView(_:willSelectRowAt:)",
        ]

        return functionsToSkipForSR11985.contains(name)
    }

    func shouldSkipResultBuilder() -> Bool {
        guard let name, declarationKind == .functionMethodStatic else {
            return false
        }

        // https://github.com/apple/swift-evolution/blob/main/proposals/0289-result-builders.md#result-building-methods
        let resultBuilderStaticMethods = [
            "buildBlock(_:)",
            "buildExpression(_:)",
            "buildOptional(_:)",
            "buildEither(first:)",
            "buildEither(second:)",
            "buildArray(_:)",
            "buildLimitedAvailability(_:)",
            "buildFinalResult(_:)",
            // https://github.com/apple/swift-evolution/blob/main/proposals/0348-buildpartialblock.md
            "buildPartialBlock(first:)",
            "buildPartialBlock(accumulated:next:)",
        ]

        return resultBuilderStaticMethods.contains(name)
    }
}
