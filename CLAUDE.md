# NooVeu: working notes

A native Swift image viewer for Apple Silicon Macs (macOS 26+). Speed and a small footprint are the
product: every change is judged against the performance targets in the README.

## Rules that apply to everything committed

- **Never name the application this project is inspired by**: not in code, comments, tests, docs,
  commit messages, pull requests or issues. Describe features directly ("a fast, keyboard-driven
  image viewer"). `scripts/check-names.sh` enforces this and CI runs it. Run it before committing.
- Do not commit to `main`. One branch and one pull request per slice of work.

## Commands

```sh
scripts/test.sh                  # tests (Swift Testing); also handles Command-Line-Tools-only setups
swift build -c release           # release build (benchmarks and timings mean nothing in debug)
scripts/bundle-app.sh            # build/NooVeu.app, ad-hoc signed
scripts/check-names.sh           # the naming rule above
.build/release/nooveu-bench run Corpus/generated --enforce      # performance targets
scripts/measure-launch.sh --bare --strict small-image.jpg       # launch time and bare-app memory
```

Generate the corpus once with `nooveu-bench corpus Corpus/generated` (it is git-ignored).

## Layout and design rules

`NooVeuCore` (no AppKit, no Metal) → `NooVeuRender` (Metal canvas); `NooVeuShell` (the viewer
window's logic: key bindings, `ViewerModel`, status text; no AppKit) uses Core; `NooVeuApp` (AppKit
shell) uses all three and stays thin; `NooVeuBench` uses Core and Render.

- **Decoding never happens on the main thread, and a decoded image is fully decoded.**
  `ImageDecoder` always returns a bitmap that needs no further work. ImageIO decodes lazily, and a
  lazy `CGImage` moves the cost to whoever draws it first (the main thread, at texture upload). The
  benchmark's "upload cost vs a plain bitmap" rows guard this; do not skip the forced decode.
- **Everything that wants pixels goes through `DecodeScheduler`**: priority queue, shared in-flight
  decodes, cancellation, cache keyed by path plus modification time and size. Preloads leave a slot
  free for the visible image, and visible requests may use two burst slots beyond the limit (a
  decode whose viewer moved on cannot be interrupted and keeps its slot). Use
  `FolderNavigator.canonical` for any URL that becomes a cache key. The cache is emptied on system
  memory pressure.
- **Upgrade to full resolution at most once per displayed image.** A full-resolution request can
  come back no larger than the texture on screen (very wide JPEGs are subsampled to stay within
  the GPU's 16384 px texture limit), so "is anything sharper available" cannot be assumed.
- **Never hand `MTKTextureLoader` an image beyond 16384 px:** it aborts the process instead of
  throwing. `TextureFactory` refuses such images first.
- **The view works in source pixels** (`ViewTransform`). A downsampled texture is drawn stretched
  to the source's footprint, so a sharper texture can replace it without moving the view.
- **First views are decoded at display size** (`DecodeStrategy` picks the fastest path per format);
  full resolution follows only when the user zooms past what the small texture can show.
- Keep logic out of AppKit: `ViewerModel` holds the load / upgrade / flip / screen-change rules and
  takes everything it depends on through an `Environment` of closures, so tests drive it with
  fakes and decide when each decode and upload finishes. New viewer behaviour goes in the model
  (or a plain type like `FlipState`, `UpgradePolicy`, `KeyBindings`), with a test; the controller
  only translates events and supplies the real decoder, uploader and window.
- No network access. No telemetry.

## Testing conventions

- Swift Testing. New tests should be shown to fail: break the code on purpose, confirm the test
  catches it, restore the code.
- GPU tests render offscreen through `ImageRenderer` (the production draw path) and check pixels.
  They skip themselves where there is no Metal device.
- A test must fail rather than hang when the code under test goes wrong. Tests that hold
  asynchronous work behind gates use `Harness.settle()` (a 5 s deadline that frees the gates and
  records an issue) and a suite `.timeLimit`. Check with a mutant that deadlocks.
- When mutation-testing, pass the exact test type name to `--filter` (`ViewerModelTests`, not the
  suite's display name) and check the test count printed: a wrong filter runs zero tests and looks
  like a pass.

## Measuring

- Memory "at rest" means the bare app: one small image alone in its folder, measured after the app
  settles (about 3 s). Right after the first frame it reads high because graphics memory that is
  about to be released still counts. The decode cache (512 MB budget) is separate.
- `presentedTime` is 0 for an occluded window; never wait for it to become non-zero.
- Known, tracked misses: 24 MP PNG first view and PNG launch time.
- CI runs the benchmark on a GitHub runner (an M1-class virtual machine) as an informational job:
  the nearest thing to a low-end Mac we can measure. Its numbers are noisy and never fail the build.

## Toolchain notes

- Shaders are compiled at run time from source (`Shaders.swift`). Build-time compilation needs
  Xcode's separate Metal Toolchain component, which is not assumed to be installed.
- Distribution (Developer ID signing, notarisation, updates) is not set up. The app bundle is
  ad-hoc signed for local use.

## Working agreements

- Each slice: agree the scope first, build it, then get an independent fresh-eyes review (a reviewer
  who sees the code and the intended behaviour, not the author's conclusions) and fix what it finds.
- At the end of a phase, review the whole code base the same way.
- Report results as measured, including misses.
