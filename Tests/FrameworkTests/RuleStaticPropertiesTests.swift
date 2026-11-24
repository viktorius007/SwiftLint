import SwiftLintCore
import TestHelpers
import Testing

@testable import SwiftLintFramework

@Suite(.rulesRegistered)
struct RuleStaticPropertiesTests {
    @Test
    func staticPropertiesMatchProtocolConformances() {
        let ruleTypes = Array(RuleRegistry.shared.list.list.values) + [CustomRules.self]
        #expect(ruleTypes.count > 200)
        for ruleType in ruleTypes {
            let identifier = ruleType.identifier
            #expect(ruleType.isOptIn == (ruleType is any OptInRule.Type), "\(identifier)")
            #expect(ruleType.isAnalyzer == (ruleType is any AnalyzerRule.Type), "\(identifier)")
            #expect(ruleType.isCollecting == (ruleType is any AnyCollectingRule.Type), "\(identifier)")
            #expect(ruleType.isSourceKitFree == (ruleType is any SourceKitFreeRule.Type), "\(identifier)")
            #expect(
                ruleType.isConditionallySourceKitFree == (ruleType is any ConditionallySourceKitFree.Type),
                "\(identifier)"
            )
        }
    }

    @Test
    func cacheDescriptionOfCustomRulesComesFromItsConfiguration() {
        var regexConfiguration = RegexConfiguration<CustomRules>(identifier: "custom")
        regexConfiguration.regex = "pattern"
        var configuration = CustomRulesConfiguration()
        configuration.customRuleConfigurations = [regexConfiguration]
        var customRules = CustomRules()
        customRules.configuration = configuration
        let rule: any Rule = customRules
        #expect(rule.cacheDescription == configuration.cacheDescription)
        #expect(rule.cacheDescription != rule.createConfigurationDescription().oneLiner())
    }
}
