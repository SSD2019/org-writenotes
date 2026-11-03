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
         (replaced (org-writenotes--replace-pagerect-fill svg-sample "#292b2e")))
    ;; Must not have nested/corrupted rect tags like <rect <rect ...
    (should-not (string-match-p "<rect[^>]*<rect" replaced))
    (should (string-match-p "<rect id=\"write-doc-background\" width=\"100%\" height=\"100%\" fill=\"#292b2e\"/>" replaced))
    (should (string-match-p "<rect class=\"pagerect\" fill=\"#292b2e\" stroke=\"none\" x=\"0\" y=\"0\" width=\"1200\" height=\"600\" />" replaced))
    ;; Light -> Dark -> Light adaptation check
    (cl-letf (((symbol-function 'org-writenotes--emacs-is-dark-p) (lambda () nil)))
      (let ((light-adapted (org-writenotes--adapt-svg-xml-for-theme svg-sample)))
        (should (stringp light-adapted))
        (should-not (string-match-p "<rect[^>]*<rect" light-adapted))))
    (cl-letf (((symbol-function 'org-writenotes--emacs-is-dark-p) (lambda () t)))
      (let ((dark-adapted (org-writenotes--adapt-svg-xml-for-theme svg-sample)))
        (should (stringp dark-adapted))
        (should-not (string-match-p "<rect[^>]*<rect" dark-adapted))
        (should-not (string-match-p "fill=\"#FFFDF8\"" dark-adapted))))))

(provide 'org-writenotes-test)
;;; org-writenotes-test.el ends here
