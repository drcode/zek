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

fn isDate(text: []u8) bool {
    var i: usize = 0;
    {
        var found = false;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') {
            found = true;
            i += 1;
        }
        if (!found)
            return false;
    }
    if (i == text.len or text[i] != '/')
        return false;
    i += 1;
    {
        var found = false;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') {
            found = true;
            i += 1;
        }
        if (!found)
            return false;
    }
    if (i == text.len or text[i] != '/')
        return false;
    i += 1;
    {
        var found = false;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') {
            found = true;
            i += 1;
        }
        if (!found)
            return false;
    }
    return true;
}

pub fn validate(allocator: Allocator) !void {
    var headers = try zek.Headers.init(allocator);
    defer headers.deinit();
    var out = std.io.getStdOut().writer();
    var errorCount: u32 = 0;
    for (headers.items.items) |*header| {
        var tempPage = try zek.Page.init(allocator);
        defer tempPage.deinit();
        const name = header.title;
        try tempPage.load(headers.hashedItems, name);
        if (!isDate(name) and !std.mem.eql(u8, name, "help") and !std.mem.eql(u8, name, "help todo") and !std.mem.eql(u8, name, "todo") and tempPage.references.count() == 0) {
            try out.print("Page {s} is not a date page, but has no references.\n", .{name});
            errorCount += 1;
        }
        {
            var i = tempPage.references.iterator();
            while (i.next()) |kv| {
                var otherPage = try zek.Page.init(allocator);
                defer otherPage.deinit();
                const otherName = kv.key_ptr.*;
                try otherPage.load(headers.hashedItems, otherName);
                if (!otherPage.links.contains(name) and !(std.mem.eql(u8, otherName, "todo"))) {
                    try out.print("Missing link {s} in page {s}\n", .{ name, otherName });
                    errorCount += 1;
                }
                for (kv.value_ptr.items) |ref| {
                    var found = false;
                    for (otherPage.lines.items) |item| {
                        if (std.mem.eql(u8, item.text, ref)) {
                            found = true;
                        }
                    }
                    if (!found and !(std.mem.eql(u8, otherName, "todo"))) {
                        try out.print("The text in a reference from page {s} does not exist in the page {s}.\n", .{ name, otherName });
                        errorCount += 1;
                    }
                }
            }
        }
        {
            var i = tempPage.links.iterator();
            while (i.next()) |kv| {
                var otherPage = try zek.Page.init(allocator);
                defer otherPage.deinit();
                const otherName = kv.key_ptr.*;
                try otherPage.load(headers.hashedItems, otherName);
                if (!otherPage.references.contains(name)) {
                    try out.print("Missing reference {s} in page {s}\n", .{ otherName, name });
                    errorCount += 1;
                }
            }
        }
    }
    try out.print("Found {any} validation errors.\n", .{errorCount});
    _ = allocator;
}
