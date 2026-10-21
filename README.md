# fabrum-renderer-z2d

A portable, pure-Zig renderer for [fabrum](https://github.com/ssttevee/fabrum)'s
render commands, built on [z2d](https://github.com/vancluever/z2d). It
rasterizes a frame's `RenderCommand`s into a buffer of pixels you own, so a
program on fabrum's `none` platform (no window and no toolkit: your own code
hosts the runtime) can show a fabrum interface wherever there is a
framebuffer: an e-ink panel, a VNC overlay, a game's frame, a test rig. There
is no C or C++ in it, so it builds for any target Zig does, from any host.

| | |
|---|---|
| Module | `fabrum-renderer-z2d` (package `fabrum_renderer_z2d`) |
| Draws into | `.pixels` surfaces: `rgba8_premultiplied`, `bgra8_premultiplied`, `gray8` |
| Draws | rectangles (per-corner radii), borders (inside their box), text, scissor clips |
| Does not draw | pictures (content other than text is skipped); see [fabrum-renderer-thorvg](https://github.com/ssttevee/fabrum-renderer-thorvg) for those |
| Text | TrueType and OpenType, through z2d's own shaper |
| Damage | redraws only the regions fabrum reports changed |
| Scale | any number of device pixels per point |
| Depends on | z2d 0.13; fabrum is given by the app (see below) |
| Zig | 0.17.0 |

## Adding it to an app

```sh
zig fetch --save git+https://github.com/ssttevee/fabrum#trunk
zig fetch --save git+https://github.com/ssttevee/fabrum-renderer-z2d#trunk
```

**fabrum is the app's.** The renderer does not fetch fabrum itself: the app
gives the renderer's module the `fabrum` it uses, built with its own options
(`.platform = .none`). Zig makes one instance of a package per set of options,
so a renderer that asked for fabrum on its own would put a second `fabrum`
module in the program, and the build would fail with "file exists in modules
'fabrum' and 'fabrum0'". In `build.zig`:

```zig
const fabrum = b.dependency("fabrum", .{ .target = target, .optimize = optimize, .platform = .none }).module("fabrum");
const renderer = b.dependency("fabrum_renderer_z2d", .{ .target = target, .optimize = optimize }).module("fabrum-renderer-z2d");
renderer.addImport("fabrum", fabrum);

exe.root_module.addImport("fabrum", fabrum);
exe.root_module.addImport("fabrum-renderer-z2d", renderer);
```

Then, in the host (what fabrum's `none` platform calls the app's own code
that drives the runtime; see `fabrum.app.platform.none` for the contract):

```zig
const fabrum = @import("fabrum");
const app = fabrum.app;
const Renderer = @import("fabrum-renderer-z2d");

var renderer: Renderer = try .init(gpa);
defer renderer.deinit();
try renderer.loadFont("Go", @embedFile("fonts/Go-Regular.ttf"));

// the runtime measures text with the renderer's fonts
var rt: app.Runtime(.{ .Text = Renderer.Text }) = try .init(gpa, .{ .io = io, .text_context = renderer.text_context });
defer rt.deinit();

// per frame: run it, then draw only what changed into your pixels
const commands = try rt.frame(Root, props, viewport, now);
const pixels: fabrum.layout.Surface.Pixels = .packed_(buffer, width, height, .rgba8_premultiplied);
try fabrum.layout.draw(&renderer, commands, .pixels, pixels, try rt.damage());
```

`Surface.Pixels.packed_` describes a tightly packed buffer; `packedScaled`
adds the scale (device pixels per point); for a framebuffer with padded rows,
fill in the struct (`data`, `width`, `height`, `stride`, `format`, `scale`)
directly; rows are written byte by byte, so no alignment is needed. Keep
the buffer between frames: a damage redraw leaves all other pixels as they
were, and the first frame must draw the whole surface.

A program that only wants layout, without `fabrum.app`, can make text content
with `renderer.text("Hello", style)` and draw a `[]const RenderCommand` of its
own.

## What it does

**Commands.** `rectangle` fills a rounded rectangle with the command's color
(corner radii fitted to the box). `border` fills the ring between the box and
the box inset by the border widths, with the inner radii shrunk by the widths,
so a border never spills onto its neighbours. `content` draws text (any other
content is skipped). `scissor_start`/`scissor_end` clip, horizontally and/or
vertically; z2d has no clip of its own, so what a scissor holds is drawn into
a layer the size of the clip and composited `src_over` when the scissor ends.

**Text** is TrueType or OpenType, given with `loadFont(name, data)` (the name
and data must outlive the renderer). Text whose style names a `font_family` uses the
font of that name; the first font loaded is the default. `Renderer.Text` is
the text content type for `app.Runtime` and `app.Config.Text`, measuring with
the same fonts the renderer draws with. z2d lays out Latin text left to right
with kerning; it does not shape complex scripts, has no fallback between
fonts. `font_weight` does not select a different face: load that face under
its own family name. Letter spacing is neither drawn nor measured.

**Damage.** With a damage list, each region is drawn into a scratch surface of
its own size from every command that touches it (a margin accounts for
anti-aliasing and overhanging glyphs), then copied into place. Pixels outside
the regions are never touched, so the host can composite or upload just
those. Without a list the whole surface is cleared and redrawn.

**Formats.** Regions are drawn in premultiplied RGBA and converted by
`copyOutAs`, one branch-free loop per format: a `memcpy` for
`rgba8_premultiplied`, a channel swap for `bgra8_premultiplied`. For `gray8`
each pixel's luma over white is taken (`luma + (255 - alpha)`), so
anti-aliased coverage shades towards the color's gray and a cleared pixel is
white; this is what an e-ink framebuffer wants.

**Scale.** Commands and damage are in points; every coordinate, radius, border
width and font size is multiplied by `Pixels.scale` when drawn, so a 2.2x
panel gets 2.2x glyphs, not scaled bitmaps.

**Anti-aliasing** is z2d's, 4x multisampling by default; set
`renderer.fill_options` for something else.

Load fonts before measuring text. Non-empty text with no loaded font (or
an unknown `font_family`) fails measurement with `error.MeasureFailed`.
`Renderer.Text` uses fabrum's width-before-height layout: its content defaults
to `Content.limit = .ancestors`, then wraps at the width layout assigns.

Errors: `error.UnsupportedSurface` for a surface other than `.pixels`;
`error.NoFontLoaded` when text is drawn before any `loadFont`.

## Tests

```sh
zig build test
```

The module's own test (`refAllDecls`) and `test/render_test.zig` check the
renderer against fabrum's `layout.checkRenderer`, premultiplied
colors in RGBA and BGRA order over a cleared surface, scissors and borders
inside their box, text in the loaded font inside its box, redrawing only the
damage giving the same pixels as a full redraw (also for `gray8`, and at
scale 2), and `gray8` luma over white.

The tests bring their own fabrum, a lazy dependency fetched only when this
package is built as the root, so apps that depend on the renderer never fetch
it.

## Who uses it

- [fabrum-kitchen](https://github.com/ssttevee/fabrum-kitchen)'s
  `kitchen-none`, the Kitchen hosted on the `none` platform as an RGBA
  overlay and as a `gray8` e-ink panel (`zig build run-none`, the default
  `-Drenderer=z2d`).
- [fabrum-platform-inkview](https://github.com/ssttevee/fabrum-platform-inkview),
  fabrum on PocketBook e-readers, which draws the damage straight into the
  panel's gray framebuffer with it.

The package manifest includes `test`, so a fetched cache copy can also run
`zig build test` (including the consumer app where present).
