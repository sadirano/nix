//! Library root for the `nix` module: re-exports the tool's subsystems for
//! programmatic use. The CLI itself lives in main.zig.

pub const store = @import("store.zig");
pub const groups = @import("groups.zig");
pub const segments = @import("segments.zig");
pub const actions = @import("actions.zig");
pub const config = @import("config.zig");
pub const usage = @import("usage.zig");
pub const clipboard = @import("clipboard.zig");
pub const editor = @import("editor.zig");
pub const snippet = @import("snippet.zig");
pub const proc = @import("proc.zig");
pub const png = @import("png.zig");
pub const winpath = @import("winpath.zig");

test {
    // Compile-check the whole library surface in the module test binary (the
    // exe test binary references the same files through main.zig).
    @import("std").testing.refAllDecls(@This());
}
