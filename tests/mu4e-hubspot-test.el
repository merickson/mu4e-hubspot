;;; mu4e-hubspot-test.el --- Tests for mu4e-hubspot -*- lexical-binding: t; -*-

;;; Commentary:

;; Address-extraction tests operate on plain mu4e message plists, and
;; session-cache tests operate on the buffer-local cache directly, so
;; neither requires a running mu4e session or network access.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'mu4e-hubspot)

(defun mu4e-hubspot-test--contact (name email)
  (list :name name :email email))

(ert-deftest mu4e-hubspot-test-view-addresses-dedup-and-downcase ()
  (let ((msg (list :from (list (mu4e-hubspot-test--contact "Alice" "Alice@Example.com"))
                    :cc (list (mu4e-hubspot-test--contact "Bob" "bob@example.com")
                              (mu4e-hubspot-test--contact "Alice2" "alice@example.com")))))
    (should (equal (mu4e-hubspot--view-addresses msg)
                    '("alice@example.com" "bob@example.com")))))

(ert-deftest mu4e-hubspot-test-view-addresses-ignores-to-and-bcc ()
  (let ((msg (list :from (list (mu4e-hubspot-test--contact "Alice" "alice@example.com"))
                    :to (list (mu4e-hubspot-test--contact "Carl" "carl@example.com"))
                    :bcc (list (mu4e-hubspot-test--contact "Dana" "dana@example.com")))))
    (should (equal (mu4e-hubspot--view-addresses msg) '("alice@example.com")))))

(ert-deftest mu4e-hubspot-test-view-addresses-empty ()
  (should (null (mu4e-hubspot--view-addresses (list :from nil :cc nil)))))

(defun mu4e-hubspot-test--with-headers (headers body-fn)
  "Run BODY-FN in a temp buffer containing HEADERS (an alist of
name . value) followed by a blank line, the way `message-fetch-field'
expects a message-mode buffer to be laid out."
  (with-temp-buffer
    (dolist (header headers)
      (insert (format "%s: %s\n" (car header) (cdr header))))
    (insert "\n")
    (goto-char (point-min))
    (funcall body-fn)))

(ert-deftest mu4e-hubspot-test-compose-addresses-dedup-and-downcase ()
  (mu4e-hubspot-test--with-headers
   '(("To" . "Alice Smith <Alice@Example.com>")
     ("Cc" . "bob@example.com, alice@example.com"))
   (lambda ()
     (should (equal (mu4e-hubspot--compose-addresses)
                     '("alice@example.com" "bob@example.com"))))))

(ert-deftest mu4e-hubspot-test-compose-addresses-includes-bcc ()
  (mu4e-hubspot-test--with-headers
   '(("To" . "carl@example.com")
     ("Bcc" . "dana@example.com"))
   (lambda ()
     (should (equal (mu4e-hubspot--compose-addresses)
                     '("carl@example.com" "dana@example.com"))))))

(ert-deftest mu4e-hubspot-test-compose-addresses-empty ()
  (mu4e-hubspot-test--with-headers
   '(("Subject" . "hi"))
   (lambda ()
     (should (null (mu4e-hubspot--compose-addresses))))))

(ert-deftest mu4e-hubspot-test-compose-mime-parts-multipart-html ()
  "org-mime-style <#multipart>/<#part> MML markup should yield the
real text/html and text/plain part contents, not raw MML source."
  (mu4e-hubspot-test--with-headers
   '(("To" . "bob@example.com") ("Subject" . "hi"))
   (lambda ()
     (goto-char (point-max))
     (insert "<#multipart type=alternative>\n")
     (insert "<#part type=text/plain>\n")
     (insert "Plain version.\n")
     (insert "<#part type=text/html>\n")
     (insert "<p>HTML <b>version</b>.</p>\n")
     (insert "<#/multipart>\n")
     (let ((parts (mu4e-hubspot--compose-mime-parts)))
       (should (equal (string-trim (car parts)) "<p>HTML <b>version</b>.</p>"))
       (should (equal (string-trim (cdr parts)) "Plain version."))))))

(ert-deftest mu4e-hubspot-test-compose-mime-parts-plain-draft-returns-nil ()
  "A plain draft with no MML markup has no html part to extract, so
callers fall back to `mu4e-hubspot--compose-body-text'."
  (mu4e-hubspot-test--with-headers
   '(("To" . "bob@example.com") ("Subject" . "hi"))
   (lambda ()
     (goto-char (point-max))
     (insert "Just a plain draft, no MML markup here.\n")
     (should (null (mu4e-hubspot--compose-mime-parts))))))

(ert-deftest mu4e-hubspot-test-compose-mime-parts-does-not-modify-buffer ()
  (mu4e-hubspot-test--with-headers
   '(("To" . "bob@example.com") ("Subject" . "hi"))
   (lambda ()
     (goto-char (point-max))
     (insert "<#multipart type=alternative>\n<#part type=text/plain>\nP\n<#part type=text/html>\n<p>H</p>\n<#/multipart>\n")
     (let ((before (buffer-string)))
       (mu4e-hubspot--compose-mime-parts)
       (should (equal (buffer-string) before))))))

(ert-deftest mu4e-hubspot-test-session-cache-reuses-within-session ()
  (with-temp-buffer
    (let* ((calls 0)
           (fetch (lambda () (setq calls (1+ calls)) 'value)))
      (should (eq (mu4e-hubspot--session-cache-get "msg-1" "a@b.com" fetch) 'value))
      (should (eq (mu4e-hubspot--session-cache-get "msg-1" "a@b.com" fetch) 'value))
      (should (= calls 1)))))

(ert-deftest mu4e-hubspot-test-session-cache-tracks-each-email-separately ()
  (with-temp-buffer
    (let* ((calls 0)
           (fetch (lambda () (setq calls (1+ calls)) calls)))
      (should (= (mu4e-hubspot--session-cache-get "msg-1" "a@b.com" fetch) 1))
      (should (= (mu4e-hubspot--session-cache-get "msg-1" "c@d.com" fetch) 2))
      (should (= (mu4e-hubspot--session-cache-get "msg-1" "a@b.com" fetch) 1)))))

(ert-deftest mu4e-hubspot-test-session-cache-resets-on-new-session ()
  (with-temp-buffer
    (let* ((calls 0)
           (fetch (lambda () (setq calls (1+ calls)) calls)))
      (should (= (mu4e-hubspot--session-cache-get "msg-1" "a@b.com" fetch) 1))
      (should (= (mu4e-hubspot--session-cache-get "msg-2" "a@b.com" fetch) 2)))))

(ert-deftest mu4e-hubspot-test-contact-pairs ()
  (let ((msg (list :from (list (mu4e-hubspot-test--contact "Alice" "alice@example.com")))))
    (should (equal (mu4e-hubspot--contact-pairs msg :from)
                    '(("alice@example.com" . "Alice"))))))

(ert-deftest mu4e-hubspot-test-header-address-pairs ()
  (mu4e-hubspot-test--with-headers
   '(("To" . "Alice Smith <alice@example.com>"))
   (lambda ()
     (should (equal (mu4e-hubspot--header-address-pairs "To")
                     '(("alice@example.com" . "Alice Smith")))))))

(ert-deftest mu4e-hubspot-test-header-address-pairs-no-name ()
  (mu4e-hubspot-test--with-headers
   '(("To" . "bob@example.com"))
   (lambda ()
     (should (equal (mu4e-hubspot--header-address-pairs "To")
                     '(("bob@example.com" . nil)))))))

(ert-deftest mu4e-hubspot-test-strip-rendered-headers ()
  (should (equal (mu4e-hubspot--strip-rendered-headers
                   "From: Alice\nSubject: hi\n\nHello there.\n")
                   "Hello there."))
  (should (equal (mu4e-hubspot--strip-rendered-headers "no blank line here")
                   "no blank line here")))

;;; Selectable candidates / confirm dispatch

(defun mu4e-hubspot-test--sample-suggestion ()
  (make-mu4e-hubspot-suggestion
   :email "alice@example.com"
   :contact '((id . "1")
              (properties . ((firstname . "Alice") (lastname . "A") (email . "alice@example.com"))))
   :companies '(((id . "5") (properties . ((name . "Acme")))))
   :deals nil))

(defmacro mu4e-hubspot-test--with-rendered-buffer (source &rest body)
  "Run BODY in a fresh mu4e-hubspot-suggestions-mode buffer rendered
with one sample suggestion and tagged with SOURCE, point on the first
candidate line (the matched contact)."
  (declare (indent 1))
  `(let ((buf (generate-new-buffer "*mu4e-hubspot-test*")))
     (unwind-protect
         (with-current-buffer buf
           (mu4e-hubspot-suggestions-mode)
           (setq mu4e-hubspot--address-suggestions
                 (list (cons "alice@example.com" (mu4e-hubspot-test--sample-suggestion))))
           (setq mu4e-hubspot--source ,source)
           (mu4e-hubspot--render)
           (goto-char (point-min))
           (forward-line 1)
           ,@body)
       (kill-buffer buf))))

(ert-deftest mu4e-hubspot-test-toggle-candidate-selects-and-deselects ()
  (mu4e-hubspot-test--with-rendered-buffer (list :kind 'view :key "k" :msg nil)
    (mu4e-hubspot-toggle-candidate)
    (should (= (length (mu4e-hubspot--selected-candidates)) 1))
    (mu4e-hubspot-toggle-candidate)
    (should (= (length (mu4e-hubspot--selected-candidates)) 0))))

(ert-deftest mu4e-hubspot-test-toggle-candidate-requires-candidate-at-point ()
  (mu4e-hubspot-test--with-rendered-buffer (list :kind 'view :key "k" :msg nil)
    (goto-char (point-min))
    (should-error (mu4e-hubspot-toggle-candidate) :type 'user-error)))

(ert-deftest mu4e-hubspot-test-confirm-associations-requires-selection ()
  (mu4e-hubspot-test--with-rendered-buffer (list :kind 'view :key "k" :msg nil)
    (should-error (mu4e-hubspot-confirm-associations) :type 'user-error)))

(ert-deftest mu4e-hubspot-test-confirm-associations-view-writes-immediately ()
  (let (called)
    (cl-letf (((symbol-function 'mu4e-hubspot--log-view-message-now)
               (lambda (msg associations) (setq called (list msg associations)))))
      (mu4e-hubspot-test--with-rendered-buffer (list :kind 'view :key "k" :msg 'the-msg)
        (mu4e-hubspot-toggle-candidate)
        (mu4e-hubspot-confirm-associations)))
    (should (equal called (list 'the-msg '(("contacts" . "1")))))))

(ert-deftest mu4e-hubspot-test-confirm-associations-compose-defers ()
  (let (staged)
    (cl-letf (((symbol-function 'mu4e-hubspot--stage-for-send)
               (lambda (compose-buffer associations) (setq staged (list compose-buffer associations)))))
      (mu4e-hubspot-test--with-rendered-buffer
          (list :kind 'compose :key 'compose-buf :buffer 'compose-buf)
        (mu4e-hubspot-toggle-candidate)
        (mu4e-hubspot-confirm-associations)))
    (should (equal staged (list 'compose-buf '(("contacts" . "1")))))))

(ert-deftest mu4e-hubspot-test-display-resets-selection-only-on-new-key ()
  (unwind-protect
      (progn
        (mu4e-hubspot--display
         (list (cons "alice@example.com" (mu4e-hubspot-test--sample-suggestion)))
         (list :kind 'view :key "msg-1" :msg nil))
        (with-current-buffer mu4e-hubspot--buffer-name
          (goto-char (point-min))
          (forward-line 1)
          (mu4e-hubspot-toggle-candidate)
          (push (mu4e-hubspot--named-candidate "companies" "Company" 'name
                                                 '((id . "99") (properties . ((name . "Globex")))))
                mu4e-hubspot--manual-candidates)
          (should (= (length (mu4e-hubspot--selected-candidates)) 1)))
        ;; Same key (e.g. a compose refresh): selection survives.
        (mu4e-hubspot--display
         (list (cons "alice@example.com" (mu4e-hubspot-test--sample-suggestion)))
         (list :kind 'view :key "msg-1" :msg nil))
        (with-current-buffer mu4e-hubspot--buffer-name
          (should (= (length (mu4e-hubspot--selected-candidates)) 1))
          (should (= (length mu4e-hubspot--manual-candidates) 1)))
        ;; Different key (a different message): selection resets.
        (mu4e-hubspot--display
         (list (cons "alice@example.com" (mu4e-hubspot-test--sample-suggestion)))
         (list :kind 'view :key "msg-2" :msg nil))
        (with-current-buffer mu4e-hubspot--buffer-name
          (should (= (length (mu4e-hubspot--selected-candidates)) 0))
          (should (null mu4e-hubspot--manual-candidates))))
    (when (get-buffer mu4e-hubspot--buffer-name)
      (kill-buffer mu4e-hubspot--buffer-name))))

(ert-deftest mu4e-hubspot-test-suggestions-mode-map-bindings ()
  "Regression test: toggling and confirming must be bound in the
suggestions buffer's OWN keymap (not just reachable via some
inherited default), or SPC/RET fall through to `special-mode's
scrolling commands / self-insert and the buffer appears \"stuck\"
read-only to the user."
  (should (eq (lookup-key mu4e-hubspot-suggestions-mode-map (kbd "SPC"))
              #'mu4e-hubspot-toggle-candidate))
  (should (eq (lookup-key mu4e-hubspot-suggestions-mode-map (kbd "RET"))
              #'mu4e-hubspot-toggle-candidate))
  (should (eq (lookup-key mu4e-hubspot-suggestions-mode-map (kbd "C-c C-c"))
              #'mu4e-hubspot-confirm-associations))
  (should (eq (lookup-key mu4e-hubspot-suggestions-mode-map (kbd "C-c C-k"))
              #'mu4e-hubspot-cancel))
  (should (eq (lookup-key mu4e-hubspot-suggestions-mode-map (kbd "s"))
              #'mu4e-hubspot-search-and-add)))

(ert-deftest mu4e-hubspot-test-display-selects-the-window ()
  "`mu4e-hubspot--display' must actually select the suggestions
window (not just display it in some other, unselected window), since
the user is expected to act on it with the very next keystroke."
  (unwind-protect
      (progn
        (mu4e-hubspot--display
         (list (cons "alice@example.com" (mu4e-hubspot-test--sample-suggestion)))
         (list :kind 'view :key "msg-1" :msg nil))
        (should (equal (buffer-name (window-buffer (selected-window)))
                        mu4e-hubspot--buffer-name)))
    (when (get-buffer mu4e-hubspot--buffer-name)
      (kill-buffer mu4e-hubspot--buffer-name))))

(ert-deftest mu4e-hubspot-test-cancel-kills-buffer ()
  (let ((buf (generate-new-buffer "*mu4e-hubspot-test*")))
    (with-current-buffer buf
      (mu4e-hubspot-suggestions-mode))
    (save-window-excursion
      (pop-to-buffer buf)
      (mu4e-hubspot-cancel))
    (should-not (buffer-live-p buf))))

;;; Manual search

(ert-deftest mu4e-hubspot-test-object-dispatch-helpers ()
  (should (equal (mu4e-hubspot--object-search-properties "contacts")
                  '("firstname" "lastname" "email")))
  (should (equal (mu4e-hubspot--object-search-properties "companies") '("name")))
  (should (equal (mu4e-hubspot--object-search-properties "deals") '("dealname")))
  (let ((contact '((id . "1") (properties . ((firstname . "Alice") (lastname . "A")
                                              (email . "alice@example.com")))))
        (company '((id . "5") (properties . ((name . "Acme")))))
        (deal '((id . "9") (properties . ((dealname . "Big Deal"))))))
    (should (equal (mu4e-hubspot--format-object "contacts" contact) "Alice A <alice@example.com>"))
    (should (equal (mu4e-hubspot--format-object "companies" company) "Acme"))
    (should (equal (mu4e-hubspot--format-object "deals" deal) "Big Deal"))
    (should (equal (mu4e-hubspot-candidate-type (mu4e-hubspot--object-candidate "contacts" contact))
                    "contacts"))
    (should (equal (mu4e-hubspot-candidate-type (mu4e-hubspot--object-candidate "companies" company))
                    "companies"))
    (should (equal (mu4e-hubspot-candidate-id (mu4e-hubspot--object-candidate "deals" deal)) "9"))))

(ert-deftest mu4e-hubspot-test-search-and-add-adds-preselected-candidate ()
  (mu4e-hubspot-test--with-rendered-buffer (list :kind 'view :key "k" :msg 'the-msg)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt &rest _)
                 (cond ((string-match-p "Search HubSpot for" prompt) "Company")
                       ((string-match-p "Choose" prompt) "Globex  [id: 42]")
                       (t (error "unexpected prompt: %s" prompt)))))
              ((symbol-function 'read-string) (lambda (&rest _) "globex"))
              ((symbol-function 'mu4e-hubspot-api-search-by-text)
               (lambda (type query _properties)
                 (should (equal type "companies"))
                 (should (equal query "globex"))
                 '(((id . "42") (properties . ((name . "Globex"))))))))
      (mu4e-hubspot-search-and-add)
      (should (= (length mu4e-hubspot--manual-candidates) 1))
      (should (equal (mu4e-hubspot-candidate-id (car mu4e-hubspot--manual-candidates)) "42"))
      ;; pre-selected, and included alongside auto-suggested selections in confirm
      (should (member '("companies" . "42")
                       (mapcar #'mu4e-hubspot--candidate-key (mu4e-hubspot--selected-candidates))))
      (should (string-match-p "Globex" (buffer-string))))))

(ert-deftest mu4e-hubspot-test-search-and-add-no-results ()
  (mu4e-hubspot-test--with-rendered-buffer (list :kind 'view :key "k" :msg 'the-msg)
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Contact"))
              ((symbol-function 'read-string) (lambda (&rest _) "nobody"))
              ((symbol-function 'mu4e-hubspot-api-search-by-text) (lambda (&rest _) nil)))
      (mu4e-hubspot-search-and-add)
      (should (null mu4e-hubspot--manual-candidates)))))

(ert-deftest mu4e-hubspot-test-search-and-add-empty-query-does-not-search ()
  (mu4e-hubspot-test--with-rendered-buffer (list :kind 'view :key "k" :msg 'the-msg)
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Contact"))
              ((symbol-function 'read-string) (lambda (&rest _) "   "))
              ((symbol-function 'mu4e-hubspot-api-search-by-text)
               (lambda (&rest _) (error "should not search on empty query"))))
      (mu4e-hubspot-search-and-add)
      (should (null mu4e-hubspot--manual-candidates)))))

(provide 'mu4e-hubspot-test)
;;; mu4e-hubspot-test.el ends here
