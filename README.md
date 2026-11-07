# NooVeu

A fast, keyboard-driven image viewer for Apple Silicon Macs, built natively in Swift.

NooVeu is in **early development** (phase 0 of a 1.0 plan). It already opens images quickly and
flips through a folder fast; browsing, editing and batch tools are still to come.

## What works today

- Open an image or a folder: drop it on the app, use Open With, run it from the command line, or
  use **File ▸ Open**.
- Flip through the folder in name order (sorted the way Finder sorts names, so `img2` comes before
  `img10`), with the next images decoded in the background.
- Zoom and pan on the GPU: pinch, scroll, drag, or keys. Sharp 1:1 pixels, with a full-resolution
  decode swapped in when you zoom past what the first view can show.
- Everything macOS can read: about 60 image types, including JPEG, PNG, HEIC, AVIF, JPEG XL, WebP,
  TIFF, OpenEXR and camera RAW formats. (The exact list depends on your macOS version.)
- Full screen, several windows, EXIF orientation.

Not yet: thumbnail browser, metadata panel, editing, batch conversion, formats macOS can't read.

### Keys

| Key | Action |
| --- | --- |
| → ↓ Space Page Down | Next image |
| ← ↑ ⌫ Page Up | Previous image |
| Home / End | First / last image |
| + − | Zoom in / out |
| 0 or 1 | Actual pixels |
| 9 | Fit to window |
| F or Return | Full screen (Esc leaves it) |
| ⌘O | Open… |

## Requirements

- A Mac with Apple silicon, running macOS 26 or later.
- To build: Xcode 26 or later (or just the Command Line Tools: `scripts/test.sh` copes with their
  quirks).

## Build, run, test

```sh
swift build -c release --product NooVeu     # build the app binary
.build/release/NooVeu path/to/image.jpg     # run it on an image (or a folder)

scripts/test.sh                             # run the tests
scripts/bundle-app.sh                       # build build/NooVeu.app (ad-hoc signed, for this Mac)
```

The app bundle is for use on the Mac that built it. Giving a copy to another Mac needs Developer ID
signing and notarisation, which are not set up yet.

## Performance

Speed is the point, so it is measured, not assumed. Targets (on the slowest supported Mac):

| What | Target |
| --- | --- |
| Launch to first image on screen | 300 ms or less |
| First view of a 24 MP photo / 100 MP photo | 120 ms / 400 ms or less |
| Next, already preloaded image | 30 ms or less |
| GPU time per frame while zooming | 8.3 ms or less (120 Hz) |
| Memory, bare app (one small image) | 80 MB or less |

The decode cache (the image on screen plus its preloaded neighbours) has its own budget of 512 MB.

```sh
swift run -c release nooveu-bench corpus Corpus/generated         # generate a synthetic test corpus
.build/release/nooveu-bench run Corpus/generated --enforce        # check the targets; fails on a miss
scripts/measure-launch.sh --bare --strict small-image.jpg         # launch time and bare-app memory
```

Known misses are tracked rather than hidden: a 24 MP PNG takes about 190 ms to first view and
about 330 ms to launch, because PNG has no fast partial decode.

## How it is organised

| Part | What it does |
| --- | --- |
| `NooVeuCore` | Decoding (ImageIO), the decode scheduler and cache, folder listing, flipping logic. No UI. |
| `NooVeuRender` | The Metal canvas, zoom and pan maths, texture upload. |
| `NooVeuApp` | The AppKit shell: windows, menus, keyboard. |
| `NooVeuBench` | Test-corpus generator and benchmark harness. |

See [CLAUDE.md](CLAUDE.md) for the design rules and working conventions.

## Licence

[MIT](LICENSE).
