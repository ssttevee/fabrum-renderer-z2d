//! z2d renderer for fabrum.
//!
//! A `fabrum.layout` renderer for `.pixels` surfaces, in pure Zig: it
//! rasterizes render commands (rectangles, rounded or not, borders, text
//! and clipping) with z2d, an anti-aliasing 2D library, into premultiplied
//! RGBA or BGRA pixels. With no C or C++ in it, it builds for any target
//! Zig does, from any host.
//!
//! ```zig
//! var renderer: Renderer = try .init(gpa);
//! defer renderer.deinit();
//! try renderer.loadFont("Go", @embedFile("Go-Regular.ttf"));
//! try fabrum.layout.draw(&renderer, rt.commands(), .pixels, pixels, try rt.damage());
//! ```
//!
//! **fabrum is the app's.** This package doesn't depend on fabrum (except
//! for its own tests): the app gives its module the `fabrum` it uses, with
//! `renderer_module.addImport("fabrum", fabrum_module)`. Otherwise an app
//! that passes options to fabrum (`.platform = .none`) and a renderer that
//! asked for fabrum without them would get two fabrum modules in one
//! program.
//!
//! **Text** is TrueType or OpenType, given with `loadFont`; the first font
//! loaded is used for text without a `font_family`. z2d lays out Latin
//! text left to right, with kerning; it doesn't shape complex scripts, and
//! has no fallback between fonts.
//!
//! **Damage.** With damage, each region is drawn into a scratch surface of
//! its own size from the commands that touch it, then copied into place,
//! so pixels outside the regions are never touched.
//!
//! **Clipping.** z2d has no clip, so a scissor draws what it holds into a
//! layer the size of the clip, composited onto what is under it when the
//! scissor ends.
const std = @import("std");
const fabrum = @import("fabrum");
pub const z2d = @import("z2d");

const Rect = fabrum.Rect;
const Color = fabrum.Color;
const RenderCommand = fabrum.layout.RenderCommand;
const CornerRadius = fabrum.layout.CornerRadius;
const Surface = fabrum.layout.Surface;

pub const content = @import("content.zig");

gpa: std.mem.Allocator,
/// For paths, shaped text and layers; reset after each region.
arena: std.heap.ArenaAllocator,
text_context: content.Text.Context,
/// The surface a region is drawn into, grown as needed.
scratch: []z2d.pixel.RGBA = &.{},
/// What to fill with: whether to anti-alias, and how finely.
fill_options: z2d.painter.FillOptions = .{ .anti_aliasing_mode = .multisample_4x },

const Renderer = @This();

/// The text this renderer measures and draws, for `fabrum.app.Config.Text`.
pub const Text = content.Text;

/// The surfaces it draws into.
pub const surfaces: []const Surface.Kind = &.{.pixels};

pub fn init(gpa: std.mem.Allocator) !Renderer {
    return .{
        .gpa = gpa,
        .arena = .init(gpa),
        .text_context = try content.Text.Context.init(gpa),
    };
}

pub fn deinit(self: *Renderer) void {
    self.gpa.free(self.scratch);
    self.arena.deinit();
    self.text_context.deinit();
    self.* = undefined;
}

/// Loads a TrueType or OpenType font from `data`, which must outlive the
/// renderer, as `name`, for text whose `font_family` is `name`. The first
/// font loaded is also the one for text without a family.
pub fn loadFont(self: *Renderer, name: [:0]const u8, data: []const u8) !void {
    try self.text_context.fonts().add(self.gpa, name, data);
}

/// Text content for `s`, measured with this renderer's fonts.
pub fn text(self: *const Renderer, s: []const u8, style: fabrum.layout.text.Style) content.Text {
    return .initContext(s, style, self.text_context);
}

/// Draws `commands` into `surface`, which must be `.pixels`. With
/// `damage`, only those regions are cleared and redrawn, from every command
/// that touches them; without, the whole surface is.
pub fn render(self: *Renderer, commands: []const RenderCommand, surface: Surface, damage: ?[]const Rect) !void {
    const pixels = switch (surface) {
        .pixels => |p| p,
        else => return error.UnsupportedSurface,
    };
    const whole: [1]Rect = .{.init(0, 0, @floatFromInt(pixels.width), @floatFromInt(pixels.height))};
    for (damage orelse &whole) |region| try self.renderRegion(commands, pixels, region);
}

/// A rectangle of whole pixels: `x0 <= x < x1`, `y0 <= y < y1`.
const Area = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,

    fn of(rect: Rect) Area {
        return .{ .x0 = pixel(@floor(rect.x)), .y0 = pixel(@floor(rect.y)), .x1 = pixel(@ceil(rect.x + rect.w)), .y1 = pixel(@ceil(rect.y + rect.h)) };
    }

    fn intersect(a: Area, b: Area) Area {
        return .{ .x0 = @max(a.x0, b.x0), .y0 = @max(a.y0, b.y0), .x1 = @min(a.x1, b.x1), .y1 = @min(a.y1, b.y1) };
    }

    fn isEmpty(self: Area) bool {
        return self.x0 >= self.x1 or self.y0 >= self.y1;
    }

    fn width(self: Area) i32 {
        return self.x1 - self.x0;
    }

    fn height(self: Area) i32 {
        return self.y1 - self.y0;
    }

    fn pixel(v: f32) i32 {
        return @intFromFloat(std.math.clamp(v, -(1 << 24), 1 << 24));
    }
};

/// A surface being drawn into, and where its top left is in the viewport.
const Layer = struct {
    surface: z2d.Surface,
    area: Area,
};

fn renderRegion(self: *Renderer, commands: []const RenderCommand, pixels: Surface.Pixels, region: Rect) !void {
    defer _ = self.arena.reset(.retain_capacity);
    const bounds: Area = .{ .x0 = 0, .y0 = 0, .x1 = @intCast(pixels.width), .y1 = @intCast(pixels.height) };
    const area = Area.of(region).intersect(bounds);
    if (area.isEmpty()) return;

    const count: usize = @intCast(area.width() * area.height());
    if (self.scratch.len < count) {
        self.scratch = try self.gpa.realloc(self.scratch, count);
    }
    // cleared to transparent
    var base: Layer = .{ .surface = .initBuffer(.image_surface_rgba, null, self.scratch[0..count], area.width(), area.height()), .area = area };
    try self.draw(commands, &base);
    copyOut(base, pixels);
}

/// Draws the commands that touch `base`'s area into it, clipping through
/// layers.
fn draw(self: *Renderer, commands: []const RenderCommand, base: *Layer) !void {
    const arena = self.arena.allocator();
    var layers: std.ArrayList(Layer) = .empty;
    try layers.append(arena, base.*);
    // clips in force that leave nothing of the area to draw into
    var hidden: usize = 0;
    for (commands) |cmd| {
        const layer = &layers.items[layers.items.len - 1];
        switch (cmd.data) {
            .scissor_start => |s| {
                if (hidden > 0) {
                    hidden += 1;
                    continue;
                }
                var cut = Area.of(cmd.bbox);
                if (!s.horizontal) {
                    cut.x0 = layer.area.x0;
                    cut.x1 = layer.area.x1;
                }
                if (!s.vertical) {
                    cut.y0 = layer.area.y0;
                    cut.y1 = layer.area.y1;
                }
                cut = cut.intersect(layer.area);
                if (cut.isEmpty()) {
                    hidden += 1;
                    continue;
                }
                const buffer = try arena.alloc(z2d.pixel.RGBA, @intCast(cut.width() * cut.height()));
                try layers.append(arena, .{ .surface = .initBuffer(.image_surface_rgba, null, buffer, cut.width(), cut.height()), .area = cut });
            },
            .scissor_end => {
                if (hidden > 0) {
                    hidden -= 1;
                    continue;
                }
                const top = layers.pop().?;
                const under = &layers.items[layers.items.len - 1];
                under.surface.composite(&top.surface, .src_over, top.area.x0 - under.area.x0, top.area.y0 - under.area.y0, .{});
            },
            .rectangle => |r| if (hidden == 0 and touches(cmd.bbox, layer.area)) {
                try self.fillRoundedRect(layer, cmd.bbox, r.corner_radius.fitted(cmd.bbox.w, cmd.bbox.h), null, r.color);
            },
            .border => |b| if (hidden == 0 and touches(cmd.bbox, layer.area) and !b.widths.isZero()) {
                try self.fillBorder(layer, cmd.bbox, b);
            },
            .content => |c| if (hidden == 0 and touches(cmd.bbox, layer.area)) {
                if (content.Text.asTextContent(c)) |t| try self.drawText(layer, cmd.bbox, t);
            },
        }
    }
    base.* = layers.items[0];
}

/// Whether `box`, with the pixels anti-aliasing and overhanging glyphs touch
/// around it, shares any pixels with `area`.
fn touches(box: Rect, area: Area) bool {
    const m = fabrum.layout.Damage.margin_default;
    const grown = Area.of(.init(box.x - m, box.y - m, box.w + 2 * m, box.h + 2 * m));
    return !grown.intersect(area).isEmpty();
}

fn premultiplied(color: Color) z2d.Pixel {
    const a: u32 = color.a;
    return .{ .rgba = .{
        .r = @intCast((@as(u32, color.r) * a + 127) / 255),
        .g = @intCast((@as(u32, color.g) * a + 127) / 255),
        .b = @intCast((@as(u32, color.b) * a + 127) / 255),
        .a = color.a,
    } };
}

fn fill(self: *Renderer, layer: *Layer, path: *const z2d.Path, color: Color) !void {
    const pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = premultiplied(color) } };
    try z2d.painter.fill(self.arena.allocator(), &layer.surface, &pattern, path.nodes.items, self.fill_options);
}

/// Fills a rounded rectangle, less a rounded hole if `hole` is given.
fn fillRoundedRect(self: *Renderer, layer: *Layer, box: Rect, radii: CornerRadius, hole: ?struct { Rect, CornerRadius }, color: Color) !void {
    if (color.a == 0 or box.w <= 0 or box.h <= 0) return;
    const arena = self.arena.allocator();
    var path: z2d.Path = .empty;
    const dx: f32 = @floatFromInt(layer.area.x0);
    const dy: f32 = @floatFromInt(layer.area.y0);
    try appendRoundedRect(&path, arena, .init(box.x - dx, box.y - dy, box.w, box.h), radii, false);
    if (hole) |h| try appendRoundedRect(&path, arena, .init(h[0].x - dx, h[0].y - dy, h[0].w, h[0].h), h[1], true);
    try self.fill(layer, &path, color);
}

/// Fills a border inside its box: the ring between the box and the box
/// inset by the widths.
fn fillBorder(self: *Renderer, layer: *Layer, box: Rect, b: RenderCommand.Data.Border) !void {
    const w = b.widths;
    const outer = b.corner_radius.fitted(box.w, box.h);
    const inner: Rect = .init(box.x + w.left, box.y + w.top, box.w - w.left - w.right, box.h - w.top - w.bottom);
    if (inner.w <= 0 or inner.h <= 0) return self.fillRoundedRect(layer, box, outer, null, b.color);
    const radii: CornerRadius = .{
        .top_left = @max(outer.top_left - @max(w.left, w.top), 0),
        .top_right = @max(outer.top_right - @max(w.right, w.top), 0),
        .bottom_left = @max(outer.bottom_left - @max(w.left, w.bottom), 0),
        .bottom_right = @max(outer.bottom_right - @max(w.right, w.bottom), 0),
    };
    try self.fillRoundedRect(layer, box, outer, .{ inner, radii.fitted(inner.w, inner.h) }, b.color);
}

fn drawText(self: *Renderer, layer: *Layer, box: Rect, t: *const content.Text) !void {
    const style = t.style;
    if (style.color.a == 0) return;
    const fonts = self.text_context.fonts();
    const font = fonts.find(style.font_family) orelse return error.NoFontLoaded;
    const arena = self.arena.allocator();
    const metrics = font.extents(style.font_size);
    const ascent: f32 = @floatCast(-metrics.ascender);
    const descent: f32 = @floatCast(metrics.descender);
    const pattern: z2d.Pattern = .{ .opaque_pattern = .{ .pixel = premultiplied(style.color) } };

    var lines = t.linesWithSizes(box.w);
    var y = box.y;
    while (try lines.next()) |line| {
        defer y += line.size.y;
        if (line.text.len == 0) continue;
        const x = box.x + switch (style.alignment) {
            .left => 0,
            .center => (box.w - line.size.x) / 2,
            .right => box.w - line.size.x,
        };
        // the font's ascent and descent, centered in the line
        const baseline = y + (line.size.y - (ascent + descent)) / 2 + ascent;
        // skip lines outside the layer
        const top = baseline - ascent - fabrum.layout.Damage.margin_default;
        const bottom = baseline + descent + fabrum.layout.Damage.margin_default;
        if (bottom < @as(f32, @floatFromInt(layer.area.y0)) or top > @as(f32, @floatFromInt(layer.area.y1))) continue;

        var shaped = try z2d.text.shape(arena, &font.font, line.text, x - @as(f32, @floatFromInt(layer.area.x0)), baseline - @as(f32, @floatFromInt(layer.area.y0)), .{
            .mode = .path_only,
            .size = style.font_size,
            .glyph_orientation = .baseline,
        });
        const nodes = shaped.path().nodes.items;
        if (nodes.len == 0) continue;
        try z2d.painter.fill(arena, &layer.surface, &pattern, nodes, self.fill_options);
    }
}

/// Copies a drawn region into the host's pixels, in their channel order.
fn copyOut(layer: Layer, pixels: Surface.Pixels) void {
    const area = layer.area;
    const w: usize = @intCast(area.width());
    const source = layer.surface.image_surface_rgba.buf;
    for (0..@intCast(area.height())) |row| {
        const from = source[row * w ..][0..w];
        const to = pixels.row(@intCast(area.y0 + @as(i32, @intCast(row))))[@as(usize, @intCast(area.x0)) * 4 ..][0 .. w * 4];
        switch (pixels.format) {
            .rgba8_premultiplied => @memcpy(to, std.mem.sliceAsBytes(from)),
            .bgra8_premultiplied => for (from, 0..) |p, i| {
                to[i * 4 ..][0..4].* = .{ p.b, p.g, p.r, p.a };
            },
        }
    }
}

/// The distance of a cubic Bézier's control points from a quarter
/// circle's ends, as a fraction of its radius.
const kappa = 0.5523;

/// Appends a closed rectangle with corner radii, clockwise, or
/// counter-clockwise for a hole.
fn appendRoundedRect(path: *z2d.Path, gpa: std.mem.Allocator, r: Rect, cr: CornerRadius, reversed: bool) !void {
    const x: f64 = r.x;
    const y: f64 = r.y;
    const w: f64 = r.w;
    const h: f64 = r.h;
    const tl: f64 = cr.top_left;
    const tr: f64 = cr.top_right;
    const br: f64 = cr.bottom_right;
    const bl: f64 = cr.bottom_left;
    const k = 1 - kappa;
    if (!reversed) {
        try path.moveTo(gpa, x + tl, y);
        try path.lineTo(gpa, x + w - tr, y);
        if (tr > 0) try path.curveTo(gpa, x + w - tr * k, y, x + w, y + tr * k, x + w, y + tr);
        try path.lineTo(gpa, x + w, y + h - br);
        if (br > 0) try path.curveTo(gpa, x + w, y + h - br * k, x + w - br * k, y + h, x + w - br, y + h);
        try path.lineTo(gpa, x + bl, y + h);
        if (bl > 0) try path.curveTo(gpa, x + bl * k, y + h, x, y + h - bl * k, x, y + h - bl);
        try path.lineTo(gpa, x, y + tl);
        if (tl > 0) try path.curveTo(gpa, x, y + tl * k, x + tl * k, y, x + tl, y);
    } else {
        try path.moveTo(gpa, x + tl, y);
        if (tl > 0) try path.curveTo(gpa, x + tl * k, y, x, y + tl * k, x, y + tl);
        try path.lineTo(gpa, x, y + h - bl);
        if (bl > 0) try path.curveTo(gpa, x, y + h - bl * k, x + bl * k, y + h, x + bl, y + h);
        try path.lineTo(gpa, x + w - br, y + h);
        if (br > 0) try path.curveTo(gpa, x + w - br * k, y + h, x + w, y + h - br * k, x + w, y + h - br);
        try path.lineTo(gpa, x + w, y + tr);
        if (tr > 0) try path.curveTo(gpa, x + w, y + tr * k, x + w - tr * k, y, x + w - tr, y);
    }
    try path.close(gpa);
}

test {
    std.testing.refAllDecls(@This());
}
