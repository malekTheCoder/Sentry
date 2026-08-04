# Publishing the privacy policy

App Store Connect requires a **public HTTPS URL** that serves the privacy policy. It must be reachable without a login, without a redirect to a login, and it must not 404 — review will click it.

`docs/privacy-policy.md` is the source of truth. This document is about getting it to a URL.

## Before you publish

Fill in the two placeholders in `docs/privacy-policy.md`:

- `[EFFECTIVE DATE — TO FILL IN]` — the date the first public build ships is fine.
- `[CONTACT EMAIL — TO FILL IN]` — must be an address you actually read. Reviewers sometimes write to it, and some jurisdictions require a working contact.

Then re-read the "What leaves your device" and "AI agents" sections against the build you are actually shipping. If you turn a default on or off before release, the policy has to change with it.

## The cheap path: GitHub Pages

You already publish the Sparkle appcast at `malekthecoder.github.io/Sentry/`, so the hosting is in place. The policy can live in the same site.

### If that site is served from a `docs/` folder or a `gh-pages` branch of a public repo

1. Copy the finished policy into the site, as `privacy.md` (or `privacy/index.md`).
2. Add a Jekyll front matter block at the top so GitHub renders it as a page rather than raw text:

   ```
   ---
   title: Sentry Privacy Policy
   ---
   ```

   GitHub Pages runs Jekyll by default and converts Markdown to HTML automatically. No build step, no dependencies.
3. Commit and push. The page appears within a minute or two at
   `https://<user>.github.io/<repo>/privacy` (or `/privacy.html`, depending on your permalink settings).
4. Open the URL in a private browsing window to confirm it loads with no login.

### If you want a separate, minimal repo instead

1. Create a public repo, e.g. `sentry-privacy`.
2. Add `index.md` containing the policy, with the front matter block above.
3. Repo → Settings → Pages → Source: "Deploy from a branch", branch `main`, folder `/ (root)`. Save.
4. Wait for the green check, then visit `https://<user>.github.io/sentry-privacy/`.

The repo must be **public**. Pages on a private repo requires a paid plan and, more importantly, may not serve to anonymous visitors — which fails review.

### Keeping it in sync

Whatever you choose, treat the published page as a copy of `docs/privacy-policy.md` in this repo. When the policy changes here, push the change there in the same release. A one-line release checklist item is enough; a small script that copies the file and prepends front matter is better.

### Alternatives, if you would rather not use GitHub Pages

Any static host works: Cloudflare Pages, Netlify, Vercel, or a `privacy` page on a product site you own. The requirements are the same — public, HTTPS, no login, stable URL. Avoid Google Docs, Notion public links, and Gists: they work until the sharing setting drifts, and a dead privacy URL can hold up a release.

Prefer a URL you can keep forever. Changing it later means editing it in App Store Connect for every app and shipping a new build for the in-app link.

## Where the URL has to go

### 1. App Store Connect — required

For **both** the iOS app and the watchOS app (a watch app bundled with an iOS app inherits the iOS listing; a standalone one needs its own):

- App Store Connect → your app → **App Privacy** → **Privacy Policy** → Edit → paste the URL.
- It is set per-localization. If you ship more than one language, each localization has its own field and each must be filled.

While you are in App Privacy, you also have to complete the **data collection questionnaire**. Based on the code, the honest answers are: no data is collected, no data is linked to the user, and no data is used for tracking — *unless* you decide the precise-location capability needs declaring. See the open questions in the accompanying report. The iOS `PrivacyInfo.xcprivacy` currently declares Precise Location as collected-but-not-linked-and-not-tracked, so the questionnaire answer must match that manifest.

### 2. In the app — Settings or About

Add a link labelled "Privacy Policy" that opens the URL in the browser. Put it wherever the app already shows version and licence information — the About pane, or the bottom of General settings. Reviewers look for it, and it is the only way a user who has already installed the app can find the policy.

This applies to the iPhone and Watch companion too, at least on iPhone; a link in the iOS Settings tab is enough.

### 3. The Mac direct-download build — do this too

The Mac app ships outside the App Store, so nobody is forcing you. Do it anyway:

- The same "Privacy Policy" link in Settings → General or the About window.
- A link on the download page, next to the download button.

The Mac build is the one that opens a local network listener, can talk to AI agents, and checks for updates over the internet. It is the version where the policy actually has something to say, and it is the version whose users have the least reason to trust an unsigned-looking download. Linking the policy prominently is worth more here than on iOS.

## Final check before submitting

- [ ] Both placeholders filled in.
- [ ] URL loads over HTTPS in a private window, no login, no certificate warning.
- [ ] URL pasted into App Store Connect for every app and every localization.
- [ ] App Privacy questionnaire answers match `PrivacyInfo.xcprivacy` and match the policy text.
- [ ] In-app link present on iOS and macOS, and it opens the right page.
- [ ] Mac download page links it.
