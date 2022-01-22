const std = @import("std");

pub var terminalWidth: ?u16 = null;
pub var terminalHeight: ?u16 = null;
pub const maxBufLen = 10000;
pub fn fileExists(fname: []const u8) bool {
    if (std.fs.cwd().access(fname, .{})) {
        return true;
    } else |_| {
        return false;
    }
}
pub fn appendFile(fname: []const u8) !std.fs.File {
    var f = try std.fs.cwd().createFile(fname, std.fs.File.CreateFlags{ .truncate = false });
    try f.seekFromEnd(0);
    return f;
}
pub const IndentInfo = struct {
    const Self = @This();
    indent: u8,
    text: []u8,
    pub fn parseIndent(s: []u8) IndentInfo {
        var indent: u8 = 0;
        var i: u16 = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] == ' ')
                continue;
            if (s[i] == '-') {
                indent += 1;
            } else break;
        }
        return IndentInfo{
            .indent = indent,
            .text = s[i..],
        };
    }
};
var pageFileNameBuf: [maxBufLen]u8 = undefined;
pub fn pageFileName(title: []const u8) ![]const u8 {
    const s = try std.fmt.bufPrint(&pageFileNameBuf, "{s}.md", .{title});
    for (s) |*c| {
        if (c.* == '/')
            c.* = '|';
    }
    return s;
}
fn dbg(k: anytype) void {
    const writer = std.io.getStdOut().writer();
    if ((@TypeOf(k) == []const u8) or (@TypeOf(k) == []u8)) {
        writer.print("{s}\n", .{k}) catch unreachable;
    } else {
        writer.print("{any}\n", .{k}) catch unreachable;
    }
}

fn dbgs(s: []const u8, k: anytype) void {
    const writer = std.io.getStdOut().writer();
    writer.print("{s}=", .{s}) catch unreachable;
    dbg(k);
}

fn dbgc(k: anytype) void {
    @compileLog("", k);
}

fn dbgcs(s: anytype, k: anytype) void {
    @compileLog(s, k);
}
