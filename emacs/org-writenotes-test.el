;;; org-writenotes-test.el --- ERT Test Suite for Org-WriteNotes -*- lexical-binding: t; -*-

;;; Commentary:
;; Run in batch mode with:
;;   emacs -Q -batch -L emacs -l ert -l emacs/org-writenotes-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org)
(require 'org-writenotes)

(ert-deftest org-writenotes-test-ws-frame-roundtrip ()
  "Verify RFC 6455 WebSocket server frame encoding and decoding."
  (let* ((payload "{\"jsonrpc\":\"2.0\",\"method\":\"node.get\"}")
         (encoded (org-writenotes--ws-encode-frame payload))
         (decoded (org-writenotes--ws-try-decode-frame encoded)))
    (should decoded)
    (should (= (nth 0 decoded) 1))
    (should (equal (nth 1 decoded) payload))))

(ert-deftest org-writenotes-test-svgz-creation-and-dimension-parsing ()
  "Verify blank .svgz creation produces a gzip SVG with the right size."
  (let ((tmp-file (make-temp-file "org-wn-test-" nil ".svgz")))
    (unwind-protect
        (progn
          (org-writenotes--create-blank-svgz tmp-file 1200 600 0 40)
          (should (file-exists-p tmp-file))
          (let ((svg (with-temp-buffer
                       (set-buffer-multibyte nil)
                       (insert-file-contents-literally tmp-file)
                       (when (zlib-decompress-region (point-min) (point-max))
                         (buffer-string)))))
            (should (stringp svg))
            (should (string-match "viewBox=\"0 0 1200 600\"" svg))))
      (when (file-exists-p tmp-file)
        (delete-file tmp-file)))))

(ert-deftest org-writenotes-test-parse-subtree-blocks-and-hierarchy ()
  "Verify parsing of checklists (including partial [-]), code blocks, tables, breadcrumbs, and subheadings."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent Project\n"
            "** TODO [#A] Architecture Node :design:ink:\n"
            "SCHEDULED: <2026-11-03 Tue>\n"
            ":PROPERTIES:\n"
            ":ID: test-node-arch-1\n"
            ":END:\n"
            "Intro paragraph text.\n"
            "- [ ] Unchecked item\n"
            "- [-] Partial item\n"
            "- [X] Checked item\n"
            "#+BEGIN_SRC emacs-lisp\n"
            "(+ 1 2)\n"
            "#+END_SRC\n"
            "| Name | Score |\n"
            "|------+-------|\n"
            "| Alice | 95 |\n"
            "*** Child Subtask 1\n")
    (goto-char (point-min))
    (re-search-forward "^\\*\\* TODO")
    (beginning-of-line)
    (let* ((snap (org-writenotes--parse-subtree-at-point))
           (header (plist-get snap :header))
           (blocks (append (plist-get snap :blocks) nil))
           (subheadings (append (plist-get snap :subheadings) nil)))
      (should (string-suffix-p "::id:test-node-arch-1" (plist-get snap :nodeId)))
      (should (equal (plist-get header :title) "Architecture Node"))
      (should (equal (plist-get header :todoKeyword) "TODO"))
      (should (equal (plist-get header :priority) "A"))
      (should (equal (append (plist-get header :breadcrumbs) nil)
                     '("Parent Project" "Architecture Node")))
      (should (= (length subheadings) 1))
      (should (equal (plist-get (car subheadings) :title) "Child Subtask 1"))
      ;; Blocks: paragraph, checklist, code_block, table
      (should (cl-some (lambda (b) (equal (plist-get b :type) "checklist")) blocks))
      (should (cl-some (lambda (b) (equal (plist-get b :type) "code_block")) blocks))
      (should (cl-some (lambda (b) (equal (plist-get b :type) "table")) blocks)))))

(ert-deftest org-writenotes-test-parse-sketch-after-paragraph ()
  "Verify inserting and parsing a sketch link after a paragraph does not clobber match-data."
  (let* ((tmp-dir (make-temp-file "org-wn-sketch-test-" t))
         (tmp-svgz (expand-file-name "test-sketch.svgz" tmp-dir)))
    (unwind-protect
        (progn
          (org-writenotes--create-blank-svgz tmp-svgz 1200 600 40 40)
          (with-temp-buffer
            (org-mode)
            (setq buffer-file-name (expand-file-name "test.org" tmp-dir))
            (insert "* TODO Node with Sketch\n"
                    ":PROPERTIES:\n:ID: test-sketch-node-1\n:END:\n"
                    "Leading paragraph before the sketch.\n"
                    (format "[[file:%s]]\n" tmp-svgz)
                    "\nTrailing paragraph.\n")
            (goto-char (point-min))
            (let* ((snap (org-writenotes--parse-subtree-at-point))
                   (blocks (append (plist-get snap :blocks) nil)))
              (should (= (length blocks) 3))
              (should (equal (plist-get (nth 0 blocks) :type) "paragraph"))
              (should (equal (plist-get (nth 1 blocks) :type) "ink_canvas"))
              (should (equal (plist-get (nth 1 blocks) :fileName) "test-sketch.svgz"))
              (should (equal (plist-get (nth 2 blocks) :type) "paragraph")))))
      (delete-directory tmp-dir t))))

(ert-deftest org-writenotes-test-checklist-and-table-mutations ()
  "Verify checklist partial state, checklist item edit/indent, and table cell update."
  (let ((tmp-org (make-temp-file "org-wn-mut-" nil ".org"))
        (node-id nil))
    (unwind-protect
        (with-current-buffer (find-file-noselect tmp-org)
          (org-mode)
          (insert "* TODO Mutation Test\n"
                  ":PROPERTIES:\n"
                  ":ID: mut-node-1\n"
                  ":END:\n"
                  "- [ ] Item A\n"
                  "- [ ] Item B\n"
                  "| Col1 | Col2 |\n"
                  "| Val1 | Val2 |\n")
          (basic-save-buffer)
          (setq node-id (format "file:%s::id:mut-node-1" tmp-org))
          ;; Toggle partial state on line 5 ("- [ ] Item A")
          (org-writenotes--handle-toggle-checkbox
           `((nodeId . ,node-id) (line . 5) (state . "partial")))
          (goto-char (point-min))
          (should (re-search-forward "^- \\[-\\] Item A" nil t))
          ;; Update checklist item text and indent
          (org-writenotes--handle-update-checklist-item
           `((nodeId . ,node-id) (line . 5) (text . "Item A Updated") (action . "indent")))
          (goto-char (point-min))
          (should (re-search-forward "^  - \\[-\\] Item A Updated" nil t))
          ;; Update table cell (row 1, col 1 -> "UpdatedVal")
          (org-writenotes--handle-update-table-cell
           `((nodeId . ,node-id) (startLine . 7) (row . 1) (col . 1) (value . "UpdatedVal")))
          (goto-char (point-min))
          (should (re-search-forward "UpdatedVal" nil t))
          (kill-buffer))
      (when (file-exists-p tmp-org)
        (delete-file tmp-org)))))

(ert-deftest org-writenotes-test-svg-theme-adaptation ()
  "Verify SVG background replacement and light<->dark adaptation do not corrupt XML tags."
  (let* ((svg-sample (concat "<svg id=\"write-document\">\n"
                             "<rect id=\"write-doc-background\" width=\"100%\" height=\"100%\" fill=\"#808080\"/>\n"
                             "<rect class=\"pagerect\" fill=\"#FFFDF8\" stroke=\"none\" x=\"0\" y=\"0\" width=\"1200\" height=\"600\" />\n"
                             "<path stroke=\"#000000\" d=\"M0 0 L10 10\"/>\n"
                             "<path fill=\"#1E293B\" d=\"M20 20 L30 30\"/>\n"
                             "</svg>"))
         (svg-white-paper (concat "<svg id=\"write-document\">\n"
                                  "<rect id=\"write-doc-background\" width=\"100%\" height=\"100%\" fill=\"#808080\"/>\n"
                                  "<g class=\"write-content\" papercolor=\"#FFFFFF\">\n"
                                  "<rect class=\"pagerect\" fill=\"#FFFFFF\" stroke=\"none\" x=\"0\" y=\"0\" width=\"1440\" height=\"1728\" />\n"
                                  "<path class=\"write-round-pen\" fill=\"#000000\" d=\"M0 0 L10 10\"/>\n"
                                  "<path class=\"write-flat-pen\" fill=\"#FFFFFF\" d=\"M20 20 L30 30\"/>\n"
                                  "</g></svg>"))
         (svg-dark-paper (concat "<svg id=\"write-document\">\n"
                                 "<rect id=\"write-doc-background\" width=\"100%\" height=\"100%\" fill=\"#808080\"/>\n"
                                 "<g class=\"write-content\" papercolor=\"#000000\">\n"
                                 "<rect class=\"pagerect\" fill=\"#000000\" stroke=\"none\" x=\"0\" y=\"0\" width=\"1440\" height=\"1728\" />\n"
                                 "<path class=\"write-round-pen\" fill=\"#000000\" d=\"M0 0 L10 10\"/>\n"
                                 "</g></svg>"))
         (replaced (org-writenotes--replace-pagerect-fill svg-sample "#292b2e")))
    ;; Must not have nested/corrupted rect tags like <rect <rect ...
    (should-not (string-match-p "<rect[^>]*<rect" replaced))
    (should (string-match-p "<rect id=\"write-doc-background\" width=\"100%\" height=\"100%\" fill=\"#292b2e\"/>" replaced))
    (should (string-match-p "<rect class=\"pagerect\" fill=\"#292b2e\" stroke=\"none\" x=\"0\" y=\"0\" width=\"1200\" height=\"600\" />" replaced))
    ;; Light -> Dark -> Light adaptation check
    (cl-letf (((symbol-function 'org-writenotes--emacs-is-dark-p) (lambda () nil))
              ((symbol-function 'face-background) (lambda (&rest _) "#ffffff"))
              ((symbol-function 'face-foreground) (lambda (&rest _) "#5f5f87")))
      (let ((light-adapted (org-writenotes--adapt-svg-xml-for-theme svg-sample))
            (white-light-adapted (org-writenotes--adapt-svg-xml-for-theme svg-white-paper)))
        (should (stringp light-adapted))
        (should-not (string-match-p "<rect[^>]*<rect" light-adapted))
        ;; Pure-white paper in light theme must keep #FFFFFF on .pagerect and #write-doc-background,
        ;; while adapting white pen strokes to frame-fg (#5F5F87).
        (should (string-match-p "<rect id=\"write-doc-background\" width=\"100%\" height=\"100%\" fill=\"#FFFFFF\"/>" white-light-adapted))
        (should (string-match-p "<rect class=\"pagerect\" fill=\"#FFFFFF\"" white-light-adapted))
        (should (string-match-p "<path class=\"write-round-pen\" fill=\"#000000\"" white-light-adapted))
        (should (string-match-p "<path class=\"write-flat-pen\" fill=\"#5F5F87\"" white-light-adapted))))
    (cl-letf (((symbol-function 'org-writenotes--emacs-is-dark-p) (lambda () t))
              ((symbol-function 'face-background) (lambda (&rest _) "#292b2e"))
              ((symbol-function 'face-foreground) (lambda (&rest _) "#b2b2b2")))
      (let ((dark-adapted (org-writenotes--adapt-svg-xml-for-theme svg-sample))
            (dark-paper-adapted (org-writenotes--adapt-svg-xml-for-theme svg-dark-paper)))
        (should (stringp dark-adapted))
        (should-not (string-match-p "<rect[^>]*<rect" dark-adapted))
        (should-not (string-match-p "fill=\"#FFFDF8\"" dark-adapted))
        ;; Dark paper in dark theme must keep dark #000000 on .pagerect, while strokes adapt to #B2B2B2.
        (should (string-match-p "<rect class=\"pagerect\" fill=\"#000000\"" dark-paper-adapted))
        (should (string-match-p "<path class=\"write-round-pen\" fill=\"#B2B2B2\"" dark-paper-adapted))))))

;; Agenda must return only what Emacs' own day agenda shows, not every TODO.
(ert-deftest org-writenotes-test-agenda-only-today ()
  "Verify the agenda filter returns today's, overdue and timed entries only."
  (let* ((tmp (make-temp-file "org-wn-agenda-" nil ".org"))
         (today (format-time-string "%Y-%m-%d %a")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "* TODO Today task\nSCHEDULED: <" today ">\n"
                    "* TODO Overdue thing\nSCHEDULED: <2020-01-01 Wed>\n"
                    "* TODO Meeting\n<" today " 14:30>\n"
                    "* TODO Far future\nSCHEDULED: <2099-05-01 Fri>\n"
                    "* TODO Undated task\n"))
          (let* ((org-agenda-files (list tmp))
                 (nodes (append (org-writenotes--collect-node-summaries "agenda" nil nil) nil))
                 (titles (mapcar (lambda (n) (plist-get n :title)) nodes)))
            ;; Timed entry sorts first.
            (should (equal (car titles) "Meeting"))
            (should (equal (plist-get (car nodes) :agendaLabel) "14:30"))
            (should (member "Today task" titles))
            (should (member "Overdue thing" titles))
            (should-not (member "Far future" titles))
            (should-not (member "Undated task" titles))))
      (let ((buf (find-buffer-visiting tmp)))
        (when buf (kill-buffer buf)))
      (delete-file tmp))))

(ert-deftest org-writenotes-test-search-capped-and-deduped ()
  "Verify search matches body text once per heading and honours the result cap."
  (let ((tmp (make-temp-file "org-wn-search-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file tmp
            (insert "* Banana heading\nbanana banana banana\n"
                    "** Child\nmentions banana\n"
                    "* Other\nnothing here\n")
            (dotimes (i 30) (insert (format "* Fruit %d\nbanana\n" i))))
          (let ((org-agenda-files (list tmp)))
            (let ((titles (mapcar (lambda (n) (plist-get n :title))
                                  (org-writenotes--collect-node-summaries "search" "banana"))))
              (should (equal (seq-take titles 2) '("Banana heading" "Child")))
              (should-not (member "Other" titles))
              (should (= (length titles) (length (delete-dups (copy-sequence titles))))))
            (let ((org-writenotes-search-max-results 5))
              (should (= 5 (length (org-writenotes--collect-node-summaries "search" "banana")))))
            (should (= 0 (length (org-writenotes--collect-node-summaries "search" "b"))))))
      (let ((buf (find-buffer-visiting tmp)))
        (when buf (kill-buffer buf)))
      (delete-file tmp))))

;; Idle-time OCR: recognition must wait for Emacs idleness and a quiet sketch.
(defmacro org-writenotes-test--with-ocr-sketch (vars org-text &rest body)
  "Run BODY with VARS = (ORG-FILE NODE-ID SVGZ) bound to a temp sketch fixture.
ORG-TEXT is the content of the Org file; the OCR helper counts as installed."
  (declare (indent 2))
  (let ((dir (make-symbol "dir")))
    `(let* ((,dir (make-temp-file "org-wn-ocr-" t))
            (,(nth 0 vars) (expand-file-name "notes.org" ,dir))
            (,(nth 1 vars) (format "file:%s::line:1" ,(nth 0 vars)))
            (,(nth 2 vars) (expand-file-name "writenotes/sketch.svgz" ,dir))
            (org-writenotes-ocr-enabled t)
            (org-writenotes-ocr-idle-seconds 5))
       (make-directory (file-name-directory ,(nth 2 vars)) t)
       (with-temp-file ,(nth 2 vars)
         (set-buffer-multibyte nil)
         (insert "svgz-bytes-1"))
       (with-temp-file ,(nth 0 vars) (insert ,org-text))
       (unwind-protect
           (cl-letf (((symbol-function 'org-writenotes--ocr-available-p) (lambda () t)))
             ,@body)
         (org-writenotes--ocr-shutdown)
         (clrhash org-writenotes--ocr-done)
         (let ((buf (find-buffer-visiting ,(nth 0 vars))))
           (when buf
             (with-current-buffer buf (set-buffer-modified-p nil))
             (kill-buffer buf)))
         (delete-directory ,dir t)))))

(defun org-writenotes-test--file-string (file)
  "Return the contents of FILE as a string."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(defun org-writenotes-test--backdate-ocr (path)
  "Make the queued commit for PATH old enough to count as quiet."
  (let ((entry (copy-sequence (gethash path org-writenotes--ocr-pending))))
    (puthash path (plist-put entry :time (- (float-time) 60)) org-writenotes--ocr-pending)))

(ert-deftest org-writenotes-test-ocr-needs-idle-emacs-and-quiet-sketch ()
  "OCR is due only when Emacs is idle and the sketch has not changed recently."
  (let ((org-writenotes-ocr-idle-seconds 5)
        (old (- (float-time) 10))
        (fresh (float-time)))
    (cl-letf (((symbol-function 'org-writenotes--idle-seconds) (lambda () 10)))
      (should (org-writenotes--ocr-quiet-p old))
      (should-not (org-writenotes--ocr-quiet-p fresh)))
    (cl-letf (((symbol-function 'org-writenotes--idle-seconds) (lambda () 2)))
      (should-not (org-writenotes--ocr-quiet-p old)))
    (cl-letf (((symbol-function 'org-writenotes--idle-seconds) (lambda () nil)))
      (should-not (org-writenotes--ocr-quiet-p old)))))

(ert-deftest org-writenotes-test-ocr-idle-job-writes-drawer-once ()
  "A quiet queued sketch is recognised once; unchanged bytes are not re-run."
  (org-writenotes-test--with-ocr-sketch (org-file node-id svgz)
      "* Sketch node\n[[file:./writenotes/sketch.svgz]]\n"
    (let ((calls 0))
      (cl-letf (((symbol-function 'org-writenotes--idle-seconds) (lambda () 60))
                ((symbol-function 'org-writenotes--ocr-run-helper)
                 (lambda (_bytes callback)
                   (cl-incf calls)
                   (funcall callback "Architecture Overview"))))
        (org-writenotes--ocr-enqueue svgz node-id "sketch.svgz")
        ;; Just committed: Emacs is idle but the sketch is not quiet yet.
        (org-writenotes--ocr-tick)
        (should (= calls 0))
        (should (= 1 (hash-table-count org-writenotes--ocr-pending)))
        (org-writenotes-test--backdate-ocr svgz)
        (org-writenotes--ocr-tick)
        (should (= calls 1))
        (should (= 0 (hash-table-count org-writenotes--ocr-pending)))
        (should (string-match-p ":WRITENOTES_OCR:\nArchitecture Overview\n:END:"
                                (org-writenotes-test--file-string org-file)))
        ;; Same bytes committed again: already recognised, helper stays idle.
        (org-writenotes--ocr-enqueue svgz node-id "sketch.svgz")
        (org-writenotes-test--backdate-ocr svgz)
        (org-writenotes--ocr-tick)
        (should (= calls 1))))))

(ert-deftest org-writenotes-test-ocr-waits-while-emacs-is-busy ()
  "Nothing runs while Emacs is in use, however old the queued commit is."
  (org-writenotes-test--with-ocr-sketch (org-file node-id svgz)
      "* Sketch node\n[[file:./writenotes/sketch.svgz]]\n"
    (let ((calls 0))
      (cl-letf (((symbol-function 'org-writenotes--idle-seconds) (lambda () 1))
                ((symbol-function 'org-writenotes--ocr-run-helper)
                 (lambda (_bytes callback) (cl-incf calls) (funcall callback "x"))))
        (org-writenotes--ocr-enqueue svgz node-id "sketch.svgz")
        (org-writenotes-test--backdate-ocr svgz)
        (org-writenotes--ocr-tick)
        (should (= calls 0))
        (should (= 1 (hash-table-count org-writenotes--ocr-pending)))
        ;; `org-writenotes-ocr-run-now' overrides the idle requirement.
        (org-writenotes-ocr-run-now)
        (should (= calls 1))
        (should (= 0 (hash-table-count org-writenotes--ocr-pending)))))))

(ert-deftest org-writenotes-test-ocr-failed-helper-leaves-drawer-and-queue-empty ()
  "A failing helper must not clobber the drawer or retry in a loop."
  (org-writenotes-test--with-ocr-sketch (org-file node-id svgz)
      "* Sketch node\n[[file:./writenotes/sketch.svgz]]\n:WRITENOTES_OCR:\nOLD\n:END:\n"
    (let ((calls 0))
      (cl-letf (((symbol-function 'org-writenotes--idle-seconds) (lambda () 60))
                ((symbol-function 'org-writenotes--ocr-run-helper)
                 (lambda (_bytes callback) (cl-incf calls) (funcall callback nil))))
        (org-writenotes--ocr-enqueue svgz node-id "sketch.svgz")
        (org-writenotes-test--backdate-ocr svgz)
        (org-writenotes--ocr-tick)
        (should (= calls 1))
        (should (= 0 (hash-table-count org-writenotes--ocr-pending)))
        (should (string-match-p "OLD" (org-writenotes-test--file-string org-file)))))))

(ert-deftest org-writenotes-test-ocr-replaces-existing-drawer-instead-of-stacking ()
  "Fresh OCR text replaces the old drawer; drawers must never pile up."
  (org-writenotes-test--with-ocr-sketch (org-file node-id svgz)
      "* Sketch node\n[[file:./writenotes/sketch.svgz]]\n:WRITENOTES_OCR:\nOLD TEXT\n:END:\nBody text\n"
    (org-writenotes--update-ocr-drawer node-id "sketch.svgz" "NEW TEXT" t)
    (org-writenotes--update-ocr-drawer node-id "sketch.svgz" "NEWER TEXT" t)
    (let ((content (org-writenotes-test--file-string org-file)))
      (should (string-match-p "NEWER TEXT" content))
      (should-not (string-match-p "OLD TEXT\\|NEW TEXT" content))
      (should (= 1 (with-temp-buffer
                     (insert content)
                     (goto-char (point-min))
                     (let ((n 0))
                       (while (search-forward ":WRITENOTES_OCR:" nil t) (cl-incf n))
                       n))))
      (should (string-match-p "Body text" content)))))

(ert-deftest org-writenotes-test-ocr-off-by-default-and-drops-queue ()
  "OCR is disabled by default; switching it off empties the queue without running."
  (should-not (default-value 'org-writenotes-ocr-enabled))
  (org-writenotes-test--with-ocr-sketch (org-file node-id svgz)
      "* Sketch node\n[[file:./writenotes/sketch.svgz]]\n"
    (let ((calls 0))
      (cl-letf (((symbol-function 'org-writenotes--idle-seconds) (lambda () 60))
                ((symbol-function 'org-writenotes--ocr-run-helper)
                 (lambda (_bytes callback) (cl-incf calls) (funcall callback "x"))))
        (org-writenotes--ocr-enqueue svgz node-id "sketch.svgz")
        (org-writenotes-test--backdate-ocr svgz)
        (should (= 1 (hash-table-count org-writenotes--ocr-pending)))
        (cl-letf (((symbol-function 'org-writenotes--ocr-available-p) (lambda () nil)))
          (org-writenotes--ocr-tick)
          (org-writenotes--ocr-enqueue svgz node-id "sketch.svgz"))
        (should (= calls 0))
        (should (= 0 (hash-table-count org-writenotes--ocr-pending)))))))

(ert-deftest org-writenotes-test-ocr-run-now-explains-why-it-cannot-run ()
  "`org-writenotes-ocr-run-now' says whether OCR is off or the helper is missing."
  (let ((org-writenotes-ocr-enabled nil))
    (should (string-match-p "OCR is off"
                            (cadr (should-error (org-writenotes-ocr-run-now) :type 'user-error)))))
  (let ((org-writenotes-ocr-enabled t)
        (org-writenotes-ocr-python "/nonexistent/python"))
    (should (string-match-p "Python not found"
                            (cadr (should-error (org-writenotes-ocr-run-now) :type 'user-error)))))
  (let ((org-writenotes-ocr-enabled t)
        (org-writenotes-ocr-python "/bin/sh")
        (org-writenotes-ocr-script "/nonexistent/recognize.py"))
    (should (string-match-p "script not found"
                            (cadr (should-error (org-writenotes-ocr-run-now) :type 'user-error))))))

(ert-deftest org-writenotes-test-ocr-parse-output ()
  "The helper's JSON line is turned into newline-joined text."
  (should (equal (org-writenotes--ocr-parse-output
                  "{\"lines\": [\"first\", \"second\"], \"device\": \"cpu\"}\n")
                 "first\nsecond"))
  (should (equal (org-writenotes--ocr-parse-output "{\"lines\": []}") ""))
  (should-not (org-writenotes--ocr-parse-output "not json")))

(ert-deftest org-writenotes-test-ink-commit-keeps-drawer-and-queues-ocr ()
  "With the OCR helper present, a commit queues the sketch and keeps the old drawer."
  (org-writenotes-test--with-ocr-sketch (org-file node-id svgz)
      "* Sketch node\n[[file:./writenotes/sketch.svgz]]\n:WRITENOTES_OCR:\nOLD TEXT\n:END:\n"
    (org-writenotes--handle-ink-commit
     `((nodeId . ,node-id) (fileName . "sketch.svgz")
       (svgzBase64 . ,(base64-encode-string "svgz-bytes-2" t))))
    (should (string-match-p "OLD TEXT" (org-writenotes-test--file-string org-file)))
    (should (gethash svgz org-writenotes--ocr-pending))))

(ert-deftest org-writenotes-test-ink-commit-without-helper-drops-stale-drawer ()
  "Without the OCR helper, the pre-existing behaviour (drop stale drawer) is kept."
  (org-writenotes-test--with-ocr-sketch (org-file node-id svgz)
      "* Sketch node\n[[file:./writenotes/sketch.svgz]]\n:WRITENOTES_OCR:\nOLD TEXT\n:END:\n"
    (cl-letf (((symbol-function 'org-writenotes--ocr-available-p) (lambda () nil)))
      (org-writenotes--handle-ink-commit
       `((nodeId . ,node-id) (fileName . "sketch.svgz")
         (svgzBase64 . ,(base64-encode-string "svgz-bytes-2" t)))))
    (should-not (string-match-p "OLD TEXT" (org-writenotes-test--file-string org-file)))
    (should-not (gethash svgz org-writenotes--ocr-pending))))

(ert-deftest org-writenotes-test-compensate-nonscaling-ruling-strokes ()
  "Ruling stroke widths are divided by the display scale; pen strokes are untouched."
  (let* ((svg (concat "<svg xmlns=\"http://www.w3.org/2000/svg\">"
                      "<svg class=\"write-page\" x=\"10\" y=\"0\" width=\"1200px\" height=\"400px\">"
                      "<g class=\"write-content\">"
                      "<g class=\"ruleline write-std-ruling\" stroke-width=\"1\" "
                      "vector-effect=\"non-scaling-stroke\">"
                      "<path stroke-width=\"2.2\" d=\"M0 40\"/>"
                      "<g><path stroke-width=\"3\" d=\"M0 1\"/></g>"
                      "<path d=\"M0 80\"/></g>"
                      "<path class=\"write-round-pen\" fill=\"#000\" stroke-width=\"2.6\" d=\"M1 1\"/>"
                      "</g></svg></svg>"))
         (out (org-writenotes--compensate-nonscaling-strokes svg 0.5)))
    (should (string-match-p "class=\"ruleline write-std-ruling\" stroke-width=\"2\"" out))
    (should (string-match-p "stroke-width=\"4.4\" d=\"M0 40\"" out))
    (should (string-match-p "stroke-width=\"6\" d=\"M0 1\"" out))
    (should (string-match-p "stroke-width=\"2.6\" d=\"M1 1\"" out))
    (should (equal svg (org-writenotes--compensate-nonscaling-strokes svg 1.0)))
    (should (equal svg (org-writenotes--compensate-nonscaling-strokes svg nil)))))

(ert-deftest org-writenotes-test-compensate-strokes-fades-with-scale ()
  "Shrunken template strokes get wider but keep the same total ink."
  (let* ((plain "<g class=\"ruleline\" stroke=\"#475569\" stroke-width=\"1.1\"><path d=\"M0 0\"/></g>")
         (with-opacity (concat "<g class=\"ruleline\" stroke-opacity=\"0.29\" stroke-width=\"1\">"
                               "<path stroke-opacity=\"0.5\" d=\"M0 0\"/></g>")))
    ;; Zoomed out: width / scale, opacity * scale; a group without opacity gets one.
    (let ((out (org-writenotes--compensate-nonscaling-strokes plain 0.5)))
      (should (string-match-p "stroke-width=\"2.2\"" out))
      (should (string-match-p "stroke-opacity=\"0.5\">" out)))
    (let ((out (org-writenotes--compensate-nonscaling-strokes with-opacity 0.5)))
      (should (string-match-p "stroke-opacity=\"0.145\"" out))
      (should (string-match-p "stroke-opacity=\"0.25\" d=" out))
      (should (= 1 (with-temp-buffer
                     (insert out) (goto-char (point-min))
                     (let ((n 0)) (while (search-forward "<g " nil t) (cl-incf n)) n)))))
    ;; Shown larger than native: width is held at one pixel but nothing fades.
    (let ((out (org-writenotes--compensate-nonscaling-strokes with-opacity 2.0)))
      (should (string-match-p "stroke-width=\"0.5\"" out))
      (should (string-match-p "stroke-opacity=\"0.29\"" out))
      (should-not (string-match-p "stroke-opacity=\"0.25\"" out)))))

(ert-deftest org-writenotes-test-inline-scale-follows-image-props ()
  "The scale Emacs applies is derived from the page width and image props."
  (let ((svg (concat "<svg><svg class=\"write-page\" __comx=\"NaN\" x=\"10\" y=\"0\" "
                     "width=\"1200px\" height=\"1360px\"></svg></svg>")))
    (should (= 1220 (org-writenotes--svg-native-width svg)))
    (should (< (abs (- 0.623 (org-writenotes--inline-scale 1220 '(:max-width 760)))) 0.001))
    (should (= 1.0 (org-writenotes--inline-scale 1220 '(:max-width 2000))))
    (should (= 0.5 (org-writenotes--inline-scale 1000 '(:width 500))))
    (should (= 1.0 (org-writenotes--inline-scale 1000 nil)))
    (should-not (org-writenotes--inline-scale nil '(:max-width 760)))))

(provide 'org-writenotes-test)
;;; org-writenotes-test.el ends here
