# Org-WriteNotes Wire Protocol Specification (v1.0)

Org-WriteNotes communicates between **GNU Emacs** (`org-writenotes.el`) and the **Android Tablet Companion App** over a single **WebSocket** connection using **JSON-RPC 2.0**.

---

## 1. Transport & Pairing Modes

### 1.1 Mode A: ADB USB Tunnel (Zero-Config)
- Emacs runs `adb reverse tcp:9876 tcp:9876` via `M-x org-writenotes-adb-reverse`.
- The Android tablet connects to `ws://127.0.0.1:9876/org-writenotes`.
- Latency: `< 2ms`, works offline without Wi-Fi.

### 1.2 Mode B: LAN / Tailscale Network (QR Code Pairing)
- Emacs listens on `0.0.0.0:9876` (or a user-configured interface/port) with a 256-bit session token (`org-writenotes-session-token`).
- `M-x org-writenotes-pair-qr` displays a QR code encoding:
  ```json
  {
    "v": 1,
    "url": "ws://192.168.1.42:9876/org-writenotes",
    "token": "8f9d2a..."
  }
  ```
- Client sends `session.hello` as the first message to authenticate.

---

## 2. Core Data Structures

### 2.1 `OrgNodeSummary` (Used in Sidebar / Agenda / Search)
```json
{
  "nodeId": "file:/home/user/org/tasks.org::#design-sync-engine",
  "filePath": "/home/user/org/tasks.org",
  "outlinePath": ["Projects", "Org-WriteNotes"],
  "level": 2,
  "todoKeyword": "TODO",
  "priority": "A",
  "title": "Design System Architecture for Sync Engine",
  "tags": ["design", "arch"],
  "scheduled": "2026-11-03",
  "deadline": null,
  "checkboxProgress": "2/3",
  "sketchCount": 1
}
```

### 2.2 `OrgNodeSnapshot` (Block-Interleaved Hybrid Model)
An Org node's body is decomposed into an ordered list of blocks so that native UI elements (checklists, paragraphs, drawers) and Stylus Labs Write ink canvases (`[[file:./writenotes/....svgz]]`) interleave seamlessly:

```json
{
  "nodeId": "file:/home/user/org/tasks.org::142",
  "etag": "tick-9821-sha1-4b825dc6",
  "header": {
    "level": 2,
    "todoKeyword": "TODO",
    "todoKeywordsAll": ["TODO", "NEXT", "WAIT", "DONE"],
    "priority": "A",
    "title": "Design System Architecture for Sync Engine",
    "tags": ["design", "arch"],
    "scheduled": "2026-11-03",
    "deadline": null,
    "properties": {
      "ID": "4f8c9a12-3b2a-4d1e-9c0f-1a2b3c4d5e6f"
    }
  },
  "blocks": [
    {
      "blockId": "blk-1",
      "type": "checklist",
      "items": [
        { "index": 0, "state": "checked", "text": "Define JSON-RPC framing" },
        { "index": 1, "state": "checked", "text": "Test ADB reverse socket" },
        { "index": 2, "state": "unchecked", "text": "Implement delta stroke streaming" }
      ]
    },
    {
      "blockId": "blk-2",
      "type": "ink_canvas",
      "fileName": "design-system-arch-20261102-153000.svgz",
      "linkText": "[[file:./writenotes/design-system-arch-20261102-153000.svgz]]",
      "width": 1200,
      "height": 800,
      "yRuling": 40,
      "xRuling": 40,
      "paperColor": "#FFFDF8",
      "ruleColor": "#4A90E233",
      "svgzBase64": "H4sIAAAAAAAAA..."
    },
    {
      "blockId": "blk-3",
      "type": "paragraph",
      "text": "Notes from architecture review: keep in-flight strokes uncompressed as XML fragments and commit full block-gzipped .svgz on debounce."
    }
  ]
}
```

---

## 3. JSON-RPC 2.0 Methods

### 3.1 Handshake & Discovery (Tablet → Emacs)
- **`session.hello`**
  - Params: `{ "clientName": "Pixel Tablet", "version": "1.0.0", "token": "..." }`
  - Result: `{ "emacsVersion": "30.1", "orgVersion": "9.7", "imageDir": "./writenotes", "activeNodeId": "..." }`
- **`node.list`**
  - Params: `{ "filter": "pushed_history" | "buffer_outline" | "agenda" | "search", "query": "", "date": "YYYY-MM-DD" }`
  - `agenda` returns the entries of Emacs' own day agenda (`org-agenda-get-day-entries` over `org-agenda-files`) for `date` (default today): overdue SCHEDULED items and DEADLINE warnings included, timed entries first. Each summary carries an `agendaLabel` such as `"14:30"`, `"Scheduled"`, `"Sched.3x"`, `"In 2 d."`.
  - `search` needs a query of 2+ characters, matches each heading once, and returns at most `org-writenotes-search-max-results` (default 100) nodes.
  - Result: `{ "nodes": [ OrgNodeSummary, ... ] }`
- **`node.get`**
  - Params: `{ "nodeId": "..." }`
  - Result: `OrgNodeSnapshot`

### 3.2 Structured Org Node Mutations (Tablet → Emacs)
- **`node.updateHeader`**
  - Params: `{ "nodeId": "...", "todoKeyword": "NEXT", "priority": "A", "title": "...", "tags": ["design", "arch"] }`
- **`node.toggleCheckbox`**
  - Params: `{ "nodeId": "...", "blockId": "blk-1", "itemIndex": 2, "state": "checked" }`
- **`node.addChecklistItem`**
  - Params: `{ "nodeId": "...", "blockId": "blk-1", "text": "Verify librsvg inline refresh" }`
- **`node.updateParagraph`**
  - Params: `{ "nodeId": "...", "blockId": "blk-3", "text": "Updated paragraph text..." }`
- **`node.insertInkBlock`**
  - Params: `{ "nodeId": "...", "afterBlockId": "blk-1", "width": 1200, "height": 600, "xRuling": 40, "yRuling": 40 }`
  - Result: `{ "blockId": "blk-new", "fileName": "design-system-arch-20261102-154210.svgz", "linkText": "[[file:./writenotes/design-system-arch-20261102-154210.svgz]]" }`

### 3.3 Real-Time Ink Sync & `.svgz` Storage (Tablet → Emacs)
- **`ink.delta`** *(Sent immediately on pen-up / eraser action for live preview)*
  - Params:
    ```json
    {
      "nodeId": "...",
      "fileName": "design-system-arch-20261102-153000.svgz",
      "op": "stroke_add",
      "strokeId": "s_104",
      "pathXml": "<path id=\"s_104\" class=\"ug-path\" fill=\"#1e293b\" __comx=\"140.2\" __comy=\"82.1\" d=\"M 120 80 L 160 84 ...\"/>",
      "canvasWidth": 1200,
      "canvasHeight": 800
    }
    ```
- **`ink.commit`** *(Sent after 3.0s idle debounce or when switching nodes; writes `.svgz` to disk and refreshes Emacs inline image)*
  - Params:
    ```json
    {
      "nodeId": "...",
      "fileName": "design-system-arch-20261102-153000.svgz",
      "width": 1200,
      "height": 1040,
      "svgzBase64": "H4sIAAAAAAAAA..."
    }
    ```
  - Result: `{ "savedPath": "/home/user/org/writenotes/design-system-arch-20261102-153000.svgz", "bytesWritten": 6412 }`

- **`ink.conflictInfo`** (capability `ink.resolveConflict`)
  - Params: `{ "nodeId": "...", "fileName": "...", "conflictFile": "optional; default newest" }`
  - Result: `{ "fileName", "conflictFile", "conflictCount", "emacsSvgzBase64", "tabletSvgzBase64", "etag" }`
- **`ink.resolveConflict`**
  - Params: `{ "nodeId": "...", "fileName": "...", "conflictFile": "...", "choice": "emacs" | "tablet" | "merged", "svgzBase64": "<merged copy, for merged>" }`
  - The previous file is snapshotted to `.history/` and the conflict copy moved there (never deleted).
  - Result: `{ "svgzBase64": "<final file>", "etag": "...", "remainingConflicts": 0 }`

### 3.4 Server Push Notifications (Emacs → Tablet)
- **`emacs.focusNode`** *(Sent when user runs `M-x org-writenotes-push-node` or when `org-writenotes-follow-mode` moves to a new heading)*
  - Params: `OrgNodeSnapshot`
- **`emacs.nodeModified`** *(Sent when user edits the active Org subtree inside Emacs)*
  - Params: `OrgNodeSnapshot`

