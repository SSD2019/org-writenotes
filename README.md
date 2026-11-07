# Org-WriteNotes (Emacs Server Plugin)

**Org-WriteNotes** is a zero-dependency GNU Emacs package (`org-writenotes.el` & `org-writenotes-extras.el`) that turns Emacs into a live bidirectional sync server for handwritten ink canvases and Org-mode document trees.

> [!NOTE]
> Client applications (Android tablet, Linux Desktop companion, and iOS/iPadOS) are maintained in the companion apps repository:
> **[`SSD2019/org-writenotes-apps`](https://github.com/SSD2019/org-writenotes-apps)**.

Write structured notes, manage tasks, execute Babel code blocks, and sketch high-precision vector diagrams with an S-Pen, Apple Pencil, or Wacom stylus—all stored natively in your `.org` files and standard `.svgz` vector files with zero cloud lock-in.

---

## Key Features

### 1. Native Stylus Handwriting & C++ Vector Ink Engine
- **Stylus Labs Write C++ Core via JNI:** Ultra-low-latency pressure- and tilt-sensitive vector strokes serialized directly to standard block-gzipped `.svgz` files.
- **Rich Stylus Toolset:**
  - **Pen Tips & Presets:** Ballpoint, Fountain, Brush, Chisel (configurable angle), Highlighter, and 6 customizable one-tap **Favorite Pen Slots**.
  - **Ruled & Standard Eraser:** Erase whole strokes or snap-erase along ruling lines.
  - **Lasso Selection & Restyling:** Freeform lasso with move, scale, rotate, duplicate, cross-sketch copy/paste, and live stroke recoloring/rewidening.
  - **Cross-Sketch Clipboard:** Copy or cut strokes in one sketch and paste them into any other; the clipboard survives app restarts, a **Paste (N)** button appears in the toolbar, and pasted strokes land in the visible part of the target sketch.
  - **Hold-to-Snap Geometric Shapes:** Pause 400 ms at the end of a stroke to snap freehand lines, arrows, axis-aligned rectangles, or circles/ellipses (with optional grid snapping).
  - **Laser Pointer Mode:** Stream a live glowing pointer trail to your Emacs buffer during presentations or screen sharing without modifying the saved `.svgz`.
- **Hardware Stylus & Touch Ergonomics:**
  - **Palm Rejection & Stylus-Only Mode:** Single-finger scrolling passes cleanly through inline canvases; holding the S-Pen barrel button temporarily engages Lasso Select.
  - **Procreate-Style Multi-Touch Gestures:** Two-finger tap to **Undo**, three-finger tap to **Redo**, and pinch-to-zoom with a live **Viewport Minimap** navigator.
  - **Radial Pen Menu:** Hold the barrel button while the pen hovers (not touching) to open Pen / Eraser / Lasso / Undo / Redo and your favorite pens around the pen tip.
  - **Toolbar Layout:** Dock the sketch toolbar at the top or bottom, or use a draggable, collapsible floating palette in the full-screen editor; **Left-handed mode** mirrors the sidebar, rail and palette.
  - **Stroke Tuning:** Configurable stroke smoothing, pressure gamma curve, and tilt sensitivity.
- **Dynamic Canvas & Paper Templates:**
  - Automatic vertical canvas expansion as you write near the bottom edge, plus one-tap **Trim Bottom Whitespace**.
  - Built-in paper rulings: **Ruled, College, Narrow, Quad Grid, Dotted Grid, Engineering 5×5, Isometric 30°/60°, Music Staff, Cornell Notes, and Weekly Planner**.
  - **Layer Controls:** Lock/unlock background template layers, adjust template image opacity, and toggle highlighter layer visibility.
  - **Tiled Large-Canvas Rendering:** Viewport-culled tiled rendering (`nativeRenderTileToBitmap`) for massive diagrams (>16 MP).

### 2. Smart Ink: Offline OCR, Audio Sync & Image Markup
- **Handwriting OCR:**
  - **Idle-Time Recognition on the Emacs Host (TrOCR):** Sketches are never recognized per commit. Each commit queues the sketch in Emacs, and a local [TrOCR](https://huggingface.co/microsoft/trocr-base-handwritten) helper (`ocr/recognize.py`) runs only after Emacs has been idle, and the sketch untouched, for `org-writenotes-ocr-idle-seconds` (default 3 minutes). It uses the GPU when present and falls back to CPU. See [Setting up local OCR](#setting-up-local-ocr).
  - **Searchable `:WRITENOTES_OCR:` Drawers:** The recognized text is written into a folded Org drawer beneath each sketch link, replacing the previous one, so `isearch`, `ripgrep`, `consult-line`, and `org-ql` search inside your diagrams natively.
  - **Lasso → Convert to Text:** Convert selected handwritten notes into native Org paragraphs or checklist items on the fly (still uses the tablet's built-in basic recognizer).
  - **Smart Math & Checklist Detection:** Automatically converts drawn `[ ]` boxes into interactive Org checklists and handwritten math expressions into LaTeX (`$...$`).
- **Audio-Synced Sketches:** Record voice notes while sketching; each pen stroke is timestamp-indexed to the audio track so you can jump backward/forward stroke-by-stroke during playback.
- **Image & Diagram Annotation:**
  - Run `M-x org-writenotes-annotate-image-at-point` in Emacs on any `[[file:diagram.png]]` link to wrap it as a background template and open it on the tablet for stylus markup.
  - Share images from any Android app (`ACTION_SEND`) or paste from the clipboard directly onto your active canvas.
  - Export sketches as **PNG** or **SVG**, or import external Write `.svgz` files.

### 3. Full Org-Mode Productivity on the Tablet
- **5-Tab Sidebar Navigator:**
  - **History:** Recently pushed headings from Emacs.
  - **Outline:** Full hierarchical heading tree of the active `.org` buffer with collapse/expand and sketch count badges (`🎨`).
  - **Agenda:** Today's entries from Emacs' own day agenda (overdue, scheduled, deadline warnings, timed items first).
  - **Search:** Full-text, title, tag and OCR search across Org buffers and `org-agenda-files` (2+ characters, capped at `org-writenotes-search-max-results`).
- **Focus Mode:** The sidebar shrinks to an icon rail; one-finger swipes left/right (or `Alt+←/→`) walk back and forward through the headings you visited.
- **Command Palette & Keyboard Shortcuts:** `Ctrl+K` fuzzy-searches actions and headings. `C-c w f` / `C-c w q` / `C-c w w` mirror the Emacs prefix; `Ctrl+\` focus mode, `Ctrl+1…5` sidebar tabs, `Ctrl+N` new heading, `Ctrl+T` cycle TODO, `Ctrl+Shift+C` clock in/out.
- **E-Ink Profile (Onyx Boox):** No animations, high-contrast chrome, shape-coded connection status (filled = connected, ring = offline, ring + dot = connecting, ring + ✕ = error) and named pen-color swatches.
  - **Gallery:** Visual thumbnail grid of all `.svgz` sketches with one-tap jump to the parent heading.
- **Rich Interactive Org AST Blocks:**
  - **Header Card & Metadata:** Cycle `TODO`/`NEXT`/`DONE` states, set priorities (`[#A]`–`[#C]`), edit `:tags:`, pick `SCHEDULED` and `DEADLINE` dates via Material 3 DatePickers, and edit `:PROPERTIES:` drawers.
  - **Live `org-clock` Timer:** Clock in/out directly from the tablet header with a live elapsed timer synced to Emacs.
  - **Power Checklists:** Toggle `[X]` / `[ ]` / `[-]` (partial), inline-edit item text, indent/outdent hierarchy, reorder items, or add new items.
  - **Org Babel Source Blocks:** View syntax-styled `#+BEGIN_SRC` blocks and tap **▶ Run** to execute via `org-babel-execute-src-block` in Emacs and view live `#+RESULTS:`.
  - **Interactive Org Tables & Subheadings:** Edit table cells inline and drill down into child subheadings with a top **Breadcrumb Trail**.
  - **Split-Pane View:** View and edit a sketch side-by-side with the node's Org text or a second reference sketch.
  - **Spaced Repetition (`org-drill`):** Flag headings as flashcards (`:drill:`) directly from the tablet or Emacs (`C-c w f`).

### 4. Resilient Bidirectional Sync & Offline-First Architecture
- **Zero-Dependency Emacs Server:** Built-in RFC 6455 WebSocket + JSON-RPC 2.0 server in pure Elisp—no external Python/Node bridges required.
- **Flexible Transport & Pairing:**
  - **USB (Zero-Config):** One-command `adb reverse tcp:9876 tcp:9876` tunnel (`M-x org-writenotes-connect-adb`).
  - **Wireless LAN / Tailscale:** Token-authenticated QR code pairing (`M-x org-writenotes-pair-qr` or `M-x org-writenotes-pair-tailscale`) with brute-force rate limiting.
- **Offline SQLite Cache & Mutation Coalescing:**
  - Browse cached nodes, edit text/checklists, and create or modify sketches completely offline.
  - Pending mutations are persisted in SQLite (`OfflineStore`) with automatic coalescing and replayed upon reconnection.
  - Crash-recovery snapshots and automatic flush on `ON_PAUSE` / `onTrimMemory`.
- **Data Safety & Conflict Protection:**
  - Atomic `.svgz` disk writes (`temp + rename`) and automatic rolling snapshot history (`writenotes/.history/`) with one-command revert (`M-x org-writenotes-revert-sketch-at-point`).
  - Optimistic concurrency via SHA-1 `etag` / `baseEtag` verification—conflicting edits are safely preserved as `*.conflict-<timestamp>.svgz`.
  - **Conflict Resolution Screen:** Review both versions side by side, overlaid, or flipping between them, then keep the Emacs copy, keep the tablet copy, or merge every stroke. The replaced copy is kept in `.history/`.
- **Dark Mode & Theme Synchronization:**
  - Emacs broadcasts its active theme palette (`isDark`, background, foreground, accent) to the tablet.
  - Adaptive inline `.svgz` rendering in Emacs (`org-writenotes-inline-theme`) automatically adjusts paper and ink contrast in dark mode without altering the saved `.svgz` file on disk.

---

## Architecture Overview

```mermaid
flowchart LR
    subgraph Emacs["GNU Emacs (org-writenotes.el)"]
        AST["Org Buffer AST\n(Headings, Checklists, Tables, Babel)"]
        SVGZ["Common Image Dir\n(./writenotes/*.svgz + .history/)"]
        WS_SRV["RFC 6455 WebSocket\nJSON-RPC 2.0 Server"]
    end

    subgraph Transport["Transport Layer"]
        ADB["ADB USB Reverse\n(127.0.0.1:9876)"]
        LAN["LAN / Tailscale\n(QR + 256-bit Token)"]
    end

    subgraph Tablet["Android Tablet Companion"]
        SYNC["EmacsSyncClient\n(SQLite Cache + Offline Queue)"]
        UI["Jetpack Compose UI\n(Sidebar, Split Pane, Zoom Overlay)"]
        JNI["WriteCanvasBlockView\n+ Stylus Labs Write C++ JNI"]
    end

    AST <--> WS_SRV
    SVGZ <--> WS_SRV
    WS_SRV <--> ADB
    WS_SRV <--> LAN
    ADB <--> SYNC
    LAN <--> SYNC
    SYNC <--> UI
    UI <--> JNI
```

---

## Repository Structure

| Path | Description |
| :--- | :--- |
| [`emacs/org-writenotes.el`](emacs/org-writenotes.el) | Core Emacs package: RFC 6455 WebSocket server, JSON-RPC 2.0 dispatcher, Org AST parser/mutator, adaptive `.svgz` inline image renderer, and `org-writenotes-follow-mode`. |
| [`emacs/org-writenotes-extras.el`](emacs/org-writenotes-extras.el) | Extended capabilities: atomic writes, `.history/` version snapshots, `etag` conflict copies, Tailscale pairing, `org-roam` sketch backlinks, link repair, `ox-html` inline SVG export, and `C-c w` transient menu. |
| [`docs/protocol-spec.md`](docs/protocol-spec.md) | JSON-RPC 2.0 over WebSocket wire protocol specification (`session.hello`, `node.*`, `ink.*`, `emacs.*`, `presence.*`). |
| [`android/app/src/main/cpp/write_bridge_jni.cpp`](android/app/src/main/cpp/write_bridge_jni.cpp) | C++ JNI & portable C ABI (`wn_session_*`) bridge (`NativeCanvasSession`) wrapping Stylus Labs Write's `Document`, `Page`, `StrokeBuilder`, shape recognizer, paper templates, tiled renderer, and `.svgz` serializer across Android, Linux Desktop, and iPadOS. |
| [`android/app/src/main/cpp/linux_stylus_input.cpp`](android/app/src/main/cpp/linux_stylus_input.cpp) | Native Linux stylus & touch manager (`XInput2` + XWayland tablet devices + Linux kernel `evdev` `/dev/input/event*`) supporting Wacom EMR, USI, AES, pressure, tilt (`tiltX`, `tiltY`), eraser tail (`BTN_TOOL_RUBBER`), and barrel buttons (`BTN_STYLUS`, `BTN_STYLUS2`). |
| [`android/desktop/`](android/desktop/) | Kotlin Compose Desktop (`:desktop`) module sharing 100% of the Compose UI, `WriteCanvasBlockView`, and `EmacsSyncClient` on Linux (X11 & Wayland). |
| [`linux/org-writenotes-linux`](linux/org-writenotes-linux) | Linux launcher supporting Full Companion Mode, Quick Single-Sketch Popup Mode (`--sketch <file.svgz>`), and stylus device diagnostics (`--devices`). |
| [`android/app/src/main/java/com/orgwritenotes/ink/`](android/app/src/main/java/com/orgwritenotes/ink/) | `WriteCanvasBlockView` (stylus input, palm rejection, gestures), `HandwritingOcrEngine` (basic stroke recognizer for the lasso dialog), `OcrSmartInsert`, `AudioSketch`, `SvgLayers`, and `StrokeTuning`. |
| [`android/app/src/main/java/com/orgwritenotes/sync/`](android/app/src/main/java/com/orgwritenotes/sync/) | `EmacsSyncClient` (WebSocket JSON-RPC client, auto-reconnect, mutation coalescing), `OfflineStore` (SQLite persistence), and `AppLogger`. |
| [`android/app/src/main/java/com/orgwritenotes/ui/`](android/app/src/main/java/com/orgwritenotes/ui/) | Jetpack Compose tablet UI: `OrgWriteNotesTabletScreen`, `WriteZoomedEditorOverlay`, `WriteSplitPane`, and `WriteExtrasBar`. |

---

## Quick Start

### 1. Emacs Setup

Requirements: **GNU Emacs 28.1+** (built with `librsvg` and `zlib` support) and **Org 9.5+**.

```elisp
(add-to-list 'load-path "/path/to/org-writenotes/emacs")
(require 'org-writenotes)

;; Store all .svgz sketches in a single common folder (relative to the .org file or global)
(setq org-writenotes-image-dir "./writenotes")

;; Adaptive inline .svgz theme ('auto adapts to dark/light Emacs themes, 'paper, or 'transparent)
(setq org-writenotes-inline-theme 'auto)

;; Start the WebSocket server and set up ADB USB reverse port forwarding (localhost:9876)
(org-writenotes-connect-adb)

;; Automatically push the active Org heading to the tablet as you move point
(org-writenotes-follow-mode 1)

;; Enable the C-c w keybinding prefix in Org buffers
(add-hook 'org-mode-hook #'org-writenotes-mode)
```

### 2. Building & Installing the Android App

Connect your Android tablet via USB (with USB Debugging enabled) and run the helper script:

```bash
./android/build_and_install.sh
```

Or build manually with Gradle:

```bash
cd android
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb reverse tcp:9876 tcp:9876
```

### 3. Running on Linux Tablet / Laptop (Wacom EMR / USI / AES Stylus)

The `:desktop` module builds `liborgwritenotes_jni.so` (Stylus Labs Write C++ engine + native Linux `XInput2` and kernel `evdev` stylus subsystem) and runs the full Compose UI natively on Linux (both Wayland and X11):

```bash
# 1. Full Companion App Mode (auto-connects to local Emacs on ws://127.0.0.1:9876)
./linux/org-writenotes-linux

# 2. Quick Single-Sketch Popup Mode (opens a single .svgz directly in full-screen stylus mode)
./linux/org-writenotes-linux --sketch /path/to/writenotes/diagram.svgz

# 3. Inspect detected Linux XInput2 / evdev stylus & touch hardware
./linux/org-writenotes-linux --devices
```

> **Note (Wayland / Kernel `evdev` Stylus Axes):** On X11 and XWayland, Wacom EMR / USI / AES pressure, tilt, eraser tip, and barrel buttons are read automatically via `XInput2`. For direct kernel `/dev/input/event*` access under Wayland, ensure your user is in the `input` group (`sudo usermod -aG input $USER`).

### 4. Running on iPadOS (Apple Pencil 1st/2nd Gen, USB-C, & Apple Pencil Pro)

The `ios/` Swift Package and `android/ios-kmp/` Kotlin Multiplatform `cinterop` module wrap the exact same C++ Stylus Labs Write engine (`write_bridge_c_api.h` / `liborgwritenotes_c_static.a`) and support:
- **240Hz Coalesced Touches & ProMotion 120Hz Predicted Wet-Ink** (`WriteCanvasUIView.swift`)
- **Altitude & Azimuth Tilt + Normalized Pressure** (with USB-C Apple Pencil fallback)
- **Apple Pencil Pro Barrel Roll (`rollAngle`)** mapped dynamically to chisel nib angle (`chiselAngle`)
- **Apple Pencil Hover (`UIHoverGestureRecognizer` `zOffset`)**, **2nd Gen Double-Tap**, and **Apple Pencil Pro Squeeze** (`UIPencilInteraction`) to open the floating radial tool palette

```bash
# Option A: Open directly in Xcode on macOS and deploy to iPad / Simulator
open ios/Package.swift

# Option B: Build universal OrgWriteNotesEngine.xcframework (iPadOS arm64 + Simulator)
./ios/build_xcframework.sh
```

In Emacs, run `M-x org-writenotes-connect-ipad` (`C-c w i`) to display a deep-link QR code (`orgwritenotes://connect?host=...&port=9876&token=...`) or pass `C-u M-x org-writenotes-connect-ipad` to tunnel over USB via `iproxy 9876 9876`.

---

## Emacs Commands & Keybindings

When `org-writenotes-mode` is active in an Org buffer, use the `C-c w` prefix (or invoke `M-x org-writenotes-menu` for the interactive Transient popup):

| Key / Command | Description |
| :--- | :--- |
| `M-x org-writenotes-connect-adb` | Start the WebSocket server and run `adb reverse tcp:9876 tcp:9876` for USB pairing. |
| `C-c w d` / `M-x org-writenotes-connect-linux` | Start the WebSocket server and launch the local Linux Desktop companion app (`org-writenotes-linux`). |
| `C-c w s` / `M-x org-writenotes-popup-sketch-at-point` | Open the `.svgz` sketch at point directly in a Linux single-sketch popup window and auto-refresh inline on save/close. |
| `C-c w i` / `M-x org-writenotes-connect-ipad` | Start the server (optionally with `iproxy` USB port forwarding) and display an `orgwritenotes://connect` QR code for iPadOS. |
| `C-c w q` / `M-x org-writenotes-pair-qr` | Start the server on LAN and display a QR code + session token for wireless pairing. |
| `C-c w t` / `M-x org-writenotes-pair-tailscale` | Bind to your Tailscale IPv4 (`100.x.y.z`) and generate a Tailscale pairing QR code. |
| `C-c w p` / `M-x org-writenotes-push-node` | Push the Org subtree at point to the connected tablet. |
| `M-x org-writenotes-insert-sketch` | Create a new `.svgz` canvas, insert `[[file:./writenotes/...svgz]]` at point, and open it on the tablet. |
| `M-x org-writenotes-open-sketch-at-point` | Open the `.svgz` link at point directly in the tablet's full-screen zoomed editor (also bound to `C-c C-o` on `.svgz` links). |
| `M-x org-writenotes-annotate-image-at-point` | Wrap a PNG/JPEG/WebP image link at point as the background template of a new `.svgz` sketch and open on the tablet. |
| `M-x org-writenotes-delete-sketch-at-point` | Delete the `.svgz` link at point and remove its file from disk. |
| `C-c w r` / `M-x org-writenotes-revert-sketch-at-point` | Restore a previous version of the `.svgz` sketch at point from `.history/`. |
| `M-x org-writenotes-ocr-run-now` | Recognize all queued sketches immediately, without waiting for Emacs to go idle. |
| `C-c w b` / `M-x org-writenotes-show-sketch-backlinks` | List all Org headings (including `org-roam` files) referencing the sketch at point. |
| `C-c w l` / `M-x org-writenotes-repair-links` | Automatically repair broken `.svgz` file links in the current buffer. |
| `C-c w f` / `M-x org-writenotes-flag-as-flashcard` | Flag the current Org heading as an `org-drill` spaced-repetition card (`:drill:`). |
| `M-x org-writenotes-gallery` | Open an interactive gallery buffer of all `.svgz` sketches with thumbnails and heading links. |
| `M-x org-writenotes-clean-orphans` | Scan `.org` files for unreferenced `.svgz` files and move orphans to `.trash/`. |
| `C-c w w` / `M-x org-writenotes-menu` | Open the Transient command menu. |

---

## Customization Variables

| Variable | Default | Description |
| :--- | :--- | :--- |
| `org-writenotes-image-dir` | `"./writenotes"` | Directory (relative to `.org` file or absolute) where `.svgz` files are stored. |
| `org-writenotes-port` | `9876` | TCP port for the WebSocket JSON-RPC server. |
| `org-writenotes-inline-theme` | `'auto` | Inline SVG rendering mode in Emacs (`'auto`, `'paper`, or `'transparent`). |
| `org-writenotes-inline-max-width` | `760` | Maximum pixel width for inline `.svgz` previews in Emacs (`nil` for native width). |
| `org-writenotes-sketch-history-depth` | `20` | Number of historical snapshots retained per sketch inside `.history/`. |
| `org-writenotes-auto-sync-ocr-drawer` | `nil` | When non-nil, automatically insert/update folded `:WRITENOTES_OCR:` drawers for OCR text sent by a client on ink commit. |
| `org-writenotes-ocr-enabled` | `nil` | Set to `t` to recognize sketches with the local TrOCR helper (requires the setup below). |
| `org-writenotes-ocr-idle-seconds` | `180` | Seconds Emacs must be idle, and a sketch left untouched, before OCR runs. |
| `org-writenotes-ocr-python` | `~/.cache/org-writenotes-ocr/venv/bin/python` | Python interpreter (with torch, transformers, cairosvg) that runs the helper. |
| `org-writenotes-ocr-script` | `ocr/recognize.py` next to `emacs/` | Path to the OCR helper script. |
| `org-writenotes-ocr-device` | `"auto"` | `"auto"`, `"cuda"` or `"cpu"`. |
| `org-writenotes-ocr-model` | `nil` | TrOCR model, picked from a menu in `M-x customize-variable` or entered as a Hugging Face id or local path (default `microsoft/trocr-base-handwritten`). |
| `org-writenotes-live-stroke-preview` | `nil` | When non-nil, splice incoming `ink.delta` strokes into Emacs inline previews in real time. |
| `org-writenotes-html-inline-svgz` | `t` | Inline `.svgz` links directly as `<svg>` elements during `ox-html` export. |

---

## Setting up local OCR

Handwriting is recognized on the machine that runs Emacs, with [TrOCR](https://huggingface.co/microsoft/trocr-base-handwritten). Nothing leaves the machine; the model is downloaded once from Hugging Face on first use (about 1.3 GB).

```bash
python3 -m venv ~/.cache/org-writenotes-ocr/venv
~/.cache/org-writenotes-ocr/venv/bin/pip install "torch>=2.6" torchvision --index-url https://download.pytorch.org/whl/cu124   # use .../whl/cpu without an NVIDIA GPU
~/.cache/org-writenotes-ocr/venv/bin/pip install "transformers>=4.46,<5" pillow cairosvg
```

PyTorch 2.6 or newer is required: the large and small TrOCR models ship only pickle `.bin` weights, which recent transformers refuses to load on older PyTorch (CVE-2025-32434). Then turn it on with `(setq org-writenotes-ocr-enabled t)`; it is off by default.

- **When it runs:** after Emacs has been idle, and the sketch left alone, for `org-writenotes-ocr-idle-seconds`. Drawing on the tablet does not count as Emacs activity, so a sketch finished while you are away is recognized a few minutes later.
- **Run it now:** `M-x org-writenotes-ocr-run-now` recognizes all queued sketches immediately.
- **Try the helper by hand:** `~/.cache/org-writenotes-ocr/venv/bin/python ocr/recognize.py < sketch.svgz` prints the recognized lines as JSON.
- **Behaviour on commit:** an existing `:WRITENOTES_OCR:` drawer stays in place (stale but searchable) until fresh text replaces it. Unchanged sketches are not re-processed.

---

## Testing

Run the Emacs ERT test suites in batch mode:

```bash
emacs -Q --batch -L emacs \
  -l emacs/org-writenotes-test.el \
  -l emacs/org-writenotes-extras-test.el \
  -f ert-run-tests-batch-and-exit
```

For client application tests (Android, Compose Desktop, iOS), see the [`org-writenotes-apps`](https://github.com/SSD2019/org-writenotes-apps) repository.
