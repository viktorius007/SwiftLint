import Dispatch

/// A storage mechanism for aggregating the results of `CollectingRule`s.
public class RuleStorage: CustomStringConvertible {
    private var storage: [ObjectIdentifier: [SwiftLintFile: Any]]
    private var summaries = [ObjectIdentifier: Any]()
    /// How often info was collected for a rule. Tells whether a summary was computed from the current info.
    private var collections = [ObjectIdentifier: Int]()
    private let access = DispatchQueue(label: "io.realm.swiftlint.ruleStorageAccess", attributes: .concurrent)

    public var description: String {
        storage.description
    }

    /// Creates a `RuleStorage` with no initial stored data.
    public init() {
        storage = [:]
    }

    /// Collects file info for a given rule into the storage.s
    ///
    /// - parameter info: The file information to store.
    /// - parameter file: The file for which this information pertains to.
    /// - parameter rule: The SwiftLint rule that generated this info.
    func collect<R: CollectingRule>(info: R.FileInfo, for file: SwiftLintFile, in _: R) {
        let key = ObjectIdentifier(R.self)
        access.sync(flags: .barrier) {
            storage[key, default: [:]][file] = info
            summaries[key] = nil
            collections[key, default: 0] += 1
        }
    }

    /// Retrieves all file information for a given rule that was collected via `collect(...)`.
    ///
    /// - parameter rule: The rule whose collected information should be retrieved.
    ///
    /// - returns: All file information for a given rule that was collected via `collect(...)`.
    func collectedInfo<R: CollectingRule>(for _: R) -> [SwiftLintFile: R.FileInfo]? {
        access.sync {
            storage[ObjectIdentifier(R.self)] as? [SwiftLintFile: R.FileInfo]
        }
    }

    /// Retrieves the information that a rule collected for one file.
    ///
    /// Unlike `collectedInfo(for:)`, this does not convert the information of all files.
    ///
    /// - parameter rule: The rule whose collected information should be retrieved.
    /// - parameter file: The file the information pertains to.
    ///
    /// - returns: The information collected for the file, if any.
    public func collectedInfo<R: CollectingRule>(for _: R, file: SwiftLintFile) -> R.FileInfo? {
        access.sync {
            storage[ObjectIdentifier(R.self)]?[file] as? R.FileInfo
        }
    }

    /// Returns a value that a rule derives from the information it collected for all files.
    ///
    /// The value is computed on first use and kept until more information is collected for the rule. A rule that
    /// needs the same value for every file it validates gets it computed once this way, instead of once per file.
    ///
    /// - parameter rule:    The rule whose collected information the value is derived from.
    /// - parameter compute: Computes the value from the information collected for all files.
    ///
    /// - returns: The derived value.
    public func summary<R: CollectingRule, Summary>(
        for _: R,
        compute: ([SwiftLintFile: R.FileInfo]) -> Summary
    ) -> Summary {
        let key = ObjectIdentifier(R.self)
        let (cached, collection, info) = access.sync {
            (summaries[key], collections[key, default: 0], storage[key])
        }
        if let summary = cached as? Summary {
            return summary
        }
        let summary = compute(info as? [SwiftLintFile: R.FileInfo] ?? [:])
        access.sync(flags: .barrier) {
            // Info collected in the meantime makes this summary outdated. It must not replace a newer one.
            if collections[key, default: 0] == collection {
                summaries[key] = summary
            }
        }
        return summary
    }
}
