const std = @import("std");
const builtin = @import("builtin");
const zek = @import("zek.zig");
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

const TodoItemInfo = struct {
    const Self = @This();
    text: []u8,
    link: bool,
    project: bool,
    fn parseTodoItem(s: []u8) TodoItemInfo {
        const project = (s.len >= 2) and (s[s.len - 1] == 'P') and (s[s.len - 2] == ' ');
        if (s[0] == '[') {
            var x: usize = 1;
            while (x < s.len) : (x += 1) {
                if (s[x] == ']')
                    return TodoItemInfo{
                        .text = s[1..x],
                        .link = true,
                        .project = project,
                    };
            }
        } else {
            return TodoItemInfo{
                .text = if (project)
                    s[0 .. s.len - 2]
                else
                    s,
                .link = false,
                .project = project,
            };
        }
        unreachable;
    }
};
const PageTodo = struct {
    const Self = @This();
    const Todo = struct {
        text: []u8,
        time: i64, //time on which trigger occurs
        interval: u16, //interval on which trigger recurs (for repeat triggers)
        project: bool,
        link: bool, //does the todo have its own page?
        future: bool,
        trigger: bool, //item is not active todo but is active trigger
        repeat: bool, //trigger repeats
        modified: bool,
        xtra: bool,
    };
    var tempBuf: [util.maxBufLen]u8 = undefined;
    allocator: *std.heap.ArenaAllocator,
    parentAllocator: Allocator,
    todos: std.ArrayList(Todo),
    modified: bool,
    fn init(parentAllocator: Allocator) !Self {
        var allocator = try parentAllocator.create(std.heap.ArenaAllocator);
        allocator.* = std.heap.ArenaAllocator.init(parentAllocator);
        return Self{
            .parentAllocator = parentAllocator,
            .allocator = allocator,
            .todos = std.ArrayList(Todo).init(allocator.allocator()),
            .modified = false,
        };
    }
    fn deinit(self: Self) void {
        self.allocator.deinit();
        self.parentAllocator.destroy(self.allocator);
    }
    fn allocText(self: *Self, s: []const u8) ![]u8 {
        const sCopy = try self.allocator.allocator().alloc(u8, s.len);
        mem.copy(u8, sCopy, s);
        return sCopy;
    }
    fn print(self: Self, out: Writer, in: Reader) !void {
        for (self.todos.items) |*todo| {
            if (todo.xtra and todo.text.len > 0) {
                try out.print("XTRA: {s}\n", .{todo.text});
            }
        }
        var i: usize = 0;
        for (self.todos.items) |todo| {
            if (todo.trigger or todo.future or todo.xtra)
                continue;
            try out.print("{:>2} ", .{i + 1});
            if (todo.link)
                try out.print("[", .{});
            try out.print("{s}", .{todo.text});
            if (todo.link)
                try out.print("]", .{});
            if (todo.project)
                try out.print(" P", .{});
            try out.print("\n", .{});
            i += 1;
            if (util.terminalHeight) |th| {
                if (i % (th - 1) == 0) {
                    var inputBuf: [1]u8 = undefined;
                    try out.print(":continue:", .{});
                    _ = (try in.readUntilDelimiterOrEof(&inputBuf, '\n')).?;
                }
            }
        }
    }
    fn indexVisibleToIndex(self: Self, indexVisible: u16) usize {
        var n: usize = 0;
        for (self.todos.items) |todo, i| {
            if (todo.trigger or todo.future or todo.xtra)
                continue;
            if (n == indexVisible)
                return i;
            n += 1;
        }
        unreachable;
    }
    fn zeFuture(self: Self, out: Writer, in: Reader) !void {
        var i: u16 = 0;
        try out.print("future\n", .{});
        for (self.todos.items) |todo| {
            if (todo.future) {
                try out.print("- {s}\n", .{todo.text});
            }
            i += 1;
            if (util.terminalHeight) |th| {
                if (i % (th - 1) == 0) {
                    var inputBuf: [1]u8 = undefined;
                    try out.print(":continue:", .{});
                    _ = (try in.readUntilDelimiterOrEof(&inputBuf, '\n')).?;
                }
            }
        }
        try out.print("trigger\n", .{});
        for (self.todos.items) |todo| {
            if (todo.trigger) {
                try out.print("- {s}\n", .{todo.text});
            }
            i += 1;
            if (util.terminalHeight) |th| {
                if (i % (th - 1) == 0) {
                    var inputBuf: [1]u8 = undefined;
                    try out.print(":continue:", .{});
                    _ = (try in.readUntilDelimiterOrEof(&inputBuf, '\n')).?;
                }
            }
        }
        try out.print("--------------\n", .{});
    }
    fn append(self: *Self, s: []const u8, isProject: bool, future: bool, xtra: bool) !void {
        try self.todos.append(Todo{
            .text = try self.allocText(s),
            .interval = undefined,
            .time = undefined,
            .project = isProject,
            .link = isProject,
            .future = future,
            .trigger = false,
            .repeat = false,
            .xtra = xtra,
            .modified = true,
        });
        self.modified = true;
    }
    fn updateXtra(self: *Self, s: []const u8) !void {
        for (self.todos.items) |*todo| {
            if (todo.xtra) {
                todo.text = try self.allocText(s);
            }
        }
    }
    fn freshen(self: *Self, index: usize) void { //Moves the item to the end of the list, making it more "recent"
        const items = self.todos.items;
        var temp = items[index];
        var i = index;
        while (i < items.len - 1) : (i += 1) {
            items[i] = items[i + 1];
        }
        items[items.len - 1] = temp;
        self.modified = true;
    }
    fn complete(self: *Self, indexVisible: u16, projectKill: bool) void {
        const index = self.indexVisibleToIndex(indexVisible);
        const item = &self.todos.items[index];
        self.modified = true;
        if (item.repeat) {
            item.trigger = true;
            item.time = time.adjustedTimestamp(@intCast(i16, item.interval));
        } else if (item.project) {
            if (projectKill) {
                _ = self.todos.orderedRemove(index);
            } else {
                self.freshen(index);
            }
        } else {
            assert(!projectKill);
            _ = self.todos.orderedRemove(index);
        }
    }
    fn toggleLink(self: *Self, indexVisible: u16) bool {
        const index = self.indexVisibleToIndex(indexVisible);
        const item = &self.todos.items[index];
        item.link = !item.link;
        item.modified = true;
        return item.link;
    }
    fn last(self: *Self) *Todo {
        return &self.todos.items[self.todos.items.len - 1];
    }
    fn checkTriggers(self: *Self) void {
        const now = std.time.timestamp();
        const items = self.todos.items;
        var i: usize = 0;
        while (i < items.len) {
            const todo = &items[i];
            if (todo.trigger and todo.time <= now) {
                todo.trigger = false;
                self.freshen(i);
            } else i += 1;
        }
    }
    fn readLine(f: Reader) !?[]u8 {
        return try f.readUntilDelimiterOrEof(&tempBuf, '\n');
    }
    fn load(self: *Self) !void {
        const fname = "todo.md";
        if (util.fileExists(fname)) {
            const f = try std.fs.cwd().openFile(fname, .{});
            defer f.close();
            const reader = f.reader();
            var todoItem: Todo = undefined;
            var firstItem = true;
            while (try readLine(reader)) |line| {
                const info = util.IndentInfo.parseIndent(line);
                if (info.indent == 0) {
                    if (!firstItem)
                        try self.todos.append(todoItem);
                    firstItem = false;
                    const item = TodoItemInfo.parseTodoItem(info.text);
                    todoItem = Todo{
                        .text = try self.allocText(item.text),
                        .time = undefined,
                        .interval = undefined,
                        .project = item.project,
                        .link = item.link,
                        .future = false,
                        .trigger = false,
                        .repeat = false,
                        .modified = false,
                        .xtra = false,
                    };
                } else {
                    assert(info.indent == 1);
                    const len = info.text.len;
                    if (len >= 7 and std.mem.eql(u8, "trigger", info.text[0..7])) {
                        const n = fmt.parseInt(i64, info.text[8..], 10) catch {
                            @panic("bad trigger time");
                        };
                        todoItem.trigger = true;
                        todoItem.time = n;
                    }
                    if (std.mem.eql(u8, "repeat", info.text)) {
                        todoItem.repeat = true;
                    }
                    if (len >= 8 and std.mem.eql(u8, "interval", info.text[0..8])) {
                        const n = fmt.parseUnsigned(u16, info.text[9..], 10) catch {
                            @panic("bad interval");
                        };
                        todoItem.interval = n;
                    }
                    if (std.mem.eql(u8, "future", info.text)) {
                        todoItem.future = true;
                    }
                    if (std.mem.eql(u8, "xtra", info.text)) {
                        todoItem.xtra = true;
                    }
                }
            }
            if (!firstItem)
                try self.todos.append(todoItem);
        }
    }
    fn save(self: Self) !void {
        var modified = self.modified;
        for (self.todos.items) |todo| {
            modified = modified or todo.modified;
        }
        if (!modified)
            return;
        {
            var f = try std.fs.cwd().createFile("todo.md", std.fs.File.CreateFlags{ .truncate = true });
            defer f.close();
            const writer = f.writer();
            for (self.todos.items) |todo| {
                if (todo.link)
                    try writer.print("[", .{});
                try writer.print("{s}", .{todo.text});
                if (todo.link)
                    try writer.print("]", .{});
                if (todo.project)
                    try writer.print(" P", .{});
                try writer.print("\n", .{});
                if (todo.trigger)
                    try writer.print("- trigger {any}\n", .{todo.time});
                if (todo.repeat) {
                    try writer.print("- repeat\n", .{});
                    try writer.print("- interval {any}\n", .{todo.interval});
                }
                if (todo.future) {
                    try writer.print("- future\n", .{});
                }
                if (todo.xtra) {
                    try writer.print("- xtra\n", .{});
                }
            }
        }
        for (self.todos.items) |todo| {
            if (todo.modified and todo.link) {
                const fname = try util.pageFileName(todo.text);
                const fileExisted = util.fileExists(fname);
                var f = try util.appendFile(fname);
                defer f.close();
                if (!fileExisted) {
                    try f.writer().print("__references\n", .{});
                }
                try f.writer().print("- todo\n- - {s}\n", .{todo.text});
            }
        }
    }
};

const ActionTodo = struct {
    const Command = enum {
        nextAction,
        project,
        complete,
        kill,
        todo,
        goto,
        quit,
        link,
        future,
        trigger,
        zeFuture,
        help,
        sync,
        xtra,
        skip,
        write,
    };
    command: Command,
    arg: []const u8,
    fn fromString(s: []u8) ?ActionTodo {
        if (s.len == 0) {
            return ActionTodo{ .command = .skip, .arg = undefined };
        }
        switch (s[0]) {
            'n' => return ActionTodo{
                .command = .nextAction,
                .arg = s[1..],
            },
            'p' => return ActionTodo{
                .command = .project,
                .arg = s[1..],
            },
            'c' => return ActionTodo{
                .command = .complete,
                .arg = s[1..],
            },
            'k' => return ActionTodo{
                .command = .kill,
                .arg = s[1..],
            },
            't' => return ActionTodo{
                .command = .todo,
                .arg = undefined,
            },
            'q' => return ActionTodo{
                .command = .quit,
                .arg = undefined,
            },
            'l' => return ActionTodo{
                .command = .link,
                .arg = s[1..],
            },
            'g' => return ActionTodo{
                .command = .goto,
                .arg = s[1..],
            },
            'f' => return ActionTodo{
                .command = .future,
                .arg = s[1..],
            },
            'x' => return ActionTodo{
                .command = .xtra,
                .arg = s[1..],
            },
            'r' => return ActionTodo{
                .command = .trigger,
                .arg = s[1..],
            },
            'z' => return ActionTodo{
                .command = .zeFuture,
                .arg = undefined,
            },
            'h' => return ActionTodo{
                .command = .help,
                .arg = undefined,
            },
            's' => return ActionTodo{
                .command = .sync,
                .arg = undefined,
            },
            'w' => return ActionTodo{
                .command = .write,
                .arg = undefined,
            },
            else => return null,
        }
    }
};

pub const UserInterfaceTodo = struct {
    const Self = @This();
    pageTodo: PageTodo,
    const EventLoopTodoResult = struct {
        nextPageIndex: usize,
        prevPage: bool,
        quit: bool,
        write: bool,
    };
    pub fn activate(self: *Self, ui: *zek.UserInterface, printPage: *bool) !bool {
        try ui.page.save();
        const eltr = try self.eventLoopTodo(ui);

        if (eltr.quit) {
            printPage.* = false;
        } else if (eltr.write) {
            try ui.setupDateRoll();
            printPage.* = false;
        } else {
            if (!eltr.prevPage) {
                if (ui.pageOther) |po|
                    po.deinit();
                ui.pageOther = ui.page;
                ui.page = try zek.Page.init(ui.allocator);
                const name = ui.headers.items.items[eltr.nextPageIndex].title;
                try ui.page.load(ui.headers.hashedItems, name);
            }
        }
        return eltr.quit;
    }
    fn trigger(self: *Self, ui: *zek.UserInterface, s: []const u8) !void {
        try self.pageTodo.append(s, false, false, false);
        const todo = self.pageTodo.last();
        try ui.out.print("# Days:", .{});
        const d = try ui.readNumber(10000);
        todo.trigger = true;
        todo.time = time.adjustedTimestamp(@intCast(i16, d));
        try ui.out.print("Repeating (y/n):", .{});
        const k = try ui.readLine();
        var repeat = if (std.mem.eql(u8, k, "y"))
            true
        else if (std.mem.eql(u8, k, "n"))
            false
        else
            @panic("bad val");
        todo.repeat = repeat;
        if (repeat) {
            try ui.out.print("Trigger Interval Days:", .{});
            const interval = try ui.readNumber(10000);
            todo.interval = interval;
        }
    }
    fn eventLoopTodo(self: *Self, ui: *zek.UserInterface) !EventLoopTodoResult {
        self.pageTodo = try PageTodo.init(ui.allocator);
        try self.pageTodo.load();
        self.pageTodo.checkTriggers();
        while (true) {
            try self.pageTodo.print(ui.out, ui.in);
            try ui.out.print("?", .{});
            const line = try ui.readLine();
            if (ActionTodo.fromString(line)) |action| {
                switch (action.command) {
                    .help => {
                        try ui.help("help todo");
                    },
                    .nextAction => try self.pageTodo.append(action.arg, false, false, false),
                    .project => {
                        try self.pageTodo.append(action.arg, true, false, false);
                        if (ui.headers.find(action.arg) == null) {
                            _ = try ui.headers.append(action.arg);
                        }
                    },
                    .complete => {
                        const n = (try fmt.parseUnsigned(u16, action.arg, 10)) - 1;
                        self.pageTodo.complete(n, false);
                    },
                    .kill => {
                        const n = (try fmt.parseUnsigned(u16, action.arg, 10)) - 1;
                        self.pageTodo.complete(n, true);
                    },
                    .link => {
                        const n = (try fmt.parseUnsigned(u16, action.arg, 10)) - 1;
                        const link = self.pageTodo.toggleLink(n);
                        if (link) {
                            _ = try ui.headers.append(self.pageTodo.todos.items[n].text);
                        }
                    },
                    .quit => {
                        try self.pageTodo.save();
                        self.pageTodo.deinit();
                        return EventLoopTodoResult{
                            .nextPageIndex = 0,
                            .prevPage = false,
                            .quit = true,
                            .write = false,
                        };
                    },
                    .todo => {
                        try self.pageTodo.save();
                        self.pageTodo.deinit();
                        return EventLoopTodoResult{
                            .nextPageIndex = 0,
                            .prevPage = true,
                            .quit = false,
                            .write = true,
                        };
                    },
                    .goto => {
                        try self.pageTodo.save();
                        if (try ui.pickHeader(action.arg, false, true)) |i| {
                            self.pageTodo.deinit();
                            return EventLoopTodoResult{
                                .nextPageIndex = i,
                                .prevPage = false,
                                .quit = false,
                                .write = false,
                            };
                        }
                    },
                    .write => {
                        try ui.setupDateRoll();
                        return EventLoopTodoResult{
                            .nextPageIndex = 0,
                            .prevPage = false,
                            .quit = false,
                            .write = true,
                        };
                    },
                    .sync => {
                        try self.pageTodo.save();
                        self.pageTodo.deinit();
                        try ui.sync();
                        self.pageTodo = try PageTodo.init(ui.allocator);
                        try self.pageTodo.load();
                        self.pageTodo.checkTriggers();
                    },
                    .future => try self.pageTodo.append(action.arg, true, true, false),
                    .xtra => try self.pageTodo.updateXtra(action.arg),
                    .trigger => try self.trigger(ui, action.arg),
                    .zeFuture => try self.pageTodo.zeFuture(ui.out, ui.in),
                    .skip => {
                        try self.pageTodo.save();
                    },
                }
            }
        }
    }
};
