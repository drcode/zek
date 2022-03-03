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
const Term = std.ChildProcess.Term;
const util = @import("util.zig");
const time = @import("time.zig");
const validator = @import("validator.zig");

const includeTodoModule = false;
const todoModule = (if (includeTodoModule) //The todo module is an experimental module not currently supported and is disabled
    @import("todo_experimental.zig")
else
    undefined);

const maxBufLen = 10000;
const maxLinkLen = 1000;
//Headers is an ArrayList of all the names of the pages in the system. They are available in memory for querying at all times (unlike the bodies of the pages, which are only loaded on demand)
pub const Headers = struct {
    const Self = @This();
    const Header = struct {
        title: []u8,
        marked: bool,
        connections: u32,
    };
    var tempBuf: [maxBufLen]u8 = undefined;
    allocator: *std.heap.ArenaAllocator,
    parentAllocator: Allocator,
    items: std.ArrayList(Header),
    hashedItems: std.StringHashMap(usize),
    fn allocTextNoExtension(allocator: Allocator, s: []const u8) ![]u8 {
        var extensionIndex: u8 = 0;
        while (extensionIndex < s.len) : (extensionIndex += 1) {
            if (s[extensionIndex] == '.')
                break;
        }
        const sCopy = try allocator.alloc(u8, extensionIndex);
        mem.copy(u8, sCopy, s[0..extensionIndex]);
        return sCopy;
    }
    fn allocText(self: *Self, s: []const u8) ![]u8 {
        const sCopy = try self.allocator.allocator.alloc(u8, s.len);
        mem.copy(u8, sCopy, s);
        return sCopy;
    }
    pub fn init(parentAllocator: Allocator) !Self {
        var allocator = try parentAllocator.create(std.heap.ArenaAllocator);
        allocator.* = std.heap.ArenaAllocator.init(parentAllocator);
        const dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
        var iterator = dir.iterate();
        var items = std.ArrayList(Header).init(allocator.allocator());
        var hashedItems = std.StringHashMap(usize).init(allocator.allocator());
        while (try iterator.next()) |item| {
            const len = item.name.len;
            if (len >= 4 and std.mem.eql(u8, item.name[len - 3 ..], ".md")) {
                const title = try allocTextNoExtension(allocator.allocator(), item.name);
                for (title) |*c| {
                    if (c.* == '|')
                        c.* = '/';
                }
                try items.append(Header{
                    .title = title,
                    .marked = false,
                    .connections = undefined,
                });
                try hashedItems.put(title, items.items.len - 1);
            }
        }
        return Self{
            .parentAllocator = parentAllocator,
            .allocator = allocator,
            .items = items,
            .hashedItems = hashedItems,
        };
    }
    pub fn deinit(self: Self) void {
        self.allocator.deinit();
        self.parentAllocator.destroy(self.allocator);
    }
    fn print(self: Self, out: anytype) !void {
        for (self.items.items) |item| {
            try out.print("{s}\n", .{item});
        }
    }
    pub fn append(self: *Self, text: []const u8) !usize {
        const s = try std.ascii.allocLowerString(self.allocator.allocator(), text);
        try self.items.append(Header{
            .title = s,
            .marked = false,
            .connections = undefined,
        });
        try self.hashedItems.put(s, self.items.items.len - 1);
        return self.items.items.len - 1;
    }
    fn markByQuery(self: *Self, query: []const u8) u16 {
        var numMarked: u16 = 0;
        for (self.items.items) |*header| {
            if (contains(query, header.title)) {
                numMarked += 1;
                header.marked = true;
            } else header.marked = false;
        }
        return numMarked;
    }
    pub fn find(self: *Self, query: []const u8) ?usize {
        return self.hashedItems.get(query);
    }
    fn remove(self: *Self, i: usize) void {
        _ = self.hashedItems.remove(self.items.items[i].title);
        _ = self.items.orderedRemove(i);
    }
    fn sortByConnections(context: void, a: Header, b: Header) bool {
        _ = context;
        return b.connections < a.connections;
    }
};
fn forEachLink(context: anytype, comptime fun: anytype, s: []const u8) !void { //Modified means we will need to update backlinks (in other md files) during saving
    var link: [maxLinkLen]u8 = undefined;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '[') {
            var j = i + 1;
            while (j < s.len and s[j] != ']') : (j += 1) {}
            const linkSlice = std.ascii.lowerString(link[0..], s[i + 1 .. j]);
            try fun(context, linkSlice, (j == s.len));
            i = j + 1;
        } else i += 1;
    }
}
pub const Page = struct {
    const Self = @This();
    const Line = struct {
        indent: u8,
        text: []u8,
    };
    const Reference = std.ArrayList([]u8);
    var tempBuf: [maxBufLen]u8 = undefined;
    allocator: *std.heap.ArenaAllocator,
    parentAllocator: Allocator,
    lines: std.ArrayList(Line),
    references: std.StringHashMap(Reference),
    links: std.StringHashMap(bool), //the bool indicates if the link has been modified
    modified: bool,
    pub fn init(parentAllocator: Allocator) !Self {
        var allocator = try parentAllocator.create(std.heap.ArenaAllocator);
        allocator.* = std.heap.ArenaAllocator.init(parentAllocator);
        return Self{
            .parentAllocator = parentAllocator,
            .allocator = allocator,
            .lines = std.ArrayList(Line).init(allocator.allocator()),
            .references = std.StringHashMap(Reference).init(allocator.allocator()),
            .links = std.StringHashMap(bool).init(allocator.allocator()),
            .modified = false,
        };
    }
    pub fn deinit(self: Self) void {
        self.allocator.deinit();
        self.parentAllocator.destroy(self.allocator);
    }
    fn allocText(self: *Self, s: []const u8) ![]u8 {
        const sCopy = try self.allocator.allocator().alloc(u8, s.len);
        mem.copy(u8, sCopy, s);
        return sCopy;
    }
    fn gatherLink(context: struct { self: *Self, modified: bool }, link: []const u8, terminating: bool) !void {
        _ = terminating;
        const self = context.self;
        const myLink = try self.allocText(link);
        const k = try self.links.getOrPut(myLink);
        if (k.found_existing) {
            k.value_ptr.* = k.value_ptr.* or context.modified;
        } else {
            k.value_ptr.* = context.modified;
        }
    }
    fn injectLink(context: struct { self: Self, text: []const u8 }, link: []const u8, terminating: bool) !void {
        _ = terminating;
        if (includeTodoModule) {
            assert(!std.mem.eql(u8, link, "todo"));
        }
        if (!context.self.links.get(link).?)
            return;
        var f = try util.appendFile(try util.pageFileName(link));
        defer f.close();
        try f.writer().print("- - {s}\n", .{context.text});
    }
    fn append(self: *Self, indent: u8, s: []const u8, modified: bool) !void {
        var fixedIndent = indent;
        if (self.lines.items.len > 0 and self.lines.items[self.lines.items.len - 1].indent < indent - 1) { //User is overindenting, let's fix and hope for the best
            fixedIndent = self.lines.items[self.lines.items.len - 1].indent + 1;
        }
        try self.lines.append(Line{
            .indent = fixedIndent,
            .text = try self.allocText(s),
        });
        try forEachLink(.{ .self = self, .modified = modified }, gatherLink, s);
    }
    fn insert(self: *Self, index: usize, indent: u8, s: []u8) !void {
        try self.lines.insert(index, Line{
            .indent = indent,
            .text = try self.allocText(s),
        });
        try forEachLink(.{ .self = self, .modified = true }, gatherLink, s);
        self.modified = true;
    }
    fn update(self: *Self, index: usize, text: []const u8) !void {
        //try forEachLink(.{ .self = self, .modified = true }, gatherLink, self.lines.items[index].text);
        try forEachLink(.{ .self = self, .modified = true }, gatherLink, self.lines.items[index].text);
        self.lines.items[index].text = try self.allocText(text);
        try forEachLink(.{ .self = self, .modified = true }, gatherLink, self.lines.items[index].text);
        self.modified = true;
    }
    fn delete(self: *Self, index: usize) !void {
        try forEachLink(.{ .self = self, .modified = true }, gatherLink, self.lines.items[index].text);
        _ = self.lines.orderedRemove(index);
        self.modified = true;
    }
    fn swapLines(self: *Self, startA: usize, startB: usize, length: usize) void {
        var i: usize = 0;
        while (i < length) : (i += 1) {
            std.mem.swap(Line, &self.lines.items[startA + i], &self.lines.items[startB + i]);
        }
    }
    fn rotateLines(self: *Self, start: usize, middle: usize, end: usize) void { //swaps the (start,middle) section and (middle,end) section. The sections may be of different lengths.
        const len1 = middle - start;
        const len2 = end - middle;
        if (len1 == 0 or len2 == 0)
            return;
        if (len1 == len2) {
            self.swapLines(start, middle, len1);
        } else if (len1 < len2) {
            const middle2 = end - len1;
            self.swapLines(start, middle2, len1);
            self.rotateLines(start, middle, middle2);
        } else {
            const middle1 = start + len2;
            self.swapLines(start, middle, len2);
            self.rotateLines(middle1, middle, end);
        }
    }
    fn outdent(self: *Self, index: usize) void {
        const items = self.lines.items;
        const indent = items[index].indent;
        if (indent <= 1)
            return;
        var end = index + 1;
        while (end < items.len and items[end].indent > indent) : (end += 1) {}
        var swapEnd = end;
        while (swapEnd < items.len and items[swapEnd].indent >= indent) : (swapEnd += 1) {}
        var i = index;
        while (i < end) : (i += 1) {
            items[i].indent -= 1;
        }
        self.rotateLines(index, end, swapEnd);
        self.modified = true;
    }
    fn indentLine(self: *Self, index: usize) void {
        const items = self.lines.items;
        const indent = items[index].indent;
        items[index].indent += 1;
        var i = index + 1;
        while (i < items.len and items[i].indent > indent) : (i += 1) {
            items[i].indent += 1;
        }
        self.modified = true;
    }
    fn up(self: *Self, index: usize) void {
        const items = self.lines.items;
        const indent = items[index].indent;
        assert(index > 0);
        var start = index - 1;
        while (items[start].indent > indent) : (start -= 1) {}
        assert(items[start].indent == indent);
        var end = index + 1;
        while (end < items.len and items[end].indent > indent) : (end += 1) {}
        self.rotateLines(start, index, end);
        self.modified = true;
    }
    fn down(self: *Self, index: usize) void {
        const items = self.lines.items;
        const indent = items[index].indent;
        var end = index + 1;
        while (end < items.len and items[end].indent > indent) : (end += 1) {}
        assert(items[end].indent == indent);
        var swapEnd = end + 1;
        while (swapEnd < items.len and items[swapEnd].indent > indent) : (swapEnd += 1) {}
        self.rotateLines(index, end, swapEnd);
        self.modified = true;
    }
    fn appendReference(self: *Self, title: []const u8) !void {
        var texts = std.ArrayList([]u8).init(self.allocator.allocator());
        _ = try self.references.getOrPutValue(try self.allocText(title), texts);
    }
    fn appendReferenceEntry(self: *Self, title: []const u8, entry: []const u8) !void {
        const ent = self.references.getEntry(title).?;
        try ent.value_ptr.*.append(try self.allocText(entry));
    }
    fn readLine(f: Reader) !?[]u8 {
        return try f.readUntilDelimiterOrEof(&tempBuf, '\n');
    }
    pub fn load(self: *Self, hashedTitles: std.StringHashMap(usize), title: []const u8) !void {
        _ = hashedTitles;
        try self.append(0, title, false);
        const fname = try util.pageFileName(title);
        if (util.fileExists(fname)) {
            const f = try std.fs.cwd().openFile(fname, .{});
            defer f.close();
            const reader = f.reader();
            while (try readLine(reader)) |line| {
                const info = util.IndentInfo.parseIndent(line);
                if (info.indent == 0 and std.mem.eql(u8, info.text, "__references"))
                    break;
                try self.append(info.indent + 1, info.text, false);
            }
            var futureLine = try readLine(reader);
            if (futureLine != null) {
                while (futureLine) |line| { //now processing references
                    const refTitleInfo = util.IndentInfo.parseIndent(line);
                    assert(refTitleInfo.indent == 1);
                    const refTitle = try self.allocText(refTitleInfo.text);
                    var texts = std.ArrayList([]u8).init(self.allocator.allocator());
                    while (true) {
                        futureLine = try readLine(reader);
                        if (futureLine) |refLine| {
                            const info = util.IndentInfo.parseIndent(refLine);
                            if (info.indent == 1)
                                break;
                            assert(info.indent == 2);
                            try texts.append(try self.allocText(info.text));
                        } else {
                            break;
                        }
                    }
                    if (texts.items.len > 0 and hashedTitles.contains(refTitle)) { //The reference is not an empty reference, and the referred item was not previously renamed/deleted
                        try self.references.put(refTitle, texts);
                    } else {
                        _ = self.references.remove(refTitle);
                        texts.deinit();
                    }
                }
            }
        }
    }
    pub fn save(self: Self) !void {
        if (!self.modified)
            return;
        const title = self.lines.items[0].text;
        {
            var f = try std.fs.cwd().createFile(try util.pageFileName(title), std.fs.File.CreateFlags{ .truncate = true });
            defer f.close();
            const writer = f.writer();
            try self.printFile(writer);
            if (includeTodoModule) {
                if (!std.mem.eql(u8, title, "todo"))
                    try writer.print("__references\n", .{});
            } else {
                try writer.print("__references\n", .{});
            }
            var i = self.references.iterator();
            while (i.next()) |kv| {
                try writer.print("- {s}\n", .{kv.key_ptr.*});
                for (kv.value_ptr.items) |text| {
                    try writer.print("- - {s}\n", .{text});
                }
            }
        }
        {
            //Whenever we save a page, we traverse all other pages it references to add backlinks in the files of those pages in an optimized way: We simply append the references to the other file for speed, which can cause repeated/conflicting references in that file. However, whenever that page is loaded in the future the duplicate references will be fixed during loading.
            var i = self.links.iterator();
            while (i.next()) |kv| {
                if (!kv.value_ptr.*)
                    continue;
                const fname = try util.pageFileName(kv.key_ptr.*);
                const fileExisted = util.fileExists(fname);
                var f = try util.appendFile(fname);
                defer f.close();
                if (!fileExisted) {
                    try f.writer().print("__references\n", .{});
                }
                try f.writer().print("- {s}\n", .{title});
            }
        }
        for (self.lines.items) |line| {
            try forEachLink(.{ .text = line.text, .self = self }, injectLink, line.text);
        }
    }
    fn printReferences(self: Self, out: *OutputManager) !void {
        if (self.references.count() == 0)
            return;
        const title = self.lines.items[0].text;
        out.startLine(2);
        try out.print("<< {s} >>", .{title});
        try out.endLine();
        var i = self.references.iterator();
        while (i.next()) |kv| {
            if (kv.value_ptr.items.len > 0) {
                out.startLine(2);
                try out.print("[{s}]", .{kv.key_ptr.*});
                try out.endLine();
                for (kv.value_ptr.items) |text| {
                    out.startLine(2);
                    try out.print("- {s}", .{text});
                    try out.endLine();
                }
            }
        }
    }
    fn printLineTree(self: Self, out: *OutputManager, index: usize, indent: u8, numbered: bool, clipboard: ?usize) std.os.WriteError!usize { //This function prints all subsequent lines starting at the given index that have the same indent, using recursion to print children
        const items = self.lines.items;
        var curIndex = index;
        var number: u16 = 1;
        while (curIndex < items.len) {
            var item = items[curIndex];
            if (item.indent < indent)
                return curIndex;
            assert(item.indent == indent);
            out.startLine(if (numbered)
                1 + indent * 2
            else if (indent < 2)
                2
            else
                (indent - 1) * 2);
            var i: u8 = if (numbered)
                0
            else
                1;
            while (i < indent) : (i += 1) {
                if (i + 1 == indent) {
                    if (numbered)
                        try out.print("{:>2} ", .{number})
                    else
                        try out.print("- ", .{});
                } else try out.print("  ", .{});
            }
            if (clipboard) |c| {
                if (c == curIndex)
                    try out.print("*", .{});
            }
            try out.print("{s}", .{item.text});
            out.endLine() catch unreachable;
            number += 1;
            curIndex = try self.printLineTree(out, curIndex + 1, indent + 1, numbered, clipboard);
        }
        return curIndex;
    }
    fn printLineTreeFile(self: Self, out: Writer, index: usize, indent: u8) std.os.WriteError!usize { //This function prints all subsequent lines starting at the given index that have the same indent, using recursion to print children
        const items = self.lines.items;
        var curIndex = index;
        while (curIndex < items.len) {
            var item = items[curIndex];
            if (item.indent < indent)
                return curIndex;
            assert(item.indent == indent);
            var i: u8 = 1;
            while (i < indent) : (i += 1) {
                try out.print("- ", .{});
            }
            try out.print("{s}\n", .{item.text});
            curIndex = try self.printLineTreeFile(out, curIndex + 1, indent + 1);
        }
        return curIndex;
    }
    fn print(self: Self, out: *OutputManager, numbered: bool, clipboard: ?usize) !void {
        out.startLine(2);
        try out.print("<< {s} >>", .{self.lines.items[0].text});
        try out.endLine();
        _ = try self.printLineTree(out, 1, 1, numbered, clipboard);
    }
    fn printFile(self: Self, out: Writer) !void {
        _ = try self.printLineTreeFile(out, 1, 1);
    }
    fn navigateChildIndex(self: Self, index: usize, childIndex: u16) ?usize {
        const items = self.lines.items;
        const targetIndent = items[index].indent + 1;
        var curIndex = index + 1;
        var ci = childIndex;
        while (curIndex < self.lines.items.len) : (curIndex += 1) {
            if (items[curIndex].indent == targetIndent) {
                if (ci == 0) {
                    return curIndex;
                }
                ci -= 1;
            }
        }
        return null;
    }
    fn resolveLinePath(self: Self, path: []const u8) ?usize {
        var index: usize = 0;
        var longForm = false;
        for (path) |c| {
            if (c == '.')
                longForm = true;
        }
        if (longForm) {
            var start: usize = 0;
            var i: usize = 0;
            while (true) {
                while (i < path.len and path[i] != '.') : (i += 1) {}
                var s = path[start..i];
                var n = fmt.parseUnsigned(u16, s, 10) catch {
                    @panic("bad path");
                };
                if (self.navigateChildIndex(index, n - 1)) |x| {
                    index = x;
                } else {
                    return null;
                }
                while (i < path.len and path[i] == '.') : (i += 1) {}
                start = i;
                if (i >= path.len)
                    break;
                i += 1;
            }
        } else {
            for (path) |c| {
                if (self.navigateChildIndex(index, c - '0' - 1)) |x| {
                    index = x;
                } else {
                    return null;
                }
            }
        }
        return index;
    }
    fn wordNumberIndex(s: []u8, numberIndex: u16) usize { //given the word number in a string, returns the index in the string at the beginning of the word
        var n: u16 = 1;
        var separator = true;
        var i: usize = 0;
        for (s) |c| {
            if (c == ' ' or c == ',' or c == '(' or c == ')') {
                separator = true;
            } else {
                if (separator) {
                    if (n == numberIndex)
                        return i;
                    n += 1;
                    separator = false;
                }
            }
            i += 1;
        }
        return i;
    }
    fn printWordNumbers(out: Writer, s: []u8) !u16 {
        var n: u16 = 1;
        var separator = true;
        var slop: usize = 0; //used to keep track of extra chars for word ids that need multple characters (i.e. are greater than 9)
        for (s) |c| {
            if (c == ' ' or c == ',' or c == '(' or c == ')') {
                separator = true;
                if (slop > 0) {
                    slop -= 1;
                } else {
                    try out.print(" ", .{});
                }
            } else {
                if (separator) {
                    try out.print("{any}", .{n});
                    n += 1;
                    if (n >= 11) {
                        slop += 1;
                    }
                    if (n >= 101) {
                        slop += 1;
                    }
                    separator = false;
                } else {
                    if (slop > 0) {
                        slop -= 1;
                    } else {
                        try out.print(" ", .{});
                    }
                }
            }
        }
        try out.print("\n", .{});
        return n + 1;
    }
    fn smartRenameSelf(self: *Self, hashedTitles: std.StringHashMap(usize), oldText: []u8, newText: []u8) !void { //The page has been renamed, need to fix all links/references to the page. Page is out of date after the process is complete and should no longer be accessed
        {
            var i = self.links.iterator();
            while (i.next()) |kv| {
                kv.value_ptr.* = true;
            }
        }
        try self.save();
        {
            var i = self.references.iterator();
            while (i.next()) |kv| {
                const ref = kv.key_ptr.*;
                var tempPage = try Page.init(self.allocator.allocator());
                defer tempPage.deinit();
                try tempPage.load(hashedTitles, ref);
                try tempPage.smartRenameLink(oldText, newText);
                try tempPage.save();
            }
        }
    }
    fn smartRenameLink(self: *Self, oldText: []u8, newText: []u8) !void { //A link in this page has been renamed, need to fix link text and all references. Page is out of date after the process is complete and should no longer be accessed
        for (self.lines.items) |line, index| {
            var found = false;
            var s: []u8 = tempBuf[0..0];
            var i: usize = 0;
            while (i < line.text.len) {
                if (line.text[i] == '[') {
                    s.len += 1;
                    s[s.len - 1] = '[';
                    var j = i + 1;
                    while (j < line.text.len and line.text[j] != ']') {
                        j += 1;
                    }
                    if (std.mem.eql(u8, line.text[i + 1 .. j], oldText)) {
                        const k = s.len;
                        s.len += newText.len;
                        std.mem.copy(u8, s[k..], newText);
                        found = true;
                    } else {
                        const k = s.len;
                        s.len += j - i - 1;
                        std.mem.copy(u8, s[k..], line.text[i + 1 .. j]);
                    }
                    s.len += 1;
                    s[s.len - 1] = ']';
                    i = j + 1;
                } else {
                    s.len += 1;
                    s[s.len - 1] = line.text[i];
                    i += 1;
                }
            }
            if (found) {
                try self.update(index, s);
            }
        }
        self.modified = true;
    }
};

const Action = struct {
    const Command = enum {
        append,
        back,
        insert,
        goto,
        quit,
        view,
        edit,
        outdent,
        indent,
        up,
        down,
        delete,
        sync,
        todo,
        move,
        inject,
        merge,
        write,
        help,
        overview,
        yeet,
        skip,
    };
    command: Command,
    arg: []const u8,
    fn fromString(s: []u8) ?Action {
        if (s.len == 0) {
            return Action{ .command = .skip, .arg = undefined };
        }
        switch (s[0]) {
            'a' => return Action{
                .command = .append,
                .arg = undefined,
            },
            'b' => return Action{
                .command = .back,
                .arg = undefined,
            },
            'i' => return Action{
                .command = .insert,
                .arg = s[1..],
            },
            'q' => return Action{
                .command = .quit,
                .arg = undefined,
            },
            'g' => return Action{
                .command = .goto,
                .arg = s[1..],
            },
            'v' => return Action{
                .command = .view,
                .arg = undefined,
            },
            'e' => return Action{
                .command = .edit,
                .arg = s[1..],
            },
            '<' => return Action{
                .command = .outdent,
                .arg = s[1..],
            },
            '>' => return Action{
                .command = .indent,
                .arg = s[1..],
            },
            '+' => return Action{
                .command = .up,
                .arg = s[1..],
            },
            '-' => return Action{
                .command = .down,
                .arg = s[1..],
            },
            'd' => return Action{
                .command = .delete,
                .arg = s[1..],
            },
            's' => return Action{
                .command = .sync,
                .arg = undefined,
            },
            't' => return Action{
                .command = .todo,
                .arg = undefined,
            },
            'm' => return Action{
                .command = .move,
                .arg = s[1..],
            },
            'j' => return Action{
                .command = .inject,
                .arg = s[1..],
            },
            'u' => return Action{
                .command = .merge,
                .arg = undefined,
            },
            'w' => return Action{
                .command = .write,
                .arg = undefined,
            },
            'h' => return Action{
                .command = .help,
                .arg = undefined,
            },
            'o' => return Action{
                .command = .overview,
                .arg = undefined,
            },
            'y' => return Action{
                .command = .yeet,
                .arg = undefined,
            },
            else => return null,
        }
    }
};

fn parseBracket(s: []u8) ?[]u8 {
    var i: usize = s.len - 1;
    while (true) : (i -= 1) {
        if (s[i] == ']')
            break;
        if (s[i] == '[')
            return s[i + 1 ..];
        if (i == 0)
            break;
    }
    return null;
}

fn contains(inner: []const u8, outer: []const u8) bool {
    var i: u16 = 0;
    while (i + inner.len <= outer.len) : (i += 1) {
        if (mem.eql(u8, inner, outer[i .. i + inner.len]))
            return true;
        while (true) {
            i += 1;
            if (i + inner.len > outer.len)
                break;
            const c = outer[i];
            if ((c == ' ') or (c == '-') or (c == '/') or (c == '|')) //only compare at beginnings of words
                break;
        }
    }
    return false;
}

//A buffer for screen output that supports word wrap and multiple columns
const OutputManager = struct {
    const Self = @This();
    colWidth: ?u16,
    numColumns: u8,
    buf: [maxBufLen]u8,
    allocator: *std.heap.ArenaAllocator,
    parentAllocator: Allocator,
    lines: std.ArrayList([]u8),
    curIndent: u8,
    curLen: u16,
    fn init(parentAllocator: Allocator, noColumns: bool) !Self {
        var allocator = try parentAllocator.create(std.heap.ArenaAllocator);
        allocator.* = std.heap.ArenaAllocator.init(parentAllocator);
        var lines = std.ArrayList([]u8).init(allocator.allocator());
        var colWidth: ?u16 = null;
        var numColumns: u8 = 1;
        if (!noColumns)
            if (util.terminalWidth) |tw| {
                colWidth = tw;
                if (util.terminalHeight) |th| {
                    if (tw > 100) {
                        if ((tw / th > 4) or (tw > 150)) {
                            numColumns = 3;
                            colWidth = (tw - 4) / 3;
                        } else {
                            numColumns = 2;
                            colWidth = (tw - 3) / 2;
                        }
                    }
                }
            };
        return Self{
            .parentAllocator = parentAllocator,
            .allocator = allocator,
            .lines = lines,
            .buf = undefined,
            .curIndent = undefined,
            .curLen = undefined,
            .colWidth = colWidth,
            .numColumns = numColumns,
        };
    }
    fn deinit(self: Self) void {
        self.allocator.deinit();
        self.parentAllocator.destroy(self.allocator);
    }
    fn allocText(self: *Self, s: []const u8) ![]u8 {
        const sCopy = try self.allocator.allocator.alloc(u8, s.len);
        mem.copy(u8, sCopy, s);
        return sCopy;
    }
    fn startLine(self: *Self, indent: u8) void {
        self.curIndent = indent;
        self.curLen = 0;
    }
    fn print(self: *Self, comptime format: []const u8, args: anytype) !void {
        const s = try std.fmt.bufPrint(self.buf[self.curLen..], format, args);
        self.curLen += @intCast(u16, s.len);
    }
    fn endLine(self: *Self) !void {
        var start: u16 = 0;
        var stop: u16 = 0;
        var mostRecentSpace: ?u16 = null;
        const text = self.buf[0..self.curLen];
        var extraWid: u16 = 0;
        while (stop < text.len) : (stop += 1) {
            if (self.colWidth != null and stop - start + extraWid >= self.colWidth.?) {
                if (mostRecentSpace) |mrs| {
                    if (mrs > self.curIndent) {
                        stop = mrs + 1;
                    }
                }
                const sCopy = try self.allocator.allocator().alloc(u8, extraWid + stop - start);
                mem.set(u8, sCopy[0..extraWid], ' ');
                mem.copy(u8, sCopy[extraWid..], text[start..stop]);
                try self.lines.append(sCopy);
                start = stop;
                extraWid = self.curIndent;
                mostRecentSpace = null;
            }
            if (text[stop] == ' ') {
                mostRecentSpace = stop;
            }
        }
        const sCopy = try self.allocator.allocator().alloc(u8, extraWid + stop - start);
        mem.set(u8, sCopy[0..extraWid], ' ');
        mem.copy(u8, sCopy[extraWid..], text[start..stop]);
        try self.lines.append(sCopy);
    }
    //This function finally dumps all the data to stdout, using the entirety of the data to calculate appropriate columns and word wrapping
    fn flush(self: Self, out: Writer, in: Reader) !void {
        const items = self.lines.items;
        if (self.colWidth != null) {
            const totalRows = (items.len + self.numColumns - 1) / self.numColumns;
            var rowIndex: usize = 0;
            const visibleRows = util.terminalHeight.? - 1;
            var leftIndex: usize = 0;
            while (rowIndex < totalRows) : ({
                rowIndex += visibleRows;
                leftIndex += visibleRows * self.numColumns;
            }) {
                var curRows = totalRows - rowIndex;
                const partialRow = curRows > visibleRows;
                if (partialRow)
                    curRows = visibleRows;
                var pageIndex: usize = 0;
                while (pageIndex < curRows) : (pageIndex += 1) {
                    var column: usize = 0;
                    while (column < self.numColumns) : (column += 1) {
                        const index = leftIndex + pageIndex + column * curRows;
                        const isValid = index < items.len;
                        const offset = (self.colWidth.? + 1);
                        if (isValid)
                            try out.print("{s}", .{items[index]});
                        var j: usize = 0;
                        if (column < self.numColumns - 1)
                            while (j < (offset - (if (isValid) items[index].len else 0))) : (j += 1) {
                                try out.print(" ", .{});
                            };
                        if (column < self.numColumns - 1)
                            try out.print("|", .{});
                    }
                    try out.print("\n", .{});
                }
                if (partialRow) {
                    try out.print(":more:", .{});
                    var buf: [10]u8 = undefined;
                    var k = (try in.readUntilDelimiterOrEof(&buf, '\n')).?;
                    if (k.len == 1 and k[0] == 'q')
                        return;
                }
            }
        } else {
            for (self.lines.items) |line| {
                try out.print("{s}\n", .{line});
            }
        }
    }
};

const ViewModes = enum {
    split,
    normal,
    numbered,
};
pub const UserInterface = struct {
    const Self = @This();
    var useTestInput = false;
    in: Reader,
    out: Writer,
    allocator: Allocator,
    inputBuf: [maxBufLen]u8, //only used by readline
    lineBuf: [maxBufLen]u8, //used as a scratch pad for manipulating a line in a page
    headers: Headers,
    page: Page,
    pageOther: ?Page,
    viewMode: ViewModes,
    clipboard: ?usize,
    clipboardOther: bool,
    userInterfaceTodo: (if (includeTodoModule)
        todoModule.UserInterfaceTodo
    else
        void),
    fn init(allocator: Allocator) !Self {
        const out = io.getStdOut().writer();
        var in = io.getStdIn().reader();
        var dateBuf: [100]u8 = undefined;
        var mgr = try OutputManager.init(allocator, false);
        defer mgr.deinit();
        var headers = try Headers.init(allocator);
        try printDateRoll(headers.hashedItems, allocator, &mgr, &dateBuf);
        try mgr.flush(out, in);
        var page = try Page.init(allocator);
        {
            var date = try time.printNowLocal(&dateBuf);
            try page.load(headers.hashedItems, date);
        }
        return UserInterface{
            .in = in,
            .out = out,
            .allocator = allocator,
            .headers = headers,
            .page = page,
            .pageOther = null,
            .inputBuf = undefined,
            .lineBuf = undefined,
            .viewMode = .split,
            .clipboard = null,
            .clipboardOther = undefined,
            .userInterfaceTodo = undefined,
        };
    }
    fn deinit(self: *Self) void {
        self.headers.deinit();
        self.page.deinit();
        if (self.pageOther) |po|
            po.deinit();
    }
    //When we view the list of daily notes, it's helpful to view not just a single page, but a whole week of pages
    fn printDateRoll(hashedTitles: std.StringHashMap(usize), allocator: Allocator, out: *OutputManager, dateBuf: *[100]u8) !void {
        {
            var daysBack: i16 = 6;
            while (true) : (daysBack -= 1) {
                const date = try time.printDateTime(time.timestamp2DateTime(time.unix2local(time.adjustedTimestamp(-daysBack))), dateBuf);
                var datePage = try Page.init(allocator);
                defer datePage.deinit();
                try datePage.load(hashedTitles, date);
                try datePage.print(out, false, null);
                if (daysBack == 0)
                    break;
            }
        }
    }
    pub fn readLine(self: *Self) ![]u8 {
        var result: []u8 = undefined;
        if (try self.in.readUntilDelimiterOrEof(&self.inputBuf, '\n')) |r| {
            result = r;
        } else {
            mem.copy(u8, self.inputBuf[0..], "q");
            result = self.inputBuf[0..1];
        }
        if (useTestInput)
            try self.out.print("\nread \"{s}\"\n", .{result});
        return result;
    }
    pub fn readNumber(self: *Self, maxNum: u16) !u16 {
        while (true) {
            const s = try self.readLine();
            if (s.len == self.lineBuf.len) {
                try self.out.print("Input too long.\n", .{});
                continue;
            }
            const line = std.mem.trimRight(u8, self.inputBuf[0..s.len], "\r\n");
            const n = (fmt.parseUnsigned(u16, line, 10) catch {
                try self.out.print("Invalid number.\n", .{});
                continue;
            });
            if (n > maxNum) {
                try self.out.print("Number out of range.", .{});
            }
            return n;
        }
    }
    //This function takes a partial page name and interactively resolves the desired header index
    pub fn pickHeader(self: *Self, query: []const u8, allowNew: bool, globalQuery: bool) !?usize {
        //first handle intra-page queries
        if (!globalQuery) {
            {
                var it = self.page.links.keyIterator();
                while (it.next()) |link| {
                    if (contains(query, link.*))
                        return self.headers.find(link.*);
                }
            }
            {
                var it = self.page.references.keyIterator();
                while (it.next()) |reference| {
                    if (contains(query, reference.*)) {
                        return self.headers.find(reference.*);
                    }
                }
            }
        }
        //Now handle global queries
        const numMarked = self.headers.markByQuery(query);
        if (numMarked == 1 and !allowNew) {
            for (self.headers.items.items) |header, i| {
                if (header.marked) {
                    return i;
                }
            }
        }
        for (self.headers.items.items) |header, i| {
            if (!header.marked)
                continue;
            if (header.title.len == query.len)
                return i;
        }
        var markIndex: u16 = 0;
        for (self.headers.items.items) |header| {
            if (!header.marked)
                continue;
            try self.out.print("{any} {s}\n", .{ markIndex + 1, header.title });
            markIndex += 1;
        }
        if (markIndex == 0 and !allowNew)
            return null;
        if (allowNew) {
            try self.out.print("n {s} (new page)\nb back\n", .{query});
        }
        try self.out.print(">", .{});
        const maxNum = markIndex;
        var n: u16 = undefined;
        while (true) {
            const s = try self.readLine();
            if (s.len == self.lineBuf.len) {
                try self.out.print("Input too long.\n", .{});
                continue;
            }
            const line = std.mem.trimRight(u8, self.inputBuf[0..s.len], "\r\n");
            if (s.len == 0 and maxNum == 1) {
                n = 0;
                break;
            }
            n = (fmt.parseUnsigned(u16, line, 10) catch {
                if (allowNew) {
                    if (line.len == 1) {
                        if (line[0] == 'n') {
                            return try self.headers.append(query);
                        }
                        if (line[0] == 'b') {
                            return null;
                        }
                    }
                }
                if (line.len == 0) {
                    if (maxNum > 0) {
                        n = 0;
                        break;
                    }
                }
                try self.out.print("Invalid number.\n", .{});
                continue;
            }) - 1;
            if (n >= maxNum) {
                try self.out.print("Number out of range.", .{});
            }
            break;
        }
        markIndex = 0;
        for (self.headers.items.items) |header, i| {
            if (!header.marked)
                continue;
            if (markIndex == n) {
                return i;
            }
            markIndex += 1;
        }
        unreachable;
    }
    //The result argument is a slice that can be increased in length. The result is already pre-populated with everything up to the query text.
    fn queryHeaders(self: *Self, query: []const u8, destination: []u8) ![]u8 {
        if (try self.pickHeader(query, true, true)) |h| {
            const header = self.headers.items.items[h];
            var result = destination;
            result.len += header.title.len;
            mem.copy(u8, result[destination.len..], header.title);
            result.len += 1;
            result[result.len - 1] = ']';
            return result;
        } else {
            return destination[0 .. destination.len - 1];
        }
    }
    fn checkPageExist(context: struct { self: *Self, terminatingMissingPage: *bool, nonterminatingMissingPage: *bool, terminatingLink: *[]const u8 }, link: []const u8, terminating: bool) !void {
        if (context.self.headers.find(link) == null) {
            if (!terminating) {
                try context.self.out.print("Will create page [{s}]\n", .{link});
                context.nonterminatingMissingPage.* = true;
            } else {
                context.terminatingLink.* = link;
                context.terminatingMissingPage.* = true;
            }
        }
    }
    fn createHeader(context: struct { self: *Self }, link: []const u8, terminating: bool) !void {
        if (context.self.headers.find(link) == null and !terminating) {
            _ = try context.self.headers.append(link);
        }
    }
    fn interactiveTextEntry(self: *Self, prefixLen: usize) !usize { //a readline that supports interactive link queries. uses lineBuf array as buffer, which can be prefilled with perfixLen chars.
        var fragment: []u8 = self.lineBuf[0..prefixLen];
        try self.out.print("{s}", .{fragment});
        while (true) {
            const input = try self.readLine();
            const prevLen = fragment.len;
            fragment.len = fragment.len + input.len;
            mem.copy(u8, fragment[prevLen..], input);
            if (fragment.len == 0)
                return 0;
            var terminatingMissingPage = false;
            var nonterminatingMissingPage = false;
            var terminatingLink: []const u8 = undefined;
            try forEachLink(.{ .self = self, .terminatingMissingPage = &terminatingMissingPage, .nonterminatingMissingPage = &nonterminatingMissingPage, .terminatingLink = &terminatingLink }, checkPageExist, fragment);
            if ((!terminatingMissingPage) and (!nonterminatingMissingPage))
                return fragment.len;
            if (nonterminatingMissingPage) {
                try self.out.print("Create page(s) Y/n ?", .{});
                const answer = try self.readLine();
                if (std.mem.eql(u8, answer, "y") or std.mem.eql(u8, answer, "")) {
                    try forEachLink(.{ .self = self }, createHeader, fragment);
                } else {
                    fragment = self.lineBuf[0..prevLen];
                    try self.out.print("{s}", .{fragment});
                    continue;
                }
            }
            if (terminatingMissingPage) {
                const remainingLen = fragment.len - terminatingLink.len;
                fragment = try self.queryHeaders(terminatingLink, self.lineBuf[0..remainingLen]);
                try self.out.print("{s}", .{fragment});
            } else return fragment.len;
        }
    }
    fn addText(self: *Self, action: Action) !void {
        var index: usize = undefined;
        if (action.command == .insert or action.command == .inject) {
            index = self.page.resolveLinePath(action.arg).?;
        }
        const indent = if (action.command == .inject)
            self.page.lines.items[index].indent + 1
        else
            1;
        if (action.command == .inject) {
            index += 1;
            while (index < self.page.lines.items.len and self.page.lines.items[index].indent >= indent) : (index += 1) {}
        }
        while (true) {
            const fragment = self.lineBuf[0..(try self.interactiveTextEntry(0))];
            if (fragment.len == 0)
                break;
            const ii = util.IndentInfo.parseIndent(fragment);
            if (action.command == .append) {
                try self.page.append(indent + ii.indent, ii.text, true);
            } else {
                try self.page.insert(index, indent + ii.indent, ii.text);
                index += 1;
            }
            self.page.modified = true;
        }
    }
    fn editText(self: *Self, path: []const u8) !void {
        const index = self.page.resolveLinePath(path).?;
        var oldText = self.page.lines.items[index].text;
        const maxNum = try Page.printWordNumbers(self.out, oldText);
        try self.out.print("{s}\n", .{oldText});
        try self.out.print("#", .{});
        const start = try self.readNumber(maxNum);
        const startIndex = Page.wordNumberIndex(oldText, start);
        const frontSlice = oldText[0..startIndex];
        std.mem.copy(u8, &self.lineBuf, frontSlice);
        const fragment = self.lineBuf[0..try self.interactiveTextEntry(startIndex)];
        try self.out.print("#", .{});
        const end = try self.readNumber(maxNum);
        const endIndex = Page.wordNumberIndex(oldText, end);
        const endSlice = oldText[endIndex..];
        std.mem.copy(u8, self.lineBuf[fragment.len..], endSlice);
        if (index == 0) {
            mem.copy(u8, self.inputBuf[0..oldText.len], oldText);
            oldText = self.inputBuf[0..oldText.len];
        }
        try self.page.update(index, self.lineBuf[0 .. fragment.len + endSlice.len]);
        if (index == 0) {
            const newName = self.lineBuf[0 .. fragment.len + endSlice.len];
            _ = try self.headers.append(newName);
            try self.page.smartRenameSelf(self.headers.hashedItems, oldText, newName);
            self.page.deinit();
            const headerIndex = self.headers.find(oldText) orelse unreachable;
            self.headers.remove(headerIndex);
            self.page = try Page.init(self.allocator);
            try self.page.load(self.headers.hashedItems, newName);
        }
    }
    fn goto(self: *Self, s: []const u8) !void {
        try self.page.save();
        const globalHeader = (s.len >= 1 and s[0] == ' ');
        const query = if (globalHeader)
            s[1..]
        else
            s;
        if (try self.pickHeader(query, false, globalHeader)) |i| {
            if (self.pageOther) |po|
                po.deinit();
            self.pageOther = self.page;
            self.page = try Page.init(self.allocator);
            if (self.clipboard) |_| {
                if (self.clipboardOther) {
                    self.clipboard = null;
                    self.clipboardOther = false;
                } else {
                    self.clipboardOther = true;
                }
            }
            const name = self.headers.items.items[i].title;
            try self.page.load(self.headers.hashedItems, name);
        }
    }
    const Errors = error{ShellFail};
    fn shell(self: *Self, comptime args: anytype) !u32 {
        var process = try std.ChildProcess.init(&args, self.allocator);
        defer process.deinit();
        const result = try process.spawnAndWait();
        switch (result) {
            Term.Exited => |n| return n,
            Term.Signal, Term.Stopped, Term.Unknown => return Errors.ShellFail,
        }
    }
    fn merge(self: *Self) !void {
        const po = self.pageOther.?;
        const poTitle = po.lines.items[0].text;
        const title = self.page.lines.items[0].text;
        for (po.lines.items[1..]) |line| {
            try self.page.append(line.indent, line.text, true);
        }
        var iterator = po.references.iterator();
        while (iterator.next()) |kv| {
            const ref = kv.key_ptr.*;
            try self.page.appendReference(ref);
            var tempPage = try Page.init(self.allocator);
            defer tempPage.deinit();
            try tempPage.load(self.headers.hashedItems, ref);
            for (tempPage.lines.items[1..]) |line, lineIndex| {
                const text = line.text;
                var i: usize = 0;
                var iDst: usize = 0;
                var match = false;
                while (i < text.len) {
                    if (text[i] == '[') {
                        if (text[i + 1 ..].len >= poTitle.len and std.mem.eql(u8, text[i + 1 .. i + 1 + poTitle.len], poTitle) and text[i + 1 + poTitle.len] == ']') {
                            self.lineBuf[iDst] = '[';
                            iDst += 1;
                            std.mem.copy(u8, self.lineBuf[iDst .. iDst + title.len], title);
                            iDst += title.len;
                            self.lineBuf[iDst] = ']';
                            iDst += 1;
                            i += 2 + poTitle.len;
                            match = true;
                        } else {
                            self.lineBuf[iDst] = '[';
                            iDst += 1;
                            std.mem.copy(u8, self.lineBuf[iDst .. iDst + poTitle.len], poTitle);
                            iDst += poTitle.len;
                            self.lineBuf[iDst] = ']';
                            iDst += 1;
                            i += 2 + poTitle.len;
                        }
                    } else {
                        self.lineBuf[iDst] = text[i];
                        iDst += 1;
                        i += 1;
                    }
                }
                if (match) {
                    try tempPage.update(lineIndex + 1, self.lineBuf[0..iDst]);
                    try self.page.appendReferenceEntry(ref, self.lineBuf[0..iDst]);
                }
            }
            tempPage.modified = true;
            try tempPage.save();
            tempPage.deinit();
        }
        self.page.modified = true;
        try std.fs.cwd().deleteFile(try util.pageFileName(poTitle));
        if (self.headers.find(poTitle)) |index| {
            self.headers.remove(index);
        }
        po.deinit();
        self.pageOther = null;
    }
    pub fn sync(self: *Self) !void {
        const title = self.page.lines.items[0].text;
        std.mem.copy(u8, &self.lineBuf, title);
        const titleCopy = self.lineBuf[0..title.len];
        try self.page.save();
        self.page.deinit();
        if (self.pageOther) |po| {
            po.deinit();
            self.pageOther = null;
        }
        self.headers.deinit();
        _ = try self.shell([_][]const u8{
            "git",
            "add",
            ".",
        });
        _ = try self.shell([_][]const u8{
            "git",
            "commit",
            "-a",
            "-m",
            "\"wip\"",
        });
        _ = try self.shell([_][]const u8{
            "git",
            "pull",
        });
        _ = try self.shell([_][]const u8{
            "git",
            "push",
        });
        self.headers = try Headers.init(self.allocator);
        self.page = try Page.init(self.allocator);
        try self.page.load(self.headers.hashedItems, titleCopy);
    }
    pub fn help(self: *Self, title: []const u8) !void {
        var helpPage = try Page.init(self.allocator);
        defer helpPage.deinit();
        try helpPage.load(self.headers.hashedItems, title);
        var mgr = try OutputManager.init(self.allocator, false);
        defer mgr.deinit();
        try helpPage.print(&mgr, false, null);
        try mgr.flush(self.out, self.in);
        try self.out.print(":continue:", .{});
        _ = try self.readLine();
    }
    fn printHyphenated(self: *Self, s: []const u8) !void {
        for (s) |c| {
            if (c == ' ') {
                try self.out.print("-", .{});
            } else {
                try self.out.print("{c}", .{c});
            }
        }
    }
    fn printOverviewNode(self: *Self, header: Headers.Header, name: []const u8, neighborFound: *bool) !void {
        if (self.headers.find(name)) |index| {
            if (!self.headers.items.items[index].marked) {
                if (!neighborFound.*) {
                    if (header.connections < 10) {
                        try self.out.print(" ", .{});
                    }
                    try self.out.print("{any} ", .{header.connections});
                    try self.printHyphenated(header.title);
                    try self.out.print(" ", .{});
                } else {
                    try self.out.print(" ", .{});
                }
                try self.printHyphenated(name);
                self.headers.items.items[index].marked = true;
                neighborFound.* = true;
            }
        } else {
            //try self.out.print("!!!missing key {s}", .{key.*});
        }
    }
    pub fn setupDateRoll(self: *Self) !void {
        try self.page.save();
        if (self.pageOther) |po|
            po.deinit();
        self.pageOther = self.page;
        self.page = try Page.init(self.allocator);
        self.clipboard = null;
        var dateBuf: [100]u8 = undefined;
        {
            var mgr = try OutputManager.init(self.allocator, false);
            defer mgr.deinit();
            try printDateRoll(self.headers.hashedItems, self.allocator, &mgr, &dateBuf);
            try mgr.flush(self.out, self.in);
        }
        var date = try time.printNowLocal(&dateBuf);
        try self.page.load(self.headers.hashedItems, date);
    }
    fn eventLoop(self: *Self, initialPrint: bool) !void {
        var printPage: bool = initialPrint;
        while (true) {
            const co = if (self.clipboardOther)
                null
            else
                self.clipboard;
            if (printPage) {
                var mgr = try OutputManager.init(self.allocator, self.viewMode == .normal);
                defer mgr.deinit();
                try self.page.printReferences(&mgr);
                try self.page.print(&mgr, self.viewMode == .numbered, co);
                try mgr.flush(self.out, self.in);
            }
            try self.out.print("?", .{});
            if (self.clipboard) |_| {
                try self.out.print("*", .{});
            }
            printPage = true;
            const line = try self.readLine();
            if (Action.fromString(line)) |action| {
                switch (action.command) {
                    .help => {
                        try self.help("help");
                    },
                    .append, .insert, .inject => try self.addText(action),
                    .goto => {
                        try self.goto(action.arg);
                    },
                    .quit => {
                        try self.page.save();
                        break;
                    },
                    .view => {
                        self.viewMode = @intToEnum(ViewModes, (@enumToInt(self.viewMode) + 1) % 3);
                    },
                    .edit => try self.editText(action.arg),
                    .outdent => {
                        if (self.page.resolveLinePath(action.arg)) |path| {
                            self.page.outdent(path);
                        } else {
                            try self.out.print("Invalid path.\n", .{});
                        }
                    },
                    .indent => {
                        if (self.page.resolveLinePath(action.arg)) |path| {
                            self.page.indentLine(path);
                        } else {
                            try self.out.print("Invalid path.\n", .{});
                        }
                    },
                    .up => {
                        if (self.page.resolveLinePath(action.arg)) |path| {
                            self.page.up(path);
                        } else {
                            try self.out.print("Invalid path.\n", .{});
                        }
                    },
                    .down => {
                        if (self.page.resolveLinePath(action.arg)) |path| {
                            self.page.down(path);
                        } else {
                            try self.out.print("Invalid path.\n", .{});
                        }
                    },
                    .delete => {
                        if (self.page.resolveLinePath(action.arg)) |path| {
                            try self.page.delete(path);
                        } else {
                            try self.out.print("Invalid path.\n", .{});
                        }
                    },
                    .sync => try self.sync(),
                    .todo => if (includeTodoModule) {
                        if (try self.userInterfaceTodo.activate(self, &printPage))
                            break;
                    },
                    .move => {
                        if (self.page.resolveLinePath(action.arg)) |path| {
                            if (self.clipboard) |cl| {
                                if (action.arg.len == 0) { //cancel operation
                                    self.clipboard = null;
                                    self.clipboardOther = false;
                                } else if (self.clipboardOther) { //Moving from other page, not inter-page move
                                    if (self.pageOther) |*po| {
                                        const srcLines = &po.lines;
                                        var srcIndex = cl;
                                        const srcIndent = srcLines.items[cl].indent;
                                        const dstLines = self.page.lines;
                                        var dstIndex = path;
                                        const dstIndent = dstLines.items[dstIndex].indent;
                                        dstIndex += 1;
                                        while (dstIndex < dstLines.items.len and dstLines.items[dstIndex].indent > dstIndent) : (dstIndex += 1) {}
                                        var firstTime = true;
                                        while (srcIndex < srcLines.items.len and (firstTime or srcLines.items[srcIndex].indent > srcIndent)) {
                                            firstTime = false;
                                            try self.page.insert(dstIndex, srcLines.items[srcIndex].indent + dstIndent + 1 - srcIndent, srcLines.items[srcIndex].text);
                                            try po.delete(srcIndex);
                                            dstIndex += 1;
                                        }
                                        try po.save();
                                        try self.page.save();
                                        self.clipboard = null;
                                        self.clipboardOther = false;
                                    } else @panic("missing other page");
                                } else {
                                    const lines = self.page.lines;
                                    var srcIndex = cl;
                                    const srcIndent = lines.items[cl].indent;
                                    var dstIndex = path;
                                    const dstIndent = lines.items[dstIndex].indent;
                                    dstIndex += 1;
                                    while (dstIndex < lines.items.len and lines.items[dstIndex].indent > dstIndent) : (dstIndex += 1) {}
                                    var firstTime = true;
                                    while (srcIndex < lines.items.len and (firstTime or lines.items[srcIndex].indent > srcIndent)) {
                                        firstTime = false;
                                        try self.page.insert(dstIndex, lines.items[srcIndex].indent + dstIndent + 1 - srcIndent, lines.items[srcIndex].text);
                                        if (srcIndex > dstIndex)
                                            srcIndex += 1;
                                        try self.page.delete(srcIndex);
                                    }
                                    try self.page.save();
                                    self.clipboard = null;
                                }
                            } else {
                                self.clipboard = path;
                                self.clipboardOther = false;
                            }
                        } else {
                            try self.out.print("Invalid path.\n", .{});
                        }
                    },
                    .merge => {
                        if (self.pageOther) |*po| {
                            try self.out.print("Create union of [{s}] into [{s}] (y/n):", .{ po.lines.items[0].text, self.page.lines.items[0].text });
                            const k = try self.readLine();
                            if (std.mem.eql(u8, k, "y"))
                                try self.merge();
                        } else {
                            printPage = false;
                        }
                    },
                    .write => {
                        try self.setupDateRoll();
                        printPage = false;
                    },
                    .overview => {
                        for (self.headers.items.items) |*header| {
                            //try self.out.print("title{s}", .{header.title});
                            var tempPage = try Page.init(self.allocator);
                            defer tempPage.deinit();
                            const name = header.title;
                            try tempPage.load(self.headers.hashedItems, name);
                            header.connections = tempPage.links.count() + tempPage.references.count();
                            //try self.out.print("connections{any}", .{header.connections});
                            header.marked = false;
                        }
                        std.sort.sort(Headers.Header, self.headers.items.items, {}, Headers.sortByConnections);
                        for (self.headers.items.items) |*header| {
                            var tempPage = try Page.init(self.allocator);
                            defer tempPage.deinit();
                            const name = header.title;
                            try tempPage.load(self.headers.hashedItems, name);
                            var neighborFound = false;
                            header.marked = true;
                            {
                                var it = tempPage.links.keyIterator();
                                while (it.next()) |key| {
                                    try self.printOverviewNode(header.*, key.*, &neighborFound);
                                }
                            }
                            {
                                var it = tempPage.references.keyIterator();
                                while (it.next()) |key| {
                                    try self.printOverviewNode(header.*, key.*, &neighborFound);
                                }
                            }
                            if (neighborFound) {
                                try self.out.print("\n", .{});
                            }
                        }
                        try self.out.print(":continue:", .{});
                        _ = try self.readLine();
                    },
                    .back => {
                        if (self.pageOther) |po| {
                            try self.page.save();
                            self.pageOther = self.page;
                            self.page = po;
                            self.clipboard = null;
                        } else {
                            printPage = false;
                        }
                    },
                    .yeet => {
                        if (self.page.references.count() > 0) {
                            try self.out.print("Please delete all references to [{s}] first before yeeting this page.\n", .{self.page.lines.items[0].text});
                        } else {
                            try self.out.print("Really yeet page for [{s}]? y/N", .{self.page.lines.items[0].text});
                            const ans = try self.readLine();
                            if (std.mem.eql(u8, ans, "y")) {
                                try self.out.print("Page yeeted.\n", .{});
                                try std.fs.cwd().deleteFile(try util.pageFileName(self.page.lines.items[0].text));
                                if (self.headers.find(self.page.lines.items[0].text)) |index| {
                                    self.headers.remove(index);
                                }

                                self.page.deinit();
                                self.page = try Page.init(self.allocator);
                                self.clipboard = null;
                                var dateBuf: [100]u8 = undefined;
                                var date = try time.printNowLocal(&dateBuf);
                                try self.page.load(self.headers.hashedItems, date);
                            } else {
                                try self.out.print("cancelled.\n", .{});
                            }
                        }
                    },
                    .skip => {
                        try self.page.save();
                    },
                }
            } else {
                printPage = true;
            }
        }
    }
};

pub fn main() !void {
    if (builtin.os.tag != .windows) {
        var tty: std.fs.File = try std.fs.cwd().openFile("/dev/tty", .{ .read = true, .write = true });
        defer tty.close();
        var winSize = mem.zeroes(std.os.system.winsize);
        const err = std.os.system.ioctl(tty.handle, std.os.system.T.IOCGWINSZ, @ptrToInt(&winSize));
        if (std.os.errno(err) == .SUCCESS) {
            util.terminalWidth = winSize.ws_col;
            util.terminalHeight = winSize.ws_row;
        }
        try std.io.getStdOut().writer().print("\x1b[37;1m", .{});
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaks = gpa.deinit();
        assert(!leaks);
    }

    var args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    if (args.len > 1) {
        assert(args.len == 2);
        if (std.mem.eql(u8, args[1], "-validate")) {
            try std.io.getStdOut().writer().print("validating...\n", .{});
            try validator.validate(gpa.allocator());
            return;
        }
        try std.io.getStdOut().writer().print("Invalid command line argument", .{});
        return;
    }
    var userInterface = try UserInterface.init(gpa.allocator());
    defer userInterface.deinit();
    try userInterface.eventLoop(false);
}
