# fabrum-renderer-z2d

A renderer for [fabrum](https://github.com/ssttevee/fabrum), written in pure
Zig on top of the [z2d](https://github.com/vancluever/z2d) graphics library.

**What it does:** fabrum describes your UI as a list of drawing commands,
such as "fill this rectangle" or "draw this text here". This package turns
those commands into pixels in a memory buffer that you own. You can then
send the pixels wherever you like: an e-ink screen, a remote desktop
session, a game's frame, or a PNG in a test.

**When you'd use it:** on fabrum's `none` platform. That's the platform for
places with no window system, where your own program runs the main loop and
handles the screen. You don't need it on macOS or Linux desktops, where
fabrum already draws with the system's Quartz or Cairo.

**Why this one:** it contains no C or C++, so it cross-compiles to any
target Zig supports with no extra setup. It also draws 8-bit grayscale,
which is what e-ink screens use. It can't draw pictures such as SVGs. If
you need those, use
[fabrum-renderer-thorvg](https://github.com/ssttevee/fabrum-renderer-thorvg).

## At a glance

| | |
|---|---|
| Draws | Rectangles (with rounded corners), borders, text, and clipping |
| Doesn't draw | Pictures: anything other than text is skipped |
| Pixel formats | RGBA or BGRA (premultiplied), or 8-bit grayscale |
| Fonts | TrueType and OpenType fonts that you load |
| Redraws | Only the parts of the screen that changed |
| Depends on | z2d 0.13, and the fabrum your app already uses |
| Zig version | 0.17.0 |

## Add it to your app

Fetch fabrum and the renderer:

```sh
zig fetch --save git+https://github.com/ssttevee/fabrum#trunk
zig fetch --save git+https://github.com/ssttevee/fabrum-renderer-z2d#trunk
```

In `build.zig`, give the renderer **your** fabrum module:

```zig
const fabrum = b.dependency("fabrum", .{ .target = target, .optimize = optimize, .platform = .none }).module("fabrum");
const renderer = b.dependency("fabrum_renderer_z2d", .{ .target = target, .optimize = optimize }).module("fabrum-renderer-z2d");
renderer.addImport("fabrum", fabrum);

exe.root_module.addImport("fabrum", fabrum);
exe.root_module.addImport("fabrum-renderer-z2d", renderer);
```

**Why `addImport`?** The renderer needs fabrum's types, but it deliberately
doesn't fetch fabrum itself. If it did, Zig would build a second, separate
copy of fabrum without your build options (such as `.platform = .none`). A
program can't contain two copies of fabrum; the build fails with "file
exists in modules 'fabrum' and 'fabrum0'". Handing the renderer your module
means everything shares one fabrum.

## Draw a frame

On the `none` platform, your program is the **host**. It owns the main
loop, passes input to fabrum, and draws each frame. The full contract is
documented in `fabrum.app.platform.none`. The drawing part looks like this:

```zig
const fabrum = @import("fabrum");
const app = fabrum.app;
const Renderer = @import("fabrum-renderer-z2d");

// 1. Make a renderer and give it at least one font.
var renderer: Renderer = try .init(gpa);
defer renderer.deinit();
try renderer.loadFont("Go", @embedFile("fonts/Go-Regular.ttf"));

// 2. Make the runtime. It measures text with the renderer's fonts, so the
//    layout matches what actually gets drawn.
var rt: app.Runtime(.{ .Text = Renderer.Text }) = try .init(gpa, .{ .io = io, .text_context = renderer.text_context });
defer rt.deinit();

// 3. Each frame: run the UI, then draw only what changed into your pixels.
const commands = try rt.frame(Root, props, viewport, now);
const pixels: fabrum.layout.Surface.Pixels = .packed_(buffer, width, height, .rgba8_premultiplied);
try fabrum.layout.draw(&renderer, commands, .pixels, pixels, try rt.damage());
```

A few rules for the pixel buffer:

- **Keep the same buffer between frames.** `rt.damage()` returns the
  regions that changed since the last frame. fabrum calls these the
  **damage**. The renderer redraws only those regions and leaves every
  other pixel alone. That makes redraws fast, but only if the buffer still
  holds the previous frame. The first frame must draw the whole surface.
- **Describe the buffer's shape.** Use `Surface.Pixels.packed_` for a
  buffer whose rows sit back to back, or `packedScaled` to also give a scale
  (see [Scale](#scale)). If your framebuffer pads the end of each row, fill
  in the struct's `data`, `width`, `height`, `stride`, `format` and `scale`
  fields yourself.
- **No alignment needed.** The renderer writes one byte at a time.

If you only want fabrum's layout engine, without the app runtime, make text
with `renderer.text("Hello", style)` and draw a `[]const RenderCommand` you
built yourself.

## How it works

### Drawing commands

| Command | What the renderer does |
|---|---|
| `rectangle` | Fills a rectangle with the command's color. Each corner can have its own radius. |
| `border` | Fills the ring between the box's edge and an inner edge set in by the border widths. A border always stays *inside* its box, so it never overlaps its neighbours. |
| `content` | Draws text. Other kinds of content are skipped. |
| `scissor_start` / `scissor_end` | Clips everything in between to a box: horizontally, vertically, or both. z2d has no clipping of its own, so the clipped content is drawn into a separate layer the size of the box, then blended onto the frame when the scissor ends. |

### Text and fonts

Load fonts with `loadFont(name, data)`. Both the name and the data must
stay alive as long as the renderer does. The first font you load is the
default, and text whose style sets `font_family` uses the font loaded under
that name.

`Renderer.Text` is the text type you give to `app.Runtime` (as above) or to
`app.Config.Text`. It measures text with the same fonts the renderer draws
with, so lines wrap exactly where they're drawn. fabrum decides a box's
width first, then wraps its text to fit.

These limitations come from z2d:

- Text is laid out left to right, with kerning. Scripts that need complex
  shaping, such as Arabic or Devanagari, aren't shaped.
- There's no fallback between fonts. A character missing from the chosen
  font isn't looked up in another one.
- `font_weight` doesn't select a bold face for you. Load the bold font
  under its own family name, and use that name.
- Letter spacing is ignored, both when drawing and when measuring.

### Redrawing only what changed

Given a damage list, the renderer handles one region at a time. It draws
every command that touches the region into a scratch image the size of the
region, then copies that into your buffer. A small margin around each
region catches smoothed edges and letters that stick out of their box.
Pixels outside the regions are never written, so a host can send only
those regions to the screen. Without a damage list, the whole surface is
cleared and redrawn.

### Pixel formats

The renderer always draws in premultiplied RGBA, then converts each region
as it copies it out:

- **`rgba8_premultiplied`** is copied as is.
- **`bgra8_premultiplied`** has red and blue swapped.
- **`gray8`** is one byte per pixel. Each pixel becomes its brightness as
  if laid over white: a cleared pixel is white, and soft edges fade toward
  the color's gray. That's what an e-ink framebuffer expects.

"Premultiplied" means each color channel has already been multiplied by
the pixel's opacity (its alpha). It's the usual format for blending images
quickly.

### Scale

Commands and damage are measured in **points**, fabrum's
resolution-independent unit. `Pixels.scale` says how many device pixels
make up one point. Every coordinate, radius, border width and font size is
multiplied by the scale when drawn. On a 2.2× screen, text is drawn 2.2×
larger at full sharpness, rather than drawn small and stretched.

### Anti-aliasing

Edges are smoothed by z2d, with 4× multisampling by default. Set
`renderer.fill_options` to change it.

### Errors

| Error | Cause |
|---|---|
| `error.MeasureFailed` | Text was measured with no font loaded, or with a `font_family` that isn't loaded. Load fonts before the first frame. |
| `error.NoFontLoaded` | Text was drawn before any `loadFont`. |
| `error.UnsupportedSurface` | The surface isn't `.pixels`. |

## Tests

```sh
zig build test
```

The tests in `test/render_test.zig` run the renderer through fabrum's
standard renderer checks (`layout.checkRenderer`), and also check that:

- colors come out right in both RGBA and BGRA order;
- clipping works, and borders stay inside their box;
- text is drawn in the loaded font, inside its box;
- grayscale gives each pixel's brightness over white;
- redrawing only the damaged regions gives exactly the same pixels as a
  full redraw, in color, in grayscale, and at 2× scale.

The tests bring their own fabrum, but fetch it only when you build this
package directly. Apps that depend on the renderer never download it. The
test sources ship with the package, so `zig build test` also works on a
copy in Zig's package cache.

## Who uses it

- [fabrum-kitchen](https://github.com/ssttevee/fabrum-kitchen)'s
  `kitchen-none` draws with it by default, both as a color overlay and as a
  grayscale e-ink panel (`zig build run-none`).
- [fabrum-platform-inkview](https://github.com/ssttevee/fabrum-platform-inkview)
  uses it to draw fabrum apps straight into a PocketBook e-reader's
  grayscale framebuffer.
