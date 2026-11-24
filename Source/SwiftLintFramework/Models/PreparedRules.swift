import SwiftLintCore

/// A rule together with the properties that are the same for every file linted with one configuration.
///
/// Computing them once per configuration instead of once per rule and file avoids repeated dynamic casts,
/// version comparisons and set constructions.
struct PreparedRule {
    /// The rule itself.
    let rule: any Rule
    /// The rule's identifier.
    let identifier: String
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
    /// The rules that collect information from all files before linting.
    let collectingRules: [any Rule]
    /// The `superfluous_disable_command` rule if it is enabled.
    let superfluousDisableCommandRule: SuperfluousDisableCommandRule?

    init(allRules: [any Rule], mode: LintOrAnalyzeMode) {
        let rules = allRules.filter { rule in
            switch mode {
            case .lint: !type(of: rule).isAnalyzer
            case .analyze: type(of: rule).isAnalyzer || rule is SuperfluousDisableCommandRule
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
                identifier: description.identifier,
                supportsCurrentSwiftVersion: SwiftVersion.current >= description.minSwiftVersion,
                requiresSourceKit: rule.requiresSourceKit,
                disableCommandIdentifiers: Set(identifiers.map { RuleIdentifier($0) })
            )
        }
        self.collectingRules = rules.filter { type(of: $0).isCollecting }
        self.superfluousDisableCommandRule = superfluousDisableCommandRule
    }
}
