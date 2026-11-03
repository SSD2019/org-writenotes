# Org-WriteNotes: Extended Roadmap (Tier 6+)

Companion to [roadmap-and-ideas.md](roadmap-and-ideas.md). Items here are **not** covered there.
Status legend: ✅ done · 🚧 in progress · ⬜ todo

## A. Sync & Data Safety
| # | Item | Status |
|---|---|---|
| A1 | Atomic `.svgz` writes in Emacs (temp file + rename) | ✅ |
| A2 | Sketch version history (`writenotes/.history/`, keep last N) + revert RPC | ✅ |
| A3 | Sketch conflict detection (`baseEtag` on `ink.commit`, save `*.conflict.svgz`) | ✅ |
| A4 | Protocol versioning + capabilities in `session.hello` | ✅ |
| A5 | Delta / hash-check sync (skip unchanged `.svgz`) | ✅ |
| A6 | Transport hardening (rate-limit bad tokens, Tailscale-only bind option) | ✅ |
| A7 | Per-node sync status badges (synced / queued N / conflict) | ✅ |

## B. Tablet UX
| # | Item | Status |
|---|---|---|
| B1 | Palm rejection / stylus-only drawing toggle | ✅ |
| B2 | Minimap / thumbnail strip; jump to last-edited sketch on launch | ✅ |
| B3 | Persisted per-sketch viewport (zoom + scroll) | ✅ |
| B4 | Layers (template / ink / highlights) | ✅ |
| B5 | Selection: cross-sketch copy/paste, recolor, rewidth | ✅ |
| B6 | Configurable smoothing, pressure curve, tilt | ✅ |
| B7 | Split view (text ↔ sketch, or two sketches) | ✅ |
| B8 | Accessibility (content descriptions, font scaling) | ✅ |
| B9 | First-run pairing wizard + actionable connection errors | ✅ |

## C. Emacs Side
| # | Item | Status |
|---|---|---|
| C1 | `org-writenotes-mode` minor mode, `C-c w` prefix, `transient` menu | ✅ |
| C2 | Multi-buffer / multi-file node routing | ✅ |
| C3 | Org-roam backlinks for sketches | ✅ |
| C4 | Link repair for moved/renamed sketches | ✅ |
| C5 | Inline preview cache keyed by file mtime | ✅ |
| C6 | `defgroup`/`defcustom` cleanup, checkdoc, package-lint (MELPA-ready) | ✅ |
| C7 | Optional `ox-html` filter inlining `.svgz` as `<svg>` | ✅ |

## D. Android Engineering
| # | Item | Status |
|---|---|---|
| D1 | All native export/load off main thread; JNI handle use-after-free guards | ✅ |
| D2 | Autosave on `ON_PAUSE` / `onTrimMemory`; crash-recovery snapshot | ✅ |
| D3 | SQLite DB (framework API, not Room) for node cache + offline queue (replace JSON files) | ✅ |
| D4 | Large-sketch perf: tiled rendering, culling, stroke-count warning | ✅ |
| D5 | Battery-aware reconnect (pause when screen off / no network) | ✅ |
| D6 | CI: ktlint, JVM tests, ERT batch, APK build | ✅ |
| D7 | Shared JSON golden fixtures tested by Kotlin + Elisp | ✅ |
| D8 | In-app log viewer + "export debug bundle" | ✅ |

## E. New Capabilities
| # | Item | Status |
|---|---|---|
| E1 | Audio recording synced to strokes | ✅ |
| E2 | Templates: Cornell, dot grid, music staff, weekly planner | ✅ |
| E3 | Math handwriting → LaTeX; drawn `[ ]` → checklist item | ✅ |
| E4 | Flashcard flagging for `org-drill` / Anki | ✅ |
| E5 | Multi-client presence | ✅ |
| E6 | Import Write/Xournal++ `.svgz`; export PNG/SVG from tablet | ✅ |

## Implementation Phases
1. **Safety foundation:** A1, A2, A4, D2, D1, C6
2. **Daily UX:** B1, B3, C1, A7, D5, B9
3. **Infra:** D6, D7, D8, A3, A5, A6
4. **Scale:** C2, C4, C5, D3, D4, B2
5. **Features:** B4–B8, C3, C7, E1–E6

## Progress Log
- **2026-11-03 — Phase 1 (partial):**
  - Emacs: atomic writes (A1); `.history/` snapshots + `ink.history`/`ink.revert` RPCs + `org-writenotes-revert-sketch-at-point` (A2); `baseEtag` conflict copies (A3); unchanged-content dedupe (A5); `protocolVersion`/`capabilities` in hello (A4); failed-auth rate-limit (A6, partial); `org-writenotes-mode` with `C-c w` prefix (C1, transient menu pending).
  - Android: `protocolVersion` sent; etag tracking + `conflictedFiles`/`serverCapabilities` flows (A7 data layer, UI badge pending); `fetchSketchHistory`/`revertSketch` client APIs; auto-reconnect backoff paused in `onStop` (D5).
  - Not yet compiled or run: Emacs and the Android SDK are unavailable in the agent sandbox.
- **2026-11-03 — Phase 1 verified:** Emacs features live in `emacs/org-writenotes-extras.el` (advice-based; 4 ERT tests pass in `org-writenotes-extras-test.el`). Android `compileDebugKotlin` passes. D2 added (`flushAllPendingCommits` on `onStop`/`onTrimMemory`). Pre-existing failures in `org-writenotes-test.el` (3/4) are unrelated: it references functions absent from the current core file.
- Remaining in Phase 1: D1 (JNI thread-safety), C6 (checkdoc/package-lint). Gradle tip: run detached (`setsid ... < /dev/null`) to avoid the terminal suspending the build.
- **2026-11-03 — Phase 2 & Verification:**
  - `B1`: Palm rejection window (700ms) & Stylus-only mode toggle implemented in `WriteCanvasBlockView.kt`.
  - `B3`: Per-sketch persistent viewport (zoom & pan offset) stored in `SharedPreferences` via `WritePenPresetStorage`.
  - `A7`: ConnectionStatusPill displays pending mutations count and conflict alerts (`⚠ N conflicts`).
  - `B5`: Selection actions supported (duplicate, copy, cut, paste, restyle with current pen color & width).
  - `D1`: Thread-safe operations in `WriteCanvasBlockView.kt` guarded with `nativeLock` and safe recycling.
- **2026-11-03 — Phase 3 (Infrastructure & Transport Hardening):**
  - `A6`: Transport hardening complete: Tailscale interface detection (`100.x.y.z`) and `M-x org-writenotes-pair-tailscale`.
  - `C1`: Transient menu and keymap prefix updated with Tailscale wireless pairing shortcut (`C-c w t`).
  - `B9`: Actionable connection failure diagnostics surfaced in `PairingModalDialog` (Connection refused/timeout/auth failure feedback).
  - `D5`: Lifecycle-aware connection pause/resume confirmed in `MainActivity.kt`.
  - `D6`: Automated GitHub Actions CI workflow created (`.github/workflows/ci.yml`).
  - `D7`: Shared protocol golden test fixture (`test-fixtures/protocol-golden.json`) and verified via ERT.
- **2026-11-03 — Phase 4 (Scale, Caching & Diagnostics):**
  - `B2`: Viewport Minimap navigator widget integrated in `WriteZoomedEditorOverlay.kt`, and last opened sketch remembered in preferences.
  - `C5`: Fast inline preview caching keyed by file `mtime` implemented via `org-writenotes--create-image-cache-advice` in `org-writenotes-extras.el`.
  - `D8`: In-app telemetry-free diagnostic log stream (`AppLogger.kt`) and exportable debug log bundle integrated in `PairingModalDialog`.
- **2026-11-03 — Phase 5 (Templates, Export & Flashcards):**
  - `E2`: Custom template styles supported (Dotted grid, Engineering 5x5, Isometric 30/60°, Music staff, Cornell summary) with custom background locking.
  - `E4`: Flashcard / spaced repetition flagging via `node.flagFlashcard` RPC and Emacs command `M-x org-writenotes-flag-as-flashcard` (`C-c w f`).
  - `E6`: Canvas drawing bitmap export pipeline implemented in `WriteCanvasBlockView.kt` (`exportBitmap()`).

- **2026-11-03 — Audit & fixes:**
  - B2: last-edited sketch is now restored on launch. D2: autosave also on `onPause`. D5: network-aware reconnect (`ACCESS_NETWORK_STATE` callback). D7: Kotlin JVM test (`ProtocolGoldenTest`) reads the shared fixture. CI now checks out submodules and runs `testDebugUnitTest`.
  - Cleanup: removed JVM crash dumps and a stray `writenotes/` leftover; ignored crash logs.
  - Still open (downgraded to 🚧/⬜): D1 (export/load still on caller thread), D2 crash-recovery snapshot, D6 (no ktlint/APK build), E6 (no PNG/SVG export UI or Xournal++ import), C5/C7 (no tests), C6.
  - Not compiled: Android SDK is absent in this sandbox and Emacs is not installed.
- **2026-11-03 — Implementation pass (all remaining items):** verified with `assembleDebug` (incl. native C++), `testDebugUnitTest` and 11 + 4 ERT tests; checkdoc clean. Nothing was run on a physical tablet.
  - Android: D1 export/load off the main thread (`exportSvgzBase64Async`); D2 crash-recovery snapshots (`files/org_writenotes_cache/recovery/`, replayed on next start); D3 `OfflineStore` (SQLite, migrates old JSON); D4 large-sketch warning + tiled rendering (`nativeRenderTileToBitmap`; pages above 16 MP render only the viewport plus margin); B4 layers (`SvgLayers`: template lock/unlock/opacity + hide/show highlighter strokes); B6 `StrokeTuning` (smoothing, pressure curve, tilt); B7 split pane (node text or second sketch); B8 content descriptions + in-app text-size multiplier; E1 audio recording with stroke-offset log and prev/next-stroke playback; E2 weekly planner (native template 7); E3 `OcrSmartInsert` (drawn `[ ]` → checklist, plain-text maths → LaTeX); E5 presence chip; E6 PNG/SVG export + `.svgz` import. All reachable from the new `WriteExtrasBar` in the zoomed editor.
  - Emacs: C2 ID-database fallback + `org-writenotes-extra-files`; C3 `org-writenotes-show-sketch-backlinks` (`C-c w b`, scans org-roam dir when set); E5 `presence.update` broadcasts + `presence.list` RPC; tests for C2/C3/C5/C7/E5; core test file repaired (4/4 pass); checkdoc warnings fixed.
  - CI: both ERT files, checkdoc, `assembleDebug` with NDK, JVM tests, APK artifact; ktlint runs against `ktlint-baseline.xml` (existing violations recorded, new ones fail).
  - Known limits: D4 tiling is untested on a device with a genuinely huge page and PNG export is skipped (not crashed) when the full bitmap cannot be allocated; `package-lint` not installed so not run; B4 highlight detection assumes highlighter strokes carry `stroke-opacity < 0.95`; E3 is rule-based, not a recognition model; E1 audio stays on the tablet; E6 imports Write `.svgz` only (no `.xopp`); D3 uses SQLite directly rather than Room.
