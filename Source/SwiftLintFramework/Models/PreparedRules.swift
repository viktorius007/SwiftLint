import SwiftLintCore

/// A rule together with the properties that are the same for every file linted with one configuration.
///
/// Computing them once per configuration instead of once per rule and file avoids repeated dynamic casts,
/// version comparisons and set constructions.
struct PreparedRule {
    /// The rule itself.
    let rule: any Rule
    /// Whether the rule supports the Swift version in use.
    let supportsCurrentSwiftVersion: Bool
    /// Whether the rule needs SourceKit in its current configuration.
    let requiresSourceKit: Bool
    /// All identifiers a `swiftlint:disable` command may use to refer to this rule, including identifiers that
    /// disable all rules or the `superfluous_disable_command` rule.
    let disableCommandIdentifiers: Set<RuleIdentifier>
}

/// The rules of a configuration that run in one mode, prepared for linting many files.
struct PreparedRules {
    /// The rules that run in this mode.
    let rules: [PreparedRule]
    /// Whether at least one of the rules collects information from all files before linting.
    let isCollecting: Bool
    /// The `superfluous_disable_command` rule if it is enabled.
    let superfluousDisableCommandRule: SuperfluousDisableCommandRule?

    init(allRules: [any Rule], mode: LintOrAnalyzeMode) {
        let rules = allRules.filter { rule in
            switch mode {
            case .lint: !(rule is any AnalyzerRule)
            case .analyze: rule is any AnalyzerRule || rule is SuperfluousDisableCommandRule
            }
        }
        let superfluousDisableCommandRule = rules.lazy.compactMap { $0 as? SuperfluousDisableCommandRule }.first
        let commonIdentifiers = (superfluousDisableCommandRule.map { type(of: $0).description.allIdentifiers } ?? [])
            + [RuleIdentifier.all.stringRepresentation]
        self.rules = rules.map { rule in
            let description = type(of: rule).description
            let identifiers = description.allIdentifiers
                + ((rule as? CustomRules)?.customRuleIdentifiers ?? [])
                + commonIdentifiers
            return PreparedRule(
                rule: rule,
                supportsCurrentSwiftVersion: SwiftVersion.current >= description.minSwiftVersion,
                requiresSourceKit: rule.requiresSourceKit,
                disableCommandIdentifiers: Set(identifiers.map { RuleIdentifier($0) })
            )
        }
        self.isCollecting = rules.contains { $0 is any AnyCollectingRule }
        self.superfluousDisableCommandRule = superfluousDisableCommandRule
    }
}
