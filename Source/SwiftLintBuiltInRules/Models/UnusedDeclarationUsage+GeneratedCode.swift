extension UnusedDeclarationUsage {
    /// Code that the compiler generates for a conformance if no declaration satisfies the requirement, and that
    /// reads or writes the stored properties of the type.
    enum GeneratedCode: CaseIterable {
        /// `init(from:)` of `Decodable`.
        case decoding
        /// `encode(to:)` of `Encodable`.
        case encoding
        /// `==` of `Equatable`.
        case equality
        /// `hash(into:)` of `Hashable`. With a declared `hashValue`, the generated code reads that instead of
        /// the stored properties.
        case hashing

        /// The names of the declarations that can satisfy one of the requirements.
        static let namesOfRequirements: Set = ["init(from:)", "encode(to:)", "==(_:_:)", "hash(into:)", "hashValue"]
        /// The USRs of the requirements of all kinds.
        static let allRequirements = Set(allCases.flatMap(\.requirements))

        /// USR of the protocol whose conformance gets the code.
        var conformance: String {
            switch self {
            case .decoding: UnusedDeclarationUsage.decodable
            case .encoding: UnusedDeclarationUsage.encodable
            case .equality: "s:SQ"
            case .hashing: "s:SH"
            }
        }

        /// USRs of the requirements. A declaration that satisfies one of them takes the place of the code.
        var requirements: [String] {
            switch self {
            case .decoding: ["s:Se4fromxs7Decoder_p_tKcfc"]
            case .encoding: ["s:SE6encode2toys7Encoder_p_tKF"]
            case .equality: ["s:SQ2eeoiySbx_xtFZ"]
            case .hashing: ["s:SH4hash4intoys6HasherVz_tF", "s:SH9hashValueSivp"]
            }
        }

        /// Whether a struct gets the code and a class does not: a class has to declare how it compares and
        /// hashes, and its subclasses inherit that.
        var isForStructsOnly: Bool {
            self == .equality || self == .hashing
        }

        /// Whether the code leaves out a property declared with `let` and an initial value. Decoding cannot
        /// write it.
        var skipsInitializedConstants: Bool {
            self == .decoding
        }
    }
}
