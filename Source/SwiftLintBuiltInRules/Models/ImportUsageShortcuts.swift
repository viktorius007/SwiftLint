import Foundation
import SourceKittenFramework
import SwiftLintCore
import SwiftSyntax

/// Knowledge about the tokens of a file that saves the `unused_import` rule cursor info requests.
///
/// The rule needs the module of the symbol at every token. A cursor info request answers that for one token, and
/// each request makes SourceKit process the compiler arguments of the whole module again. Three facts, each known
/// for a whole file at once, make most of these requests unnecessary:
///
/// - A token that names a declaration of the file, or that refers to a local variable, belongs to the module being
///   compiled. Once one such token of the file got a request, the others add nothing new.
/// - An argument label of a call to a function refers to that function, which the token of its name refers to as
///   well.
/// - The cursor info at a position is determined by the declarations that SourceKit's index lists there. So two
///   positions with the same declarations give the same answer.
///
/// Known limit: a module built with `-module-abi-name` set to the name of another module gives its declarations
/// the USRs that the other module would give to declarations of the same name. If a file uses both, the second
/// one gets the answer of the first.
struct ImportUsageShortcuts {
    /// What the cursor info at a position says, as far as the rule needs it.
    struct SymbolUsage {
        /// The modules of the symbols at the position.
        let modules: Set<String>
        /// Whether one of the symbols is a function or an initializer. The argument labels of a call refer to that
        /// same symbol. An enum case does not count: a call on a case without values calls the value itself.
        let isFunction: Bool
        /// Whether the position holds a single declaration and nothing else.
        let isSingleDeclaration: Bool

        init(modules: Set<String>, kinds: [String]) {
            self.modules = modules
            isFunction = kinds.contains { $0.hasPrefix("source.lang.swift.ref.function.") }
            isSingleDeclaration = kinds.count == 1 && kinds[0].hasPrefix("source.lang.swift.decl.")
        }
    }

    /// What was learned about one module, shared by all of its files.
    private final class ModuleKnowledge: @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var knowledgeByCompilerArguments = [[String]: ModuleKnowledge]()

        private let lock = NSLock()
        private var usagesByUSRs = [[String]: SymbolUsage]()

        static func ofModule(compiledWith compilerArguments: [String]) -> ModuleKnowledge {
            lock.withLock {
                if let knowledge = knowledgeByCompilerArguments[compilerArguments] {
                    return knowledge
                }
                let knowledge = ModuleKnowledge()
                knowledgeByCompilerArguments[compilerArguments] = knowledge
                return knowledge
            }
        }

        subscript(usrs: [String]) -> SymbolUsage? {
            get { lock.withLock { usagesByUSRs[usrs] } }
            set { lock.withLock { usagesByUSRs[usrs] = newValue } }
        }
    }

    private var module: ModuleKnowledge?
    /// The positions of the tokens that belong to the module being compiled.
    private var offsetsInOwnModule = Set<ByteCount>()
    /// Whether a request for one of these tokens returned a declaration, and with it the module being compiled.
    /// A file can consist of code that is compiled out, where no such token has a symbol.
    private var hasSeenOwnDeclaration = false
    /// The position of the name of the called function, for the position of each argument label of a call.
    private var calleeOffsetsByLabelOffset = [ByteCount: ByteCount]()
    /// The USRs of all declarations that SourceKit's index lists at a position, declared or referenced, in a
    /// stable order.
    private var usrsByOffset = [ByteCount: [String]]()
    /// The positions whose cursor info can hold a symbol that the index does not list there, so that the listed
    /// declarations do not determine it.
    private var offsetsWithUnlistedSymbols = Set<ByteCount>()
    /// The usage at a position, by the declarations at that position, where it only holds within this file.
    private var usagesInThisFile = [[String]: SymbolUsage]()

    /// Creates an instance that knows nothing, so that every token needs a request.
    init() { /* Nothing is known. */ }

    /// Creates an instance for one file.
    ///
    /// - parameter file:              The file.
    /// - parameter compilerArguments: The compiler arguments needed to compile the file.
    init(file: SwiftLintFile, compilerArguments: [String]) {
        module = .ofModule(compiledWith: compilerArguments)
        let collector = TokenCollector(viewMode: .sourceAccurate)
        collector.walk(file.syntaxTree)
        calleeOffsetsByLabelOffset = collector.calleeOffsetsByLabelOffset
        offsetsInOwnModule = collector.declarationNameOffsets
            .union(file.localVariableReferenceOffsets(compilerArguments: compilerArguments))
            .subtracting(collector.offsetsReferringToShadowedDeclarations)
        let index = file.indexedDeclarations(compilerArguments: compilerArguments)
        usrsByOffset = index.usrsByOffset
        // The index leaves out hidden declarations of system modules. For a call that means: if the index lists no
        // function at the callee, the called function is not among the listed declarations.
        offsetsWithUnlistedSymbols = collector.calleeOffsets.subtracting(index.offsetsOfFunctions)
            .union(collector.offsetsReferringToShadowedDeclarations)
    }

    /// Returns the modules that the token at a position adds to the modules used by the file, if that is known
    /// without a request.
    ///
    /// - parameter offset: The position of the token.
    ///
    /// - returns: The modules, or `nil` if a cursor info request is needed.
    func knownModules(at offset: ByteCount) -> Set<String>? {
        if offsetsInOwnModule.contains(offset) {
            return hasSeenOwnDeclaration ? [] : nil
        }
        if let calleeOffset = calleeOffsetsByLabelOffset[offset], usage(at: calleeOffset)?.isFunction == true {
            // The token of the callee comes first and has added the modules already.
            return []
        }
        return usage(at: offset)?.modules
    }

    /// Records what a cursor info request said about the token at a position.
    ///
    /// - parameter usage:  The result of the request.
    /// - parameter offset: The position of the token.
    mutating func remember(_ usage: SymbolUsage, at offset: ByteCount) {
        if offsetsInOwnModule.contains(offset) {
            if usage.isSingleDeclaration, usage.modules.isNotEmpty {
                hasSeenOwnDeclaration = true
            }
            return
        }
        guard let usrs = usrsByOffset[offset], !offsetsWithUnlistedSymbols.contains(offset) else {
            return
        }
        let swiftUSRs = usrs.filter { $0.hasPrefix("s:") }
        // A module built with `-module-abi-name` gives its declarations USRs that do not name it, and that a
        // declaration of another module can have as well. Such a result is not reused at all.
        guard swiftUSRs.allSatisfy({ usr in usage.modules.contains { MangledName.usr(usr, names: $0) } }) else {
            return
        }
        // A C declaration can be declared in several modules, and which of them a file sees depends on its
        // imports. So a result for one is reused within the file only.
        guard swiftUSRs.count == usrs.count else {
            usagesInThisFile[usrs] = usage
            return
        }
        // A module that no listed declaration accounts for comes from a symbol the index does not list.
        if usage.modules.allSatisfy({ name in usrs.contains { MangledName.usr($0, names: name) } }) {
            module?[usrs] = usage
        }
    }

    private func usage(at offset: ByteCount) -> SymbolUsage? {
        if offsetsWithUnlistedSymbols.contains(offset) {
            return nil
        }
        return usrsByOffset[offset].flatMap { usagesInThisFile[$0] ?? module?[$0] }
    }
}

private extension SwiftLintFile {
    /// Returns the positions of all references to local variables, from one request for the whole file.
    func localVariableReferenceOffsets(compilerArguments: [String]) -> Set<ByteCount> {
        guard let path = path?.filepath else {
            return []
        }
        let request = Request.customRequest(request: [
            "key.request": UID("source.request.semantic_tokens"),
            "key.name": path,
            "key.sourcefile": path,
            "key.compilerargs": compilerArguments,
        ])
        guard let response = try? request.sendIfNotDisabled(),
              let tokens = response["key.semantic_tokens"] as? [any SourceKitRepresentable] else {
            return []
        }
        return Set(tokens.lazy.compactMap { $0 as? [String: any SourceKitRepresentable] }.compactMap { token in
            token["key.kind"] as? String == "source.lang.swift.ref.var.local"
                ? (token["key.offset"] as? Int64).map { ByteCount($0) }
                : nil
        })
    }

    /// Returns the USRs that SourceKit's index lists at the position of a token, for every position where the
    /// text of the file matches the name of one of the listed declarations, and the positions where it lists a
    /// function.
    ///
    /// The index gives lines and columns. The name check guards against a position computed from them that is not
    /// the one SourceKit meant.
    func indexedDeclarations(
        compilerArguments: [String]
    ) -> (usrsByOffset: [ByteCount: [String]], offsetsOfFunctions: Set<ByteCount>) {
        guard let index = index(compilerArguments: compilerArguments) else {
            return ([:], [])
        }
        let bytes = Array(contents.utf8)
        let converter = locationConverter
        var usrsByOffset = [ByteCount: Set<String>]()
        var offsetsWithMatchingName = Set<ByteCount>()
        var offsetsOfFunctions = Set<ByteCount>()
        _ = index.traverseEntitiesDepthFirst { _, entity -> Void? in
            guard let usr = entity.value["key.usr"] as? String,
                  let line = entity.line,
                  let column = entity.column else {
                return nil
            }
            // The converter counts lines like the compiler does, also for files with carriage returns.
            let offset = converter.position(ofLine: Int(line), column: Int(column)).utf8Offset
            usrsByOffset[ByteCount(offset), default: []].insert(usr)
            if let name = entity.name?.prefix(while: { $0 != "(" }).utf8, name.isNotEmpty,
               bytes.dropFirst(offset).starts(with: name) {
                offsetsWithMatchingName.insert(ByteCount(offset))
            }
            if entity.kind?.contains(".function.") == true {
                offsetsOfFunctions.insert(ByteCount(offset))
            }
            return nil
        }
        return (
            usrsByOffset.filter { offsetsWithMatchingName.contains($0.key) }.mapValues { $0.sorted() },
            offsetsOfFunctions
        )
    }
}

/// Collects the positions of the tokens that name a declaration, and of argument labels with their callee.
private final class TokenCollector: SyntaxVisitor {
    private(set) var declarationNameOffsets = Set<ByteCount>()
    private(set) var calleeOffsetsByLabelOffset = [ByteCount: ByteCount]()
    /// The positions of the names in the called expression of every call.
    private(set) var calleeOffsets = Set<ByteCount>()
    /// The positions of names that declare a variable and at the same time refer to another one of the same name,
    /// which can come from any module: the shorthand `if let value` and the items of a closure's capture list.
    private(set) var offsetsReferringToShadowedDeclarations = Set<ByteCount>()

    override func visitPost(_ node: FunctionCallExprSyntax) {
        if let callee = offset(ofIdentifier: node.calledExpression.calleeName) {
            calleeOffsets.insert(callee)
        } else {
            // A callee like `[Element]` or `(Element)`. Any of its names can be the called type.
            for token in node.calledExpression.tokens(viewMode: .sourceAccurate) {
                if let callee = offset(ofIdentifier: token) {
                    calleeOffsets.insert(callee)
                }
            }
        }
    }

    override func visitPost(_ node: LabeledExprSyntax) {
        guard let label = offset(ofIdentifier: node.label),
              let call = node.parent?.parent?.as(FunctionCallExprSyntax.self),
              let callee = offset(ofIdentifier: call.calledExpression.calleeName) else {
            return
        }
        calleeOffsetsByLabelOffset[label] = callee
    }

    override func visitPost(_ node: IdentifierPatternSyntax) {
        if let binding = node.parent?.as(OptionalBindingConditionSyntax.self), binding.initializer == nil {
            if let offset = offset(ofIdentifier: node.identifier) {
                offsetsReferringToShadowedDeclarations.insert(offset)
            }
            return
        }
        collect(node.identifier)
    }

    override func visitPost(_ node: ClosureCaptureSyntax) {
        if let offset = offset(ofIdentifier: node.name) {
            offsetsReferringToShadowedDeclarations.insert(offset)
        }
    }

    override func visitPost(_ node: FunctionParameterSyntax) {
        collect(node.firstName)
        collect(node.secondName)
    }

    override func visitPost(_ node: ClosureParameterSyntax) {
        collect(node.firstName)
        collect(node.secondName)
    }

    override func visitPost(_ node: ClosureShorthandParameterSyntax) {
        collect(node.name)
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        collect(node.name)
    }

    override func visitPost(_ node: StructDeclSyntax) {
        collect(node.name)
    }

    override func visitPost(_ node: ClassDeclSyntax) {
        collect(node.name)
    }

    override func visitPost(_ node: ActorDeclSyntax) {
        collect(node.name)
    }

    override func visitPost(_ node: EnumDeclSyntax) {
        collect(node.name)
    }

    override func visitPost(_ node: ProtocolDeclSyntax) {
        collect(node.name)
    }

    override func visitPost(_ node: TypeAliasDeclSyntax) {
        collect(node.name)
    }

    override func visitPost(_ node: AssociatedTypeDeclSyntax) {
        collect(node.name)
    }

    override func visitPost(_ node: EnumCaseElementSyntax) {
        collect(node.name)
    }

    override func visitPost(_ node: GenericParameterSyntax) {
        collect(node.name)
    }

    private func collect(_ token: TokenSyntax?) {
        if let offset = offset(ofIdentifier: token) {
            declarationNameOffsets.insert(offset)
        }
    }

    private func offset(ofIdentifier token: TokenSyntax?) -> ByteCount? {
        if let token, case .identifier = token.tokenKind {
            return ByteCount(token.positionAfterSkippingLeadingTrivia)
        }
        return nil
    }
}

private extension ExprSyntax {
    /// The token that names the function if this expression is the callee of a call.
    var calleeName: TokenSyntax? {
        if let reference = `as`(DeclReferenceExprSyntax.self) {
            return reference.baseName
        }
        if let memberAccess = `as`(MemberAccessExprSyntax.self) {
            return memberAccess.declName.baseName
        }
        return `as`(GenericSpecializationExprSyntax.self)?.expression.calleeName
    }
}
