import SwiftIDEUtils
import SwiftSyntax

/// The source range of a comment, or of several directly adjacent comments of the same kind.
public struct CommentRange: Equatable, Sendable {
    /// The kind of comment. Always one of the comment classifications.
    public let kind: SyntaxClassification
    /// The range covered by the comment including its delimiters.
    public let range: Range<AbsolutePosition>
}

/// Visitor to find the ranges of all comments in a syntax tree.
///
/// The result equals the comment ranges in `SyntaxProtocol.classifications`. Classifying every token of a file
/// only to find its comments is expensive, though. This visitor looks at trivia only and mirrors the two aspects
/// of the classifier that influence comment ranges: adjacent comments of the same kind are merged, and comments
/// inside an attribute's name are not reported.
final class CommentRangesVisitor: SyntaxVisitor {
    private var commentRanges = [CommentRange]()
    /// Whether the classifier's most recent range is the last comment range, so that a directly following comment
    /// of the same kind extends it.
    private var lastRangeIsComment = false

    /// Find the ranges of all comments in the given file.
    ///
    /// - Parameter file: The SwiftLint file to analyze.
    /// - Returns: All comment ranges in source order.
    static func commentRanges(in file: SwiftLintFile) -> [CommentRange] {
        CommentRangesVisitor(viewMode: .sourceAccurate)
            .walk(tree: file.syntaxTree, handler: \.commentRanges)
    }

    override func visit(_ node: AttributeSyntax) -> SyntaxVisitorContinueKind {
        // The classifier reports the name of an attribute as a single range, no matter what it contains.
        let nameID = node.attributeName.id
        for child in node.children(viewMode: .sourceAccurate) {
            if child.id == nameID {
                process(child.leadingTrivia, startingAt: child.position)
                lastRangeIsComment = false
                process(child.trailingTrivia, startingAt: child.endPositionBeforeTrailingTrivia)
            } else {
                walk(child)
            }
        }
        return .skipChildren
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        if token.leadingTriviaLength != .zero {
            process(token.leadingTrivia, startingAt: token.position)
        }
        // The classifier ignores empty ranges without classification. Every other token ends a comment range.
        if token.trimmedLength != .zero || token.tokenClassification.kind != .none {
            lastRangeIsComment = false
        }
        if token.trailingTriviaLength != .zero {
            process(token.trailingTrivia, startingAt: token.endPositionBeforeTrailingTrivia)
        }
        return .skipChildren
    }

    private func process(_ trivia: Trivia, startingAt start: AbsolutePosition) {
        var position = start
        for piece in trivia {
            let length = piece.sourceLength
            let end = position + length
            if let kind = piece.commentKind {
                if lastRangeIsComment, let last = commentRanges.last, last.kind == kind,
                   last.range.upperBound == position {
                    commentRanges[commentRanges.count - 1] = CommentRange(
                        kind: kind,
                        range: last.range.lowerBound..<end
                    )
                } else {
                    commentRanges.append(CommentRange(kind: kind, range: position..<end))
                }
                lastRangeIsComment = true
            } else if length != .zero {
                lastRangeIsComment = false
            }
            position = end
        }
    }
}

private extension TriviaPiece {
    var commentKind: SyntaxClassification? {
        switch self {
        case .lineComment: .lineComment
        case .blockComment: .blockComment
        case .docLineComment: .docLineComment
        case .docBlockComment: .docBlockComment
        default: nil
        }
    }
}
