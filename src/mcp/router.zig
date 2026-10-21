const std = @import("std");
const lp = @import("lightpanda");

const protocol = @import("protocol.zig");

const log = lp.log;

// Storage snapshots and initialization scripts can exceed the stdin reader's
// 64 KiB buffer. Bound the complete JSON-RPC frame, not an individual read.
pub const max_request_bytes = 32 * 1024 * 1024;

/// Generic over the server type. The server must expose: `allocator`, a
/// `transport: Transport` field, and the per-method `handleInitialize`,
/// `handleToolList`, `handleToolCall` methods. `handleResourceList` /
/// `handleResourceRead` are optional — servers that don't expose
/// resources can omit them and the router returns `MethodNotFound`
/// automatically. When `input` is the file behind `reader`, the server must
/// also expose `idle`: the router then pumps the browser session between
/// requests instead of blocking on the read.
pub fn processRequests(server: anytype, reader: *std.Io.Reader, input: ?std.Io.File) !void {
    return processRequestsWithLimit(server, reader, input, max_request_bytes);
}

fn processRequestsWithLimit(server: anytype, reader: *std.Io.Reader, input: ?std.Io.File, limit: usize) !void {
    var arena: std.heap.ArenaAllocator = .init(server.allocator);
    defer arena.deinit();

    while (true) {
        _ = arena.reset(.{ .retain_with_limit = 256 * 1024 });
        const aa = arena.allocator();

        if (input) |file| idleUntilInput(server, reader, file);

        const buffered_line = readMessage(reader, aa, limit) catch |err| switch (err) {
            error.StreamTooLong => {
                log.debug(.mcp, "Message too long", .{});
                try server.sendError(.null, .InvalidRequest, "Message too long");
                _ = reader.discardDelimiterInclusive('\n') catch |e| switch (e) {
                    error.EndOfStream => break,
                    else => return e,
                };
                continue;
            },
            else => return err,
        } orelse break;

        const trimmed = std.mem.trim(u8, buffered_line, " \r\t");
        if (trimmed.len > 0) {
            handleMessage(server, aa, trimmed) catch |err| {
                log.err(.mcp, "Failed to handle message", .{ .err = err, .message_bytes = trimmed.len });
            };
        }
    }
}

fn readMessage(reader: *std.Io.Reader, arena: std.mem.Allocator, limit: usize) !?[]const u8 {
    var line: std.Io.Writer.Allocating = .init(arena);
    // One extra byte lets a frame exactly at the limit reach its delimiter.
    const count = try reader.streamDelimiterLimit(&line.writer, '\n', .limited(limit + 1));
    if (reader.bufferedLen() != 0) {
        reader.toss(1); // streamDelimiterLimit leaves the newline buffered.
    } else if (count == 0) return null;
    return line.written();
}

/// Returns once `reader` holds a delimiter or the fd is readable —
/// `readMessage` may still block on a partial line, but MCP clients write
/// whole lines. A full buffer also returns so readMessage can drain it.
fn idleUntilInput(server: anytype, reader: *std.Io.Reader, file: std.Io.File) void {
    while (std.mem.indexOfScalar(u8, reader.buffered(), '\n') == null and
        reader.bufferedLen() < reader.buffer.len)
    {
        const wait_ms = server.idle();
        var fds = [_]std.posix.pollfd{.{ .fd = file.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, wait_ms) catch return;
        if (ready > 0) return;
    }
}

const Method = enum {
    initialize,
    ping,
    @"notifications/initialized",
    @"tools/list",
    @"tools/call",
    @"resources/list",
    @"resources/read",
};

const method_map = std.StaticStringMap(Method).initComptime(.{
    .{ "initialize", .initialize },
    .{ "ping", .ping },
    .{ "notifications/initialized", .@"notifications/initialized" },
    .{ "tools/list", .@"tools/list" },
    .{ "tools/call", .@"tools/call" },
    .{ "resources/list", .@"resources/list" },
    .{ "resources/read", .@"resources/read" },
});

pub fn handleMessage(server: anytype, arena: std.mem.Allocator, msg: []const u8) !void {
    const req = std.json.parseFromSliceLeaky(protocol.Request, arena, msg, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.debug(.mcp, "JSON Parse Error", .{ .err = err, .message_bytes = msg.len });
        try server.sendError(.null, .ParseError, "Parse error");
        return;
    };

    const method = method_map.get(req.method) orelse {
        if (req.id != null) {
            try server.sendError(req.id.?, .MethodNotFound, "Method not found");
        }
        return;
    };

    switch (method) {
        .initialize => try server.handleInitialize(req),
        .ping => try handlePing(server, req),
        .@"notifications/initialized" => {},
        .@"tools/list" => try server.handleToolList(arena, req),
        .@"tools/call" => try server.handleToolCall(arena, req),
        .@"resources/list" => try handleOptional(server, req, "handleResourceList", .{req}),
        .@"resources/read" => try handleOptional(server, req, "handleResourceRead", .{ arena, req }),
    }
}

fn handleOptional(server: anytype, req: protocol.Request, comptime method: []const u8, args: anytype) !void {
    if (@hasDecl(@TypeOf(server.*), method)) {
        try @call(.auto, @field(@TypeOf(server.*), method), .{server} ++ args);
    } else if (req.id) |id| {
        try server.sendError(id, .MethodNotFound, "Method not supported");
    }
}

fn handlePing(server: anytype, req: protocol.Request) !void {
    const id = req.id orelse return;
    try server.sendResult(id, struct {}{});
}

const Server = @import("Server.zig");
const testing = @import("../testing.zig");

test "MCP.router - handleMessage - synchronous unit tests" {
    const allocator = testing.allocator;
    const app = testing.test_app;

    var out_alloc: std.Io.Writer.Allocating = .init(testing.arena_allocator);
    defer out_alloc.deinit();

    var server = try Server.init(allocator, app, &out_alloc.writer);
    defer server.deinit();

    const aa = testing.arena_allocator;

    // 1. Valid handshake
    try handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-client","version":"1.0.0"}}}
    );
    try testing.expectJson(
        \\{ "jsonrpc": "2.0", "id": 1, "result": { "protocolVersion": "2024-11-05", "capabilities": { "tools": {} } } }
    , out_alloc.writer.buffered());
    out_alloc.writer.end = 0;

    // 2. Ping
    try handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
    );
    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 2, .result = struct {}{} }, out_alloc.writer.buffered());
    out_alloc.writer.end = 0;

    // 3. Tools list
    try handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/list"}
    );
    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 3 }, out_alloc.writer.buffered());
    try testing.expect(std.mem.indexOf(u8, out_alloc.writer.buffered(), "\"name\":\"goto\"") != null);
    out_alloc.writer.end = 0;

    // 4. Method not found
    try handleMessage(server, aa,
        \\{"jsonrpc":"2.0","id":4,"method":"unknown_method"}
    );
    try testing.expectJson(.{ .jsonrpc = "2.0", .id = 4, .@"error" = .{ .code = -32601 } }, out_alloc.writer.buffered());
    out_alloc.writer.end = 0;

    // 5. Parse error
    {
        try handleMessage(server, aa, "invalid json");
        try testing.expectJson("{\"jsonrpc\": \"2.0\", \"id\": null, \"error\": {\"code\": -32700}}", out_alloc.writer.buffered());
    }
}

test "MCP.router - storage and init scripts span input buffers; oversized frames recover" {
    const aa = testing.arena_allocator;
    var out: std.Io.Writer.Allocating = .init(aa);
    const server = try Server.init(testing.allocator, testing.test_app, &out.writer);
    defer server.deinit();
    const payload = try aa.alloc(u8, 96 * 1024);
    @memset(payload, 'x');
    const state_request = try std.json.Stringify.valueAlloc(aa, .{ .id = 11, .method = "tools/call", .params = .{
        .name = "setStorageState",
        .arguments = .{ .state = .{ .cookies = &.{}, .origins = &.{.{ .origin = "https://state.test", .localStorage = &.{.{ .name = "large", .value = payload }} }} } },
    } }, .{});
    const script_request = try std.json.Stringify.valueAlloc(aa, .{ .id = 12, .method = "tools/call", .params = .{
        .name = "addInitScript",
        .arguments = .{ .script = try std.fmt.allocPrint(aa, "/*{s}*/", .{payload}) },
    } }, .{});
    const input = try std.fmt.allocPrint(aa, "{s}\n{s}\n", .{ state_request, script_request });
    var fixed: std.Io.Reader = .fixed(input);
    var buffer: [64 * 1024]u8 = undefined;
    var reader = fixed.limited(.unlimited, &buffer);
    try processRequests(server, &reader.interface, null);
    var responses = std.mem.tokenizeScalar(u8, out.written(), '\n');
    try testing.expectJson(.{ .id = 11, .result = .{ .isError = false } }, responses.next().?);
    try testing.expectJson(.{ .id = 12, .result = .{ .isError = false } }, responses.next().?);
    try testing.expect(responses.next() == null);
    try testing.expectEqual(payload, server.active_session.session.storage_shed._origins.get("https://state.test").?.local.getItem("large").?);
    try testing.expectEqual(1, server.active_session.session.inject_scripts.len);

    // An oversized line is discarded through its newline; the next frame is
    // still a valid JSON-RPC request. Use a small limit to exercise the same path.
    out.clearRetainingCapacity();
    const ping = "{\"id\":13,\"method\":\"ping\"}";
    const padding = " " ** 64;
    const bounded_input = try std.fmt.allocPrint(aa, "{s}{s}\n{s}{s}\n{{\"id\":15,\"method\":\"ping\"}}", .{
        ping, padding[0 .. 64 - ping.len], ping, padding[0 .. 65 - ping.len],
    });
    var oversized: std.Io.Reader = .fixed(bounded_input);
    var small_buffer: [16]u8 = undefined;
    var small_reader = oversized.limited(.unlimited, &small_buffer);
    try processRequestsWithLimit(server, &small_reader.interface, null, 64);
    responses = std.mem.tokenizeScalar(u8, out.written(), '\n');
    try testing.expectJson(.{ .id = 13, .result = struct {}{} }, responses.next().?); // Exactly 64 bytes.
    try testing.expectJson(.{ .id = null, .@"error" = .{ .code = -32600, .message = "Message too long" } }, responses.next().?); // 65 bytes.
    try testing.expectJson(.{ .id = 15, .result = struct {}{} }, responses.next().?); // EOF without newline.
    try testing.expect(responses.next() == null);
}
