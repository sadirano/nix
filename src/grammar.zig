//! The CLI grammar: every flag nix accepts, in one table per surface.
//!
//! Before this file a command existed in four places - the parser's flag map,
//! the hand-written `--help` heredoc, the agentdocs spec table, and the README
//! - and only the eight wrapper slots had anything keeping them in step. They
//! drifted: `--notes`/`-N` and the `--note` action shipped and never reached
//! `nix --help` at all.
//!
//! Now the parser and the help text read the same rows. A flag that is not in a
//! table does not parse, so the binary can no longer know about a command its
//! own help does not, and `verb` is an ENUM: the dispatcher switches on it
//! exhaustively, so adding a row without wiring a handler is a compile error
//! rather than a silent "unknown flag" at runtime.
//!
//! This module imports nothing but std on purpose. It is the bottom of the
//! import graph - main, app, cmd_groups and agentdocs all read it, and it must
//! never read them back.

const std = @import("std");

/// Verbs `nix --<flag>` dispatches to. dispatchSystem switches over this with
/// no else branch, which is what makes the table and the dispatcher provably
/// the same set.
pub const SystemVerb = enum {
    list,
    list_names,
    which,
    edit,
    prune,
    doctor,
    groups,
    contexts,
    actions,
    notes,
    log_list,
    time,
    init,
    sync,
    sync_bin,
    secret,
    trust,
    agent,
    quit,
    version,
    help,
    preview,
    rga_preview,
};

/// Verbs `nix <alias> --<flag>` dispatches to. Their names are also the strings
/// the multicall layer uses for a wrapper's action, so `@tagName` is the bridge
/// between the two (see main.actionFlag).
pub const ActionVerb = enum {
    resolve,
    edit,
    explore,
    yank,
    paste,
    run,
    grep,
    find,
    env,
    note,
    /// `nix <alias> --notes`: READ this alias's notes (the `--note` above
    /// writes one). Same spelling as the system `--notes`, one scope narrower -
    /// the pair `--edit` already forms across the two tables.
    notes,
    remove,
};

/// Process-wide flags any sub-parser silently accepts.
pub const GlobalFlag = enum { no_prompt, force, json, as, log, no_log };

/// internal commands are real and dispatched, but are nix re-invoking itself
/// (fzf preview panes) rather than anything a user or agent types. They are
/// excluded from --help and need no spec.
pub const Visibility = enum { public, internal };

/// One command, on any of the three surfaces.
pub fn Row(comptime Verb: type) type {
    return struct {
        /// Every accepted spelling, canonical form FIRST - that order is what
        /// --help renders ("--list, -l") and what flagFor returns.
        flags: []const []const u8,
        verb: Verb,
        /// Argument sketch rendered after the flags in --help.
        args: []const u8 = "",
        /// One line for --help. Embedded newlines continue on the next line,
        /// indented to the description column.
        help: []const u8,
        /// The agentdocs topic carrying this command's full spec, or "" for the
        /// ones that only ever get a help line. Deliberately has NO default:
        /// adding a command makes you decide whether an agent needs a spec for
        /// it, which is the one call nobody remembers to make later. A test
        /// checks both directions of this against the spec table.
        spec: []const u8,
        visibility: Visibility = .public,
    };
}

pub const System = Row(SystemVerb);
pub const Action = Row(ActionVerb);
pub const Global = Row(GlobalFlag);

// ---- the tables -------------------------------------------------------------

pub const system = [_]System{
    .{ .flags = &.{ "--list", "--ls", "-l" }, .verb = .list, .help = "list every alias with its path", .spec = "--list" },
    .{ .flags = &.{"--list-names"}, .verb = .list_names, .help = "bare alias names, one per line (the form to parse)", .spec = "" },
    .{ .flags = &.{ "--which", "-w" }, .verb = .which, .args = "[path]", .help = "print the alias containing a path (default: cwd)", .spec = "--which" },
    .{ .flags = &.{ "--edit", "-e" }, .verb = .edit, .help = "open ~/.nix in your editor", .spec = "" },
    .{ .flags = &.{"--prune"}, .verb = .prune, .help = "interactively remove stale aliases", .spec = "" },
    .{ .flags = &.{ "--doctor", "-D" }, .verb = .doctor, .args = "[-q]", .help = "check tools/config and what the picker will use", .spec = "--doctor" },
    .{ .flags = &.{ "--groups", "-G" }, .verb = .groups, .help = "list alias groups  (+<group> --list shows members)", .spec = "groups" },
    .{ .flags = &.{ "--actions", "-A" }, .verb = .actions, .args = "[pat]", .help = "every alias's actions in one picker; Enter runs the pick", .spec = "--actions" },
    .{ .flags = &.{ "--notes", "-N" }, .verb = .notes, .args = "[pat]", .help = "search every alias's notes in one view", .spec = "notes" },
    .{ .flags = &.{ "--contexts", "-c" }, .verb = .contexts, .help = "list global @-segment contexts", .spec = "segments" },
    .{ .flags = &.{"--logs"}, .verb = .log_list, .args = "[alias]", .help = "browse recorded action output (~/.nix/logs)", .spec = "--logs" },
    .{ .flags = &.{ "--time", "-T" }, .verb = .time, .args = "[alias]", .help = "time per alias this week (--day, --all widen it)", .spec = "--time" },
    .{ .flags = &.{ "--init", "-I" }, .verb = .init, .help = "set up ~/.nix, wrappers, and PATH", .spec = "" },
    .{ .flags = &.{ "--sync", "-S" }, .verb = .sync, .help = "regenerate wrappers and generated files", .spec = "" },
    .{ .flags = &.{"--sync-bin"}, .verb = .sync_bin, .help = "install projects' [bin] exports into ~/.nix/bin", .spec = "--sync-bin" },
    .{ .flags = &.{"--secret"}, .verb = .secret, .args = "set|rm|list [NAME]", .help = "manage ${secret:NAME} values for actions (Windows Credential Manager)", .spec = "--secret" },
    .{ .flags = &.{"--trust"}, .verb = .trust, .args = "<alias> [segment|env]", .help = "approve an alias's project actions, scripts, context sources and env.toml as they stand", .spec = "" },
    .{ .flags = &.{"--agent"}, .verb = .agent, .args = "[topic]", .help = "full command spec for an agent (`<cmd> --agent` works too)", .spec = "" },
    .{ .flags = &.{"--quit"}, .verb = .quit, .args = "[--dry-run]", .help = "close the shell this ran in (the `q` command)", .spec = "q" },
    .{ .flags = &.{ "--version", "-v" }, .verb = .version, .help = "print version and platform", .spec = "" },
    .{ .flags = &.{ "--help", "-h" }, .verb = .help, .help = "show this help", .spec = "" },
    // nix re-invoking itself for an fzf preview pane. Not user grammar.
    .{ .flags = &.{"--preview"}, .verb = .preview, .help = "", .spec = "", .visibility = .internal },
    .{ .flags = &.{"--rga-preview"}, .verb = .rga_preview, .help = "", .spec = "", .visibility = .internal },
};

pub const actions = [_]Action{
    .{ .flags = &.{"--resolve"}, .verb = .resolve, .help = "print the resolved path", .spec = "" },
    .{ .flags = &.{ "--edit", "-e" }, .verb = .edit, .args = "[file]", .help = "open in your editor", .spec = "e" },
    .{ .flags = &.{ "--explore", "-x" }, .verb = .explore, .args = "[pat]", .help = "open in the file manager; with a pattern, pick files -> open them", .spec = "s" },
    .{ .flags = &.{ "--yank", "-y" }, .verb = .yank, .args = "[pat]", .help = "copy the path; with a pattern, pick files -> copy the files", .spec = "y" },
    .{ .flags = &.{ "--paste", "-p" }, .verb = .paste, .args = "[name]", .help = "save the clipboard into the dir", .spec = "p" },
    .{ .flags = &.{ "--run", "-r" }, .verb = .run, .args = "<cmd>", .help = "run a command at the dir (`:name` runs a saved action)", .spec = "x" },
    .{ .flags = &.{ "--grep", "-g" }, .verb = .grep, .args = "<pat>", .help = "ripgrep search (add --all/-a to search via rga)", .spec = "g" },
    .{ .flags = &.{ "--find", "-f" }, .verb = .find, .args = "[pat]", .help = "fuzzy-find files", .spec = "f" },
    .{ .flags = &.{"--env"}, .verb = .env, .help = "print the project's environment (.nix/env.toml), with provenance", .spec = "env" },
    .{ .flags = &.{"--note"}, .verb = .note, .args = "<text>", .help = "append a line to the alias's notes", .spec = "notes" },
    .{ .flags = &.{"--notes"}, .verb = .notes, .args = "[pat]", .help = "search this alias's notes (the `n <alias>` command)", .spec = "n" },
    .{ .flags = &.{ "--remove", "--rm" }, .verb = .remove, .help = "forget the alias", .spec = "" },
};

pub const globals = [_]Global{
    .{
        .flags = &.{"--no-prompt"},
        .verb = .no_prompt,
        .help =
        \\never open a picker or ask; print what it would
        \\have offered and act on nothing
        ,
        .spec = "",
    },
    .{
        // `-q` is deliberately NOT a spelling of this: `--doctor -q` is doctor's
        // own quiet flag and `rg -q` is ripgrep's, so the short form read as
        // three different things depending on where it landed.
        .flags = &.{"--force"},
        .verb = .force,
        .help =
        \\go through with an act that would otherwise ask.
        \\Today: repointing an existing alias, which
        \\forgets the path it had. NOT implied by
        \\--no-prompt - "don't block me" and "overwrite
        \\what I have" are different statements
        ,
        .spec = "",
    },
    .{ .flags = &.{ "--json", "-j" }, .verb = .json, .help = "machine-readable output where a command has it", .spec = "" },
    .{
        .flags = &.{"--log"},
        .verb = .log,
        .help =
        \\record this action's output to ~/.nix/logs,
        \\whatever [log] actions says (named actions only)
        ,
        .spec = "--logs",
    },
    .{ .flags = &.{"--no-log"}, .verb = .no_log, .help = "do not record this run, whatever [log] actions says", .spec = "--logs" },
    .{
        // The only global that takes a VALUE. run() lifts the pair out of argv
        // before any sub-parser sees it, precisely because the shared
        // "skip global flags" idiom would skip the flag and then read `wsl` as
        // a positional. Listed here so --help and --agent document it.
        .flags = &.{"--as"},
        .verb = .as,
        .args = "<dialect>",
        .help =
        \\spell the path for another tool: win, slash,
        \\gitbash, wsl, uri. Applies to the resolve form
        \\(`nix <alias> --as wsl`) and to `y`; `o` refuses
        \\it, since it navigates rather than printing
        ,
        .spec = "--as",
    },
};

/// Flags a sub-command parses for itself, and the form that would work. They
/// are deliberately NOT rows above - the owning module still parses them, and
/// promoting them would mean a verb the dispatcher has no arm for. They are
/// listed only so a flag typed in the WRONG SCOPE can be answered with where it
/// belongs instead of "unknown flag", which is true and useless.
pub const Scoped = struct {
    flag: []const u8,
    form: []const u8,
    /// The verb this flag can only have meant. A scoped flag naming no alias
    /// action would be ambiguous; every one of these names exactly one, which
    /// is what lets the parser act on it instead of refusing.
    implies: ActionVerb,
};
pub const scoped = [_]Scoped{
    .{ .flag = "--watch", .form = "x <alias> --watch <cmd>", .implies = .run },
    .{ .flag = "--outside", .form = "x <alias> --outside <cmd>", .implies = .run },
    .{ .flag = "--all", .form = "g <alias> <pat> --all", .implies = .grep },
};

/// impliedAction resolves a sub-command flag typed where no action was named.
/// `nix acme --watch <cmd>` has one possible reading, so it gets it rather
/// than an error naming the spelling it should have used.
///
/// NOT fuzzy matching: nothing is being guessed. The token is in the table or
/// it is not, and a flag that is not stays an error.
pub fn impliedAction(flag: []const u8) ?ActionVerb {
    for (scoped) |sc| {
        if (std.mem.eql(u8, sc.flag, flag)) return sc.implies;
    }
    return null;
}

// ---- lookup -----------------------------------------------------------------

fn lookup(comptime Verb: type, rows: []const Row(Verb), flag: []const u8) ?Verb {
    for (rows) |r| {
        for (r.flags) |f| if (std.mem.eql(u8, f, flag)) return r.verb;
    }
    return null;
}

/// systemVerb resolves `nix --<flag>`. Null means the flag is not nix's.
pub fn systemVerb(flag: []const u8) ?SystemVerb {
    return lookup(SystemVerb, &system, flag);
}

/// aliasAction resolves `nix <alias> --<flag>`.
pub fn aliasAction(flag: []const u8) ?ActionVerb {
    return lookup(ActionVerb, &actions, flag);
}

pub fn isGlobal(flag: []const u8) bool {
    return lookup(GlobalFlag, &globals, flag) != null;
}

/// flagFor returns an action's canonical spelling - the inverse of aliasAction,
/// used when the multicall layer rewrites `g acme pat` into the canonical
/// `nix acme --grep pat`.
pub fn flagFor(verb: ActionVerb) []const u8 {
    for (actions) |r| {
        if (r.verb == verb) return r.flags[0];
    }
    unreachable; // the table is exhaustive over ActionVerb; see the test below.
}

/// knows reports whether a token is a flag nix accepts anywhere - the universe
/// the agentdocs safe_form lint checks against.
pub fn knows(flag: []const u8) bool {
    return systemVerb(flag) != null or aliasAction(flag) != null or isGlobal(flag) or impliedAction(flag) != null;
}

// ---- rendering --------------------------------------------------------------

/// writeMisplacedHint writes the "you meant it here" line for a flag nix DOES
/// know, typed somewhere it does not parse. Returns false for a flag nix has
/// never heard of - a plain typo, which has no better answer than the one the
/// caller already printed.
///
/// The three scopes are the three tables: a system flag takes no alias, an
/// action flag comes after one, and a scoped flag belongs to the command that
/// parses it. Written here rather than at the call sites so both of them say
/// the same thing.
pub fn writeMisplacedHint(w: *std.Io.Writer, flag: []const u8) !bool {
    if (systemVerb(flag)) |_| {
        try w.print("  {s} is a system command and takes no alias: nix {s}\n", .{ flag, flag });
        return true;
    }
    if (aliasAction(flag)) |_| {
        try w.print("  {s} belongs after an alias: nix <alias> {s}\n", .{ flag, flag });
        return true;
    }
    for (scoped) |s| {
        if (std.mem.eql(u8, s.flag, flag)) {
            try w.print("  {s} belongs to another command: {s}\n", .{ flag, s.form });
            return true;
        }
    }
    return false;
}

/// spellings writes the flags column ("--list, -l") into buf and returns it.
/// Callers size buf themselves; every row fits comfortably in 32 bytes.
pub fn spellings(buf: []u8, flags: []const []const u8) []const u8 {
    var n: usize = 0;
    for (flags, 0..) |f, i| {
        if (i > 0) {
            @memcpy(buf[n..][0..2], ", ");
            n += 2;
        }
        @memcpy(buf[n..][0..f.len], f);
        n += f.len;
    }
    return buf[0..n];
}

// ---- tests ------------------------------------------------------------------

test "every flag resolves to its verb, unknown flags to null" {
    try std.testing.expectEqual(SystemVerb.list, systemVerb("--list").?);
    try std.testing.expectEqual(SystemVerb.list, systemVerb("-l").?);
    try std.testing.expectEqual(SystemVerb.notes, systemVerb("--notes").?);
    try std.testing.expect(systemVerb("--bogus") == null);
    // File deletion was removed: --remove/--rm are actions, never system verbs.
    try std.testing.expect(systemVerb("--remove") == null);
    try std.testing.expect(systemVerb("--rm") == null);

    try std.testing.expectEqual(ActionVerb.edit, aliasAction("-e").?);
    try std.testing.expectEqual(ActionVerb.remove, aliasAction("--rm").?);
    try std.testing.expect(aliasAction("acme") == null);

    try std.testing.expect(isGlobal("--no-prompt"));
    try std.testing.expect(!isGlobal("-q"));

    try std.testing.expect(knows("--list"));
    try std.testing.expect(knows("--grep"));
    try std.testing.expect(knows("--no-prompt"));
    try std.testing.expect(knows("--watch"));
    try std.testing.expect(!knows("--bogus"));
}

test "no flag is claimed by two rows of the same table" {
    inline for (.{ .{ SystemVerb, &system }, .{ ActionVerb, &actions }, .{ GlobalFlag, &globals } }) |pair| {
        const rows = pair[1];
        for (rows, 0..) |a, i| {
            for (a.flags) |fa| {
                for (rows[i + 1 ..]) |b| {
                    for (b.flags) |fb| try std.testing.expect(!std.mem.eql(u8, fa, fb));
                }
            }
        }
    }
}

test "every verb has exactly one row" {
    inline for (.{ .{ SystemVerb, &system }, .{ ActionVerb, &actions }, .{ GlobalFlag, &globals } }) |pair| {
        const Verb = pair[0];
        const rows = pair[1];
        for (std.enums.values(Verb)) |v| {
            var seen: usize = 0;
            for (rows) |r| {
                if (r.verb == v) seen += 1;
            }
            try std.testing.expectEqual(@as(usize, 1), seen);
        }
    }
    // flagFor's unreachable rests on the ActionVerb half of the above.
    try std.testing.expectEqualStrings("--grep", flagFor(.grep));
}

test "public rows carry help text, internal ones are excluded from it" {
    for (system) |r| {
        switch (r.visibility) {
            .public => try std.testing.expect(r.help.len > 0),
            .internal => try std.testing.expect(r.help.len == 0),
        }
    }
    for (actions) |r| try std.testing.expect(r.help.len > 0);
}

test "impliedAction resolves a scoped flag to its owner, and nothing else" {
    try std.testing.expectEqual(ActionVerb.run, impliedAction("--watch").?);
    try std.testing.expectEqual(ActionVerb.run, impliedAction("--outside").?);
    try std.testing.expectEqual(ActionVerb.grep, impliedAction("--all").?);
    try std.testing.expect(impliedAction("--wtach") == null);
    // An action flag is not "implied" - it names its verb outright, and the
    // caller finds it first.
    try std.testing.expect(impliedAction("--grep") == null);
}

test "a scoped flag is never also a row, or the hint would contradict the parser" {
    for (scoped) |s| {
        try std.testing.expect(systemVerb(s.flag) == null);
        try std.testing.expect(aliasAction(s.flag) == null);
        try std.testing.expect(!isGlobal(s.flag));
    }
}

test "writeMisplacedHint names the scope, and declines an unknown flag" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try std.testing.expect(try writeMisplacedHint(&w, "--watch"));
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "x <alias> --watch <cmd>") != null);

    w = .fixed(&buf);
    try std.testing.expect(try writeMisplacedHint(&w, "--list"));
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "takes no alias") != null);

    w = .fixed(&buf);
    try std.testing.expect(try writeMisplacedHint(&w, "--grep"));
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "after an alias") != null);

    // A real typo gets no invented advice.
    w = .fixed(&buf);
    try std.testing.expect(!try writeMisplacedHint(&w, "--wtach"));
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "spellings joins the accepted forms" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("--list, --ls, -l", spellings(&buf, system[0].flags));
    try std.testing.expectEqualStrings("--list-names", spellings(&buf, system[1].flags));
}

test "knows recognizes flags across system, action, and global tables" {
    // The safe_form lint requires knowing whether a flag is valid anywhere,
    // so all three tables and their short forms must answer affirmatively.
    try std.testing.expect(knows("--list"));
    try std.testing.expect(knows("-l"));
    try std.testing.expect(knows("--grep"));
    try std.testing.expect(knows("-g"));
    try std.testing.expect(knows("--force"));
    try std.testing.expect(knows("--no-prompt"));
    try std.testing.expect(knows("-j"));
    try std.testing.expect(!knows("--bogus"));
    try std.testing.expect(!knows("-q"));
    try std.testing.expect(!knows("bare_word"));
}
