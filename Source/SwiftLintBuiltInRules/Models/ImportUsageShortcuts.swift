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
///   compiled.
/// - An argument label of a call refers to the called function, which the token of its name refers to as well.
/// - The cursor info at a position is determined by the declarations that SourceKit's index lists there. So two
///   positions with the same declarations give the same answer.
struct ImportUsageShortcuts {
    /// What the cursor info at a position says, as far as the rule needs it.
    struct SymbolUsage {
        /// The modules of the symbols at the position.
        let modules: Set<String>
        /// Whether one of the symbols is a function, an initializer or an enum case. The argument labels of a call
        /// refer to that same symbol.
        let isCallable: Bool

        init(modules: Set<String>, kinds: [String]) {
            self.modules = modules
            isCallable = kinds.contains {
                $0.hasPrefix("source.lang.swift.ref.function.") || $0 == "source.lang.swift.ref.enumelement"
            }
        }
    }

    /// The usage at a position, by the declarations at that position. Shared by all files, because the module of
    /// a Swift declaration does not depend on the file using it.
    private final class SharedUsages: @unchecked Sendable {
        private let lock = NSLock()
        private var usagesByUSRs = [[String]: SymbolUsage]()

        subscript(usrs: [String]) -> SymbolUsage? {
            get { lock.withLock { usagesByUSRs[usrs] } }
            set { lock.withLock { usagesByUSRs[usrs] = newValue } }
        }
    }

    private static let usagesOfSwiftDeclarations = SharedUsages()

    /// The module being compiled.
    private var currentModule: String?
    /// The positions of the tokens that belong to the module being compiled.
    private var offsetsInCurrentModule = Set<ByteCount>()
    /// The position of the name of the called function, for the position of each argument label of a call.
    private var calleeOffsetsByLabelOffset = [ByteCount: ByteCount]()
    /// The USRs of all declarations that SourceKit's index lists at a position, declared or referenced, in a
    /// stable order.
    private var usrsByOffset = [ByteCount: [String]]()
    /// The usage at a position, by the declarations at that position, where it only holds within this file.
    private var usagesInThisFile = [[String]: SymbolUsage]()

    /// Creates an instance that knows nothing, so that every token needs a request.
    init() { /* Nothing is known. */ }

    /// Creates an instance for one file.
    ///
    /// - parameter file:              The file.
    /// - parameter compilerArguments: The compiler arguments needed to compile the file.
    /// - parameter currentModule:     The module being compiled, if known.
    init(file: SwiftLintFile, compilerArguments: [String], currentModule: String?) {
        self.currentModule = currentModule
        let collector = TokenCollector(viewMode: .sourceAccurate)
        collector.walk(file.syntaxTree)
        calleeOffsetsByLabelOffset = collector.calleeOffsetsByLabelOffset
        if currentModule != nil {
            offsetsInCurrentModule = collector.declarationNameOffsets
                .union(file.localVariableReferenceOffsets(compilerArguments: compilerArguments))
        }
        usrsByOffset = file.indexedUSRsByOffset(compilerArguments: compilerArguments)
    }

    /// Returns the modules that the token at a position adds to the modules used by the file, if that is known
    /// without a request.
    ///
    /// - parameter offset: The position of the token.
    ///
    /// - returns: The modules, or `nil` if a cursor info request is needed.
    func knownModules(at offset: ByteCount) -> Set<String>? {
        if let currentModule, offsetsInCurrentModule.contains(offset) {
            return [currentModule]
        }
        if let calleeOffset = calleeOffsetsByLabelOffset[offset], usage(at: calleeOffset)?.isCallable == true {
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
        guard let usrs = usrsByOffset[offset] else {
            return
        }
        // Only a Swift USR names the module of its declaration. A C declaration can be declared in several
        // modules, and which of them a file sees depends on its imports.
        if usrs.allSatisfy({ $0.hasPrefix("s:") }) {
            Self.usagesOfSwiftDeclarations[usrs] = usage
        } else {
            usagesInThisFile[usrs] = usage
        }
    }

    private func usage(at offset: ByteCount) -> SymbolUsage? {
        usrsByOffset[offset].flatMap { usagesInThisFile[$0] ?? Self.usagesOfSwiftDeclarations[$0] }
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

    func indexedUSRsByOffset(compilerArguments: [String]) -> [ByteCount: [String]] {
        guard let index = index(compilerArguments: compilerArguments) else {
            return [:]
        }
        var usrsByOffset = [ByteCount: Set<String>]()
        _ = index.traverseEntitiesDepthFirst { _, entity -> Void? in
            if let usr = entity.value["key.usr"] as? String,
               let line = entity.line,
               let column = entity.column,
               let offset = stringView.byteOffset(forLine: line, bytePosition: column) {
                usrsByOffset[offset, default: []].insert(usr)
            }
            return nil
        }
        return usrsByOffset.mapValues { $0.sorted() }
    }
}

/// Collects the positions of the tokens that name a declaration, and of argument labels with their callee.
private final class TokenCollector: SyntaxVisitor {
    private(set) var declarationNameOffsets = Set<ByteCount>()
    private(set) var calleeOffsetsByLabelOffset = [ByteCount: ByteCount]()

    override func visitPost(_ node: LabeledExprSyntax) {
        guard let label = offset(ofIdentifier: node.label),
              let call = node.parent?.parent?.as(FunctionCallExprSyntax.self),
              let callee = offset(ofIdentifier: call.calledExpression.calleeName) else {
            return
        }
        calleeOffsetsByLabelOffset[label] = callee
    }

    override func visitPost(_ node: IdentifierPatternSyntax) {
        // The shorthand `if let value` declares a variable and refers to another one of the same name, which can
        // come from any module.
        if let binding = node.parent?.as(OptionalBindingConditionSyntax.self), binding.initializer == nil {
            return
        }
        collect(node.identifier)
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
