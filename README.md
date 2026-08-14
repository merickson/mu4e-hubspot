# mu4e-hubspot

A simple HubSpot integration module for [mu4e](https://www.djcbsoftware.nl/code/mu/mu4e.html).

Why? I love mu4e as my email client. I use HubSpot, but I don't want to connect it straight to my inbox but would rather select what gets logged.

It provides a subset of functionality of how the Chrome and Outlook plugins interact with GMail and Outlook.

Claude was my homeboy on this. This README was written by me (a human), but the rest was almost all vibe-coded.

## Install

Pretty straightforward:

```elisp
(use-package mu4e-hubspot
    :ensure t
    :vc (:url "https://github.com/merickson/mu4e-hubspot.git"
           :rev :newest)
    :config
    (setq mu4e-hubspot-api-token "<YOUR HUBSPOT TOKEN HERE>"))
```

### mu4e-contexts
We respect mu4e-context, allowing you to have a different HubSpot configuration for different accounts. Simply add `mu4e-hubspot-api-token` to the context's `:vars` alist.

## Usage

This works in both `mu4e-view-mode` and `mu4e-compose-mode`. `C-c C-h` will call either:

- `mu4e-hubspot-show-suggestions` in view
- `mu4e-hubspot-show-compose-suggestions` in compose.

They will look at the addresses the email was sent to / will be sent to, and suggest objects for association. Select each with SPC/RET to toggle, and `s` will search HubSpot for records that weren't auto-suggested. `C-c C-c` will confirm and `C-c C-k` will cancel and kill the buffer.

When in view mode, `C-c C-c` will immediately update HubSpot. In compose, it will update HubSpot only after the email is sent as part of `message-send-actions`. It's smart enough to understand plaintext versus HTML email (even with `org-mime` when composing new emails) and will default to sending the HTML content to HubSpot.

## Getting the right HubSpot Token

HubSpot has a long series of ways to integrate with it, so there's multiple paths that may seem right but will lead you astray. Here's how to get what you need here:

1. From the upper right hand side of the UI, select your profile icon to open the menu and select "Profile & Preferences"
2. From the preferences screen that opens, under the heading "Account Management", expand "Integrations", and select "Service Keys". 
3. Select the button "Create service key" in the upper right.
4. Give your token a name
5. Select the following scopes:
   1. `crm.objects.companies.read`
   2. `crm.objects.companies.write`
   3. `crm.objects.contacts.read`
   4. `crm.objects.contacts.write`
   5. `crm.objects.deals.read`
   6. `crm.objects.deals.write`
   7. `oauth`
6. Select the button "Create" at the top right of the screen.
7. It'll give you a Service Key, and should start with `pat-...`. That's the token you want to use.

Put that token somewhere appropriate, and call your favorite function to pull it into mu4e-hubspot (`auth-sources`, perhaps?)
