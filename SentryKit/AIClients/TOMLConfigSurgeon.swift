import Foundation

/// The TOML equivalent of `JSONConfigSurgeon`: adds, replaces and removes one
/// named table (and its sub-tables) inside a TOML document by splicing lines,
/// leaving every other line — including comments and key order — exactly as
/// the user left it.
///
/// **Why a line splicer and not a TOML library.** This project vendors no TOML
/// parser and `Foundation` has none, so the choice was between adding a
/// dependency, writing a full parser, or writing the smallest thing that can
/// do this job correctly. A full parser would be the wrong answer even if it
/// were free: TOML's whole point is that it is a human-edited format, and
/// round-tripping `~/.codex/config.toml` through *any* parser loses the
/// comments, blank-line grouping and key ordering the user put there. The one
/// file this has to edit is the Codex CLI's, which is a file people genuinely
/// hand-write — `model`, `approval_policy`, `sandbox_mode` and a stack of
/// per-profile tables, usually commented. Destroying that to add four lines
/// would be an unambiguously worse outcome than not offering the button.
///
/// **What "smallest thing that can do this job" means precisely.** TOML tables
/// are line-oriented: a `[header]` line begins a table and it runs until the
/// next `[header]` or the end of the file. Finding a table's extent therefore
/// needs no value parsing at all — only enough lexing to know when a `[` at
/// the start of a line is a header rather than something inside a value.
/// Exactly two things can put it there: a multi-line array (`args = [` … `]`)
/// and a multi-line string (`"""` / `'''`). The scanner below tracks those two
/// states and nothing else, which is why it is fifty lines instead of a
/// thousand — and why its failure mode is "declines to find a table that is
/// there" rather than "corrupts one that is."
///
/// **Rejected: writing `codex mcp add`'s job by hand when the CLI is
/// present.** It isn't rejected — `AIClientConnector` prefers the vendor CLI
/// wherever one exists, exactly as it prefers `claude mcp add` for Claude
/// Code, and this type is the fallback for a Codex install whose CLI does not
/// offer the subcommand. See that type for the argument.
///
/// Pure `String` → `String`, no I/O, same as `JSONConfigSurgeon`.
public enum TOMLConfigSurgeon {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// A `[header]` line that never closes its bracket, i.e. the document
        /// is not TOML and we should not be splicing it.
        case malformedTableHeader(line: Int)

        public var description: String {
            switch self {
            case .malformedTableHeader(let line):
                return "the file has an unterminated table header on line \(line), so it isn't valid TOML"
            }
        }
    }

    // MARK: - Public operations

    /// The body of `[<path>]` (its lines, minus the header) if that table is
    /// present, else `nil`. Sub-tables are included, for the same reason
    /// `remove` deletes them: `[mcp_servers.sentry.env]` is part of our entry.
    public static func table(at path: [String], in text: String) throws -> String? {
        guard let span = try locate(path: path, in: lines(of: text)) else { return nil }
        let all = lines(of: text)
        return all[(span.lowerBound + 1)..<span.upperBound].joined(separator: "\n")
    }

    /// Inserts or replaces `[<path>]` so its body becomes `body`, returning
    /// the new document.
    ///
    /// Idempotent: the second call replaces the table the first one wrote
    /// rather than appending a second `[mcp_servers.sentry]`. (A duplicate
    /// table header is a hard error in TOML, not a last-one-wins quirk — an
    /// append-only implementation would leave Codex unable to read its own
    /// config at all, which is the single worst thing this code could do.)
    ///
    /// - Parameter body: the table's lines without the header, e.g.
    ///   `command = "…"\nargs = []`.
    public static func upsert(table path: [String], body: String, in text: String?) throws -> String {
        let header = "[" + path.map(quoteIfNeeded).joined(separator: ".") + "]"
        let block = header + "\n" + body
        let source = text ?? ""

        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return block + "\n"
        }

        var all = lines(of: source)
        if let span = try locate(path: path, in: all) {
            // The span runs to the next header — or, for the last table in the
            // file, to the end, which includes the empty final element that
            // represents the trailing newline. Replacing that would strip the
            // newline off the file on every write, so a second Connect would
            // produce a different document from the first and idempotency
            // would be quietly false.
            var end = span.upperBound
            while end > span.lowerBound, all[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                end -= 1
            }
            all.replaceSubrange(span.lowerBound..<end, with: block.components(separatedBy: "\n"))
            return all.joined(separator: "\n")
        }

        // Append. A table appended anywhere other than the end would land
        // inside whatever table currently owns that position, silently
        // reparenting the keys that followed it.
        var appended = source
        if !appended.hasSuffix("\n") { appended += "\n" }
        if !appended.hasSuffix("\n\n") { appended += "\n" }
        return appended + block + "\n"
    }

    /// Removes `[<path>]` and its sub-tables, returning the new text, or `nil`
    /// if the table was not there. Every other table survives untouched.
    public static func remove(table path: [String], in text: String) throws -> String? {
        var all = lines(of: text)
        guard let span = try locate(path: path, in: all) else { return nil }
        let start = span.lowerBound
        var end = span.upperBound
        // The span runs to the next header, so it has swallowed the blank
        // separator line before that header. Give it back — it belongs to the
        // table that follows, not to ours.
        while end > start, all[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end -= 1
        }
        all.removeSubrange(start..<end)
        // Removing the *last* table leaves the blank line that separated it
        // from the one before. Collapse trailing blanks down to the single
        // empty element that represents the file's final newline.
        while all.count > 1,
              all[all.count - 1].isEmpty,
              all[all.count - 2].trimmingCharacters(in: .whitespaces).isEmpty {
            all.removeLast()
        }
        return all.joined(separator: "\n")
    }

    // MARK: - Location

    private static func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// The half-open line range covering `[<path>]`, its keys, and any
    /// `[<path>.child]` tables that follow it.
    private static func locate(path: [String], in all: [String]) throws -> Range<Int>? {
        let target = path
        var start: Int?
        var index = 0
        var state = LineState()
        while index < all.count {
            let line = all[index]
            let wasInsideValue = state.isInsideValue
            state.consume(line)
            if !wasInsideValue, let header = try headerPath(of: line, lineNumber: index + 1) {
                if header == target {
                    start = index
                } else if let start, !isDescendant(header, of: target) {
                    return start..<index
                }
            }
            index += 1
        }
        if let start { return start..<all.count }
        return nil
    }

    private static func isDescendant(_ header: [String], of parent: [String]) -> Bool {
        header.count > parent.count && Array(header.prefix(parent.count)) == parent
    }

    /// The dotted key path of a `[table]` header line, or `nil` if the line is
    /// not a header.
    ///
    /// Array-of-tables headers (`[[x]]`) deliberately return `nil`: nothing
    /// this code writes is an array of tables, and treating one as a plain
    /// table would let a `[[mcp_servers.sentry]]` somebody else wrote be
    /// silently overwritten by a `[mcp_servers.sentry]` — a change in kind,
    /// not just in content.
    private static func headerPath(of line: String, lineNumber: Int) throws -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[[") else { return nil }
        guard let close = trimmed.lastIndex(of: "]") else {
            throw Failure.malformedTableHeader(line: lineNumber)
        }
        // Anything after the closing bracket must be a comment; otherwise this
        // is not a header line and we leave it alone.
        let tail = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard tail.isEmpty || tail.hasPrefix("#") else { return nil }
        let inner = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        return splitDotted(inner)
    }

    /// Splits `a.b."c.d"` into its segments, honouring quoted keys — the one
    /// place a naive `split(separator: ".")` would produce a wrong answer, and
    /// the reason it is written out rather than inlined.
    private static func splitDotted(_ inner: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        for character in inner {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "." {
                segments.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        segments.append(current.trimmingCharacters(in: .whitespaces))
        return segments
    }

    /// TOML bare keys are `A-Za-z0-9_-`; anything else has to be quoted, and
    /// quoting something that didn't need it would churn the file on every
    /// write.
    private static func quoteIfNeeded(_ segment: String) -> String {
        let bare = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        if !segment.isEmpty, segment.unicodeScalars.allSatisfy(bare.contains) { return segment }
        return "\"" + segment.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Tracks the only two multi-line constructs that can put a `[` at the
    /// start of a line without it being a table header.
    private struct LineState {
        private var arrayDepth = 0
        private var multilineDelimiter: String?

        var isInsideValue: Bool { arrayDepth > 0 || multilineDelimiter != nil }

        mutating func consume(_ line: String) {
            let characters = Array(line)
            var i = 0
            while i < characters.count {
                if let delimiter = multilineDelimiter {
                    if matches(delimiter, in: characters, at: i) {
                        multilineDelimiter = nil
                        i += 3
                        continue
                    }
                    i += 1
                    continue
                }
                let c = characters[i]
                if c == "#" { return }
                if matches("\"\"\"", in: characters, at: i) { multilineDelimiter = "\"\"\""; i += 3; continue }
                if matches("'''", in: characters, at: i) { multilineDelimiter = "'''"; i += 3; continue }
                if c == "\"" || c == "'" {
                    let quote = c
                    i += 1
                    while i < characters.count, characters[i] != quote {
                        if quote == "\"", characters[i] == "\\" { i += 1 }
                        i += 1
                    }
                    i += 1
                    continue
                }
                if c == "[", arrayDepth > 0 || isValueBracket(characters, at: i) { arrayDepth += 1 }
                else if c == "]", arrayDepth > 0 { arrayDepth -= 1 }
                i += 1
            }
        }

        /// A `[` that opens a *value* rather than a table header: something
        /// other than whitespace precedes it on the line.
        private func isValueBracket(_ characters: [Character], at index: Int) -> Bool {
            characters[0..<index].contains { !$0.isWhitespace }
        }

        private func matches(_ needle: String, in characters: [Character], at index: Int) -> Bool {
            let n = Array(needle)
            guard index + n.count <= characters.count else { return false }
            return Array(characters[index..<(index + n.count)]) == n
        }
    }
}
