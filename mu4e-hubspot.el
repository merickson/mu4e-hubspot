;;; mu4e-hubspot.el --- Associate mu4e messages with HubSpot records -*- lexical-binding: t; -*-

;;; Commentary:

;; Viewing a received message in mu4e, or composing/replying to one,
;; shows HubSpot contacts/companies/deals suggested from its
;; From/Cc (view) or To/Cc/Bcc (compose) addresses, in a selectable
;; side buffer.  Confirming a selection logs the message as a HubSpot
;; email engagement and associates it with the chosen records, so it
;; shows up on their timelines:
;;
;; - Viewing a received message: written immediately on confirm.
;; - Composing a draft: the selection is staged and only written once
;;   the draft is actually sent (via `message-send-actions'), never on
;;   confirm itself.
;;
;; Requires mu4e (>= 1.8, i.e. the plist-based contact representation)
;; already on `load-path'.  See mu4e-hubspot-api.el for how to
;; configure a HubSpot token per mu4e-context.
;;
;; Usage: `mu4e-hubspot-show-suggestions' (bound to "C-c C-h" in
;; mu4e-view-mode) shows suggestions for the message at point.
;; `mu4e-hubspot-show-compose-suggestions' (bound to "C-c C-h" in
;; mu4e-compose-mode, and run automatically whenever a compose buffer
;; is created) shows suggestions for the current draft; re-run it by
;; hand after editing recipients to refresh.  In the suggestions
;; buffer, SPC/RET toggles a record, "s" searches HubSpot for a
;; contact/company/deal to add (for records that weren't
;; auto-suggested), "C-c C-c" confirms, and "C-c C-k" cancels and
;; kills the buffer without applying anything.

;;; Code:

(require 'mu4e)
(require 'mu4e-hubspot-api)
(require 'mail-parse)
(require 'cl-lib)
(require 'mml)
(require 'mm-decode)

;;; Address extraction

(defun mu4e-hubspot--dedup-downcase (emails)
  "Return EMAILS downcased and de-duplicated, keeping first-seen order."
  (delete-dups (mapcar #'downcase emails)))

(defun mu4e-hubspot--contact-pairs (msg field)
  "Return the list of (EMAIL . NAME-OR-NIL) pairs in FIELD (e.g.
`:from') of the mu4e message plist MSG."
  (mapcar (lambda (contact)
            (cons (mu4e-contact-email contact) (mu4e-contact-name contact)))
          (mu4e-message-field msg field)))

(defun mu4e-hubspot--addresses (msg fields)
  "Return a de-duplicated, downcased list of email addresses drawn
from FIELDS (a list of mu4e message field keywords, e.g. `:from') of
the mu4e message plist MSG."
  (mu4e-hubspot--dedup-downcase
   (delq nil (mapcar #'car (apply #'append (mapcar (lambda (f) (mu4e-hubspot--contact-pairs msg f))
                                                     fields))))))

(defun mu4e-hubspot--view-addresses (msg)
  "Addresses to suggest HubSpot associations for on a received
message: From and Cc."
  (mu4e-hubspot--addresses msg '(:from :cc)))

(defun mu4e-hubspot--header-address-pairs (header)
  "Return the list of (EMAIL . NAME-OR-NIL) pairs found in HEADER
(e.g. \"To\") of the current buffer, parsed the way `message-mode'
buffers store headers.  Returns nil if HEADER is absent."
  (when-let ((value (message-fetch-field header)))
    (mapcar (lambda (addr) (cons (car addr) (cdr addr)))
            (mail-header-parse-addresses value))))

(defun mu4e-hubspot--header-addresses (header)
  "Return just the email addresses from
`mu4e-hubspot--header-address-pairs' for HEADER."
  (mapcar #'car (mu4e-hubspot--header-address-pairs header)))

(defun mu4e-hubspot--compose-addresses ()
  "Addresses to suggest HubSpot associations for on a draft message:
To, Cc, and Bcc, read from the current compose buffer's headers."
  (mu4e-hubspot--dedup-downcase
   (append (mu4e-hubspot--header-addresses "To")
           (mu4e-hubspot--header-addresses "Cc")
           (mu4e-hubspot--header-addresses "Bcc"))))

;;; Session-scoped suggestion cache

(defvar-local mu4e-hubspot--session-key nil
  "Identifies the message currently being viewed in this buffer.
Used to reset `mu4e-hubspot--session-table' when a different message
is shown, so lookups are only ever reused within one message-viewing
session.")

(defvar-local mu4e-hubspot--session-table nil
  "Hash table of email address -> `mu4e-hubspot-suggestion' (or nil),
scoped to `mu4e-hubspot--session-key'.")

(defun mu4e-hubspot--message-session-key (msg)
  "Return a value identifying MSG for session-cache purposes."
  (or (mu4e-message-field msg :message-id)
      (mu4e-message-field msg :docid)))

(defun mu4e-hubspot--session-cache-get (session-key email fetch-fn)
  "Return the cached suggestion for EMAIL scoped to SESSION-KEY in the
current buffer, calling FETCH-FN and caching its result on a miss.
The cache resets whenever SESSION-KEY changes from the last call in
this buffer."
  (unless (equal mu4e-hubspot--session-key session-key)
    (setq mu4e-hubspot--session-key session-key
          mu4e-hubspot--session-table (make-hash-table :test #'equal)))
  (let ((cached (gethash email mu4e-hubspot--session-table 'mu4e-hubspot--miss)))
    (if (not (eq cached 'mu4e-hubspot--miss))
        cached
      (let ((value (funcall fetch-fn)))
        (puthash email value mu4e-hubspot--session-table)
        value))))

(defun mu4e-hubspot--suggestions-for-addresses (session-key addresses)
  "Return an alist of (EMAIL . SUGGESTION-OR-NIL) for ADDRESSES,
looking each up via the session cache scoped to SESSION-KEY."
  (mapcar (lambda (email)
            (cons email
                  (mu4e-hubspot--session-cache-get
                   session-key email
                   (lambda () (mu4e-hubspot-api-suggestions-for-email email)))))
          addresses))

;;; Selectable suggestions buffer

(cl-defstruct mu4e-hubspot-candidate
  "A selectable HubSpot record shown in the suggestions buffer.
TYPE is a HubSpot object-type path segment (\"contacts\",
\"companies\", or \"deals\").  PENDING, when non-nil, is a plist
(:email EMAIL :name NAME-OR-NIL) marking this candidate as a contact
that doesn't exist in HubSpot yet -- ID is nil in that case, and
selecting+confirming this candidate creates the contact (see
`mu4e-hubspot--resolve-associations') instead of referencing an
existing record."
  type id label pending)

(defconst mu4e-hubspot--buffer-name "*mu4e-hubspot*"
  "Name of the buffer used to display suggested HubSpot associations.")

(defvar-local mu4e-hubspot--address-suggestions nil
  "The (EMAIL . SUGGESTION-OR-NIL) alist currently rendered in this
suggestions buffer.")

(defvar-local mu4e-hubspot--source nil
  "Plist describing what this suggestions buffer's candidates belong
to: (:kind view :key SESSION-KEY :msg MSG) for a viewed message, or
(:kind compose :key BUFFER :buffer BUFFER) for a draft.  :key is
compared with `equal' to decide whether `mu4e-hubspot--selected'
should reset (a genuinely different message) or persist (the same
draft, just refreshed).")

(defvar-local mu4e-hubspot--selected nil
  "Hash table of (TYPE . ID) -> `mu4e-hubspot-candidate', for
candidates currently selected in this suggestions buffer.")

(defvar-local mu4e-hubspot--manual-candidates nil
  "List of `mu4e-hubspot-candidate' structs added via
`mu4e-hubspot-search-and-add', most-recently-added first.")

(define-derived-mode mu4e-hubspot-suggestions-mode special-mode "mu4e-hubspot"
  "Major mode for the mu4e-hubspot suggestions/selection buffer.")

(define-key mu4e-hubspot-suggestions-mode-map (kbd "SPC") #'mu4e-hubspot-toggle-candidate)
(define-key mu4e-hubspot-suggestions-mode-map (kbd "RET") #'mu4e-hubspot-toggle-candidate)
(define-key mu4e-hubspot-suggestions-mode-map (kbd "s") #'mu4e-hubspot-search-and-add)
(define-key mu4e-hubspot-suggestions-mode-map (kbd "C-c C-c") #'mu4e-hubspot-confirm-associations)
(define-key mu4e-hubspot-suggestions-mode-map (kbd "C-c C-k") #'mu4e-hubspot-cancel)

(defun mu4e-hubspot--format-contact (contact)
  "Format the HubSpot CONTACT object for display."
  (let ((props (alist-get 'properties contact)))
    (string-trim
     (format "%s %s <%s>"
             (or (alist-get 'firstname props) "")
             (or (alist-get 'lastname props) "")
             (or (alist-get 'email props) "")))))

(defun mu4e-hubspot--format-named (object name-property)
  "Format a HubSpot company/deal OBJECT using NAME-PROPERTY."
  (or (alist-get name-property (alist-get 'properties object))
      (alist-get 'id object)))

(defun mu4e-hubspot--contact-candidate (contact)
  (make-mu4e-hubspot-candidate
   :type "contacts" :id (alist-get 'id contact)
   :label (format "%-8s: %s" "Contact" (mu4e-hubspot--format-contact contact))))

(defun mu4e-hubspot--named-candidate (type label-prefix name-property object)
  (make-mu4e-hubspot-candidate
   :type type :id (alist-get 'id object)
   :label (format "%-8s: %s" label-prefix (mu4e-hubspot--format-named object name-property))))

(defconst mu4e-hubspot--object-types
  '(("Contact" . "contacts") ("Company" . "companies") ("Deal" . "deals"))
  "Alist of (DISPLAY-LABEL . HUBSPOT-OBJECT-TYPE) offered by
`mu4e-hubspot-search-and-add'.")

(defun mu4e-hubspot--object-search-properties (type)
  "Properties to fetch for a TYPE search result, just enough to
format it for display (see `mu4e-hubspot--format-object')."
  (pcase type
    ("contacts" '("firstname" "lastname" "email"))
    ("companies" '("name"))
    ("deals" '("dealname"))))

(defun mu4e-hubspot--format-object (type object)
  "Format a HubSpot OBJECT of TYPE for display, dispatching to the
same formatters used for auto-suggested candidates."
  (pcase type
    ("contacts" (mu4e-hubspot--format-contact object))
    ("companies" (mu4e-hubspot--format-named object 'name))
    ("deals" (mu4e-hubspot--format-named object 'dealname))))

(defun mu4e-hubspot--object-candidate (type object)
  "Build a `mu4e-hubspot-candidate' from a HubSpot OBJECT of TYPE,
dispatching to the same constructors used for auto-suggested
candidates."
  (pcase type
    ("contacts" (mu4e-hubspot--contact-candidate object))
    ("companies" (mu4e-hubspot--named-candidate "companies" "Company" 'name object))
    ("deals" (mu4e-hubspot--named-candidate "deals" "Deal" 'dealname object))))

(defun mu4e-hubspot--candidate-key (candidate)
  "Return a key uniquely identifying CANDIDATE for selection purposes.
Falls back to its pending contact's email when it has no id yet (see
`mu4e-hubspot-candidate-pending')."
  (cons (mu4e-hubspot-candidate-type candidate)
        (or (mu4e-hubspot-candidate-id candidate)
            (plist-get (mu4e-hubspot-candidate-pending candidate) :email))))

(defun mu4e-hubspot--new-contact-candidate (email &optional name)
  "Build a selectable `mu4e-hubspot-candidate' representing a contact
that doesn't exist in HubSpot yet.  Selecting and confirming it
creates the contact (see `mu4e-hubspot--resolve-associations') before
associating it, rather than referencing an existing record.  NAME, if
given, is passed through to `mu4e-hubspot-api-create-contact' to
prefill firstname/lastname on creation."
  (make-mu4e-hubspot-candidate
   :type "contacts" :id nil
   :label (format "%-8s: create new contact <%s>" "Contact" email)
   :pending (list :email email :name name)))

(defun mu4e-hubspot--selected-p (candidate)
  (and mu4e-hubspot--selected
       (gethash (mu4e-hubspot--candidate-key candidate) mu4e-hubspot--selected)))

(defun mu4e-hubspot--insert-candidate (candidate)
  "Insert one selectable CANDIDATE line at point."
  (let ((start (point)))
    (insert (format "  [%s] %s\n"
                     (if (mu4e-hubspot--selected-p candidate) "x" " ")
                     (mu4e-hubspot-candidate-label candidate)))
    (put-text-property start (point) 'mu4e-hubspot-candidate candidate)))

(defun mu4e-hubspot--insert-suggestion (email suggestion)
  "Insert a rendering of SUGGESTION (a `mu4e-hubspot-suggestion' or
nil) for EMAIL at point, one selectable line per candidate record."
  (insert (format "%s\n" email))
  (if-let ((contact (and suggestion (mu4e-hubspot-suggestion-contact suggestion))))
      (progn
        (mu4e-hubspot--insert-candidate (mu4e-hubspot--contact-candidate contact))
        (dolist (company (mu4e-hubspot-suggestion-companies suggestion))
          (mu4e-hubspot--insert-candidate
           (mu4e-hubspot--named-candidate "companies" "Company" 'name company)))
        (dolist (deal (mu4e-hubspot-suggestion-deals suggestion))
          (mu4e-hubspot--insert-candidate
           (mu4e-hubspot--named-candidate "deals" "Deal" 'dealname deal))))
    (mu4e-hubspot--insert-candidate (mu4e-hubspot--new-contact-candidate email)))
  (insert "\n"))

(defun mu4e-hubspot--footer-text ()
  (concat
   (pcase (plist-get mu4e-hubspot--source :kind)
     ('view "SPC/RET toggles a record.  C-c C-c logs this email to HubSpot and associates it with the selected records.\n")
     ('compose "SPC/RET toggles a record.  C-c C-c stages the selection for logging once this draft is actually sent.\n"))
   "s searches HubSpot for a contact/company/deal to add.\n"
   "C-c C-k cancels and kills this buffer without applying anything.\n"))

(defun mu4e-hubspot--render ()
  "(Re)draw the suggestions buffer from `mu4e-hubspot--address-suggestions'
and `mu4e-hubspot--manual-candidates'."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (pcase-dolist (`(,email . ,suggestion) mu4e-hubspot--address-suggestions)
      (mu4e-hubspot--insert-suggestion email suggestion))
    (when mu4e-hubspot--manual-candidates
      (insert "Manually added:\n")
      (dolist (candidate (reverse mu4e-hubspot--manual-candidates))
        (mu4e-hubspot--insert-candidate candidate))
      (insert "\n"))
    (insert (mu4e-hubspot--footer-text))
    (goto-char (point-min))))

(defun mu4e-hubspot--display (address-suggestions source)
  "Render ADDRESS-SUGGESTIONS, an alist of (EMAIL . SUGGESTION-OR-NIL),
into the mu4e-hubspot suggestions buffer, tag it with SOURCE (see
`mu4e-hubspot--source'), and display it."
  (let ((buffer (get-buffer-create mu4e-hubspot--buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'mu4e-hubspot-suggestions-mode)
        (mu4e-hubspot-suggestions-mode))
      (unless (equal (plist-get mu4e-hubspot--source :key) (plist-get source :key))
        (setq mu4e-hubspot--selected (make-hash-table :test #'equal)
              mu4e-hubspot--manual-candidates nil))
      (setq mu4e-hubspot--address-suggestions address-suggestions
            mu4e-hubspot--source source)
      (mu4e-hubspot--render))
    ;; Select the window, not just display it -- this is a buffer the
    ;; user is meant to act in immediately (SPC/RET/C-c C-c), so the
    ;; next keystroke needs to land here rather than in the
    ;; view/compose buffer it popped up from.
    (pop-to-buffer buffer)))

(defun mu4e-hubspot-toggle-candidate ()
  "Toggle selection of the HubSpot record described on the current line."
  (interactive)
  (let ((candidate (get-text-property (line-beginning-position) 'mu4e-hubspot-candidate))
        (line (line-number-at-pos)))
    (unless candidate
      (user-error "mu4e-hubspot: nothing selectable on this line"))
    (unless mu4e-hubspot--selected
      (setq mu4e-hubspot--selected (make-hash-table :test #'equal)))
    (let ((key (mu4e-hubspot--candidate-key candidate)))
      (if (gethash key mu4e-hubspot--selected)
          (remhash key mu4e-hubspot--selected)
        (puthash key candidate mu4e-hubspot--selected)))
    (mu4e-hubspot--render)
    (forward-line (1- line))))

(defun mu4e-hubspot--selected-candidates ()
  "Return the list of currently-selected `mu4e-hubspot-candidate' structs."
  (let (candidates)
    (when mu4e-hubspot--selected
      (maphash (lambda (_key candidate) (push candidate candidates)) mu4e-hubspot--selected))
    candidates))

(defun mu4e-hubspot--read-object-type ()
  "Prompt for one of `mu4e-hubspot--object-types', returning its
HubSpot object-type string."
  (cdr (assoc (completing-read "Search HubSpot for: "
                                (mapcar #'car mu4e-hubspot--object-types) nil t)
              mu4e-hubspot--object-types)))

(defun mu4e-hubspot--choose-search-result (type results)
  "Prompt to choose one of RESULTS (HubSpot TYPE objects), each
labeled with its id to disambiguate same-named records.  Returns the
chosen object, or nil if RESULTS is empty."
  (when results
    (let* ((labeled (mapcar (lambda (r)
                               (cons (format "%s  [id: %s]"
                                             (mu4e-hubspot--format-object type r)
                                             (alist-get 'id r))
                                     r))
                             results))
           (choice (completing-read "Choose: " (mapcar #'car labeled) nil t)))
      (cdr (assoc choice labeled)))))

(defun mu4e-hubspot--add-manual-candidate (candidate)
  "Add CANDIDATE to `mu4e-hubspot--manual-candidates', pre-select it,
and re-render -- shared by `mu4e-hubspot-search-and-add' whether
CANDIDATE references an existing HubSpot record or (via its `pending'
slot) a contact to be created on confirm."
  (push candidate mu4e-hubspot--manual-candidates)
  (unless mu4e-hubspot--selected
    (setq mu4e-hubspot--selected (make-hash-table :test #'equal)))
  (puthash (mu4e-hubspot--candidate-key candidate) candidate mu4e-hubspot--selected)
  (mu4e-hubspot--render)
  (message "mu4e-hubspot: added %s" (mu4e-hubspot-candidate-label candidate)))

(defun mu4e-hubspot--prompt-new-contact (default-email)
  "Prompt to create a new HubSpot contact, offered when a manual
contacts search comes back empty.  Returns a pending
`mu4e-hubspot-candidate' (see `mu4e-hubspot--new-contact-candidate'),
or nil if the user declines or gives no email.  DEFAULT-EMAIL
prefills the email prompt (e.g. when the search query itself already
looked like an address)."
  (when (y-or-n-p "No matches -- create a new contact instead? ")
    (let ((email (string-trim (read-string "New contact email: " default-email))))
      (if (zerop (length email))
          (progn (message "mu4e-hubspot: no email given, not creating a contact") nil)
        (let ((name (string-trim (read-string "New contact name (optional): "))))
          (mu4e-hubspot--new-contact-candidate email (and (> (length name) 0) name)))))))

(defun mu4e-hubspot-search-and-add ()
  "Search HubSpot for a contact, company, or deal by free text and add
it to the selection in this suggestions buffer -- for records that
weren't auto-suggested from the message's addresses.

Matches are HubSpot's own free-text search against each object
type's default searchable properties (name/email for contacts, name
for companies, deal name for deals), the same as HubSpot's own
search UI, not a custom filter this package defines.  If a contacts
search comes back empty, offers to create a new contact instead (see
`mu4e-hubspot--prompt-new-contact'); companies/deals searches with no
matches are unaffected.

The chosen (or newly created) record is added pre-selected; toggle it
off with SPC/RET like any other candidate if you change your mind
before confirming."
  (interactive)
  (let* ((type (mu4e-hubspot--read-object-type))
         (query (string-trim
                 (read-string (format "Search HubSpot %s: "
                                       (car (rassoc type mu4e-hubspot--object-types)))))))
    (if (zerop (length query))
        (message "mu4e-hubspot: no search text given")
      (let* ((properties (mu4e-hubspot--object-search-properties type))
             (results (mu4e-hubspot-api-search-by-text type query properties)))
        (if (null results)
            (if (equal type "contacts")
                (when-let ((candidate (mu4e-hubspot--prompt-new-contact
                                        (and (string-match-p "@" query) query))))
                  (mu4e-hubspot--add-manual-candidate candidate))
              (message "mu4e-hubspot: no %s matched %S" type query))
          (when-let ((chosen (mu4e-hubspot--choose-search-result type results)))
            (mu4e-hubspot--add-manual-candidate (mu4e-hubspot--object-candidate type chosen))))))))

;;; Logging and associating

(defun mu4e-hubspot--resolve-associations (candidates)
  "Resolve CANDIDATES (a list of `mu4e-hubspot-candidate') into a
plist (:associations ASSOCIATIONS :failures FAILURES).

Most candidates already reference an existing HubSpot record, so
their `mu4e-hubspot--candidate-key' (a (TYPE . ID) cons) is used
as-is.  A candidate with a `pending' slot set (a \"create new
contact\" candidate from an unmatched address or a manual-search
miss, see `mu4e-hubspot--new-contact-candidate') doesn't have a real
id yet -- this creates it via `mu4e-hubspot-api-create-contact' right
here, immediately before it's needed, so for a draft that happens at
actual send-time (inside the closure staged by
`mu4e-hubspot--stage-for-send'), not at confirm time, consistent with
nothing else being written to HubSpot until the draft is sent.

A failed creation is collected into FAILURES as
((\"contacts\" . EMAIL) . ERROR) -- the same shape
`mu4e-hubspot-api-log-email' uses for association failures -- rather
than aborting the rest of the associations."
  (let (associations failures)
    (dolist (candidate candidates)
      (let ((pending (mu4e-hubspot-candidate-pending candidate)))
        (if (not pending)
            (push (mu4e-hubspot--candidate-key candidate) associations)
          (condition-case err
              (let* ((created (mu4e-hubspot-api-create-contact
                                (plist-get pending :email) (plist-get pending :name)))
                     (id (alist-get 'id created)))
                (push (cons "contacts" id) associations))
            (error (push (cons (cons "contacts" (plist-get pending :email)) err) failures))))))
    (list :associations (nreverse associations) :failures (nreverse failures))))

(defun mu4e-hubspot--report-result (result)
  "Message a summary of RESULT, as returned by `mu4e-hubspot-api-log-email'.
Failures include the underlying error, not just which association
failed, so the actual cause (bad scope, wrong id, etc.) is visible
without having to reproduce it."
  (let ((failures (plist-get result :failures)))
    (if failures
        (message "mu4e-hubspot: logged email %s, but %d association(s) failed:\n%s"
                  (plist-get result :id) (length failures)
                  (mapconcat (lambda (f)
                               (format "  %s: %s" (car f) (error-message-string (cdr f))))
                             failures "\n"))
      (message "mu4e-hubspot: logged and associated email %s" (plist-get result :id)))))

(defun mu4e-hubspot--epoch-millis (&optional time)
  "Return TIME (default now) as a HubSpot-style epoch-millisecond
integer.  HubSpot's datetime properties officially also accept an
ISO-8601 string, but epoch-millis is the format HubSpot's own
examples use for hs_timestamp and is what several reported cases of
API-created emails not appearing on a record's timeline turned out to
need -- so it's used here to avoid that failure mode entirely."
  (round (* 1000 (float-time time))))

(defun mu4e-hubspot--message-timestamp (msg)
  (mu4e-hubspot--epoch-millis (mu4e-message-field msg :date)))

(defun mu4e-hubspot--strip-rendered-headers (text)
  "Strip the From/To/Cc/Subject/Date header block that
`mu4e-view-message-text' prepends to its rendering, returning just
the body.  We already send structured header data separately via
hs_email_headers/hs_email_subject, so this avoids duplicating it
inside hs_email_text too -- which also sidesteps that header block
sometimes coming out strangely word-wrapped by Gnus outside of a
real display (observed in batch testing)."
  (if-let ((boundary (string-match "\n\n" text)))
      (string-trim (substring text (match-end 0)))
    (string-trim text)))

(defun mu4e-hubspot--message-body-text (msg)
  "Best-effort plain-text body for MSG, or nil if it can't be produced.

Uses mu4e's own `mu4e-view-message-text', which re-reads and renders
the raw message file the same way the view buffer does -- this is
what actually reflects what the user is looking at.  (An earlier
version tried the message plist's :body field instead; this mu4e
version doesn't populate it for messages loaded via the message
view, so it always logged an empty body.)  Wrapped in `ignore-errors'
so a rendering failure degrades to \"logged without a body\" rather
than blocking the whole confirm."
  (ignore-errors
    (let ((body (mu4e-hubspot--strip-rendered-headers (mu4e-view-message-text msg))))
      (and (> (length body) 0) body))))

(defun mu4e-hubspot--message-html-text (msg)
  "Return MSG's own HTML rendering (its real text/html part if it has
one, or mu4e's own construction from text/plain otherwise), or nil if
neither is available -- in which case `mu4e-hubspot-api-log-email'
falls back to generating hs_email_html from the plain-text body
itself.  Preferring the message's real HTML (when it has one) avoids
degrading it to plain text and rebuilding crude <br>-based HTML from
that, which would lose real formatting (links, bold, etc.)."
  (ignore-errors (mu4e-view-message-html msg t)))

(defun mu4e-hubspot--log-view-message-now (msg candidates)
  "Log MSG as a HubSpot email engagement and associate it with
CANDIDATES (a list of `mu4e-hubspot-candidate', resolved to real ids
-- creating any pending contacts along the way -- via
`mu4e-hubspot--resolve-associations')."
  (let* ((resolved (mu4e-hubspot--resolve-associations candidates))
         (result (mu4e-hubspot-api-log-email
                  :subject (mu4e-message-field msg :subject)
                  :body (mu4e-hubspot--message-body-text msg)
                  :html (mu4e-hubspot--message-html-text msg)
                  :direction "INCOMING_EMAIL"
                  :timestamp (mu4e-hubspot--message-timestamp msg)
                  :from (car (mu4e-hubspot--contact-pairs msg :from))
                  :to (mu4e-hubspot--contact-pairs msg :to)
                  :cc (mu4e-hubspot--contact-pairs msg :cc)
                  :bcc (mu4e-hubspot--contact-pairs msg :bcc)
                  :associations (plist-get resolved :associations))))
    (mu4e-hubspot--report-result
     (list :id (plist-get result :id)
           :failures (append (plist-get resolved :failures) (plist-get result :failures))))))

(defun mu4e-hubspot--compose-body-text ()
  "Return the plain-text body of the current compose buffer, verbatim
(including any raw MML markup -- callers wanting the real
parts of an MML multipart body should use
`mu4e-hubspot--compose-mime-parts' instead)."
  (save-excursion
    (save-restriction
      (widen)
      (message-goto-body)
      (buffer-substring-no-properties (point) (point-max)))))

(defun mu4e-hubspot--find-mime-part (handle media-type)
  "Return the first MIME handle within HANDLE (as returned by
`mm-dissect-buffer') whose media type is MEDIA-TYPE (e.g.
\"text/html\"), searching multipart structures recursively.  Returns
nil if none is found."
  (if (equal (mm-handle-media-type handle) media-type)
      handle
    (when (equal (mm-handle-media-supertype handle) "multipart")
      (seq-some (lambda (part) (mu4e-hubspot--find-mime-part part media-type))
                (cdr handle)))))

(defun mu4e-hubspot--compose-mime-parts ()
  "If the compose buffer's body is MML markup for a multipart message
with a text/html part -- as produced by e.g. org-mime -- return
(HTML . PLAIN): the real text/html and text/plain part contents.
Returns nil if there's no such html part (the common case for a
plain draft with no MML markup at all), in which case callers should
fall back to `mu4e-hubspot--compose-body-text' for the plain body and
let `mu4e-hubspot-api-log-email' generate hs_email_html from that.

This mirrors the view-side workflow of sending a real HTML rendering
alongside a real plain-text one, rather than logging raw MML markup
(tags and all) as the body, or discarding real formatting by
degrading the html part to plain text.

Operates on a disposable copy of the buffer via `mml-to-mime' (the
same MML->MIME expansion `message-send' itself performs before
transmission) -- the actual compose buffer is never modified."
  (let ((source (buffer-string))
        (separator mail-header-separator))
    (ignore-errors
      (with-temp-buffer
        (insert source)
        (let ((mail-header-separator separator))
          (mml-to-mime)
          (goto-char (point-min))
          (let ((handles (mm-dissect-buffer t t)))
            (unwind-protect
                (when-let ((html-part (mu4e-hubspot--find-mime-part handles "text/html")))
                  (cons (mm-get-part html-part)
                        (when-let ((plain-part (mu4e-hubspot--find-mime-part handles "text/plain")))
                          (mm-get-part plain-part))))
              (mm-destroy-parts handles))))))))

(defun mu4e-hubspot--log-compose-buffer-now (candidates)
  "Log the current compose buffer's message as a HubSpot email
engagement and associate it with CANDIDATES (a list of
`mu4e-hubspot-candidate', resolved to real ids -- creating any
pending contacts along the way -- via
`mu4e-hubspot--resolve-associations').  Must be called from within
the compose buffer, at or after the message has actually been sent
(so headers/body reflect what was sent, and so any pending contact is
only created once the draft is actually going out)."
  (let* ((mime-parts (mu4e-hubspot--compose-mime-parts))
         (html (car mime-parts))
         (body (or (cdr mime-parts) (mu4e-hubspot--compose-body-text)))
         (resolved (mu4e-hubspot--resolve-associations candidates))
         (result (mu4e-hubspot-api-log-email
                  :subject (message-fetch-field "Subject")
                  :body body
                  :html html
                  :direction "EMAIL"
                  :timestamp (mu4e-hubspot--epoch-millis)
                  :from (car (mu4e-hubspot--header-address-pairs "From"))
                  :to (mu4e-hubspot--header-address-pairs "To")
                  :cc (mu4e-hubspot--header-address-pairs "Cc")
                  :bcc (mu4e-hubspot--header-address-pairs "Bcc")
                  :associations (plist-get resolved :associations))))
    (mu4e-hubspot--report-result
     (list :id (plist-get result :id)
           :failures (append (plist-get resolved :failures) (plist-get result :failures))))))

(defun mu4e-hubspot--stage-for-send (compose-buffer candidates)
  "Arrange for CANDIDATES to be resolved (creating any pending
contacts), logged, and associated with the draft in COMPOSE-BUFFER
once it is actually sent.

`message-send-actions' runs each action inside `ignore-errors', so
any failure here is caught and reported explicitly first -- otherwise
it would be silently swallowed and the user would never know the
email wasn't logged."
  (with-current-buffer compose-buffer
    (push (lambda ()
            (condition-case err
                (mu4e-hubspot--log-compose-buffer-now candidates)
              (error
               (message "mu4e-hubspot: failed to log/associate sent email: %s"
                         (error-message-string err)))))
          message-send-actions)))

(defun mu4e-hubspot-confirm-associations ()
  "Apply the HubSpot records selected in this suggestions buffer.

For a viewed message, logs and associates immediately.  For a draft,
stages the selection so it is only logged and associated once the
draft is actually sent -- nothing is written to HubSpot on confirm
itself in that case."
  (interactive)
  (let ((candidates (mu4e-hubspot--selected-candidates)))
    (unless candidates
      (user-error "mu4e-hubspot: nothing selected"))
    (let ((source mu4e-hubspot--source))
      (pcase (plist-get source :kind)
        ('view
         (mu4e-hubspot--log-view-message-now (plist-get source :msg) candidates)
         (message "mu4e-hubspot: logged and associated with %d record(s)" (length candidates)))
        ('compose
         (mu4e-hubspot--stage-for-send (plist-get source :buffer) candidates)
         (message "mu4e-hubspot: will log and associate %d record(s) when this draft is sent"
                   (length candidates)))
        (_ (user-error "mu4e-hubspot: no source for this suggestions buffer"))))))

(defun mu4e-hubspot-cancel ()
  "Cancel this HubSpot suggestions buffer and kill it.
Nothing selected in it is applied -- for a draft, this only discards
the pending selection; it does not un-stage associations from an
earlier confirm in the same buffer."
  (interactive)
  (quit-window t))

;;; Entry points

;;;###autoload
(defun mu4e-hubspot-show-suggestions ()
  "Show suggested HubSpot contacts/companies/deals for the message at
point in mu4e-view, based on its From and Cc addresses.

Results are cached for the remainder of this viewing session (i.e.
until a different message is shown in this mu4e-view buffer), so
re-running this command against the same message does not re-query
HubSpot.  Select records with SPC/RET and confirm with C-c C-c in the
resulting buffer to log this email to HubSpot and associate it."
  (interactive)
  (let* ((msg (mu4e-message-at-point))
         (session-key (mu4e-hubspot--message-session-key msg))
         (addresses (mu4e-hubspot--view-addresses msg)))
    (unless addresses
      (user-error "mu4e-hubspot: no From/Cc addresses found on this message"))
    (mu4e-hubspot--display
     (mu4e-hubspot--suggestions-for-addresses session-key addresses)
     (list :kind 'view :key session-key :msg msg))))

;;;###autoload
(with-eval-after-load 'mu4e-view
  (define-key mu4e-view-mode-map (kbd "C-c C-h") #'mu4e-hubspot-show-suggestions))

;;;###autoload
(defun mu4e-hubspot-show-compose-suggestions ()
  "Show suggested HubSpot contacts/companies/deals for the current
draft, based on its To, Cc, and Bcc addresses.

Results are cached for the remainder of this drafting session (i.e.
until this buffer is killed), so re-running this command after
editing recipients only re-queries HubSpot for addresses it hasn't
already looked up in this buffer.  Run automatically whenever a
compose buffer is created (see `mu4e-compose-mode-hook'); re-run by
hand (bound to \"C-c C-h\") to refresh after changing recipients.
Selections made in the resulting buffer are only logged and
associated once this draft is actually sent."
  (interactive)
  (let ((addresses (mu4e-hubspot--compose-addresses))
        (buffer (current-buffer)))
    (if (null addresses)
        (message "mu4e-hubspot: no To/Cc/Bcc addresses on this draft yet")
      (mu4e-hubspot--display
       (mu4e-hubspot--suggestions-for-addresses "compose" addresses)
       (list :kind 'compose :key buffer :buffer buffer)))))

;;;###autoload
(add-hook 'mu4e-compose-mode-hook #'mu4e-hubspot-show-compose-suggestions)

;;;###autoload
(with-eval-after-load 'mu4e-compose
  (define-key mu4e-compose-mode-map (kbd "C-c C-h") #'mu4e-hubspot-show-compose-suggestions))

(provide 'mu4e-hubspot)
;;; mu4e-hubspot.el ends here
