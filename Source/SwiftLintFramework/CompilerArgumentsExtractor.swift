import Foundation

struct CompilerArgumentsExtractor {
    static func allCompilerInvocations(compilerLogs: String) -> [[String]] {
        var compilerInvocations = [[String]]()
        compilerLogs.enumerateLines { line, _ in
            guard let swiftcIndex = line.range(of: "swiftc ")?.upperBound else {
                return
            }
            let arguments = parseCLIArguments(String(line[swiftcIndex...])).expandingResponseFilesOfABuildLog
            // A line that names a module is an invocation. The name can come from a response file too.
            guard arguments.contains(where: { $0 == "-module-name" || $0.starts(with: moduleNameWithValue) }) else {
                return
            }
            compilerInvocations.append(arguments.removingArgumentsThatSourceKitRejects)
        }
        return compilerInvocations
    }
}

// MARK: - Private

/// The option that names the module, as the compiler takes it in one argument with the name. It also takes
/// the name in the next argument. Which arguments the compiler reads as options is not known here, so an
/// argument that another option takes, or a file after `--`, counts as the option if it is spelled like it:
/// `-I -module-name`, `-- -module-name=A.swift`.
private let moduleNameWithValue = "-module-name="

/// Stands for a backslash inside quotes in what `parseCLIArguments` returns.
private let quotedBackslashPlaceholder = "\u{1}"

/// Splits a line of a build log into arguments. A backslash inside quotes is returned as
/// `quotedBackslashPlaceholder`.
private func parseCLIArguments(_ string: String) -> [String] {
    let escapedSpacePlaceholder = "\u{0}"
    let scanner = Scanner(string: string)
    var str = ""
    var didStart = false
    while !scanner.isAtEnd {
        // Nothing is scanned where a quote comes first: at the start, and after another quoted argument.
        let result = scanner.scanUpToString("\"") ?? ""
        if didStart {
            str += result.replacingOccurrences(of: " ", with: escapedSpacePlaceholder)
                .replacingOccurrences(of: "\\", with: quotedBackslashPlaceholder)
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
    /// These arguments of a build log's line as the compiler gets them: without the escapes of the log, and with
    /// the contents of each response file in its place. A response file is not written by the build tool, so it
    /// has none of the log's escapes.
    fileprivate var expandingResponseFilesOfABuildLog: [String] {
        // A backslash inside quotes is no escape: a shell passes it on as it is before `=` and before a space.
        removingEscapesOfBuildLogs
            .map { $0.replacingOccurrences(of: quotedBackslashPlaceholder, with: "\\") }
            .expandingResponseFiles(within: [])
    }

    /// Returns the arguments with the contents of each response file in its place.
    ///
    /// - parameter openFiles: The response files that are being expanded, each by its absolute path without `.`
    ///                        and `..`. Like the compiler, this leaves out one of them that it meets again.
    private func expandingResponseFiles(within openFiles: Set<String>) -> [String] {
        flatMap { arg -> [String] in
            guard arg.starts(with: "@") else {
                return [arg]
            }
            // Like the compiler, this takes `.` and `..` out of the path before it opens the file, so that a
            // symbolic link before `..` is not followed.
            let responseFile = URL(filePath: String(arg.dropFirst()), directoryHint: .notDirectory)
                .absoluteURL.standardized
            let path = responseFile.path
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
        var args = removingEscapesOfBuildLogs
        // The arguments of a compilation database start with the compiler. A line of a build log is cut after it.
        if args.first == "swiftc" {
            args.removeFirst()
        }
        return args.removingArgumentsThatSourceKitRejects
    }

    // https://github.com/realm/SwiftLint/issues/3365
    fileprivate var removingEscapesOfBuildLogs: [String] {
        map { $0.replacingOccurrences(of: "\\=", with: "=").replacingOccurrences(of: "\\ ", with: " ") }
    }

    fileprivate var removingArgumentsThatSourceKitRejects: [String] {
        var args = self
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
