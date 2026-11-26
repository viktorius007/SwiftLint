extension UnusedDeclarationUsage {
    /// A member of a type, as far as its name tells.
    struct Member: Hashable {
        /// USR of the type that declares the member, or that the member's extension extends. Empty for an
        /// operator at file scope.
        let type: String
        let name: Name

        /// Stands for the type of an operator at file scope.
        static let fileScope = ""
        /// Stands for the type of a function at file scope that is no operator.
        static let functions = "()"
        /// Stands for a type that is not known: the one that an extension with a header in parentheses extends,
        /// and the one of a test at file scope.
        static let unknownType = "?"
    }

    struct Name: Hashable {
        /// Base name with argument labels, as the index spells it: `copy(to:)`, `count`.
        let name: String
        let kind: NameKind

        /// The name without argument labels: `copy` for `copy(to:)`.
        var withoutLabels: Self {
            Self(name: String(name.prefix { $0 != "(" }), kind: kind)
        }
    }

    /// What can stand for each other under one name: a type alias satisfies an associated type, a static
    /// method never an instance method.
    enum NameKind {
        case instance
        case `static`
        case type
        /// A function at file scope that is no operator.
        case function
    }
}
