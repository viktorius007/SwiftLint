extension UnusedDeclarationUsage {
    /// Whether a declaration carries `@objc`, with or without a name. Objective-C can then use it by name, which
    /// the index does not show.
    ///
    /// - parameter fullyAnnotatedDeclaration: The declaration as SourceKit's cursor info annotates it in full.
    static func isMarkedForObjectiveC(fullyAnnotatedDeclaration: String) -> Bool {
        // SourceKit puts the name of every attribute between two tags of its own. What the source spells, like a
        // default argument, has its `<` escaped, and a USR sits inside a tag. So neither can hold this text.
        fullyAnnotatedDeclaration.contains("<syntaxtype.attribute.name>@objc</syntaxtype.attribute.name>")
    }
}
