# Org-WriteNotes

A companion Android tablet app and GNU Emacs package (`org-writenotes.el`) for editing Org-mode nodes with embedded, dynamically expanding handwritten ink blocks powered by the **[Stylus Labs Write](https://github.com/styluslabs/Write)** C++ engine.

---

## Architecture & Repository Layout

- **[docs/protocol-spec.md](file:///home/saisan/.vim/emacs_plugin/org-writenotes/docs/protocol-spec.md)** — JSON-RPC 2.0 over WebSocket protocol specification (ADB USB tunnel + LAN/Tailscale QR pairing, Org AST block-interleaved snapshots, live stroke deltas, and `.svgz` commits).
- **[emacs/org-writenotes.el](file:///home/saisan/.vim/emacs_plugin/org-writenotes/emacs/org-writenotes.el)** — Zero-dependency Emacs package providing:
  - Built-in RFC 6455 WebSocket + JSON-RPC 2.0 server (`M-x org-writenotes-start-server`)
  - One-command ADB USB reverse port forwarding (`M-x org-writenotes-connect-adb`)
  - Common-directory `.svgz` management (`org-writenotes-image-dir`, defaulting to `./writenotes` with standard `[[file:./writenotes/<slug>-<timestamp>.svgz]]` links)
  - Automatic inline `.svgz` rendering in Emacs via `librsvg`
  - Live `org-writenotes-follow-mode` to push the active Org heading to the tablet automatically.
- **android/** — Modern Kotlin + Jetpack Compose Android tablet app embedding the Stylus Labs Write C++ engine via JNI:
  - **[android/cpp/Write](file:///home/saisan/.vim/emacs_plugin/org-writenotes/android/cpp/Write)** — Cloned Stylus Labs Write repository and core C++ submodules (`usvg`, `ulib`, `pugixml`, `miniz`, `nanovgXC`, `stb`).
  - **[write_bridge_jni.h](file:///home/saisan/.vim/emacs_plugin/org-writenotes/android/app/src/main/cpp/write_bridge_jni.h) / [write_bridge_jni.cpp](file:///home/saisan/.vim/emacs_plugin/org-writenotes/android/app/src/main/cpp/write_bridge_jni.cpp)** — C++ JNI bridge (`NativeCanvasSession`) wrapping Stylus Labs Write's `Document`, `Page`, `StrokeBuilder`, and block-gzipped `.svgz` serializer, with automatic vertical canvas expansion.
  - **[WriteCanvasBlockView.kt](file:///home/saisan/.vim/emacs_plugin/org-writenotes/android/app/src/main/java/com/orgwritenotes/ink/WriteCanvasBlockView.kt)** — Android custom view with stylus-only palm rejection (finger touch passes through to scroll the Org node; stylus events render pressure-sensitive strokes).
  - **[EmacsSyncClient.kt](file:///home/saisan/.vim/emacs_plugin/org-writenotes/android/app/src/main/java/com/orgwritenotes/sync/EmacsSyncClient.kt)** — WebSocket JSON-RPC 2.0 client supporting real-time stroke delta streaming (`ink.delta`) and debounced `.svgz` binary commits (`ink.commit`).
  - **[OrgWriteNotesTabletScreen.kt](file:///home/saisan/.vim/emacs_plugin/org-writenotes/android/app/src/main/java/com/orgwritenotes/ui/OrgWriteNotesTabletScreen.kt)** — Landscape tablet UI with collapsible Org agenda/heading sidebar, interactive checklists, and inline expanding Write `.svgz` blocks.

---

## Quick Start (Emacs Setup)

```elisp
(add-to-list 'load-path "/home/saisan/.vim/emacs_plugin/org-writenotes/emacs")
(require 'org-writenotes)

;; Store all .svgz sketches in a single common folder (relative to the .org file or global)
(setq org-writenotes-image-dir "./writenotes")

;; Start server and set up ADB USB port forwarding (localhost:9876)
(org-writenotes-connect-adb)

;; Optional: Automatically switch the tablet view to whichever Org heading point is on
(org-writenotes-follow-mode 1)
```

### Interactive Emacs Commands
- `M-x org-writenotes-connect-adb` — Starts the WebSocket server and runs `adb reverse tcp:9876 tcp:9876`.
- `M-x org-writenotes-push-node` — Pushes the Org subtree at point to the connected tablet.
- `M-x org-writenotes-insert-sketch` — Creates a new `.svgz` file in `org-writenotes-image-dir`, inserts `[[file:./writenotes/...svgz]]` into the current Org node, and opens it on the tablet.

