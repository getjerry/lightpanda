const std = @import("std");
const lp = @import("lightpanda");
const storage = @import("../browser/webapi/storage/storage.zig");
// These are pure cookie-jar functions. No CDP transport or connection is used.
const cookie_state = @import("../server/cdp/domains/storage.zig");

const Item = struct { name: []const u8, value: []const u8 };
const Origin = struct {
    origin: [:0]const u8,
    localStorage: []const Item = &.{},
    indexedDB: ?std.json.Value = null,
};
const StoredCookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8,
    expires: f64,
    httpOnly: bool,
    secure: bool,
    sameSite: []const u8,
};
const Values = std.json.ArrayHashMap([]const u8);

fn items(arena: std.mem.Allocator, lookup: *const storage.Lookup) ![]const Item {
    const result = try arena.alloc(Item, lookup._data.count());
    var it = lookup._data.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        result[i] = .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* };
    }
    return result;
}

pub fn get(arena: std.mem.Allocator, session: *lp.Session) ![]const u8 {
    session.cookie_jar.removeExpired(null);
    const cookies = try arena.alloc(StoredCookie, session.cookie_jar.cookies.items.len);
    for (session.cookie_jar.cookies.items, cookies) |cookie, *out| {
        out.* = .{
            .name = cookie.name,
            .value = cookie.value,
            .domain = cookie.domain,
            .path = cookie.path,
            .expires = cookie.expires orelse -1,
            .httpOnly = cookie.http_only,
            .secure = cookie.secure,
            .sameSite = switch (cookie.same_site) {
                .strict => "Strict",
                .lax => "Lax",
                .none => "None",
            },
        };
    }
    var origins: std.ArrayList(Origin) = .empty;
    var it = session.storage_shed._origins.iterator();
    while (it.next()) |entry| {
        const origin = try arena.dupeZ(u8, entry.key_ptr.*);
        // Opaque origins have no portable storage-state representation.
        if (try lp.URL.getOrigin(arena, origin) == null) continue;
        try origins.append(arena, .{ .origin = origin, .localStorage = try items(arena, &entry.value_ptr.*.local) });
    }
    var session_storages: std.json.ArrayHashMap(Values) = .{};
    // Match Botly's existing snapshot: only live top-level pages, by hostname.
    for (session.pages.items) |page| {
        if (page.replaces != null or page.frame.window._closed) continue;
        const frame = &page.frame;
        if (frame.origin == null) continue;
        const bucket = session.storage_shed._origins.get(frame.js.origin.key) orelse continue;
        var values: Values = .{};
        var entries = bucket.session._data.iterator();
        while (entries.next()) |entry| try values.map.put(arena, entry.key_ptr.*, entry.value_ptr.*);
        try session_storages.map.put(arena, lp.URL.getHostname(frame.url), values);
    }
    return std.json.Stringify.valueAlloc(arena, .{
        .cookies = cookies,
        .origins = origins.items,
        .sessionStorages = session_storages,
    }, .{ .emit_null_optional_fields = false });
}

pub fn set(arena: std.mem.Allocator, session: *lp.Session, arguments: ?std.json.Value) !void {
    const Args = struct { state: struct {
        cookies: []const cookie_state.CdpCookie,
        origins: []const Origin,
    } };
    const args = try lp.tools.parseArgs(Args, arena, arguments);
    const allocator = session.browser.app.allocator;
    var staged_cookies = storage.Cookie.Jar.init(allocator, null);
    defer staged_cookies.deinit();
    var staged_storage: storage.Shed = .{};
    defer staged_storage.deinit(allocator);

    // Validate and allocate everything before changing the live cookie jar or
    // storage. Invalid input must not erase a working authenticated session.
    for (args.state.cookies) |cookie| {
        if (cookie.partitionKey != null) return error.UnsupportedPartitionedCookie;
        if (cookie.domain == null or cookie.domain.?.len == 0) return error.InvalidParams;
        if (cookie.path) |path| if (path.len == 0 or path[0] != '/') return error.InvalidParams;
        if (cookie.expires) |expires| {
            if (!std.math.isFinite(expires) or (expires < 0 and expires != -1)) return error.InvalidParams;
        }
        if (cookie.sameSite) |same_site| {
            if (!std.mem.eql(u8, same_site, "Strict") and !std.mem.eql(u8, same_site, "Lax") and !std.mem.eql(u8, same_site, "None")) return error.InvalidParams;
            if (std.mem.eql(u8, same_site, "None") and !(cookie.secure orelse false)) return error.InvalidParams;
        }
    }
    _ = try cookie_state.setCdpCookies(&staged_cookies, args.state.cookies);
    for (args.state.origins) |origin| {
        if (origin.indexedDB != null) return error.UnsupportedIndexedDB;
        if (!lp.URL.canParse(origin.origin, null)) return error.InvalidParams;
        const normalized = try lp.URL.resolve(arena, "", origin.origin, .{});
        const canonical = try lp.URL.getOrigin(arena, normalized) orelse return error.InvalidParams;
        if (!std.mem.eql(u8, canonical, origin.origin) or staged_storage._origins.contains(canonical)) return error.InvalidParams;
        const bucket = try staged_storage.getOrPut(allocator, canonical);
        for (origin.localStorage) |item| try bucket.local.setItem(item.name, item.value);
    }
    // Pre-create missing live buckets before committing. Keep existing Bucket
    // and Lookup addresses: page-side Storage objects may still reference them.
    var staged = staged_storage._origins.iterator();
    while (staged.next()) |entry| _ = try session.storage_shed.getOrPut(allocator, entry.key_ptr.*);
    var live = session.storage_shed._origins.iterator();
    while (live.next()) |entry| {
        if (staged_storage._origins.get(entry.key_ptr.*)) |bucket| {
            std.mem.swap(storage.Lookup, &entry.value_ptr.*.local, &bucket.local);
        } else entry.value_ptr.*.local.clear();
    }
    std.mem.swap(std.ArrayList(storage.Cookie), &session.cookie_jar.cookies, &staged_cookies.cookies);
}
