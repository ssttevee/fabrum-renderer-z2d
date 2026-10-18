const std = @import("std");
const z2d = @import("z2d");
const fabrum = @import("fabrum");

const Vec2 = fabrum.Vec2;

/// The fonts text is measured and drawn in.
pub const Fonts = struct {
    list: std.ArrayList(Named) = .empty,
    /// Scratch for measuring.
    arena: ?std.heap.ArenaAllocator = null,

    pub const Named = struct {
        name: [:0]const u8,
        font: z2d.font.Font,

        /// The font's ascender, descender and line height at `size` pixels.
        pub fn extents(self: *const Named, size: f32) z2d.font.Font.Extents {
            return self.font.extents(size);
        }
    };

    pub fn add(self: *Fonts, gpa: std.mem.Allocator, name: [:0]const u8, data: []const u8) !void {
        const file = try z2d.font.File.loadBuffer(data);
        try self.list.append(gpa, .{ .name = name, .font = try file.loadFontIndex(0) });
    }

    /// The font named `family`, or the first loaded for null; null if there
    /// is none.
    pub fn find(self: *Fonts, family: ?[:0]const u8) ?*Named {
        const name = family orelse return if (self.list.items.len > 0) &self.list.items[0] else null;
        for (self.list.items) |*named| {
            if (std.mem.eql(u8, named.name, name)) return named;
        }
        return null;
    }
};

/// Text measured as z2d draws it: as wide as its glyphs advance, and as
/// tall as its lines.
pub const Text = fabrum.layout.text.Content(
    struct {
        inner: fabrum.layout.text.CachedContext(Measurer),

        pub fn init(allocator: std.mem.Allocator) !@This() {
            return .{ .inner = try .init(allocator, try .init(allocator)) };
        }

        pub fn measureText(self: @This(), text: []const u8, style: fabrum.layout.text.Style) fabrum.layout.Content.MeasureError!Vec2 {
            return self.inner.measureText(text, style);
        }

        /// The fonts loaded so far.
        pub fn fonts(self: @This()) *Fonts {
            return self.inner.inner.fonts;
        }

        pub fn deinit(self: *@This()) void {
            self.inner.deinit();
            self.* = undefined;
        }
    },
);

const Measurer = struct {
    allocator: std.mem.Allocator,
    fonts: *Fonts,

    pub fn init(allocator: std.mem.Allocator) !Measurer {
        const fonts = try allocator.create(Fonts);
        fonts.* = .{ .arena = .init(allocator) };
        return .{ .allocator = allocator, .fonts = fonts };
    }

    pub fn measureText(self: Measurer, text: []const u8, style: fabrum.layout.text.Style) fabrum.layout.Content.MeasureError!Vec2 {
        const height = style.font_size * style.line_height;
        if (text.len == 0) return .init(0, height);
        const named = self.fonts.find(style.font_family) orelse return error.MeasureFailed;
        const arena = &self.fonts.arena.?;
        defer _ = arena.reset(.retain_capacity);
        var shaped = z2d.text.shape(arena.allocator(), &named.font, text, 0, 0, .{ .mode = .extents_only, .size = style.font_size }) catch return error.MeasureFailed;
        // letter spacing isn't drawn, so it isn't measured either
        return .init(@floatCast(shaped.extents().advance), height);
    }

    pub fn deinit(self: *Measurer) void {
        self.fonts.list.deinit(self.allocator);
        self.fonts.arena.?.deinit();
        self.allocator.destroy(self.fonts);
        self.* = undefined;
    }
};
