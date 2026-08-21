;;; mu4e-hubspot-api-test.el --- Tests for mu4e-hubspot-api -*- lexical-binding: t; -*-

;;; Commentary:

;; These tests stub `mu4e-hubspot-api--request' (and, for the
;; aggregate suggestions test, the functions built on top of it) so
;; no network access or HubSpot credentials are required.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'mu4e-hubspot-api)

(ert-deftest mu4e-hubspot-api-test-no-token-signals ()
  (let ((mu4e-hubspot-api-token nil))
    (should-error (mu4e-hubspot-api--request "GET" "/x")
                  :type 'mu4e-hubspot-api-error)))

(ert-deftest mu4e-hubspot-api-test-search-contact-by-email ()
  (let (captured-method captured-path captured-params captured-body)
    (cl-letf (((symbol-function 'mu4e-hubspot-api--request)
               (lambda (method path &optional params body)
                 (setq captured-method method
                       captured-path path
                       captured-params params
                       captured-body body)
                 '((results . (((id . "42") (properties . ((email . "a@b.com"))))))))))
      (let ((result (mu4e-hubspot-api-search-contact-by-email "a@b.com")))
        (should (equal captured-method "POST"))
        (should (equal captured-path "/crm/objects/2026-03/contacts/search"))
        (should (null captured-params))
        (should (equal (alist-get 'id result) "42"))
        (let* ((filter-groups (alist-get 'filterGroups captured-body))
               (filters (alist-get 'filters (car filter-groups)))
               (filter (car filters)))
          (should (equal (alist-get 'propertyName filter) "email"))
          (should (equal (alist-get 'operator filter) "EQ"))
          (should (equal (alist-get 'value filter) "a@b.com")))
        (should (equal (alist-get 'properties captured-body)
                        '("email" "firstname" "lastname")))
        (should (equal (alist-get 'limit captured-body) 1))))))

(ert-deftest mu4e-hubspot-api-test-search-contact-by-email-no-match ()
  (cl-letf (((symbol-function 'mu4e-hubspot-api--request)
             (lambda (&rest _) '((results . nil)))))
    (should (null (mu4e-hubspot-api-search-contact-by-email "nobody@nowhere.com")))))

(ert-deftest mu4e-hubspot-api-test-search-by-text ()
  (let (captured-method captured-path captured-body)
    (cl-letf (((symbol-function 'mu4e-hubspot-api--request)
               (lambda (method path &optional _params body)
                 (setq captured-method method captured-path path captured-body body)
                 '((results . (((id . "1") (properties . ((name . "Acme"))))
                                ((id . "2") (properties . ((name . "Acme Corp"))))))))))
      (let ((results (mu4e-hubspot-api-search-by-text "companies" "acme" '("name"))))
        (should (equal captured-method "POST"))
        (should (equal captured-path "/crm/objects/2026-03/companies/search"))
        (should (equal (alist-get 'query captured-body) "acme"))
        (should (equal (alist-get 'properties captured-body) '("name")))
        (should (equal (alist-get 'limit captured-body) 10))
        (should (= (length results) 2))
        (should (equal (alist-get 'name (alist-get 'properties (car results))) "Acme"))))))

(ert-deftest mu4e-hubspot-api-test-search-by-text-custom-limit ()
  (let (captured-body)
    (cl-letf (((symbol-function 'mu4e-hubspot-api--request)
               (lambda (_method _path &optional _params body)
                 (setq captured-body body)
                 '((results . nil)))))
      (mu4e-hubspot-api-search-by-text "deals" "renewal" '("dealname") 25)
      (should (equal (alist-get 'limit captured-body) 25)))))

(ert-deftest mu4e-hubspot-api-test-association-ids ()
  (let ((contact '((id . "1")
                    (associations (companies (results ((id . "10")) ((id . "11"))))
                                  (deals (results ((id . "20"))))))))
    (should (equal (mu4e-hubspot-api--association-ids contact 'companies) '("10" "11")))
    (should (equal (mu4e-hubspot-api--association-ids contact 'deals) '("20")))
    (should (null (mu4e-hubspot-api--association-ids contact 'tickets)))))

(ert-deftest mu4e-hubspot-api-test-batch-read-empty-ids-skips-request ()
  (cl-letf (((symbol-function 'mu4e-hubspot-api--request)
             (lambda (&rest _) (error "should not be called for empty ids"))))
    (should (null (mu4e-hubspot-api-batch-read "companies" nil '("name"))))))

(ert-deftest mu4e-hubspot-api-test-batch-read ()
  (let (captured-path captured-body)
    (cl-letf (((symbol-function 'mu4e-hubspot-api--request)
               (lambda (_method path &optional _params body)
                 (setq captured-path path captured-body body)
                 '((results . (((id . "10") (properties . ((name . "Acme"))))))))))
      (let ((result (mu4e-hubspot-api-batch-read "companies" '("10") '("name"))))
        (should (equal captured-path "/crm/objects/2026-03/companies/batch/read"))
        (should (equal (alist-get 'properties captured-body) '("name")))
        (should (equal (alist-get 'inputs captured-body) '(((id . "10")))))
        (should (equal (alist-get 'name (alist-get 'properties (car result))) "Acme"))))))

(ert-deftest mu4e-hubspot-api-test-suggestions-for-email-no-contact ()
  (cl-letf (((symbol-function 'mu4e-hubspot-api-search-contact-by-email)
             (lambda (_email) nil)))
    (should (null (mu4e-hubspot-api-suggestions-for-email "nobody@nowhere.com")))))

(ert-deftest mu4e-hubspot-api-test-suggestions-for-email ()
  (cl-letf (((symbol-function 'mu4e-hubspot-api-search-contact-by-email)
             (lambda (_email) '((id . "1"))))
            ((symbol-function 'mu4e-hubspot-api-get-contact-with-associations)
             (lambda (id)
               (should (equal id "1"))
               '((id . "1")
                 (associations (companies (results ((id . "10"))))
                               (deals (results ((id . "20"))))))))
            ((symbol-function 'mu4e-hubspot-api-batch-read)
             (lambda (object-type ids _properties)
               (cond
                ((equal object-type "companies")
                 (should (equal ids '("10")))
                 '(((id . "10") (properties . ((name . "Acme"))))))
                ((equal object-type "deals")
                 (should (equal ids '("20")))
                 '(((id . "20") (properties . ((dealname . "Big Deal"))))))))))
    (let ((suggestion (mu4e-hubspot-api-suggestions-for-email "a@b.com")))
      (should (mu4e-hubspot-suggestion-p suggestion))
      (should (equal (mu4e-hubspot-suggestion-email suggestion) "a@b.com"))
      (should (equal (alist-get 'name (alist-get 'properties
                                                   (car (mu4e-hubspot-suggestion-companies suggestion))))
                      "Acme"))
      (should (equal (alist-get 'dealname (alist-get 'properties
                                                       (car (mu4e-hubspot-suggestion-deals suggestion))))
                      "Big Deal")))))

(ert-deftest mu4e-hubspot-api-test-associate-builds-path ()
  (let (captured-method captured-path)
    (cl-letf (((symbol-function 'mu4e-hubspot-api--request)
               (lambda (method path &optional &rest _)
                 (setq captured-method method captured-path path)
                 nil)))
      (mu4e-hubspot-api-associate "emails" "77" "contacts" "1")
      (should (equal captured-method "PUT"))
      (should (equal captured-path
                      "/crm/objects/2026-03/emails/77/associations/default/contacts/1")))))

(ert-deftest mu4e-hubspot-api-test-create-email-builds-path-and-body ()
  (let (captured-path captured-body)
    (cl-letf (((symbol-function 'mu4e-hubspot-api--request)
               (lambda (_method path &optional _params body)
                 (setq captured-path path captured-body body)
                 '((id . "999")))))
      (let ((result (mu4e-hubspot-api-create-email '((hs_email_subject . "hi")))))
        (should (equal captured-path "/crm/objects/2026-03/emails"))
        (should (equal (alist-get 'properties captured-body) '((hs_email_subject . "hi"))))
        (should (equal (alist-get 'id result) "999"))))))

(ert-deftest mu4e-hubspot-api-test-create-contact-builds-path-and-body ()
  (let (captured-path captured-body)
    (cl-letf (((symbol-function 'mu4e-hubspot-api--request)
               (lambda (_method path &optional _params body)
                 (setq captured-path path captured-body body)
                 '((id . "555")))))
      (let ((result (mu4e-hubspot-api-create-contact "alice@example.com" "Alice Smith")))
        (should (equal captured-path "/crm/objects/2026-03/contacts"))
        (let ((properties (alist-get 'properties captured-body)))
          (should (equal (alist-get 'email properties) "alice@example.com"))
          (should (equal (alist-get 'firstname properties) "Alice"))
          (should (equal (alist-get 'lastname properties) "Smith")))
        (should (equal (alist-get 'id result) "555"))))))

(ert-deftest mu4e-hubspot-api-test-create-contact-no-name ()
  (let (captured-body)
    (cl-letf (((symbol-function 'mu4e-hubspot-api--request)
               (lambda (_method _path &optional _params body)
                 (setq captured-body body)
                 '((id . "556")))))
      (mu4e-hubspot-api-create-contact "bob@example.com")
      (let ((properties (alist-get 'properties captured-body)))
        (should (equal (alist-get 'email properties) "bob@example.com"))
        (should (null (alist-get 'firstname properties)))
        (should (null (alist-get 'lastname properties)))))))

(ert-deftest mu4e-hubspot-api-test-text-to-html-escapes-and-linebreaks ()
  (should (equal (mu4e-hubspot-api--text-to-html "Dear Bob,\n\nA & B < C > D.")
                  "Dear Bob,<br>\n<br>\nA &amp; B &lt; C &gt; D.")))

(ert-deftest mu4e-hubspot-api-test-log-email-uses-given-html-verbatim ()
  "An explicit :html (e.g. the message's real original HTML) must be
sent as-is, not discarded in favor of rebuilding hs_email_html from
:body -- that round-trip would lose real formatting like links/bold."
  (let (create-properties)
    (cl-letf (((symbol-function 'mu4e-hubspot-api-create-email)
               (lambda (properties) (setq create-properties properties) '((id . "999"))))
              ((symbol-function 'mu4e-hubspot-api-associate) (lambda (&rest _) t)))
      (mu4e-hubspot-api-log-email
       :body "Dear Bob,\n\nBody text."
       :html "<p>Dear Bob,</p><p>Body <b>text</b>.</p>"
       :direction "INCOMING_EMAIL" :timestamp 0)
      (should (equal (alist-get 'hs_email_html create-properties)
                      "<p>Dear Bob,</p><p>Body <b>text</b>.</p>")))))

(ert-deftest mu4e-hubspot-api-test-build-email-headers ()
  (let* ((json (mu4e-hubspot-api-build-email-headers
                (cons "alice@example.com" "Alice Smith")
                (list (cons "bob@example.com" nil))
                nil nil))
         (parsed (let ((json-object-type 'alist) (json-array-type 'list) (json-key-type 'symbol))
                   (json-read-from-string json))))
    (should (equal (alist-get 'email (alist-get 'from parsed)) "alice@example.com"))
    (should (equal (alist-get 'firstName (alist-get 'from parsed)) "Alice"))
    (should (equal (alist-get 'lastName (alist-get 'from parsed)) "Smith"))
    (should (equal (alist-get 'email (car (alist-get 'to parsed))) "bob@example.com"))
    (should (null (alist-get 'firstName (car (alist-get 'to parsed)))))
    (should (equal (alist-get 'cc parsed) nil))
    (should (equal (alist-get 'bcc parsed) nil))))

(ert-deftest mu4e-hubspot-api-test-log-email-creates-and-associates-all ()
  (let (create-properties associate-calls)
    (cl-letf (((symbol-function 'mu4e-hubspot-api-create-email)
               (lambda (properties)
                 (setq create-properties properties)
                 '((id . "999"))))
              ((symbol-function 'mu4e-hubspot-api-associate)
               (lambda (from-type from-id to-type to-id)
                 (push (list from-type from-id to-type to-id) associate-calls)
                 t)))
      (let ((result (mu4e-hubspot-api-log-email
                     :subject "Hi" :body "Dear Bob,\n\nBody text."
                     :direction "INCOMING_EMAIL" :timestamp "2026-08-12T00:00:00.000Z"
                     :from (cons "alice@example.com" "Alice")
                     :to (list (cons "bob@example.com" nil))
                     :cc nil :bcc nil
                     :associations '(("contacts" . "1") ("deals" . "2")))))
        (should (equal (alist-get 'hs_email_subject create-properties) "Hi"))
        (should (equal (alist-get 'hs_email_text create-properties) "Dear Bob,\n\nBody text."))
        (should (equal (alist-get 'hs_email_html create-properties)
                        "Dear Bob,<br>\n<br>\nBody text."))
        (should (equal (alist-get 'hs_email_direction create-properties) "INCOMING_EMAIL"))
        (should (equal (alist-get 'hs_email_status create-properties) "SENT"))
        (should (equal (plist-get result :id) "999"))
        (should (null (plist-get result :failures)))
        (should (equal (nreverse associate-calls)
                        '(("emails" "999" "contacts" "1")
                          ("emails" "999" "deals" "2"))))))))

(ert-deftest mu4e-hubspot-api-test-log-email-collects-partial-failures ()
  (cl-letf (((symbol-function 'mu4e-hubspot-api-create-email)
             (lambda (_properties) '((id . "999"))))
            ((symbol-function 'mu4e-hubspot-api-associate)
             (lambda (_from-type _from-id to-type _to-id)
               (if (equal to-type "contacts")
                   t
                 (error "boom")))))
    (let ((result (mu4e-hubspot-api-log-email
                   :direction "EMAIL" :timestamp "2026-08-12T00:00:00.000Z"
                   :associations '(("contacts" . "1") ("deals" . "2")))))
      (should (equal (plist-get result :id) "999"))
      (should (= (length (plist-get result :failures)) 1))
      (should (equal (car (car (plist-get result :failures))) '("deals" . "2"))))))

(provide 'mu4e-hubspot-api-test)
;;; mu4e-hubspot-api-test.el ends here
