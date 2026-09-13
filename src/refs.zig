//! How the gate reads a command line: which project files it names, and what
//! those files are called inside an approval token.
//!
//! Split out of provenance.zig, which is the policy - this is the parsing under
//! it. Pure but for the two calls that ask the filesystem whether a named file
//! is really there.

const std = @import("std");
const app_zig = @import("app.zig");
const proc = @import("proc.zig");
const store = @import("store.zig");

const App = app_zig.App;

/// Most files any one command is credited with referencing. A command naming
/// more than this is doing something the gate cannot summarise usefully anyway,
/// and the cap keeps a pathological line from turning approval into a scan.
pub const max_refs: usize = 8;

/// Extensions worth reviewing: interpreted source, where the file IS the
/// instructions.
///
/// An allowlist, not a blocklist. A project's build OUTPUT is a project file
/// too, and hashing it would re-arm approval on every rebuild - which is how
/// people learn to answer `y` without looking. A binary cannot be reviewed by
/// opening it either.
const script_exts = [_][]const u8{
    ".py", ".sh",  ".bash", ".zsh", ".ps1",  ".psm1", ".cmd", ".bat",
    ".js", ".mjs", ".cjs",  ".ts",  ".rb",   ".pl",   ".lua", ".php",
    ".r",  ".jl",  ".tcl",  ".awk", ".fish",
};

pub fn reviewable(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return false;
    for (script_exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// referencedFiles returns the project files a command actually runs: every
/// whitespace-separated token resolving to an existing file inside the project
/// dir. It is what lets an edit to deploy.py re-arm the gate.
///
/// A shallow heuristic on purpose: it sees what the command line names, not
/// what those files then call, and skips absolute paths and `..` escapes -
/// hashing a system binary would re-arm every approval on the next OS update.
/// Order follows the command line and duplicates collapse, so the same command
/// always produces the same list.
pub fn referencedFiles(app: *App, dir: []const u8, command: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = QuotedTokens{ .s = command };
    while (it.next()) |raw| {
        if (out.items.len >= max_refs) break;
        const tok = std.mem.trim(u8, raw, "\"'");
        if (tok.len == 0 or tok[0] == '-') continue; // a flag is not a path
        const rel = stripDotSlash(tok);
        if (rel.len == 0 or std.fs.path.isAbsolute(rel) or escapes(rel)) continue;
        if (!reviewable(rel)) continue; // build outputs and binaries are not review material
        // The token keeps whatever separator the command used, so a `/` inside an
        // otherwise-`\` path would print as `...\proj\tools/deploy.py`. These
        // paths are shown to someone deciding whether to trust them; a path that
        // looks malformed is a bad thing to ask a person to vouch for.
        const full = nativeSep(app.arena, std.fs.path.join(app.arena, &.{ dir, rel }) catch continue);
        if (!proc.fileExists(app.io, full)) continue;
        var dup = false;
        for (out.items) |o| if (store.eqlFoldAscii(o, full)) {
            dup = true;
            break;
        };
        if (!dup) try out.append(app.arena, full);
    }
    return out.items;
}

/// QuotedTokens splits a command line on whitespace, except inside quotes.
///
/// Plain whitespace tokenizing tore `"tools/my script.py"` into two halves,
/// neither of which named a file, so the script was left out of the approval
/// entirely - editing it did not re-arm the gate. A path with a space in it is
/// the ordinary case on Windows, not an exotic one.
const QuotedTokens = struct {
    s: []const u8,
    i: usize = 0,

    fn next(self: *QuotedTokens) ?[]const u8 {
        while (self.i < self.s.len and isSpace(self.s[self.i])) self.i += 1;
        if (self.i >= self.s.len) return null;
        const start = self.i;
        var quote: ?u8 = null;
        while (self.i < self.s.len) : (self.i += 1) {
            const c = self.s[self.i];
            if (quote) |q| {
                if (c == q) quote = null;
            } else if (c == '"' or c == '\'') {
                quote = c;
            } else if (isSpace(c)) break;
        }
        return self.s[start..self.i];
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\r' or c == '\n';
    }
};

/// nativeSep rewrites separators to the platform's, so a displayed path is one
/// the user could paste back. Returns the input untouched off Windows, where `/`
/// is already native.
pub fn nativeSep(arena: std.mem.Allocator, path: []const u8) []const u8 {
    if (!proc.is_windows) return path;
    const out = arena.dupe(u8, path) catch return path;
    for (out) |*ch| if (ch.* == '/') {
        ch.* = '\\';
    };
    return out;
}

pub fn stripDotSlash(tok: []const u8) []const u8 {
    if (std.mem.startsWith(u8, tok, "./") or std.mem.startsWith(u8, tok, ".\\")) return tok[2..];
    return tok;
}

/// escapes reports whether a relative path walks out of its root via `..`. A
/// textual check, so it never has to touch the filesystem to say no.
pub fn escapes(rel: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, rel, "/\\");
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return true;
    return false;
}

/// relativeTo strips `dir` from the front of an absolute path so the record
/// names the file's place in the project rather than its place on this machine.
/// Falls back to the basename when the path is not under dir, which is what the
/// record used to hold for every file.
pub fn relativeTo(dir: []const u8, path: []const u8) []const u8 {
    if (path.len > dir.len and store.eqlFoldAscii(path[0..dir.len], dir)) {
        var r = path[dir.len..];
        if (r.len > 0 and (r[0] == '/' or r[0] == '\\')) r = r[1..];
        if (r.len > 0) return r;
    }
    return std.fs.path.basename(path);
}

/// canonPath folds the spellings of one path together: separators, and case on
/// Windows. Only for hashing - never for display, which wants what the user
/// would paste back.
pub fn canonPath(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, path);
    for (out) |*ch| {
        if (ch.* == '\\') ch.* = '/';
        if (proc.is_windows) ch.* = std.ascii.toLower(ch.*);
    }
    return out;
}

test "reviewable: interpreted source yes, build output no" {
    // The point of the allowlist: this repo's own `sync` action runs
    // zig-out\bin\nix.exe, and hashing that would re-arm approval on every
    // rebuild - which is how people learn to stop reading the prompt.
    try std.testing.expect(!reviewable("zig-out\\bin\\nix.exe"));
    try std.testing.expect(!reviewable("build\\app.dll"));
    try std.testing.expect(!reviewable("Makefile")); // no extension: not claimed either way
    try std.testing.expect(reviewable("tools/deploy.py"));
    try std.testing.expect(reviewable("scripts\\publish.cmd"));
    try std.testing.expect(reviewable("BUILD.PS1")); // extension match is case-insensitive
}

test "escapes: a `..` segment is refused wherever it sits" {
    try std.testing.expect(escapes(".."));
    try std.testing.expect(escapes("../outside.py"));
    try std.testing.expect(escapes("tools/../../outside.py"));
    try std.testing.expect(escapes("tools\\..\\..\\outside.py"));
    // A name that merely CONTAINS dots is not traversal.
    try std.testing.expect(!escapes("tools/deploy..py"));
    try std.testing.expect(!escapes("tools/..hidden/x.py"));
}

test "stripDotSlash: a leading ./ or .\\ is not part of the path" {
    try std.testing.expectEqualStrings("build.sh", stripDotSlash("./build.sh"));
    try std.testing.expectEqualStrings("build.sh", stripDotSlash(".\\build.sh"));
    try std.testing.expectEqualStrings("build.sh", stripDotSlash("build.sh"));
    // Not to be confused with a parent reference, which escapes() then rejects.
    try std.testing.expectEqualStrings("../x.sh", stripDotSlash("../x.sh"));
}

test "QuotedTokens: a quoted path with a space stays one token" {
    var it = QuotedTokens{ .s = "python \"tools/my script.py\" --flag" };
    try std.testing.expectEqualStrings("python", it.next().?);
    // Whitespace tokenizing split this into `"tools/my` and `script.py"`,
    // neither of which named a file, so the script never entered the approval.
    try std.testing.expectEqualStrings("\"tools/my script.py\"", it.next().?);
    try std.testing.expectEqualStrings("--flag", it.next().?);
    try std.testing.expect(it.next() == null);

    // Single quotes too, and runs of whitespace collapse like the old splitter.
    var q = QuotedTokens{ .s = "sh  'a b.sh'\t x.py" };
    try std.testing.expectEqualStrings("sh", q.next().?);
    try std.testing.expectEqualStrings("'a b.sh'", q.next().?);
    try std.testing.expectEqualStrings("x.py", q.next().?);
    try std.testing.expect(q.next() == null);

    // An unbalanced quote runs to the end rather than losing the rest.
    var u = QuotedTokens{ .s = "sh \"a b" };
    try std.testing.expectEqualStrings("sh", u.next().?);
    try std.testing.expectEqualStrings("\"a b", u.next().?);
    try std.testing.expect(u.next() == null);
}

test "relativeTo: a referenced file is named by its place in the project" {
    // Same basename, same bytes, two projects: the record has to tell them
    // apart, or approving one approves the other.
    try std.testing.expectEqualStrings("scripts/deploy.py", relativeTo("C:/a", "C:/a/scripts/deploy.py"));
    // Separators are left as they came; canonPath folds them at the call site,
    // which is what makes one file reached two ways one approval.
    try std.testing.expectEqualStrings("scripts\\deploy.py", relativeTo("C:\\a", "C:\\a\\scripts\\deploy.py"));
    // Not under dir: the basename, which is what every record used to hold.
    try std.testing.expectEqualStrings("deploy.py", relativeTo("C:/a", "D:/other/deploy.py"));
    // dir itself is not a file under dir.
    try std.testing.expectEqualStrings("a", relativeTo("C:/a", "C:/a"));
}
