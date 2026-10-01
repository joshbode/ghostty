//! DECRQCRA (Request Checksum of Rectangular Area) and XTCHECKSUM
//! (select the checksum variant DECRQCRA computes).
//!
//! The checksum follows xterm's `xtermCheckRect`. No real VT420 was
//! available to compare against while this was written, so xterm is the
//! reference:
//!
//! - `xtermCheckRect`: https://github.com/ThomasDickey/xterm-snapshots/blob/xterm-411/screen.c#L3162-L3290
//! - `xtermCharSetDec`: https://github.com/ThomasDickey/xterm-snapshots/blob/xterm-411/charsets.c#L608
const std = @import("std");
const testing = std.testing;
const PageList = @import("PageList.zig");
const Terminal = @import("Terminal.zig");
const pagepkg = @import("page.zig");
const style = @import("style.zig");

/// The XTCHECKSUM (CSI Ps # y) bits. The zero value is the DEC checksum,
/// which is also what a full reset restores.
pub const Flags = packed struct(u5) {
    /// Don't negate the result.
    positive: bool = false,

    /// Don't add the VT100 video attributes to each cell.
    no_attributes: bool = false,

    /// Don't omit blanks. The DEC checksum only counts a plain space if it
    /// is the first cell of the rectangle.
    no_trim: bool = false,

    /// Count cells that were never written to as spaces instead of
    /// skipping them.
    undrawn: bool = false,

    /// Use the full codepoint rather than the DEC 8-bit value. Wide
    /// spacers are skipped and, as in xterm, combining marks are not
    /// counted in this mode.
    full: bool = false,
};

/// A DECRQCRA request as it arrives in `CSI Pi ; Pg ; Pt ; Pl ; Pb ; Pr * y`.
/// The coordinates are 1-based and zero means the parameter was omitted.
/// The page number (Pg) is ignored since we only have one page.
pub const Request = extern struct {
    id: u16 = 0,
    top: u16 = 0,
    left: u16 = 0,
    bottom: u16 = 0,
    right: u16 = 0,
};

/// A rectangle in the active area, 0-based and inclusive.
pub const Rect = struct {
    top: u16,
    left: u16,
    bottom: u16,
    right: u16,

    /// Resolve a request against a screen of the given size. If `origin`
    /// is set (DECOM), coordinates are relative to its top-left, as in
    /// xterm. Coordinates are clamped to the screen. Returns null if the
    /// rectangle is empty.
    pub fn init(
        req: Request,
        rows: u16,
        cols: u16,
        origin: ?Terminal.ScrollingRegion,
    ) ?Rect {
        if (rows == 0 or cols == 0) return null;
        const top_margin: u16 = if (origin) |o| o.top else 0;
        const left_margin: u16 = if (origin) |o| o.left else 0;
        const top = limit(req.top, 1, top_margin, rows);
        const left = limit(req.left, 1, left_margin, cols);
        const bottom = limit(req.bottom, rows, top_margin, rows);
        const right = limit(req.right, cols, left_margin, cols);
        if (top > bottom or left > right) return null;
        return .{
            .top = top - 1,
            .left = left - 1,
            .bottom = bottom - 1,
            .right = right - 1,
        };
    }

    fn limit(v: u16, default: u16, margin: u16, max: u16) u16 {
        const n = if (v == 0) default else v;
        return std.math.clamp(n +| margin, 1, max);
    }
};

/// Compute the checksum of a rectangle of the active area.
pub fn compute(pages: *const PageList, rect_: ?Rect, flags: Flags) u16 {
    // An empty rectangle still gets a reply, with a sum of zero.
    const rect = rect_ orelse return 0;

    // Everything is summed modulo 2^16 since only 16 bits are reported.
    var sum: u16 = 0;

    // The DEC checksum omits plain spaces except for the very first cell
    // counted in the rectangle.
    var first = true;

    var y = rect.top;
    while (y <= rect.bottom) : (y += 1) {
        const pin = pages.pin(.{ .active = .{ .y = y } }) orelse continue;
        const cells = pin.cells(.all);

        var x = rect.left;
        while (x <= rect.right and x < cells.len) : (x += 1) {
            const cell = &cells[x];
            var ch: u16 = switch (value(cell, flags)) {
                .skip => continue,
                .undrawn => if (flags.no_trim or flags.undrawn) ' ' else continue,
                .value => |v| v,
            };

            const s = pin.style(cell);
            if (!flags.no_attributes) ch +%= attributes(cell, s);

            if (flags.no_trim) {
                sum +%= ch;

                // xterm adds combining marks only in the DEC mode, and
                // only to the untrimmed sum.
                if (!flags.full and cell.hasGrapheme()) {
                    if (pin.grapheme(cell)) |cps| {
                        for (cps) |cp| sum +%= @truncate(cp);
                    }
                }
            } else if (first or ch != ' ' or extended(s)) {
                sum +%= ch;
            }

            first = flags.no_trim;
        }

        if (!flags.no_trim) first = false;
    }

    return if (flags.positive) sum else 0 -% sum;
}

const Value = union(enum) {
    /// Not counted at all.
    skip,

    /// Never written to.
    undrawn,

    /// The value of the character, before attributes.
    value: u16,
};

fn value(cell: *const pagepkg.Cell, flags: Flags) Value {
    // The right half of a wide character. xterm stores a placeholder
    // outside of 8 bits there, so the DEC checksum counts it as ESC.
    if (cell.wide == .spacer_tail) {
        return if (flags.full) .skip else .{ .value = 0x1B };
    }

    if (!cell.hasText()) return .undrawn;

    const cp = cell.codepoint();
    if (flags.full) return .{ .value = @truncate(cp) };

    // The DEC 8-bit value, as xterm's `xtermCharSetDec` produces it for
    // the ASCII character set. xterm works from the byte as it was
    // received, before character set translation, so it counts DEC line
    // drawing as the letter that was sent. We only have the translated
    // codepoint, so those count as characters outside of 8 bits.
    return .{ .value = switch (cp) {
        0x7F, 0xFF => 0,
        0x20...0x7E, 0x80...0x9F, 0xA1...0xFE => @intCast(cp & 0x7F),
        else => 0x1B,
    } };
}

/// The VT100 video attributes xterm adds to each cell.
fn attributes(cell: *const pagepkg.Cell, s: style.Style) u16 {
    var result: u16 = 0;
    if (cell.protected) result += 0x04;
    if (s.flags.invisible) result += 0x08;
    if (s.flags.underline != .none) result += 0x10;
    if (s.flags.inverse) result += 0x20;
    if (s.flags.blink) result += 0x40;
    if (s.flags.bold) result += 0x80;
    return result;
}

/// Attributes that xterm doesn't add to the sum but that still keep a
/// space from being trimmed.
fn extended(s: style.Style) bool {
    return s.flags.faint or
        s.flags.italic or
        s.flags.strikethrough or
        s.flags.underline == .double;
}

/// The largest reply `encode` writes.
pub const max_encode_size = "\x1bP65535!~FFFF\x1b\\".len;

/// Encode the DECRQCRA reply, `DCS Pi ! ~ XXXX ST`.
pub fn encode(
    writer: *std.Io.Writer,
    id: u16,
    sum: u16,
) std.Io.Writer.Error!void {
    try writer.print("\x1bP{d}!~{X:0>4}\x1b\\", .{ id, sum });
}

fn testChecksum(t: *Terminal, req: Request, flags: Flags) u16 {
    return compute(
        &t.screens.active.pages,
        .init(req, t.rows, t.cols, null),
        flags,
    );
}

test "xt_checksum: encode" {
    var buf: [max_encode_size]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, 65535, 0xFFFF);
    try testing.expectEqualStrings("\x1bP65535!~FFFF\x1b\\", writer.buffered());

    writer = .fixed(&buf);
    try encode(&writer, 1, 0x1A);
    try testing.expectEqualStrings("\x1bP1!~001A\x1b\\", writer.buffered());
}

test "xt_checksum: rect defaults and clamping" {
    try testing.expectEqual(
        Rect{ .top = 0, .left = 0, .bottom = 4, .right = 9 },
        Rect.init(.{}, 5, 10, null).?,
    );
    try testing.expectEqual(
        Rect{ .top = 1, .left = 2, .bottom = 4, .right = 9 },
        Rect.init(.{ .top = 2, .left = 3, .bottom = 99, .right = 99 }, 5, 10, null).?,
    );
    try testing.expectEqual(
        null,
        Rect.init(.{ .top = 3, .bottom = 2 }, 5, 10, null),
    );
    try testing.expectEqual(
        null,
        Rect.init(.{ .left = 3, .right = 2 }, 5, 10, null),
    );
}

test "xt_checksum: rect origin mode" {
    const region: Terminal.ScrollingRegion = .{
        .top = 1,
        .bottom = 3,
        .left = 2,
        .right = 8,
    };
    try testing.expectEqual(
        Rect{ .top = 1, .left = 2, .bottom = 4, .right = 9 },
        Rect.init(.{}, 5, 10, region).?,
    );
    try testing.expectEqual(
        Rect{ .top = 1, .left = 2, .bottom = 1, .right = 2 },
        Rect.init(.{ .top = 1, .left = 1, .bottom = 1, .right = 1 }, 5, 10, region).?,
    );
}

test "xt_checksum: DEC trims blanks and skips undrawn cells" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("a b");

    // Only the first row, the whole width. The space is omitted and the
    // unwritten cells are skipped.
    const req: Request = .{ .top = 1, .bottom = 1 };
    try testing.expectEqual(0 -% @as(u16, 'a' + 'b'), testChecksum(&t, req, .{}));
    try testing.expectEqual(@as(u16, 'a' + 'b'), testChecksum(&t, req, .{ .positive = true }));

    // Untrimmed counts the space and the undrawn cells as spaces.
    try testing.expectEqual(
        @as(u16, 'a' + 'b' + ' ' * 8),
        testChecksum(&t, req, .{ .positive = true, .no_trim = true }),
    );

    // Undrawn cells are spaces, which are then trimmed.
    try testing.expectEqual(
        @as(u16, 'a' + 'b'),
        testChecksum(&t, req, .{ .positive = true, .undrawn = true }),
    );
}

test "xt_checksum: DEC counts a leading space" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString(" a\n b");

    // The very first counted cell is kept even if it's a space, but not
    // the first cell of later rows.
    try testing.expectEqual(
        @as(u16, ' ' + 'a' + 'b'),
        testChecksum(&t, .{}, .{ .positive = true }),
    );
}

test "xt_checksum: empty rectangle" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("abc");
    try testing.expectEqual(0, testChecksum(&t, .{ .left = 3, .right = 2 }, .{}));
}

test "xt_checksum: rectangle bounds" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("abc\ndef\nghi");
    try testing.expectEqual(
        @as(u16, 'e' + 'f' + 'h' + 'i'),
        testChecksum(&t, .{ .top = 2, .left = 2, .bottom = 3, .right = 3 }, .{ .positive = true }),
    );
}

test "xt_checksum: attributes" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.setAttribute(.bold);
    try t.setAttribute(.{ .underline = .single });
    try t.printString("a");
    try t.setAttribute(.unset);
    try t.setAttribute(.inverse);
    try t.setAttribute(.blink);
    try t.printString(" ");
    try t.setAttribute(.unset);
    try t.setAttribute(.invisible);
    t.setProtectedMode(.dec);
    try t.printString("b");

    const req: Request = .{ .top = 1, .bottom = 1 };
    try testing.expectEqual(
        @as(u16, 'a' + 0x80 + 0x10 + ' ' + 0x20 + 0x40 + 'b' + 0x08 + 0x04),
        testChecksum(&t, req, .{ .positive = true }),
    );
    try testing.expectEqual(
        @as(u16, 'a' + 'b'),
        testChecksum(&t, req, .{ .positive = true, .no_attributes = true }),
    );
}

test "xt_checksum: extended attributes keep a space" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("a");
    try t.setAttribute(.italic);
    try t.printString(" ");

    try testing.expectEqual(
        @as(u16, 'a' + ' '),
        testChecksum(&t, .{ .top = 1, .bottom = 1 }, .{ .positive = true }),
    );
}

test "xt_checksum: DEC 8-bit values" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);

    // é is 0xE9, masked to 7 bits; the euro sign is outside of 8 bits.
    try t.printString("é€");
    const req: Request = .{ .top = 1, .bottom = 1 };
    try testing.expectEqual(
        @as(u16, 0x69 + 0x1B),
        testChecksum(&t, req, .{ .positive = true }),
    );
    try testing.expectEqual(
        @as(u16, 0xE9 + 0x20AC),
        testChecksum(&t, req, .{ .positive = true, .full = true }),
    );
}

test "xt_checksum: wide characters" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    try t.printString("橋");

    const req: Request = .{ .top = 1, .bottom = 1 };
    try testing.expectEqual(
        @as(u16, 0x1B + 0x1B),
        testChecksum(&t, req, .{ .positive = true }),
    );
    try testing.expectEqual(
        @as(u16, 0x6A4B),
        testChecksum(&t, req, .{ .positive = true, .full = true }),
    );
}

test "xt_checksum: combining marks" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);
    t.modes.set(.grapheme_cluster, true);
    try t.printString("e\u{301}");

    const req: Request = .{ .top = 1, .bottom = 1, .right = 1 };
    try testing.expectEqual(
        @as(u16, 'e'),
        testChecksum(&t, req, .{ .positive = true }),
    );
    try testing.expectEqual(
        @as(u16, 'e' + 0x301),
        testChecksum(&t, req, .{ .positive = true, .no_trim = true }),
    );
    try testing.expectEqual(
        @as(u16, 'e'),
        testChecksum(&t, req, .{ .positive = true, .no_trim = true, .full = true }),
    );
}
