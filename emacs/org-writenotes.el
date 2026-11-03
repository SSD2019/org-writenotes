;;; org-writenotes.el --- Companion tablet handwriting app integration for Org-mode -*- lexical-binding: t; -*-

;; Author: Org-WriteNotes Contributors
;; Maintainer: Org-WriteNotes Contributors
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (org "9.5"))
;; Keywords: outlines, hypermedia, multimedia, tools
;; URL: https://github.com/styluslabs/Write

;;; Commentary:
;;
;; `org-writenotes' pairs GNU Emacs with the Org-WriteNotes Android tablet
;; companion app (powered by the Stylus Labs Write C++ engine).
;;
;; Features:
;; - Built-in zero-dependency RFC 6455 WebSocket + JSON-RPC 2.0 server
;; - One-command ADB USB reverse port forwarding (`M-x org-writenotes-connect-adb')
;; - Network QR pairing (`M-x org-writenotes-pair-qr')
;; - Common-directory `.svgz' storage with native Emacs inline image rendering
;; - Block-interleaved Org AST serializer & mutator (headings, checklists,
;;   paragraphs, and expanding `.svgz' ink blocks)
;; - Live `org-writenotes-follow-mode' to push the current Org subtree to the tablet.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'org-id)
(require 'image)
(require 'image-file)
(require 'json)
(require 'url-util)

(defgroup org-writenotes nil
  "Handwritten stylus notes companion app for Org-mode."
  :group 'org
  :prefix "org-writenotes-")

(defcustom org-writenotes-port 9876
  "TCP port for the Org-WriteNotes WebSocket JSON-RPC server."
  :type 'integer
  :group 'org-writenotes)

(defcustom org-writenotes-host "127.0.0.1"
  "Host interface to bind the server to.
Use \"127.0.0.1\" for ADB USB debugging, or \"0.0.0.0\" for LAN/Tailscale."
  :type 'string
  :group 'org-writenotes)

(defcustom org-writenotes-image-dir "./writenotes"
  "Common directory for storing `.svgz' handwritten ink files.
Can be a path relative to the `.org' file (e.g., \"./writenotes\") or an
absolute directory path (e.g., \"~/org/writenotes\").
All nodes share this directory so per-node subdirectories are not required."
  :type 'string
  :group 'org-writenotes)

(defcustom org-writenotes-adb-executable
  (or (executable-find "adb")
      (let ((home-adb (expand-file-name "~/.android-sdk/platform-tools/adb")))
        (if (file-executable-p home-adb) home-adb "adb")))
  "Path to the `adb' executable used for USB reverse port forwarding."
  :type 'string
  :group 'org-writenotes)

(defcustom org-writenotes-default-canvas-width 1200
  "Default initial width (in px) for newly inserted `.svgz' ink blocks."
  :type 'integer
  :group 'org-writenotes)

(defcustom org-writenotes-default-canvas-height 600
  "Default initial height (in px) for newly inserted `.svgz' ink blocks."
  :type 'integer
  :group 'org-writenotes)

;;; Internal State

(defvar org-writenotes--server-proc nil
  "Listening network process for the Org-WriteNotes WebSocket server.")

(defvar org-writenotes--clients nil
  "List of connected client process objects.")

(defvar org-writenotes--session-token nil
  "Random 256-bit hex authentication token for network pairing.")

(defvar org-writenotes--active-node-id nil
  "Identifier (`file:<path>::<line-or-id>') of the currently focused Org node.")

(defcustom org-writenotes-history-limit 50
  "Maximum number of pushed Org nodes to keep in history."
  :type 'integer
  :group 'org-writenotes)

(defcustom org-writenotes-auto-start t
  "If non-nil, automatically start the WebSocket server and ADB tunnel when loaded."
  :type 'boolean
  :group 'org-writenotes)

(defcustom org-writenotes-auto-assign-id t
  "If non-nil, automatically create a stable Org `:ID:' when pushing a node."
  :type 'boolean
  :group 'org-writenotes)

(defcustom org-writenotes-inline-theme 'auto
  "Theme behavior for inline .svgz rendering in Emacs.
- `auto': Adapt colors if Emacs background is dark (soft dark paper, light strokes)
- `paper': Always render as drawn (cream paper, dark ink)
- `transparent': Remove paper background rect entirely."
  :type '(choice (const :tag "Auto-adapt to Emacs theme" auto)
                 (const :tag "Always paper appearance" paper)
                 (const :tag "Transparent background" transparent))
  :group 'org-writenotes)

(defcustom org-writenotes-inline-max-width 760
  "Default maximum pixel width for inline `.svgz' images in Emacs buffers.
Set to nil to render at native SVG width unless overridden by `#+ATTR_ORG: :width N'."
  :type '(choice integer (const nil))
  :group 'org-writenotes)

(defcustom org-writenotes-live-stroke-preview nil
  "If non-nil, splice incoming `ink.delta' strokes into an in-memory SVG preview."
  :type 'boolean
  :group 'org-writenotes)

(defcustom org-writenotes-capture-file nil
  "Optional default `.org' file path for quick-capture notes created from the tablet."
  :type '(choice file (const nil))
  :group 'org-writenotes)

(defcustom org-writenotes-auto-sync-ocr-drawer nil
  "If non-nil, automatically insert or update folded `:WRITENOTES_OCR:' drawers on ink commit.
When nil (the default), drawing on canvas updates the `.svgz' file and inline preview
without inserting `:WRITENOTES_OCR:' sections into the Org buffer unless an OCR drawer
already exists under the sketch link."
  :type 'boolean
  :group 'org-writenotes)

(defvar org-writenotes--last-theme-is-dark nil
  "Last known background mode of Emacs (t for dark, nil for light).")

(defvar org-writenotes--last-active-etag nil
  "Last broadcast `:etag' of `org-writenotes--active-node-id'.")

(defvar org-writenotes--change-debounce-timer nil
  "Idle timer for debounced live buffer change notifications.")

(defvar org-writenotes--live-svg-cache (make-hash-table :test 'equal)
  "In-memory SVG XML cache keyed by absolute `.svgz' path for live `ink.delta' splicing.")

;;; ---------------------------------------------------------------------------
;;; Theme Detection & Dynamic SVG Adaptation
;;; ---------------------------------------------------------------------------

(defun org-writenotes--hex-color-dark-p (hex-str)
  "Return t if HEX-STR (e.g. \"#1E293B\") has dark relative luminance (< 128)."
  (save-match-data
    (when (and (stringp hex-str)
               (string-match "\\`#\\([0-9A-Fa-f]\\{2\\}\\)\\([0-9A-Fa-f]\\{2\\}\\)\\([0-9A-Fa-f]\\{2\\}\\)" hex-str))
      (let* ((r (string-to-number (match-string 1 hex-str) 16))
             (g (string-to-number (match-string 2 hex-str) 16))
             (b (string-to-number (match-string 3 hex-str) 16))
             (lum (/ (+ (* r 299) (* g 587) (* b 114)) 1000)))
        (< lum 128)))))

(defun org-writenotes--normalize-hex-color (color &optional fallback)
  "Normalize COLOR to a 6-digit `#RRGGBB' hex string, or return FALLBACK."
  (save-match-data
    (cond
     ((or (null color)
          (not (stringp color))
          (string-empty-p color)
          (string-prefix-p "unspecified" (downcase color)))
      fallback)
     ((string-match "\\`#\\([0-9A-Fa-f]\\{6\\}\\)\\(?:[0-9A-Fa-f]\\{2\\}\\)?\\'" color)
      (concat "#" (upcase (match-string 1 color))))
     ((string-match "\\`#\\([0-9A-Fa-f]\\)\\([0-9A-Fa-f]\\)\\([0-9A-Fa-f]\\)\\'" color)
      (let ((r (upcase (match-string 1 color)))
            (g (upcase (match-string 2 color)))
            (b (upcase (match-string 3 color))))
        (concat "#" r r g g b b)))
     ((and (fboundp 'color-values)
           (ignore-errors (color-values color)))
      (let ((rgb (ignore-errors (color-values color))))
        (if (and (consp rgb) (>= (length rgb) 3))
            (format "#%02X%02X%02X"
                    (ash (nth 0 rgb) -8)
                    (ash (nth 1 rgb) -8)
                    (ash (nth 2 rgb) -8))
          fallback)))
     (t fallback))))

(defun org-writenotes--emacs-is-dark-p ()
  "Return t if the current Emacs frame has a dark background."
  (let ((bg-hex (org-writenotes--normalize-hex-color
                 (face-background 'default nil t) nil)))
    (if bg-hex
        (org-writenotes--hex-color-dark-p bg-hex)
      (eq (frame-parameter nil 'background-mode) 'dark))))

(defun org-writenotes--replace-pagerect-fill (svg-xml new-fill)
  "Replace the `fill' attribute on `.pagebg', `.pagerect', `.write-background', and `#write-doc-background' `<rect>' tags in SVG-XML with NEW-FILL."
  (save-match-data
    (replace-regexp-in-string
     "<rect\\b[^>]*\\(?:\\bclass=\"[^\"]*\\(?:pagebg\\|pagerect\\|write-background\\)[^\"]*\"\\|\\bid=\"write-doc-background\"\\)[^>]*>"
     (lambda (rect-tag)
       (save-match-data
         (if (string-match "\\bfill=\"[^\"]*\"" rect-tag)
             (replace-regexp-in-string "\\bfill=\"[^\"]*\"" (format "fill=\"%s\"" new-fill) rect-tag t t)
           (replace-regexp-in-string "<rect\\b" (format "<rect fill=\"%s\"" new-fill) rect-tag t t))))
     svg-xml t t)))

(defun org-writenotes--current-theme-payload ()
  "Return a plist describing the active Emacs color theme."
  (let* ((dark-p (org-writenotes--emacs-is-dark-p))
         (raw-bg (org-writenotes--normalize-hex-color
                  (face-background 'default nil t)
                  (if dark-p "#1E293B" "#FFFDF8")))
         (bg (if dark-p
                 (if (org-writenotes--hex-color-dark-p raw-bg) raw-bg "#1E293B")
               (if (org-writenotes--hex-color-dark-p raw-bg) "#FFFDF8" raw-bg)))
         (raw-fg (org-writenotes--normalize-hex-color
                  (face-foreground 'default nil t)
                  (if dark-p "#F8FAFC" "#1E293B")))
         (fg (if dark-p
                 (if (org-writenotes--hex-color-dark-p raw-fg) "#F8FAFC" raw-fg)
               (if (org-writenotes--hex-color-dark-p raw-fg) raw-fg "#1E293B")))
         (accent (org-writenotes--normalize-hex-color
                  (or (face-foreground 'font-lock-keyword-face nil t)
                      (face-foreground 'font-lock-function-name-face nil t))
                  "#38BDF8")))
    `(:isDark ,(if dark-p t :false)
      :bgColor ,bg
      :fgColor ,fg
      :accentColor ,accent)))

(defun org-writenotes--adapt-svg-xml-for-theme (svg-xml)
  "Adapt SVG-XML string to match Emacs's active light/dark theme according to `org-writenotes-inline-theme'."
  (save-match-data
    (let ((clean-xml (if (and (stringp svg-xml) (not (multibyte-string-p svg-xml)))
                         (decode-coding-string svg-xml 'utf-8)
                       svg-xml)))
      (if (or (not (stringp clean-xml))
              (eq org-writenotes-inline-theme 'paper))
          clean-xml
        (let* ((dark-p (org-writenotes--emacs-is-dark-p))
               (raw-bg (org-writenotes--normalize-hex-color
                        (face-background 'default nil t)
                        (if dark-p "#1E293B" "#FFFDF8")))
               (frame-bg (if dark-p
                             (if (org-writenotes--hex-color-dark-p raw-bg) raw-bg "#1E293B")
                           (if (org-writenotes--hex-color-dark-p raw-bg) "#FFFDF8" raw-bg)))
               (raw-fg (org-writenotes--normalize-hex-color
                        (face-foreground 'default nil t)
                        (if dark-p "#F8FAFC" "#1E293B")))
               (frame-fg (if dark-p
                             (if (org-writenotes--hex-color-dark-p raw-fg) "#F8FAFC" raw-fg)
                           (if (org-writenotes--hex-color-dark-p raw-fg) raw-fg "#1E293B")))
               (paper-color (if (string-match "papercolor=\"\\(#[0-9A-Fa-f]+\\)\"" clean-xml)
                                (org-writenotes--normalize-hex-color (match-string 1 clean-xml) "#FFFDF8")
                              "#FFFDF8"))
               (page-is-dark (org-writenotes--hex-color-dark-p paper-color))
               (adapted clean-xml))
          (cond
           ((eq org-writenotes-inline-theme 'transparent)
            ;; 1. Make .pagebg and .pagerect fill="none" without duplicate attributes
            (setq adapted (org-writenotes--replace-pagerect-fill adapted "none"))
            ;; 2. Adapt strokes so they remain visible against the active Emacs background
            (if dark-p
                (unless page-is-dark
                  (setq adapted (replace-regexp-in-string
                                 "fill=\"\\(?:#\\(?:1[eE]293[bB]\\|000000\\|000\\)\\|black\\)\""
                                 (format "fill=\"%s\"" frame-fg) adapted t t))
                  (setq adapted (replace-regexp-in-string
                                 "stroke=\"\\(?:#\\(?:1[eE]293[bB]\\|000000\\|000\\)\\|black\\)\""
                                 (format "stroke=\"%s\"" frame-fg) adapted t t))
                  (setq adapted (replace-regexp-in-string
                                 "stroke=\"#\\(?:4[aA]90[eE]2\\|0000[fF][fF]\\)\""
                                 "stroke=\"#334155\"" adapted t t)))
              (setq adapted (replace-regexp-in-string
                             "fill=\"\\(?:#\\(?:[fF]\\{6\\}\\|[fF]\\{3\\}\\|[fF]8[fF][aA][fF][cC]\\|[cC][dD][dD]6[fF]4\\)\\|white\\)\""
                             (format "fill=\"%s\"" frame-fg) adapted t t))
              (setq adapted (replace-regexp-in-string
                             "stroke=\"\\(?:#\\(?:[fF]\\{6\\}\\|[fF]\\{3\\}\\|[fF]8[fF][aA][fF][cC]\\|[cC][dD][dD]6[fF]4\\)\\|white\\)\""
                             (format "stroke=\"%s\"" frame-fg) adapted t t))))

           ((and (eq org-writenotes-inline-theme 'auto) dark-p)
            ;; 1. First adapt standard black/dark strokes to light frame foreground
            ;;    (before changing .pagerect so dark frame-bg on .pagerect is never re-matched)
            (setq adapted (replace-regexp-in-string
                           "fill=\"\\(?:#\\(?:1[eE]293[bB]\\|000000\\|000\\)\\|black\\)\""
                           (format "fill=\"%s\"" frame-fg) adapted t t))
            (setq adapted (replace-regexp-in-string
                           "stroke=\"\\(?:#\\(?:1[eE]293[bB]\\|000000\\|000\\)\\|black\\)\""
                           (format "stroke=\"%s\"" frame-fg) adapted t t))
            ;; 2. Adapt any light page background rect (.pagebg / .pagerect) to Emacs frame-bg
            (unless page-is-dark
              (setq adapted (org-writenotes--replace-pagerect-fill adapted frame-bg))
              (setq adapted (replace-regexp-in-string
                             "papercolor=\"#[0-9A-Fa-f]+\""
                             (format "papercolor=\"%s\"" frame-bg) adapted t t))
              ;; 3. Soften ruling lines in dark mode
              (setq adapted (replace-regexp-in-string
                             "stroke=\"#\\(?:4[aA]90[eE]2\\|0000[fF][fF]\\)\""
                             "stroke=\"#334155\"" adapted t t))
              (setq adapted (replace-regexp-in-string
                             "rulecolor=\"#4[aA]90[eE]2[0-9A-Fa-f]*\""
                             "rulecolor=\"#33415544\"" adapted t t))))

           ((and (eq org-writenotes-inline-theme 'auto) (not dark-p))
            ;; In light mode, ensure white/light-foreground strokes remain visible on light paper
            (if page-is-dark
                (progn
                  (setq adapted (replace-regexp-in-string
                                 "fill=\"\\(?:#\\(?:[fF]\\{6\\}\\|[fF]\\{3\\}\\|[fF]8[fF][aA][fF][cC]\\|[cC][dD][dD]6[fF]4\\)\\|white\\)\""
                                 (format "fill=\"%s\"" frame-fg) adapted t t))
                  (setq adapted (replace-regexp-in-string
                                 "stroke=\"\\(?:#\\(?:[fF]\\{6\\}\\|[fF]\\{3\\}\\|[fF]8[fF][aA][fF][cC]\\|[cC][dD][dD]6[fF]4\\)\\|white\\)\""
                                 (format "stroke=\"%s\"" frame-fg) adapted t t))
                  (setq adapted (org-writenotes--replace-pagerect-fill adapted frame-bg))
                  (setq adapted (replace-regexp-in-string
                                 "papercolor=\"#[0-9A-Fa-f]+\""
                                 (format "papercolor=\"%s\"" frame-bg) adapted t t)))
              (setq adapted (replace-regexp-in-string
                             "fill=\"\\(?:#\\(?:[fF]\\{6\\}\\|[fF]\\{3\\}\\|[fF]8[fF][aA][fF][cC]\\|[cC][dD][dD]6[fF]4\\)\\|white\\)\""
                             (format "fill=\"%s\"" frame-fg) adapted t t))
              (setq adapted (replace-regexp-in-string
                             "stroke=\"\\(?:#\\(?:[fF]\\{6\\}\\|[fF]\\{3\\}\\|[fF]8[fF][aA][fF][cC]\\|[cC][dD][dD]6[fF]4\\)\\|white\\)\""
                             (format "stroke=\"%s\"" frame-fg) adapted t t)))))
          adapted)))))

(defun org-writenotes-notify-theme-changed (&rest _)
  "Broadcast an `emacs.themeChanged' notification to connected tablets."
  (when (fboundp 'frame-set-background-mode)
    (ignore-errors (frame-set-background-mode (selected-frame))))
  (let ((current-dark (org-writenotes--emacs-is-dark-p)))
    (setq org-writenotes--last-theme-is-dark current-dark)
    (org-writenotes--refresh-inline-image)
    (when org-writenotes--clients
      (org-writenotes--broadcast-notification
       "emacs.themeChanged"
       (org-writenotes--current-theme-payload)))))

(defun org-writenotes--extract-svg-meta (svg-xml)
  "Extract width, height, xRuling, yRuling from SVG-XML string.
Returns `(WIDTH HEIGHT XRULING YRULING PAPERCOLOR RULECOLOR RULINGSTYLE)'."
  (save-match-data
    (let ((w org-writenotes-default-canvas-width)
          (h org-writenotes-default-canvas-height)
          (xr 40)
          (yr 40)
          (paper nil)
          (rule nil)
          (style nil))
      (when (stringp svg-xml)
        ;; Match <svg ... width="1200px" height="600px" ...> or viewBox
        (if (string-match "<svg[^>]+width=\"\\([0-9]+\\)\\(?:px\\)?\"[^>]+height=\"\\([0-9]+\\)\\(?:px\\)?\"" svg-xml)
            (setq w (string-to-number (match-string 1 svg-xml))
                  h (string-to-number (match-string 2 svg-xml)))
          (when (string-match "viewBox=\"[0-9.]+\\s-+[0-9.]+\\s-+\\([0-9.]+\\)\\s-+\\([0-9.]+\\)\"" svg-xml)
            (setq w (truncate (string-to-number (match-string 1 svg-xml)))
                  h (truncate (string-to-number (match-string 2 svg-xml))))))
        ;; Match write-content attributes
        (when (string-match "xruling=\"\\([0-9]+\\)\"" svg-xml)
          (setq xr (string-to-number (match-string 1 svg-xml))))
        (when (string-match "yruling=\"\\([0-9]+\\)\"" svg-xml)
          (setq yr (string-to-number (match-string 1 svg-xml))))
        (when (string-match "papercolor=\"\\(#[0-9A-Fa-f]+\\)\"" svg-xml)
          (setq paper (match-string 1 svg-xml)))
        (when (string-match "rulecolor=\"\\(#[0-9A-Fa-f]+\\)\"" svg-xml)
          (setq rule (match-string 1 svg-xml)))
        (when (string-match "rulingstyle=\"\\([a-zA-Z0-9_]+\\)\"" svg-xml)
          (setq style (match-string 1 svg-xml))))
      (list w h xr yr paper rule style))))

(defcustom org-writenotes-adb-watchdog-interval 10
  "Interval in seconds to asynchronously maintain `adb reverse' when no client is connected.
Set to nil to disable periodic ADB tunnel maintenance."
  :type '(choice integer (const nil))
  :group 'org-writenotes)

(defvar org-writenotes--pushed-history nil
  "Recent history of pushed Org node summary plists (most recent first).")

(defvar org-writenotes--adb-watchdog-timer nil
  "Background timer that keeps `adb reverse' active while waiting for tablet connection.")

(defvar org-writenotes--adb-proc nil
  "In-flight async process for `adb reverse'.")

;;; ---------------------------------------------------------------------------
;;; Native `.svgz' Inline Image Rendering in Emacs
;;; ---------------------------------------------------------------------------

(defun org-writenotes--gzip-bytes-p (bytes)
  "Return non-nil if unibyte string BYTES begins with the gzip magic header (0x1f 0x8b)."
  (and (stringp bytes)
       (>= (length bytes) 2)
       (= (aref bytes 0) #x1f)
       (= (aref bytes 1) #x8b)))

(defun org-writenotes--write-raw-bytes (filepath raw-bytes)
  "Write unibyte RAW-BYTES directly to FILEPATH, bypassing `jka-compr' auto-compression."
  (let ((file-name-handler-alist nil)
        (coding-system-for-write 'no-conversion)
        (write-region-inhibit-fsync t))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert (string-as-unibyte raw-bytes))
      (write-region (point-min) (point-max) filepath nil 'silent))))

(defun org-writenotes--read-raw-bytes (filepath)
  "Read raw unibyte bytes directly from FILEPATH, bypassing `jka-compr'."
  (let ((file-name-handler-alist nil)
        (coding-system-for-read 'no-conversion))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally filepath)
      (buffer-string))))

(defun org-writenotes--gunzip-once (bytes)
  "Decompress one gzip layer from unibyte string BYTES, returning unibyte string."
  (if (not (org-writenotes--gzip-bytes-p bytes))
      bytes
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert bytes)
      (let ((decompressed nil))
        (when (and (fboundp 'zlib-available-p) (zlib-available-p))
          (setq decompressed (ignore-errors (zlib-decompress-region (point-min) (point-max)))))
        (when (or (not decompressed)
                  (org-writenotes--gzip-bytes-p (buffer-string)))
          (erase-buffer)
          (insert bytes)
          (when (executable-find "gzip")
            (call-process-region (point-min) (point-max) "gzip" t t nil "-c" "-d")))
        (buffer-string)))))

(defun org-writenotes--read-and-repair-svgz (filepath)
  "Read FILEPATH and return `(SVGZ-BYTES . SVG-XML-BYTES)'.
If FILEPATH was accidentally double-gzipped by `jka-compr', automatically
repairs the file on disk to single-gzipped `.svgz'."
  (save-match-data
    (let* ((raw (org-writenotes--read-raw-bytes filepath))
           (svgz-bytes raw)
           (xml-bytes raw))
      (when (org-writenotes--gzip-bytes-p raw)
        (let ((step1 (org-writenotes--gunzip-once raw)))
          (if (org-writenotes--gzip-bytes-p step1)
              ;; File on disk was double-gzipped; repair it on disk to 1x gzip
              (progn
                (setq svgz-bytes step1)
                (ignore-errors (org-writenotes--write-raw-bytes filepath step1))
                (setq xml-bytes (org-writenotes--gunzip-once step1))
                (when (org-writenotes--gzip-bytes-p xml-bytes)
                  (setq xml-bytes (org-writenotes--gunzip-once xml-bytes))))
            (setq xml-bytes step1))))
      (cons svgz-bytes
            (if (and (stringp xml-bytes) (not (multibyte-string-p xml-bytes)))
                (decode-coding-string xml-bytes 'utf-8)
              xml-bytes)))))

(defun org-writenotes--create-image-svgz-advice (orig-fun file-or-data &optional type data-p &rest props)
  "Render `.svgz' files through `create-image' as native `svg' images.
ORIG-FUN is the original function and FILE-OR-DATA, TYPE, DATA-P and
PROPS are the `create-image' arguments.  Colors adapt to the theme and
`org-writenotes-inline-max-width' scaling applies if configured."
  (if (and (not data-p)
           (stringp file-or-data)
           (save-match-data (string-match-p "\\.svgz\\'" (downcase file-or-data)))
           (file-exists-p file-or-data))
      (let* ((abs-file (expand-file-name file-or-data))
             (cached-live (and org-writenotes-live-stroke-preview
                               (gethash abs-file org-writenotes--live-svg-cache)))
             (cached-mtime (and (not cached-live)
                                (fboundp 'org-writenotes--cached-svg-for-file)
                                (ignore-errors (org-writenotes--cached-svg-for-file abs-file))))
             (pair (unless (or cached-live cached-mtime)
                     (ignore-errors (org-writenotes--read-and-repair-svgz abs-file))))
             (svg-xml (or cached-live cached-mtime (cdr pair)))
             (final-props
              (if (and org-writenotes-inline-max-width
                       (not (plist-member props :width))
                       (not (plist-member props :max-width)))
                  (append props (list :max-width org-writenotes-inline-max-width))
                props)))
        (when (and (not cached-live)
                   (not cached-mtime)
                   (stringp svg-xml)
                   (> (length svg-xml) 0)
                   (fboundp 'org-writenotes--put-cached-svg-for-file))
          (ignore-errors (org-writenotes--put-cached-svg-for-file abs-file svg-xml)))
        (if (and (stringp svg-xml)
                 (> (length svg-xml) 0)
                 (save-match-data (string-match-p "<svg" svg-xml)))
            (let ((adapted-xml (or (ignore-errors (org-writenotes--adapt-svg-xml-for-theme svg-xml))
                                   svg-xml)))
              (apply orig-fun adapted-xml 'svg t final-props))
          (apply orig-fun file-or-data 'svg nil final-props)))
    (apply orig-fun file-or-data type data-p props)))

(defun org-writenotes--org-export-unpack-svgz (backend)
  "Unpack `.svgz' links to inline `<svg>' or `.svg' files during Org export for BACKEND."
  (when (memq backend '(html latex md))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "\\[\\[\\(?:file:\\|attachment:\\)\\([^]\n]+\\.svgz\\)\\(?:\\]\\[[^]\n]*\\)?\\]\\]" nil t)
        (let* ((rel-path (match-string 1))
               (abs-path (expand-file-name rel-path default-directory)))
          (when (file-exists-p abs-path)
            (let* ((pair (ignore-errors (org-writenotes--read-and-repair-svgz abs-path)))
                   (svg-xml (cdr pair)))
              (when (and (stringp svg-xml) (string-match-p "<svg" svg-xml))
                (if (eq backend 'html)
                    (replace-match (format "#+BEGIN_EXPORT html\n%s\n#+END_EXPORT" svg-xml) t t)
                  (let ((unpacked-svg (concat (file-name-sans-extension abs-path) ".svg")))
                    (org-writenotes--write-raw-bytes unpacked-svg svg-xml)
                    (replace-match (format "[[file:%s]]" (file-relative-name unpacked-svg default-directory)) t t)))))))))))

(defun org-writenotes--register-theme-hooks ()
  "Register theme-change hooks and advices so inline `.svgz' previews stay in sync."
  (when (boundp 'enable-theme-functions)
    (add-hook 'enable-theme-functions #'org-writenotes-notify-theme-changed))
  (when (boundp 'disable-theme-functions)
    (add-hook 'disable-theme-functions #'org-writenotes-notify-theme-changed))
  (when (boundp 'after-load-theme-hook)
    (add-hook 'after-load-theme-hook #'org-writenotes-notify-theme-changed))
  (advice-add 'load-theme :after #'org-writenotes-notify-theme-changed)
  (advice-add 'disable-theme :after #'org-writenotes-notify-theme-changed))

;;;###autoload
(defun org-writenotes-enable-svgz-inline-images ()
  "Register `.svgz' in Emacs image mode and Org inline image regexps."
  (interactive)
  ;; Register .svgz with Emacs's librsvg image loader and magic header table
  (when (boundp 'image-type-file-name-regexps)
    (add-to-list 'image-type-file-name-regexps '("\\.svgz\\'" . svg)))
  (when (boundp 'image-type-header-regexps)
    (add-to-list 'image-type-header-regexps '("\\`\x1f\x8b" . svg)))
  (add-to-list 'image-file-name-extensions "svgz")
  (when (and (boundp 'org-image-file-name-regexp)
             (fboundp 'image-file-name-regexp))
    (setq org-image-file-name-regexp (image-file-name-regexp)))
  (advice-add 'create-image :around #'org-writenotes--create-image-svgz-advice)
  (add-hook 'org-open-at-point-functions #'org-writenotes--open-at-point-h)
  (when (boundp 'org-export-before-parsing-functions)
    (add-hook 'org-export-before-parsing-functions #'org-writenotes--org-export-unpack-svgz))
  (org-writenotes--register-theme-hooks)
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (derived-mode-p 'org-mode) (display-graphic-p))
        (ignore-errors (org-display-inline-images t t)))))
  (when (called-interactively-p 'interactive)
    (message "[Org-WriteNotes] Enabled inline .svgz rendering.")))

(defun org-writenotes--refresh-inline-image (&optional saved-path)
  "Clear Emacs image cache and refresh inline images in visible Org buffers."
  (when (fboundp 'clear-image-cache)
    (ignore-errors (clear-image-cache)))
  (when (boundp 'org-writenotes--mtime-image-cache)
    (if saved-path
        (remhash (expand-file-name saved-path) org-writenotes--mtime-image-cache)
      (clrhash org-writenotes--mtime-image-cache)))
  (when (and saved-path (boundp 'org-writenotes--live-svg-cache))
    (remhash (expand-file-name saved-path) org-writenotes--live-svg-cache))
  (dolist (buf (buffer-list))
    (when (get-buffer-window buf 'visible)
      (with-current-buffer buf
        (when (derived-mode-p 'org-mode)
          (ignore-errors (org-display-inline-images t t))))))
  (redisplay))

(defun org-writenotes--resolve-image-dir (org-file)
  "Return the absolute directory path for storing `.svgz' files for ORG-FILE."
  (let* ((base-dir (if org-file
                       (file-name-directory (expand-file-name org-file))
                     default-directory))
         (target-dir (expand-file-name org-writenotes-image-dir base-dir)))
    (unless (file-directory-p target-dir)
      (make-directory target-dir t))
    target-dir))

(defun org-writenotes--format-file-link (org-file svgz-filename)
  "Format an Org `[[file:...]]' link for SVGZ-FILENAME relative to ORG-FILE."
  (let* ((base-file (or org-file (buffer-file-name) default-directory))
         (base-dir (file-name-directory (expand-file-name base-file)))
         (abs-img (expand-file-name svgz-filename (org-writenotes--resolve-image-dir base-file)))
         (rel-path (file-relative-name abs-img base-dir)))
    (unless (or (string-prefix-p "./" rel-path)
                (string-prefix-p "../" rel-path)
                (file-name-absolute-p rel-path))
      (setq rel-path (concat "./" rel-path)))
    (format "[[file:%s]]" rel-path)))

(defun org-writenotes--slugify (title)
  "Convert Org heading TITLE into a clean filename slug."
  (let* ((clean (downcase (replace-regexp-in-string "[^a-zA-Z0-9]+" "-" (or title "note"))))
         (trimmed (replace-regexp-in-string "\\`-+\\|-+\\'" "" clean)))
    (if (string-empty-p trimmed)
        "note"
      (substring trimmed 0 (min 28 (length trimmed))))))

(defun org-writenotes--create-blank-svgz (filepath width height &optional x-ruling y-ruling)
  "Write a blank Stylus Labs Write SVG/SVGZ template to FILEPATH.
WIDTH and HEIGHT set the canvas size; X-RULING and Y-RULING the grid."
  (let* ((w (or width org-writenotes-default-canvas-width))
         (h (or height org-writenotes-default-canvas-height))
         (xr (or x-ruling 40))
         (yr (or y-ruling 40))
         (svg-xml
          (format
           (concat
            "<svg id=\"write-document\" xmlns=\"http://www.w3.org/2000/svg\" "
            "xmlns:xlink=\"http://www.w3.org/1999/xlink\" "
            "width=\"%dpx\" height=\"%dpx\" viewBox=\"0 0 %d %d\">\n"
            "  <svg class=\"write-page\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\">\n"
            "    <g class=\"write-content write-v3\" xruling=\"%d\" yruling=\"%d\" marginLeft=\"0\" papercolor=\"#FFFDF8\" rulecolor=\"#4A90E233\">\n"
            "      <g class=\"ruleline\">\n"
            "        <rect class=\"pagebg\" x=\"0\" y=\"0\" width=\"%d\" height=\"%d\" fill=\"#FFFDF8\"/>\n"
            "      </g>\n"
            "    </g>\n"
            "  </svg>\n"
            "</svg>\n")
           w h w h w h w h xr yr w h))
         (raw-bytes
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert (encode-coding-string svg-xml 'utf-8))
            (when (executable-find "gzip")
              (call-process-region (point-min) (point-max) "gzip" t t nil "-c" "-9"))
            (buffer-string))))
    (org-writenotes--write-raw-bytes filepath raw-bytes)
    filepath))

;;; ---------------------------------------------------------------------------
;;; Org Subtree AST Serializer & Block-Interleaved Parser
;;; ---------------------------------------------------------------------------

(defun org-writenotes--node-id-at-point (&optional ensure-id)
  "Construct a stable identifier for the Org heading at point.
When ENSURE-ID and `org-writenotes-auto-assign-id' are non-nil, automatically
generates an `:ID:' property if one is not already present."
  (save-excursion
    (org-back-to-heading t)
    (when (and ensure-id org-writenotes-auto-assign-id (not (org-entry-get (point) "ID")))
      (when (fboundp 'org-id-get-create)
        (ignore-errors (org-id-get-create))))
    (let ((file (buffer-file-name))
          (id (org-entry-get (point) "ID"))
          (line (line-number-at-pos (point))))
      (if id
          (format "file:%s::id:%s" file id)
        (format "file:%s::line:%d" file line)))))

(defun org-writenotes--locate-node (node-id)
  "Find the buffer and point for NODE-ID.  Return `(buffer . marker)' or nil."
  (let ((target-id (if (and node-id
                            (string-match-p "\\`file:.*::\\(id:\\|line:\\)" node-id))
                       node-id
                     org-writenotes--active-node-id)))
    (when (and target-id (string-match "\\`file:\\(.*\\)::\\(id:\\|line:\\)\\(.*\\)\\'" target-id))
      (let ((file (match-string 1 target-id))
            (kind (match-string 2 target-id))
            (val (match-string 3 target-id)))
        (when (and file (file-exists-p file))
          (let ((buf (find-file-noselect file)))
            (with-current-buffer buf
              (widen)
              (goto-char (point-min))
              (cond
               ((string= kind "id:")
                (let ((pos (org-find-entry-with-id val)))
                  (when pos
                    (goto-char pos)
                    (cons buf (point-marker)))))
               ((string= kind "line:")
                (goto-char (point-min))
                (forward-line (max 0 (1- (string-to-number val))))
                (when (or (org-at-heading-p)
                          (ignore-errors (org-back-to-heading t))
                          (outline-next-heading))
                  (cons buf (point-marker))))))))))))

(defun org-writenotes--count-sketches-in-region (beg end)
  "Count `.svgz' / `.svg' links between BEG and END."
  (if (or (null beg) (null end))
      0
    (let ((b (max (point-min) (min (point-max) beg)))
          (e (max (point-min) (min (point-max) end))))
      (if (>= b e)
          0
        (save-excursion
          (goto-char b)
          (let ((count 0))
            (while (and (< (point) e)
                        (re-search-forward "\\[\\[\\(?:file:\\|attachment:\\)?\\([^]\n]+\\.svgz?\\)\\(?:\\]\\[[^]\n]*\\)?\\]\\]" e t))
              (cl-incf count))
            count))))))

(defun org-writenotes--extract-direct-subheadings (beg sub-end parent-level)
  "Collect direct child subheadings (level = PARENT-LEVEL + 1) between BEG and SUB-END."
  (save-excursion
    (goto-char (max (point-min) (min (point-max) (or beg (point)))))
    (forward-line 1)
    (let ((children nil)
          (target-level (1+ (or parent-level 1)))
          (lim (max (point) (min (point-max) (or sub-end (point-max))))))
      (while (and (< (point) lim)
                  (re-search-forward org-heading-regexp lim t))
        (save-excursion
          (goto-char (match-beginning 0))
          (let* ((comp (org-heading-components))
                 (lvl (nth 0 comp)))
            (when (and lvl (= lvl target-level))
              (let* ((c-beg (point))
                     (c-end (save-excursion (org-end-of-subtree t t) (point)))
                     (c-body-end (org-writenotes--body-end-pos c-beg c-end))
                     (todo (nth 2 comp))
                     (prio (nth 3 comp))
                     (raw-title (or (nth 4 comp) "Untitled"))
                     (clean-title (replace-regexp-in-string
                                   "\\s-*\\[[0-9]+/[0-9]+\\]\\s-*\\|\\s-*\\[[0-9]+%\\]\\s-*"
                                   "" raw-title))
                     (prog (when (string-match "\\[\\([0-9]+/[0-9]+\\|[0-9]+%\\)\\]" raw-title)
                             (match-string 1 raw-title)))
                     (nid (org-writenotes--node-id-at-point))
                     (sketches (org-writenotes--count-sketches-in-region c-beg c-body-end)))
                (push `(:nodeId ,nid
                        :level ,lvl
                        :todoKeyword ,(or todo :null)
                        :priority ,(cond ((characterp prio) (char-to-string prio))
                                         ((and (stringp prio) (not (string-empty-p prio))) prio)
                                         (t :null))
                        :title ,clean-title
                        :checkboxProgress ,(or prog :null)
                        :sketchCount ,sketches)
                      children))))))
      (vconcat (nreverse children)))))

(defun org-writenotes--node-clocked-in-p (beg end)
  "Return non-nil if `org-clock-marker' is currently active inside BEG..END."
  (and (boundp 'org-clock-marker)
       (markerp org-clock-marker)
       (eq (marker-buffer org-clock-marker) (current-buffer))
       (>= (marker-position org-clock-marker) beg)
       (< (marker-position org-clock-marker) end)))

(defun org-writenotes--parse-subtree-at-point (&optional read-only)
  "Serialize the Org subtree at point into a hybrid block-interleaved plist.
When READ-ONLY is nil, ensures a stable `:ID:' is assigned if `org-writenotes-auto-assign-id' is non-nil."
  (save-restriction
    (widen)
    (save-excursion
      (org-back-to-heading t)
      (let* ((node-id (org-writenotes--node-id-at-point (not read-only)))
             (beg (point))
             (end (save-excursion (org-end-of-subtree t t) (point)))
             (body-end (org-writenotes--body-end-pos beg end))
             (file (or (buffer-file-name) default-directory))
             (heading-components (org-heading-components))
             (level (or (nth 0 heading-components) 1))
             (todo (nth 2 heading-components))
             (prio (nth 3 heading-components))
             (raw-title (or (nth 4 heading-components) ""))
             (title (replace-regexp-in-string "\\s-*\\[[0-9]+/[0-9]+\\]\\s-*\\|\\s-*\\[[0-9]+%\\]\\s-*" "" raw-title))
             (tags (org-get-tags nil t))
             (sched (org-entry-get beg "SCHEDULED"))
             (deadl (org-entry-get beg "DEADLINE"))
             (breadcrumbs (ignore-errors (org-get-outline-path t)))
             (parent-node-id (save-excursion
                               (when (and (> level 1) (ignore-errors (org-up-heading-safe)))
                                 (org-writenotes--node-id-at-point))))
             (clocked-in (org-writenotes--node-clocked-in-p beg end))
             (clock-mins (or (and clocked-in
                                  (fboundp 'org-clock-get-clocked-time)
                                  (ignore-errors (org-clock-get-clocked-time)))
                             (ignore-errors (org-clock-sum-current-item))
                             0))
             (raw-props (org-entry-properties beg 'standard))
             (props (let ((ht (make-hash-table :test 'equal)))
                      (dolist (pair raw-props)
                        (when (consp pair)
                          (puthash (format "%s" (car pair))
                                   (format "%s" (or (cdr pair) ""))
                                   ht)))
                      ht))
             (safe-end (min (point-max) (max beg end)))
             (subtree-text (buffer-substring-no-properties beg safe-end))
             (etag (format "tick-%d-sha1-%s"
                           (buffer-chars-modified-tick)
                           (substring (sha1 subtree-text) 0 10)))
             (blocks (org-writenotes--extract-blocks beg body-end file))
             (subheadings (org-writenotes--extract-direct-subheadings beg end level))
             (check-total 0)
             (check-done 0))
        ;; Calculate overall checklist progress across blocks
        (dolist (blk blocks)
          (when (string= (plist-get blk :type) "checklist")
            (cl-loop for item across (plist-get blk :items) do
                     (cl-incf check-total)
                     (when (string= (plist-get item :state) "checked")
                       (cl-incf check-done)))))
        (let ((snapshot
               `(:nodeId ,node-id
                 :etag ,etag
                 :filePath ,file
                 :header (:level ,level
                          :todoKeyword ,(or todo :null)
                          :todoKeywordsAll ,(vconcat (or org-todo-keywords-1 '("TODO" "DONE")))
                          :priority ,(cond ((characterp prio) (char-to-string prio))
                                           ((and (stringp prio) (not (string-empty-p prio))) prio)
                                           (t :null))
                          :title ,title
                          :tags ,(vconcat tags)
                          :scheduled ,(or sched :null)
                          :deadline ,(or deadl :null)
                          :checkboxProgress ,(if (> check-total 0)
                                                 (format "%d/%d" check-done check-total)
                                               :null)
                          :breadcrumbs ,(vconcat (or breadcrumbs (list title)))
                          :parentNodeId ,(or parent-node-id :null)
                          :clockedIn ,(if clocked-in t :false)
                          :clockedMinutes ,clock-mins
                          :properties ,props)
                 :blocks ,(vconcat blocks)
                 :subheadings ,subheadings)))
          (setq org-writenotes--last-active-etag etag)
          (org-writenotes--record-pushed-node snapshot)
          snapshot)))))

(defun org-writenotes--goto-body-start (beg end)
  "Move point to the first body line after heading at BEG and any planning/drawers before END."
  (goto-char (max (point-min) (min (point-max) (or beg (point)))))
  (let ((lim (max (point) (min (point-max) (or end (point-max))))))
    (if (fboundp 'org-end-of-meta-data)
        (progn
          (org-end-of-meta-data t)
          (when (> (point) lim)
            (goto-char lim)))
      ;; Fallback: manual scan over planning and drawers
      (forward-line 1)
      (while (and (< (point) lim)
                  (or (looking-at-p "^[ \t]*$")
                      (looking-at-p "^[ \t]*\\(SCHEDULED:\\|DEADLINE:\\|CLOSED:\\)")
                      (looking-at-p "^[ \t]*:[A-Za-z0-9_@#$-]+:[ \t]*$")))
        (if (looking-at "^[ \t]*:[A-Za-z0-9_@#$-]+:[ \t]*$")
            (if (re-search-forward "^[ \t]*:END:[ \t]*$" lim 'move)
                (forward-line 1)
              (goto-char lim))
          (forward-line 1)))))
  (point))

(defun org-writenotes--body-end-pos (beg sub-end)
  "Return the buffer position where the node at BEG's direct body ends (before any child heading or at SUB-END)."
  (save-excursion
    (goto-char (max (point-min) (min (point-max) (or beg (point)))))
    (forward-line 1)
    (let ((lim (max (point) (min (point-max) (or sub-end (point-max))))))
      (if (and (< (point) lim)
               (re-search-forward org-heading-regexp lim t))
          (match-beginning 0)
        lim))))

(defun org-writenotes--parse-table-row-cells (line-str)
  "Parse an Org table row LINE-STR into a vector of trimmed cell strings, or nil if separator row."
  (when (and (string-match "^\\s-*|\\(.*\\)|\\s-*$" line-str)
             (not (string-match-p "^\\s-*|[-+]+|\\s-*$" line-str)))
    (let ((inner (match-string 1 line-str)))
      (vconcat (mapcar #'string-trim (split-string inner "|"))))))

(defun org-writenotes--extract-blocks (beg end org-file)
  "Parse lines between BEG and END into ordered content blocks.
Blocks are checklist, ink_canvas, code_block, table or paragraph.
ORG-FILE is the file used to resolve sketch links."
  (save-excursion
    (let ((lim (max (point-min) (min (point-max) (or end (point-max))))))
      (org-writenotes--goto-body-start beg lim)
      (let ((blocks nil)
          (blk-idx 0)
          (curr-checklist nil)
          (curr-checklist-start nil)
          (curr-checklist-end nil)
          (curr-para nil)
          (curr-para-start nil)
          (curr-para-end nil))
      (cl-labels
          ((flush-checklist ()
             (when curr-checklist
               (cl-incf blk-idx)
               (push `(:blockId ,(format "blk-%d" blk-idx)
                       :type "checklist"
                       :startLine ,curr-checklist-start
                       :endLine ,(or curr-checklist-end curr-checklist-start)
                       :items ,(vconcat (nreverse curr-checklist)))
                     blocks)
               (setq curr-checklist nil
                     curr-checklist-start nil
                     curr-checklist-end nil)))
           (flush-para ()
             (when curr-para
               (let ((txt (string-trim (mapconcat #'identity (nreverse curr-para) "\n"))))
                 (unless (string-empty-p txt)
                   (cl-incf blk-idx)
                   (push `(:blockId ,(format "blk-%d" blk-idx)
                           :type "paragraph"
                           :startLine ,curr-para-start
                           :endLine ,(or curr-para-end curr-para-start)
                           :text ,txt)
                         blocks)))
               (setq curr-para nil
                     curr-para-start nil
                     curr-para-end nil))))
        (while (and (< (point) lim)
                    (not (org-at-heading-p)))
          (let ((line-str (buffer-substring-no-properties
                           (line-beginning-position) (line-end-position)))
                (line-num (line-number-at-pos (point))))
            (cond
             ;; Case 1: Embedded .svgz / .svg Ink Block Link
             ((string-match "\\[\\[\\(?:file:\\|attachment:\\)?\\([^]\n]+\\.svgz?\\)\\(?:\\]\\[[^]\n]*\\)?\\]\\]" line-str)
              (flush-checklist)
              (flush-para)
              (cl-incf blk-idx)
              (let* ((full-link-str (match-string 0 line-str))
                     (rel-target (match-string 1 line-str))
                     (abs-target (expand-file-name rel-target (file-name-directory (expand-file-name org-file))))
                     (abs-resolved (if (file-exists-p abs-target)
                                       abs-target
                                     (let ((in-img-dir (expand-file-name (file-name-nondirectory rel-target)
                                                                         (org-writenotes--resolve-image-dir org-file))))
                                       (if (file-exists-p in-img-dir) in-img-dir abs-target))))
                     (svgz-pair (when (file-exists-p abs-resolved)
                                  (ignore-errors (org-writenotes--read-and-repair-svgz abs-resolved))))
                     (svgz-bytes (car svgz-pair))
                     (svg-xml (cdr svgz-pair))
                     (meta (org-writenotes--extract-svg-meta svg-xml))
                     (w (nth 0 meta))
                     (h (nth 1 meta))
                     (xr (nth 2 meta))
                     (yr (nth 3 meta))
                     (b64 (when svgz-bytes (base64-encode-string svgz-bytes t))))
                (push `(:blockId ,(format "blk-%d" blk-idx)
                        :type "ink_canvas"
                        :startLine ,line-num
                        :endLine ,line-num
                        :fileName ,(file-name-nondirectory abs-resolved)
                        :linkText ,full-link-str
                        :width ,w
                        :height ,h
                        :xRuling ,xr
                        :yRuling ,yr
                        :svgzBase64 ,(or b64 :null))
                      blocks)))

             ;; Case 1.5: Org Source Code Block (#+BEGIN_SRC <lang> ... #+END_SRC)
             ((let ((case-fold-search t))
                (string-match "^\\s-*#\\+BEGIN_SRC\\(?:\\s-+\\([^ \t\n]+\\)\\)?\\(.*\\)$" line-str))
              (flush-checklist)
              (flush-para)
              (let ((lang (or (match-string 1 line-str) "text"))
                    (src-start line-num)
                    (src-end line-num)
                    (code-lines nil)
                    (results-text nil))
                (forward-line 1)
                (while (and (< (point) lim)
                            (not (let ((case-fold-search t))
                                   (looking-at-p "^\\s-*#\\+END_SRC\\b"))))
                  (push (buffer-substring-no-properties (line-beginning-position) (line-end-position))
                        code-lines)
                  (forward-line 1))
                (setq src-end (line-number-at-pos (point)))
                ;; Check if followed by #+RESULTS:
                (save-excursion
                  (forward-line 1)
                  (while (and (< (point) lim) (looking-at-p "^\\s-*$"))
                    (forward-line 1))
                  (let ((case-fold-search t))
                    (when (and (< (point) lim) (looking-at-p "^\\s-*#\\+RESULTS:"))
                      (forward-line 1)
                      (let ((res-lines nil))
                        (while (and (< (point) lim)
                                    (looking-at "^\\s-*\\(?::\\s-?\\(.*\\)\\|#\\+\\(?:BEGIN_EXAMPLE\\|END_EXAMPLE\\)\\)"))
                          (when (match-string 1)
                            (push (match-string 1) res-lines))
                          (forward-line 1))
                        (when res-lines
                          (setq results-text (mapconcat #'identity (nreverse res-lines) "\n")))))))
                (cl-incf blk-idx)
                (push `(:blockId ,(format "blk-%d" blk-idx)
                        :type "code_block"
                        :startLine ,src-start
                        :endLine ,src-end
                        :language ,lang
                        :code ,(mapconcat #'identity (nreverse code-lines) "\n")
                        :results ,(or results-text :null))
                      blocks)))

             ;; Case 1.8: Org Table (| col1 | col2 |)
             ((string-match-p "^\\s-*|.*|\\s-*$" line-str)
              (flush-checklist)
              (flush-para)
              (let ((tbl-start line-num)
                    (tbl-end line-num)
                    (rows nil))
                (while (and (< (point) lim)
                            (looking-at-p "^\\s-*|.*|\\s-*$"))
                  (setq tbl-end (line-number-at-pos (point)))
                  (let* ((row-str (buffer-substring-no-properties (line-beginning-position) (line-end-position)))
                         (cells (org-writenotes--parse-table-row-cells row-str)))
                    (when cells
                      (push cells rows)))
                  (forward-line 1))
                (forward-line -1)
                (when rows
                  (cl-incf blk-idx)
                  (push `(:blockId ,(format "blk-%d" blk-idx)
                          :type "table"
                          :startLine ,tbl-start
                          :endLine ,tbl-end
                          :rows ,(vconcat (nreverse rows)))
                        blocks))))

             ;; Case 2: Org Checklist Item (- [ ] or - [X] or - [-])
             ((string-match "^\\(\\s-*[-+*]\\s-+\\)\\[\\([ Xx-]\\)\\]\\s-+\\(.*\\)$" line-str)
              (flush-para)
              (unless curr-checklist-start
                (setq curr-checklist-start line-num))
              (setq curr-checklist-end line-num)
              (let ((mark (upcase (match-string 2 line-str)))
                    (item-text (match-string 3 line-str))
                    (idx (length curr-checklist)))
                (push `(:index ,idx
                        :line ,line-num
                        :state ,(cond ((string= mark "X") "checked")
                                      ((string= mark "-") "partial")
                                      (t "unchecked"))
                        :text ,item-text)
                      curr-checklist)))

             ;; Case 2.5: Skip folded :WRITENOTES_OCR: drawer so it does not appear as a raw paragraph
             ((string-match-p "^\\s-*:WRITENOTES_OCR:\\s-*$" line-str)
              (flush-checklist)
              (flush-para)
              (when (re-search-forward "^\\s-*:END:\\s-*$" lim 'move)
                (end-of-line)))

             ;; Case 2.6: Skip standalone #+RESULTS: lines already attached to code blocks
             ((let ((case-fold-search t))
                (string-match-p "^\\s-*#\\+RESULTS:" line-str))
              (flush-checklist)
              (flush-para)
              (forward-line 1)
              (while (and (< (point) lim)
                          (looking-at-p "^\\s-*:\\s-"))
                (forward-line 1))
              (forward-line -1))

             ;; Case 3: Blank line separates paragraphs/checklists
             ((string-match-p "^\\s-*$" line-str)
              (flush-checklist)
              (flush-para))

             ;; Case 4: Standard text line
             (t
              (flush-checklist)
              (unless curr-para-start
                (setq curr-para-start line-num))
              (setq curr-para-end line-num)
              (push line-str curr-para))))
          (forward-line 1))
        (flush-checklist)
        (flush-para)
        (nreverse blocks))))))

(defun org-writenotes--record-pushed-node (snapshot)
  "Record SNAPSHOT in `org-writenotes--pushed-history' (most recent first, deduplicated)."
  (let* ((node-id (plist-get snapshot :nodeId))
         (file-path (plist-get snapshot :filePath))
         (hdr (plist-get snapshot :header))
         (blocks (plist-get snapshot :blocks))
         (sketch-count (cl-count-if (lambda (b) (equal (plist-get b :type) "ink_canvas")) blocks))
         (summary `(:nodeId ,node-id
                    :filePath ,file-path
                    :level ,(plist-get hdr :level)
                    :todoKeyword ,(plist-get hdr :todoKeyword)
                    :priority ,(plist-get hdr :priority)
                    :title ,(plist-get hdr :title)
                    :tags ,(plist-get hdr :tags)
                    :scheduled ,(plist-get hdr :scheduled)
                    :deadline ,(plist-get hdr :deadline)
                    :sketchCount ,sketch-count)))
    (setq org-writenotes--pushed-history
          (cons summary
                (cl-remove-if (lambda (item)
                                (equal (plist-get item :nodeId) node-id))
                              org-writenotes--pushed-history)))
    (when (> (length org-writenotes--pushed-history) org-writenotes-history-limit)
      (setq org-writenotes--pushed-history
            (cl-subseq org-writenotes--pushed-history 0 org-writenotes-history-limit)))))

(defun org-writenotes--handle-create-node (params)
  "Create a new Org heading (child, sibling, or quick-capture note) from PARAMS."
  (let* ((parent-id (alist-get 'parentId params))
         (mode (or (alist-get 'mode params) "child")) ; "child", "sibling", or "capture"
         (create-sketch (alist-get 'createSketch params))
         (title (or (alist-get 'title params) "New Note"))
         (todo (alist-get 'todoKeyword params))
         (tags (alist-get 'tags params))
         (loc (when parent-id (org-writenotes--locate-node parent-id)))
         (active-loc (when (and (not loc) org-writenotes--active-node-id)
                       (org-writenotes--locate-node org-writenotes--active-node-id)))
         (capture-buf (when (and (equal mode "capture") org-writenotes-capture-file)
                        (find-file-noselect (expand-file-name org-writenotes-capture-file))))
         (target-buf
          (cond
           (capture-buf capture-buf)
           (loc (car loc))
           ((and active-loc (buffer-live-p (car active-loc))) (car active-loc))
           ((derived-mode-p 'org-mode) (current-buffer))
           (t (cl-find-if (lambda (b)
                            (with-current-buffer b
                              (and (derived-mode-p 'org-mode) (buffer-file-name))))
                          (buffer-list))))))
    (unless (and target-buf (buffer-live-p target-buf))
      (error "No Org buffer available to create node"))
    (with-current-buffer target-buf
      (widen)
      (cond
       ((and loc (equal mode "sibling"))
        (let ((sib-level (save-excursion
                           (goto-char (cdr loc))
                           (org-back-to-heading t)
                           (org-outline-level))))
          (goto-char (cdr loc))
          (org-end-of-subtree t t)
          (unless (bolp) (insert "\n"))
          (insert (make-string sib-level ?*) " ")
          (unless (eolp) (save-excursion (insert "\n")))))
       (loc
        (let ((parent-level (save-excursion
                              (goto-char (cdr loc))
                              (org-back-to-heading t)
                              (org-outline-level))))
          (goto-char (cdr loc))
          (org-end-of-subtree t t)
          (unless (bolp) (insert "\n"))
          (insert (make-string (1+ parent-level) ?*) " ")
          (unless (eolp) (save-excursion (insert "\n")))))
       (t
        (goto-char (point-max))
        (unless (bolp) (insert "\n"))
        (insert "* ")))
      (when (and todo (not (string-empty-p todo)))
        (org-todo todo))
      (org-edit-headline title)
      (when tags
        (org-set-tags (append tags nil)))
      (let ((new-nid (org-writenotes--node-id-at-point t)))
        (save-buffer)
        (if (and create-sketch (not (eq create-sketch :false)))
            (org-writenotes--handle-insert-ink-block `((nodeId . ,new-nid)))
          (let ((snapshot (org-writenotes--parse-subtree-at-point)))
            (setq org-writenotes--active-node-id (plist-get snapshot :nodeId))
            (org-writenotes--broadcast-notification "emacs.focusNode" snapshot)
            snapshot))))))

(defun org-writenotes--node-summary-at-point ()
  "Construct a node summary plist for the heading at point."
  (let* ((beg (point))
         (sub-end (save-excursion (org-end-of-subtree t t) (point)))
         (body-end (org-writenotes--body-end-pos beg sub-end))
         (components (org-heading-components))
         (level (nth 0 components))
         (todo (nth 2 components))
         (prio (nth 3 components))
         (raw-title (or (nth 4 components) "Untitled"))
         (title (replace-regexp-in-string "\\s-*\\[[0-9]+/[0-9]+\\]\\s-*\\|\\s-*\\[[0-9]+%\\]\\s-*" "" raw-title))
         (tags (org-get-tags beg t))
         (sched (org-entry-get beg "SCHEDULED"))
         (deadl (org-entry-get beg "DEADLINE"))
         (nid (org-writenotes--node-id-at-point))
         (sketches (org-writenotes--count-sketches-in-region beg body-end)))
    `(:nodeId ,nid
      :filePath ,(or (buffer-file-name) "")
      :level ,level
      :todoKeyword ,(or todo :null)
      :priority ,(cond ((characterp prio) (char-to-string prio))
                       ((and (stringp prio) (not (string-empty-p prio))) prio)
                       (t :null))
      :title ,title
      :tags ,(vconcat tags)
      :scheduled ,(or sched :null)
      :deadline ,(or deadl :null)
      :sketchCount ,sketches)))

(defun org-writenotes--collect-buffer-outline ()
  "Collect the full outline tree of the active Org buffer."
  (let ((buf (when org-writenotes--active-node-id
               (let ((loc (org-writenotes--locate-node org-writenotes--active-node-id)))
                 (and loc (car loc))))))
    (unless (and buf (buffer-live-p buf))
      (setq buf (cl-find-if (lambda (b) (with-current-buffer b (derived-mode-p 'org-mode)))
                            (buffer-list))))
    (if (not (and buf (buffer-live-p buf)))
        []
      (with-current-buffer buf
        (save-excursion
          (save-restriction
            (widen)
            (goto-char (point-min))
            (let ((nodes nil))
              (while (re-search-forward org-heading-regexp nil t)
                (save-excursion
                  (goto-char (match-beginning 0))
                  (push (org-writenotes--node-summary-at-point) nodes)))
              (vconcat (nreverse nodes)))))))))

(defun org-writenotes--candidate-org-buffers ()
  "Return a list of open `.org' buffers and `org-agenda-files' buffers."
  (let ((bufs (cl-remove-if-not
               (lambda (b)
                 (with-current-buffer b
                   (and (derived-mode-p 'org-mode) (buffer-file-name))))
               (buffer-list))))
    (when (fboundp 'org-agenda-files)
      (dolist (f (ignore-errors (org-agenda-files)))
        (when (and (stringp f) (file-exists-p f))
          (cl-pushnew (find-file-noselect f) bufs))))
    bufs))

(defun org-writenotes--collect-agenda-nodes (&optional query)
  "Collect nodes with active TODO keywords or SCHEDULED/DEADLINE dates.\nOptional QUERY filters the results."
  (let ((results nil)
        (q (and query (not (string-empty-p query)) (downcase query))))
    (dolist (buf (org-writenotes--candidate-org-buffers))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (save-excursion
            (save-restriction
              (widen)
              (goto-char (point-min))
              (while (re-search-forward org-heading-regexp nil t)
                (save-excursion
                  (goto-char (match-beginning 0))
                  (let* ((summary (org-writenotes--node-summary-at-point))
                         (todo (plist-get summary :todoKeyword))
                         (sched (plist-get summary :scheduled))
                         (deadl (plist-get summary :deadline))
                         (title (or (plist-get summary :title) "")))
                    (when (and (or (and (stringp todo) (not (member todo '("DONE" "CANCELLED"))))
                                   (stringp sched)
                                   (stringp deadl))
                               (or (not q)
                                   (string-match-p (regexp-quote q) (downcase title))))
                      (push summary results))))))))))
    (vconcat (nreverse results))))

(defun org-writenotes--collect-search-nodes (query)
  "Search headings, tags, body text, and `:WRITENOTES_OCR:' drawers across Org buffers for QUERY."
  (let ((results nil)
        (q (string-trim (or query ""))))
    (dolist (buf (org-writenotes--candidate-org-buffers))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (save-excursion
            (save-restriction
              (widen)
              (goto-char (point-min))
              (while (re-search-forward org-heading-regexp nil t)
                (save-excursion
                  (goto-char (match-beginning 0))
                  (let* ((beg (point))
                         (sub-end (save-excursion (org-end-of-subtree t t) (point)))
                         (body-end (org-writenotes--body-end-pos beg sub-end))
                         (body-txt (buffer-substring-no-properties beg body-end))
                         (case-fold-search t))
                    (when (or (string-empty-p q)
                              (string-match-p (regexp-quote q) body-txt))
                      (push (org-writenotes--node-summary-at-point) results))))))))))
    (vconcat (nreverse results))))

(defun org-writenotes--collect-node-summaries (&optional filter query)
  "Return a vector of node summaries for FILTER.
FILTER is one of `pushed_history', `buffer_outline', `agenda' or `search'.
QUERY narrows search results."
  (cond
   ((equal filter "buffer_outline")
    (org-writenotes--collect-buffer-outline))
   ((equal filter "agenda")
    (org-writenotes--collect-agenda-nodes query))
   ((equal filter "search")
    (org-writenotes--collect-search-nodes query))
   (t
    (let ((filtered
           (if (or (not query) (string-empty-p query))
               org-writenotes--pushed-history
             (cl-remove-if-not
              (lambda (item)
                (let ((case-fold-search t))
                  (string-match-p (regexp-quote query)
                                  (or (plist-get item :title) ""))))
              org-writenotes--pushed-history))))
      (vconcat filtered)))))

;;; ---------------------------------------------------------------------------
;;; Org Subtree Mutation Handlers (Checklists, Headings, Ink Blocks)
;;; ---------------------------------------------------------------------------

(defun org-writenotes--handle-toggle-checkbox (params)
  "Toggle a checkbox line in the Org node specified by PARAMS."
  (let* ((node-id (alist-get 'nodeId params))
         (line-num (alist-get 'line params))
         (new-state (alist-get 'state params))
         (loc (org-writenotes--locate-node node-id))
         (checkbox-re "^\\(\\s-*[-+*]\\s-+\\[\\)\\([ Xx-]\\)\\(\\]\\s-+.*\\)$"))
    (unless loc
      (error "Node not found: %s" node-id))
    (with-current-buffer (car loc)
      (save-excursion
        (goto-char (cdr loc))
        (org-back-to-heading t)
        (let* ((beg (point))
               (sub-end (save-excursion (org-end-of-subtree t t) (point)))
               (body-end (org-writenotes--body-end-pos beg sub-end)))
          (goto-char (point-min))
          (forward-line (1- line-num))
          ;; If line numbers shifted (e.g. due to drawer insertion), search within node body
          (unless (and (>= (point) beg) (< (point) body-end) (looking-at checkbox-re))
            (let ((best-pos nil)
                  (best-dist most-positive-fixnum))
              (save-excursion
                (goto-char beg)
                (while (re-search-forward checkbox-re body-end t)
                  (let* ((cand-pos (match-beginning 0))
                         (cand-line (line-number-at-pos cand-pos))
                         (dist (abs (- cand-line line-num))))
                    (when (< dist best-dist)
                      (setq best-dist dist
                            best-pos cand-pos)))))
              (when best-pos
                (goto-char best-pos))))
          (when (looking-at checkbox-re)
            (let ((box-char (cond
                             ((equal new-state "checked") "X")
                             ((equal new-state "partial") "-")
                             (t " "))))
              (replace-match box-char t t nil 2))
            (org-update-checkbox-count-maybe)))
        (goto-char (cdr loc))
        (org-writenotes--node-id-at-point t)
        (save-buffer))
      (goto-char (cdr loc))
      (org-writenotes--parse-subtree-at-point))))

(defun org-writenotes--locate-checklist-line (beg body-end line-num)
  "Locate the checklist item line near LINE-NUM within BEG..BODY-END."
  (let ((checkbox-re "^\\(\\s-*\\)\\([-+*]\\)\\(\\s-+\\[\\)\\([ Xx-]\\)\\(\\]\\s-+\\)\\(.*\\)$"))
    (goto-char (point-min))
    (forward-line (1- line-num))
    (unless (and (>= (point) beg) (< (point) body-end) (looking-at checkbox-re))
      (let ((best-pos nil)
            (best-dist most-positive-fixnum))
        (save-excursion
          (goto-char beg)
          (while (re-search-forward checkbox-re body-end t)
            (let* ((cand-pos (match-beginning 0))
                   (cand-line (line-number-at-pos cand-pos))
                   (dist (abs (- cand-line line-num))))
              (when (< dist best-dist)
                (setq best-dist dist
                      best-pos cand-pos)))))
        (when best-pos
          (goto-char best-pos))))
    (looking-at checkbox-re)))

(defun org-writenotes--handle-update-checklist-item (params)
  "Update text, state, or indentation/order of a checklist item specified by PARAMS.
Supports:
- `text': new item text
- `state': \"checked\" | \"unchecked\" | \"partial\"
- `action': \"indent\" | \"outdent\" | \"moveUp\" | \"moveDown\"."
  (let* ((node-id (alist-get 'nodeId params))
         (line-num (alist-get 'line params))
         (new-text (alist-get 'text params))
         (new-state (alist-get 'state params))
         (action (alist-get 'action params))
         (loc (org-writenotes--locate-node node-id)))
    (unless loc
      (error "Node not found: %s" node-id))
    (with-current-buffer (car loc)
      (save-excursion
        (goto-char (cdr loc))
        (org-back-to-heading t)
        (let* ((beg (point))
               (sub-end (save-excursion (org-end-of-subtree t t) (point)))
               (body-end (org-writenotes--body-end-pos beg sub-end)))
          (when (org-writenotes--locate-checklist-line beg body-end (or line-num 1))
            (when new-state
              (let ((box-char (cond
                               ((equal new-state "checked") "X")
                               ((equal new-state "partial") "-")
                               (t " "))))
                (replace-match box-char t t nil 4)))
            (when new-text
              (org-writenotes--locate-checklist-line beg body-end (line-number-at-pos))
              (replace-match new-text t t nil 6))
            (pcase action
              ("indent"
               (beginning-of-line)
               (insert "  "))
              ("outdent"
               (beginning-of-line)
               (when (looking-at "^  ")
                 (delete-char 2)))
              ("moveUp"
               (ignore-errors (org-move-item-up)))
              ("moveDown"
               (ignore-errors (org-move-item-down))))
            (org-update-checkbox-count-maybe)))
        (goto-char (cdr loc))
        (org-writenotes--node-id-at-point t)
        (save-buffer))
      (goto-char (cdr loc))
      (org-writenotes--parse-subtree-at-point))))

(defun org-writenotes--handle-delete-checklist-item (params)
  "Delete a checklist item at `line' in the Org node specified by PARAMS."
  (let* ((node-id (alist-get 'nodeId params))
         (line-num (alist-get 'line params))
         (loc (org-writenotes--locate-node node-id)))
    (unless loc
      (error "Node not found: %s" node-id))
    (with-current-buffer (car loc)
      (save-excursion
        (goto-char (cdr loc))
        (org-back-to-heading t)
        (let* ((beg (point))
               (sub-end (save-excursion (org-end-of-subtree t t) (point)))
               (body-end (org-writenotes--body-end-pos beg sub-end)))
          (when (org-writenotes--locate-checklist-line beg body-end (or line-num 1))
            (delete-region (line-beginning-position)
                           (min (point-max) (1+ (line-end-position))))
            (org-update-checkbox-count-maybe)))
        (goto-char (cdr loc))
        (org-writenotes--node-id-at-point t)
        (save-buffer))
      (goto-char (cdr loc))
      (org-writenotes--parse-subtree-at-point))))

(defun org-writenotes--handle-execute-code-block (params)
  "Execute the Org Babel source block at `startLine' in the node specified by PARAMS."
  (let* ((node-id (alist-get 'nodeId params))
         (start-line (alist-get 'startLine params))
         (loc (org-writenotes--locate-node node-id)))
    (unless loc
      (error "Node not found: %s" node-id))
    (with-current-buffer (car loc)
      (save-excursion
        (goto-char (cdr loc))
        (org-back-to-heading t)
        (let* ((beg (point))
               (sub-end (save-excursion (org-end-of-subtree t t) (point)))
               (body-end (org-writenotes--body-end-pos beg sub-end))
               (case-fold-search t))
          (goto-char (point-min))
          (when (and (integerp start-line) (> start-line 0))
            (forward-line (1- start-line)))
          (unless (and (>= (point) beg) (< (point) body-end)
                       (looking-at-p "^\\s-*#\\+BEGIN_SRC\\b"))
            (goto-char beg)
            (re-search-forward "^\\s-*#\\+BEGIN_SRC\\b" body-end t))
          (beginning-of-line)
          (when (looking-at-p "^\\s-*#\\+BEGIN_SRC\\b")
            (let ((org-confirm-babel-evaluate nil))
              (condition-case err
                  (org-babel-execute-src-block)
                (error
                 (save-excursion
                   (when (re-search-forward "^\\s-*#\\+END_SRC\\b" body-end t)
                     (end-of-line)
                     (insert (format "\n#+RESULTS:\n: Error: %s" (error-message-string err))))))))
            (save-buffer))))
      (goto-char (cdr loc))
      (org-writenotes--parse-subtree-at-point))))

(defun org-writenotes--handle-update-table-cell (params)
  "Update a cell `(row, col)' in the Org table starting at `startLine' in PARAMS."
  (let* ((node-id (alist-get 'nodeId params))
         (start-line (alist-get 'startLine params))
         (row-idx (or (alist-get 'row params) 0))
         (col-idx (or (alist-get 'col params) 0))
         (new-val (or (alist-get 'value params) ""))
         (loc (org-writenotes--locate-node node-id)))
    (unless loc
      (error "Node not found: %s" node-id))
    (with-current-buffer (car loc)
      (save-excursion
        (goto-char (cdr loc))
        (org-back-to-heading t)
        (let* ((beg (point))
               (sub-end (save-excursion (org-end-of-subtree t t) (point)))
               (body-end (org-writenotes--body-end-pos beg sub-end)))
          (goto-char (point-min))
          (when (and (integerp start-line) (> start-line 0))
            (forward-line (1- start-line)))
          (unless (and (>= (point) beg) (< (point) body-end)
                       (looking-at-p "^\\s-*|"))
            (goto-char beg)
            (re-search-forward "^\\s-*|" body-end t))
          (beginning-of-line)
          (let ((cur-data-row 0)
                (updated nil))
            (while (and (not updated)
                        (< (point) body-end)
                        (looking-at "^\\s-*|\\(.*\\)|\\s-*$"))
              (let ((inner (match-string-no-properties 1)))
                (unless (string-match-p "^[-+]+$" (string-trim inner))
                  (if (= cur-data-row row-idx)
                      (let* ((cells (mapcar #'string-trim (split-string inner "|"))))
                        (while (<= (length cells) col-idx)
                          (setq cells (append cells (list ""))))
                        (setf (nth col-idx cells) (string-trim new-val))
                        (delete-region (line-beginning-position) (line-end-position))
                        (insert (concat "| " (mapconcat #'identity cells " | ") " |"))
                        (ignore-errors (org-table-align))
                        (setq updated t))
                    (setq cur-data-row (1+ cur-data-row)))))
              (unless updated
                (forward-line 1)))))
        (goto-char (cdr loc))
        (org-writenotes--node-id-at-point t)
        (save-buffer))
      (goto-char (cdr loc))
      (org-writenotes--parse-subtree-at-point))))

(defun org-writenotes--handle-clock-in (params)
  "Start `org-clock-in' on the Org node specified by PARAMS."
  (let* ((node-id (alist-get 'nodeId params))
         (loc (org-writenotes--locate-node node-id)))
    (unless loc
      (error "Node not found: %s" node-id))
    (with-current-buffer (car loc)
      (save-excursion
        (goto-char (cdr loc))
        (org-back-to-heading t)
        (ignore-errors
          (require 'org-clock)
          (org-clock-in))
        (save-buffer))
      (goto-char (cdr loc))
      (org-writenotes--parse-subtree-at-point))))

(defun org-writenotes--handle-clock-out (params)
  "Stop `org-clock-out' on the active clock or the node specified by PARAMS."
  (let* ((node-id (alist-get 'nodeId params))
         (loc (org-writenotes--locate-node node-id)))
    (unless loc
      (error "Node not found: %s" node-id))
    (with-current-buffer (car loc)
      (save-excursion
        (goto-char (cdr loc))
        (org-back-to-heading t)
        (ignore-errors
          (require 'org-clock)
          (when (and (fboundp 'org-clocking-p) (org-clocking-p))
            (org-clock-out)))
        (save-buffer))
      (goto-char (cdr loc))
      (org-writenotes--parse-subtree-at-point))))

(defun org-writenotes--handle-insert-ocr-text (params)
  "Insert converted handwriting OCR text into the Org node specified by PARAMS.
Supports `mode' (\"paragraph\" or \"checklist\"), `text', and optional `fileName'."
  (let* ((node-id (alist-get 'nodeId params))
         (text (string-trim (or (alist-get 'text params) "")))
         (mode (or (alist-get 'mode params) "paragraph"))
         (filename (alist-get 'fileName params))
         (loc (org-writenotes--locate-node node-id)))
    (unless loc
      (error "Node not found: %s" node-id))
    (when (string-empty-p text)
      (error "OCR text is empty"))
    (let ((formatted
           (if (equal mode "checklist")
               (mapconcat (lambda (ln)
                            (let ((clean (replace-regexp-in-string "^[-+*]\\s-*\\(\\[[ Xx-]\\]\\s-*\\)?" "" (string-trim ln))))
                              (format "- [ ] %s" clean)))
                          (split-string text "\n" t)
                          "\n")
             text)))
      (with-current-buffer (car loc)
        (save-excursion
          (goto-char (cdr loc))
          (org-back-to-heading t)
          (let* ((beg (point))
                 (sub-end (save-excursion (org-end-of-subtree t t) (point)))
                 (body-end (org-writenotes--body-end-pos beg sub-end))
                 (inserted nil))
            (when (and filename (stringp filename) (not (string-empty-p filename)))
              (let ((bare (file-name-nondirectory filename)))
                (goto-char beg)
                (when (re-search-forward
                       (format "\\[\\[\\(?:file:\\|attachment:\\)[^]\n]*?%s\\(?:\\]\\[[^]\n]*\\)?\\]\\]"
                               (regexp-quote bare))
                       body-end t)
                  (end-of-line)
                  ;; Skip past any :WRITENOTES_OCR: drawer if present
                  (save-excursion
                    (forward-line 1)
                    (when (looking-at "^\\s-*:WRITENOTES_OCR:\\s-*\n\\(?:.\\|\n\\)*?^\\s-*:END:\\s-*$")
                      (goto-char (match-end 0))))
                  (when (save-excursion
                          (forward-line 1)
                          (looking-at "^\\s-*:WRITENOTES_OCR:\\s-*\n\\(?:.\\|\n\\)*?^\\s-*:END:\\s-*$"))
                    (forward-line 1)
                    (re-search-forward "^\\s-*:END:\\s-*$" body-end t))
                  (end-of-line)
                  (insert (format "\n\n%s\n" formatted))
                  (setq inserted t))))
            (unless inserted
              (goto-char body-end)
              (skip-chars-backward " \t\n" beg)
              (insert (format "\n\n%s\n" formatted)))
            (goto-char (cdr loc))
            (org-writenotes--node-id-at-point t)
            (save-buffer)))
        (goto-char (cdr loc))
        (let ((snapshot (org-writenotes--parse-subtree-at-point)))
          (org-writenotes--broadcast-notification "emacs.focusNode" snapshot)
          snapshot)))))

(defun org-writenotes--handle-list-gallery (_params)
  "Scan `.org' buffers and `org-writenotes-image-dir' to list `.svgz' sketches with metadata."
  (let* ((ref-map (make-hash-table :test 'equal))
         (items nil))
    ;; Scan open Org buffers for sketch links -> parent node metadata
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and (derived-mode-p 'org-mode) (buffer-file-name))
          (let ((bfile (buffer-file-name)))
            (save-excursion
              (save-restriction
                (widen)
                (goto-char (point-min))
                (while (re-search-forward
                        "\\[\\[\\(?:file:\\|attachment:\\)\\([^]\n]+\\.svgz?\\)\\(?:\\]\\[[^]\n]*\\)?\\]\\]"
                        nil t)
                  (let* ((rel (match-string-no-properties 1))
                         (fname (file-name-nondirectory rel)))
                    (save-excursion
                      (when (ignore-errors (org-back-to-heading t))
                        (let ((nid (org-writenotes--node-id-at-point t))
                              (title (or (nth 4 (org-heading-components)) "Untitled")))
                          (puthash fname
                                   (list :nodeId nid :nodeTitle title :orgFile bfile)
                                   ref-map))))))))))))
    ;; Collect all .svgz files from image directory
    (let* ((img-dir (org-writenotes--resolve-image-dir nil))
           (svgz-files (when (file-directory-p img-dir)
                         (directory-files img-dir t "\\.svgz\\'" t))))
      ;; Sort newest first by modification time
      (setq svgz-files
            (sort svgz-files
                  (lambda (a b)
                    (time-less-p (file-attribute-modification-time (file-attributes b))
                                 (file-attribute-modification-time (file-attributes a))))))
      (dolist (abs-path svgz-files)
        (let* ((fname (file-name-nondirectory abs-path))
               (ref (gethash fname ref-map))
               (dims (org-writenotes--extract-svgz-dimensions abs-path))
               (mtime (format-time-string
                       "%Y-%m-%d %H:%M"
                       (file-attribute-modification-time (file-attributes abs-path)))))
          (push `(:fileName ,fname
                  :filePath ,abs-path
                  :nodeId ,(or (plist-get ref :nodeId) :null)
                  :nodeTitle ,(or (plist-get ref :nodeTitle) "Unlinked Sketch")
                  :orgFile ,(or (plist-get ref :orgFile) :null)
                  :modifiedTime ,mtime
                  :width ,(car dims)
                  :height ,(cdr dims)
                  :svgzBase64 ,(or (org-writenotes--file-to-base64 abs-path) :null))
                items)))
      `(:sketches ,(vconcat (nreverse items))))))

(defun org-writenotes--handle-add-checklist-item (params)
  "Append a new `- [ ]' checklist item to the node specified by PARAMS."
  (let* ((node-id (alist-get 'nodeId params))
         (text (or (alist-get 'text params) "New item"))
         (after-line (alist-get 'afterLine params))
         (loc (org-writenotes--locate-node node-id)))
    (unless loc
      (error "Node not found: %s" node-id))
    (with-current-buffer (car loc)
      (save-excursion
        (goto-char (cdr loc))
        (org-back-to-heading t)
        (let* ((beg (point))
               (sub-end (save-excursion (org-end-of-subtree t t) (point)))
               (body-end (org-writenotes--body-end-pos beg sub-end)))
          (cond
           ((and (integerp after-line) (> after-line 0))
            (goto-char (point-min))
            (forward-line (1- after-line))
            (goto-char (min body-end (line-end-position)))
            (insert (format "\n- [ ] %s" text)))
           ((re-search-forward "^\\s-*[-+*]\\s-+\\[[ Xx-]\\].*$" body-end t)
            (while (and (< (point) body-end)
                        (save-excursion
                          (forward-line 1)
                          (and (< (point) body-end)
                               (looking-at-p "^\\s-*[-+*]\\s-+\\[[ Xx-]\\]"))))
              (forward-line 1))
            (end-of-line)
            (insert (format "\n- [ ] %s" text)))
           (t
            (org-writenotes--goto-body-start beg body-end)
            (unless (bolp) (insert "\n"))
            (insert (format "- [ ] %s\n" text))))
          (org-update-checkbox-count-maybe)
          (goto-char (cdr loc))
          (org-writenotes--node-id-at-point t)
          (save-buffer)))
      (goto-char (cdr loc))
      (org-writenotes--parse-subtree-at-point))))

(defun org-writenotes--handle-update-header (params)
  "Update TODO keyword, priority, title, tags, scheduled, or deadline of the Org node in PARAMS."
  (let* ((node-id (alist-get 'nodeId params))
         (todo (alist-get 'todoKeyword params))
         (prio (alist-get 'priority params))
         (title (alist-get 'title params))
         (tags (alist-get 'tags params))
         (has-sched (assq 'scheduled params))
         (sched (alist-get 'scheduled params))
         (has-deadl (assq 'deadline params))
         (deadl (alist-get 'deadline params))
         (loc (org-writenotes--locate-node node-id)))
    (unless loc
      (error "Node not found: %s" node-id))
    (with-current-buffer (car loc)
      (save-excursion
        (goto-char (cdr loc))
        (when todo
          (org-todo todo))
        (when (and prio (stringp prio) (> (length prio) 0))
          (org-priority (aref prio 0)))
        (when title
          (org-edit-headline title))
        (when tags
          (org-set-tags (append tags nil)))
        (when has-sched
          (if (or (null sched) (eq sched :null) (and (stringp sched) (string-empty-p (string-trim sched))))
              (ignore-errors (org-schedule '(4)))
            (ignore-errors (org-schedule nil sched))))
        (when has-deadl
          (if (or (null deadl) (eq deadl :null) (and (stringp deadl) (string-empty-p (string-trim deadl))))
              (ignore-errors (org-deadline '(4)))
            (ignore-errors (org-deadline nil deadl))))
        (goto-char (cdr loc))
        (org-writenotes--node-id-at-point t)
        (save-buffer))
      (goto-char (cdr loc))
      (org-writenotes--parse-subtree-at-point))))

(defun org-writenotes--handle-update-paragraph (params)
  "Replace paragraph text starting at `startLine' in the Org node specified by PARAMS."
  (let* ((node-id (alist-get 'nodeId params))
         (start-line (alist-get 'startLine params))
         (end-line (alist-get 'endLine params))
         (old-text (alist-get 'oldText params))
         (new-text (alist-get 'text params))
         (loc (org-writenotes--locate-node node-id)))
    (unless loc
      (error "Node not found: %s" node-id))
    (with-current-buffer (car loc)
      (save-excursion
        (goto-char (cdr loc))
        (org-back-to-heading t)
        (let* ((beg (point))
               (sub-end (save-excursion (org-end-of-subtree t t) (point)))
               (body-end (org-writenotes--body-end-pos beg sub-end)))
          (cond
           ((and old-text (not (string-empty-p old-text))
                 (save-excursion
                   (goto-char beg)
                   (search-forward old-text body-end t)))
            (goto-char beg)
            (when (search-forward old-text body-end t)
              (replace-match (or new-text "") t t)))
           ((and (integerp start-line) (> start-line 0)
                 (integerp end-line) (>= end-line start-line))
            (goto-char (point-min))
            (forward-line (1- start-line))
            (let ((line-beg (line-beginning-position))
                  (line-end (save-excursion
                              (goto-char (point-min))
                              (forward-line (1- end-line))
                              (min body-end (line-end-position)))))
              (delete-region line-beg line-end)
              (insert (or new-text ""))))
           (start-line
            (goto-char (point-min))
            (forward-line (1- start-line))
            (let ((line-beg (line-beginning-position))
                  (line-end (min body-end (line-end-position))))
              (delete-region line-beg line-end)
              (insert (or new-text "")))))
          (goto-char (cdr loc))
          (org-writenotes--node-id-at-point t)
          (save-buffer)))
      (goto-char (cdr loc))
      (org-writenotes--parse-subtree-at-point))))

(defun org-writenotes--handle-set-property (params)
  "Set an Org `:PROPERTIES:' drawer key-value pair on the node in PARAMS."
  (let* ((node-id (alist-get 'nodeId params))
         (key (alist-get 'key params))
         (val (alist-get 'value params))
         (loc (org-writenotes--locate-node node-id)))
    (unless (and loc key)
      (error "Missing node or key for node.setProperty"))
    (with-current-buffer (car loc)
      (save-excursion
        (goto-char (cdr loc))
        (org-set-property key (or val ""))
        (org-writenotes--node-id-at-point t)
        (save-buffer))
      (goto-char (cdr loc))
      (org-writenotes--parse-subtree-at-point))))

(defun org-writenotes--handle-insert-ink-block (params)
  "Create a `.svgz' file in the common directory and link it into the Org node.
PARAMS is the RPC parameter alist.  Supports positioning via:
- `afterLine' (0 for top of node body, or line number after a block / checklist item)
- `splitStartLine' + `splitEndLine' + `textBefore' + `textAfter' (to split a paragraph at cursor)."
  (let* ((node-id (alist-get 'nodeId params))
         (w (or (alist-get 'width params) org-writenotes-default-canvas-width))
         (h (or (alist-get 'height params) org-writenotes-default-canvas-height))
         (xr (or (alist-get 'xRuling params) 40))
         (yr (or (alist-get 'yRuling params) 40))
         (after-line (alist-get 'afterLine params))
         (split-start (alist-get 'splitStartLine params))
         (split-end (alist-get 'splitEndLine params))
         (text-before (alist-get 'textBefore params))
         (text-after (alist-get 'textAfter params))
         (loc (org-writenotes--locate-node node-id)))
    (unless loc
      (error "Node not found: %s" node-id))
    (let ((snapshot
           (with-current-buffer (car loc)
             (save-restriction
               (widen)
               (let* ((marker-pos (cdr loc))
                      (abs-path nil))
                 (save-excursion
                   (goto-char marker-pos)
                   (org-back-to-heading t)
                   (let* ((beg (point))
                          (org-file (or (buffer-file-name) default-directory))
                          (title (or (nth 4 (org-heading-components)) "note"))
                          (slug (org-writenotes--slugify title))
                          (timestamp (format-time-string "%Y%m%d-%H%M%S"))
                          (filename (format "%s-%s.svgz" slug timestamp))
                          (img-dir (org-writenotes--resolve-image-dir org-file))
                          (path (expand-file-name filename img-dir))
                          (link-str (org-writenotes--format-file-link org-file filename))
                          (sub-end (save-excursion (org-end-of-subtree t t) (point-marker)))
                          (body-end (copy-marker (org-writenotes--body-end-pos beg (marker-position sub-end)))))
                     (setq abs-path path)
                     (org-writenotes--create-blank-svgz path w h xr yr)
                     (cond
                      ;; 1. Split a paragraph at a specific text cursor position
                      ((and (integerp split-start) (> split-start 0))
                       (let* ((end-ln (if (and (integerp split-end) (>= split-end split-start))
                                          split-end
                                        split-start))
                              (before-clean (string-trim-right (or text-before "")))
                              (after-clean (string-trim-left (or text-after "")))
                              (replacement
                               (cond
                                ((and (not (string-empty-p before-clean))
                                      (not (string-empty-p after-clean)))
                                 (format "%s\n\n%s\n\n%s" before-clean link-str after-clean))
                                ((not (string-empty-p before-clean))
                                 (format "%s\n\n%s" before-clean link-str))
                                ((not (string-empty-p after-clean))
                                 (format "%s\n\n%s" link-str after-clean))
                                (t link-str))))
                         (goto-char (point-min))
                         (forward-line (1- split-start))
                         (let* ((reg-beg (max (point-min) (min (point-max) (line-beginning-position))))
                                (raw-end (save-excursion
                                           (goto-char (point-min))
                                           (forward-line (1- end-ln))
                                           (min (marker-position body-end) (line-end-position))))
                                (reg-end (max reg-beg (min (point-max) raw-end))))
                           (delete-region reg-beg reg-end)
                           (insert replacement))))

                      ;; 2. Insert at top of node body (after heading + drawers)
                      ((and (integerp after-line) (<= after-line 0))
                       (org-writenotes--goto-body-start beg (marker-position body-end))
                       (unless (bolp) (insert "\n"))
                       (insert (format "%s\n\n" link-str)))

                      ;; 3. Insert after a specific line (after a checklist item, checklist, paragraph, or sketch)
                      ((and (integerp after-line) (> after-line 0))
                       (let ((body-start (save-excursion
                                           (org-writenotes--goto-body-start beg (marker-position body-end))
                                           (point))))
                         (goto-char (point-min))
                         (forward-line (1- after-line))
                         (let* ((line-end (min (marker-position body-end) (line-end-position)))
                                (ins-pos (max body-start line-end)))
                           (goto-char ins-pos)
                           (unless (bolp) (insert "\n"))
                           (insert (format "%s\n\n" link-str)))))

                      ;; 4. Default: append at the end of the node body (before any child headings)
                      (t
                       (let ((body-start (save-excursion
                                           (org-writenotes--goto-body-start beg (marker-position body-end))
                                           (point))))
                         (goto-char (marker-position body-end))
                         (skip-chars-backward " \t\n" body-start)
                         (if (<= (point) body-start)
                             (progn
                               (goto-char body-start)
                               (unless (bolp) (insert "\n"))
                               (insert (format "%s\n\n" link-str)))
                           (insert (format "\n\n%s\n" link-str))))))
                     (goto-char marker-pos)
                     (org-writenotes--node-id-at-point t)
                     (save-buffer)
                     (org-writenotes--refresh-inline-image abs-path)))
                 (goto-char marker-pos)
                 (org-back-to-heading t)
                 (org-writenotes--parse-subtree-at-point))))))
      (setq org-writenotes--active-node-id (plist-get snapshot :nodeId))
      (org-writenotes--broadcast-notification "emacs.focusNode" snapshot)
      snapshot)))

(defun org-writenotes--remove-associated-ocr-at-point (&optional bare-filename)
  "Remove any `:WRITENOTES_OCR:' drawer or following OCR heading near point.
If BARE-FILENAME is given, also clean up child headings matching OCR for that file."
  ;; 1. Remove any :WRITENOTES_OCR: drawer immediately following point
  (save-excursion
    (skip-chars-forward " \t\n")
    (beginning-of-line)
    (let ((drawer-re "^[ \t]*:WRITENOTES_OCR:[ \t]*\n\\(?:.\\|\n\\)*?^[ \t]*:END:[ \t]*\n?"))
      (while (looking-at drawer-re)
        (replace-match "" t t))))
  ;; 2. Remove any directly following OCR heading (e.g. "** OCR", "** OCR: ...", or "** Handwriting OCR")
  (save-excursion
    (skip-chars-forward " \t\n")
    (beginning-of-line)
    (when (looking-at "^\\*+[ \t]+\\(?:TODO[ \t]+\\|DONE[ \t]+\\)?\\(?:\\[#[A-Z]\\][ \t]+\\)?\\(?:OCR\\b\\|Handwriting OCR\\).*$")
      (let* ((h-beg (point))
             (h-end (save-excursion (org-end-of-subtree t t) (point))))
        (delete-region h-beg h-end))))
  ;; 3. If BARE-FILENAME is provided, scan the current subtree for child headings specifically named after this sketch's OCR
  (when bare-filename
    (save-excursion
      (let ((sub-end (save-excursion (org-end-of-subtree t t) (point-marker)))
            (bare-no-ext (file-name-sans-extension (file-name-nondirectory bare-filename))))
        (while (re-search-forward
                (format "^\\*+[ \t]+.*\\(?:OCR.*%s\\|%s.*OCR\\).*$"
                        (regexp-quote bare-no-ext)
                        (regexp-quote bare-no-ext))
                sub-end t)
          (let* ((h-beg (line-beginning-position))
                 (h-end (save-excursion (org-end-of-subtree t t) (point))))
            (delete-region h-beg h-end)))))))

(defun org-writenotes--handle-delete-ink-block (params)
  "Delete an `.svgz' handwritten ink block from the Org node specified by PARAMS.
PARAMS contains:
- `nodeId': Org ID of the node
- `fileName': The file name of the `.svgz' drawing (e.g. \"heading-timestamp.svgz\")
- `linkText': Optional exact link string originally extracted from buffer
- `deleteFile': Non-nil (default t) to delete the physical file on disk."
  (let* ((node-id (alist-get 'nodeId params))
         (filename (alist-get 'fileName params))
         (link-text (alist-get 'linkText params))
         (delete-file-p (if (null (assq 'deleteFile params)) t (alist-get 'deleteFile params)))
         (loc (org-writenotes--locate-node node-id)))
    (unless loc
      (error "Node not found: %s" node-id))
    (unless (and filename (stringp filename) (not (string-empty-p filename)))
      (error "Missing or invalid fileName for node.deleteInkBlock"))
    (let ((snapshot
           (with-current-buffer (car loc)
             (save-restriction
               (widen)
               (save-excursion
                 (goto-char (cdr loc))
                 (org-back-to-heading t)
                 (let* ((beg (point))
                        (org-file (buffer-file-name))
                        (img-dir (org-writenotes--resolve-image-dir org-file))
                        (bare-filename (file-name-nondirectory filename))
                        (sub-end (save-excursion (org-end-of-subtree t t) (point-marker)))
                        (found nil)
                        (deleted-disk-path nil))
                   ;; 1. Search for link in the subtree
                   ;; Priority 1: Exact linkText if provided
                   (goto-char beg)
                   (if (and link-text
                            (stringp link-text)
                            (not (string-empty-p link-text))
                            (search-forward link-text sub-end t))
                       (setq found t)
                     ;; Priority 2: Flexible search matching any Org link containing bare-filename
                     (goto-char beg)
                     (let* ((encoded-name (if (fboundp 'url-hexify-string)
                                              (url-hexify-string bare-filename)
                                            bare-filename))
                            (name-pat (if (string= encoded-name bare-filename)
                                          (regexp-quote bare-filename)
                                        (format "%s\\|%s"
                                                (regexp-quote bare-filename)
                                                (regexp-quote encoded-name))))
                            (link-regex (format "\\[\\[\\(?:[^]\n]*?\\)?%s\\(?:\\]\\[[^]\n]*\\)?\\]\\]"
                                                name-pat)))
                       (when (re-search-forward link-regex sub-end t)
                         (setq found t))))

                   (unless found
                     ;; If link was already deleted from buffer (e.g. earlier edit or offline queue retry),
                     ;; ensure disk file is removed if requested, but do not error out.
                     (let* ((cand-base (when org-file
                                         (expand-file-name bare-filename (file-name-directory (expand-file-name org-file)))))
                            (cand-img (when img-dir
                                        (expand-file-name bare-filename img-dir))))
                       (setq deleted-disk-path
                             (cond
                              ((and cand-base (file-exists-p cand-base)) cand-base)
                              ((and cand-img (file-exists-p cand-img)) cand-img)
                              (cand-img cand-img)
                              (t cand-base)))))

                   (when found
                     ;; 2. Match bounds and delete from Org buffer
                     (let* ((link-beg (match-beginning 0))
                            (link-end (match-end 0))
                            (matched-str (buffer-substring-no-properties link-beg link-end))
                            (line-beg (line-beginning-position))
                            (line-end (line-end-position))
                            (line-str (string-trim (buffer-substring-no-properties line-beg line-end)))
                            (raw-target
                             (save-match-data
                               (if (string-match "\\[\\[\\(?:file:\\|attachment:\\)?\\([^]\n]+?\\)\\(?:\\]\\[[^]\n]*\\)?\\]\\]" matched-str)
                                   (match-string 1 matched-str)
                                 bare-filename)))
                            (clean-target (if (and raw-target (fboundp 'url-unhex-string))
                                              (url-unhex-string raw-target)
                                            (or raw-target bare-filename)))
                            (cand-base (when org-file
                                         (expand-file-name clean-target (file-name-directory (expand-file-name org-file)))))
                            (cand-img (when img-dir
                                        (expand-file-name (file-name-nondirectory clean-target) img-dir))))

                       ;; Resolve the physical file path on disk
                       (setq deleted-disk-path
                             (cond
                              ((and cand-base (file-exists-p cand-base)) cand-base)
                              ((and cand-img (file-exists-p cand-img)) cand-img)
                              (cand-img cand-img)
                              (t cand-base)))

                       ;; Delete line or inline region
                       (if (string= line-str (string-trim matched-str))
                           (delete-region line-beg (min (point-max) (1+ line-end)))
                         (delete-region link-beg link-end))

                       ;; Remove any immediately following :WRITENOTES_OCR: drawer or OCR heading
                       (org-writenotes--remove-associated-ocr-at-point bare-filename)

                       ;; Clean up excessive blank lines within this subtree
                       (save-excursion
                         (goto-char beg)
                         (let ((lim (save-excursion (org-end-of-subtree t t) (point-marker))))
                           (while (re-search-forward "\n\\{3,\\}" lim t)
                             (replace-match "\n\n" nil nil))))))

                   ;; 3. Delete physical file on disk if requested
                   (when (and delete-file-p deleted-disk-path (file-exists-p deleted-disk-path))
                     (ignore-errors (delete-file deleted-disk-path)))

                   ;; 4. Save Org buffer and refresh image display
                   (save-buffer)
                   (when deleted-disk-path
                     (org-writenotes--refresh-inline-image deleted-disk-path))))
               (goto-char (cdr loc))
               (org-writenotes--parse-subtree-at-point)))))
      (setq org-writenotes--active-node-id (plist-get snapshot :nodeId))
      (org-writenotes--broadcast-notification "emacs.focusNode" snapshot)
      snapshot)))

(defun org-writenotes--handle-ink-delta (params)
  "Handle live stroke delta in PARAMS, updating in-memory SVG preview if enabled."
  (let* ((node-id (alist-get 'nodeId params))
         (filename (alist-get 'fileName params))
         (path-xml (alist-get 'pathXml params))
         (stroke-id (alist-get 'strokeId params)))
    (when (and org-writenotes-live-stroke-preview
               filename
               path-xml
               (stringp path-xml)
               (not (string-empty-p path-xml)))
      (let* ((loc (when node-id (org-writenotes--locate-node node-id)))
             (org-file (when loc (buffer-file-name (car loc))))
             (img-dir (org-writenotes--resolve-image-dir org-file))
             (bare-filename (file-name-nondirectory filename))
             (abs-path (expand-file-name bare-filename img-dir))
             (base-xml (or (gethash abs-path org-writenotes--live-svg-cache)
                           (org-writenotes--read-svgz-xml abs-path))))
        (when (and base-xml (string-match "</g>\\s-*</svg>\\s-*</svg>" base-xml))
          (let ((updated-xml
                 (replace-match (concat "  " path-xml "\n</g>\n</svg>\n</svg>")
                                t t base-xml)))
            (puthash abs-path updated-xml org-writenotes--live-svg-cache)
            (org-writenotes--refresh-inline-image abs-path)))))
    `(:ok t :strokeId ,(or stroke-id :null))))

(defun org-writenotes--handle-ink-commit (params)
  "Write base64-encoded `.svgz' bytes from PARAMS to the common directory.
Refresh the inline display and update the folded :WRITENOTES_OCR: drawer
if OCR text is provided."
  (let* ((node-id (alist-get 'nodeId params))
         (filename (alist-get 'fileName params))
         (b64 (alist-get 'svgzBase64 params))
         (ocr-text (alist-get 'ocrText params))
         (loc (org-writenotes--locate-node node-id)))
    (unless (and filename b64)
      (error "Missing fileName or svgzBase64 in ink.commit"))
    (let* ((org-file (when loc (buffer-file-name (car loc))))
           (img-dir (org-writenotes--resolve-image-dir org-file))
           (bare-filename (file-name-nondirectory filename))
           (abs-path (expand-file-name bare-filename img-dir))
           (raw-bytes (base64-decode-string b64)))
      (remhash abs-path org-writenotes--live-svg-cache)
      (org-writenotes--write-raw-bytes abs-path raw-bytes)
      ;; Update folded :WRITENOTES_OCR: drawer beneath the link in the Org buffer
      (when loc
        (with-current-buffer (car loc)
          (save-excursion
            (goto-char (cdr loc))
            (let* ((end (save-excursion (org-end-of-subtree t t) (point)))
                   (link-re (format "\\[\\[\\(?:file:\\|attachment:\\)[^]\n]*?%s\\(?:\\]\\[[^]\n]*\\)?\\]\\]"
                                    (regexp-quote bare-filename))))
              (when (re-search-forward link-re end t)
                (let ((had-drawer nil)
                      (trimmed-ocr (when (and ocr-text (stringp ocr-text))
                                     (string-trim ocr-text))))
                  ;; Check and clean up any existing duplicate drawer(s) following the link
                  (save-excursion
                    (skip-chars-forward " \t\n")
                    (beginning-of-line)
                    (let ((drawer-re "^[ \t]*:WRITENOTES_OCR:[ \t]*\n\\(?:.\\|\n\\)*?^[ \t]*:END:[ \t]*\n?"))
                      (while (looking-at drawer-re)
                        (setq had-drawer t)
                        (replace-match "" t t))))
                  ;; Insert single clean drawer only if auto-sync is enabled OR a drawer was already present
                  (when (and trimmed-ocr (not (string-empty-p trimmed-ocr))
                             (or org-writenotes-auto-sync-ocr-drawer had-drawer))
                    (end-of-line)
                    (insert (format "\n:WRITENOTES_OCR:\n%s\n:END:\n" trimmed-ocr)))
                  (when (or had-drawer (and org-writenotes-auto-sync-ocr-drawer
                                            trimmed-ocr (not (string-empty-p trimmed-ocr))))
                    (save-buffer))))))))
      (org-writenotes--refresh-inline-image abs-path)
      `(:savedPath ,abs-path :bytesWritten ,(length raw-bytes)))))

;;; ---------------------------------------------------------------------------
;;; Lightweight Built-in RFC 6455 WebSocket & JSON-RPC 2.0 Server
;;; ---------------------------------------------------------------------------

(defun org-writenotes--ws-accept-key (client-key)
  "Compute the RFC 6455 `Sec-WebSocket-Accept' value for CLIENT-KEY."
  (base64-encode-string
   (secure-hash 'sha1
                (concat (string-trim client-key)
                        "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
                nil nil t)
   t))

(defun org-writenotes--ws-encode-frame (text)
  "Encode UTF-8 TEXT into an unmasked RFC 6455 WebSocket text frame."
  (let* ((payload (encode-coding-string text 'utf-8))
         (len (length payload))
         (header
          (cond
           ((< len 126)
            (unibyte-string #x81 len))
           ((< len 65536)
            (unibyte-string #x81 126
                            (logand (ash len -8) #xff)
                            (logand len #xff)))
           (t
            (unibyte-string #x81 127
                            (logand (ash len -56) #xff)
                            (logand (ash len -48) #xff)
                            (logand (ash len -40) #xff)
                            (logand (ash len -32) #xff)
                            (logand (ash len -24) #xff)
                            (logand (ash len -16) #xff)
                            (logand (ash len -8) #xff)
                            (logand len #xff))))))
    (concat header payload)))

(defun org-writenotes--ws-try-decode-frame (buffer-bytes)
  "Try to parse a single RFC 6455 frame from unibyte BUFFER-BYTES.
Returns `(opcode payload remaining-bytes)' or nil if incomplete."
  (setq buffer-bytes (string-as-unibyte buffer-bytes))
  (let ((total (length buffer-bytes)))
    (when (>= total 2)
      (let* ((b0 (logand (aref buffer-bytes 0) #xff))
             (b1 (logand (aref buffer-bytes 1) #xff))
             (opcode (logand b0 #x0f))
             (masked (/= (logand b1 #x80) 0))
             (len-indicator (logand b1 #x7f))
             (offset 2)
             (payload-len nil))
        (cond
         ((< len-indicator 126)
          (setq payload-len len-indicator
                offset 2))
         ((= len-indicator 126)
          (when (>= total 4)
            (setq payload-len (+ (ash (logand (aref buffer-bytes 2) #xff) 8)
                                 (logand (aref buffer-bytes 3) #xff))
                  offset 4)))
         ((= len-indicator 127)
          (when (>= total 10)
            (setq payload-len (+ (ash (logand (aref buffer-bytes 6) #xff) 24)
                                 (ash (logand (aref buffer-bytes 7) #xff) 16)
                                 (ash (logand (aref buffer-bytes 8) #xff) 8)
                                 (logand (aref buffer-bytes 9) #xff))
                  offset 10))))
        (let ((mask-len (if masked 4 0)))
          (when (and payload-len (>= total (+ offset mask-len payload-len)))
            (let* ((data-start (+ offset mask-len))
                   (data-end (+ data-start payload-len))
                   (unmasked
                    (if masked
                        (let ((out (make-string payload-len 0 nil))
                              (m0 (aref buffer-bytes offset))
                              (m1 (aref buffer-bytes (+ offset 1)))
                              (m2 (aref buffer-bytes (+ offset 2)))
                              (m3 (aref buffer-bytes (+ offset 3)))
                              (i 0)
                              (limit (- payload-len 3)))
                          (while (< i limit)
                            (let ((src (+ data-start i)))
                              (aset out i       (logxor (aref buffer-bytes src) m0))
                              (aset out (+ i 1) (logxor (aref buffer-bytes (+ src 1)) m1))
                              (aset out (+ i 2) (logxor (aref buffer-bytes (+ src 2)) m2))
                              (aset out (+ i 3) (logxor (aref buffer-bytes (+ src 3)) m3)))
                            (setq i (+ i 4)))
                          (while (< i payload-len)
                            (let ((mask-b (aref buffer-bytes (+ offset (logand i 3)))))
                              (aset out i (logxor (aref buffer-bytes (+ data-start i)) mask-b)))
                            (setq i (1+ i)))
                          out)
                      (substring buffer-bytes data-start data-end)))
                   (rest (substring buffer-bytes data-end)))
              (list opcode
                    (if (= opcode 1)
                        (decode-coding-string unmasked 'utf-8)
                      unmasked)
                    rest))))))))

(defun org-writenotes--ws-send-json (proc payload-plist)
  "Serialize PAYLOAD-PLIST to JSON and send over WebSocket PROC."
  (when (and proc (process-live-p proc))
    (let ((json-str (json-serialize payload-plist
                                    :null-object :null
                                    :false-object :false)))
      (process-send-string proc (org-writenotes--ws-encode-frame json-str)))))

(defun org-writenotes--broadcast-notification (method params-plist)
  "Broadcast a JSON-RPC 2.0 notification METHOD with PARAMS-PLIST to all connected tablets."
  (setq org-writenotes--clients
        (cl-remove-if-not #'process-live-p org-writenotes--clients))
  (dolist (client org-writenotes--clients)
    (org-writenotes--ws-send-json
     client
     `(:jsonrpc "2.0"
       :method ,method
       :params ,params-plist))))

(defun org-writenotes--dispatch-rpc (proc msg-text)
  "Handle an incoming JSON-RPC 2.0 request MSG-TEXT from client PROC."
  (let (req-id)
    (condition-case err
        (let* ((json-object-type 'alist)
               (json-array-type 'list)
               (json-key-type 'symbol)
               (req (json-read-from-string msg-text))
               (id (alist-get 'id req))
               (method (alist-get 'method req))
               (params (alist-get 'params req))
               (result nil))
          (setq req-id id)
          (setq result
                (pcase method
                  ("session.hello"
                   (let ((token (alist-get 'token params)))
                     ;; Validate token on non-loopback bindings
                     (when (and (not (member org-writenotes-host '("127.0.0.1" "localhost")))
                                org-writenotes--session-token
                                (not (equal token org-writenotes--session-token)))
                       (error "Authentication failed: invalid session token"))
                     `(:emacsVersion ,emacs-version
                       :orgVersion ,(org-version)
                       :imageDir ,org-writenotes-image-dir
                       :activeNodeId ,(or org-writenotes--active-node-id :null)
                       :theme ,(org-writenotes--current-theme-payload))))
                  ("node.create"
                   (org-writenotes--handle-create-node params))
                  ("node.list"
                   `(:nodes ,(org-writenotes--collect-node-summaries
                              (alist-get 'filter params)
                              (alist-get 'query params))))
                  ("node.get"
                   (let* ((nid (or (alist-get 'nodeId params)
                                   org-writenotes--active-node-id))
                          (loc (org-writenotes--locate-node nid)))
                     (if loc
                         (with-current-buffer (car loc)
                           (save-excursion
                             (goto-char (cdr loc))
                             (org-writenotes--parse-subtree-at-point)))
                       (error "Could not locate Org node: %s" nid))))
                  ("node.toggleCheckbox"
                   (org-writenotes--handle-toggle-checkbox params))
                  ("node.addChecklistItem"
                   (org-writenotes--handle-add-checklist-item params))
                  ("node.updateChecklistItem"
                   (org-writenotes--handle-update-checklist-item params))
                  ("node.deleteChecklistItem"
                   (org-writenotes--handle-delete-checklist-item params))
                  ("node.executeCodeBlock"
                   (org-writenotes--handle-execute-code-block params))
                  ("node.updateTableCell"
                   (org-writenotes--handle-update-table-cell params))
                  ("node.clockIn"
                   (org-writenotes--handle-clock-in params))
                  ("node.clockOut"
                   (org-writenotes--handle-clock-out params))
                  ("node.insertOcrText"
                   (org-writenotes--handle-insert-ocr-text params))
                  ("sketch.listGallery"
                   (org-writenotes--handle-list-gallery params))
                  ("node.updateHeader"
                   (org-writenotes--handle-update-header params))
                  ("node.updateParagraph"
                   (org-writenotes--handle-update-paragraph params))
                  ("node.setProperty"
                   (org-writenotes--handle-set-property params))
                  ("node.insertInkBlock"
                   (org-writenotes--handle-insert-ink-block params))
                  ("node.deleteInkBlock"
                   (org-writenotes--handle-delete-ink-block params))
                  ("ink.delta"
                   (org-writenotes--handle-ink-delta params))
                  ("ink.laser"
                   `(:ok t))
                  ("ink.commit"
                   (org-writenotes--handle-ink-commit params))
                  (_
                   (error "Unknown JSON-RPC method: %s" method))))
          (when id
            (org-writenotes--ws-send-json
             proc
             `(:jsonrpc "2.0" :id ,id :result ,result))))
      (error
       (message "[Org-WriteNotes] RPC Error: %s" (error-message-string err))
       (when req-id
         (org-writenotes--ws-send-json
          proc
          `(:jsonrpc "2.0"
            :id ,req-id
            :error (:code -32603 :message ,(error-message-string err)))))))))

(defun org-writenotes--client-filter (proc chunk)
  "Network filter for WebSocket handshake and frame decoding on PROC.
CHUNK is the newly received data."
  (let ((buf (concat (string-as-unibyte (or (process-get proc :recv-buf) (unibyte-string)))
                     (string-as-unibyte chunk))))
    (when (not (process-get proc :ws-upgraded))
      ;; Perform HTTP Upgrade -> WebSocket Handshake
      (when (string-match "\r\n\r\n" buf)
        (let* ((headers-end (match-end 0))
               (headers (substring buf 0 headers-end))
               (rest (substring buf headers-end)))
          (if (string-match "Sec-WebSocket-Key:\\s-*\\([^\r\n]+\\)" headers)
              (let* ((key (match-string 1 headers))
                     (accept (org-writenotes--ws-accept-key key))
                     (resp (concat
                            "HTTP/1.1 101 Switching Protocols\r\n"
                            "Upgrade: websocket\r\n"
                            "Connection: Upgrade\r\n"
                            (format "Sec-WebSocket-Accept: %s\r\n\r\n" accept))))
                (process-put proc :ws-upgraded t)
                (setq buf (string-as-unibyte rest))
                (process-put proc :recv-buf buf)
                (process-send-string proc resp)
                (cl-pushnew proc org-writenotes--clients)
                (message "[Org-WriteNotes] Tablet connected!")
                ;; Immediately send active node snapshot if one is already focused
                (when org-writenotes--active-node-id
                  (let ((loc (org-writenotes--locate-node org-writenotes--active-node-id)))
                    (when loc
                      (with-current-buffer (car loc)
                        (save-excursion
                          (goto-char (cdr loc))
                          (org-writenotes--ws-send-json
                           proc
                           `(:jsonrpc "2.0"
                             :method "emacs.focusNode"
                             :params ,(org-writenotes--parse-subtree-at-point)))))))))
            (delete-process proc)))))
    ;; Decode RFC 6455 frames once upgraded
    (when (and (process-live-p proc) (process-get proc :ws-upgraded))
      (let ((continue t))
        (while continue
          (let ((decoded (org-writenotes--ws-try-decode-frame buf)))
            (if (not decoded)
                (setq continue nil)
              (let ((opcode (nth 0 decoded))
                    (payload (nth 1 decoded))
                    (rem (nth 2 decoded)))
                (setq buf (string-as-unibyte rem))
                (cond
                 ((= opcode 1) ;; Text frame
                  (org-writenotes--dispatch-rpc proc payload))
                 ((= opcode 8) ;; Close frame
                  (setq org-writenotes--clients (delq proc org-writenotes--clients))
                  (ignore-errors (process-send-string proc (unibyte-string #x88 0)))
                  (delete-process proc)
                  (setq continue nil))
                 ((= opcode 9) ;; Ping -> Pong (echo unibyte payload, max 125 bytes per RFC 6455)
                  (let* ((raw-pong (string-as-unibyte payload))
                         (pong-bytes (if (> (length raw-pong) 125)
                                         (substring raw-pong 0 125)
                                       raw-pong))
                         (pong-len (length pong-bytes)))
                    (process-send-string
                     proc
                     (concat (unibyte-string #x8a pong-len) pong-bytes)))))))))))
    (when (process-live-p proc)
      (process-put proc :recv-buf buf))))

(defun org-writenotes--client-sentinel (proc event)
  "Clean up disconnected client PROC on EVENT."
  (when (string-match-p "\\(deleted\\|connection broken\\|closed\\)" event)
    (setq org-writenotes--clients (delq proc org-writenotes--clients))
    (message "[Org-WriteNotes] Tablet disconnected.")))

;;; ---------------------------------------------------------------------------
;;; Interactive Commands & Minor Mode
;;; ---------------------------------------------------------------------------

(defun org-writenotes--ensure-adb-reverse-async (&optional verbose)
  "Asynchronously run `adb reverse tcp:PORT tcp:PORT' without blocking Emacs.
When VERBOSE is non-nil, report the outcome."
  (when (and org-writenotes-adb-executable
             (not (and org-writenotes--adb-proc
                       (process-live-p org-writenotes--adb-proc))))
    (let ((port-spec (format "tcp:%d" org-writenotes-port)))
      (condition-case nil
          (setq org-writenotes--adb-proc
                (make-process
                 :name "org-writenotes-adb-reverse"
                 :command (list org-writenotes-adb-executable "reverse" port-spec port-spec)
                 :noquery t
                 :sentinel
                 (lambda (proc _event)
                   (when (and verbose (eq (process-status proc) 'exit))
                     (if (= (process-exit-status proc) 0)
                         (message "[Org-WriteNotes] ADB USB tunnel ready on localhost:%d!"
                                  org-writenotes-port)
                       (message "[Org-WriteNotes] Server running on port %d (waiting for USB ADB device...)"
                                org-writenotes-port))))))
        (error nil)))))

(defun org-writenotes--adb-watchdog-tick ()
  "Periodically ensure server is running and `adb reverse' is active when no client is connected."
  (setq org-writenotes--clients
        (cl-remove-if-not #'process-live-p org-writenotes--clients))
  (when (and org-writenotes--server-proc
             (process-live-p org-writenotes--server-proc)
             (null org-writenotes--clients))
    (org-writenotes--ensure-adb-reverse-async nil)))

(defun org-writenotes--start-adb-watchdog ()
  "Start the periodic ADB reverse tunnel watchdog timer."
  (when (timerp org-writenotes--adb-watchdog-timer)
    (cancel-timer org-writenotes--adb-watchdog-timer))
  (when (and (integerp org-writenotes-adb-watchdog-interval)
             (> org-writenotes-adb-watchdog-interval 0))
    (setq org-writenotes--adb-watchdog-timer
          (run-with-timer 2 org-writenotes-adb-watchdog-interval
                          #'org-writenotes--adb-watchdog-tick))))

(defun org-writenotes--ensure-server-and-adb ()
  "Ensure the WebSocket server is listening and ADB reverse forwarding is active."
  (unless (and org-writenotes--server-proc
               (process-live-p org-writenotes--server-proc))
    (org-writenotes-start-server))
  (unless (timerp org-writenotes--adb-watchdog-timer)
    (org-writenotes--start-adb-watchdog))
  (setq org-writenotes--clients
        (cl-remove-if-not #'process-live-p org-writenotes--clients))
  (when (null org-writenotes--clients)
    (org-writenotes--ensure-adb-reverse-async nil)))

;;;###autoload
(defun org-writenotes-start-server ()
  "Start the Org-WriteNotes WebSocket JSON-RPC server."
  (interactive)
  (org-writenotes-enable-svgz-inline-images)
  (when (and org-writenotes--server-proc
             (process-live-p org-writenotes--server-proc))
    (delete-process org-writenotes--server-proc))
  (unless org-writenotes--session-token
    (setq org-writenotes--session-token
          (substring (secure-hash 'sha256 (format "%s-%s" (random) (current-time-string))) 0 32)))
  (setq org-writenotes--server-proc
        (make-network-process
         :name "org-writenotes-server"
         :server t
         :host org-writenotes-host
         :service org-writenotes-port
         :family 'ipv4
         :coding 'binary
         :noquery t
         :filter #'org-writenotes--client-filter
         :sentinel #'org-writenotes--client-sentinel))
  (org-writenotes--start-adb-watchdog)
  (org-writenotes--ensure-adb-reverse-async nil)
  (message "[Org-WriteNotes] Server listening on ws://%s:%d"
           org-writenotes-host org-writenotes-port))

;;;###autoload
(defun org-writenotes-stop-server ()
  "Stop the Org-WriteNotes server and disconnect clients."
  (interactive)
  (when (timerp org-writenotes--adb-watchdog-timer)
    (cancel-timer org-writenotes--adb-watchdog-timer)
    (setq org-writenotes--adb-watchdog-timer nil))
  (dolist (c org-writenotes--clients)
    (when (process-live-p c) (delete-process c)))
  (setq org-writenotes--clients nil)
  (when (and org-writenotes--server-proc
             (process-live-p org-writenotes--server-proc))
    (delete-process org-writenotes--server-proc))
  (setq org-writenotes--server-proc nil)
  (message "[Org-WriteNotes] Server stopped."))

;;;###autoload
(defun org-writenotes-connect-adb ()
  "Start the server and configure `adb reverse' for zero-config USB tablet pairing."
  (interactive)
  (unless (and org-writenotes--server-proc
               (process-live-p org-writenotes--server-proc))
    (org-writenotes-start-server))
  (org-writenotes--ensure-adb-reverse-async t))

;;;###autoload
(defun org-writenotes-pair-qr ()
  "Display a LAN / Tailscale pairing QR code and JSON payload for wireless tablet connection."
  (interactive)
  (let ((org-writenotes-host "0.0.0.0"))
    (unless (and org-writenotes--server-proc
                 (process-live-p org-writenotes--server-proc))
      (org-writenotes-start-server)))
  (let* ((lan-ip (string-trim
                  (shell-command-to-string
                   "hostname -I 2>/dev/null | awk '{print $1}'")))
         (ip (if (string-empty-p lan-ip) "127.0.0.1" lan-ip))
         (ws-url (format "ws://%s:%d" ip org-writenotes-port))
         (qr-json (json-serialize
                   `(:v 1 :url ,ws-url :token ,(or org-writenotes--session-token ""))))
         (buf (get-buffer-create "*Org-WriteNotes Pairing*")))
    (with-current-buffer buf
      (read-only-mode -1)
      (erase-buffer)
      (insert "=== Org-WriteNotes Wireless LAN / Tailscale Pairing ===\n\n")
      (insert (format "WebSocket URL : %s\n" ws-url))
      (insert (format "Session Token : %s\n" (or org-writenotes--session-token "")))
      (insert (format "QR Payload    : %s\n\n" qr-json))
      (when (executable-find "qrencode")
        (insert (shell-command-to-string
                 (format "qrencode -t UTF8 %s" (shell-quote-argument qr-json))))
        (insert "\n"))
      (read-only-mode 1))
    (pop-to-buffer buf)))

;;;###autoload
(defun org-writenotes-push-node ()
  "Push the Org subtree at point to the connected Android tablet."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org-mode buffer"))
  (org-writenotes--ensure-server-and-adb)
  (save-excursion
    (org-back-to-heading t)
    (setq org-writenotes--active-node-id (org-writenotes--node-id-at-point t))
    (setq org-writenotes--last-followed-node org-writenotes--active-node-id)
    (let ((snapshot (org-writenotes--parse-subtree-at-point)))
      (org-writenotes--broadcast-notification "emacs.focusNode" snapshot)
      (message "[Org-WriteNotes] Pushed node '%s' to tablet."
               (plist-get (plist-get snapshot :header) :title)))))

;;;###autoload
(defun org-writenotes-insert-sketch ()
  "Insert a new `.svgz' handwritten sketch block at point and open it on the tablet."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org-mode buffer"))
  (org-writenotes--ensure-server-and-adb)
  (let ((cursor-pos (point)))
    (save-excursion
      (org-back-to-heading t)
      (let* ((node-id (org-writenotes--node-id-at-point t))
             (beg (point))
             (sub-end (save-excursion (org-end-of-subtree t t) (point)))
             (body-end (org-writenotes--body-end-pos beg sub-end))
             (body-start (save-excursion (org-writenotes--goto-body-start beg body-end) (point)))
             (after-line (cond
                          ((< cursor-pos body-start) 0)
                          ((< cursor-pos body-end) (line-number-at-pos cursor-pos))
                          (t nil)))
             (params (if after-line
                         `((nodeId . ,node-id) (afterLine . ,after-line))
                       `((nodeId . ,node-id)))))
        (org-writenotes--handle-insert-ink-block params)
        (message "[Org-WriteNotes] Created .svgz sketch and pushed to tablet!")))))

;;;###autoload
(defun org-writenotes-delete-sketch-at-point ()
  "Delete the `.svgz' handwritten sketch under point, its link in the buffer, and file on disk."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org-mode buffer"))
  (let* ((line-beg (line-beginning-position))
         (line-end (line-end-position))
         (line-str (buffer-substring-no-properties line-beg line-end))
         (matched (string-match "\\[\\[\\(?:file:\\|attachment:\\)?\\([^]\n]+\\.svgz?\\)\\(?:\\]\\[[^]\n]*\\)?\\]\\]" line-str)))
    (unless matched
      (user-error "No .svgz sketch link found on current line"))
    (let* ((m-beg (match-beginning 0))
           (m-end (match-end 0))
           (rel-path (match-string 1 line-str))
           (filename (file-name-nondirectory rel-path))
           (link-beg (+ line-beg m-beg))
           (link-end (+ line-beg m-end))
           (org-file (buffer-file-name))
           (img-dir (org-writenotes--resolve-image-dir org-file))
           (abs-path (expand-file-name filename img-dir)))
      (when (yes-or-no-p (format "Delete sketch image '%s' and remove file from disk? " filename))
        (goto-char link-beg)
        (let ((trimmed (string-trim line-str)))
          (if (string= trimmed (buffer-substring-no-properties link-beg link-end))
              (if (< line-end (point-max))
                  (delete-region line-beg (1+ line-end))
                (delete-region (if (> line-beg (point-min)) (1- line-beg) line-beg) line-end))
            (delete-region link-beg link-end)))
        ;; Remove any immediately following :WRITENOTES_OCR: drawer or OCR heading
        (org-writenotes--remove-associated-ocr-at-point filename)
        (when (file-exists-p abs-path)
          (ignore-errors (delete-file abs-path)))
        (save-buffer)
        (org-writenotes--refresh-inline-image abs-path)
        (save-excursion
          (when (org-back-to-heading t)
            (let ((snapshot (org-writenotes--parse-subtree-at-point)))
              (org-writenotes--broadcast-notification "emacs.focusNode" snapshot))))
        (message "[Org-WriteNotes] Deleted sketch '%s'." filename)))))

;;;###autoload
(defun org-writenotes-open-sketch-at-point ()
  "Push the current Org subtree and open the `.svgz' sketch on the current line zoomed on the tablet."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org-mode buffer"))
  (let* ((line-str (buffer-substring-no-properties (line-beginning-position) (line-end-position)))
         (matched (string-match "\\[\\[\\(?:file:\\|attachment:\\)?\\([^]\n]+\\.svgz?\\)\\(?:\\]\\[[^]\n]*\\)?\\]\\]" line-str)))
    (unless matched
      (user-error "No .svgz sketch link found on current line"))
    (let ((filename (file-name-nondirectory (match-string 1 line-str))))
      (org-writenotes--ensure-server-and-adb)
      (save-excursion
        (org-back-to-heading t)
        (setq org-writenotes--active-node-id (org-writenotes--node-id-at-point t))
        (let ((snapshot (org-writenotes--parse-subtree-at-point)))
          (org-writenotes--broadcast-notification "emacs.focusNode" snapshot)
          (org-writenotes--broadcast-notification
           "emacs.zoomInkBlock"
           `(:nodeId ,(plist-get snapshot :nodeId)
             :fileName ,filename
             :snapshot ,snapshot))
          (message "[Org-WriteNotes] Opened '%s' in full-screen editor on tablet." filename))))))

(defun org-writenotes--open-at-point-h ()
  "Hook for `org-open-at-point-functions' to open `.svgz' links directly on the connected tablet."
  (when (and (derived-mode-p 'org-mode)
             org-writenotes--clients)
    (let ((line-str (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
      (when (string-match-p "\\[\\[\\(?:file:\\|attachment:\\)?\\([^]\n]+\\.svgz?\\)\\(?:\\]\\[[^]\n]*\\)?\\]\\]" line-str)
        (org-writenotes-open-sketch-at-point)
        t))))

;;;###autoload
(defun org-writenotes-annotate-image-at-point (&optional image-path)
  "Wrap an image link at point (or IMAGE-PATH) in a new `.svgz' sketch.
The image becomes a background layer and the sketch opens on the
connected tablet for stylus annotation."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org-mode buffer"))
  (org-writenotes--ensure-server-and-adb)
  (let* ((org-file (buffer-file-name))
         (line-str (buffer-substring-no-properties (line-beginning-position) (line-end-position)))
         (detected-path
          (when (string-match "\\[\\[\\(?:file:\\|attachment:\\)?\\([^]\n]+\\.\\(?:png\\|jpe?g\\|webp\\|gif\\)\\)\\(?:\\]\\[[^]\n]*\\)?\\]\\]" line-str)
            (expand-file-name (match-string 1 line-str)
                              (if org-file (file-name-directory org-file) default-directory))))
         (src-path (or image-path
                       detected-path
                       (read-file-name "Image to annotate: " nil nil t))))
    (unless (and src-path (file-exists-p src-path))
      (user-error "Image file not found: %s" src-path))
    (save-excursion
      (org-back-to-heading t)
      (let* ((node-id (org-writenotes--node-id-at-point t))
             (title (or (nth 4 (org-heading-components)) "annotation"))
             (slug (org-writenotes--slugify title))
             (timestamp (format-time-string "%Y%m%d-%H%M%S"))
             (filename (format "%s-annotated-%s.svgz" slug timestamp))
             (img-dir (org-writenotes--resolve-image-dir org-file))
             (abs-path (expand-file-name filename img-dir))
             (link-str (org-writenotes--format-file-link org-file filename))
             (ext (downcase (or (file-name-extension src-path) "png")))
             (mime (cond
                    ((member ext '("jpg" "jpeg")) "image/jpeg")
                    ((string= ext "webp") "image/webp")
                    ((string= ext "gif") "image/gif")
                    (t "image/png")))
             (img-b64 (org-writenotes--file-to-base64 src-path))
             (w org-writenotes-default-canvas-width)
             (h org-writenotes-default-canvas-height)
             (svg-xml
              (format (concat "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\n"
                              "<svg xmlns=\"http://www.w3.org/2000/svg\" "
                              "xmlns:xlink=\"http://www.w3.org/1999/xlink\" "
                              "width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\">\n"
                              "<svg class=\"write-doc\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\">\n"
                              "<g class=\"write-page\" width=\"%d\" height=\"%d\" xruling=\"0\" yruling=\"0\" marginLeft=\"0\" color=\"#FFFFFFFF\">\n"
                              "<rect class=\"write-background\" x=\"0\" y=\"0\" width=\"%d\" height=\"%d\" fill=\"#FFFFFF\"/>\n"
                              "<image class=\"write-template-image\" x=\"20\" y=\"20\" width=\"%d\" height=\"%d\" preserveAspectRatio=\"xMidYMid meet\" href=\"data:%s;base64,%s\" xlink:href=\"data:%s;base64,%s\"/>\n"
                              "</g>\n"
                              "<g class=\"write-content\">\n"
                              "</g>\n"
                              "</svg>\n"
                              "</svg>\n")
                      w h w h w h w h w h w h (- w 40) (- h 40) mime img-b64 mime img-b64)))
        (org-writenotes--write-svgz-xml abs-path svg-xml)
        (end-of-line)
        (insert (format "\n\n%s\n" link-str))
        (save-buffer)
        (org-writenotes--refresh-inline-image abs-path)
        (setq org-writenotes--active-node-id node-id)
        (let ((snapshot (org-writenotes--parse-subtree-at-point)))
          (org-writenotes--broadcast-notification "emacs.focusNode" snapshot)
          (org-writenotes--broadcast-notification
           "emacs.zoomInkBlock"
           `(:nodeId ,node-id :fileName ,filename :snapshot ,snapshot))
          (message "[Org-WriteNotes] Created annotated sketch '%s' and opened on tablet!" filename))))))

;;;###autoload
(defun org-writenotes-gallery ()
  "Open an interactive gallery buffer of all `.svgz' sketches with parent heading links."
  (interactive)
  (let* ((gallery-res (org-writenotes--handle-list-gallery nil))
         (sketches (append (plist-get gallery-res :sketches) nil))
         (buf (get-buffer-create "*Org-WriteNotes Gallery*")))
    (with-current-buffer buf
      (read-only-mode -1)
      (erase-buffer)
      (org-mode)
      (insert "#+TITLE: Org-WriteNotes Sketch Gallery\n\n")
      (if (null sketches)
          (insert "No `.svgz` sketches found in `org-writenotes-image-dir`.\n")
        (dolist (item sketches)
          (let ((fname (plist-get item :fileName))
                (fpath (plist-get item :filePath))
                (nid (plist-get item :nodeId))
                (ntitle (plist-get item :nodeTitle))
                (mtime (plist-get item :modifiedTime))
                (w (plist-get item :width))
                (h (plist-get item :height)))
            (insert (format "* %s (%s)\n" ntitle fname))
            (insert (format "  - Modified: %s | Size: %dx%d\n" mtime w h))
            (when (and nid (not (eq nid :null)))
              (insert (format "  - Node ID: [[id:%s][Jump to Heading (%s)]]\n" nid ntitle)))
            (insert (format "  [[file:%s]]\n\n" fpath)))))
      (goto-char (point-min))
      (ignore-errors (org-display-inline-images t t))
      (read-only-mode 1))
    (pop-to-buffer buf)))

;;;###autoload
(defun org-writenotes-clean-orphans ()
  "Scan `.org' files in the current directory for referenced `.svgz' sketches and offer to clean up orphans."
  (interactive)
  (let* ((org-file (or (buffer-file-name) (expand-file-name "dummy.org" default-directory)))
         (base-dir (file-name-directory (expand-file-name org-file)))
         (img-dir (org-writenotes--resolve-image-dir org-file))
         (all-svgz (when (file-directory-p img-dir)
                     (directory-files img-dir nil "\\.svgz\\'" t)))
         (org-files (directory-files-recursively base-dir "\\.org\\'" nil))
         (referenced (make-hash-table :test 'equal)))
    (dolist (f org-files)
      (with-temp-buffer
        (insert-file-contents f)
        (goto-char (point-min))
        (while (re-search-forward "\\[\\[\\(?:file:\\|attachment:\\)\\([^]\n]+\\.svgz?\\)\\(?:\\]\\[[^]\n]*\\)?\\]\\]" nil t)
          (puthash (file-name-nondirectory (match-string 1)) t referenced))))
    (let ((orphans (cl-remove-if (lambda (fname) (gethash fname referenced)) all-svgz)))
      (if (null orphans)
          (message "[Org-WriteNotes] All %d .svgz sketches in %s are referenced!" (length all-svgz) img-dir)
        (when (yes-or-no-p
               (format "Found %d orphaned .svgz sketch(es) in %s (%s).  Move them to .trash/? "
                       (length orphans)
                       img-dir
                       (mapconcat #'identity (cl-subseq orphans 0 (min 4 (length orphans))) ", ")))
          (let ((trash-dir (expand-file-name ".trash" img-dir)))
            (unless (file-directory-p trash-dir)
              (make-directory trash-dir t))
            (dolist (fname orphans)
              (rename-file (expand-file-name fname img-dir)
                           (expand-file-name fname trash-dir)
                           t))
            (message "[Org-WriteNotes] Moved %d orphaned sketch(es) to %s."
                     (length orphans) trash-dir)))))))

(defvar org-writenotes--last-followed-node nil)

(defun org-writenotes--follow-post-command ()
  "Automatically push the Org node at point when moving between headings."
  (condition-case err
      (when (and (derived-mode-p 'org-mode)
                 org-writenotes--clients
                 (save-excursion (ignore-errors (org-back-to-heading t))))
        (let ((nid (save-excursion (ignore-errors (org-writenotes--node-id-at-point)))))
          (when (and nid (not (equal nid org-writenotes--last-followed-node)))
            (setq org-writenotes--last-followed-node nid)
            (save-excursion
              (org-back-to-heading t)
              (setq org-writenotes--active-node-id nid)
              (let ((snapshot (org-writenotes--parse-subtree-at-point t)))
                (setq org-writenotes--last-active-etag (plist-get snapshot :etag))
                (org-writenotes--broadcast-notification "emacs.focusNode" snapshot))))))
    (error
     (message "[Org-WriteNotes] follow-mode warning: %s" (error-message-string err)))))

(defun org-writenotes--change-debounce-tick ()
  "Check if the active Org node's `:etag' changed and broadcast `emacs.nodeModified'."
  (setq org-writenotes--change-debounce-timer nil)
  (when (and org-writenotes--clients
             org-writenotes--active-node-id)
    (let ((loc (org-writenotes--locate-node org-writenotes--active-node-id)))
      (when loc
        (with-current-buffer (car loc)
          (save-excursion
            (goto-char (cdr loc))
            (let* ((snapshot (org-writenotes--parse-subtree-at-point t))
                   (new-etag (plist-get snapshot :etag)))
              (when (and new-etag (not (equal new-etag org-writenotes--last-active-etag)))
                (setq org-writenotes--last-active-etag new-etag)
                (org-writenotes--broadcast-notification "emacs.nodeModified" snapshot)))))))))

(defun org-writenotes--on-buffer-changed (_beg _end _len)
  "Debounced `after-change-functions' hook to broadcast live edits in the focused Org node."
  (when (and org-writenotes--clients
             (derived-mode-p 'org-mode)
             org-writenotes--active-node-id)
    (when (timerp org-writenotes--change-debounce-timer)
      (cancel-timer org-writenotes--change-debounce-timer))
    (setq org-writenotes--change-debounce-timer
          (run-with-idle-timer 0.6 nil #'org-writenotes--change-debounce-tick))))

(defun org-writenotes--on-buffer-saved ()
  "Broadcast `emacs.nodeModified' if the currently focused Org node was modified."
  (when (and org-writenotes--clients
             (derived-mode-p 'org-mode)
             org-writenotes--active-node-id)
    (let ((loc (org-writenotes--locate-node org-writenotes--active-node-id)))
      (when (and loc (eq (car loc) (current-buffer)))
        (save-restriction
          (widen)
          (save-excursion
            (goto-char (cdr loc))
            (org-back-to-heading t)
            (let ((snapshot (org-writenotes--parse-subtree-at-point)))
              (setq org-writenotes--last-active-etag (plist-get snapshot :etag))
              (org-writenotes--broadcast-notification "emacs.nodeModified" snapshot))))))))

;;;###autoload
(define-minor-mode org-writenotes-follow-mode
  "Minor mode to automatically sync the tablet view with the Org heading at point."
  :global t
  :lighter " [OrgWrite✍️]"
  (if org-writenotes-follow-mode
      (progn
        (org-writenotes--ensure-server-and-adb)
        (add-hook 'post-command-hook #'org-writenotes--follow-post-command)
        (add-hook 'after-change-functions #'org-writenotes--on-buffer-changed)
        (add-hook 'after-save-hook #'org-writenotes--on-buffer-saved)
        (org-writenotes--register-theme-hooks))
    (remove-hook 'post-command-hook #'org-writenotes--follow-post-command)
    (remove-hook 'after-change-functions #'org-writenotes--on-buffer-changed)
    (remove-hook 'after-save-hook #'org-writenotes--on-buffer-saved)))

(org-writenotes-enable-svgz-inline-images)

(when org-writenotes-auto-start
  (ignore-errors
    (org-writenotes--ensure-server-and-adb)))

(provide 'org-writenotes)
;; Extended roadmap features (docs/roadmap-extended.md), loaded via advice.
(require 'org-writenotes-extras nil t)
;;; org-writenotes.el ends here
