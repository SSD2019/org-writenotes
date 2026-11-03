;;; org-writenotes.el --- Companion tablet handwriting app integration for Org-mode -*- lexical-binding: t; -*-

;; Author: Org-WriteNotes Contributors
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
  "If non-nil, automatically start the WebSocket server and ADB USB watchdog on load."
  :type 'boolean
  :group 'org-writenotes)

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
    (cons svgz-bytes xml-bytes)))

(defun org-writenotes--create-image-svgz-advice (orig-fun file-or-data &optional type data-p &rest props)
  "Advice for `create-image' to seamlessly render `.svgz' files via native `svg'."
  (if (and (not data-p)
           (stringp file-or-data)
           (string-match-p "\\.svgz\\'" (downcase file-or-data))
           (file-exists-p file-or-data))
      (let* ((pair (ignore-errors (org-writenotes--read-and-repair-svgz file-or-data)))
             (svg-xml (cdr pair)))
        (if (and (stringp svg-xml)
                 (> (length svg-xml) 0)
                 (string-match-p "<svg" svg-xml))
            (apply orig-fun svg-xml 'svg t props)
          (apply orig-fun file-or-data 'svg nil props)))
    (apply orig-fun file-or-data type data-p props)))

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
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (and (derived-mode-p 'org-mode) (display-graphic-p))
        (ignore-errors (org-display-inline-images t t)))))
  (when (called-interactively-p 'interactive)
    (message "[Org-WriteNotes] Enabled inline .svgz rendering.")))

(defun org-writenotes--refresh-inline-image (&optional _saved-path)
  "Clear Emacs image cache and refresh inline images in Org buffers."
  (when (fboundp 'clear-image-cache)
    (ignore-errors (clear-image-cache)))
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when (derived-mode-p 'org-mode)
        (ignore-errors (org-display-inline-images t t)))))
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
  (let* ((base-dir (file-name-directory (expand-file-name org-file)))
         (abs-img (expand-file-name svgz-filename (org-writenotes--resolve-image-dir org-file)))
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
  "Write an initial valid Stylus Labs Write SVG/SVGZ template to FILEPATH."
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

(defun org-writenotes--node-id-at-point ()
  "Construct a stable identifier for the Org heading at point."
  (save-excursion
    (org-back-to-heading t)
    (let ((file (buffer-file-name))
          (id (org-entry-get (point) "ID"))
          (line (line-number-at-pos (point))))
      (if id
          (format "file:%s::id:%s" file id)
        (format "file:%s::line:%d" file line)))))

(defun org-writenotes--locate-node (node-id)
  "Find the buffer and point for NODE-ID. Returns `(buffer . marker)' or nil."
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

(defun org-writenotes--parse-subtree-at-point ()
  "Serialize the Org subtree at point into a hybrid block-interleaved plist."
  (save-excursion
    (org-back-to-heading t)
    (let* ((beg (point))
           (end (save-excursion (org-end-of-subtree t t) (point)))
           (file (or (buffer-file-name) default-directory))
           (node-id (org-writenotes--node-id-at-point))
           (heading-components (org-heading-components))
           (level (nth 0 heading-components))
           (todo (nth 2 heading-components))
           (prio (nth 3 heading-components))
           (raw-title (or (nth 4 heading-components) ""))
           (title (replace-regexp-in-string "\\s-*\\[[0-9]+/[0-9]+\\]\\s-*\\|\\s-*\\[[0-9]+%\\]\\s-*" "" raw-title))
           (tags (org-get-tags nil t))
           (sched (org-entry-get beg "SCHEDULED"))
           (deadl (org-entry-get beg "DEADLINE"))
           (raw-props (org-entry-properties beg 'standard))
           (props (let ((ht (make-hash-table :test 'equal)))
                    (dolist (pair raw-props)
                      (when (consp pair)
                        (puthash (format "%s" (car pair))
                                 (format "%s" (or (cdr pair) ""))
                                 ht)))
                    ht))
           (subtree-text (buffer-substring-no-properties beg end))
           (etag (format "tick-%d-sha1-%s"
                         (buffer-chars-modified-tick)
                         (substring (sha1 subtree-text) 0 10)))
           (blocks (org-writenotes--extract-blocks beg end file))
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
                        :priority ,(if prio (char-to-string prio) :null)
                        :title ,title
                        :tags ,(vconcat tags)
                        :scheduled ,(or sched :null)
                        :deadline ,(or deadl :null)
                        :checkboxProgress ,(if (> check-total 0)
                                               (format "%d/%d" check-done check-total)
                                             :null)
                        :properties ,props)
               :blocks ,(vconcat blocks))))
        (org-writenotes--record-pushed-node snapshot)
        snapshot))))

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

(defun org-writenotes--extract-blocks (beg end org-file)
  "Parse lines between BEG and END into ordered checklist, ink_canvas, and paragraph blocks."
  (save-excursion
    (org-writenotes--goto-body-start beg end)
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
        (while (and (< (point) end)
                    (not (org-at-heading-p)))
          (let ((line-str (buffer-substring-no-properties
                           (line-beginning-position) (line-end-position)))
                (line-num (line-number-at-pos (point))))
            (cond
             ;; Case 1: Embedded .svgz / .svg Ink Block Link
             ((string-match "\\[\\[\\(?:file:\\|attachment:\\)\\([^]\n]+\\.svgz?\\)\\]\\]" line-str)
              (flush-checklist)
              (flush-para)
              (cl-incf blk-idx)
              (let* ((rel-target (match-string 1 line-str))
                     (abs-target (expand-file-name rel-target (file-name-directory (expand-file-name org-file))))
                     (b64 (when (file-exists-p abs-target)
                            (let ((svgz-bytes (car (org-writenotes--read-and-repair-svgz abs-target))))
                              (base64-encode-string svgz-bytes t)))))
                (push `(:blockId ,(format "blk-%d" blk-idx)
                        :type "ink_canvas"
                        :startLine ,line-num
                        :endLine ,line-num
                        :fileName ,(file-name-nondirectory abs-target)
                        :linkText ,(match-string 0 line-str)
                        :width ,org-writenotes-default-canvas-width
                        :height ,org-writenotes-default-canvas-height
                        :xRuling 40
                        :yRuling 40
                        :svgzBase64 ,(or b64 :null))
                      blocks)))

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
        (nreverse blocks)))))

(defun org-writenotes--record-pushed-node (snapshot)
  "Record SNAPSHOT in `org-writenotes--pushed-history' (most recent first, deduplicated)."
  (let* ((node-id (plist-get snapshot :nodeId))
          (file-path (plist-get snapshot :filePath))
          (hdr (plist-get snapshot :header))
          (summary `(:nodeId ,node-id
                     :filePath ,file-path
                     :level ,(plist-get hdr :level)
                     :todoKeyword ,(plist-get hdr :todoKeyword)
                     :priority ,(plist-get hdr :priority)
                     :title ,(plist-get hdr :title)
                     :tags ,(plist-get hdr :tags))))
    (setq org-writenotes--pushed-history
          (cons summary
                (cl-remove-if (lambda (item)
                                (equal (plist-get item :nodeId) node-id))
                              org-writenotes--pushed-history)))
    (when (> (length org-writenotes--pushed-history) org-writenotes-history-limit)
      (setq org-writenotes--pushed-history
            (cl-subseq org-writenotes--pushed-history 0 org-writenotes-history-limit)))))

(defun org-writenotes--collect-node-summaries (&optional _filter query)
  "Return a vector of pushed node summaries from `org-writenotes--pushed-history'."
  (let ((filtered
         (if (or (not query) (string-empty-p query))
             org-writenotes--pushed-history
           (cl-remove-if-not
            (lambda (item)
              (string-match-p (regexp-quote query)
                              (or (plist-get item :title) "")))
            org-writenotes--pushed-history))))
    (vconcat filtered)))

;;; ---------------------------------------------------------------------------
;;; Org Subtree Mutation Handlers (Checklists, Headings, Ink Blocks)
;;; ---------------------------------------------------------------------------

(defun org-writenotes--handle-toggle-checkbox (params)
  "Toggle a checkbox line in the Org node specified by PARAMS."
  (let* ((node-id (alist-get 'nodeId params))
         (line-num (alist-get 'line params))
         (new-state (alist-get 'state params))
         (loc (org-writenotes--locate-node node-id)))
    (unless loc
      (error "Node not found: %s" node-id))
    (with-current-buffer (car loc)
      (save-excursion
        (goto-char (point-min))
        (forward-line (1- line-num))
        (when (looking-at "^\\(\\s-*[-+*]\\s-+\\[\\)[ Xx-]\\(\\]\\s-+.*\\)$")
          (replace-match (if (equal new-state "checked") "X" " ") t t nil 0)
          (org-update-checkbox-count-maybe)
          (save-buffer)))
      (goto-char (cdr loc))
      (org-writenotes--parse-subtree-at-point))))

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
        (let ((end (save-excursion (org-end-of-subtree t t) (point))))
          (cond
           ((and (integerp after-line) (> after-line 0))
            (goto-char (point-min))
            (forward-line (1- after-line))
            (end-of-line)
            (insert (format "\n- [ ] %s" text)))
           ((re-search-forward "^\\s-*[-+*]\\s-+\\[[ Xx-]\\].*$" end t)
            (while (and (< (point) end)
                        (save-excursion
                          (forward-line 1)
                          (looking-at-p "^\\s-*[-+*]\\s-+\\[[ Xx-]\\]")))
              (forward-line 1))
            (end-of-line)
            (insert (format "\n- [ ] %s" text)))
           (t
            (end-of-line)
            (insert (format "\n- [ ] %s" text))))
          (org-update-checkbox-count-maybe)
          (save-buffer)))
      (goto-char (cdr loc))
      (org-writenotes--parse-subtree-at-point))))

(defun org-writenotes--handle-update-header (params)
  "Update TODO keyword, priority, title, or tags of the Org node in PARAMS."
  (let* ((node-id (alist-get 'nodeId params))
         (todo (alist-get 'todoKeyword params))
         (prio (alist-get 'priority params))
         (title (alist-get 'title params))
         (tags (alist-get 'tags params))
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
        (let ((sub-end (save-excursion (org-end-of-subtree t t) (point))))
          (cond
           ((and (integerp start-line) (> start-line 0)
                 (integerp end-line) (>= end-line start-line))
            (goto-char (point-min))
            (forward-line (1- start-line))
            (let ((line-beg (line-beginning-position))
                  (line-end (save-excursion
                              (goto-char (point-min))
                              (forward-line (1- end-line))
                              (min sub-end (line-end-position)))))
              (delete-region line-beg line-end)
              (insert (or new-text ""))))
           ((and old-text (not (string-empty-p old-text))
                 (search-forward old-text sub-end t))
            (replace-match (or new-text "") t t))
           (start-line
            (goto-char (point-min))
            (forward-line (1- start-line))
            (let ((line-beg (line-beginning-position))
                  (line-end (line-end-position)))
              (delete-region line-beg line-end)
              (insert (or new-text "")))))
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
        (save-buffer))
      (goto-char (cdr loc))
      (org-writenotes--parse-subtree-at-point))))

(defun org-writenotes--handle-insert-ink-block (params)
  "Create a new `.svgz' file in the common directory and insert its link into the Org node.
Supports positioning via:
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
             (save-excursion
               (goto-char (cdr loc))
               (let* ((beg (point))
                      (org-file (buffer-file-name))
                      (title (nth 4 (org-heading-components)))
                      (slug (org-writenotes--slugify title))
                      (timestamp (format-time-string "%Y%m%d-%H%M%S"))
                      (filename (format "%s-%s.svgz" slug timestamp))
                      (img-dir (org-writenotes--resolve-image-dir org-file))
                      (abs-path (expand-file-name filename img-dir))
                      (link-str (org-writenotes--format-file-link org-file filename))
                      (sub-end (save-excursion (org-end-of-subtree t t) (point))))
                 (org-writenotes--create-blank-svgz abs-path w h xr yr)
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
                     (let ((reg-beg (line-beginning-position))
                           (reg-end (save-excursion
                                      (goto-char (point-min))
                                      (forward-line (1- end-ln))
                                      (min sub-end (line-end-position)))))
                       (delete-region reg-beg reg-end)
                       (insert replacement))))

                  ;; 2. Insert at top of node body (after heading + drawers)
                  ((and (integerp after-line) (<= after-line 0))
                   (org-writenotes--goto-body-start beg sub-end)
                   (insert (format "%s\n\n" link-str)))

                  ;; 3. Insert after a specific line (after a checklist item, checklist, paragraph, or sketch)
                  ((and (integerp after-line) (> after-line 0))
                   (let ((body-start (save-excursion
                                       (org-writenotes--goto-body-start beg sub-end)
                                       (point))))
                     (goto-char (point-min))
                     (forward-line (1- after-line))
                     (let* ((line-end (min sub-end (line-end-position)))
                            (ins-pos (max body-start line-end)))
                       (goto-char ins-pos)
                       (unless (bolp) (insert "\n"))
                       (insert (format "%s\n\n" link-str)))))

                  ;; 4. Default: append at the end of the node body
                  (t
                   (let ((body-start (save-excursion
                                       (org-writenotes--goto-body-start beg sub-end)
                                       (point))))
                     (goto-char sub-end)
                     (skip-chars-backward " \t\n" body-start)
                     (if (<= (point) body-start)
                         (progn
                           (goto-char body-start)
                           (unless (bolp) (insert "\n"))
                           (insert (format "%s\n\n" link-str)))
                       (insert (format "\n\n%s\n" link-str))))))
                 (save-buffer)
                 (org-writenotes--refresh-inline-image abs-path)))
             (goto-char (cdr loc))
             (org-writenotes--parse-subtree-at-point))))
      (setq org-writenotes--active-node-id (plist-get snapshot :nodeId))
      (org-writenotes--broadcast-notification "emacs.focusNode" snapshot)
      snapshot)))

(defun org-writenotes--handle-delete-ink-block (params)
  "Delete an `.svgz' handwritten ink block from the Org node specified by PARAMS.
PARAMS contains:
- `nodeId': Org ID of the node
- `fileName': The file name of the `.svgz' drawing (e.g. \"heading-timestamp.svgz\")
- `deleteFile': Non-nil (default t) to delete the physical file on disk."
  (let* ((node-id (alist-get 'nodeId params))
         (filename (alist-get 'fileName params))
         (delete-file-p (if (null (assq 'deleteFile params)) t (alist-get 'deleteFile params)))
         (loc (org-writenotes--locate-node node-id)))
    (unless loc
      (error "Node not found: %s" node-id))
    (unless (and filename (stringp filename) (not (string-empty-p filename)))
      (error "Missing or invalid fileName for node.deleteInkBlock"))
    (let ((snapshot
           (with-current-buffer (car loc)
             (save-excursion
               (goto-char (cdr loc))
               (let* ((beg (point))
                      (org-file (buffer-file-name))
                      (img-dir (org-writenotes--resolve-image-dir org-file))
                      (bare-filename (file-name-nondirectory filename))
                      (abs-path (expand-file-name bare-filename img-dir))
                      (sub-end (save-excursion (org-end-of-subtree t t) (point)))
                      (file-regex (format "\\[\\[\\(?:file:\\|attachment:\\)[^]\n]*?%s\\(?:\\]\\[[^]\n]*\\)?\\]\\]"
                                          (regexp-quote bare-filename))))
                 ;; Locate the link within this subtree
                 (goto-char beg)
                 (if (re-search-forward file-regex sub-end t)
                     (let* ((link-beg (match-beginning 0))
                            (link-end (match-end 0))
                            (line-beg (line-beginning-position))
                            (line-end (line-end-position))
                            (line-str (string-trim (buffer-substring-no-properties line-beg line-end))))
                       (if (string= line-str (buffer-substring-no-properties link-beg link-end))
                           ;; Line only contains the image link
                           (delete-region line-beg (min (point-max) (1+ line-end)))
                         ;; Line contains additional text
                         (delete-region link-beg link-end))
                       ;; Clean up any excessive blank lines
                       (save-excursion
                         (goto-char (max (point-min) (- (point) 2)))
                         (let ((cur-sub-end (save-excursion (org-end-of-subtree t t) (point))))
                           (while (re-search-forward "\n\\{3,\\}" cur-sub-end t)
                             (replace-match "\n\n" nil nil)))))
                   (message "[Org-WriteNotes] Warning: Link for '%s' not found in subtree" bare-filename))
                 ;; Delete file on disk if requested
                 (when (and delete-file-p (file-exists-p abs-path))
                   (ignore-errors (delete-file abs-path)))
                 (save-buffer)
                 (org-writenotes--refresh-inline-image abs-path)))
             (goto-char (cdr loc))
             (org-writenotes--parse-subtree-at-point))))
      (setq org-writenotes--active-node-id (plist-get snapshot :nodeId))
      (org-writenotes--broadcast-notification "emacs.focusNode" snapshot)
      snapshot)))

(defun org-writenotes--handle-ink-commit (params)
  "Write base64-encoded `.svgz' bytes to the common directory and refresh Emacs inline display."
  (let* ((node-id (alist-get 'nodeId params))
         (filename (alist-get 'fileName params))
         (b64 (alist-get 'svgzBase64 params))
         (loc (org-writenotes--locate-node node-id)))
    (unless (and filename b64)
      (error "Missing fileName or svgzBase64 in ink.commit"))
    (let* ((org-file (when loc (buffer-file-name (car loc))))
           (img-dir (org-writenotes--resolve-image-dir org-file))
           (abs-path (expand-file-name (file-name-nondirectory filename) img-dir))
           (raw-bytes (base64-decode-string b64)))
      (org-writenotes--write-raw-bytes abs-path raw-bytes)
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
                            (ash len -8)
                            (logand len #xff)))
           (t
            (unibyte-string #x81 127
                            0 0 0 0
                            (ash len -24)
                            (logand (ash len -16) #xff)
                            (logand (ash len -8) #xff)
                            (logand len #xff))))))
    (concat header payload)))

(defun org-writenotes--ws-try-decode-frame (buffer-bytes)
  "Try to parse a single RFC 6455 frame from unibyte BUFFER-BYTES.
Returns `(opcode payload-string remaining-bytes)' or nil if incomplete."
  (let ((total (length buffer-bytes)))
    (when (>= total 2)
      (let* ((b0 (aref buffer-bytes 0))
             (b1 (aref buffer-bytes 1))
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
            (setq payload-len (+ (ash (aref buffer-bytes 2) 8)
                                 (aref buffer-bytes 3))
                  offset 4)))
         ((= len-indicator 127)
          (when (>= total 10)
            (setq payload-len (+ (ash (aref buffer-bytes 6) 24)
                                 (ash (aref buffer-bytes 7) 16)
                                 (ash (aref buffer-bytes 8) 8)
                                 (aref buffer-bytes 9))
                  offset 10))))
        (let ((mask-len (if masked 4 0)))
          (when (and payload-len (>= total (+ offset mask-len payload-len)))
            (let* ((mask-key (when masked
                               (substring buffer-bytes offset (+ offset 4))))
                   (data-start (+ offset mask-len))
                   (data-end (+ data-start payload-len))
                   (raw (substring buffer-bytes data-start data-end))
                   (unmasked
                    (if masked
                        (let ((out (make-string payload-len 0)))
                          (dotimes (i payload-len)
                            (aset out i (logxor (aref raw i)
                                                (aref mask-key (mod i 4)))))
                          out)
                      raw))
                   (rest (substring buffer-bytes data-end)))
              (list opcode
                    (decode-coding-string unmasked 'utf-8)
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
  (condition-case err
      (let* ((json-object-type 'alist)
             (json-array-type 'list)
             (json-key-type 'symbol)
             (req (json-read-from-string msg-text))
             (id (alist-get 'id req))
             (method (alist-get 'method req))
             (params (alist-get 'params req))
             (result nil))
        (setq result
              (pcase method
                ("session.hello"
                 `(:emacsVersion ,emacs-version
                   :orgVersion ,(org-version)
                   :imageDir ,org-writenotes-image-dir
                   :activeNodeId ,(or org-writenotes--active-node-id :null)))
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
                 ;; Acknowledge live stroke delta
                 `(:ok t :strokeId ,(or (alist-get 'strokeId params) :null)))
                ("ink.commit"
                 (org-writenotes--handle-ink-commit params))
                (_
                 (error "Unknown JSON-RPC method: %s" method))))
        (when id
          (org-writenotes--ws-send-json
           proc
           `(:jsonrpc "2.0" :id ,id :result ,result))))
    (error
     (message "[Org-WriteNotes] RPC Error: %s" (error-message-string err)))))

(defun org-writenotes--client-filter (proc chunk)
  "Network filter for WebSocket handshake and frame decoding on PROC."
  (let ((buf (concat (or (process-get proc :recv-buf) "")
                     (string-to-unibyte chunk))))
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
                (setq buf rest)
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
                (setq buf rem)
                (cond
                 ((= opcode 1) ;; Text frame
                  (org-writenotes--dispatch-rpc proc payload))
                 ((= opcode 8) ;; Close frame
                  (setq org-writenotes--clients (delq proc org-writenotes--clients))
                  (delete-process proc)
                  (setq continue nil))
                 ((= opcode 9) ;; Ping -> Pong (echo payload)
                  (let* ((pong-bytes (encode-coding-string payload 'utf-8))
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
  "Asynchronously run `adb reverse tcp:PORT tcp:PORT' without blocking Emacs."
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
    (setq org-writenotes--active-node-id (org-writenotes--node-id-at-point))
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
  (save-excursion
    (org-back-to-heading t)
    (let* ((node-id (org-writenotes--node-id-at-point))
           (snapshot (org-writenotes--handle-insert-ink-block
                      `((nodeId . ,node-id)))))
      (org-writenotes--broadcast-notification "emacs.focusNode" snapshot)
      (message "[Org-WriteNotes] Created .svgz sketch and pushed to tablet!"))))

;;;###autoload
(defun org-writenotes-delete-sketch-at-point ()
  "Delete the `.svgz' handwritten sketch under point, its link in the buffer, and file on disk."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org-mode buffer"))
  (let* ((line-str (buffer-substring-no-properties (line-beginning-position) (line-end-position)))
         (matched (string-match "\\[\\[\\(?:file:\\|attachment:\\)\\([^]\n]+\\.svgz?\\)\\(?:\\]\\[[^]\n]*\\)?\\]\\]" line-str)))
    (unless matched
      (user-error "No .svgz sketch link found on current line"))
    (let* ((rel-path (match-string 1 line-str))
           (filename (file-name-nondirectory rel-path))
           (org-file (buffer-file-name))
           (img-dir (org-writenotes--resolve-image-dir org-file))
           (abs-path (expand-file-name filename img-dir)))
      (when (yes-or-no-p (format "Delete sketch image '%s' and remove file from disk? " filename))
        (let* ((link-beg (+ (line-beginning-position) (match-beginning 0)))
               (link-end (+ (line-beginning-position) (match-end 0)))
               (line-beg (line-beginning-position))
               (line-end (line-end-position))
               (trimmed (string-trim line-str)))
          (if (string= trimmed (buffer-substring-no-properties link-beg link-end))
              (delete-region line-beg (min (point-max) (1+ line-end)))
            (delete-region link-beg link-end)))
        (when (file-exists-p abs-path)
          (ignore-errors (delete-file abs-path)))
        (save-buffer)
        (org-writenotes--refresh-inline-image abs-path)
        (save-excursion
          (when (org-back-to-heading t)
            (let ((snapshot (org-writenotes--parse-subtree-at-point)))
              (org-writenotes--broadcast-notification "emacs.focusNode" snapshot))))
        (message "[Org-WriteNotes] Deleted sketch '%s'." filename)))))

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
            (org-writenotes-push-node))))
    (error
     (message "[Org-WriteNotes] follow-mode warning: %s" (error-message-string err)))))

;;;###autoload
(define-minor-mode org-writenotes-follow-mode
  "Minor mode to automatically sync the tablet view with the Org heading at point."
  :global t
  :lighter " [OrgWrite✍️]"
  (if org-writenotes-follow-mode
      (progn
        (org-writenotes--ensure-server-and-adb)
        (add-hook 'post-command-hook #'org-writenotes--follow-post-command))
    (remove-hook 'post-command-hook #'org-writenotes--follow-post-command)))

(org-writenotes-enable-svgz-inline-images)

(when org-writenotes-auto-start
  (ignore-errors
    (org-writenotes--ensure-server-and-adb)))

(provide 'org-writenotes)
;;; org-writenotes.el ends here
