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

(ert-deftest org-writenotes-extras-resolve-conflict ()
  "Conflict info returns both copies; each choice writes the right bytes and retires the copy."
  (org-writenotes-test--with-dir d
    (let ((f (expand-file-name "s.svgz" d))
          (org-writenotes-sketch-history-min-interval 0))
      (cl-letf (((symbol-function 'org-writenotes--resolve-sketch-path) (lambda (_) f))
                ((symbol-function 'org-writenotes--resolve-image-dir) (lambda (_) d))
                ((symbol-function 'org-writenotes--refresh-inline-image) #'ignore)
                ((symbol-function 'org-writenotes--locate-node) (lambda (_) nil)))
        (cl-flet ((make-conflict (tablet)
                    (org-writenotes--write-raw-bytes f "disk")
                    (org-writenotes--handle-ink-commit
                     `((nodeId . "n") (fileName . "s.svgz") (baseEtag . "stale")
                       (svgzBase64 . ,(base64-encode-string tablet))))
                    (sleep-for 1.1))
                  (resolve (choice &optional b64)
                    (org-writenotes--handle-ink-resolve-conflict
                     `((nodeId . "n") (fileName . "s.svgz") (choice . ,choice)
                       ,@(when b64 `((svgzBase64 . ,b64)))))))
          (make-conflict "tablet")
          (let ((info (org-writenotes--handle-ink-conflict-info '((nodeId . "n") (fileName . "s.svgz")))))
            (should (equal (base64-decode-string (plist-get info :emacsSvgzBase64)) "disk"))
            (should (equal (base64-decode-string (plist-get info :tabletSvgzBase64)) "tablet")))
          ;; Keep Emacs: disk untouched, conflict copy moved into .history/
          (should (= 0 (plist-get (resolve "emacs") :remainingConflicts)))
          (should (equal (org-writenotes--read-raw-bytes f) "disk"))
          (should (directory-files (org-writenotes--history-dir f) nil "conflict"))
          ;; Keep tablet
          (make-conflict "tablet2")
          (resolve "tablet")
          (should (equal (org-writenotes--read-raw-bytes f) "tablet2"))
          ;; Merged bytes from the tablet
          (make-conflict "tablet3")
          (let ((res (resolve "merged" (base64-encode-string "union"))))
            (should (equal (org-writenotes--read-raw-bytes f) "union"))
            (should (equal (plist-get res :etag) (secure-hash 'sha1 "union"))))
          (should-error (resolve "emacs")))))))

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

(ert-deftest org-writenotes-extras-linux-commands ()
  "F1: Linux companion and single-sketch popup commands invoke the launcher."
  (should (eq (lookup-key org-writenotes-command-map (kbd "d"))
              #'org-writenotes-connect-linux))
  (should (eq (lookup-key org-writenotes-command-map (kbd "s"))
              #'org-writenotes-popup-sketch-at-point))
  (org-writenotes-test--with-dir d
    (let* ((org-file (expand-file-name "linux-test.org" d))
           (svgz-file (expand-file-name "writenotes/sketch1.svgz" d))
           (spawned-args nil)
           (dummy-proc (make-pipe-process :name "wn-linux-test" :noquery t)))
      (unwind-protect
          (progn
            (make-directory (file-name-directory svgz-file) t)
            (with-temp-file svgz-file (insert "dummy"))
            (with-current-buffer (find-file-noselect org-file)
              (org-mode)
              (insert "* Heading\n:PROPERTIES:\n:ID: linux-node-1\n:END:\n[[file:./writenotes/sketch1.svgz]]\n")
              (save-buffer)
              (goto-char (point-min))
              (search-forward "sketch1.svgz")
              (cl-letf (((symbol-function 'org-writenotes-start-server) #'ignore)
                        ((symbol-function 'start-process)
                         (lambda (_name _buf &rest args)
                           (setq spawned-args args)
                           dummy-proc)))
                (org-writenotes-popup-sketch-at-point)
                (should (member "--sketch" spawned-args))
                (should (member svgz-file spawned-args)))
              (kill-buffer)))
        (delete-process dummy-proc)))))

(ert-deftest org-writenotes-extras-ipad-commands ()
  "F2: iPadOS pairing URI generation and command keybinding work as expected."
  (should (eq (lookup-key org-writenotes-command-map (kbd "i"))
              #'org-writenotes-connect-ipad))
  (let ((uri (org-writenotes--format-ipad-connect-uri "100.64.1.12" 9876 "tok123")))
    (should (equal uri "orgwritenotes://connect?host=100.64.1.12&port=9876&token=tok123")))
  (let ((org-writenotes--session-token "secret-ipad-tok")
        (org-writenotes-port 9876))
    (cl-letf (((symbol-function 'org-writenotes-start-server) #'ignore)
              ((symbol-function 'org-writenotes--get-tailscale-ip) (lambda () "100.88.1.9"))
              ((symbol-function 'pop-to-buffer) #'ignore))
      (let ((generated (org-writenotes-connect-ipad nil)))
        (should (equal generated
                       "orgwritenotes://connect?host=100.88.1.9&port=9876&token=secret-ipad-tok"))))))

(ert-deftest org-writenotes-extras-broadcast-frame-cache ()
  "Broadcasting to N clients serializes and frames the JSON payload only once."
  (let* ((c1 (make-pipe-process :name "wn-c1" :noquery t))
         (c2 (make-pipe-process :name "wn-c2" :noquery t))
         (c3 (make-pipe-process :name "wn-c3" :noquery t))
         (org-writenotes--clients (list c1 c2 c3))
         (org-writenotes--ws-frame-cache nil)
         (encode-calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'org-writenotes--ws-encode-frame)
                   (lambda (s) (cl-incf encode-calls) (concat "FRAME:" s))))
          (org-writenotes--broadcast-notification "emacs.themeChanged" '(:isDark t))
          (should (= encode-calls 1))
          (should (consp org-writenotes--ws-frame-cache)))
      (delete-process c1)
      (delete-process c2)
      (delete-process c3))))

(ert-deftest org-writenotes-extras-multi-client-sync ()
  "Multiple clients on the same node sync mutations, strokes, and commits without echoing or disturbing clients on other nodes."
  (org-writenotes-test--with-dir d
    (let* ((org-file (expand-file-name "multi.org" d))
           (svgz-file (expand-file-name "writenotes/s1.svgz" d))
           (client-a (make-pipe-process :name "wn-mc-a" :noquery t))
           (client-b (make-pipe-process :name "wn-mc-b" :noquery t))
           (client-c (make-pipe-process :name "wn-mc-c" :noquery t))
           (org-writenotes--clients (list client-a client-b client-c))
           (sent nil)
           node-1 node-2)
      (unwind-protect
          (progn
            (make-directory (file-name-directory svgz-file) t)
            (org-writenotes--create-blank-svgz svgz-file 1200 600 40 40)
            (with-current-buffer (find-file-noselect org-file)
              (org-mode)
              (insert "* Node One\n"
                      ":PROPERTIES:\n:ID: mc-node-1\n:END:\n"
                      "- [ ] Check item\n"
                      "[[file:./writenotes/s1.svgz]]\n"
                      "* Node Two\n"
                      ":PROPERTIES:\n:ID: mc-node-2\n:END:\n"
                      "Initial paragraph on node two.\n")
              (basic-save-buffer)
              (setq node-1 (format "file:%s::id:mc-node-1" org-file)
                    node-2 (format "file:%s::id:mc-node-2" org-file)
                    org-writenotes--active-node-id node-1)
              (dolist (c (list client-a client-b client-c))
                (process-put c :authed t)
                (process-put c 'presence-ok t))
              (process-put client-a 'active-node node-1)
              (process-put client-b 'active-node node-1)
              (process-put client-c 'active-node node-2)
              (setq org-writenotes--last-presence (org-writenotes--presence-list))
              (cl-letf (((symbol-function 'org-writenotes--ws-send-json)
                         (lambda (proc payload)
                           (push (cons proc payload) sent)))
                        ((symbol-function 'org-writenotes--refresh-inline-image) #'ignore))
                ;; 1. Client A toggles checkbox on Node 1 -> A gets RPC result, B gets nodeModified, C gets nothing.
                (setq sent nil)
                (org-writenotes--dispatch-rpc
                 client-a
                 (json-serialize
                  `(:jsonrpc "2.0" :id 10 :method "node.toggleCheckbox"
                    :params (:nodeId ,node-1 :line 5 :state "checked"))))
                (let ((a-msgs (cl-remove-if-not (lambda (x) (eq (car x) client-a)) sent))
                      (b-msgs (cl-remove-if-not (lambda (x) (eq (car x) client-b)) sent))
                      (c-msgs (cl-remove-if-not (lambda (x) (eq (car x) client-c)) sent)))
                  (should (= (length a-msgs) 1))
                  (should (equal (plist-get (cdr (car a-msgs)) :id) 10))
                  (should (= (length b-msgs) 1))
                  (should (equal (plist-get (cdr (car b-msgs)) :method) "emacs.nodeModified"))
                  (should (null c-msgs)))

                ;; 2. Client A sends ink.delta on Node 1 -> B gets relayed ink.delta, A and C do not.
                (setq sent nil)
                (org-writenotes--dispatch-rpc
                 client-a
                 (json-serialize
                  `(:jsonrpc "2.0" :id 11 :method "ink.delta"
                    :params (:nodeId ,node-1 :fileName "s1.svgz" :strokeId "st-1"
                             :pathXml "<path id=\"st-1\" d=\"M 0 0 L 10 10\"/>"))))
                (let ((b-msgs (cl-remove-if-not (lambda (x) (eq (car x) client-b)) sent))
                      (c-msgs (cl-remove-if-not (lambda (x) (eq (car x) client-c)) sent)))
                  (should (= (length b-msgs) 1))
                  (should (equal (plist-get (cdr (car b-msgs)) :method) "ink.delta"))
                  (should (equal (plist-get (plist-get (cdr (car b-msgs)) :params) :strokeId) "st-1"))
                  (should (null c-msgs)))

                ;; 3. Client A commits new .svgz bytes on Node 1 -> B gets emacs.nodeModified with updated svgzBase64 & etag.
                (setq sent nil)
                (let ((new-b64 (base64-encode-string "updated-svgz-binary" t))
                      (expected-etag (secure-hash 'sha1 "updated-svgz-binary")))
                  (org-writenotes--dispatch-rpc
                   client-a
                   (json-serialize
                    `(:jsonrpc "2.0" :id 12 :method "ink.commit"
                      :params (:nodeId ,node-1 :fileName "s1.svgz" :svgzBase64 ,new-b64))))
                  (let* ((b-msgs (cl-remove-if-not (lambda (x) (eq (car x) client-b)) sent))
                         (c-msgs (cl-remove-if-not (lambda (x) (eq (car x) client-c)) sent))
                         (b-snap (plist-get (cdr (car b-msgs)) :params))
                         (b-blocks (append (plist-get b-snap :blocks) nil))
                         (ink-blk (cl-find-if (lambda (b) (equal (plist-get b :type) "ink_canvas")) b-blocks)))
                    (should (= (length b-msgs) 1))
                    (should (equal (plist-get (cdr (car b-msgs)) :method) "emacs.nodeModified"))
                    (should (equal (plist-get ink-blk :svgzBase64) new-b64))
                    (should (equal (plist-get ink-blk :etag) expected-etag))
                    (should (null c-msgs)))

                  ;; 3b. Client B commits on top of the pushed sketch -> succeeds without conflict and notifies Client A.
                  (setq sent nil)
                  (let ((b2-b64 (base64-encode-string "updated-svgz-from-b" t)))
                    (org-writenotes--dispatch-rpc
                     client-b
                     (json-serialize
                      `(:jsonrpc "2.0" :id 13 :method "ink.commit"
                        :params (:nodeId ,node-1 :fileName "s1.svgz"
                                 :baseEtag "stale-etag-before-push"
                                 :svgzBase64 ,b2-b64))))
                    (let* ((b-resp (cdr (cl-find-if (lambda (x) (and (eq (car x) client-b)
                                                                     (plist-get (cdr x) :id)))
                                                    sent)))
                           (a-msgs (cl-remove-if-not (lambda (x) (eq (car x) client-a)) sent)))
                      (should-not (plist-get (plist-get b-resp :result) :conflict))
                      (should (= (length a-msgs) 1))
                      (should (equal (plist-get (cdr (car a-msgs)) :method) "emacs.nodeModified")))))

                ;; 4. Direct Emacs edit in Node 2 pushes emacs.nodeModified to Client C (watching Node 2) only.
                (goto-char (point-min))
                (search-forward "* Node Two")
                (org-writenotes--parse-subtree-at-point t)
                (goto-char (point-max))
                (insert "Added line in Emacs for Node Two.\n")
                (setq sent nil)
                (setq org-writenotes--changed-buffers (list (current-buffer)))
                (org-writenotes--change-debounce-tick)
                (let ((a-msgs (cl-remove-if-not (lambda (x) (eq (car x) client-a)) sent))
                      (b-msgs (cl-remove-if-not (lambda (x) (eq (car x) client-b)) sent))
                      (c-msgs (cl-remove-if-not (lambda (x) (eq (car x) client-c)) sent)))
                  (should (null a-msgs))
                  (should (null b-msgs))
                  (should (= (length c-msgs) 1))
                  (should (equal (plist-get (cdr (car c-msgs)) :method) "emacs.nodeModified"))
                  (should (equal (plist-get (plist-get (cdr (car c-msgs)) :params) :nodeId) node-2))))
              (set-buffer-modified-p nil)
              (kill-buffer)))
        (delete-process client-a)
        (delete-process client-b)
        (delete-process client-c)))))


