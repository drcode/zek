const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const warn = std.debug.warn;
const assert = std.debug.assert;
const io = std.io;
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const Writer = std.fs.File.Writer;
const Reader = std.fs.File.Reader;
const zek = @import("zek.zig");

pub fn validate(allocator: *Allocator) !void {
    var headers = try zek.Headers.init(allocator);
    defer headers.deinit();
    var out = std.io.getStdOut().writer();
    var errorCount: u32 = 0;
    for (headers.items.items) |*header| {
        var tempPage = try zek.Page.init(allocator);
        defer tempPage.deinit();
        const name = header.title;
        try tempPage.load(name);
        {
            var i = tempPage.references.iterator();
            while (i.next()) |kv| {
                var otherPage = try zek.Page.init(allocator);
                defer otherPage.deinit();
                const otherName = kv.key_ptr.*;
                try otherPage.load(otherName);
                if (!otherPage.links.contains(name)) {
                    try out.print("Missing link {s} in page {s}\n", .{ name, otherName });
                    errorCount += 1;
                }
            }
        }
        {
            var i = tempPage.links.iterator();
            while (i.next()) |kv| {
                var otherPage = try zek.Page.init(allocator);
                defer otherPage.deinit();
                const otherName = kv.key_ptr.*;
                try otherPage.load(otherName);
                if (!otherPage.references.contains(name)) {
                    try out.print("Missing reference {s} in page {s}\n", .{ name, otherName });
                    errorCount += 1;
                }
            }
        }
    }
    try out.print("Found {any} validation errors.\n", .{errorCount});
    _ = allocator;
}
