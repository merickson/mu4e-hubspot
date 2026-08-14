;;; mu4e-hubspot-api.el --- HubSpot CRM API client -*- lexical-binding: t; -*-

;; This file is part of mu4e-hubspot.

;;; Commentary:

;; A minimal, dependency-free HubSpot CRM API client built on Emacs'
;; built-in `url' and `json' libraries, targeting HubSpot's date-based
;; "2026-03" API version throughout (see
;; `mu4e-hubspot-api--version').  This file has no dependency on mu4e
;; itself, so it can be exercised without a running mu4e session.
;;
;; Authentication is per mu4e-context: callers are expected to bind
;; `mu4e-hubspot-api-token' (and optionally `mu4e-hubspot-api-portal-id')
;; via a context's `:vars' alist, e.g.:
;;
;;   (make-mu4e-context
;;    :name "work"
;;    :vars '((mu4e-hubspot-api-token . "pat-na1-xxxxxxxx")
;;            (mu4e-hubspot-api-portal-id . "12345678")))
;;
;; mu4e sets context `:vars' as regular global `setq' bindings when the
;; context becomes active, so these variables just need to be declared
;; here with `defvar'.

;;; Code:

(require 'url)
(require 'json)
(require 'cl-lib)

(defvar mu4e-hubspot-api-token nil
  "HubSpot private app access token for the active mu4e context.
Normally set per mu4e-context via that context's `:vars' alist,
not directly by the user.")

(defvar mu4e-hubspot-api-portal-id nil
  "HubSpot portal (account) id for the active mu4e context.
Informational only; not required for API calls.")

(defconst mu4e-hubspot-api--base-url "https://api.hubapi.com"
  "Base URL for the HubSpot API.")

(defconst mu4e-hubspot-api--version "2026-03"
  "HubSpot date-based API version this client targets.
All CRM object endpoints are rooted at \"/crm/objects/VERSION/...\"
and the associations-schema endpoints at
\"/crm/associations/VERSION/...\" under this scheme.")

(define-error 'mu4e-hubspot-api-error "mu4e-hubspot: HubSpot API error")

(defun mu4e-hubspot-api--url-encode-params (params)
  "Build a \"?key=val&...\" query string from the alist PARAMS."
  (mapconcat
   (lambda (kv)
     (format "%s=%s"
             (url-hexify-string (format "%s" (car kv)))
             (url-hexify-string (format "%s" (cdr kv)))))
   params "&"))

(defun mu4e-hubspot-api--request (method path &optional params body)
  "Perform a synchronous HubSpot API request and return the parsed JSON body.
METHOD is an HTTP method string, PATH is the API path (e.g.
\"/crm/objects/2026-03/contacts/search\"), PARAMS is an alist of query
parameters, and BODY, if non-nil, is an alist/list JSON payload.

Signals `mu4e-hubspot-api-error' if no token is configured for the
current context, or if HubSpot returns a non-2xx status."
  (unless mu4e-hubspot-api-token
    (signal 'mu4e-hubspot-api-error
            '("no HubSpot API token configured for the current mu4e context")))
  (let* ((url-request-method method)
         (url-request-extra-headers
          `(("Authorization" . ,(concat "Bearer " mu4e-hubspot-api-token))
            ("Content-Type" . "application/json")))
         (url-request-data
          (when body (encode-coding-string (json-encode body) 'utf-8)))
         (url (concat mu4e-hubspot-api--base-url path
                      (when params
                        (concat "?" (mu4e-hubspot-api--url-encode-params params)))))
         (response-buffer (url-retrieve-synchronously url t t 15)))
    (unless response-buffer
      (signal 'mu4e-hubspot-api-error (list (format "request to %s timed out" path))))
    (with-current-buffer response-buffer
      (unwind-protect
          (progn
            (goto-char (point-min))
            (unless (re-search-forward "^HTTP/[0-9.]+ \\([0-9]+\\)" nil t)
              (signal 'mu4e-hubspot-api-error (list "malformed HTTP response")))
            (let ((status (string-to-number (match-string 1))))
              (search-forward "\n\n" nil t)
              (let* ((json-object-type 'alist)
                     (json-array-type 'list)
                     (json-key-type 'symbol)
                     (parsed (ignore-errors (json-read))))
                (if (and (>= status 200) (< status 300))
                    parsed
                  (signal 'mu4e-hubspot-api-error
                          (list (format "%s %s -> HTTP %s" method path status) parsed))))))
        (kill-buffer response-buffer)))))

(defun mu4e-hubspot-api-search-contact-by-email (email)
  "Return the first HubSpot contact object matching EMAIL, or nil."
  (let* ((filter (list (cons 'propertyName "email")
                        (cons 'operator "EQ")
                        (cons 'value email)))
         (filter-group (list (cons 'filters (list filter))))
         (body (list (cons 'filterGroups (list filter-group))
                     (cons 'properties '("email" "firstname" "lastname"))
                     (cons 'limit 1)))
         (response (mu4e-hubspot-api--request
                    "POST"
                    (format "/crm/objects/%s/contacts/search" mu4e-hubspot-api--version)
                    nil body)))
    (car (alist-get 'results response))))

(defun mu4e-hubspot-api-search-by-text (object-type query properties &optional limit)
  "Free-text search HubSpot OBJECT-TYPE (e.g. \"contacts\") for QUERY,
returning up to LIMIT (default 10) matching objects with PROPERTIES.

Uses the search endpoint's free-text `query' parameter, which matches
against a fixed set of default text properties per object type (for
contacts: firstname/lastname/email/etc; companies: name/domain/etc;
deals: dealname/etc -- see HubSpot's CRM Search API docs for the full
list) -- no explicit filters needed for a simple \"search by name\"
UI."
  (let ((body (list (cons 'query query)
                     (cons 'properties properties)
                     (cons 'limit (or limit 10)))))
    (alist-get 'results
               (mu4e-hubspot-api--request
                "POST" (format "/crm/objects/%s/%s/search" mu4e-hubspot-api--version object-type)
                nil body))))

(defun mu4e-hubspot-api-get-contact-with-associations (contact-id)
  "Return the HubSpot contact object for CONTACT-ID with associated
companies and deals included."
  (mu4e-hubspot-api--request
   "GET" (format "/crm/objects/%s/contacts/%s" mu4e-hubspot-api--version contact-id)
   `((associations . "companies,deals"))))

(defun mu4e-hubspot-api--association-ids (contact object-type)
  "Return the list of associated object ids of OBJECT-TYPE (a symbol,
e.g. `companies' or `deals') found on CONTACT, as returned by
`mu4e-hubspot-api-get-contact-with-associations'."
  (let* ((associations (alist-get 'associations contact))
         (group (alist-get object-type associations))
         (results (alist-get 'results group)))
    (mapcar (lambda (r) (alist-get 'id r)) results)))

(defun mu4e-hubspot-api-batch-read (object-type ids properties)
  "Batch-read HubSpot OBJECT-TYPE (e.g. \"companies\", \"deals\") objects
by IDS, returning only PROPERTIES.  Returns nil without a request if
IDS is empty."
  (when ids
    (let* ((body `((properties . ,properties)
                   (inputs . ,(mapcar (lambda (id) `((id . ,id))) ids))))
           (response (mu4e-hubspot-api--request
                      "POST"
                      (format "/crm/objects/%s/%s/batch/read" mu4e-hubspot-api--version object-type)
                      nil body)))
      (alist-get 'results response))))

(cl-defstruct mu4e-hubspot-suggestion
  "Suggested HubSpot associations for a single email address."
  email contact companies deals)

(defun mu4e-hubspot-api-suggestions-for-email (email)
  "Look up EMAIL in HubSpot and return a `mu4e-hubspot-suggestion', or
nil if no contact matches EMAIL."
  (when-let* ((contact (mu4e-hubspot-api-search-contact-by-email email))
              (contact-id (alist-get 'id contact))
              (full-contact (mu4e-hubspot-api-get-contact-with-associations contact-id)))
    (let* ((company-ids (mu4e-hubspot-api--association-ids full-contact 'companies))
           (deal-ids (mu4e-hubspot-api--association-ids full-contact 'deals)))
      (make-mu4e-hubspot-suggestion
       :email email
       :contact full-contact
       :companies (mu4e-hubspot-api-batch-read "companies" company-ids '("name"))
       :deals (mu4e-hubspot-api-batch-read "deals" deal-ids '("dealname"))))))

;; Email-engagement logging and association.
;;
;; "Associating an email" means creating a HubSpot email
;; engagement/communication object (a `crm/objects/.../emails' record)
;; representing the message, then linking that object to the chosen
;; contacts/companies/deals via the associations API -- this is what
;; makes the message show up on those records' timelines, matching
;; what HubSpot's own Gmail/Outlook extensions do.  Just associating
;; the already-matched contact would be cheaper but would never make
;; the email itself visible anywhere in HubSpot.

(defun mu4e-hubspot-api-associate (from-type from-id to-type to-id)
  "Associate the FROM-TYPE/FROM-ID record with the TO-TYPE/TO-ID
record, using HubSpot's own \"default association\" endpoint -- this
creates the standard unlabeled association between the two object
types without needing to know its numeric association type id (those
ids are portal-specific and would otherwise have to be looked up via
the associations-schema labels endpoint first)."
  (mu4e-hubspot-api--request
   "PUT"
   (format "/crm/objects/%s/%s/%s/associations/default/%s/%s"
           mu4e-hubspot-api--version from-type from-id to-type to-id)))

(defun mu4e-hubspot-api-create-email (properties)
  "Create a HubSpot email engagement with PROPERTIES (an alist) and
return the created object (with its id)."
  (mu4e-hubspot-api--request
   "POST" (format "/crm/objects/%s/emails" mu4e-hubspot-api--version)
   nil (list (cons 'properties properties))))

(defun mu4e-hubspot-api--address-object (pair)
  "Build a HubSpot hs_email_headers participant object from PAIR, a
(EMAIL . NAME-OR-NIL) cons.  NAME, if present, is naively split into
first/last name on whitespace."
  (let* ((email (car pair))
         (name (cdr pair))
         (parts (and name (split-string name)))
         (first-name (car parts))
         (last-name (and (cdr parts) (mapconcat #'identity (cdr parts) " "))))
    (delq nil (list (cons 'email email)
                     (and first-name (cons 'firstName first-name))
                     (and last-name (cons 'lastName last-name))))))

(defun mu4e-hubspot-api-build-email-headers (from to cc bcc)
  "Build the JSON string for a HubSpot email engagement's
hs_email_headers property.  FROM is a single (EMAIL . NAME-OR-NIL)
cons or nil; TO, CC, and BCC are lists of such conses."
  (json-encode
   (delq nil
         (list (and from (cons 'from (mu4e-hubspot-api--address-object from)))
               (cons 'to (mapcar #'mu4e-hubspot-api--address-object to))
               (cons 'cc (mapcar #'mu4e-hubspot-api--address-object cc))
               (cons 'bcc (mapcar #'mu4e-hubspot-api--address-object bcc))))))

(defun mu4e-hubspot-api--text-to-html (text)
  "Convert plain TEXT to a minimal HTML rendering for hs_email_html:
HTML-escape it, then turn newlines into <br> tags.  HubSpot's
engagement timeline renders hs_email_html, not hs_email_text, so
without this a logged email's paragraph/line breaks are lost."
  (let* ((escaped (replace-regexp-in-string "&" "&amp;" text))
         (escaped (replace-regexp-in-string "<" "&lt;" escaped))
         (escaped (replace-regexp-in-string ">" "&gt;" escaped)))
    (replace-regexp-in-string "\n" "<br>\n" escaped)))

(cl-defun mu4e-hubspot-api-log-email (&key subject body html direction timestamp
                                            from to cc bcc associations)
  "Create a HubSpot email engagement and associate it with ASSOCIATIONS.

SUBJECT and BODY are strings (BODY may be nil to omit hs_email_text
and hs_email_html).  BODY is sent verbatim as hs_email_text.  HTML,
if given, is sent as-is as hs_email_html -- pass the message's own
original HTML here when it has one, so real formatting (links, bold,
etc.) round-trips instead of being rebuilt from BODY.  If HTML is nil
but BODY is non-nil, hs_email_html is instead generated from BODY by
HTML-escaping it and turning newlines into <br> tags, since HubSpot's
engagement timeline does not honor bare newlines in hs_email_text --
without an HTML rendering, paragraph breaks in a logged plain-text
email collapse into one run-on line.
DIRECTION is \"EMAIL\" (outgoing) or \"INCOMING_EMAIL\" (received).
TIMESTAMP is a HubSpot-accepted timestamp for hs_timestamp -- an
epoch-millisecond integer is recommended (see
`mu4e-hubspot--epoch-millis' in mu4e-hubspot.el) over an ISO-8601
string, which is documented as valid but has been unreliable for
email-engagement timeline rendering in practice.  FROM is a
(EMAIL . NAME-OR-NIL) cons or nil; TO, CC, and BCC are lists of such
conses.  ASSOCIATIONS is a list of (OBJECT-TYPE . OBJECT-ID) conses,
e.g. (\"contacts\" . \"123\").

Returns a plist (:id EMAIL-ID :failures FAILURES), where FAILURES is
an alist of (ASSOCIATION . ERROR) for any association that failed to
apply; the email is still created, and every other association is
still attempted, even if some fail."
  (let* ((html (or html (and body (mu4e-hubspot-api--text-to-html body))))
         (properties (delq nil
                       (list (cons 'hs_timestamp timestamp)
                             (cons 'hs_email_direction direction)
                             (cons 'hs_email_status "SENT")
                             (and subject (cons 'hs_email_subject subject))
                             (and body (cons 'hs_email_text body))
                             (and html (cons 'hs_email_html html))
                             (cons 'hs_email_headers
                                   (mu4e-hubspot-api-build-email-headers from to cc bcc)))))
         (email (mu4e-hubspot-api-create-email properties))
         (email-id (alist-get 'id email))
         (failures nil))
    (dolist (assoc associations)
      (condition-case err
          (mu4e-hubspot-api-associate "emails" email-id (car assoc) (cdr assoc))
        (error (push (cons assoc err) failures))))
    (list :id email-id :failures (nreverse failures))))

(provide 'mu4e-hubspot-api)
;;; mu4e-hubspot-api.el ends here
