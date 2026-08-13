# Deploying the landing page

This folder is a self-contained handoff bundle for the **SentryWebsite**
repo (the GitHub Pages site served at `https://malekthecoder.github.io/Sentry/`,
to be fronted by a custom domain). Nothing here is served from the app
repo itself.

## What's in the bundle

```
docs/landing/
├── index.html      # the whole page — inline CSS, no JS, no external assets
├── assets/         # screenshots, copied from docs/screenshots/
│   ├── ios-alerts.png
│   ├── ios-dashboard.png
│   ├── ios-history.png
│   ├── macos-dashboard.png
│   ├── macos-menubar.png
│   └── watch-overview.png
└── DEPLOY.md       # this file (do not deploy)
```

## To deploy

1. Copy `index.html` and the entire `assets/` folder into the SentryWebsite
   repo, keeping them **adjacent** — the page references images as
   `assets/<name>.png`, so `assets/` must sit next to `index.html`.
   Because every link in the page is either absolute (GitHub, Pages) or
   relative (`assets/`), the bundle works unchanged at the site root, at
   the `/Sentry/` project path, or behind the custom domain.
2. Do **not** copy `DEPLOY.md`.
3. Commit and push; GitHub Pages picks it up automatically.

## Before or shortly after deploying

- **Support email.** The page contains the literal marker
  `TO-FILL(support-email)` (in the email-capture section's `mailto:` link).
  Replace it with the real address once one exists — grep for `TO-FILL`.
- **Buttondown.** The email-capture section carries an HTML comment
  (`BUTTONDOWN-EMBED`) marking exactly which element the Buttondown
  subscribe form replaces, once that account is created.
- **Privacy policy.** The footer links
  `https://malekthecoder.github.io/Sentry/privacy-policy` — the same URL
  compiled into the app (`SentryKit/Models/AppCredits.swift`). The policy
  text (`docs/privacy-policy.md` in the app repo) is not yet published
  there; publish it to that path as part of the same deploy, or the footer
  link 404s.

## Paths that must not break

The shipped app compiles in two URLs on this same Pages site. Whatever the
site's layout becomes, these must keep resolving:

- `https://malekthecoder.github.io/Sentry/appcast.xml` — Sparkle update
  feed (`SUFeedURL` in `project.yml`; baked into every shipped binary,
  cannot be changed retroactively).
- `https://malekthecoder.github.io/Sentry/privacy-policy` — the About
  screen's privacy link.

If the custom domain is added via a CNAME on this Pages site, GitHub
redirects the `github.io` addresses to it, so the compiled-in URLs keep
working — but verify both after the domain flips.

## When things change

- **The name.** "Sentry" is provisional pending a trademark decision. It
  appears in `index.html` only as visible text and in the `<title>`/meta
  description — never in anchors or asset filenames — so a rename is a
  find-and-replace of the visible strings plus the absolute GitHub URLs
  (repo rename changes those too; GitHub redirects old repo URLs, but
  update them anyway). The screenshot filenames are name-neutral on
  purpose; leave them.
- **The price.** Both amounts live in one place: the Pro plan card in the
  pricing section (`$14.99` launch, struck-through `$19.99` regular). When
  the launch price ends, delete the `<span class="was">` element and put
  the regular price in its place. The "3 Macs" and "no subscription" terms
  are in the same card's `price-note` line.
- **New screenshots.** Re-copy from `docs/screenshots/` in the app repo
  into `assets/` (same filenames = no HTML edit). If dimensions change,
  update the corresponding `<img>` `width`/`height` attributes to match
  the new aspect ratio.
- **Minimum macOS version.** Stated three times: the hero microcopy, the
  Free plan's download note, and the footer. Grep for `macOS 14`.
