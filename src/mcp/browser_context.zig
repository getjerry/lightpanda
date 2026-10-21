const std = @import("std");
const lp = @import("lightpanda");
const protocol = @import("protocol.zig");
const state = @import("browser_state.zig");

pub const Tool = enum {
    getStorageState,
    setStorageState,
    listPages,
    selectPage,
    newPage,
    closePage,
    addInitScript,
    removeInitScript,
    setViewport,
};

const empty_schema = lp.tools.minify("{\"type\":\"object\",\"properties\":{}}");
const id_schema = lp.tools.minify("{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\",\"minimum\":1}},\"required\":[\"id\"]}");
const read_only: protocol.ToolAnnotations = .{ .readOnlyHint = true, .destructiveHint = false, .idempotentHint = true, .openWorldHint = false };

pub const tools = [_]protocol.Tool{
    .{ .name = "getStorageState", .title = "Export browser storage", .description = "Export cookies including HttpOnly, cross-origin localStorage, and live top-level pages' sessionStorages by hostname. Does not navigate or change the selected page. IndexedDB is not exported.", .inputSchema = empty_schema, .annotations = read_only },
    .{ .name = "setStorageState", .title = "Restore browser storage", .description = "Replace cookies and localStorage from a storage-state object. Validates before mutating. Does not navigate, change the selected page, or restore sessionStorage; use addInitScript before navigation for that. IndexedDB and partitioned cookies are unsupported.", .inputSchema = lp.tools.minify("{\"type\":\"object\",\"properties\":{\"state\":{\"type\":\"object\",\"properties\":{\"cookies\":{\"type\":\"array\"},\"origins\":{\"type\":\"array\"}},\"required\":[\"cookies\",\"origins\"]}},\"required\":[\"state\"]}") },
    .{ .name = "listPages", .title = "List browser pages", .description = "List live top-level pages and popups with stable numeric ids, URLs, titles, openerId and active selection. Iframes are excluded.", .inputSchema = empty_schema, .annotations = read_only },
    .{ .name = "selectPage", .title = "Select a browser page", .description = "Select a page by id for subsequent browser tools. Does not navigate.", .inputSchema = id_schema, .annotations = .{ .destructiveHint = false, .idempotentHint = true, .openWorldHint = false } },
    .{ .name = "newPage", .title = "Create a browser page", .description = "Create and select a top-level page sharing this session's cookies and storage. Optionally navigate to url and wait for load (timeout in milliseconds).", .inputSchema = lp.tools.minify("{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\"},\"timeout\":{\"type\":\"integer\",\"minimum\":1}}}"), .annotations = .{ .destructiveHint = false } },
    .{ .name = "closePage", .title = "Close a browser page", .description = "Close the given page, or the selected page when id is omitted. Other top-level pages remain open.", .inputSchema = lp.tools.minify("{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"integer\",\"minimum\":1}}}"), .annotations = .{ .openWorldHint = false } },
    .{ .name = "addInitScript", .title = "Install a document initialization script", .description = "Run script at the start of each future HTML document, before its page scripts, including redirects and popups. Does not run in already loaded documents. Returns an id for removal.", .inputSchema = lp.tools.minify("{\"type\":\"object\",\"properties\":{\"script\":{\"type\":\"string\"}},\"required\":[\"script\"]}"), .annotations = .{ .openWorldHint = false } },
    .{ .name = "removeInitScript", .title = "Remove a document initialization script", .description = "Remove a previously added initialization script. Existing documents keep changes the script already made.", .inputSchema = id_schema, .annotations = .{ .idempotentHint = true, .openWorldHint = false } },
    .{ .name = "setViewport", .title = "Set the browser viewport", .description = "Set the engine viewport width and height in CSS pixels for this browser session.", .inputSchema = lp.tools.minify("{\"type\":\"object\",\"properties\":{\"width\":{\"type\":\"integer\",\"minimum\":1},\"height\":{\"type\":\"integer\",\"minimum\":1}},\"required\":[\"width\",\"height\"]}"), .annotations = .{ .destructiveHint = false, .idempotentHint = true, .openWorldHint = false } },
};

const PageInfo = struct { id: u32, url: []const u8, title: []const u8, active: bool, openerId: ?u32 };

fn pageInfo(session: *lp.Session, page: *lp.Page) PageInfo {
    return .{
        .id = page.frame._frame_id,
        .url = page.frame.url,
        .title = (page.frame.getTitle() catch null) orelse "",
        .active = session.currentFrame() == &page.frame,
        .openerId = page.opener_frame_id,
    };
}

fn json(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{ .emit_null_optional_fields = false });
}

pub fn call(tool: Tool, arena: std.mem.Allocator, active: *lp.ToolSession, arguments: ?std.json.Value) ![]const u8 {
    const session = active.session;
    switch (tool) {
        .getStorageState => return state.get(arena, session),
        .setStorageState => {
            try state.set(arena, session, arguments);
            return json(arena, .{ .restored = true });
        },
        .listPages => {
            var pages: std.ArrayList(PageInfo) = .empty;
            for (session.pages.items) |page| {
                if (page.replaces != null or page.frame.window._closed) continue;
                try pages.append(arena, pageInfo(session, page));
            }
            return json(arena, pages.items);
        },
        .selectPage => {
            const args = try lp.tools.parseArgs(struct { id: u32 }, arena, arguments);
            const page = session.livePage(args.id) orelse return error.PageNotFound;
            if (page.frame.window._closed) return error.PageNotFound;
            active.registry.reset();
            session.followPopup(args.id);
            return json(arena, pageInfo(session, page));
        },
        .newPage => {
            const args = try lp.tools.parseArgsOrDefault(struct { url: []const u8 = "about:blank", timeout: u32 = 10000 }, arena, arguments);
            const url = try lp.URL.resolveNavigation(arena, args.url, .{});
            const handle = try session.createPage();
            errdefer handle.close();
            try handle.navigate(url, .{ .reason = .address_bar });
            var waiter = session.runner(.{});
            var conditions = [_]lp.Session.Runner.WaitCondition{.{ .frame_id = handle.frame_id, .until = .load }};
            if (try waiter.waitResult(args.timeout, &conditions) == .timeout) return error.Timeout;
            const page = handle.page() orelse return error.PageNotFound;
            if (page.frame._last_navigate_error != null) return error.NavigationFailed;
            active.registry.reset();
            session.followPopup(handle.frame_id);
            return json(arena, pageInfo(session, page));
        },
        .closePage => {
            const args = try lp.tools.parseArgsOrDefault(struct { id: ?u32 = null }, arena, arguments);
            const id = args.id orelse (session.currentFrame() orelse return error.PageNotFound)._frame_id;
            _ = session.livePage(id) orelse return error.PageNotFound;
            active.registry.reset();
            session.closePage(id);
            return json(arena, .{ .closed = true, .id = id });
        },
        .addInitScript => {
            const args = try lp.tools.parseArgs(struct { script: []const u8 }, arena, arguments);
            const owned = session.arena.allocator();
            const scripts = try owned.alloc([]const u8, session.inject_scripts.len + 1);
            @memcpy(scripts[0..session.inject_scripts.len], session.inject_scripts);
            scripts[scripts.len - 1] = try owned.dupe(u8, args.script);
            session.inject_scripts = scripts;
            return json(arena, .{ .id = scripts.len });
        },
        .removeInitScript => {
            const args = try lp.tools.parseArgs(struct { id: u32 }, arena, arguments);
            if (args.id == 0 or args.id > session.inject_scripts.len) return json(arena, .{ .removed = false });
            const scripts = try session.arena.allocator().dupe([]const u8, session.inject_scripts);
            const removed = scripts[args.id - 1].len != 0;
            scripts[args.id - 1] = "";
            session.inject_scripts = scripts;
            return json(arena, .{ .removed = removed });
        },
        .setViewport => {
            const args = try lp.tools.parseArgs(struct { width: u32, height: u32 }, arena, arguments);
            if (args.width == 0 or args.height == 0 or args.width > 100000 or args.height > 100000) return error.InvalidParams;
            session.browser.setViewportOverride(.{ .width = args.width, .height = args.height });
            return json(arena, args);
        },
    }
}
