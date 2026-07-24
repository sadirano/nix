//! Command specs - the single source of truth for nix's own documentation.
//!
//! One Spec per topic feeds three renderings at three depths: `nix --help`
//! (one line each), ~/.nix/AGENTS.md (the command table plus standing
//! guidance), and `<cmd> --agent` / `nix --agent <topic>` (the full spec).
//! Before this table the first two were hand-written copies of the same eight
//! rows and drifted apart; a new command could ship documented in one and
//! missing from the other. specForSlot is exhaustive over the shortcut slots
//! and a test asserts it, so that can't happen again.
//!
//! Agent-facing text uses CANONICAL forms (`nix <alias> --grep <pat>`), never
//! wrapper names: canonical flags are stable, while a wrapper name is whatever
//! [shortcuts] says it is on this machine. Only the lines addressed to the
//! user - suggest and examples - carry wrapper names, expanded from
//! `${cmd:<slot>}` placeholders at render time.

const std = @import("std");
const config = @import("config.zig");

/// Safety is the "can an agent run this itself?" tier. It is the first thing
/// a spec renders because it is the only field that changes what an agent
/// should DO rather than what it should know.
pub const Safety = enum {
    /// No picker, no GUI, no clipboard: an agent may run it unprompted.
    safe,
    /// Opens fzf. Without --no-prompt it hangs a non-interactive shell.
    blocks,
    /// Moves the user's shell, GUI, or clipboard. Ask before running it.
    user_surface,

    pub fn label(s: Safety) []const u8 {
        return switch (s) {
            .safe => "safe",
            .blocks => "blocks",
            .user_surface => "user-surface",
        };
    }

    pub fn note(s: Safety) []const u8 {
        return switch (s) {
            .safe => "No picker and no side effects on the user's desktop. Run it freely.",
            .blocks => "Opens an fzf picker and waits for a keypress, which hangs a non-interactive shell. Use the safe form below instead.",
            .user_surface => "Acts on something the user owns - their shell, a GUI window, or the clipboard. Don't run it unprompted; suggest it instead.",
        };
    }
};

/// Spec is one documented topic: a wrapper command, a system flag, or a
/// concept addressable by name (`nix --agent groups`).
pub const Spec = struct {
    /// Shortcut slot ("y") when this topic is a wrapper command, "" otherwise.
    /// Non-empty slots are exactly the rows --help and the AGENTS.md table show.
    slot: []const u8 = "",
    /// The name `--agent <topic>` matches. For wrappers this is the slot.
    topic: []const u8,
    /// Argument sketch rendered after the command name.
    args: []const u8 = "",
    /// One line. The only field --help and the AGENTS.md table consume.
    summary: []const u8,
    safety: Safety,
    /// The non-interactive invocation, when the plain form would block or act
    /// on the user's desktop. Empty when the command is already safe, or when
    /// no safe equivalent exists.
    safe_form: []const u8 = "",
    /// What it does and how the grammar works.
    detail: []const u8,
    /// How an agent should use it - or what to reach for instead.
    agent_use: []const u8,
    /// Phrasing to hand the user when suggesting it. Wrapper names allowed.
    suggest: []const u8 = "",
    /// Example invocations. Wrapper names allowed.
    examples: []const []const u8 = &.{},
    see_also: []const []const u8 = &.{},
    /// External tools the command needs, probed for the "On this machine"
    /// block. Names as they appear on PATH.
    needs_tools: []const []const u8 = &.{},
};

/// Facts is the live "On this machine" block, gathered by the caller so this
/// module stays pure and its renderers stay trivially testable. Every field is
/// optional: an empty Facts renders no block at all.
pub const Facts = struct {
    /// Tools from the topic's needs_tools that were NOT found on PATH.
    missing_tools: []const []const u8 = &.{},
    /// Registered alias count, when the topic is about aliases.
    alias_count: ?usize = null,
    /// Group names, when the topic is about groups.
    group_names: []const []const u8 = &.{},

    pub fn isEmpty(f: Facts) bool {
        return f.missing_tools.len == 0 and f.alias_count == null and f.group_names.len == 0;
    }
};

// ---- the table --------------------------------------------------------------

pub const specs = [_]Spec{
    .{
        .slot = "o",
        .topic = "o",
        .args = "<alias> [path]",
        .summary = "cd into the alias dir; bare `o` opens ~/.nix",
        .safety = .user_surface,
        .safe_form = "nix <alias>",
        .needs_tools = &.{"fzf"},
        .detail =
        \\Navigation. `o <alias>` changes the user's CURRENT shell to the alias
        \\dir. `o <alias> <path>` registers the alias to that path first (creating
        \\the directory) and then lands there. `o <seg>@<alias>` navigates to a
        \\sub-alias segment; `o +<group>` opens an fzf multi-select where the
        \\first pick keeps the current shell and the rest open new terminals.
        \\
        \\An unknown alias routes to a directory picker that REGISTERS it - `o` is
        \\how aliases get created, not just used.
        ,
        .agent_use =
        \\Don't run it. In your own shell it can only stack a subshell, which
        \\changes nothing the user sees and may leave you in a nested process.
        \\
        \\To get the path, run `nix <alias>` - it prints the absolute path and
        \\creates nothing. Inside a command started by `r`/`o`, $NIX_ALIAS and
        \\$NIX_ALIAS_PATH are already set, so no lookup is needed at all.
        ,
        .suggest = "Point the user at `${cmd:o} <alias>` when your work leaves them somewhere they'll want to be.",
        .examples = &.{
            "`${cmd:o} acme` - cd there",
            "`${cmd:o} acme ../new-project` - register and land in one step",
            "`nix acme` - what YOU should run instead",
        },
        .see_also = &.{ "--which", "segments" },
    },
    .{
        .slot = "e",
        .topic = "e",
        .args = "<alias> [file]",
        .summary = "open the dir (or a file) in your editor",
        .safety = .user_surface,
        .detail =
        \\Opens the alias dir, or one file under it, in the user's configured
        \\editor ([editor] in config.toml, else $EDITOR / $VISUAL). Bare `nix -e`
        \\opens ~/.nix itself for editing aliases and config.
        \\
        \\`e` is deliberately single-alias: it does not fan out over a +group.
        ,
        .agent_use =
        \\Don't run it - it spawns a GUI window and takes the user's focus.
        \\
        \\You already have file tools: resolve with `nix <alias>` and read or edit
        \\the file directly. Reach for `e` only in what you TELL the user.
        ,
        .suggest = "After changing code, name the entry point: `${cmd:e} <alias> src/main.zig`.",
        .examples = &.{
            "`${cmd:e} acme` - open the project",
            "`${cmd:e} acme src/server.zig` - open one file",
        },
        .see_also = &.{"o"},
    },
    .{
        .slot = "s",
        .topic = "s",
        .args = "<alias> [pat]",
        .summary = "open the dir in the file manager; with a pattern, pick files to open",
        .safety = .user_surface,
        .safe_form = "nix <alias> --no-prompt --explore <pat>",
        .needs_tools = &.{ "fzf", "fd" },
        .detail =
        \\Without a pattern, opens the alias dir in the OS file manager. With a
        \\pattern, fuzzy-finds under the dir and opens the picks with their
        \\default applications - PDFs in the PDF viewer, everything else in the
        \\editor. An exact filename short-circuits the picker and opens directly.
        ,
        .agent_use =
        \\Don't open things on the user's desktop unprompted. With a pattern it
        \\also blocks on fzf.
        \\
        \\The safe form prints the paths the picker would have offered and opens
        \\nothing, which makes it a usable "what matches this?" query.
        ,
        .suggest = "When your work produces a document to look at: `${cmd:s} <alias> report.pdf`.",
        .examples = &.{
            "`${cmd:s} acme` - open the folder",
            "`${cmd:s} acme invoice` - pick among matches, open the picks",
            "`nix acme --no-prompt --explore invoice` - list matches, open nothing",
        },
        .see_also = &.{ "ff", "y" },
    },
    .{
        .slot = "y",
        .topic = "y",
        .args = "<alias> [pat]",
        .summary = "copy the path; with a pattern, pick files and copy the files",
        .safety = .user_surface,
        .safe_form = "nix <alias>",
        .needs_tools = &.{ "fzf", "fd" },
        .detail =
        \\Bare `y <alias>` copies the alias's PATH as text. With a pattern it
        \\fuzzy-finds under the dir and copies the matched FILES themselves (a
        \\real file-manager clipboard payload, so they paste into Explorer or a
        \\mail client as attachments, not as text).
        ,
        .agent_use =
        \\Don't run it. The clipboard belongs to the user and may be holding
        \\something they're mid-way through using; silently replacing it is the
        \\kind of thing that loses work.
        \\
        \\If you want the path, `nix <alias>` prints it. To see what a pattern
        \\would match without touching the clipboard, use
        \\`nix <alias> --no-prompt --yank <pat>`.
        ,
        .suggest = "When the user will want to paste something elsewhere: `${cmd:y} <alias> <pat>`.",
        .examples = &.{
            "`${cmd:y} acme` - copy the path",
            "`${cmd:y} acme .pdf` - pick PDFs, copy the files",
            "`nix acme` - print the path, clipboard untouched",
        },
        .see_also = &.{ "p", "s" },
    },
    .{
        .slot = "p",
        .topic = "p",
        .args = "<alias> [name]",
        .summary = "save clipboard contents into the alias dir",
        .safety = .user_surface,
        .detail =
        \\Writes whatever the clipboard holds into the alias dir: text becomes a
        \\.txt file, an image becomes a .png, and copied FILES are copied in as
        \\files. An optional name sets the basename. `p +<group>` picks ONE
        \\member as the destination - a paste has exactly one target.
        ,
        .agent_use =
        \\Don't run it. It materializes files from state you can't inspect, into
        \\a directory the user cares about.
        \\
        \\If you need to create a file, write it directly - you know its contents,
        \\which is strictly better than pasting something unseen.
        ,
        .suggest = "When the user has just copied something they'll want saved: `${cmd:p} <alias> <name>`.",
        .examples = &.{
            "`${cmd:p} acme` - save the clipboard, auto-named",
            "`${cmd:p} acme design-notes` - save it under a name",
        },
        .see_also = &.{"y"},
    },
    .{
        .slot = "r",
        .topic = "r",
        .args = "<alias> <cmd...>",
        .summary = "run a command at the alias dir",
        .safety = .safe,
        .detail =
        \\Runs a command with the alias dir as the working directory, so nothing
        \\has to cd first. Canonical form: `nix <alias> --run <cmd...>`.
        \\
        \\Everything after --run is passed to the command VERBATIM, including
        \\flags that look like nix's own - `nix acme --run build --no-prompt`
        \\hands --no-prompt to build. nix's own flags must come before --run.
        \\
        \\`:<name>` runs a saved action from the project's .nix/actions.toml;
        \\`nix <alias> --run :` lists them. A bare name matching a file in
        \\.nix/scripts/ runs that script. The child gets $NIX_ALIAS and
        \\$NIX_ALIAS_PATH. `r +<group> <cmd>` fans the command across members.
        ,
        .agent_use =
        \\This is the command to reach for. It is safe, it is scriptable, and it
        \\removes the cd-then-run dance from anything you tell the user to do.
        \\
        \\When a project grows a recurring build/test/deploy command, add it to
        \\.nix/actions.toml under [actions] and hand the user `${cmd:r} <alias>
        \\:<name>` rather than the raw command line. See `--agent actions`.
        ,
        .suggest = "Give runnable work as an action, not a command line: `${cmd:r} <alias> :test`.",
        .examples = &.{
            "`${cmd:r} acme git status` - run at the project dir",
            "`${cmd:r} acme :deploy` - run a saved action",
            "`${cmd:r} +work git pull` - across every member of a group",
            "`nix acme --run zig build test` - the canonical form",
        },
        .see_also = &.{ "actions", "groups" },
    },
    .{
        .slot = "sg",
        .topic = "sg",
        .args = "<alias> <pat>",
        .summary = "ripgrep search under the alias dir (fzf UI)",
        .safety = .blocks,
        .safe_form = "nix <alias> --no-prompt --grep <pat>",
        .needs_tools = &.{ "rg", "fzf" },
        .detail =
        \\Streams ripgrep into fzf over `file:line:text` rows with a bat preview,
        \\and opens the picks in the editor at the matched line. `--all` searches
        \\via ripgrep-all instead, reaching inside PDFs, office docs and archives.
        \\`sg +<group> <pat>` searches every member in one picker, rows prefixed
        \\by alias.
        \\
        \\Search flags pass through to ripgrep: `nix acme --grep TODO -t zig`.
        ,
        .agent_use =
        \\The plain form blocks on fzf. The safe form runs the same ripgrep with
        \\the same flags and writes the rows to stdout instead, so you get the
        \\alias resolved and the search run in a single call.
        \\
        \\It is ordinary ripgrep underneath, with no extra filtering of its own -
        \\if you'd rather run rg yourself against `nix <alias>`, that is
        \\equivalent, and it is the better choice when you want flags this form
        \\doesn't reach.
        ,
        .suggest = "Leave follow-ups findable: `${cmd:sg} <alias> \"TODO(auth)\"`.",
        .examples = &.{
            "`${cmd:sg} acme TODO` - search and pick interactively",
            "`nix acme --no-prompt --grep TODO` - print matches, open nothing",
            "`nix acme --no-prompt --grep TODO -t zig` - ripgrep flags pass through",
        },
        .see_also = &.{ "ff", "groups" },
    },
    .{
        .slot = "ff",
        .topic = "ff",
        .args = "<alias> [pat]",
        .summary = "fuzzy-find files under the alias dir",
        .safety = .blocks,
        .safe_form = "nix <alias> --no-prompt --find <pat>",
        .needs_tools = &.{ "fzf", "fd" },
        .detail =
        \\Lists files under the alias dir (fd, else Everything's es on Windows,
        \\else POSIX find), picks in fzf with a preview, and opens the picks -
        \\default-app types via the OS handler, everything else in the editor.
        \\`ff +<group>` spans members, rows prefixed by alias.
        ,
        .agent_use =
        \\The plain form blocks on fzf. The safe form prints the matching paths
        \\and opens nothing.
        \\
        \\Paths print relative to the alias dir (and `alias\\rel` for a group),
        \\matching what the picker would show - join them onto `nix <alias>` when
        \\you need absolute paths.
        ,
        .suggest = "When the user is hunting for a file: `${cmd:ff} <alias> <pat>`.",
        .examples = &.{
            "`${cmd:ff} acme .zig` - pick among matches, open the picks",
            "`nix acme --no-prompt --find .zig` - print matches, open nothing",
        },
        .see_also = &.{ "sg", "s" },
    },

    // ---- system commands ----

    .{
        .topic = "--list",
        .args = "",
        .summary = "list every alias with its path",
        .safety = .safe,
        .detail =
        \\`nix --list` prints every alias and its resolved path.
        \\`nix --list-names` prints bare names, one per line - the form to parse.
        ,
        .agent_use =
        \\Run this BEFORE suggesting any alias, so you use the names the user
        \\actually has instead of inventing one. If nothing covers the directory
        \\you worked in, suggest registering it: `nix <name> <path>`.
        ,
        .examples = &.{
            "`nix --list` - names and paths",
            "`nix --list-names` - bare names, one per line",
        },
        .see_also = &.{ "--which", "o" },
    },
    .{
        .topic = "--which",
        .args = "[path]",
        .summary = "print the alias containing a path (default: cwd)",
        .safety = .safe,
        .detail =
        \\Reverse lookup: given a path, print the alias whose directory contains
        \\it. With no argument it uses the current directory.
        ,
        .agent_use =
        \\This is how you name the place you are working. After editing files in
        \\a repo, `nix --which` tells you the alias to put in your summary, so
        \\the user gets `${cmd:r} acme :test` instead of an absolute path.
        ,
        .examples = &.{
            "`nix --which` - the alias for the current directory",
            "`nix --which C:\\\\repo\\\\acme\\\\src` - the alias containing a path",
        },
        .see_also = &.{ "--list", "o" },
    },
    .{
        .topic = "--doctor",
        .args = "[-q]",
        .summary = "check tools/config and what the picker will use",
        .safety = .safe,
        .detail =
        \\Reports the external tools nix can find (fzf, rg, fd, es, bat), the
        \\config it loaded, PATH wiring, and which exclusion layers the picker
        \\will apply. `--doctor -q` keeps only problems and the summary.
        \\
        \\That -q is doctor's OWN quiet flag, unrelated to --no-prompt.
        ,
        .agent_use =
        \\Run it when a nix command behaved unexpectedly - a missing tool is the
        \\usual cause, and doctor names it directly instead of leaving you to
        \\infer it from a failure.
        ,
        .examples = &.{
            "`nix --doctor` - the full report",
            "`nix --doctor -q` - problems and summary only",
        },
        .see_also = &.{"state"},
    },
    .{
        .topic = "--secret",
        .args = "set|rm|list [NAME]",
        .summary = "manage ${secret:NAME} values used by actions",
        .safety = .user_surface,
        .detail =
        \\Stores named secrets in the Windows Credential Manager for actions to
        \\reference as ${secret:NAME}. The value is never written to
        \\actions.toml, so the file stays safe to commit.
        ,
        .agent_use =
        \\Write ${secret:NAME} into an action when it needs a credential, and
        \\tell the user to run `nix --secret set NAME` themselves.
        \\
        \\Never run `--secret set` for them: it would put the value in your
        \\transcript and in shell history, which is exactly what this indirection
        \\exists to prevent. `nix --secret list` (names only, no values) is safe.
        ,
        .suggest = "Tell the user to store it once: `nix --secret set DEPLOY_TOKEN`.",
        .examples = &.{
            "`nix --secret list` - names only, safe to run",
            "`nix --secret set DEPLOY_TOKEN` - the user runs this, not you",
        },
        .see_also = &.{"actions"},
    },
    .{
        .topic = "--sync-bin",
        .args = "",
        .summary = "install projects' [bin] exports into ~/.nix/bin",
        .safety = .safe,
        .detail =
        \\A project's .nix/actions.toml may declare [bin] entries pointing at
        \\built executables (`hoot = "zig-out/bin/hoot.exe"`). `nix --sync-bin`
        \\installs wrappers for them into ~/.nix/bin, which is on PATH, so the
        \\tool runs from anywhere by name.
        ,
        .agent_use =
        \\When a project builds a binary the user will want globally, add it
        \\under [bin] and tell them to run `nix --sync-bin` once. Re-running it
        \\after a rebuild is not needed - the wrapper points at the built path.
        ,
        .examples = &.{"`nix --sync-bin` - install every project's [bin] exports"},
        .see_also = &.{"actions"},
    },

    // ---- concepts ----

    .{
        .topic = "actions",
        .summary = "saved per-project commands (.nix/actions.toml)",
        .safety = .safe,
        .detail =
        \\A project's .nix/actions.toml holds named commands under [actions]:
        \\
        \\    [actions]
        \\    test = "zig build test"
        \\    deploy = "./scripts/deploy.ps1 --prod"
        \\
        \\They run as `nix <alias> --run :test`. Longer scripts go in
        \\.nix/scripts/ and run by bare name (`nix <alias> --run build`).
        \\Machine-wide personal actions live in ~/.nix/actions/_default.toml at
        \\lowest precedence, so they're available through any alias. Values may
        \\reference ${secret:NAME}; see `--agent --secret`.
        ,
        .agent_use =
        \\Prefer writing an action over handing the user a command line. It
        \\survives being forgotten, it works from any directory, and it gives the
        \\next agent a documented entry point.
        \\
        \\Creating .nix/actions.toml and .nix/scripts/ inside a project is
        \\encouraged - unlike ~/.nix state, these belong to the repo.
        ,
        .suggest = "Wire the command once, then reference it: `${cmd:r} <alias> :test`.",
        .examples = &.{
            "`${cmd:r} acme :` - list this project's actions",
            "`${cmd:r} acme :test` - run one",
        },
        .see_also = &.{ "r", "--secret", "--sync-bin" },
    },
    .{
        .topic = "groups",
        .summary = "multi-alias sets (+group) for fan-out",
        .safety = .safe,
        .detail =
        \\A group is a named set of aliases in ~/.nix/groups.toml, written with a
        \\leading `+`. Members are alias NAMES resolved on use, so a group
        \\follows its members when they move.
        \\
        \\    nix <member>+<group>        add a member (creates the group)
        \\    nix +<group> --list         list members
        \\    nix +<group> --remove       delete the group
        \\
        \\Commands fan out over a group: `r +work git pull` runs everywhere,
        \\`sg +work TODO` searches every member in one picker. Two deliberate
        \\exceptions: `e` stays single-alias, and `p +group` picks ONE
        \\destination.
        ,
        .agent_use =
        \\`nix --groups` lists groups; `nix +<group> --list` lists one group's
        \\members. Fan-out through `--run` is safe and is the good reason to
        \\reach for a group: one call to update or check every repo in a set.
        \\
        \\Group forms that open a picker (`o +group`, `p +group`) have no useful
        \\non-interactive behaviour and refuse to run under --no-prompt.
        ,
        .suggest = "For work spanning several repos: `${cmd:r} +work git pull`.",
        .examples = &.{
            "`nix --groups` - list groups",
            "`nix acme+work` - add acme to +work",
            "`${cmd:r} +work git status` - fan out a command",
        },
        .see_also = &.{ "r", "sg" },
    },
    .{
        .topic = "segments",
        .summary = "sub-alias paths (<seg>@<alias>) and context sources",
        .safety = .safe,
        .detail =
        \\`<seg>@<alias>` resolves a named sub-path under an alias - `docs@acme`
        \\might be the project's docs dir. Segments are defined per-alias in the
        \\project's .nix/segments.toml, or globally in ~/.nix/segments.toml.
        \\
        \\A [[contexts]] segment can compute its path by running a script
        \\(`run`), for cases where the target depends on state - the current
        \\sprint directory, today's log folder. Results are cached with a TTL.
        \\Because executing a script is a real side effect, a context source's
        \\bytes must be approved with `nix --trust <alias> [segment]` before its
        \\run will execute, and any edit to the script re-arms that prompt.
        ,
        .agent_use =
        \\`nix <seg>@<alias>` resolves and prints, like any alias. `nix
        \\--contexts` lists the global segments.
        \\
        \\Do not run `--trust` on the user's behalf. It is an approval gesture,
        \\and approving a script you just wrote defeats the check entirely.
        ,
        .examples = &.{
            "`nix docs@acme` - resolve a segment to its path",
            "`nix --contexts` - list global segments",
        },
        .see_also = &.{ "o", "state" },
    },
    .{
        .topic = "state",
        .summary = "what nix keeps in ~/.nix, and what not to touch",
        .safety = .safe,
        .detail =
        \\~/.nix holds aliases.toml (name -> path), groups.toml, config.toml
        \\([shortcuts], [editor], [nav], [notify]), usage (frecency, feeding
        \\--prune), segments.toml, picker.swept (picker exclusions), bin/ (the
        \\command wrappers plus [bin] exports, on PATH), and AGENTS.md - this
        \\guide's short form, regenerated by --sync.
        \\
        \\Every store nix owns is written atomically (temp + rename), and nix
        \\never rewrites files it doesn't own: --init doesn't touch shell
        \\profiles.
        ,
        .agent_use =
        \\Read these freely; don't write them. Registering an alias is `nix
        \\<name> <path>`, not an edit to aliases.toml - going through the command
        \\keeps usage and the wrapper set consistent.
        \\
        \\Never delete or hand-edit ~/.nix contents unless the user explicitly
        \\asks. Project-local .nix/ directories are the opposite: creating
        \\actions.toml, scripts/, and segments.toml there is encouraged.
        ,
        .examples = &.{
            "`nix acme C:\\\\repo\\\\acme` - register an alias the supported way",
            "`nix --export backup.toml` - portable backup of aliases/groups/config",
        },
        .see_also = &.{ "--doctor", "actions" },
    },
};

// ---- lookup -----------------------------------------------------------------

pub fn find(topic: []const u8) ?*const Spec {
    for (&specs) |*s| {
        if (std.mem.eql(u8, s.topic, topic)) return s;
        // `--agent list` and `--agent --list` both reach the same spec.
        if (std.mem.startsWith(u8, s.topic, "--") and std.mem.eql(u8, s.topic[2..], topic)) return s;
    }
    return null;
}

/// wrapperSpecs returns the shortcut-slot rows in declaration order - the eight
/// that --help and the AGENTS.md table render.
pub fn wrapperSpecs(buf: *[8]*const Spec) []*const Spec {
    var n: usize = 0;
    for (&specs) |*s| {
        if (s.slot.len == 0) continue;
        buf[n] = s;
        n += 1;
    }
    return buf[0..n];
}

// ---- rendering --------------------------------------------------------------

/// expand substitutes `${cmd:<slot>}` with this machine's effective command
/// name. Text with no placeholder is returned as-is (no allocation).
pub fn expand(arena: std.mem.Allocator, cfg: config.Config, text: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, text, "${cmd:") == null) return text;
    var b: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const at = std.mem.indexOfPos(u8, text, i, "${cmd:") orelse {
            try b.appendSlice(arena, text[i..]);
            break;
        };
        try b.appendSlice(arena, text[i..at]);
        const close = std.mem.indexOfScalarPos(u8, text, at, '}') orelse {
            try b.appendSlice(arena, text[at..]);
            break;
        };
        try b.appendSlice(arena, config.shortcutFor(cfg, text[at + 6 .. close]));
        i = close + 1;
    }
    return b.items;
}

/// renderTopic writes one spec in full - the `<cmd> --agent` payload.
pub fn renderTopic(arena: std.mem.Allocator, cfg: config.Config, s: *const Spec, facts: Facts) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    const name = if (s.slot.len > 0) config.shortcutFor(cfg, s.slot) else s.topic;

    if (s.args.len > 0) {
        try b.print(arena, "# {s} {s}\n\n{s}\n\n", .{ name, s.args, s.summary });
    } else {
        try b.print(arena, "# {s}\n\n{s}\n\n", .{ name, s.summary });
    }

    try b.print(arena, "**Agent safety: {s}.** {s}\n\n", .{ s.safety.label(), s.safety.note() });
    if (s.safe_form.len > 0) {
        try b.print(arena, "**Safe form:** `{s}`\n\n", .{s.safe_form});
    }

    try b.print(arena, "## What it does\n\n{s}\n\n", .{try expand(arena, cfg, s.detail)});
    try b.print(arena, "## Using it yourself\n\n{s}\n\n", .{try expand(arena, cfg, s.agent_use)});

    if (s.suggest.len > 0) {
        try b.print(arena, "## Suggesting it to the user\n\n{s}\n\n", .{try expand(arena, cfg, s.suggest)});
    }
    if (s.examples.len > 0) {
        try b.appendSlice(arena, "## Examples\n\n");
        for (s.examples) |ex| try b.print(arena, "- {s}\n", .{try expand(arena, cfg, ex)});
        try b.appendSlice(arena, "\n");
    }
    if (s.see_also.len > 0) {
        try b.appendSlice(arena, "## See also\n\n");
        for (s.see_also, 0..) |sa, i| {
            if (i > 0) try b.appendSlice(arena, ", ");
            try b.print(arena, "`nix --agent {s}`", .{sa});
        }
        try b.appendSlice(arena, "\n\n");
    }
    if (!facts.isEmpty()) {
        try b.appendSlice(arena, "## On this machine\n\n");
        for (facts.missing_tools) |t| {
            try b.print(arena, "- `{s}` is NOT on PATH; this command can't fully run until it is\n", .{t});
        }
        if (facts.alias_count) |n| try b.print(arena, "- {d} alias(es) registered (`nix --list-names`)\n", .{n});
        if (facts.group_names.len > 0) {
            try b.appendSlice(arena, "- groups: ");
            for (facts.group_names, 0..) |g, i| {
                if (i > 0) try b.appendSlice(arena, ", ");
                try b.print(arena, "+{s}", .{g});
            }
            try b.appendSlice(arena, "\n");
        }
        try b.appendSlice(arena, "\n");
    }
    return b.items;
}

/// renderIndex lists every topic - the payload of a bare `nix --agent`.
pub fn renderIndex(arena: std.mem.Allocator, cfg: config.Config) ![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(arena,
        \\# nix agent specs
        \\
        \\Every topic below has a full spec: `nix --agent <topic>`. Wrapper
        \\commands also answer to `<cmd> --agent` directly.
        \\
        \\Each spec states whether an agent may run the command itself, and gives
        \\the non-interactive form when there is one. The short standing guide is
        \\~/.nix/AGENTS.md.
        \\
        \\## Commands
        \\
        \\
    );
    for (&specs) |*s| {
        if (s.slot.len == 0) continue;
        try b.print(arena, "- `{s}` - {s} [{s}]\n", .{
            config.shortcutFor(cfg, s.slot), s.summary, s.safety.label(),
        });
    }
    try b.appendSlice(arena, "\n## System\n\n");
    for (&specs) |*s| {
        if (s.slot.len > 0 or !std.mem.startsWith(u8, s.topic, "--")) continue;
        try b.print(arena, "- `{s}` - {s}\n", .{ s.topic, s.summary });
    }
    try b.appendSlice(arena, "\n## Concepts\n\n");
    for (&specs) |*s| {
        if (s.slot.len > 0 or std.mem.startsWith(u8, s.topic, "--")) continue;
        try b.print(arena, "- `{s}` - {s}\n", .{ s.topic, s.summary });
    }
    try b.appendSlice(arena, "\n");
    return b.items;
}

// ---- tests ------------------------------------------------------------------

test "every shortcut slot has a spec" {
    for (config.builtinShortcuts()) |b| {
        try std.testing.expect(find(b.builtin) != null);
    }
    var buf: [8]*const Spec = undefined;
    try std.testing.expectEqual(@as(usize, 8), wrapperSpecs(&buf).len);
}

test "expand substitutes effective command names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = config.Config{ .shortcuts = &.{.{ .builtin = "r", .custom = "run" }} };
    try std.testing.expectEqualStrings("run acme :test", try expand(arena, cfg, "${cmd:r} acme :test"));
    // Unrenamed slots fall back to the slot name; text without a placeholder
    // is passed straight through.
    try std.testing.expectEqualStrings("sg acme TODO", try expand(arena, cfg, "${cmd:sg} acme TODO"));
    try std.testing.expectEqualStrings("no placeholder", try expand(arena, cfg, "no placeholder"));
}

test "renderTopic honours renames and states safety" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg = config.Config{ .shortcuts = &.{.{ .builtin = "y", .custom = "yank" }} };
    const out = try renderTopic(arena, cfg, find("y").?, .{});
    try std.testing.expect(std.mem.startsWith(u8, out, "# yank <alias> [pat]"));
    try std.testing.expect(std.mem.indexOf(u8, out, "**Agent safety: user-surface.**") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "**Safe form:** `nix <alias>`") != null);
    // The suggest line carries the renamed wrapper, not the slot name.
    try std.testing.expect(std.mem.indexOf(u8, out, "`yank <alias> <pat>`") != null);
}

test "renderTopic emits machine facts only when present" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const bare = try renderTopic(arena, .{}, find("sg").?, .{});
    try std.testing.expect(std.mem.indexOf(u8, bare, "On this machine") == null);

    const with = try renderTopic(arena, .{}, find("sg").?, .{ .missing_tools = &.{"rg"} });
    try std.testing.expect(std.mem.indexOf(u8, with, "`rg` is NOT on PATH") != null);
}

test "find matches system topics with and without dashes" {
    try std.testing.expect(find("--list") != null);
    try std.testing.expect(find("list") == find("--list"));
    try std.testing.expect(find("nope") == null);
}

test "index lists every topic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try renderIndex(arena_state.allocator(), .{});
    for (&specs) |*s| {
        try std.testing.expect(std.mem.indexOf(u8, out, s.summary) != null);
    }
}
