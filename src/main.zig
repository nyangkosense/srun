// srun
// Reads from stdin. Type to filter, up/down to select, enter to launch.
// See LICENSE for copyright license details.

const std = @import("std");

const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xft/Xft.h");
    @cInclude("fontconfig/fontconfig.h");
});

// ---- config ----

const dfont = "monospace:size=11";
const dprompt = "> ";
const dbg = "#1e1e2e";
const dfg = "#cdd6f4";
const dselbg = "#45475a";
const dselfg = "#f5e0dc";
const dbdc = "#89b4fa";
const dlines: u32 = 20;
const dwidth: u32 = 600;
const line_h: i32 = 24;
const border_px: u32 = 2;
const pad: i32 = 6;

// ---- limits ----

const max_entries = 4096;
const max_input = 512;
const stdin_buf_sz: usize = 1 << 19;

// ---- keysyms ----

const XK_Return: c_ulong = 0xff0d;
const XK_Escape: c_ulong = 0xff1b;
const XK_BackSpace: c_ulong = 0xff08;
const XK_Delete: c_ulong = 0xffff;
const XK_Up: c_ulong = 0xff52;
const XK_Down: c_ulong = 0xff54;
const XK_Home: c_ulong = 0xff50;
const XK_End: c_ulong = 0xff57;

// ---- config state (overridable via flags) ----

var sfont: [256]u8 = undefined;
var sprompt: [128]u8 = undefined;
var sbg: [32]u8 = undefined;
var sfg: [32]u8 = undefined;
var sselbg: [32]u8 = undefined;
var sselfg: [32]u8 = undefined;
var sbdc: [32]u8 = undefined;
var cfg_lines: u32 = dlines;
var cfg_width: u32 = dwidth;

fn setZ(buf: []u8, val: []const u8) [*:0]const u8 {
    if (val.len >= buf.len) die("string too long", .{});
    @memcpy(buf[0..val.len], val);
    buf[val.len] = 0;
    return buf[0..val.len :0].ptr;
}

fn zptr(buf: []u8) [*:0]const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end :0].ptr;
}

// ---- entry state ----

var stdin_buf: [stdin_buf_sz]u8 = undefined;
var entries: [max_entries][]const u8 = undefined;
var nentries: usize = 0;
var matched: [max_entries]usize = undefined;
var nmatched: usize = 0;
var input: std.BoundedArray(u8, max_input) = .{};
var sel: usize = 0;
var off: usize = 0;

// ---- X11 state ----

var dpy: *c.Display = undefined;
var win: c.Window = undefined;
var xftdraw: *c.XftDraw = undefined;
var xftfont: *c.XftFont = undefined;
var visual: *c.Visual = undefined;
var cmap: c.Colormap = undefined;
var xbg: c.XftColor = undefined;
var xfg: c.XftColor = undefined;
var xselbg: c.XftColor = undefined;
var xselfg: c.XftColor = undefined;
var xprompt: c.XftColor = undefined;

// ---- helpers ----

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    const w = std.io.getStdErr().writer();
    w.print("srun: " ++ fmt, args) catch {};
    w.writeByte('\n') catch {};
    std.process.exit(1);
}

fn usage() noreturn {
    const w = std.io.getStdErr().writer();
    w.writeAll(
        \\usage: srun [-l lines] [-fn font] [-p prompt] [-w width]
        \\              [-nb color] [-nf color] [-sb color] [-sf color] [-bc color]
        \\
    ) catch {};
    std.process.exit(1);
}

fn xftColor(name: [*:0]const u8) c.XftColor {
    var color: c.XftColor = undefined;
    if (c.XftColorAllocName(dpy, visual, cmap, name, &color) == 0)
        die("cannot allocate color: {s}", .{name});
    return color;
}

fn winH() u32 {
    return (cfg_lines + 1) * @as(u32, @intCast(line_h));
}

// ---- arg parsing ----

fn parseArgs() void {
    var args = std.process.args();
    _ = args.next() orelse return;
    while (args.next()) |a| {
        const eq = struct {
            fn is(s: []const u8, t: []const u8) bool {
                return std.mem.eql(u8, s, t);
            }
        }.is;
        if (eq(a, "-l")) {
            const v = args.next() orelse usage();
            cfg_lines = std.fmt.parseInt(u32, v, 10) catch die("bad number: {s}", .{v});
        } else if (eq(a, "-fn")) {
            _ = setZ(&sfont, args.next() orelse usage());
        } else if (eq(a, "-p")) {
            _ = setZ(&sprompt, args.next() orelse usage());
        } else if (eq(a, "-w")) {
            const v = args.next() orelse usage();
            cfg_width = std.fmt.parseInt(u32, v, 10) catch die("bad number: {s}", .{v});
        } else if (eq(a, "-nb")) {
            _ = setZ(&sbg, args.next() orelse usage());
        } else if (eq(a, "-nf")) {
            _ = setZ(&sfg, args.next() orelse usage());
        } else if (eq(a, "-sb")) {
            _ = setZ(&sselbg, args.next() orelse usage());
        } else if (eq(a, "-sf")) {
            _ = setZ(&sselfg, args.next() orelse usage());
        } else if (eq(a, "-bc")) {
            _ = setZ(&sbdc, args.next() orelse usage());
        } else {
            usage();
        }
    }
}

// ---- entry reading ----

fn readEntries() void {
    const stdin = std.io.getStdIn();
    const n = stdin.readAll(&stdin_buf) catch die("read stdin", .{});
    var start: usize = 0;
    for (stdin_buf[0..n], 0..) |ch, i| {
        if (ch == '\n') {
            if (i > start and nentries < max_entries) {
                entries[nentries] = stdin_buf[start..i];
                nentries += 1;
            }
            start = i + 1;
        }
    }
    if (start < n and nentries < max_entries) {
        entries[nentries] = stdin_buf[start..n];
        nentries += 1;
    }
}

// ---- matching ----

fn toLower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

fn containsI(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |ch, j| {
            if (toLower(hay[i + j]) != toLower(ch)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn matchEntries() void {
    nmatched = 0;
    const pat = input.slice();
    for (0..nentries) |i| {
        if (containsI(entries[i], pat)) {
            matched[nmatched] = i;
            nmatched += 1;
        }
    }
    if (sel >= nmatched)
        sel = if (nmatched > 0) nmatched - 1 else 0;
    adjustOff();
}

fn adjustOff() void {
    if (sel < off) off = sel;
    if (sel >= off + cfg_lines) off = sel - cfg_lines + 1;
}

// ---- drawing ----

fn textW(text: []const u8) i32 {
    var ext: c.XGlyphInfo = undefined;
    c.XftTextExtentsUtf8(dpy, xftfont, text.ptr, @intCast(text.len), &ext);
    return ext.xOff;
}

fn drawStr(x: i32, y: i32, text: []const u8, color: [*c]const c.XftColor) void {
    c.XftDrawStringUtf8(xftdraw, color, xftfont, x, y, text.ptr, @intCast(text.len));
}

fn drawRect(x: i32, y: i32, w: u32, h: u32, color: [*c]const c.XftColor) void {
    c.XftDrawRect(xftdraw, color, x, y, w, h);
}

fn draw() void {
    const w = cfg_width;
    const h = winH();
    const asc: i32 = xftfont.ascent;
    const lh: i32 = line_h;
    drawRect(0, 0, w, h, &xbg);
    const pslice = std.mem.sliceTo(zptr(&sprompt), 0);
    const pw = textW(pslice);
    drawStr(pad, asc + 2, pslice, &xprompt);
    const islice = input.slice();
    const ix = pad + pw;
    drawStr(ix, asc + 2, islice, &xfg);
    const cx = ix + textW(islice);
    drawRect(cx, 4, 2, @intCast(xftfont.height), &xfg);
    const vis = @min(nmatched, cfg_lines);
    for (0..vis) |i| {
        const mi = off + i;
        if (mi >= nmatched) break;
        const my: i32 = @intCast((i + 1) * @as(usize, @intCast(lh)));
        const entry = entries[matched[mi]];
        if (mi == sel) {
            drawRect(0, my, w, @intCast(lh), &xselbg);
            drawStr(pad, my + asc + 2, entry, &xselfg);
        } else {
            drawStr(pad, my + asc + 2, entry, &xfg);
        }
    }
    _ = c.XFlush(dpy);
}

// ---- spawn ----

fn spawn(cmd: []const u8) void {
    var child = std.process.Child.init(
        &.{ "/bin/sh", "-c", cmd },
        std.heap.page_allocator,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch {};
}

fn cleanup() void {
    c.XftFontClose(dpy, xftfont);
    c.XftDrawDestroy(xftdraw);
    _ = c.XDestroyWindow(dpy, win);
    _ = c.XCloseDisplay(dpy);
}

fn launch(cmd: []const u8) noreturn {
    spawn(cmd);
    cleanup();
    std.process.exit(0);
}

// ---- key handling ----

fn handleKey(ev: *c.XKeyEvent) void {
    var buf: [32]u8 = undefined;
    var ks: c.KeySym = 0;
    const n = c.XLookupString(ev, &buf, @intCast(buf.len), &ks, null);
    if (ks == XK_Return) {
        if (nmatched > 0 and sel < nmatched)
            launch(entries[matched[sel]]);
        cleanup();
        std.process.exit(1);
    }
    if (ks == XK_Escape) {
        cleanup();
        std.process.exit(1);
    }
    if (ks == XK_BackSpace or ks == XK_Delete) {
        if (input.pop()) |_| {
            sel = 0;
            matchEntries();
            draw();
        }
        return;
    }
    if (ks == XK_Up) {
        if (sel > 0) sel -= 1;
        adjustOff();
        draw();
        return;
    }
    if (ks == XK_Down) {
        if (sel + 1 < nmatched) sel += 1;
        adjustOff();
        draw();
        return;
    }
    if (ks == XK_Home) {
        sel = 0;
        adjustOff();
        draw();
        return;
    }
    if (ks == XK_End) {
        sel = if (nmatched > 0) nmatched - 1 else 0;
        adjustOff();
        draw();
        return;
    }
    const ctrl = ev.state & c.ControlMask != 0;
    if (n == 0 and ctrl and (ks == 'u' or ks == 'U')) {
        input.resize(0) catch {};
        sel = 0;
        matchEntries();
        draw();
        return;
    }
    if (n == 0 and ctrl and (ks == 'n' or ks == 'N')) {
        if (sel + 1 < nmatched) sel += 1;
        adjustOff();
        draw();
        return;
    }
    if (n == 0 and ctrl and (ks == 'p' or ks == 'P')) {
        if (sel > 0) sel -= 1;
        adjustOff();
        draw();
        return;
    }
    if (n > 0 and buf[0] >= 0x20) {
        for (buf[0..@as(usize, @intCast(n))]) |ch|
            input.append(ch) catch {};
        sel = 0;
        off = 0;
        matchEntries();
        draw();
    }
}

// ---- X11 init ----

fn xinit() void {
    dpy = c.XOpenDisplay(null) orelse die("cannot open display", .{});
    const scr: c_int = 0;
    const s = c.XScreenOfDisplay(dpy, scr) orelse die("no screen", .{});
    const root = s.*.root;
    const sw = s.*.width;
    visual = s.*.root_visual orelse die("no visual", .{});
    cmap = s.*.cmap;
    const wh = winH();
    const wx = @divTrunc(@as(c_int, @intCast(sw)) - @as(c_int, @intCast(cfg_width)), 2);
    const wy: c_int = 0;
    var swa: c.XSetWindowAttributes = std.mem.zeroes(c.XSetWindowAttributes);
    swa.override_redirect = 1;
    swa.event_mask = c.ExposureMask | c.KeyPressMask | c.StructureNotifyMask;
    win = c.XCreateWindow(
        dpy,
        root,
        wx,
        wy,
        cfg_width,
        wh,
        border_px,
        c.CopyFromParent,
        c.CopyFromParent,
        visual,
        c.CWOverrideRedirect | c.CWEventMask,
        &swa,
    );
    xftdraw = c.XftDrawCreate(dpy, win, visual, cmap) orelse die("XftDrawCreate", .{});
    xftfont = c.XftFontOpenName(dpy, scr, zptr(&sfont)) orelse
        die("cannot load font: {s}", .{std.mem.sliceTo(zptr(&sfont), 0)});
    xbg = xftColor(zptr(&sbg));
    xfg = xftColor(zptr(&sfg));
    xselbg = xftColor(zptr(&sselbg));
    xselfg = xftColor(zptr(&sselfg));
    xprompt = xftColor(zptr(&sbdc));
    _ = c.XSetWindowBorder(dpy, win, xprompt.pixel);
    _ = c.XSetWindowBorderWidth(dpy, win, border_px);
    _ = c.XMapWindow(dpy, win);
    _ = c.XSetInputFocus(dpy, win, c.RevertToParent, c.CurrentTime);
    _ = c.XGrabKeyboard(dpy, win, 1, c.GrabModeAsync, c.GrabModeAsync, c.CurrentTime);
    _ = c.XSync(dpy, 0);
}

// ---- event loop ----

fn run() void {
    var ev: c.XEvent = undefined;
    while (true) {
        _ = c.XNextEvent(dpy, &ev);
        switch (ev.type) {
            c.Expose => draw(),
            c.KeyPress => handleKey(&ev.xkey),
            c.DestroyNotify => return,
            else => {},
        }
    }
}

// ---- main ----

pub fn main() void {
    _ = setZ(&sfont, dfont);
    _ = setZ(&sprompt, dprompt);
    _ = setZ(&sbg, dbg);
    _ = setZ(&sfg, dfg);
    _ = setZ(&sselbg, dselbg);
    _ = setZ(&sselfg, dselfg);
    _ = setZ(&sbdc, dbdc);
    parseArgs();
    readEntries();
    xinit();
    matchEntries();
    draw();
    run();
}
