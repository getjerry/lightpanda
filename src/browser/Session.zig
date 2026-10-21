// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");
const lp = @import("lightpanda");

const App = @import("../App.zig");
const Config = @import("../Config.zig");

const History = @import("webapi/History.zig");
const storage = @import("webapi/storage/storage.zig");
const IdbManager = @import("webapi/storage/idb/idb.zig").Manager;
const CacheStore = @import("webapi/cache/Store.zig");
const Factory = @import("Factory.zig");
const EventTarget = @import("webapi/EventTarget.zig");
const Navigation = @import("webapi/navigation/Navigation.zig");

const Page = @import("Page.zig");
const Frame = @import("Frame.zig");
const Window = @import("webapi/Window.zig");
const Browser = @import("Browser.zig");
pub const Runner = @import("Runner.zig");
const Notification = @import("../Notification.zig");
const QueuedNavigation = Frame.QueuedNavigation;
const SharedWorkerGlobalScope = @import("webapi/SharedWorkerGlobalScope.zig");
const ServiceWorkerGlobalScope = @import("webapi/ServiceWorkerGlobalScope.zig");

const log = lp.log;
const ArenaPool = App.ArenaPool;

// A Session represents a browsing context group (cookie jar, session storage,
// navigation history) within a Browser. It owns a set of live Pages — each a
// root Frame and all of its descendants — and is responsible for Page
// lifecycle (create, remove, replace on root navigation).

const Session = @This();

browser: *Browser,
arena: *lp.Arena,
history: History,
navigation: *Navigation,
storage_shed: storage.Shed,
idb: IdbManager, // Per-origin IndexedDB engines
cache_store: CacheStore, // Per-origin CacheStorage
// Backs `globalThis.lp.*`; values pre-stringified so the prelude splices
// them in without re-encoding.
bridge_store: std.StringHashMapUnmanaged([]const u8) = .empty,
notification: *Notification,
cookie_jar: storage.Cookie.Jar,
/// User-provided scripts to inject into header.
inject_scripts: []const []const u8 = &.{},

// Shared allocator. Used by Session itself and borrowed by Pages.
arena_pool: *ArenaPool,

// All live top-level Pages. During a root navigation this transiently holds
// both the live page and its in-flight replacement.
pages: std.ArrayList(*Page) = .empty,

// CDP opts in; native MCP keeps its existing popup and navigation behavior.
independent_popup_pages: bool = false,
origins: std.StringHashMapUnmanaged(*lp.js.Origin) = .empty,
window_states: std.AutoHashMapUnmanaged(u32, *WindowState) = .empty,
_retained_pages: std.ArrayList(*Page) = .empty,
_deinitializing: bool = false,

// Live SharedWorkerGlobalScopes, keyed by "url\x00name", so every
// `new SharedWorker(url, name)` in the session connects to the same instance.
// Owned by the Page that creates it.
shared_workers: std.StringHashMapUnmanaged(*SharedWorkerGlobalScope) = .empty,

// url => SWGS. The SWGS is owned by the page, but can be shared with other
// pages by url.
service_workers: std.StringHashMapUnmanaged(*ServiceWorkerGlobalScope) = .empty,

_page_destruction_queue: std.ArrayList(*Page) = .empty,

// Round-robin cursor for fair page iteration (processQueuedNavigation)
_nav_cursor: usize = 0,

// Set by the agent script Runtime around one tool call so each `Page` handle's
// tools act on its own frame, not `pages[0]`. Null for all other callers.
// A frame id, not a pointer: a tool-triggered navigation commits a replacement
// Page mid-call, freeing the old Frame while keeping its frame id (see
// `commitPendingPage`).
_tool_frame_override: ?u32 = null,

// A popup the last tool action opened (target=_blank). Tools act on it, as
// a user whose click opened a tab would, until it goes away.
_followed_popup: ?u32 = null,

// Loader IDs are scoped to the Session: each new BrowserContext gets a
// fresh counter. Frame IDs (`frame_id_gen`) live on `Browser` instead so
// CDP target IDs stay unique across BrowserContext lifecycle on a single
// connection (see `Browser.frame_id_gen` and issue #2472).
loader_id_gen: u32 = 0,

// Console.* capture for the `consoleLogs` tool, capped at `max_console_bytes`.
// Opt-in via `enableConsoleCapture`: plain CDP `serve` never drains it, so
// leaving the listener off keeps the buffer at zero bytes.
_console_messages: std.Io.Writer.Allocating,
_console_capture: bool = false,

// configured external resources (images, stylesheet, worker, iframe) to load
load_resources: Config.LoadResources,

// opt-in unstable features (--experimental-features)
experimental_features: Config.ExperimentalFeatures,

/// Caller-supplied cancellation probe. `Runner._wait` polls it between
/// ticks; once `check` returns true the wait returns `error.Cancelled`.
/// The agent installs this so SIGINT can abort an in-flight tool call
/// (goto, search, waitForSelector, …) without sitting through the full
/// timeout.
cancel_hook: ?CancelHook = null,

// Download handling configured via the `Browser.setDownloadBehavior` CDP
// method (see issue #2701). When `download_behavior` is `.allow` or
// `.allow_and_name`, a navigation whose response carries
// `Content-Disposition: attachment` is written to `download_path` instead
// of being parsed as a page, and (when `download_events_enabled` is set)
// `Browser.downloadWillBegin` / `Browser.downloadProgress` events are emitted.
// `download_path` is duped into the Session arena.
download_behavior: DownloadBehavior = .deny,
download_path: ?[]const u8 = null,
download_events_enabled: bool = false,

pub const WindowState = struct {
    navigation: *Navigation,
    history: History = .{},
};

pub const DownloadBehavior = enum {
    allow,
    allow_and_name,
    // The CDP `default` behavior is mapped to `deny`: we don't write downloads
    // to disk unless the driver explicitly opts in with `allow`/`allowAndName`.
    deny,
};

const CancelHook = struct {
    context: *anyopaque,
    check: *const fn (*anyopaque) bool,
};

pub fn isCancelled(self: *const Session) bool {
    const hook = self.cancel_hook orelse return false;
    return hook.check(hook.context);
}

const max_console_bytes = 64 * 1024;

pub fn init(self: *Session, browser: *Browser, notification: *Notification) !void {
    const allocator = browser.app.allocator;
    const arena_pool = browser.arena_pool;

    const arena = try arena_pool.acquire(.small, "Session");
    errdefer arena.release();

    const navigation = try Factory.chainedWithAllocator(arena.allocator(), .{
        EventTarget{ ._type = .navigation },
        Navigation{ ._proto = undefined },
    });

    self.* = .{
        .arena = arena,
        .arena_pool = arena_pool,
        .history = .{},
        .navigation = navigation,
        .storage_shed = .{},
        .idb = IdbManager.init(allocator),
        .cache_store = CacheStore.init(allocator),
        .browser = browser,
        .notification = notification,
        .cookie_jar = storage.Cookie.Jar.init(allocator, notification),
        ._console_messages = .init(allocator),
        .load_resources = browser.app.config.loadResources(),
        .experimental_features = browser.app.config.experimentalFeatures(),
    };
    errdefer self._console_messages.deinit();
}

pub fn deinit(self: *Session) void {
    self._deinitializing = true;
    if (self._console_capture) {
        self.notification.unregister(.console_message, self);
    }

    self.closeAllPages();
    for (self._retained_pages.items) |page| {
        page.deinit();
        self.browser.page_pool.destroy(page);
    }
    self._retained_pages.clearRetainingCapacity();
    std.debug.assert(self.origins.count() == 0);

    // CorsGate/RobotsGate fetches are ownerless, so page/frame teardown above
    // never reaches them.
    //
    // They still carry this notification and can outlive it, so clear the pointer here or
    // Transfer.kill's later notify() dispatches through a freed Notification
    // once the caller runs notification.deinit() after this returns.
    var transfer_it = self.browser.http_client.transfers.valueIterator();
    while (transfer_it.next()) |t| {
        if (t.*.req.notification == self.notification) {
            t.*.req.notification = null;
        }
    }

    self.cookie_jar.deinit();

    {
        // Every context is disposed; this GC must not arm a termination.
        const env = &self.browser.env;
        const was_tearing_down = env.tearing_down;
        env.tearing_down = true;
        defer env.tearing_down = was_tearing_down;
        env.memoryPressureNotification(.critical);
    }

    self.storage_shed.deinit(self.browser.app.allocator);
    self.idb.deinit();
    self.cache_store.deinit();
    {
        const allocator = self.browser.app.allocator;
        var it = self.bridge_store.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.*);
        }
        self.bridge_store.deinit(allocator);
    }
    self._console_messages.deinit();
    self.arena.release();
}

/// Register the console listener so `drainConsoleMessages` returns output. Idempotent.
pub fn enableConsoleCapture(self: *Session) !void {
    if (self._console_capture) return;
    try self.notification.register(.console_message, self, onConsoleMessage);
    self._console_capture = true;
}

fn onConsoleMessage(ctx: *anyopaque, msg: *const Notification.ConsoleMessage) !void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    const aw = &self._console_messages;
    const start = aw.written().len;
    if (start >= max_console_bytes) return;

    // Format into a scratch buffer sized to the remaining budget so a single
    // 10 MB `console.log` can't bust the cap before the post-hoc check fires.
    const remaining = max_console_bytes - start;
    var scratch_buf: [max_console_bytes]u8 = undefined;
    var scratch: std.Io.Writer = .fixed(scratch_buf[0..remaining]);
    appendConsoleMessageInner(&scratch, msg) catch {};
    aw.writer.writeAll(scratch.buffered()) catch {
        aw.shrinkRetainingCapacity(start);
    };
}

fn appendConsoleMessageInner(w: *std.Io.Writer, msg: *const Notification.ConsoleMessage) !void {
    try w.print("[{s}] ", .{@tagName(msg.type)});
    for (msg.values, 0..) |value, i| {
        if (i > 0) try w.writeAll(" ");
        try value.format(w);
    }
    try w.writeByte('\n');
}

/// Drains and clears the buffered console output. The returned slice is valid
/// until the next dispatched `console_message` reuses the backing storage,
/// so callers must consume or copy it before that happens.
pub fn drainConsoleMessages(self: *Session) []const u8 {
    const text = self._console_messages.written();
    self._console_messages.clearRetainingCapacity();
    return text;
}

pub fn processDestroyQueues(self: *Session) void {
    {
        const queue = self._page_destruction_queue.items;
        if (queue.len > 0) {
            for (queue) |page| {
                if (comptime lp.IS_DEBUG) {
                    std.debug.assert(log.currentPage() != &page.log_context);
                }
                page.deinit();
                self.browser.page_pool.destroy(page);
            }
            self._page_destruction_queue.clearRetainingCapacity();
        }
    }
}

pub fn hasPage(self: *const Session) bool {
    return self.pages.items.len != 0;
}

pub fn windowState(self: *Session, frame_id: u32) !*WindowState {
    const gop = try self.window_states.getOrPut(self.arena.allocator(), frame_id);
    if (gop.found_existing) return gop.value_ptr.*;
    errdefer _ = self.window_states.remove(frame_id);
    const state = try self.arena.create(WindowState);
    state.* = .{ .navigation = try Factory.chainedWithAllocator(self.arena.allocator(), .{
        EventTarget{ ._type = .navigation },
        Navigation{ ._proto = undefined },
    }) };
    gop.value_ptr.* = state;
    return state;
}

pub fn findPopupByName(self: *Session, name: []const u8) ?*Frame {
    for (self.pages.items) |page| {
        if (page.replaces == null and page.script_opened and std.mem.eql(u8, page.frame.window._name, name)) return &page.frame;
    }
    return null;
}

// Cached cross-page Window references must not point into a freed arena.
// Retain only exposed documents, inert, until the execution's Session ends.
fn retainPage(self: *Session, page: *Page) void {
    deactivateFrame(&page.frame);
    for (self.browser.env.contexts.items) |ctx| {
        if (ctx.page == page) {
            self.idb.detachContext(ctx);
            self.browser.http_client.abortOwner(ctx.global.httpOwner());
            ctx.scheduler.reset();
        }
    }
    self._retained_pages.append(self.arena.allocator(), page) catch @panic("OOM");
}

fn deactivateFrame(frame: *Frame) void {
    frame.window._closed = true;
    frame.cancelQueuedNavigation();
    for (frame.child_frames.items) |child| deactivateFrame(child);
}

fn updateOpener(frame: *Frame, old: *Window, replacement: ?*Window) void {
    if (frame.window._opener) |opener| {
        if (opener._frame.page == old._frame.page) {
            frame.window._opener = if (opener == old) replacement else null;
        }
    }
    for (frame.child_frames.items) |child| updateOpener(child, old, replacement);
}

fn replaceOpenerReferences(self: *Session, old: *Window, replacement: ?*Window) void {
    if (!self.independent_popup_pages) return;
    for (self.pages.items) |page| updateOpener(&page.frame, old, replacement);
    for (self._retained_pages.items) |page| updateOpener(&page.frame, old, replacement);
}

fn copyWindowMetadata(from: *Page, to: *Page) !void {
    to.opener_frame_id = from.opener_frame_id;
    to.script_opened = from.script_opened;
    to.frame.window._opener = from.frame.window._opener;
    to.frame.window._name = try to.frame_arena.dupe(u8, from.frame.window._name);
}

// Allocate and initialize a Page.
fn allocatePage(self: *Session, frame_id: u32) !*Page {
    const browser = self.browser;
    const page = try browser.page_pool.create(browser.allocator);
    errdefer browser.page_pool.destroy(page);

    try Page.init(page, self, frame_id);
    return page;
}

// Tear down and free a Page allocated via allocatePage.
fn queuePageDestruction(self: *Session, page: *Page) void {
    if (page.destroying) {
        // see Page.destroying field for why this is necessary.
        return;
    }
    page.destroying = true;
    if (!self._deinitializing and self.independent_popup_pages and page.has_external_window_refs) {
        self.retainPage(page);
        return;
    }
    self._page_destruction_queue.append(self.arena.allocator(), page) catch @panic("OOM");
}

fn retire(self: *Session, page: *Page) void {
    if (page.replaces) |live| {
        // page is being destroyed, if it was replacing a page, then update that
        // page's replacement to keep replaces<->replacement consistent.
        live.replacement = null;
        // Might have retired while transfer was active and the Frame's
        // header/error callback might still happen. Setting this null prevents
        // those callbacks from using this page post-retirement
        page.replaces = null;
    }

    if (page.replacement) |replacement| {
        // page is being destroyed, also detroy its replacement
        self.discardPendingPage(replacement);
    }

    page.frame.abortTransfers();
    self.removePageFromList(page);
    self.queuePageDestruction(page);
}

fn removePageFromList(self: *Session, page: *Page) void {
    if (std.mem.indexOfScalar(*Page, self.pages.items, page)) |i| {
        _ = self.pages.swapRemove(i);
    }
}

// Tear down the currently-active Page. Dispatches `frame_remove` first
// so CDP can clear inspector state while the OLD page is still walkable,
// then frees the slot and notifies Navigation. Used by removePage and
// by the synthetic-nav path (replaceRootImmediate). Does NOT touch any
// pending page — callers handle that themselves.
//
// Frame IDs are NOT reset here — the counter lives on `Browser` and is
// monotonic for the lifetime of the CDP connection so target IDs stay
// unique (issue #2472). The previous reset-to-zero behaviour was
// invisible within a single Session/BrowserContext (the next
// `installNewActivePage` was usually called with the old frame's
// explicit `frame_id`, see `replaceRootImmediate`) but caused
// `Duplicate target FID-...` collisions when a new BrowserContext
// allocated its first page after dispose.
//
// NOT a substitute for the careful 5-step sequence in commitPendingPage,
// which interleaves the OLD-page teardown with the pending-page promotion
// in a specific order.
fn tearDownPage(self: *Session, page: *Page, closed: bool) void {
    self.notification.dispatch(.frame_remove, .{ .frame_id = page.frame._frame_id, .closed = closed });
    if (closed) self.replaceOpenerReferences(page.frame.window, null);
    page.navigation.onRemoveFrame();
    self.retire(page);
}

// Allocate a Page in a free slot, publish it as the active page, and
// dispatch `frame_created` so CDP can bind its page handle to the new
// frame. Used by createPage and by the synthetic-nav path. Does NOT
// dispatch `frame_navigate` — the caller does that (or doesn't, for a
// blank initial page).
//
// On any failure after allocation, the errdefers roll back the Page
// and `active`, leaving the session pageless (the caller is responsible
// for any prior teardown of an old page).
fn installNewActivePage(self: *Session, frame_id: u32, previous: ?*Page) !*Frame {
    const page = try self.allocatePage(frame_id);
    errdefer self.queuePageDestruction(page);

    if (self.independent_popup_pages) {
        if (previous) |old| try copyWindowMetadata(old, page);
    }
    try self.pages.append(self.arena.allocator(), page);
    errdefer _ = self.pages.pop();

    const frame = &page.frame;
    // Inform CDP the main frame has been created so it can point its page
    // handle at the new frame.
    self.notification.dispatch(.frame_created, frame);
    return frame;
}

pub fn createPage(self: *Session) !PageHandle {
    // Drain any pending Page deinits now, while we're at a known-safe point
    self.processDestroyQueues();

    if (comptime lp.IS_DEBUG) {
        log.debug(.browser, "create page", .{});
    }

    const frame_id = self.nextFrameId();
    const frame = try self.installNewActivePage(frame_id, null);

    // https://html.spec.whatwg.org/multipage/document-sequences.html --
    // Creating a new browsing context always produces an initial about:blank
    // Document with its own session history entry, even before any real
    // navigation happens. Without this, navigation.currentEntry crashes on
    // a page that hasn't navigated yet.
    _ = try frame.navigation().pushEntry(
        frame.url,
        .{ .source = .navigation, .value = null },
        frame,
        false,
    );
    frame.navigation()._initial_entry = true;

    return .{ .session = self, .frame_id = frame_id };
}

pub fn createPopupPage(self: *Session, opening_frame: *Frame, url: [:0]const u8, name: []const u8, opener: ?*Window) !*Frame {
    const frame_id = self.nextFrameId();
    const page = try self.allocatePage(frame_id);
    errdefer self.queuePageDestruction(page);
    const frame = &page.frame;
    page.script_opened = true;
    page.opener_frame_id = opening_frame.page.frame._frame_id;
    frame.window._opener = opener;
    frame.window._name = try page.frame_arena.dupe(u8, if (std.ascii.eqlIgnoreCase(name, "_blank")) "" else name);
    try self.pages.append(self.arena.allocator(), page);
    errdefer self.removePageFromList(page);
    _ = try frame.navigation().pushEntry(frame.url, .{ .source = .navigation, .value = null }, frame, false);
    frame.navigation()._initial_entry = true;
    // A new window exposes a same-origin initial about:blank synchronously,
    // even when CDP auto-attach pauses its eventual network navigation.
    try frame.navigate("about:blank", .{ .reason = .script, .initiator_origin = opening_frame.origin });
    if (opener) |creator| {
        if (creator._frame.origin == null) {
            // Null origin strings do not identify opaque origins: the initial
            // blank document must share its creator's actual security token.
            const origin = creator._frame.js.origin;
            origin.rc += 1;
            page.releaseOrigin(frame.js.origin);
            frame.js.origin = origin;
            var ls: lp.js.Local.Scope = undefined;
            frame.js.localScope(&ls);
            defer ls.deinit();
            const token = lp.js.v8.v8__Global__Get(&origin.security_token, frame.js.isolate.handle);
            lp.js.v8.v8__Context__SetSecurityToken(ls.local.handle, token);
        }
    }
    self.notification.dispatch(.frame_created, frame);
    if (!std.mem.eql(u8, url, "about:blank")) {
        try page.deferInitialNavigation(url, .{ .reason = .script, .initiator_origin = opening_frame.origin });
    }
    return frame;
}

// Tear down the live page for `frame_id` and any in-flight replacement.
pub fn closePage(self: *Session, frame_id: u32) void {
    const live = self.livePage(frame_id) orelse return;

    // If a navigation is in flight, drop the pending Page first. Its
    // transfer was protected from abort to survive commitPendingPage's
    // teardown of the old page, but we are now permanently removing the
    // page state — the pending transfer should die with it.
    if (self.replacementOf(live)) |pending| {
        self.discardPendingPage(pending);
    }
    self.tearDownPage(live, true);
}

// Does not dispatch notifications. Used in session.deinit() and used in tests.
// We queue then process so that there is a single place (processDestroyQueues)
// where pages get destroyed.
pub fn closeAllPages(self: *Session) void {
    for (self.pages.items) |page| {
        page.frame.abortTransfers();
        self.queuePageDestruction(page);
    }
    self.pages.clearRetainingCapacity();
    self.processDestroyQueues();
}

pub fn getArena(self: *Session, size_or_bucket: anytype, debug: []const u8) !*lp.Arena {
    return self.arena_pool.acquire(size_or_bucket, debug);
}

// For an arena owned by a JS-exposed object, freed by its finalizer.
pub fn getPinnedArena(self: *Session, size_or_bucket: anytype, debug: []const u8) !*lp.Arena {
    return self.arena_pool.acquirePinned(&self.browser.arena_account, size_or_bucket, debug);
}

pub fn stopLoading(self: *Session, frame_id: u32) void {
    const live = self.livePage(frame_id) orelse return;
    if (self.replacementOf(live)) |pending| {
        pending.frame.stopLoading();
    }
    live.frame.stopLoading();
}

pub fn livePage(self: *Session, frame_id: u32) ?*Page {
    for (self.pages.items) |page| {
        if (page.frame._frame_id == frame_id) {
            // If this page is replacing another page, then other page is
            // considered the "live" on. Only once this page is committed will
            // that swap.
            return page.replaces orelse page;
        }
    }
    return null;
}

pub fn pendingOrLivePage(self: *Session, frame_id: u32) ?*Page {
    for (self.pages.items) |page| {
        if (page.frame._frame_id == frame_id) {
            return page.replacement orelse page;
        }
    }
    return null;
}

// The in-flight replacement for `page`
pub fn replacementOf(self: *Session, page: *Page) ?*Page {
    const replacement = page.replacement;

    if (comptime lp.IS_DEBUG) {
        // quick check to make sure our replacement <=> replaces link is in sync
        var found: ?*Page = null;
        for (self.pages.items) |p| {
            if (p.replaces == page) {
                found = p;
                break;
            }
        }
        std.debug.assert(found == replacement);
    }
    return replacement;
}

// DEPRECATED.
// Needed by Runner so long as Runner is largel single-page driven.
// Ultimately the goal is that runner is full multi-page, but during this
// transition to multi-page sessions, we maintain the idea that one page is
// the "main" page.
pub fn primaryPage(self: *Session) ?PageHandle {
    if (self.pages.items.len == 0) {
        return null;
    }
    const page = self.pages.items[0];
    if (comptime lp.IS_DEBUG) {
        std.debug.assert(page.replaces == null);
    }
    return .{ .session = self, .frame_id = page.frame._frame_id };
}

// DEPRECATED. Exists during our transition to multi-page sessions.
pub fn currentFrame(self: *Session) ?*Frame {
    if (self._tool_frame_override) |frame_id| {
        // No pages[0] fallthrough: the override targets one specific page.
        return self.findFrameByFrameId(frame_id);
    }
    if (self._followed_popup) |frame_id| {
        if (self.findFrameByFrameId(frame_id)) |frame| {
            return frame;
        }
        self._followed_popup = null;
    }
    if (self.pages.items.len == 0) {
        return null;
    }
    const page = self.pages.items[0];
    if (comptime lp.IS_DEBUG) {
        std.debug.assert(page.replaces == null);
    }
    return &page.frame;
}

/// See `_tool_frame_override`. Pass null to clear.
pub fn setToolFrameOverride(self: *Session, frame_id: ?u32) void {
    self._tool_frame_override = frame_id;
}

/// See `_followed_popup`.
pub fn followPopup(self: *Session, frame_id: u32) void {
    self._followed_popup = frame_id;
}

// Multi-page aware: frame ids are globally unique (monotonic on `Browser`).
// First we find the "live" page for a frame, then we search every nested
// frame within that page.
pub fn findFrameByFrameId(self: *Session, frame_id: u32) ?*Frame {
    if (self.livePage(frame_id)) |page| {
        return &page.frame;
    }
    for (self.pages.items) |page| {
        if (page.findFrameByFrameId(frame_id)) |frame| {
            return frame;
        }
    }
    return null;
}

pub fn runner(self: *Session, opts: Runner.Opts) Runner {
    return Runner.init(self, opts);
}

/// Page transfers run on the session thread's curl multi; left unserviced
/// while the frontend waits on input they die on curl's wall-clock timeout.
/// Returns how long the caller may block before pumping again.
pub fn idleSlice(self: *Session) u31 {
    const quiet_ms = 250;
    self.processDestroyQueues();

    if (self.pages.items.len == 0) {
        // no page, we don't want the watchdog to kill us.
        self.browser.http_client.heartbeat.disarm();
        return quiet_ms;
    }
    const page = self.pages.items[0];

    var r = self.runner(.{});
    const result = r.tickForFrame(page.frame._frame_id, 25, .{ .until = .done }) catch return quiet_ms;
    return switch (result) {
        .done => quiet_ms,
        .ok => |next_ms| @intCast(@min(next_ms, quiet_ms)),
    };
}

pub fn scheduleNavigation(_: *Session, frame: *Frame) !void {
    return frame.page.scheduleNavigation(frame);
}

// Drain one page's queued navigations and return whether any page had work.
// Processing a root navigation mutates self.pages, so it's safer to do this
// just once, signal the caller, and have them call again. We use a cursor
// to prevent one page from starving the rest.
pub fn processQueuedNavigation(self: *Session) !bool {
    const pages = self.pages.items;
    if (pages.len == 0) {
        return false;
    }

    var i = self._nav_cursor;
    if (i >= pages.len) {
        i = 0;
    }

    for (0..pages.len) |_| {
        const page = pages[i];

        i += 1;
        if (i == pages.len) {
            i = 0;
        }

        if (page.close_requested) {
            self._nav_cursor = i;
            self.closePage(page.frame._frame_id);
            return true;
        }
        if (page.waiting_for_debugger) continue;
        if (page.deferred_initial_navigation) |navigation| {
            page.deferred_initial_navigation = null;
            self._nav_cursor = i;
            // Init scripts may already have run in the initial blank realm.
            // A new document needs a new realm, while keeping the target id.
            try self.initiateRootNavigation(page.frame._frame_id, navigation.url, navigation.opts);
            return true;
        }
        if (page.queued_navigation.items.len != 0) {
            // i was already incremented (and wrapped) to the "next" page
            self._nav_cursor = i;
            try self.processPageQueuedNavigation(page);
            return true;
        }
    }
    return false;
}

fn processPageQueuedNavigation(self: *Session, page: *Page) !void {
    const navigations = page.queued_navigation;
    if (page.queued_navigation == &page.queued_navigation_1) {
        page.queued_navigation = &page.queued_navigation_2;
    } else {
        page.queued_navigation = &page.queued_navigation_1;
    }

    if (page.frame._queued_navigation != null) {
        // This is both an optimization and a simplification of sorts. If the
        // root frame is navigating, then we don't need to process any other
        // navigation. Also, the navigation for the root frame and for a frame
        // is different enough that have two distinct code blocks is, imo,
        // better. Yes, there will be duplication.
        navigations.clearRetainingCapacity();
        return self.processRootQueuedNavigation(page);
    }

    const about_blank_queue = &page.queued_queued_navigation;
    defer about_blank_queue.clearRetainingCapacity();

    // First pass: process async navigations (non-about:blank)
    for (navigations.items) |frame| {
        const qn = frame._queued_navigation orelse {
            // Was previously an assert; downgraded so prod can recover, but
            // kept at warn so the invariant violation isn't silently lost.
            log.warn(.frame, "skipped null queued nav", .{});
            continue;
        };

        if (qn.is_about_something) {
            // Defer about:blank or about:srcdoc to second pass
            try about_blank_queue.append(self.arena.allocator(), frame);
            continue;
        }

        // qn is invalid after this
        self.processFrameNavigation(frame, qn) catch {
            // already logged
        };
    }

    navigations.clearRetainingCapacity();

    // Second pass: process synchronous navigations (about:blank)
    // These may trigger new navigations which go into queued_navigation.
    // Mirror the first pass: a failure on one frame must not orphan the
    // rest of the queue (the `defer clearRetainingCapacity` would wipe
    // siblings whose _queued_navigation stays set).
    for (about_blank_queue.items) |frame| {
        const qn = frame._queued_navigation orelse {
            // Was previously an assert; downgraded so prod can recover, but
            // kept at warn so the invariant violation isn't silently lost.
            log.warn(.frame, "skipped null queued nav", .{});
            continue;
        };
        self.processFrameNavigation(frame, qn) catch |err| {
            log.debug(.frame, "frame navigation", .{ .url = qn.url, .err = err });
        };
    }

    // Safety: Remove any about:blank navigations that were queued during
    // processing to prevent infinite loops. New navigations have been queued
    // in the other buffer.
    const new_navigations = page.queued_navigation;
    var i: usize = 0;
    while (i < new_navigations.items.len) {
        const frame = new_navigations.items[i];
        if (frame._queued_navigation) |qn| {
            if (qn.is_about_something) {
                log.debug(.frame, "recursive about blank", .{});
                _ = page.queued_navigation.swapRemove(i);
                continue;
            }
        }
        i += 1;
    }
}

fn processFrameNavigation(self: *Session, frame: *Frame, qn: *QueuedNavigation) !void {
    frame._queued_navigation = null;
    defer qn.arena.release();

    // A popup whose window was close()'d is parked in page.closed_frames and
    // torn down at Page.deinit. It must never be navigated. This navigation
    // can happen _after_ window.close() has been called (because JS can do
    // anything with that window), so the safest place to prevent navigation
    // from happening is here.
    if (frame.window._closed) {
        return;
    }

    self._processFrameNavigation(frame, qn) catch |err| {
        log.debug(.frame, "frame navigation", .{ .url = qn.url, .err = err });
        return err;
    };
}

fn _processFrameNavigation(self: *Session, frame: *Frame, qn: *QueuedNavigation) !void {
    // Popups live on the Page as top-level browsing contexts without a
    // parent or iframe element. Their re-navigation path is simpler than
    // iframes — no parent bookkeeping to patch.
    if (frame.parent == null and frame.iframe == null) {
        return self.processPopupNavigation(frame, qn);
    }

    lp.assert(frame.parent != null, "root queued navigation", .{});

    const iframe = frame.iframe.?;
    const parent = frame.parent.?;

    errdefer iframe._window = null;

    // was the previous navigation of this frame delaying the paren't load event?
    const was_delaying = frame._delays_parent_load and !frame._parent_notified;

    // we weren't delaying the parent' load navigation, but now we should
    const starts_delaying = !was_delaying and !iframe.isLazyLoading();

    if (starts_delaying) {
        parent._pending_loads += 1;
    }

    const frame_id = frame._frame_id;
    const reuse_window = frame.window;
    const page = frame.page;
    frame.deinit();
    frame.* = undefined;

    errdefer {
        // If anything fails from this point on, frame.deinit will be called
        // and we need to remove the frame from the parent's frame list.
        for (parent.child_frames.items, 0..) |f, i| {
            if (f == frame) {
                parent.child_frames_sorted = false;
                _ = parent.child_frames.swapRemove(i);
                break;
            }
        }
    }

    try Frame.init(frame, frame_id, page, .{ .parent = parent, .reuse_window = reuse_window });
    errdefer {
        if (starts_delaying) {
            parent._pending_loads -= 1;
        }
        frame.deinit();
    }

    frame.iframe = iframe;
    // If we transition from was_delaying to !starts_delaying, we could potentially
    // call `parent._pending_loads -= 1;` but it's hard to reason through the
    // edge cases. So instead we carry it over, at worse delaying the parent's load
    // in the very unlikely case that the iframe was switch from non-lazy to lazy.
    frame._delays_parent_load = was_delaying or starts_delaying;
    iframe._window = frame.window;

    frame.navigate(qn.url, qn.opts) catch |err| {
        log.debug(.browser, "queued frame navigation error", .{ .err = err });
        return err;
    };
}

// Re-navigates a popup Frame in place. Both the Frame pointer and its Window
// stay stable across the re-init, so a cached `window.open()` return value keeps
// a valid `.location` instead of dangling against the freed one.
fn processPopupNavigation(_: *Session, frame: *Frame, qn: *QueuedNavigation) !void {
    // Preserve popup identity fields. _name lives in the Page arena and
    // survives Frame.deinit; _opener is just a pointer.

    const reuse_window = frame.window;
    const saved_name = reuse_window._name;
    const saved_opener = reuse_window._opener;
    const frame_id = frame._frame_id;
    const page = frame.page;

    frame.deinit();
    frame.* = undefined;

    errdefer {
        // If re-init fails, drop from popups so we don't leave a corpse.
        for (page.popups.items, 0..) |p, i| {
            if (p == frame) {
                _ = page.popups.swapRemove(i);
                break;
            }
        }
    }

    try Frame.init(frame, frame_id, page, .{ .reuse_window = reuse_window });
    errdefer frame.deinit();

    frame.window._name = saved_name;
    frame.window._opener = saved_opener;

    frame.navigate(qn.url, qn.opts) catch |err| {
        log.debug(.browser, "queued popup navigation error", .{ .err = err });
        return err;
    };
}

fn processRootQueuedNavigation(self: *Session, page: *Page) !void {
    const current_frame = &page.frame;

    // Detach the QueuedNavigation. Whether we keep it on the active frame
    // (synthetic path) or transfer it to the pending frame (HTTP path), the
    // current frame must no longer claim it.
    const qn = current_frame._queued_navigation.?;
    current_frame._queued_navigation = null;

    // Synthetic navigations (about:blank, blob:) commit instantly — no HTTP,
    // so there is no in-flight window to worry about. Use the optimized
    // immediate-swap path for them.
    const is_synthetic = qn.is_about_something or std.mem.startsWith(u8, qn.url, "blob:");

    // The qn arena is consumed here regardless of success — frame.navigate
    // dupes the URL into the page's own arena, so we can release the qn
    // arena as soon as navigate returns.
    defer qn.arena.release();

    if (is_synthetic) {
        return self.replaceRootImmediate(current_frame._frame_id, qn.url, qn.opts);
    }
    return self.initiateRootNavigation(current_frame._frame_id, qn.url, qn.opts);
}

// Immediate-swap path for synthetic navigations (about:blank, blob:): there is
// no in-flight HTTP and therefore no "pending" window to span — and no
// frameHeaderDoneCallback to commit a pending Page. Tear down the active page
// and create a new one in its place, then navigate it. Reached from both the
// queued-navigation path (processRootQueuedNavigation) and the CDP entry point
// (initiateRootNavigation); each caller owns any arena tied to `url`/`opts`.
fn replaceRootImmediate(self: *Session, frame_id: u32, url: [:0]const u8, opts: Frame.NavigateOpts) !void {
    const previous = self.livePage(frame_id) orelse return error.FrameNotFound;
    self.tearDownPage(previous, false);
    const new_frame = try self.installNewActivePage(frame_id, previous);
    self.replaceOpenerReferences(previous.frame.window, new_frame.window);

    new_frame.navigate(url, opts) catch |err| {
        log.debug(.browser, "synthetic navigation error", .{ .err = err, .url = url });
        return err;
    };
}

// Real HTTP root navigation: allocate a pending Page, leave the active Page
// alive, and dispatch the navigation HTTP request against the pending frame.
// The active Page (and its V8 context) stays addressable across the round-
// trip — Runtime.evaluate, DOM.*, etc. continue to operate on the OLD page
// until commitPendingPage swaps the pointer when response headers arrive.
pub fn initiateRootNavigation(self: *Session, frame_id: u32, url: [:0]const u8, opts: Frame.NavigateOpts) !void {
    const live = self.livePage(frame_id) orelse {
        lp.assert(false, "Session.initiateRootNavigation - no live page", .{});
    };

    // Re-navigation before a previous root nav committed: drop the outstanding
    // replacement so `replaces` stays a single link, never a chain.
    if (self.replacementOf(live)) |old_replacement| {
        self.discardPendingPage(old_replacement);
    }

    // Synthetic navigations (about:blank, blob:) have no HTTP round-trip and
    // therefore no frameHeaderDoneCallback to commit a pending Page. Swap the
    // active Page immediately instead of allocating a pending one that would
    // never be promoted, leaving the previous document in place (issue #2363).
    if (std.mem.eql(u8, "about:blank", url) or std.mem.startsWith(u8, url, "blob:")) {
        return self.replaceRootImmediate(frame_id, url, opts);
    }

    const page = try self.allocatePage(frame_id);
    errdefer self.queuePageDestruction(page);

    // Reuses `live`'s frame_id: the replacement IS the same browsing context.
    // `replaces` keeps `live` addressable until commit; the `replacement`
    // back-pointer is its inverse
    if (self.independent_popup_pages) try copyWindowMetadata(live, page);
    page.replaces = live;
    live.replacement = page;

    errdefer live.replacement = null;
    try self.pages.append(self.arena.allocator(), page);
    // don't just pop, frame.navitate() can itself remove this page from the pages list
    errdefer self.removePageFromList(page);

    if (comptime lp.IS_DEBUG) {
        log.debug(.browser, "initiate root navigation", .{ .url = url });
    }

    // No frame_created notification yet — CDP must not see the pending page
    // (no isolated worlds, no Target.* visibility). Both the pending main
    // world and the isolated worlds get registered with the V8 inspector at
    // commit, after frame_remove tears down the OLD page's context group.

    page.frame.navigate(url, opts) catch |err| {
        log.debug(.browser, "pending navigation start", .{ .err = err, .url = url });
        return err;
    };

    live.frame.abortDocumentLoad();
    live.frame.abortedDocumentIsComplete();
}

// Promote a pending replacement Page to be the live Page.
// Called from frameHeaderDoneCallback, aka when we get the headers, of the
// replacement page.
//
// Order matters here:
//   1. frame_remove dispatch — CDP's frameRemove resets the V8 inspector
//      context group (emits Runtime.executionContextsCleared) and clears
//      isolated world contexts plus the node_registry. OLD is still the live
//      page and its memory is alive (intentional: CDP teardown can walk
//      old-page state without UAF).
//   2. frame_created dispatch — CDP rebinds its page handle to the new
//      frame. `replacement.replaces` is still set, so the session still
//      reports an in-flight nav and CDP's frameCreated skips its frame_arena
//      reset and captured_responses zeroing (the captured response for the
//      request we are committing was just inserted by
//      onHttpResponseHeadersDone moments earlier and must survive). The
//      isolated worlds emptied in step 1 are NOT refilled here — CDP rebuilds
//      their contexts on the frame_navigate the caller dispatches afterwards.
//   3. Promote: clear `replaces` and unlink OLD from `pages`, so
//      `currentFrame()` / `livePage()` now resolve to `replacement`. Done AFTER
//      step 2 so the in-commit signal (replaces != null) survives the dispatch
//      — this is why no separate "committing" flag is needed.
//   4. Tear down OLD last.
pub fn commitPendingPage(self: *Session, replacement: *Page) !void {
    const old = replacement.replaces orelse {
        lp.assert(false, "Session.commitPendingPage - page has no replaces", .{});
    };

    if (comptime lp.IS_DEBUG) {
        log.debug(.browser, "commit pending page", .{});
    }

    // Step 1: clear the OLD page's CDP / V8 inspector state while it is still
    // walkable (node_registry, inspector context group, isolated worlds). OLD
    // is still the live page (index 0); its memory stays alive until step 4.
    self.notification.dispatch(.frame_remove, .{ .frame_id = old.frame._frame_id });
    old.navigation.onRemoveFrame();

    // Step 2: register the new page with CDP. `replacement.replaces` is still
    // set, so the session still reports an in-flight nav and CDP's frameCreated
    // skips the captured_responses / frame_arena reset that would wipe the
    // response we just received.
    self.notification.dispatch(.frame_created, &replacement.frame);

    // Step 3: promote — clear `replaces` and unlink OLD so  `livePage()`
    // resolve to `replacement` (both share OLD's frame_id). OLD stays allocated
    // (torn down next) but is no longer the addressable live page.

    old.replacement = null;
    replacement.replaces = null;
    self.removePageFromList(old);
    self.replaceOpenerReferences(old.frame.window, replacement.frame.window);

    // Step 4: tear down the OLD page LAST. Anything in steps 1-3 that needed to
    // walk the OLD page's state has already done so. Kill any remaining
    // transfers/websockets synchronously before queuing for deferred destroy —
    // otherwise a still-inflight transfer firing its done_callback after this
    // point would re-enter against the now-live `replacement` and trip a
    // half-torn-down session.
    old.frame.abortTransfers();
    self.queuePageDestruction(old);
}

// Discard a pending Page without committing. Used for failure paths
// (HTTP error before commit, session deinit during pending, etc.). The
// active page is untouched.
pub fn discardPendingPage(self: *Session, replacement: *Page) void {
    if (comptime lp.IS_DEBUG) {
        log.debug(.browser, "discard pending page", .{});
    }

    // Force abort all inflight queries (HTTP + WS) and queue for deferred
    // destroy. The live page it was replacing is untouched.
    self.retire(replacement);
}

// Frame IDs come from `Browser` (per-CDP-connection scope), not
// `Session` (per-BrowserContext). Kept as a Session method so existing
// callers (Frame, Worker) don't have to thread a Browser pointer.
pub fn nextFrameId(self: *Session) u32 {
    return self.browser.nextFrameId();
}

pub fn nextLoaderId(self: *Session) u32 {
    const id = self.loader_id_gen +% 1;
    self.loader_id_gen = id;
    return id;
}

// A stable, navigation-safe reference to a top-level browsing context (what
// `openPage` opens).
pub const PageHandle = struct {
    frame_id: u32,
    session: *Session,

    pub fn frame(self: PageHandle) ?*Frame {
        return &(self.page() orelse return null).frame;
    }

    pub fn page(self: PageHandle) ?*Page {
        return self.session.livePage(self.frame_id);
    }

    pub fn inCommit(self: PageHandle) bool {
        const live = self.page() orelse return false;
        return self.session.replacementOf(live) != null;
    }

    pub fn close(self: PageHandle) void {
        self.session.closePage(self.frame_id);
    }

    pub fn navigate(self: PageHandle, request_url: [:0]const u8, opts: Frame.NavigateOpts) !void {
        const f = self.frame() orelse return error.FrameNotLoaded;
        return f.navigate(request_url, opts);
    }
};

const testing = @import("../testing.zig");
test "Session: retiring a pending page destroys it once" {
    const session = testing.test_session;
    defer session.closeAllPages();

    const handle = try session.createPage();
    const live = handle.page().?;

    // A pending root navigation, set up like initiateRootNavigation does.
    const pending = try session.allocatePage(live.frame._frame_id);
    pending.replaces = live;
    live.replacement = pending;
    try session.pages.append(session.arena.allocator(), pending);

    // Its transfer failed inside submit(): the error_callback discards the
    // pending page...
    session.discardPendingPage(pending);
    try testing.expectEqual(null, pending.replaces);
    try testing.expectEqual(null, live.replacement);

    // ...and then submit's error unwinds initiateRootNavigation's errdefers
    // over a page that is already off the list and already queued.
    session.removePageFromList(pending);
    session.queuePageDestruction(pending);

    try testing.expectEqual(1, session.pages.items.len);
    try testing.expectEqual(live, session.pages.items[0]);
    try testing.expectEqual(1, session._page_destruction_queue.items.len);

    // Would deinit `pending` twice if it had been queued twice.
    session.processDestroyQueues();
}

test "Session: console capture runs no page JS" {
    const js = @import("js/js.zig");

    const session = testing.test_session;
    try session.enableConsoleCapture();
    defer {
        session.notification.unregister(.console_message, session);
        session._console_capture = false;
        session._console_messages.clearRetainingCapacity();
    }

    const frame = try testing.createFrame();
    defer session.closeAllPages();

    var ls: js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.exec(
        \\globalThis.probed = 0;
        \\const probe = { toString() { globalThis.probed++; console.log('inner'); return 'outer'; } };
        \\console.log('head', probe, 10n, Symbol('s'));
    , null);

    try testing.expectEqualSlices(u8, "[log] head [object Object] 10n Symbol(s)\n", session.drainConsoleMessages());
    const probed = try ls.local.exec("globalThis.probed", null);
    try testing.expectEqual(0, try probed.toF64());
}

test "Session: independent ordinary pages reclaim navigation documents" {
    var ts: @import("../ToolSession.zig") = undefined;
    try ts.init(testing.test_app);
    defer ts.deinit();
    const session = ts.session;
    session.independent_popup_pages = true;
    const handle = try session.createPage();
    var waiter = session.runner(.{});
    for (0..4) |_| {
        try session.initiateRootNavigation(handle.frame_id, "http://127.0.0.1:9582/src/browser/tests/hi.html", .{});
        try waiter.waitForFrame(handle.frame_id, 2000, .{ .until = .load });
        try session.initiateRootNavigation(handle.frame_id, "about:blank", .{});
        session.processDestroyQueues();
        try testing.expectEqual(1, session.pages.items.len);
        try testing.expectEqual(0, session._retained_pages.items.len);
        try testing.expectEqual(1, ts.browser.env.contexts.items.len);
    }
    handle.close();
    session.processDestroyQueues();
    try testing.expectEqual(0, ts.browser.env.contexts.items.len);
    try testing.expectEqual(0, session.origins.count());
}

test "Session: independent popup forwards cached windows across navigation and close" {
    const check = checkWindowScript;
    var ts: @import("../ToolSession.zig") = undefined;
    try ts.init(testing.test_app);
    defer ts.deinit();
    const session = ts.session;
    session.independent_popup_pages = true;
    const handle = try session.createPage();
    try handle.navigate("http://127.0.0.1:9582/src/browser/tests/mcp_actions.html", .{});
    var waiter = session.runner(.{});
    try waiter.waitForFrame(handle.frame_id, 2000, .{ .until = .load });
    const opener = handle.frame().?;
    try check(opener, "document.cookie = 'popupShared=1; path=/'; localStorage.setItem('popupShared', 'yes'); window.child = window.open('mcp_actions.html', 'quote'); child.document.body !== null");
    const popup_id = session.findPopupByName("quote").?._frame_id;
    try waiter.waitForFrame(popup_id, 2000, .{ .until = .load });
    var popup = session.findFrameByFrameId(popup_id).?;
    try testing.expect(popup.page != opener.page);
    try testing.expectEqual(handle.frame_id, popup.page.opener_frame_id.?);
    try testing.expectEqual(opener.js.origin, popup.js.origin);
    try testing.expect(popup.navigation() != opener.navigation());
    try check(opener, "!child.closed && child.document.querySelector('#inp') !== null");
    try check(popup, "document.cookie.includes('popupShared=1') && localStorage.getItem('popupShared') === 'yes' && opener.document.querySelector('#inp') !== null");

    // The original JS window.open result follows B's new document, including
    // postMessage delivery into B's new context rather than its retired one.
    try session.initiateRootNavigation(popup_id, "http://127.0.0.1:9582/src/browser/tests/runner/runner1.html", .{});
    try waiter.waitForFrame(popup_id, 2000, .{ .until = .load });
    popup = session.findFrameByFrameId(popup_id).?;
    try check(opener, "!child.closed && child.document.querySelector('#sel1') !== null && child.location.href.endsWith('runner1.html')");
    try check(popup, "window.savedOpener = opener; onmessage = e => window.received = e.data; history.pushState({quote: 1}, '', '#quote'); true");
    try check(opener, "child.postMessage('new popup context', '*'); true");
    try waiter.waitForScript(popup_id, "window.received === 'new popup context'", 1000);
    const popup_history_length = popup.navigation()._entries.items.len;

    // The reciprocal cached opener forwards as A navigates, without replacing
    // or closing B or mixing their independent navigation histories.
    try session.initiateRootNavigation(handle.frame_id, "http://127.0.0.1:9582/src/browser/tests/runner/runner1.html", .{});
    try waiter.waitForFrame(handle.frame_id, 2000, .{ .until = .load });
    try testing.expectEqual(popup, session.findFrameByFrameId(popup_id).?);
    try testing.expectEqual(handle.frame().?.window, popup.window._opener.?);
    try testing.expectEqual(popup_history_length, popup.navigation()._entries.items.len);
    try check(popup, "!savedOpener.closed && savedOpener.document.querySelector('#sel1') !== null");
    try check(handle.frame().?, "onmessage = e => window.received = e.data; true");
    try check(popup, "savedOpener.postMessage('new opener context', '*'); true");
    try waiter.waitForScript(handle.frame_id, "window.received === 'new opener context'", 1000);
    try testing.expectEqual(false, opener.js.scheduler.blocksCompletion());

    handle.close();
    session.processDestroyQueues();
    try testing.expectEqual(null, popup.window._opener);
    try check(popup, "savedOpener.closed && document.querySelector('#sel1') !== null");
    // Retired realms keep native Window references safe, but run no queued
    // promises or timers and release fully when the Session ends.
    try check(popup, "window.retiredRan = false; Promise.resolve().then(() => retiredRan = true); setInterval(() => retiredRan = true, 1); true");
    popup.window.close();
    try testing.expectEqual(true, try session.processQueuedNavigation());
    ts.browser.runMicrotasks();
    try ts.browser.runMacrotasks();
    try check(popup, "retiredRan === false");
    try testing.expectEqual(null, session.findFrameByFrameId(popup_id));
    try testing.expectEqual(0, session.pages.items.len);
    try testing.expectEqual(false, popup.js.scheduler.blocksCompletion());
    try testing.expectEqual(true, popup.window._closed);
    try ts.restartSession();
    try testing.expectEqual(0, ts.browser.env.contexts.items.len);
    try testing.expectEqual(0, ts.session._retained_pages.items.len);
}

test "Session: paused popup defers its request without blocking other pages" {
    var ts: @import("../ToolSession.zig") = undefined;
    try ts.init(testing.test_app);
    defer ts.deinit();
    const session = ts.session;
    session.independent_popup_pages = true;
    const opener = try session.createPage();
    try opener.navigate("about:blank", .{});

    var pause_popups = true;
    try ts.notification.register(.frame_created, &pause_popups, struct {
        fn created(ctx: *anyopaque, frame: *Frame) !void {
            const pause: *bool = @ptrCast(@alignCast(ctx));
            if (frame.page.script_opened) frame.page.waiting_for_debugger = pause.*;
        }
    }.created);
    defer ts.notification.unregister(.frame_created, &pause_popups);
    const popup = try opener.frame().?.openPopup(.{
        .url = "http://127.0.0.1:9582/src/browser/tests/mcp_actions.html",
        .name = "paused",
        .opener = opener.frame().?.window,
    });
    try testing.expect(popup.page.waiting_for_debugger);
    try testing.expectEqual(opener.frame().?.js.origin, popup.js.origin);
    try testing.expect(Window.Access.init(opener.frame().?.window, popup.window) == .window);
    try testing.expect(popup.page.deferred_initial_navigation != null);
    try testing.expect(popup._load_state == .complete);
    try testing.expectEqual(false, try session.processQueuedNavigation());

    const other = try session.createPage();
    try other.navigate("http://127.0.0.1:9582/src/browser/tests/runner/runner1.html", .{});
    var waiter = session.runner(.{});
    try waiter.waitForFrame(other.frame_id, 2000, .{ .until = .load });
    _ = try waiter.waitForSelector(other.frame_id, "#sel1", 10);
    try testing.expect(popup._load_state == .complete);

    const popup_id = popup._frame_id;
    pause_popups = false;
    popup.page.waiting_for_debugger = false;
    try testing.expectEqual(true, try session.processQueuedNavigation());
    try waiter.waitForFrame(popup_id, 2000, .{ .until = .load });
    _ = try waiter.waitForSelector(popup_id, "#inp", 10);
    try testing.expectEqual(null, session.findFrameByFrameId(popup_id).?.page.deferred_initial_navigation);
}

fn checkWindowScript(frame: *Frame, source: [:0]const u8) !void {
    var ls: lp.js.Local.Scope = undefined;
    frame.js.localScope(&ls);
    defer ls.deinit();
    const value = try ls.local.exec(source, null);
    try testing.expect(value.isTrue());
}

test "Session: independent message source survives navigation and checks current origin" {
    var ts: @import("../ToolSession.zig") = undefined;
    try ts.init(testing.test_app);
    defer ts.deinit();
    const session = ts.session;
    session.independent_popup_pages = true;
    const sender = try session.createPage();
    try sender.navigate("http://127.0.0.1:9582/src/browser/tests/mcp_actions.html", .{});
    var waiter = session.runner(.{});
    try waiter.waitForFrame(sender.frame_id, 2000, .{ .until = .load });
    const source = sender.frame().?;
    try checkWindowScript(source, "window.child = window.open('mcp_actions.html', 'receiver'); true");
    const receiver_id = session.findPopupByName("receiver").?._frame_id;
    try waiter.waitForFrame(receiver_id, 2000, .{ .until = .load });
    const receiver = session.findFrameByFrameId(receiver_id).?;
    try checkWindowScript(receiver, "onmessage = e => window.savedEvent = e; true");
    try testing.expectEqual(false, source.page.has_external_window_refs);
    try checkWindowScript(source, "child.postMessage('queued', '*'); true");
    try testing.expect(source.page.has_external_window_refs);
    try session.initiateRootNavigation(sender.frame_id, "http://localhost:9582/src/browser/tests/runner/runner1.html", .{});
    try waiter.waitForFrame(sender.frame_id, 2000, .{ .until = .load });
    try waiter.waitForScript(receiver_id, "window.savedEvent !== undefined", 1000);
    try checkWindowScript(receiver,
        \\window.savedSource = savedEvent.source;
        \\['document', 'location', 'history', 'navigation'].every(key => {
        \\  try { savedSource[key]; return false; } catch (e) { return e.name === 'SecurityError'; }
        \\}) && !savedSource.closed
    );
    try checkWindowScript(sender.frame().?, "window.received = ''; onmessage = e => window.received = e.data; true");
    try checkWindowScript(receiver, "savedSource.postMessage('wrong origin', 'http://127.0.0.1:9582'); true");
    try ts.browser.runMacrotasks();
    try checkWindowScript(sender.frame().?, "received === ''");
    try checkWindowScript(receiver, "savedSource.postMessage('current origin', 'http://localhost:9582'); true");
    try waiter.waitForScript(sender.frame_id, "received === 'current origin'", 1000);
    sender.close();
    session.processDestroyQueues();
    try checkWindowScript(receiver, "savedSource.closed");
}

test "Session: independent iframe popup survives removal of its opener document" {
    var ts: @import("../ToolSession.zig") = undefined;
    try ts.init(testing.test_app);
    defer ts.deinit();
    const session = ts.session;
    session.independent_popup_pages = true;
    const handle = try session.createPage();
    try handle.navigate("http://127.0.0.1:9582/src/browser/tests/runner/iframe_idle.html", .{});
    var waiter = session.runner(.{});
    try waiter.waitForFrame(handle.frame_id, 2000, .{ .until = .load });
    const iframe = handle.frame().?.child_frames.items[1];
    const popup = try iframe.openPopup(.{ .url = "about:blank", .name = "iframe-popup", .opener = iframe.window });
    try testing.expectEqual(handle.frame_id, popup.page.opener_frame_id.?);
    try session.initiateRootNavigation(handle.frame_id, "about:blank", .{});
    session.processDestroyQueues();
    try testing.expectEqual(null, popup.window._opener);
    try testing.expectEqual(popup, session.findFrameByFrameId(popup._frame_id).?);
    try checkWindowScript(popup, "opener === null && document.body !== null");
}
