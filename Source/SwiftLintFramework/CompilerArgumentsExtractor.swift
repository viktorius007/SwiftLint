import Foundation

struct CompilerArgumentsExtractor {
    static func allCompilerInvocations(compilerLogs: String) -> [[String]] {
        var compilerInvocations = [[String]]()
        compilerLogs.enumerateLines { line, _ in
            if let swiftcIndex = line.range(of: "swiftc ")?.upperBound, line.contains(" -module-name ") {
                // A response file is not written by the build tool, so it has none of the log's escapes.
                let invocation = parseCLIArguments(String(line[swiftcIndex...]))
                    .removingEscapesOfBuildLogs
                    .expandingResponseFiles
                    .removingArgumentsThatSourceKitRejects
                compilerInvocations.append(invocation)
            }
        }
        return compilerInvocations
    }
}

// MARK: - Private

private func parseCLIArguments(_ string: String) -> [String] {
    let escapedSpacePlaceholder = "\u{0}"
    let scanner = Scanner(string: string)
    var str = ""
    var didStart = false
    while let result = scanner.scanUpToString("\"") {
        if didStart {
            str += result.replacingOccurrences(of: " ", with: escapedSpacePlaceholder)
            str += " "
        } else {
            // `swift build -v` escapes the `#` between a macro plugin's path and the path of its server.
            str += result.replacingOccurrences(of: "\\#", with: "#")
        }
        _ = scanner.scanString("\"")
        didStart.toggle()
    }
    return str.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "\\ ", with: escapedSpacePlaceholder)
        .components(separatedBy: " ")
        .map { $0.replacingOccurrences(of: escapedSpacePlaceholder, with: " ") }
}

/// Splits a line of a response file into arguments the way the compiler does: a backslash makes the next
/// character an ordinary one, a quote of either kind starts or ends a part in which whitespace separates
/// nothing, and a line that starts with `//` is a comment.
private func parseResponseFileLine(_ line: Substring) -> [String] {
    guard !line.hasPrefix("//") else {
        return []
    }
    var arguments = [String]()
    var argument = ""
    var isEscaped = false
    var isQuoted = false
    for character in line {
        if isEscaped {
            isEscaped = false
        } else if character == "\\" {
            isEscaped = true
            continue
        } else if character == "\"" || character == "'" {
            isQuoted.toggle()
            continue
        } else if character.isWhitespace, !isQuoted {
            if argument.isNotEmpty {
                arguments.append(argument)
                argument = ""
            }
            continue
        }
        argument.append(character)
    }
    if argument.isNotEmpty {
        arguments.append(argument)
    }
    return arguments
}

/**
 Partially filters compiler arguments from `xcodebuild` to something that SourceKit/Clang will accept.

 - parameter args: Compiler arguments, as parsed from `xcodebuild`.

 - returns: A tuple of partially filtered compiler arguments in `.0`, and whether or not there are
 more flags to remove in `.1`.
 */
private func partiallyFilter(arguments args: [String]) -> ([String], Bool) {
    guard let indexOfFlagToRemove = args.firstIndex(of: "-output-file-map") else {
        return (args, false)
    }
    var args = args
    args.remove(at: args.index(after: indexOfFlagToRemove))
    args.remove(at: indexOfFlagToRemove)
    return (args, true)
}

extension Array where Element == String {
    /// Return the full list of compiler arguments, replacing any response files with their contents.
    fileprivate var expandingResponseFiles: [String] {
        expandingResponseFiles(within: [])
    }

    /// - parameter openFiles: The response files that are being expanded, each by its absolute path without `.`
    ///                        and `..`. Like the compiler, this leaves out one of them that it meets again.
    private func expandingResponseFiles(within openFiles: Set<String>) -> [String] {
        flatMap { arg -> [String] in
            guard arg.starts(with: "@") else {
                return [arg]
            }
            let responseFile = URL(filePath: String(arg.dropFirst()), directoryHint: .notDirectory)
            let path = responseFile.standardizedFileURL.path
            guard !openFiles.contains(path) else {
                return []
            }
            return (try? Data(contentsOf: responseFile)).map {
                // Like the compiler, this keeps a byte order mark and replaces bytes that are not UTF-8, and it
                // ends a line at a line feed only.
                // swiftlint:disable:next optional_data_string_conversion
                String(decoding: $0, as: UTF8.self)
                    .split { $0 == "\n" || $0 == "\r\n" }
                    .flatMap(parseResponseFileLine)
                    .expandingResponseFiles(within: openFiles.union([path]))
            } ?? [arg]
        }
    }

    /// Returns filtered compiler arguments from `xcodebuild` to something that SourceKit/Clang will accept.
    var filteringCompilerArguments: [String] {
        removingEscapesOfBuildLogs.removingArgumentsThatSourceKitRejects
    }

    // https://github.com/realm/SwiftLint/issues/3365
    fileprivate var removingEscapesOfBuildLogs: [String] {
        map { $0.replacingOccurrences(of: "\\=", with: "=").replacingOccurrences(of: "\\ ", with: " ") }
    }

    fileprivate var removingArgumentsThatSourceKitRejects: [String] {
        var args = self
        if args.first == "swiftc" {
            args.removeFirst()
        }
        args.append(contentsOf: ["-D", "DEBUG"])
        var shouldContinueToFilterArguments = true
        while shouldContinueToFilterArguments {
            (args, shouldContinueToFilterArguments) = partiallyFilter(arguments: args)
        }

        return args.filter { arg in
            ![
                "-parseable-output",
                "-incremental",
                "-serialize-diagnostics",
                "-emit-dependencies",
                "-use-frontend-parseable-output",
            ].contains(arg)
        }.map { arg in
            if arg == "-O" {
                return "-Onone"
            }
            if arg == "-DNDEBUG=1" {
                return "-DDEBUG=1"
            }
            return arg
        }
    }
}
