import Foundation

/// Adds, replaces and removes exactly one named member inside exactly one
/// nested object of a JSON document, **by splicing text rather than by
/// re-serialising** — the primitive underneath every "Connect" button that
/// writes an MCP client's own configuration file.
///
/// **Why not `JSONSerialization`.** The obvious implementation is
/// `jsonObject(with:)` → mutate the dictionary → `data(withJSONObject:)`.
/// It is three lines and it is wrong for this job, for three separate
/// reasons, each of which showed up while looking at the actual files this
/// code has to edit:
///
/// 1. **It rewrites the entire file.** `~/Library/Application Support/Claude/
///    claude_desktop_config.json` and `~/.cursor/mcp.json` belong to the
///    user, not to us. Round-tripping them through `JSONSerialization`
///    reorders every key (Foundation dictionaries are unordered;
///    `.sortedKeys` swaps one arbitrary order for another), re-indents every
///    line, and turns a diff the user could read into a diff nobody can. A
///    tool that edits somebody else's file should leave the parts it did not
///    come for byte-identical, and this one does: every byte outside the
///    spliced member survives verbatim.
/// 2. **It cannot read JSON with comments.** Editor-adjacent MCP configs are
///    routinely JSONC — VS Code's own `mcp.json` documents `//` comments as
///    supported, and users add them by hand to Cursor's file too.
///    `JSONSerialization` rejects the whole document, so the merge would
///    fail on a *valid* file. The scanner below skips `//` and `/* */`
///    exactly the way a JSONC reader does, and — because it splices — any
///    comment outside the member being changed is preserved untouched.
/// 3. **It silently normalises things it should not.** Numbers get reformatted
///    (`1.0` → `1`), `\/` escapes get unescaped, non-ASCII may get escaped.
///    None of that is our business.
///
/// **Why not a regular expression.** The member we are looking for is
/// `"Sentry"` inside `"mcpServers"`, and a regex has no way to know whether
/// the `"mcpServers"` it just matched is a real key, a string *value* that
/// happens to contain that text, or text inside a comment. A file where some
/// other server's `args` contains the literal `"mcpServers"` is not exotic,
/// and getting it wrong means writing garbage into a file the user depends
/// on. The scanner tracks structure, so it cannot make that mistake.
///
/// **Why it fails loudly instead of guessing.** Every error case carries the
/// byte offset and a sentence a human can act on, because the caller's
/// contract with the user is "if we can't do this safely we will tell you
/// exactly what's wrong and show you the manual steps" — never a partial
/// write. Nothing in this type performs I/O at all; it maps `String` to
/// `String` and throws, which is also what makes the whole merge policy
/// testable without going anywhere near a real config file.
public enum JSONConfigSurgeon {

    // MARK: - Errors

    /// Everything that can stop a splice, with enough detail to print.
    ///
    /// `byteOffset` is a character offset into the document, not a UTF-8 byte
    /// offset — the name is kept because "byte offset" is what a user
    /// expects to see next to a JSON parse error, and for the ASCII these
    /// files are overwhelmingly made of the two agree. Where they disagree
    /// the offset is still monotonic and still points at the right token.
    public enum Failure: Error, Equatable, CustomStringConvertible {

        /// The document is not parseable as JSON/JSONC at all.
        case malformed(reason: String, characterOffset: Int)

        /// The document parses, but its root is not an object — a bare array
        /// or string cannot hold an `mcpServers` key, and inventing a new
        /// root would throw away whatever the user had.
        case rootIsNotAnObject

        /// A key on the path exists but holds something other than an object
        /// (`"mcpServers": []`, say). Overwriting it would destroy data whose
        /// meaning we do not know, so this stops instead.
        case pathElementIsNotAnObject(key: String)

        public var description: String {
            switch self {
            case .malformed(let reason, let offset):
                return "the file isn't valid JSON — \(reason) at character \(offset)"
            case .rootIsNotAnObject:
                return "the file's top level isn't a JSON object, so there's nowhere to put an MCP server entry"
            case .pathElementIsNotAnObject(let key):
                return "\"\(key)\" already exists in the file but isn't a JSON object, so merging into it would destroy whatever it currently holds"
            }
        }
    }

    // MARK: - Public operations

    /// The text of the member's value if `name` is present at `path`, else
    /// `nil`.
    ///
    /// This is the read half of "verify by re-reading the file" — the caller
    /// writes, then reads back and compares against what it meant to write,
    /// rather than reporting success on the strength of `write(to:)` not
    /// having thrown. Returning the *text* rather than a decoded value is
    /// deliberate: the comparison the caller wants is "is the command path
    /// in there", and text keeps this type free of any opinion about the
    /// entry's schema, which differs per client.
    public static func value(
        ofMember name: String,
        at path: [String],
        in text: String
    ) throws -> String? {
        let characters = Array(text)
        guard let object = try locateObject(at: path, in: characters) else {
            return nil
        }
        guard let member = object.members.first(where: { $0.key == name }) else { return nil }
        return String(characters[member.valueStart..<member.end])
    }

    /// Inserts or replaces `name` at `path` so its value becomes `value`,
    /// returning the new document text.
    ///
    /// Idempotent in the only sense that matters to a button a user can
    /// double-click: running it twice produces the same document as running
    /// it once, because the second run *replaces* the member it finds rather
    /// than appending a duplicate. (JSON permits duplicate keys textually;
    /// parsers pick one arbitrarily. Producing one would be a real bug —
    /// `disconnect` would remove one and leave the other, and the pane would
    /// then honestly report "still connected" forever.)
    ///
    /// Missing objects along `path` are created, and a `nil`/empty `text`
    /// produces a whole new document. That is the "the tool is installed but
    /// has never been run" case, and creating the file is the right answer
    /// there — but the *caller* is the one that has to say so out loud, which
    /// is why `AIClientConnector` reports it separately rather than letting
    /// it pass as an ordinary write.
    ///
    /// - Parameter value: the member's value, already rendered as JSON. It is
    ///   re-indented to sit correctly at its insertion depth; its first line
    ///   is emitted where the cursor already is.
    public static func upsert(
        member name: String,
        value: String,
        at path: [String],
        in text: String?
    ) throws -> String {
        let source = text ?? ""
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return renderNewDocument(member: name, value: value, at: path)
        }

        var characters = Array(source)
        guard let object = try locateObject(at: path, in: characters) else {
            // A path element is absent. Create the shallowest missing one and
            // come back through the front door, rather than duplicating the
            // insertion-point logic for a nested-creation special case.
            let seeded = try seedMissingPath(path, in: source)
            return try upsert(member: name, value: value, at: path, in: seeded)
        }

        let indent = object.memberIndent(in: characters)
        let closingIndent = object.closingIndent(in: characters)
        let rendered = "\"\(name)\": " + reindent(value, to: indent)

        if let existing = object.members.first(where: { $0.key == name }) {
            characters.replaceSubrange(existing.start..<existing.end, with: rendered)
            return String(characters)
        }

        if let last = object.members.last {
            // Append after the final member. Inserting at the *end* rather
            // than the start keeps the user's existing servers where they
            // were in the file, which matters when they are scanning it by
            // eye to check we didn't touch them.
            characters.insert(contentsOf: ",\n" + indent + rendered, at: last.end)
        } else {
            characters.replaceSubrange(
                (object.openBrace + 1)..<object.closeBrace,
                with: "\n" + indent + rendered + "\n" + closingIndent
            )
        }
        return String(characters)
    }

    /// Removes `name` at `path` if present, returning the new text, or `nil`
    /// if there was nothing to remove.
    ///
    /// Removes **only** that member: sibling servers, unrelated top-level
    /// keys, and the `mcpServers` object itself all survive, including when
    /// ours was the only entry in it. Leaving an empty `"mcpServers": {}`
    /// behind is deliberate — deleting the key would be a second, unrequested
    /// edit to a file we were asked to remove one thing from, and an empty
    /// object is exactly what the client would have written itself.
    ///
    /// The surrounding punctuation is cleaned up (the member's comma, the
    /// blank line it leaves) so the result looks hand-edited rather than
    /// machine-gouged, but nothing outside the member's own line is touched —
    /// in particular a comment on its own line above the member is *kept*,
    /// since we cannot know it was about us.
    public static func remove(
        member name: String,
        at path: [String],
        in text: String
    ) throws -> String? {
        var characters = Array(text)
        guard let object = try locateObject(at: path, in: characters),
              let member = object.members.first(where: { $0.key == name })
        else { return nil }

        var start = member.start
        var end = member.end

        /// Extends the range over the member's own line: its leading
        /// indentation and its terminating newline. Only correct when the
        /// member owns a whole line, which is why it is not applied to the
        /// last-of-several case below.
        func swallowOwnLine() {
            var lineStart = start
            while lineStart > 0, characters[lineStart - 1] == " " || characters[lineStart - 1] == "\t" { lineStart -= 1 }
            if lineStart == 0 || characters[lineStart - 1] == "\n" { start = lineStart }
            var lineEnd = end
            while lineEnd < characters.count, characters[lineEnd] == " " || characters[lineEnd] == "\t" { lineEnd += 1 }
            if lineEnd < characters.count, characters[lineEnd] == "\n" { end = lineEnd + 1 }
        }

        var probe = end
        while probe < characters.count, characters[probe] == " " || characters[probe] == "\t" { probe += 1 }

        if probe < characters.count, characters[probe] == "," {
            // Something follows us, so the separator after us is ours. Take
            // the whole line, leaving the members either side untouched.
            end = probe + 1
            swallowOwnLine()
        } else {
            var back = start - 1
            while back >= 0, characters[back].isWhitespace { back -= 1 }
            if back >= 0, characters[back] == "," {
                // We are the last of several: the separator *before* us is
                // ours, and it lives at the end of the previous member's line.
                // Taking the trailing newline as well would splice the closing
                // brace onto that line — which is exactly the round-trip bug
                // `testConnectThenDisconnectRestoresTheFileExactly` caught.
                start = back
            } else {
                // The only member. Nothing else claims the line.
                swallowOwnLine()
            }
        }

        characters.removeSubrange(start..<end)
        return String(characters)
    }

    // MARK: - Document synthesis

    /// The whole file, for a client that has never been run.
    private static func renderNewDocument(member name: String, value: String, at path: [String]) -> String {
        var body = "\"\(name)\": " + reindent(value, to: String(repeating: "  ", count: path.count + 1))
        for (depth, key) in path.enumerated().reversed() {
            let indent = String(repeating: "  ", count: depth + 2)
            let closingIndent = String(repeating: "  ", count: depth + 1)
            body = "\"\(key)\": {\n" + indent + body + "\n" + closingIndent + "}"
        }
        return "{\n  " + body + "\n}\n"
    }

    /// Creates the first missing object along `path` and returns the new text.
    ///
    /// One level per call, re-entering through `upsert`, because creating
    /// `{"a":{"b":{}}}` in a single pass would need its own insertion-point
    /// logic that the existing single-level path already implements correctly.
    /// Config paths here are one or two elements deep; the recursion is
    /// bounded by `path.count`.
    private static func seedMissingPath(_ path: [String], in text: String) throws -> String {
        let characters = Array(text)
        for depth in 0..<path.count {
            let prefix = Array(path[0..<depth])
            guard let parent = try locateObject(at: prefix, in: characters) else { continue }
            if parent.members.contains(where: { $0.key == path[depth] }) { continue }
            return try upsert(member: path[depth], value: "{}", at: prefix, in: text)
        }
        // Unreachable in practice — the only reason `locateObject` returns nil
        // is a missing element, which the loop above must therefore have
        // found. Throwing rather than returning `text` unchanged is what stops
        // an unforeseen disagreement between the two from becoming infinite
        // mutual recursion with `upsert`.
        throw Failure.malformed(
            reason: "the \"\(path.joined(separator: "\" ▸ \""))\" section couldn't be located or created",
            characterOffset: 0
        )
    }

    // MARK: - Object location

    /// One member of a JSON object, as spans into the character array.
    struct Member {
        let key: String
        /// Index of the opening quote of the key.
        let start: Int
        /// Index of the first character of the value.
        let valueStart: Int
        /// One past the last character of the value.
        let end: Int
    }

    struct ObjectLayout {
        let openBrace: Int
        let closeBrace: Int
        let members: [Member]

        /// The indentation existing members sit at, so an inserted one lines
        /// up with them instead of announcing itself.
        func memberIndent(in characters: [Character]) -> String {
            guard let first = members.first else {
                return closingIndent(in: characters) + "  "
            }
            var i = first.start
            var indent = ""
            while i > 0, characters[i - 1] == " " || characters[i - 1] == "\t" {
                i -= 1
                indent = String(characters[i]) + indent
            }
            guard i == 0 || characters[i - 1] == "\n" else {
                // The member doesn't start its own line (`{"a": 1}`); match
                // the brace's line instead of inventing a hanging indent.
                return closingIndent(in: characters) + "  "
            }
            return indent
        }

        /// The indentation of the line the object's opening brace is on.
        func closingIndent(in characters: [Character]) -> String {
            var i = openBrace
            var indent = ""
            while i > 0, characters[i - 1] == " " || characters[i - 1] == "\t" {
                i -= 1
                indent = String(characters[i]) + indent
            }
            return (i == 0 || characters[i - 1] == "\n") ? indent : ""
        }
    }

    /// Walks `path` from the root object, returning the object it names.
    ///
    /// Returns `nil` (rather than throwing) for "a key on the path is simply
    /// absent", because absence is a normal, fixable state — the caller
    /// either creates it or reports "not connected". A key that *exists* and
    /// holds a non-object throws, because that is a genuine conflict.
    static func locateObject(
        at path: [String],
        in characters: [Character]
    ) throws -> ObjectLayout? {
        var scanner = Scanner(characters: characters)
        scanner.skipTrivia()
        guard scanner.index < characters.count, characters[scanner.index] == "{" else {
            throw Failure.rootIsNotAnObject
        }
        var object = try scanner.readObject()
        for key in path {
            guard let member = object.members.first(where: { $0.key == key }) else {
                return nil
            }
            guard characters[member.valueStart] == "{" else {
                throw Failure.pathElementIsNotAnObject(key: key)
            }
            var inner = Scanner(characters: characters)
            inner.index = member.valueStart
            object = try inner.readObject()
        }
        return object
    }

    // MARK: - Indentation

    /// Re-indents a multi-line rendered value so its continuation lines sit
    /// under the member being written, leaving single-line values alone.
    static func reindent(_ value: String, to indent: String) -> String {
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 1 else { return value }
        // The value arrives indented relative to column zero; shift every line
        // after the first by the target indent, preserving its own relative
        // depth.
        return ([lines[0]] + lines.dropFirst().map { indent + $0 }).joined(separator: "\n")
    }

    // MARK: - Scanner

    /// A JSONC-tolerant structural scanner: enough of a parser to find object
    /// and member boundaries, and deliberately no more.
    ///
    /// It does not build values, does not validate numbers beyond "these
    /// characters can form one", and does not care whether the document would
    /// satisfy a strict validator — a config file the client itself reads
    /// happily must not be rejected here on a technicality. What it *is*
    /// strict about is structure, because every span it hands back is about to
    /// be used as a splice point.
    struct Scanner {
        let characters: [Character]
        var index = 0

        init(characters: [Character]) {
            self.characters = characters
        }

        mutating func skipTrivia() {
            while index < characters.count {
                let c = characters[index]
                if c.isWhitespace {
                    index += 1
                } else if c == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                    while index < characters.count, characters[index] != "\n" { index += 1 }
                } else if c == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                    index += 2
                    while index + 1 < characters.count,
                          !(characters[index] == "*" && characters[index + 1] == "/") {
                        index += 1
                    }
                    index = min(index + 2, characters.count)
                } else {
                    return
                }
            }
        }

        /// Reads the object starting at the current `{`, returning every
        /// member's span. Leaves `index` one past the closing brace.
        mutating func readObject() throws -> ObjectLayout {
            let openBrace = index
            index += 1
            var members: [Member] = []
            while true {
                skipTrivia()
                guard index < characters.count else {
                    throw Failure.malformed(reason: "the file ends inside an object that was never closed", characterOffset: openBrace)
                }
                if characters[index] == "}" {
                    let close = index
                    index += 1
                    return ObjectLayout(openBrace: openBrace, closeBrace: close, members: members)
                }
                if characters[index] == "," {
                    // Tolerated between members and before `}` (a trailing
                    // comma). JSONC allows it and several editors write it.
                    index += 1
                    continue
                }
                guard characters[index] == "\"" else {
                    throw Failure.malformed(reason: "expected a quoted key", characterOffset: index)
                }
                let keyStart = index
                let key = try readString()
                skipTrivia()
                guard index < characters.count, characters[index] == ":" else {
                    throw Failure.malformed(reason: "expected \":\" after key \"\(key)\"", characterOffset: index)
                }
                index += 1
                skipTrivia()
                let valueStart = index
                try skipValue()
                members.append(Member(key: key, start: keyStart, valueStart: valueStart, end: index))
            }
        }

        /// Reads a quoted string, decoding just enough escapes to compare keys
        /// correctly. Leaves `index` one past the closing quote.
        mutating func readString() throws -> String {
            let start = index
            index += 1
            var out = ""
            while index < characters.count {
                let c = characters[index]
                if c == "\\" {
                    index += 1
                    guard index < characters.count else { break }
                    let escape = characters[index]
                    switch escape {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "r": out.append("\r")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "u":
                        let hex = String(characters[(index + 1)..<min(index + 5, characters.count)])
                        if hex.count == 4, let scalar = UInt32(hex, radix: 16),
                           let unicode = Unicode.Scalar(scalar) {
                            out.append(Character(unicode))
                        }
                        index += 4
                    default: out.append(escape)
                    }
                    index += 1
                } else if c == "\"" {
                    index += 1
                    return out
                } else {
                    out.append(c)
                    index += 1
                }
            }
            throw Failure.malformed(reason: "a string is never closed", characterOffset: start)
        }

        /// Advances past one complete value of any type.
        mutating func skipValue() throws {
            skipTrivia()
            guard index < characters.count else {
                throw Failure.malformed(reason: "the file ends where a value was expected", characterOffset: index)
            }
            switch characters[index] {
            case "{":
                _ = try readObject()
            case "[":
                let open = index
                index += 1
                while true {
                    skipTrivia()
                    guard index < characters.count else {
                        throw Failure.malformed(reason: "the file ends inside an array that was never closed", characterOffset: open)
                    }
                    if characters[index] == "]" { index += 1; return }
                    if characters[index] == "," { index += 1; continue }
                    try skipValue()
                }
            case "\"":
                _ = try readString()
            default:
                let start = index
                while index < characters.count {
                    let c = characters[index]
                    if c.isWhitespace || c == "," || c == "}" || c == "]" || c == "/" { break }
                    index += 1
                }
                guard index > start else {
                    throw Failure.malformed(reason: "expected a value", characterOffset: start)
                }
            }
        }
    }
}
