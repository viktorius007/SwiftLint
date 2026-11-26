extension UnusedDeclarationUsage {
    /// Which type inherits from which, as all files together tell.
    struct Inheritance {
        /// For each type, protocol or type alias: what it inherits from, conforms to or stands for.
        private let inherited: [String: Set<String>]
        /// For each of these: what inherits from it, conforms to it or stands for it.
        private let heirs: [String: [String]]

        init(_ inherited: [String: Set<String>]) {
            self.inherited = inherited
            heirs = inherited.reduce(into: [:]) { heirs, entry in
                for type in entry.value {
                    heirs[type, default: []].append(entry.key)
                }
            }
        }

        /// The given types with everything they inherit from, directly or not.
        func withInherited(_ types: some Sequence<String>) -> Set<String> {
            Self.closure(of: types) { inherited[$0] ?? [] }
        }

        /// The given type with everything that inherits from it, directly or not.
        func withHeirs(_ type: String) -> Set<String> {
            Self.closure(of: [type]) { heirs[$0] ?? [] }
        }

        private static func closure<Next: Sequence<String>>(of types: some Sequence<String>, next: (String) -> Next)
            -> Set<String> {
            var result = Set<String>()
            var typesToVisit = Array(types)
            while let type = typesToVisit.popLast() {
                if result.insert(type).inserted {
                    typesToVisit.append(contentsOf: next(type))
                }
            }
            return result
        }
    }
}
