extension UnusedDeclarationUsage {
    /// Whether a declaration carries `@objc`, with or without a name. Objective-C can then use it by name, which
    /// the index does not show.
    ///
    /// - parameter annotatedDeclaration: The declaration as SourceKit's cursor info annotates it. Each type in
    ///                                   it is in a tag with the type's USR.
    static func isMarkedForObjectiveC(annotatedDeclaration: String) -> Bool {
        guard annotatedDeclaration.contains("@objc") else {
            return false
        }
        // The USR of a class of the module that Objective-C sees has `@objc(` in it too. So the attribute is
        // looked for in the text without its tags.
        let text = annotatedDeclaration.replacing(#/<[^>]*>/#, with: "")
        return text.contains("@objc ") || text.contains("@objc(")
    }
}
