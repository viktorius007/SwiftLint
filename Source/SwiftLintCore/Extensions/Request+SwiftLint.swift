import Foundation
import SourceKittenFramework

/// Whether the environment asks to disable SourceKit. Read once, because building the environment dictionary is
/// expensive and the value is queried for every rule and file.
private let isSourceKitDisabledByEnvironment = ProcessInfo.processInfo.environment["SWIFTLINT_DISABLE_SOURCEKIT"] != nil

package enum SourceKitRequestObserver {
    /// Receives every request that the current task sends to SourceKit, right before it is sent.
    ///
    /// Tests set this to check which requests a piece of code makes.
    @TaskLocal package static var current: (@Sendable (Request) -> Void)?
}

public extension Request {
    nonisolated(unsafe) static var disableSourceKitOverride = false

    static var disableSourceKit: Bool {
        #if SWIFTLINT_DISABLE_SOURCEKIT
        // Compile-time
        true
        #else
        // Runtime
        isSourceKitDisabledByEnvironment || disableSourceKitOverride
        #endif
    }

    func sendIfNotDisabled() throws -> [String: any SourceKitRepresentable] {
        // Skip safety checks if explicitly allowed (e.g., for testing or specific operations)
        if !CurrentRule.allowSourceKitRequestWithoutRule {
            // Check if we have a rule context
            if let ruleID = CurrentRule.identifier {
                // Skip registry check for mock test rules
                if ruleID != "mock_test_rule_for_swiftlint_tests" {
                    // Ensure the rule exists in the registry
                    guard let ruleType = RuleRegistry.shared.rule(forID: ruleID) else {
                        queuedFatalError("""
                            Rule '\(ruleID)' not found in RuleRegistry. This indicates a configuration or wiring issue.
                            """)
                    }

                    // Check if the current rule is a SourceKitFreeRule
                    // Skip check for ConditionallySourceKitFree rules since we can't determine
                    // at the type level if they're effectively SourceKit-free
                    if ruleType.isSourceKitFree, !ruleType.isConditionallySourceKitFree {
                        queuedFatalError("""
                            '\(ruleID)' is a SourceKitFreeRule and should not be making requests to SourceKit.
                            """)
                    }
                }
            } else {
                // No rule context and not explicitly allowed
                queuedFatalError("""
                    SourceKit request made outside of rule execution context without explicit permission.
                    Use CurrentRule.$allowSourceKitRequestWithoutRule.withValue(true) { ... } for allowed exceptions.
                    """)
            }
        }

        guard !Self.disableSourceKit else {
            queuedFatalError("SourceKit is disabled by configuration.")
        }
        SourceKitRequestObserver.current?(self)
        return try send()
    }

    /// Makes SourceKit drop the type-checked syntax tree it caches for a file.
    ///
    /// SourceKit keeps one such tree per file and set of compiler arguments, and each tree holds the whole module.
    /// It only removes a tree when an editor document with the same file and arguments is closed. So this opens
    /// such a document, without asking for any syntax information, and closes it again.
    ///
    /// - parameter file:      The path of the file as passed to the requests that built the tree.
    /// - parameter arguments: The compiler arguments as passed to the requests that built the tree.
    static func releaseCachedSyntaxTree(file: String, arguments: [String]) {
        guard !disableSourceKit, arguments.isNotEmpty else {
            return
        }
        let open: SourceKitObject = [
            "key.request": UID("source.request.editor.open"),
            "key.name": file,
            "key.sourcefile": file,
            "key.compilerargs": arguments,
            "key.syntactic_only": 1,
            "key.enablesyntaxmap": 0,
            "key.enablesubstructure": 0,
            "key.enablediagnostics": 0,
        ]
        let close: SourceKitObject = [
            "key.request": UID("source.request.editor.close"),
            "key.name": file,
        ]
        CurrentRule.$allowSourceKitRequestWithoutRule.withValue(true) {
            for request in [open, close] {
                _ = try? Self.customRequest(request: request).sendIfNotDisabled()
            }
        }
    }

    static func cursorInfoWithoutSymbolGraph(file: String, offset: ByteCount, arguments: [String]) -> Request {
        .customRequest(request: [
            "key.request": UID("source.request.cursorinfo"),
            "key.name": file,
            "key.sourcefile": file,
            "key.offset": Int64(offset.value),
            "key.compilerargs": arguments,
            "key.cancel_on_subsequent_request": 0,
            "key.retrieve_symbol_graph": 0,
        ])
    }
}
