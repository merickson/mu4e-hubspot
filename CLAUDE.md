# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

The full original spec is implemented: viewing a received message in mu4e, and composing/replying to
one, each show HubSpot contacts/companies/deals suggested from their addresses (`From`/`Cc` for view,
`To`/`Cc`/`Bcc` for compose) as a *selectable* list, and pressing `s` in that list lets you free-text
search HubSpot for a contact/company/deal to add when nothing relevant was auto-suggested. Confirming a
selection logs the message as a HubSpot email engagement and associates it with the chosen records, so
the message actually shows up on their HubSpot timelines (not just "the contact is associated" — see
"What 'associating an email' means" below). See "What this package does" below for the full scope —
anything further (e.g. re-associating an already-logged email, bulk operations) would be new scope
beyond the original spec, not a gap in it.

## Commands

- `make test` — run the full ERT suite in batch mode (`emacs --batch -l ert ... -f
  ert-run-tests-batch-and-exit`). This is the only test entry point; there's no separate lint/build step.
- To run a single test interactively: `emacs --batch -L . -l ert -l mu4e-hubspot-api.el -l
  mu4e-hubspot.el -l tests/mu4e-hubspot-api-test.el -l tests/mu4e-hubspot-test.el --eval
  "(ert-run-tests-batch-and-exit \"test-name-regexp\")"`.
- Byte-compile check (not part of `make test`, but useful to catch warnings):
  `emacs --batch -L . -f batch-byte-compile mu4e-hubspot-api.el mu4e-hubspot.el`. Delete the resulting
  `.elc` files afterward (or rely on `.gitignore`, which already excludes them) — they aren't committed.

## File layout

- `mu4e-hubspot-api.el` — the HubSpot CRM API client. Deliberately has **no dependency on mu4e** (no
  `require 'mu4e`), so it can be loaded and tested without mu4e installed/running. Everything that talks
  HTTP/JSON to HubSpot lives here, including the email-engagement creation and association calls.
- `mu4e-hubspot.el` — the mu4e integration layer. Requires both `mu4e` and `mu4e-hubspot-api`. Owns
  header/address extraction, the per-session suggestion cache, the selectable suggestions buffer, the
  view/compose write paths, and mu4e keybindings.
- `tests/mu4e-hubspot-api-test.el` — API-layer tests. Stub `mu4e-hubspot-api--request` (or the
  functions built on it) via `cl-letf`; never hit the real network.
- `tests/mu4e-hubspot-test.el` — address-extraction, session-cache, and selection/confirm-dispatch
  tests, driven with plain mu4e message plists and synthetic suggestions buffers rather than a live
  mu4e session.

Keep this API/UI split when adding features — new HubSpot calls go in `mu4e-hubspot-api.el`; new mu4e
hook/buffer/interactive-command code goes in `mu4e-hubspot.el`.

## What this package does

`mu4e-hubspot` is an Emacs package that integrates `mu4e` with HubSpot, modeled on the workflow of the
HubSpot for Chrome/Gmail extension:

- **Associate emails with HubSpot objects.** Both existing (received) emails being viewed and draft
  emails being composed can be associated with selected HubSpot deals, contacts, and companies.
- **Auto-suggested associations.** When viewing or composing a message, the package extracts the
  relevant email addresses from the message headers and looks up matching HubSpot objects to suggest:
  - Received emails: addresses from `From` and `Cc`.
  - Draft emails: addresses from `To`, `Cc`, and `Bcc`.
- **Manual search.** Pressing `s` in the suggestions buffer (`mu4e-hubspot-search-and-add`) prompts for
  an object type and free-text query, using HubSpot's own free-text search (the `query` parameter on the
  CRM search endpoint, matching against each type's default searchable properties — not a custom
  filter), then lets the user pick a result to add to the selection, for records that weren't
  auto-suggested. Added pre-selected; toggle it off with SPC/RET like any other candidate.
- **Create a contact that doesn't exist yet.** Contacts only (not companies/deals). Two entry points:
  an address with no matching HubSpot contact renders a selectable "create new contact <email>"
  candidate right in place of a match (instead of a dead-end "no matching HubSpot contact" line); and a
  manual contacts search (`s`) with zero results offers to create one instead, prompting for email
  (required) and name (optional). Either way the result is an ordinary selectable/toggleable candidate
  — `mu4e-hubspot-candidate`'s `pending` slot marks it as "not created yet" — and the actual
  `mu4e-hubspot-api-create-contact` call happens in `mu4e-hubspot--resolve-associations`, right before
  the id is needed to associate it, which for a compose draft means at actual send-time, not at confirm
  time (same "nothing written until send" rule as every other compose association). A failed creation is
  collected as a failure alongside association failures rather than aborting the rest.
- **Send-time association.** Associations chosen while composing are applied to the corresponding
  HubSpot objects when the draft is actually sent, not when the association is chosen.

## What "associating an email" means

Mirroring HubSpot's own Gmail/Outlook extensions, associating is not just "mark the matched contact as
related to this deal" — it creates a HubSpot **email engagement** (`crm/objects/.../emails`) representing
the message itself (subject, body, direction, timestamp, participants) and associates *that object* with
the selected contacts/companies/deals. That's what makes the email show up on those records' timelines,
which is the actual visible payoff of the feature. `mu4e-hubspot-api-log-email` in `mu4e-hubspot-api.el`
is the orchestrator: create the email object, then associate it with each selected record, collecting
(not aborting on) individual association failures.

**Timestamp format:** `hs_timestamp` is sent as an epoch-millisecond integer
(`mu4e-hubspot--epoch-millis` in `mu4e-hubspot.el`), not an ISO-8601 string. HubSpot's datetime
properties document both as valid, but multiple HubSpot Community reports describe API-created email
engagements that use an ISO string not showing up on a record's timeline at all despite the create call
succeeding — epoch-millis is what HubSpot's own examples use for this property and avoids that failure
mode. If a logged email still doesn't appear after this, check: the record's timeline filters aren't
hiding activity-type events, and the returned email id (from the `mu4e-hubspot: logged and associated
email ID` message) actually resolves via a direct `GET /crm/objects/2026-03/emails/ID` call.

## Locked-in architecture decisions

- **API version.** All HubSpot calls target the date-based "2026-03" API version
  (`mu4e-hubspot-api--version`), e.g. `/crm/objects/2026-03/contacts/search`, not the legacy `/crm/v3/`
  or `/crm/v4/` paths.
- **Associations use the "default" endpoint.** `mu4e-hubspot-api-associate` calls
  `PUT /crm/objects/2026-03/{from}/{fromId}/associations/default/{to}/{toId}`, which creates HubSpot's
  standard unlabeled association without needing a numeric association-type id. An earlier version
  looked up the type id via the `/crm/associations/2026-03/{from}/{to}/labels` endpoint first — that
  lookup turned out to be the actual cause of a real "associations failed" bug report, so it was dropped
  entirely in favor of the simpler, documented default-association endpoint. Only reach for the
  labels-lookup + explicit-type-id path (`PUT .../associations/{to}/{toId}/{typeId}`) if a *custom*
  (non-default) label is ever needed — not the case for anything this package does today.

- **Multi-account auth via mu4e contexts.** HubSpot credentials are plain `defvar`s
  (`mu4e-hubspot-api-token`, `mu4e-hubspot-api-portal-id`) that the user sets per `mu4e-context` via
  that context's `:vars` alist — mu4e applies context `:vars` as global `setq` bindings when a context
  becomes active, so no custom context-storage plumbing was needed. Do not implement a single global
  token or a separate credentials store.
- **HTTP client.** `mu4e-hubspot-api--request` in `mu4e-hubspot-api.el` uses `url-retrieve-synchronously`
  plus `json.el` (`json-encode`/`json-read`) — no external processes (curl, Python, Node). Keep the
  package dependency-free and MELPA-friendly.
- **Caching scope.** `mu4e-hubspot--session-cache-get` in `mu4e-hubspot.el` is a buffer-local cache keyed
  by a session key plus email address. For viewing, the session key is the message's message-id
  (falling back to docid), so the cache resets whenever a different message is shown in that mu4e-view
  buffer. For composing, the session key is a constant (`"compose"`) since the cache is already scoped
  to that one draft's buffer for its whole lifetime — recipients can be added/removed/edited across
  multiple refreshes without losing previously-looked-up addresses. Never persisted to disk, no
  cross-session TTL cache.

## Key mu4e integration points

Read mu4e's source under `mu4e-*.el` (installed via Homebrew's `mu` package on this machine, at
`$(brew --prefix mu)/share/emacs/site-lisp/mu/mu4e/`) rather than assuming API shape — mu4e's contact
representation is a plist (`(:name ... :email ...)`, accessed via `mu4e-contact-name`/
`mu4e-contact-email`, defined in `mu4e-contacts.el`), and message fields are plists accessed via
`mu4e-message-field` (see `mu4e-message.el`).

- **Implemented, view side:** `mu4e-view-mode` — `mu4e-hubspot-show-suggestions` (bound to `C-c C-h` in
  `mu4e-view-mode-map`) reads `From`/`Cc` off `(mu4e-message-at-point)`.
- **Implemented, compose side:** `mu4e-compose-mode` (which derives from `message-mode`) — addresses are
  read live from the buffer via `message-fetch-field` + `mail-header-parse-addresses` (from Emacs'
  built-in `mail-parse`), not from an indexed mu4e message plist, since a draft-in-progress has no
  `mu4e-message-at-point` to query. `mu4e-hubspot-show-compose-suggestions` runs automatically via
  `mu4e-compose-mode-hook` (mu4e's own docs recommend this hook for acting on an already-constructed
  draft) and is also bound to `C-c C-h` in `mu4e-compose-mode-map` for manually refreshing after the
  user edits recipients — there is no live/reactive re-triggering on every keystroke.
- **Send-time write, compose side:** confirming a selection in a compose buffer does not write anything;
  `mu4e-hubspot--stage-for-send` pushes a closure onto the buffer-local `message-send-actions` (a plain
  `defvar`, made buffer-local by `message-mode` itself before `mu4e-compose-mode-hook` runs, so pushing
  onto it is always buffer-local and never leaks to other compose buffers). That closure re-reads
  subject/body/headers live from the buffer when it actually runs (right after a successful send, still
  in that buffer per `message-send`'s implementation), so it captures what was actually sent, not what
  was staged at confirm time. **Gotcha:** `message-do-actions` runs every action wrapped in
  `ignore-errors`, so a failed API call would otherwise fail completely silently — the closure has its
  own `condition-case` that reports failures via `message` before `ignore-errors` can swallow them.
- **Body text, view side:** mu4e's message plist only documents a `:body` field for messages loaded in
  the message view, and this mu4e version (1.14.3, confirmed by reading `mu4e-view.el`) doesn't actually
  populate/use it for rendering — the view buffer instead re-reads and renders the raw message file via
  Gnus' article machinery. An earlier version of `mu4e-hubspot--message-body-text` used `:body`
  opportunistically and otherwise omitted `hs_email_text` entirely — meaning every logged received email
  had an empty body. Fixed by calling mu4e's own public `mu4e-view-message-text` (in `mu4e-view.el`),
  which performs that same raw-file-read-and-render mu4e already relies on for the view buffer itself, so
  it reflects what the user is actually looking at rather than something hand-rolled and fragile.
  `mu4e-view-message-text` prepends a small From/To/Cc/Subject/Date header block (via Gnus) before the
  body; `mu4e-hubspot--strip-rendered-headers` trims that off (split on the first blank line) since it
  would otherwise duplicate `hs_email_headers`/`hs_email_subject`, and because that header block rendered
  strangely word-wrapped in `--batch` testing (likely display/frame-width dependent — reason enough to
  just not carry it into `hs_email_text` at all). Compose-side body text has no such gap
  (`message-goto-body` + buffer text is reliable for a plain edited draft).
- **HTML body / formatting.** HubSpot's engagement timeline renders `hs_email_html`, not `hs_email_text`
  — bare `\n` in `hs_email_text` does not produce line breaks in the UI (widely reported HubSpot
  behavior), so every logged email needs an `hs_email_html` value too, or paragraph/line breaks collapse
  into one run-on line. `mu4e-hubspot-api-log-email`'s `:html` argument, when given, is sent verbatim as
  `hs_email_html`; when omitted (nil) it's generated from `:body` via `mu4e-hubspot-api--text-to-html`
  (HTML-escape, then `\n` -> `<br>\n`). For the view side, `mu4e-hubspot--message-html-text` passes the
  message's own real HTML through `mu4e-view-message-html` as `:html` — this returns the message's actual
  text/html part verbatim when it has one (preserving real links/bold/etc., not a lossy
  HTML→plain-text→crude-HTML round trip), or mu4e's own well-formed `<pre style="white-space:pre-wrap">`
  construction when the message is plain-text-only. The `:body`→`:html` fallback in the API layer mainly
  exists for a plain (non-MML) compose draft, which has no separate real HTML source, and as a defensive
  fallback if `mu4e-view-message-html` itself fails on the view side.
- **Compose-side HTML (org-mime, etc.).** A compose buffer can itself contain MML markup for a genuine
  multipart/alternative message (e.g. org-mime's `<#multipart type=alternative>` / `<#part type=...>`
  tags) rather than being plain text. `mu4e-hubspot--compose-mime-parts` detects this by running
  `mml-to-mime` (the same MML→MIME expansion `message-send` itself performs before transmission) on a
  **disposable copy** of the buffer, then `mm-dissect-buffer` + a small recursive
  `mu4e-hubspot--find-mime-part` to pull out the real text/html and text/plain part contents — mirroring
  the view side's "send the message's own real HTML, not a rebuilt one" approach, rather than logging raw
  MML markup (tags and all) as the body, or degrading the html part to plain text and rebuilding crude
  HTML from that. Returns nil (both parts) when the body has no MML html part at all — the common case
  for a plain draft — so `mu4e-hubspot--log-compose-buffer-now` falls back to the plain
  `mu4e-hubspot--compose-body-text` extraction and lets the API layer generate `hs_email_html` from that,
  same as before. Never touches the live compose buffer -- `mml-to-mime` runs only in the temp-buffer
  copy, so the user's actual draft (MML markup and all) is left exactly as they wrote it, unaffected by a
  confirm that happens before the message is actually sent.
- **Suggestions-buffer keymap gotcha:** `mu4e-hubspot-suggestions-mode-map` is bound with `define-key`
  calls placed *after* the `define-derived-mode` form (matching how `mu4e-view-mode-map`/
  `mu4e-compose-mode-map` are extended elsewhere in this file), not via a pre-declared `(defvar
  mu4e-hubspot-suggestions-mode-map ...)` before it. `mu4e-hubspot--display` also uses `pop-to-buffer`,
  not `display-buffer` — the latter shows the window without selecting it, so the very next SPC/RET the
  user presses (expecting to toggle a candidate) would go to whatever buffer they were in instead
  (previously reported: candidates looked "stuck read-only" because keystrokes never reached the
  suggestions buffer at all). `mu4e-hubspot-test-suggestions-mode-map-bindings` and
  `mu4e-hubspot-test-display-selects-the-window` in the test suite exist specifically to catch a
  regression here.
