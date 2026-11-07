;;; org-writenotes-extras.el --- Extended roadmap features for Org-WriteNotes -*- lexical-binding: t; -*-

;; Author: Org-WriteNotes Contributors
;; Version: 0.2.0
;; Package-Requires: ((emacs "28.1") (org "9.5") (org-writenotes "0.1.0"))
;; Keywords: outlines, hypermedia, tools
;; URL: https://github.com/styluslabs/Write

;;; Commentary:
;; Implements items from docs/roadmap-extended.md without touching the core
;; dispatch code, by advising core functions:
;;   A1 atomic writes, A2 sketch history + ink.history/ink.revert,
;;   A3 etag conflict copies, A4 protocol version/capabilities,
;;   A5 unchanged-commit dedupe, A6 auth rate limiting,
;;   C1 minor mode + transient menu, C4 link repair, C7 ox-html inlining.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'org-element)
(require 'json)
(require 'org-writenotes)

;;; A4: Protocol versioning ---------------------------------------------------

(defconst org-writenotes-protocol-version 2
  "Wire protocol version spoken by this Emacs server.")

(defconst org-writenotes--capabilities
  ["ink.commit.etag" "ink.commit.dedupe" "ink.history" "ink.revert" "ink.resolveConflict"
    "auth.ratelimit"]
  "Capabilities advertised to clients in `session.hello'.")

(defcustom org-writenotes-max-auth-failures 5
  "Failed `session.hello' token attempts allowed before a client is dropped."
  :type 'integer :group 'org-writenotes)

(defcustom org-writenotes-sketch-history-min-interval 30
  "Minimum seconds between history snapshots of the same sketch."
  :type 'integer :group 'org-writenotes)

(defcustom org-writenotes-sketch-history-depth 20
  "Number of historical snapshots kept per sketch in `.history/'.  0 disables."
  :type 'integer :group 'org-writenotes)

;;; A1: Atomic writes ---------------------------------------------------------

(defun org-writenotes--write-raw-bytes-atomic (filepath raw-bytes)
  "Atomically write unibyte RAW-BYTES to FILEPATH (temp file + rename)."
  (let ((file-name-handler-alist nil)
        (coding-system-for-write 'no-conversion)
        (write-region-inhibit-fsync nil)
        (tmp (make-temp-name (concat filepath ".tmp-"))))
    (make-directory (file-name-directory filepath) t)
    (unwind-protect
        (progn
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (insert (if (multibyte-string-p raw-bytes)
                        (encode-coding-string raw-bytes 'raw-text)
                      raw-bytes))
            (write-region (point-min) (point-max) tmp nil 'silent))
          (rename-file tmp filepath t))
      (when (file-exists-p tmp) (ignore-errors (delete-file tmp))))))

(advice-add 'org-writenotes--write-raw-bytes :override
            #'org-writenotes--write-raw-bytes-atomic)

;;; A2: Sketch version history ------------------------------------------------

(defun org-writenotes--history-dir (abs-path)
  "Return the history directory for sketch ABS-PATH."
  (expand-file-name ".history" (file-name-directory abs-path)))

(defun org-writenotes--list-snapshots (abs-path)
  "Return snapshot paths for ABS-PATH, newest first."
  (let ((dir (org-writenotes--history-dir abs-path)))
    (when (file-directory-p dir)
      (sort (directory-files
             dir t (concat "\\`" (regexp-quote (file-name-nondirectory abs-path))
                           "\\.[0-9T]+\\'"))
            #'string>))))

(defun org-writenotes--snapshot-sketch (abs-path &optional force)
  "Copy existing ABS-PATH into history and prune to the configured depth.
If FORCE is non-nil, create a snapshot regardless of interval."
  (when (and (> org-writenotes-sketch-history-depth 0)
             (file-exists-p abs-path)
             (let ((newest (car (org-writenotes--list-snapshots abs-path))))
               (or force (null newest)
                   (>= (float-time (time-since (file-attribute-modification-time
                                                (file-attributes newest))))
                       org-writenotes-sketch-history-min-interval))))
    (let* ((dir (org-writenotes--history-dir abs-path))
           (dest (expand-file-name
                  (format "%s.%s" (file-name-nondirectory abs-path)
                          (format-time-string "%Y%m%dT%H%M%S%3N"))
                  dir))
           (file-name-handler-alist nil))
      (make-directory dir t)
      (copy-file abs-path dest t)
      (dolist (old (nthcdr org-writenotes-sketch-history-depth
                           (org-writenotes--list-snapshots abs-path)))
        (ignore-errors (delete-file old))))))

(defun org-writenotes--file-etag (abs-path)
  "Return sha1 of raw bytes at ABS-PATH, or nil if missing."
  (when (file-exists-p abs-path)
    (secure-hash 'sha1 (org-writenotes--read-raw-bytes abs-path))))

(defun org-writenotes--resolve-sketch-path (params)
  "Resolve absolute sketch path from nodeId/fileName in PARAMS."
  (let* ((loc (org-writenotes--locate-node (alist-get 'nodeId params)))
         (org-file (when loc (buffer-file-name (car loc)))))
    (expand-file-name (file-name-nondirectory (alist-get 'fileName params))
                      (org-writenotes--resolve-image-dir org-file))))

(defun org-writenotes--handle-ink-history (params)
  "Return snapshot names for the sketch in PARAMS."
  (let ((abs (org-writenotes--resolve-sketch-path params)))
    `(:snapshots ,(vconcat (mapcar #'file-name-nondirectory
                                   (org-writenotes--list-snapshots abs))))))

(defun org-writenotes--restore-snapshot (abs snap)
  "Restore snapshot file SNAP over sketch ABS; return restored bytes."
  (unless (file-exists-p snap) (error "Snapshot not found: %s" snap))
  (let ((bytes (org-writenotes--read-raw-bytes snap)))
    (org-writenotes--snapshot-sketch abs t)
    (remhash abs org-writenotes--live-svg-cache)
    (org-writenotes--write-raw-bytes abs bytes)
    (org-writenotes--refresh-inline-image abs)
    bytes))

(defun org-writenotes--handle-ink-revert (params)
  "Restore the `snapshot' in PARAMS over its sketch; return new bytes + etag."
  (let* ((abs (org-writenotes--resolve-sketch-path params))
         (snap (expand-file-name (file-name-nondirectory (alist-get 'snapshot params))
                                 (org-writenotes--history-dir abs)))
         (bytes (org-writenotes--restore-snapshot abs snap)))
    `(:svgzBase64 ,(base64-encode-string bytes t)
      :etag ,(secure-hash 'sha1 bytes))))

;;; A3: conflict resolution from the tablet -------------------------------------

(defun org-writenotes--conflict-copies (abs)
  "Return the `*.conflict-*.svgz' copies of sketch ABS, newest first."
  (let ((dir (file-name-directory abs))
        (base (file-name-nondirectory (file-name-sans-extension abs))))
    (when (file-directory-p dir)
      (sort (directory-files
             dir t (concat "\\`" (regexp-quote base) "\\.conflict-[0-9T]+\\.svgz\\'"))
            #'string>))))

(defun org-writenotes--conflict-copy-path (abs params)
  "Return the conflict copy of ABS named by `conflictFile' in PARAMS (default newest)."
  (let* ((copies (org-writenotes--conflict-copies abs))
         (wanted (alist-get 'conflictFile params))
         (hit (if wanted
                  (cl-find (file-name-nondirectory wanted) copies
                           :key #'file-name-nondirectory :test #'equal)
                (car copies))))
    (or hit (error "No conflict copy for %s" (file-name-nondirectory abs)))))

(defun org-writenotes--handle-ink-conflict-info (params)
  "Return both versions of the conflicted sketch in PARAMS for side-by-side review."
  (let* ((abs (org-writenotes--resolve-sketch-path params))
         (copy (org-writenotes--conflict-copy-path abs params)))
    (unless (file-exists-p abs) (error "Sketch not found: %s" (file-name-nondirectory abs)))
    `(:fileName ,(file-name-nondirectory abs)
      :conflictFile ,(file-name-nondirectory copy)
      :conflictCount ,(length (org-writenotes--conflict-copies abs))
      :emacsSvgzBase64 ,(base64-encode-string (org-writenotes--read-raw-bytes abs) t)
      :tabletSvgzBase64 ,(base64-encode-string (org-writenotes--read-raw-bytes copy) t)
      :etag ,(org-writenotes--file-etag abs))))

(defun org-writenotes--retire-conflict-copy (abs copy)
  "Move conflict COPY of ABS into its `.history/' directory instead of deleting it."
  (let ((dir (org-writenotes--history-dir abs))
        (file-name-handler-alist nil))
    (make-directory dir t)
    (rename-file copy (expand-file-name (file-name-nondirectory copy) dir) t)))

(defun org-writenotes--handle-ink-resolve-conflict (params)
  "Resolve a sketch conflict: `choice' is \"emacs\", \"tablet\" or \"merged\".
\"merged\" writes the `svgzBase64' in PARAMS (the tablet's stroke union).  The
previous file is snapshotted and the conflict copy moved into `.history/'."
  (let* ((abs (org-writenotes--resolve-sketch-path params))
         (copy (org-writenotes--conflict-copy-path abs params))
         (choice (alist-get 'choice params))
         (bytes (pcase choice
                  ("emacs" nil)
                  ("tablet" (org-writenotes--read-raw-bytes copy))
                  ("merged" (base64-decode-string
                             (or (alist-get 'svgzBase64 params) (error "Missing svgzBase64"))))
                  (_ (error "Unknown choice: %s" choice)))))
    (when bytes
      (org-writenotes--snapshot-sketch abs t)
      (remhash abs org-writenotes--live-svg-cache)
      (org-writenotes--write-raw-bytes abs bytes)
      (org-writenotes--refresh-inline-image abs))
    (org-writenotes--retire-conflict-copy abs copy)
    (let ((final (org-writenotes--read-raw-bytes abs)))
      `(:svgzBase64 ,(base64-encode-string final t)
        :etag ,(secure-hash 'sha1 final)
        :remainingConflicts ,(length (org-writenotes--conflict-copies abs))))))

(defun org-writenotes--svgz-link-at-point ()
  "Return absolute path of the `.svgz' file link at point, or nil."
  (let ((ctx (org-element-context)))
    (when (eq (org-element-type ctx) 'link)
      (let ((p (org-element-property :path ctx)))
        (when (and p (string-suffix-p ".svgz" p))
          (expand-file-name p))))))

;;;###autoload
(defun org-writenotes-revert-sketch-at-point ()
  "Restore a historical snapshot of the `.svgz' link at point."
  (interactive)
  (let* ((path (or (org-writenotes--svgz-link-at-point)
                   (user-error "No .svgz link at point")))
         (snaps (or (org-writenotes--list-snapshots path)
                    (user-error "No history for %s" (file-name-nondirectory path))))
         (choice (completing-read "Revert to: " (mapcar #'file-name-nondirectory snaps) nil t)))
    (org-writenotes--restore-snapshot
     path (expand-file-name choice (org-writenotes--history-dir path)))
    (message "Reverted %s to %s" (file-name-nondirectory path) choice)))

;;; A3 / A5: etag-aware ink.commit -----------------------------------------------

(defun org-writenotes--ink-commit-around (orig params)
  "Wrap ORIG `ink.commit' handler with dedupe, conflict detection and history.
PARAMS is the RPC parameter alist."
  (let* ((b64 (alist-get 'svgzBase64 params))
         (abs (and (alist-get 'fileName params) b64
                   (org-writenotes--resolve-sketch-path params)))
         (new-bytes (and abs (base64-decode-string b64)))
         (new-etag (and new-bytes (secure-hash 'sha1 new-bytes)))
         (disk-etag (and abs (org-writenotes--file-etag abs)))
         (base-etag (alist-get 'baseEtag params)))
    (cond
     ((null abs) (funcall orig params))
     ;; A5: identical bytes -> no-op (OCR drawer still updated by orig if text given)
     ((and disk-etag (equal disk-etag new-etag) (not (alist-get 'ocrText params)))
      `(:savedPath ,abs :bytesWritten 0 :etag ,new-etag :unchanged t))
     ;; A3: file changed since the client last saw it -> keep both copies
     ((and (stringp base-etag) disk-etag (not (equal base-etag disk-etag)))
      (let ((conflict (format "%s.conflict-%s.svgz" (file-name-sans-extension abs)
                              (format-time-string "%Y%m%dT%H%M%S"))))
        (org-writenotes--write-raw-bytes conflict new-bytes)
        (message "org-writenotes: conflict on %s, tablet copy saved as %s"
                 (file-name-nondirectory abs) (file-name-nondirectory conflict))
        `(:savedPath ,conflict :conflict t :etag ,disk-etag
          :bytesWritten ,(length new-bytes))))
     (t
      (unless (equal disk-etag new-etag) (org-writenotes--snapshot-sketch abs))
      (append (let ((org-writenotes--decoded-b64 (cons b64 new-bytes)))
                (funcall orig params))
              `(:etag ,new-etag))))))

(advice-add 'org-writenotes--handle-ink-commit :around
            #'org-writenotes--ink-commit-around)

;;; A4 / A6 + new RPC methods via dispatch advice --------------------------------

(defconst org-writenotes--extra-rpc-methods
  `(("ink.history" . org-writenotes--handle-ink-history)
    ("ink.revert"  . org-writenotes--handle-ink-revert)
    ("ink.conflictInfo" . org-writenotes--handle-ink-conflict-info)
    ("ink.resolveConflict" . org-writenotes--handle-ink-resolve-conflict)
    ("node.flagFlashcard" . org-writenotes--handle-flag-flashcard)
    ("presence.list" . org-writenotes--handle-presence-list))
  "Additional JSON-RPC methods handled by this module.")

(defun org-writenotes--dispatch-rpc-around (orig proc msg-text)
  "Handle extra methods and augment `session.hello' before calling ORIG.
PROC is the client process and MSG-TEXT the raw message."
  (let* ((req (ignore-errors (org-writenotes--read-rpc-json msg-text)))
         (id (alist-get 'id req))
         (method (alist-get 'method req))
         (params (alist-get 'params req))
         (extra (assoc method org-writenotes--extra-rpc-methods)))
    (cond
     ((and extra (not (process-get proc :authed)))
      (org-writenotes--ws-send-json
       proc `(:jsonrpc "2.0" :id ,id
              :error (:code -32001 :message "Not authenticated: send session.hello first"))))
     (extra
      (org-writenotes--ws-send-json
       proc
       (condition-case err
           `(:jsonrpc "2.0" :id ,id :result ,(funcall (cdr extra) params))
         (error `(:jsonrpc "2.0" :id ,id
                  :error (:code -32603 :message ,(error-message-string err)))))))
     ((equal method "session.hello")
      (if (>= (or (process-get proc 'auth-failures) 0) org-writenotes-max-auth-failures)
          (progn
            (org-writenotes--ws-send-json
             proc `(:jsonrpc "2.0" :id ,id
                    :error (:code -32001 :message "Too many failed authentication attempts")))
            (delete-process proc))
        (process-put proc 'client-protocol (alist-get 'protocolVersion params))
        (cl-letf* ((send (symbol-function 'org-writenotes--ws-send-json))
                   ((symbol-function 'org-writenotes--ws-send-json)
                    (lambda (p payload)
                      (let ((res (plist-get payload :result)))
                        (cond
                         (res
                          (setq payload
                                (plist-put payload :result
                                           (append res
                                                   `(:protocolVersion ,org-writenotes-protocol-version
                                                     :capabilities ,org-writenotes--capabilities)))))
                         ((plist-get payload :error)
                          (process-put p 'auth-failures
                                       (1+ (or (process-get p 'auth-failures) 0))))))
                      (funcall send p payload))))
          (funcall orig proc msg-text))))
     (t (funcall orig proc msg-text)))))

(advice-add 'org-writenotes--dispatch-rpc :around
            #'org-writenotes--dispatch-rpc-around)

;;; C4: Link repair ---------------------------------------------------------------

;;;###autoload
(defun org-writenotes-repair-links ()
  "Repair broken `.svgz' links in the current buffer by searching the image dir.
A link is repaired when exactly one file with the same basename exists."
  (interactive)
  (let* ((dir (org-writenotes--resolve-image-dir (buffer-file-name)))
         (files (when (file-directory-p dir)
                  (directory-files-recursively dir "\\.svgz\\'")))
         (fixed 0))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "\\[\\[file:\\([^]\n]+\\.svgz\\)\\]" nil t)
        (let* ((target (match-string 1))
               (abs (expand-file-name target)))
          (unless (file-exists-p abs)
            (let ((cands (cl-remove-if-not
                          (lambda (f) (and (equal (file-name-nondirectory f)
                                                  (file-name-nondirectory target))
                                           (not (string-match-p "/\\.history/" f))))
                          files)))
              (when (= (length cands) 1)
                (replace-match (file-relative-name (car cands)) t t nil 1)
                (cl-incf fixed)))))))
    (message "org-writenotes: repaired %d link(s)" fixed)
    fixed))

;;; C7: ox-html inlining -----------------------------------------------------------

(defcustom org-writenotes-html-inline-svgz t
  "When non-nil, HTML export inlines `.svgz' sketches as `<svg>' elements."
  :type 'boolean :group 'org-writenotes)

(defun org-writenotes--html-link-filter (text backend _info)
  "Replace `<img src=\"*.svgz\">' in TEXT with inline SVG for html BACKEND."
  (if (and org-writenotes-html-inline-svgz
           (org-export-derived-backend-p backend 'html)
           (string-match "<img src=\"\\([^\"]+\\.svgz\\)\"" text))
      (let ((path (expand-file-name (match-string 1 text))))
        (or (ignore-errors
              (let* ((res (org-writenotes--read-and-repair-svgz path))
                     (xml (if (consp res) (cdr res) res)))
                (when (stringp xml)
                  (replace-regexp-in-string "\\`<\\?xml[^>]*>\\s-*" "" xml))))
            text))
    text))

(defvar org-export-filter-link-functions)
(with-eval-after-load 'ox
  (add-to-list 'org-export-filter-link-functions #'org-writenotes--html-link-filter))

;;; E4: Flashcard & Spaced-Repetition Support (org-drill / Anki) ------------

(defcustom org-writenotes-drill-tag "drill"
  "Tag added to Org headings flagged for spaced repetition review."
  :type 'string :group 'org-writenotes)

;;;###autoload
(defun org-writenotes-flag-as-flashcard ()
  "Flag the current Org heading or active tablet node as an `org-drill' card."
  (interactive)
  (let* ((loc (or (when (derived-mode-p 'org-mode)
                    (cons (current-buffer) (point-marker)))
                  (and org-writenotes--active-node-id
                       (org-writenotes--locate-node org-writenotes--active-node-id)))))
    (unless loc
      (user-error "No Org node found at point or active on tablet"))
    (with-current-buffer (car loc)
      (save-excursion
        (goto-char (cdr loc))
        (org-back-to-heading t)
        (org-toggle-tag org-writenotes-drill-tag 'on)
        (org-set-property "DRILL_CARD_TYPE" "simple")
        (let ((snapshot (org-writenotes--parse-subtree-at-point)))
          (org-writenotes--broadcast-notification "emacs.nodeModified" snapshot))
        (message "[Org-WriteNotes] Node flagged for flashcard review (:%s:)."
                 org-writenotes-drill-tag)))))

(defun org-writenotes--handle-flag-flashcard (params)
  "Handle the `node.flagFlashcard' RPC with PARAMS from the tablet companion."
  (let* ((node-id (alist-get 'nodeId params))
         (loc (org-writenotes--locate-node node-id)))
    (unless loc
      (error "Node not found: %s" node-id))
    (with-current-buffer (car loc)
      (save-excursion
        (goto-char (cdr loc))
        (org-back-to-heading t)
        (org-toggle-tag org-writenotes-drill-tag 'on)
        (org-set-property "DRILL_CARD_TYPE" "simple")
        (save-buffer)
        (let ((snapshot (org-writenotes--parse-subtree-at-point)))
          (org-writenotes--broadcast-notification "emacs.nodeModified" snapshot)
          `(:success t :nodeId ,node-id :tag ,org-writenotes-drill-tag))))))

;;; C5: Inline preview cache keyed by file mtime ----------------------------

(defvar org-writenotes--mtime-image-cache (make-hash-table :test 'equal)
  "Cache of rendered SVG string/data keyed by `(filepath . mtime)'.")

(defun org-writenotes--cached-svg-for-file (filepath)
  "Return cached SVG XML string for FILEPATH if mtime matches, else nil."
  (when (file-exists-p filepath)
    (let* ((mtime (float-time (file-attribute-modification-time (file-attributes filepath))))
           (cached (gethash filepath org-writenotes--mtime-image-cache)))
      (when (and cached (= (car cached) mtime))
        (cdr cached)))))

(defun org-writenotes--put-cached-svg-for-file (filepath svg-xml)
  "Store SVG-XML in mtime cache for FILEPATH."
  (when (file-exists-p filepath)
    (let ((mtime (float-time (file-attribute-modification-time (file-attributes filepath)))))
      (puthash filepath (cons mtime svg-xml) org-writenotes--mtime-image-cache))))

(defun org-writenotes--create-image-cache-advice (orig-fun &rest args)
  "Use `org-writenotes--mtime-image-cache' for fast inline preview scrolling.
ORIG-FUN is the advised function; ARGS are passed through safely whether
advising `org-writenotes--create-image-svgz-advice' or `create-image'."
  (if (functionp (car args))
      (apply orig-fun args)
    (let ((file-or-data (nth 0 args))
          (type (nth 1 args))
          (data-p (nth 2 args))
          (props (nthcdr 3 args)))
      (if (and (not data-p)
               (stringp file-or-data)
               (save-match-data (string-match-p "\\.svgz\\'" (downcase file-or-data)))
               (file-exists-p file-or-data))
          (let* ((abs-file (expand-file-name file-or-data))
                 (cached-xml (org-writenotes--cached-svg-for-file abs-file))
                 (final-props
                  (if (and (bound-and-true-p org-writenotes-inline-max-width)
                           (not (plist-member props :width))
                           (not (plist-member props :max-width)))
                      (append props (list :max-width org-writenotes-inline-max-width))
                    props)))
            (if (and cached-xml (stringp cached-xml) (> (length cached-xml) 0))
                (let ((adapted (or (ignore-errors (org-writenotes--adapt-svg-xml-for-theme cached-xml))
                                   cached-xml)))
                  (apply orig-fun adapted 'svg t final-props))
              (let ((img (apply orig-fun file-or-data type data-p props)))
                (when (and (not data-p) (file-exists-p abs-file))
                  (let ((pair (ignore-errors (org-writenotes--read-and-repair-svgz abs-file))))
                    (when (and pair (cdr pair))
                      (org-writenotes--put-cached-svg-for-file abs-file (cdr pair)))))
                img)))
        (apply orig-fun args)))))

(advice-remove 'org-writenotes--create-image-svgz-advice
               #'org-writenotes--create-image-cache-advice)

;;; A6: Transport hardening (Tailscale IP detection & bind) ------------------

(defcustom org-writenotes-tailscale-only nil
  "When non-nil, automatically discover and bind to Tailscale IP (100.x.y.z)."
  :type 'boolean :group 'org-writenotes)

(defun org-writenotes--get-tailscale-ip ()
  "Return Tailscale IPv4 address if available, or nil."
  (let ((ts (executable-find "tailscale")))
    (when ts
      (let ((ip (string-trim (shell-command-to-string (format "%s ip -4 2>/dev/null" ts)))))
        (when (and (not (string-empty-p ip)) (string-match-p "^100\\." ip))
          ip)))))

(defun org-writenotes-pair-tailscale ()
  "Start server on Tailscale IP and generate pairing QR code."
  (interactive)
  (let ((ts-ip (org-writenotes--get-tailscale-ip)))
    (unless ts-ip
      (user-error "Tailscale IPv4 address not found; ensure Tailscale is running"))
    (setq org-writenotes-host ts-ip)
    (when (and org-writenotes--server-proc (process-live-p org-writenotes--server-proc))
      (org-writenotes-stop-server))
    (org-writenotes-start-server)
    (let* ((ws-url (format "ws://%s:%d" ts-ip org-writenotes-port))
           (qr-json (json-serialize
                     `(:v 1 :url ,ws-url :token ,(or org-writenotes--session-token ""))))
           (buf (get-buffer-create "*Org-WriteNotes Tailscale Pairing*")))
      (with-current-buffer buf
        (read-only-mode -1)
        (erase-buffer)
        (insert "=== Org-WriteNotes Tailscale Wireless Pairing ===\n\n")
        (insert (format "Tailscale IP   : %s\n" ts-ip))
        (insert (format "WebSocket URL  : %s\n" ws-url))
        (insert (format "Session Token  : %s\n" (or org-writenotes--session-token "")))
        (insert (format "QR Payload     : %s\n\n" qr-json))
        (when (executable-find "qrencode")
          (insert (shell-command-to-string
                   (format "qrencode -t UTF8 %s" (shell-quote-argument qr-json))))
          (insert "\n"))
        (read-only-mode 1))
      (pop-to-buffer buf))))

;;; C1: Minor mode + transient menu ------------------------------------------------

(defvar org-writenotes-command-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "p") #'org-writenotes-push-node)
    (define-key m (kbd "q") #'org-writenotes-pair-qr)
    (define-key m (kbd "t") #'org-writenotes-pair-tailscale)
    (define-key m (kbd "r") #'org-writenotes-revert-sketch-at-point)
    (define-key m (kbd "l") #'org-writenotes-repair-links)
    (define-key m (kbd "f") #'org-writenotes-flag-as-flashcard)
    (define-key m (kbd "w") #'org-writenotes-menu)
    m)
  "Prefix keymap for Org-WriteNotes commands.")

(defvar org-writenotes-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c w") org-writenotes-command-map)
    m)
  "Keymap for `org-writenotes-mode'.")

;;;###autoload
(define-minor-mode org-writenotes-mode
  "Minor mode providing `C-c w' Org-WriteNotes bindings."
  :lighter " WN" :keymap org-writenotes-mode-map)

(if (require 'transient nil t)
    (transient-define-prefix org-writenotes-menu ()
      "Org-WriteNotes commands."
      ["Org-WriteNotes"
       ["Tablet & Companion"
        ("p" "Push node" org-writenotes-push-node)
        ("q" "Pair via LAN QR" org-writenotes-pair-qr)
        ("t" "Pair via Tailscale" org-writenotes-pair-tailscale)
        ("d" "Connect Linux desktop" org-writenotes-connect-linux)
        ("i" "Connect iPadOS" org-writenotes-connect-ipad)]
       ["Sketches"
        ("s" "Popup sketch at point" org-writenotes-popup-sketch-at-point)
        ("r" "Revert sketch at point" org-writenotes-revert-sketch-at-point)
        ("l" "Repair broken links" org-writenotes-repair-links)
        ("b" "Sketch backlinks" org-writenotes-show-sketch-backlinks)
        ("f" "Flag as flashcard" org-writenotes-flag-as-flashcard)]])
  (defun org-writenotes-menu ()
    "Fallback menu when `transient' is unavailable."
    (interactive)
    (call-interactively
     (intern (completing-read "Org-WriteNotes: "
                              '("org-writenotes-push-node" "org-writenotes-pair-qr"
                                "org-writenotes-connect-linux" "org-writenotes-connect-ipad"
                                "org-writenotes-popup-sketch-at-point"
                                "org-writenotes-revert-sketch-at-point"
                                "org-writenotes-repair-links")
                              nil t)))))

;;; E5: Multi-client presence ---------------------------------------------------

(defvar org-writenotes--last-presence nil
  "Last presence list broadcast to clients, used to suppress duplicates.")

(defun org-writenotes--presence-list ()
  "Return a list of plists describing connected, authenticated clients."
  (cl-loop for proc in org-writenotes--clients
           when (and (process-live-p proc) (process-get proc 'presence-ok))
           collect (list :id (process-name proc)
                         :name (or (process-get proc 'client-name) "client")
                         :node (or (process-get proc 'active-node) :null))))

(defun org-writenotes--broadcast-presence (&optional force)
  "Broadcast `presence.update' to all clients when it changed (or FORCE)."
  (let ((now (org-writenotes--presence-list)))
    (when (or force (not (equal now org-writenotes--last-presence)))
      (setq org-writenotes--last-presence now)
      (org-writenotes--broadcast-notification
       "presence.update" `(:clients ,(vconcat now))))))

(defun org-writenotes--handle-presence-list (_params)
  "RPC handler for `presence.list'."
  `(:clients ,(vconcat (org-writenotes--presence-list))))

(defun org-writenotes--presence-around (orig proc msg-text)
  "Track which client is on which node, then call ORIG.
PROC is the client process and MSG-TEXT the raw JSON-RPC message."
  (let* ((req (ignore-errors (org-writenotes--read-rpc-json msg-text)))
         (method (alist-get 'method req))
         (params (alist-get 'params req))
         (node (and (listp params) (alist-get 'nodeId params)))
         (fails (or (process-get proc 'auth-failures) 0))
         (result (funcall orig proc msg-text)))
    (when (stringp node)
      (process-put proc 'active-node node))
    (when (and (equal method "session.hello")
               (= fails (or (process-get proc 'auth-failures) 0))
               (process-live-p proc))
      (process-put proc 'client-name (alist-get 'clientName params))
      (process-put proc 'presence-ok t))
    (when (or (equal method "session.hello") (stringp node))
      (org-writenotes--broadcast-presence))
    result))

(advice-add 'org-writenotes--dispatch-rpc :around #'org-writenotes--presence-around)

(defun org-writenotes--presence-sentinel (proc _event)
  "Update presence after client process PROC changes state."
  (unless (process-live-p proc)
    (process-put proc 'presence-ok nil)
    (run-at-time 0 nil #'org-writenotes--broadcast-presence)))

(advice-add 'org-writenotes--client-sentinel :after #'org-writenotes--presence-sentinel)

;;; C2: Multi-file node routing ----------------------------------------------------

(defcustom org-writenotes-extra-files nil
  "Additional Org files searched for nodes, besides open buffers and the agenda."
  :type '(repeat file) :group 'org-writenotes)

(defun org-writenotes--locate-node-around (orig node-id)
  "Fall back to the global ID database when ORIG cannot find NODE-ID.
This keeps tablet nodes addressable after their Org file is moved or renamed."
  (or (funcall orig node-id)
      (when (and (stringp node-id)
                 (string-match "::id:\\(.+\\)\\'" node-id)
                 (fboundp 'org-id-find))
        (let ((marker (ignore-errors (org-id-find (match-string 1 node-id) 'marker))))
          (when (markerp marker)
            (cons (marker-buffer marker) marker))))))

(advice-add 'org-writenotes--locate-node :around #'org-writenotes--locate-node-around)

(defun org-writenotes--candidate-buffers-extra (bufs)
  "Add buffers visiting `org-writenotes-extra-files' to BUFS."
  (dolist (f org-writenotes-extra-files)
    (when (and (stringp f) (file-exists-p f))
      (cl-pushnew (find-file-noselect f) bufs)))
  bufs)

(advice-add 'org-writenotes--candidate-org-buffers :filter-return
            #'org-writenotes--candidate-buffers-extra)

;;; C3: Sketch backlinks (works with org-roam when available) ----------------------

(defvar org-roam-directory)

(defun org-writenotes--backlink-files ()
  "Return Org files to scan for sketch links."
  (let ((files (mapcar #'buffer-file-name (org-writenotes--candidate-org-buffers))))
    (when (and (boundp 'org-roam-directory) (stringp org-roam-directory)
               (file-directory-p org-roam-directory))
      (setq files (append files (directory-files-recursively org-roam-directory "\\.org\\'"))))
    (delete-dups (delq nil files))))

(defun org-writenotes-sketch-backlinks (sketch-name)
  "Return a list of (FILE LINE HEADING) for Org entries linking to SKETCH-NAME.
SKETCH-NAME is compared by file name, so moved sketches still match."
  (let ((needle (regexp-quote (file-name-nondirectory sketch-name)))
        results)
    (dolist (file (org-writenotes--backlink-files))
      (when (file-readable-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (delay-mode-hooks (org-mode))
          (goto-char (point-min))
          (while (re-search-forward (concat "\\[\\[[^]\n]*" needle "\\]") nil t)
            (let ((line (line-number-at-pos))
                  (heading (save-excursion
                             (and (ignore-errors (org-back-to-heading t))
                                  (org-get-heading t t t t)))))
              (push (list file line (or heading "(before first heading)")) results))))))
    (nreverse results)))

;;;###autoload
(defun org-writenotes-show-sketch-backlinks ()
  "Show Org entries that link to the sketch at point."
  (interactive)
  (let ((link (org-writenotes--svgz-link-at-point)))
    (unless link (user-error "No sketch link at point"))
    (let ((hits (org-writenotes-sketch-backlinks link))
          (buf (get-buffer-create "*Org-WriteNotes Backlinks*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Backlinks for %s\n\n" (file-name-nondirectory link)))
          (if (null hits)
              (insert "No references found.\n")
            (dolist (h hits)
              (insert-text-button
               (format "%s:%d  %s" (abbreviate-file-name (nth 0 h)) (nth 1 h) (nth 2 h))
               'action (lambda (_)
                         (find-file (nth 0 h))
                         (goto-char (point-min))
                         (forward-line (1- (nth 1 h)))))
              (insert "\n"))))
        (special-mode))
      (pop-to-buffer buf)
      hits)))

(define-key org-writenotes-command-map (kbd "b") #'org-writenotes-show-sketch-backlinks)

;;; F1: Linux Desktop Companion & Quick Single-Sketch Popup ---------------------

(defcustom org-writenotes-linux-command
  (let ((apps-cmd (expand-file-name "~/dev/org-writenotes-apps/linux/org-writenotes-linux"))
        (local-cmd (expand-file-name "../linux/org-writenotes-linux"
                                    (file-name-directory (or load-file-name buffer-file-name
                                                             default-directory)))))
    (if (file-exists-p apps-cmd)
        apps-cmd
      local-cmd))
  "Path to the `org-writenotes-linux' launcher for Linux Desktop."
  :type 'file
  :group 'org-writenotes)

(defvar org-writenotes--linux-companion-proc nil
  "Process handle for the local Linux Org-WriteNotes companion window.")

;;;###autoload
(defun org-writenotes-connect-linux ()
  "Start the server and launch the local Linux Org-WriteNotes companion app."
  (interactive)
  (unless (and org-writenotes--server-proc
               (process-live-p org-writenotes--server-proc))
    (org-writenotes-start-server))
  (if (and org-writenotes--linux-companion-proc
           (process-live-p org-writenotes--linux-companion-proc))
      (message "[Org-WriteNotes] Linux companion app is already running.")
    (let ((cmd org-writenotes-linux-command)
          (url (format "ws://127.0.0.1:%d" org-writenotes-port)))
      (unless (file-executable-p cmd)
        (user-error "Linux launcher not found or not executable: %s" cmd))
      (setq org-writenotes--linux-companion-proc
            (start-process "org-writenotes-linux" "*Org-WriteNotes Linux*"
                           cmd "--url" url))
      (message "[Org-WriteNotes] Launched Linux companion app (%s)." url))))

;;;###autoload
(defun org-writenotes-popup-sketch-at-point ()
  "Open the `.svgz' sketch at point in a Linux single-sketch popup window.
When the popup saves or exits, the inline `.svgz' image in Emacs is refreshed."
  (interactive)
  (let ((path (org-writenotes--svgz-link-at-point)))
    (unless path
      (let* ((line-str (buffer-substring-no-properties
                        (line-beginning-position) (line-end-position)))
             (matched (string-match
                       "\\[\\[\\(?:file:\\|attachment:\\)?\\([^]\n]+\\.svgz?\\)"
                       line-str)))
        (when matched
          (setq path (expand-file-name
                      (file-name-nondirectory (match-string 1 line-str))
                      (org-writenotes--resolve-image-dir (buffer-file-name)))))))
    (unless path
      (user-error "No .svgz sketch link at point"))
    (unless (and org-writenotes--server-proc
                 (process-live-p org-writenotes--server-proc))
      (org-writenotes-start-server))
    (let* ((cmd org-writenotes-linux-command)
           (org-file (or (buffer-file-name) ""))
           (node-id (save-excursion
                      (or (ignore-errors
                            (org-back-to-heading t)
                            (org-writenotes--node-id-at-point t))
                          "")))
           (url (format "ws://127.0.0.1:%d" org-writenotes-port)))
      (unless (file-executable-p cmd)
        (user-error "Linux launcher not found or not executable: %s" cmd))
      (let ((proc (start-process
                   "org-writenotes-popup" "*Org-WriteNotes Popup*"
                   cmd "--sketch" path "--node" node-id
                   "--org-file" org-file "--url" url)))
        (set-process-sentinel
         proc
         (lambda (_p _ev)
           (when (file-exists-p path)
             (remhash path org-writenotes--live-svg-cache)
             (org-writenotes--refresh-inline-image path))))
        (message "[Org-WriteNotes] Opened %s in Linux sketch popup."
                 (file-name-nondirectory path))
        proc))))

(define-key org-writenotes-command-map (kbd "d") #'org-writenotes-connect-linux)
(define-key org-writenotes-command-map (kbd "s") #'org-writenotes-popup-sketch-at-point)

;;; F2: iPadOS Companion Connection (LAN / Tailscale QR + USB iproxy) --------

(defcustom org-writenotes-ipad-usb-command "iproxy"
  "Executable used for USB port forwarding to an iPad via `libimobiledevice'."
  :type 'string
  :group 'org-writenotes)

(defvar org-writenotes--ipad-tunnel-proc nil
  "Process handle for optional `iproxy' USB port forwarding to iPadOS.")

(defun org-writenotes--format-ipad-connect-uri (host port &optional token)
  "Format an `orgwritenotes://connect' deep-link URI for iPadOS with HOST and PORT.
Optional TOKEN is included if non-nil."
  (format "orgwritenotes://connect?host=%s&port=%d&token=%s"
          (url-hexify-string (or host "127.0.0.1"))
          (or port org-writenotes-port)
          (url-hexify-string (or token ""))))

;;;###autoload
(defun org-writenotes-connect-ipad (&optional use-usb)
  "Start the server and display pairing info / deep-link QR for iPadOS.
With prefix arg USE-USB (or when `iproxy' is requested), also starts a USB
port-forwarding tunnel via `libimobiledevice'."
  (interactive "P")
  (unless (and org-writenotes--server-proc
               (process-live-p org-writenotes--server-proc))
    (org-writenotes-start-server))
  (when (and use-usb (executable-find org-writenotes-ipad-usb-command))
    (when (and org-writenotes--ipad-tunnel-proc
               (process-live-p org-writenotes--ipad-tunnel-proc))
      (delete-process org-writenotes--ipad-tunnel-proc))
    (let ((port-str (number-to-string org-writenotes-port)))
      (setq org-writenotes--ipad-tunnel-proc
            (start-process "org-writenotes-iproxy" "*Org-WriteNotes iproxy*"
                           org-writenotes-ipad-usb-command port-str port-str))))
  (let* ((host (or (org-writenotes--get-tailscale-ip)
                   (and (fboundp 'org-writenotes--detect-lan-ip)
                        (org-writenotes--detect-lan-ip))
                   org-writenotes-host
                   "127.0.0.1"))
         (token (or org-writenotes--session-token ""))
         (uri (org-writenotes--format-ipad-connect-uri
               (if use-usb "127.0.0.1" host) org-writenotes-port token))
         (buf (get-buffer-create "*Org-WriteNotes iPadOS Pairing*")))
    (with-current-buffer buf
      (read-only-mode -1)
      (erase-buffer)
      (insert "=== Org-WriteNotes iPadOS Companion Pairing ===\n\n")
      (insert (format "Host           : %s\n" (if use-usb "127.0.0.1 (USB iproxy)" host)))
      (insert (format "Port           : %d\n" org-writenotes-port))
      (insert (format "Session Token  : %s\n" token))
      (insert (format "iPadOS URI     : %s\n\n" uri))
      (when (executable-find "qrencode")
        (insert (shell-command-to-string
                 (format "qrencode -t UTF8 %s" (shell-quote-argument uri))))
        (insert "\n"))
      (read-only-mode 1))
    (pop-to-buffer buf)
    uri))

(define-key org-writenotes-command-map (kbd "i") #'org-writenotes-connect-ipad)

(provide 'org-writenotes-extras)
;;; org-writenotes-extras.el ends here
