# Lupp

A fast, colour-honest image viewer for macOS. *Lupp* is Swedish for the loupe you
put on a lightbox to inspect a frame.

Built to be a default image viewer that opens instantly and tells you the truth
about what's in the file — including the parts above diffuse white.

```bash
./build.sh && open Lupp.app
```

## What it does

- **Opens 62 formats** — JPEG, PNG, HEIC, TIFF, GIF, WebP, AVIF, JPEG XL, PSD
  (composite), Radiance HDR, OpenEXR, and camera RAW from most manufacturers.
  The list comes from ImageIO at build time, so it tracks your macOS version.
  See `Lupp ▸ Formats Lupp Can Read…` for the exact set on your machine.
- **Scroll to zoom**, anchored under the cursor. Middle-mouse or space-drag to
  pan. Pinch to zoom on a trackpad.
- **Eyedropper readout** — linear float RGB under the cursor, plus the sRGB hex,
  plus alpha, live as you move.
- **A float pipeline throughout.** Everything decodes to linear 32-bit float, so
  an EXR pixel at 8.0 is stored, reported and displayed as 8.0 rather than
  clipped to white. HDR files are flagged with their peak value in the title bar.
- **Exposure offset** (`E` / `⇧E`) to inspect into highlights or shadows.
- **Arrow keys** step through the rest of the folder, numerically sorted so
  `frame_2` comes before `frame_10`.
- Nearest-neighbour sampling above 200%, so at high zoom you see the pixels in
  the file rather than the viewer's interpolation.
- **Scopes panel** (⌥⌘I, or the button in the title bar) — histogram, RGB parade,
  vectorscope with a BT.709 graticule, plus per-channel min/max/mean and clipping
  percentages.

The window is one continuous surface: the title bar, the canvas and the readout
footer all share a single background colour, defined once and converted to linear
for the Metal drawable so they can't drift apart.

## Two colour spaces, both labelled

The eyedropper reports **linear** values — that's the file's own light-linear
data, where an EXR highlight reads 8.0.

The scopes bin **sRGB-encoded** values, because that's what every grading tool
shows and a linear histogram crushes almost everything into the bottom eighth of
the graph. A 50% grey field peaks mid-histogram, not at 21%.

Both are correct answers to different questions, which is exactly why each says
which one it is rather than leaving you to guess.

## How zoom behaves

Three rules, and they are the whole model:

1. An image **smaller** than the window opens at **100%** — never enlarged
   without being asked, because upscaling shows you the viewer's interpolation
   instead of the file.
2. An image **larger** than the window **scales to fit** the window it opens
   into.
3. **Resizing the window never changes the zoom.** The window is a viewport that
   moves over the image, so dragging its edge reveals more of the picture at the
   same magnification.

Windows share one remembered frame, so a new image opens at whatever size you
were last working at rather than resizing your window to match the file. Only the
first window you ever open sizes itself to the image.

## Controls

| | |
|---|---|
| Scroll wheel | Zoom, anchored at the cursor |
| Two-finger scroll / pinch | Pan / zoom (trackpad) |
| ⌥ + scroll | Invert zoom-vs-pan for one gesture |
| Middle-mouse drag | Pan |
| Space + drag | Pan (trackpad fallback) |
| ← → | Previous / next image in the folder |
| ⌘0 / ⌘1 | Zoom to fit / 1 image pixel per screen pixel |
| `E` / `⇧E` / `R` | Exposure up / down / reset |
| ⌥⌘I | Show / hide the scopes panel |

## Becoming your default viewer

`Lupp ▸ Make Lupp the Default Image Viewer…` sets the handler for 14 common
types. macOS confirms **once per file type**, so expect a run of prompts; you can
stop partway and whatever you confirmed sticks. Requires macOS 15+. On earlier
versions, select a file in Finder, press ⌘I, change "Open with" and click
"Change All…".

## Building

Needs the Command Line Tools only — **no Xcode**. `swift build` produces the
binary and `build.sh` wraps it in a `.app`, generating the icon with CoreGraphics
and the Info.plist from ImageIO's own format list. Metal shaders compile at
runtime from source, because the offline `metal` compiler ships with Xcode rather
than the CLT.

```bash
./build.sh                              # → Lupp.app
./Lupp.app/Contents/MacOS/Lupp --selftest
./Lupp.app/Contents/MacOS/Lupp image.exr
LUPP_DEBUG=1 ./Lupp.app/Contents/MacOS/Lupp   # logs scroll events
```

`--selftest` checks the things a screenshot can't: that sRGB linearizes
correctly, that EXR values above 1.0 survive decoding, that EXIF rotation is
applied, that alpha is un-premultiplied, and that zoom holds the point under the
cursor.

## Known limits

These are real and mostly deliberate.

- **Not notarized.** The build is ad-hoc signed, which is fine on the machine
  that built it. A `.app` downloaded from elsewhere will be blocked by
  Gatekeeper — notarization needs a paid Apple Developer account. Build from
  source.
- **Not sandboxed**, on purpose. Under App Sandbox, opening a file grants that
  file and nothing else, which would leave arrow-key navigation reading an empty
  folder.
- **Memory is the cost of the float pipeline.** RGBA float32 is 16 bytes per
  pixel — a 24 MP photo is ~384 MB. Above 120 MP, Lupp decodes a reduced version
  and says `reduced` in the readout rather than allocating ~2 GB.
- **No DPX or Cineon**; ImageIO doesn't read them. PSD is composite only, never
  layers.
- **The eyedropper reports scene-linear values in extended sRGB**, converted by
  CoreGraphics from whatever the file declared. That is one of several defensible
  answers to "what colour is this pixel" — it is not the display-mapped value you
  are looking at, and for a wide-gamut file the two differ.
- **Scopes sample up to 600k pixels**, strided across the image, not every pixel.
  Statistically indistinguishable and far faster; the exact count is shown in the
  panel. They also cover the whole image, not the visible region.
- **Telling a mouse from a trackpad is a heuristic.** Lupp uses gesture phase,
  which smooth-scrolling drivers (Logi Options+ and friends) don't fake — unlike
  `hasPreciseScrollingDeltas`, which they do. If it still guesses wrong, untick
  `View ▸ Scroll Wheel Zooms`.
- **Middle-click may never reach the app.** macOS Mouse settings often bind
  button 3 to Mission Control, which swallows it. Space-drag always works.

## Not here yet

Palette extraction, image-sequence playback, and video with the same readout,
scopes and right-drag scrubbing. Video is the big one: `AVPlayerLayer` won't
hand pixels back, so an honest readout needs `AVPlayerItemVideoOutput` plus the
YCbCr matrix and transfer function from the track — which is exactly where most
tools quietly get the numbers wrong.

## Licence

MIT.
