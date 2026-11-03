;;; org-writenotes-extras-test.el --- ERT tests for org-writenotes-extras -*- lexical-binding: t; -*-

;;; Commentary:
;;   emacs -Q -batch -L emacs -l ert -l emacs/org-writenotes-extras-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'org-writenotes-extras)

(defmacro org-writenotes-test--with-dir (var &rest body)
  "Bind VAR to a fresh temp dir while running BODY."
  (declare (indent 1))
  `(let ((,var (make-temp-file "wn-extras" t)))
     (unwind-protect (progn ,@body) (delete-directory ,var t))))

(ert-deftest org-writenotes-extras-atomic-write ()
  (org-writenotes-test--with-dir d
    (let ((f (expand-file-name "a.svgz" d)))
      (org-writenotes--write-raw-bytes f "one")
      (org-writenotes--write-raw-bytes f "two")
      (should (equal (org-writenotes--read-raw-bytes f) "two"))
      (should (equal (directory-files d nil "tmp-") nil)))))

(ert-deftest org-writenotes-extras-history-prune ()
  (org-writenotes-test--with-dir d
    (let ((f (expand-file-name "a.svgz" d))
          (org-writenotes-sketch-history-depth 3)
          (org-writenotes-sketch-history-min-interval 0))
      (dotimes (i 5)
        (org-writenotes--write-raw-bytes f (format "v%d" i))
        (org-writenotes--snapshot-sketch f)
        (sleep-for 0.01))
      (let ((snaps (org-writenotes--list-snapshots f)))
        (should (= (length snaps) 3))
        (should (equal (org-writenotes--read-raw-bytes (car snaps)) "v4"))))))

(ert-deftest org-writenotes-extras-commit-dedupe-and-conflict ()
  (org-writenotes-test--with-dir d
    (let ((f (expand-file-name "s.svgz" d)))
      (cl-letf (((symbol-function 'org-writenotes--resolve-sketch-path) (lambda (_) f))
                ((symbol-function 'org-writenotes--resolve-image-dir) (lambda (_) d))
                ((symbol-function 'org-writenotes--refresh-inline-image) #'ignore)
                ((symbol-function 'org-writenotes--locate-node) (lambda (_) nil)))
        (org-writenotes--write-raw-bytes f "disk")
        (let* ((same (org-writenotes--handle-ink-commit
                      `((nodeId . "n") (fileName . "s.svgz")
                        (svgzBase64 . ,(base64-encode-string "disk"))))))
          (should (plist-get same :unchanged)))
        (let ((res (org-writenotes--handle-ink-commit
                    `((nodeId . "n") (fileName . "s.svgz") (baseEtag . "stale")
                      (svgzBase64 . ,(base64-encode-string "tablet"))))))
          (should (plist-get res :conflict))
          (should (equal (org-writenotes--read-raw-bytes f) "disk")))
        (let ((res (org-writenotes--handle-ink-commit
                    `((nodeId . "n") (fileName . "s.svgz")
                      (baseEtag . ,(secure-hash 'sha1 "disk"))
                      (svgzBase64 . ,(base64-encode-string "new"))))))
          (should-not (plist-get res :conflict))
          (should (equal (org-writenotes--read-raw-bytes f) "new"))
          (should (= (length (org-writenotes--list-snapshots f)) 1)))))))

(ert-deftest org-writenotes-extras-repair-links ()
  (org-writenotes-test--with-dir d
    (make-directory (expand-file-name "writenotes/sub" d) t)
    (org-writenotes--write-raw-bytes (expand-file-name "writenotes/sub/x.svgz" d) "x")
    (with-temp-buffer
      (setq default-directory (file-name-as-directory d))
      (insert "[[file:./writenotes/x.svgz]]\n")
      (cl-letf (((symbol-function 'org-writenotes--resolve-image-dir)
                 (lambda (_) (expand-file-name "writenotes" d))))
        (should (= (org-writenotes-repair-links) 1)))
      (should (string-match-p "writenotes/sub/x.svgz" (buffer-string))))))

(ert-deftest org-writenotes-extras-protocol-golden-fixture ()
  "Verify shared protocol fixture test-fixtures/protocol-golden.json."
  (let* ((fixture-file (or (let ((f (expand-file-name "test-fixtures/protocol-golden.json")))
                             (and (file-exists-p f) f))
                           (let ((f (expand-file-name "../test-fixtures/protocol-golden.json"
                                                      (file-name-directory (or load-file-name buffer-file-name default-directory)))))
                             (and (file-exists-p f) f))))
         (json-object-type 'alist)
         (json-array-type 'list)
         (json-key-type 'symbol)
         (data (when fixture-file
                 (json-read-file fixture-file))))
    (should data)
    (should (= (alist-get 'protocolVersion data) 2))
    (let* ((handshake (alist-get 'handshake data))
           (params (alist-get 'params handshake)))
      (should (equal (alist-get 'method handshake) "session.hello"))
      (should (= (alist-get 'protocolVersion params) 2)))))

(ert-deftest org-writenotes-extras-mtime-cache ()
  "C5: cache hits only while the file mtime is unchanged."
  (org-writenotes-test--with-dir d
    (let ((f (expand-file-name "c.svgz" d)))
      (org-writenotes--write-raw-bytes f "x")
      (should-not (org-writenotes--cached-svg-for-file f))
      (org-writenotes--put-cached-svg-for-file f "<svg/>")
      (should (equal (org-writenotes--cached-svg-for-file f) "<svg/>"))
      (set-file-times f (time-add (current-time) 100))
      (should-not (org-writenotes--cached-svg-for-file f)))))

(ert-deftest org-writenotes-extras-html-filter ()
  "C7: <img src=...svgz> is replaced by inline SVG for html only."
  (org-writenotes-test--with-dir d
    (let* ((f (expand-file-name "i.svgz" d))
           (text (format "<img src=\"%s\" alt=\"\"/>" f)))
      (cl-letf (((symbol-function 'org-writenotes--read-and-repair-svgz)
                 (lambda (_) "<?xml version=\"1.0\"?>\n<svg id=\"inline\"></svg>")))
        (let ((out (org-writenotes--html-link-filter text 'html nil)))
          (should (string-match-p "<svg id=\"inline\"" out))
          (should-not (string-match-p "<img" out)))
        (should (equal (org-writenotes--html-link-filter text 'latex nil) text))
        (let ((org-writenotes-html-inline-svgz nil))
          (should (equal (org-writenotes--html-link-filter text 'html nil) text)))))))

(ert-deftest org-writenotes-extras-backlinks ()
  "C3: backlinks find entries linking to a sketch by file name."
  (org-writenotes-test--with-dir d
    (let ((org (expand-file-name "n.org" d)))
      (with-temp-file org
        (insert "* One\n[[file:./writenotes/a.svgz]]\n* Two\nnothing\n"))
      (cl-letf (((symbol-function 'org-writenotes--backlink-files) (lambda () (list org))))
        (let ((hits (org-writenotes-sketch-backlinks "/elsewhere/a.svgz")))
          (should (= (length hits) 1))
          (should (equal (nth 2 (car hits)) "One")))
        (should-not (org-writenotes-sketch-backlinks "missing.svgz"))))))

(ert-deftest org-writenotes-extras-locate-node-fallback ()
  "C2: nodes resolve through the ID database when the file path is stale."
  (let ((buf (generate-new-buffer "wn-id")))
    (unwind-protect
        (with-current-buffer buf
          (insert "x")
          (let ((m (point-marker)))
            (cl-letf (((symbol-function 'org-id-find) (lambda (_id _m) m)))
              (let ((loc (org-writenotes--locate-node "file:/gone.org::id:abc")))
                (should (eq (car loc) buf))))))
      (kill-buffer buf))))

(ert-deftest org-writenotes-extras-extra-files ()
  "C2: `org-writenotes-extra-files' join the candidate buffer list."
  (org-writenotes-test--with-dir d
    (let* ((f (expand-file-name "extra.org" d))
           (org-writenotes-extra-files (list f)))
      (with-temp-file f (insert "* A\n"))
      (let ((bufs (org-writenotes--candidate-org-buffers)))
        (should (cl-some (lambda (b) (equal (buffer-file-name b) f)) bufs))
        (mapc (lambda (b) (when (equal (buffer-file-name b) f) (kill-buffer b))) bufs)))))

(ert-deftest org-writenotes-extras-presence ()
  "E5: presence lists authenticated clients with their active node."
  (let* ((a (make-pipe-process :name "wn-a" :noquery t))
         (b (make-pipe-process :name "wn-b" :noquery t))
         (org-writenotes--clients (list a b))
         (sent nil))
    (unwind-protect
        (progn
          (process-put a 'presence-ok t)
          (process-put a 'client-name "Tablet A")
          (process-put a 'active-node "file:x.org::id:1")
          (let ((lst (org-writenotes--presence-list)))
            (should (= (length lst) 1))
            (should (equal (plist-get (car lst) :name) "Tablet A"))
            (should (equal (plist-get (car lst) :node) "file:x.org::id:1")))
          (process-put b 'presence-ok t)
          (should (= (length (org-writenotes--presence-list)) 2))
          (cl-letf (((symbol-function 'org-writenotes--broadcast-notification)
                     (lambda (m p) (push (cons m p) sent))))
            (setq org-writenotes--last-presence nil)
            (org-writenotes--broadcast-presence)
            (org-writenotes--broadcast-presence)
            (should (= (length sent) 1))
            (should (equal (car (car sent)) "presence.update"))
            (org-writenotes--broadcast-presence t)
            (should (= (length sent) 2))))
      (delete-process a)
      (delete-process b))))

(provide 'org-writenotes-extras-test)
;;; org-writenotes-extras-test.el ends here

(ert-deftest org-writenotes-extras-unauthenticated-rpc-rejected ()
  (let (sent)
    (cl-letf (((symbol-function 'org-writenotes--ws-send-json)
               (lambda (_p payload) (push payload sent)))
              ((symbol-function 'process-get) (lambda (&rest _) nil)))
      (org-writenotes--dispatch-rpc 'fake "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"node.list\"}")
      (should (plist-get (car sent) :error))
      (setq sent nil)
      (org-writenotes--dispatch-rpc 'fake "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"presence.list\"}")
      (should (plist-get (car sent) :error)))))

(ert-deftest org-writenotes-extras-ws-frame-needed ()
  (let ((frame (org-writenotes--ws-encode-frame (make-string 300 ?a))))
    (should (null (org-writenotes--ws-frame-needed (substring frame 0 3))))
    (should (= (org-writenotes--ws-frame-needed (substring frame 0 4)) (length frame)))))
