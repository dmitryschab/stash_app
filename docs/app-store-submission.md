# Stash — App Store and TestFlight submission checklist

Everything App Store Connect will ask for, answered. Copy the blocks marked **PASTE** straight into
the matching field. Fields in `[[ ]]` need a real value from you before submitting.

Target: **external TestFlight beta first, App Store release later.** External TestFlight goes through
Beta App Review, which applies most of the App Store Review Guidelines — so nothing here is deferrable
to "later". The two that bite hardest at TestFlight are the demo-account rule (2.1) and the
account-deletion rule (5.1.1(v)).

Current build: bundle ID `dev.dmitryschab.Stash`, team `S76KJ8Y6C3`, deployment target iOS 17.0,
iPhone only, marketing version 1.0, build 14 (`App/project.yml`).

---

## 0. Blockers that live in the code, not in App Store Connect

Submitting before these are true means a rejection, not a question. Eight of the nine are closed;
the one that is not — the legal placeholders — is the reason this build is not uploaded yet.

| # | Blocker | Status | Why | Where |
|---|---|---|---|---|
| 1 | `PrivacyInfo.xcprivacy` in the app target | **Done** | Required since May 2024; upload is rejected without it when required-reason APIs are used. Content in §3 below. | `App/PrivacyInfo.xcprivacy` — bundle root, not `Resources/` |
| 2 | `com.apple.developer.applesignin` entitlement | **Done in the project** | Sign in with Apple does not work without it. The provisioning profile still has to carry the capability. | `App/Stash.entitlements`, `App/project.yml` |
| 3 | In-app **Delete account** that also revokes the Apple grant | **Done** | Guideline 5.1.1(v). Revocation needs a `refresh_token`, so `SignInView` sends Apple's one-time `authorizationCode` at sign-in and `DELETE /v1/me` revokes with it — and `deploy.sh` refuses to deploy without `APPLE_TEAM_ID`/`APPLE_KEY_ID`/`APPLE_PRIVATE_KEY`, because a box missing them signs users in it can never revoke. | `stash_auth.py`, `deploy.sh`, Library → gear → Delete account |
| 4 | In-app **Export my data** | **Done** | Promised in the privacy policy. `GET /v1/me/export` streams the server side, the app appends the on-device library. | `stash_auth.py`, Library → gear → Export my data |
| 5 | Third-party AI named before anything leaves the device | **Done** | Guideline 5.1.2(i). The sign-in screen names Groq and AWS Bedrock and carries "By continuing you agree to the Terms and Privacy Policy" with both linked; the Import screen repeats the split above the submit button. Consent is by continuation — there is no checkbox anywhere, and `terms.html` says so. | `App/Sources/SignInView.swift`, `ImportView.swift` (`cloudDisclosure`, `legalSection`) |
| 6 | No reachable non-functional prototype | **Done** | Guideline 2.2. `ConnectFlowView` (hardcoded "1,868 favourites imported") is now behind `#if DEBUG`, so no release build can reach it. | `App/Sources/ImportView.swift` |
| 7 | No persistent offline video copies | **Done** | Guideline 5.2.3. "KEEP OFFLINE" and the local-file playback path are gone; only the transient fetch for transcription and OCR remains. | `App/Sources/WatchSection.swift` |
| 8 | Legal placeholders filled | **Open** | `privacy.html` and `terms.html` carry `[[TOKEN]]` values. Reviewers open both URLs. | `services/webhook/site/` |
| 9 | Reviewer invite code + seeded demo library | **Done** | `mint --demo` stamps `demo: true` on the invite; the account inherits it, `/v1/auth/apple` and `/v1/me` echo it, and the app seeds ~21 already-analysed sample videos once per user id. Mint the code **without** `--demo` and the reviewer still lands in an empty app. §6. | `manage_invites.py`, `stash_auth.py`, `App/Sources/SampleData.swift` |

---

## 1. App Privacy — nutrition label answers

App Store Connect → App Privacy. Answer per data type. "Linked to you" means associated with the
user's identity; every Stash record is keyed to the Apple user identifier, so anything collected is
linked. **Nothing is used for tracking**, and there is no advertising SDK, no analytics SDK and no
data broker in the picture.

### Collected — declare these

| Data type | Collected | Linked to identity | Tracking | Purposes | What it actually is |
|---|---|---|---|---|---|
| Identifiers → **User ID** | Yes | Yes | No | App Functionality | The Apple app-specific user identifier, the invite code, and the quota counters keyed to it. |
| User Content → **Other User Content** | Yes | Yes | No | App Functionality | The Favourites list (video ID, link, save date, creator handle, caption, hashtags, thumbnail URL, duration) and everything derived from it: category, title, summary, topics, recipe/track/code cards, the transcript, and the on-screen text. |
| **Other Data** | Yes | Yes | No | App Functionality | Server access logs (timestamp, path, status, IP) kept 30 days for uptime and abuse prevention. |

### Not collected — and be able to say why

| Data type | Answer | Reason |
|---|---|---|
| Contact Info → Name | No | Stash requests no name from Apple. |
| Contact Info → Email Address | No | Stash requests no email from Apple. Not even a private-relay address. |
| Contact Info → Phone, Address, Other | No | Never asked for. |
| Health & Fitness, Financial Info, Location, Sensitive Info, Contacts | No | Never touched. No location API, no contacts API, no payments. |
| User Content → **Audio Data** | No | The audio track is extracted from a saved video, sent to Groq, transcribed, and deleted — processed to service the request and not retained. That is Apple's "not collected" case. The *transcript* is retained and is declared under Other User Content. |
| User Content → **Photos or Videos** | No | Same shape: the server streams a saved video to the device, Vision reads the on-screen text from sampled frames locally, and both copies are deleted. No offline video copies are kept anywhere. |
| User Content → Emails or Text Messages, Gameplay Content, Customer Support | No | — |
| Browsing History | No | — |
| Search History | No | In-app search runs against the local library and is not stored or sent anywhere. |
| Purchases | No | Free app, no IAP. |
| Usage Data → Product Interaction / Advertising Data / Other | No | No analytics SDK. |
| Diagnostics → Crash / Performance / Other | No | No crash-reporting SDK. TestFlight and App Store crash reports are collected by Apple, not by us, and are not declared here. |
| Identifiers → Device ID | No | No IDFA, no IDFV collection, no ATT prompt. |

**"Does your app use data for tracking?" → No.** Nothing is linked with third-party data for
advertising, and no data goes to a data broker. Therefore no App Tracking Transparency prompt.

**If you add an analytics or crash SDK later, this label is wrong the day you add it.** The label is
per-version and must be re-answered.

---

## 2. Privacy policy URL and account-deletion URL

- Privacy Policy URL: `https://stash.dmitrijs.dev/privacy`
- Account deletion: App Store Connect asks how an account is deleted. Answer that deletion is
  **inside the app** (Library tab → gear → Delete account). Only supply a URL if there is a web path too;
  there is not, and an in-app path is what the guideline wants.

---

## 3. Privacy manifest — `App/PrivacyInfo.xcprivacy`

It sits at `App/`, not under `App/Resources/`: Apple looks for it at the bundle root, and anything
inside `Resources/` is copied as a nested folder. `App/project.yml` therefore lists it on its own
with `buildPhase: resources` instead of letting the folder glob pick it up. The file itself is the
source of truth — read it rather than a copy pasted here — and it declares:

- **One required-reason API.** `NSPrivacyAccessedAPICategoryUserDefaults` → **CA92.1**: the app
  reads and writes its own defaults (`boxBaseURL`, the model names, `initialTab`, cloud-import
  state, and the one-time removal of the legacy `boxApiKey`) and nothing shared, in this app's
  domain only. `NSPrivacyAccessedAPICategoryFileTimestamp` used to be here for the "KEEP OFFLINE" size
  label's `FileManager.attributesOfItem` call; that call died with blocker #7 and the entry went
  with it. Each entry is a claim, so do not add one back "just in case".
- **Two collected data types**, both linked and both App Functionality: `…TypeUserID` and
  `…TypeOtherUserContent`. The nutrition label in §1 declares a third, Other Data, for the server's
  30-day access logs — that is deliberate and not a mismatch to "fix": the manifest covers what the
  app itself sends, the label covers what the service holds.

Confirm it actually shipped rather than assuming: `unzip -l Stash.ipa | grep xcprivacy`.

---

## 4. Age rating

Apple's questionnaire wording shifts between releases; these are answers by topic, so map them onto
whatever the form asks on the day.

**Target rating: 16+** (or 17+ if the account is still on the older 4+/9+/12+/17+ scheme). This is
deliberately conservative and it must not contradict the privacy policy, which sets a minimum age
of 16.

| Topic | Answer | Why |
|---|---|---|
| Cartoon or Fantasy Violence | None | — |
| Realistic Violence / Prolonged Graphic Violence | None | — |
| Sexual Content or Nudity | Infrequent/Mild | The library is whatever the user saved on TikTok. We cannot promise none. |
| Profanity or Crude Humor | Infrequent/Mild | Same reason. |
| Alcohol, Tobacco, or Drug Use or References | Infrequent/Mild | Same reason. |
| Mature/Suggestive Themes | Infrequent/Mild | Same reason. |
| Horror/Fear Themes | None | — |
| Medical/Treatment Information | None | Summaries are not advice and are not presented as such. |
| Gambling / Contests | None | No gambling, no contests, no loot boxes. |
| Unrestricted Web Access | **No** | The only web view loads TikTok's embedded player for a specific video ID. No address bar, no arbitrary navigation. Say this in the review notes. |
| User-Generated Content displayed in the app | **Yes** | Third-party TikTok videos and captions, shown only inside the saving user's private library. |
| Users can communicate with each other | No | No messaging, no comments, no sharing between users. |
| In-app purchases / ads | No | Free, no IAP, no ads. |

Because UGC is displayed, be ready for Guideline 1.2 (UGC moderation) questions. The honest answer:
content is never user-to-user and never public — each user sees only videos they themselves saved on
TikTok, which TikTok already moderates. There is nothing to report or block because there is no other
user to be exposed to.

---

## 5. Export compliance

- `ITSAppUsesNonExemptEncryption` is already `false` in the `info` block of `App/project.yml` —
  that suppresses the per-build question in App Store Connect. Set it there, not in
  `App/Info.plist`: that file is generated by XcodeGen on every run and is not in git.
- It is the correct answer: the app uses only standard HTTPS/TLS provided by the OS and implements
  no proprietary or non-exempt cryptography.
- Consequence: no CCATS, no ERN, no annual self-classification report, no French declaration.
- If custom encryption of the local library is ever added, this flips and the answer must change.
- `NSAllowsLocalNetworking` is set for the local model shim. Unencrypted local HTTP does not affect
  export compliance, but expect it to be noticed — see the review notes.

---

## 6. App Review Information — the demo-account problem

Sign in with Apple only, plus an invite gate, plus an empty library on a fresh account. A reviewer
hits three walls in a row. Two are answered in App Store Connect; the third is answered by one flag
on the invite code — and only if you remember to pass it.

**Wall 1 — no username/password to give them.** Reviewers sign in with their own Apple ID. Tick
"Sign-in required" and put `N/A — Sign in with Apple` in both credential fields, then explain in the
notes.

**Wall 2 — the invite gate.** Issue a dedicated reviewer code that is not tied to a person and
outlives the review. Mint it on the box — there is no admin endpoint, deliberately:

```
sudo bash -c 'set -a; . /etc/stash-webhook/env; set +a; \
  /opt/stash-webhook/venv/bin/python /opt/stash-webhook/manage_invites.py mint \
    --uses 50 --expires-days 120 --label "app review" --demo'
```

`--demo` is not optional here — it is what makes wall 3 below go away. Without it the account
App Review creates comes back `"demo": false`, the app seeds nothing, and the reviewer lands in
the empty library this whole section exists to prevent. `manage_invites.py list` prints `demo`
next to the code, so check it there before pasting the code into the notes.

Every code carries an `expiresAt` by construction (`manage_invites.py`), so "never expires" is not
on offer; pick a horizon that survives a rejection and a resubmission. `--uses` is a hard cap on
redemptions, not a switch — set it well above the number of reviewers.

- Reviewer invite code: `STASH-JJGG-7HW9`
- Keep it live for as long as the version is in review, then `manage_invites.py revoke <CODE>`,
  which expires it in place so `list` still shows it was used.

**Wall 3 — an empty app.** The reviewer has no TikTok data export, so the demo library rides on the
invite. A `--demo` code stamps `demo: true` on the account it creates; `/v1/auth/apple` and `/v1/me`
echo that; `StashSession.isDemoAccount` carries it in the Keychain blob, and `RootView` calls
`SampleData.seedDemoLibrary` once per user id — ~21 already-analysed videos covering recipes, tracks,
how-tos, six more segments and one deliberately unavailable row, enough for Library, Cook, Music,
Today, Search and the mind map to each have real content.

The seeding is client-side, and deliberately: the library is local SwiftData, so a server-side seed
would mean inventing a discovery path for imports the client never created. The ceiling is that the
content is obviously invented — made-up handles, no thumbnails, and video ids that do not resolve on
TikTok. The notes below say so rather than let a reviewer find out by tapping OPEN IN TIKTOK. For the
same reason the per-video "Re-run pipeline" control is hidden on a demo account: re-running an
invented id enriches to nothing, which flags the row `unavailable` and removes it from every shelf.

Also attach a sample TikTok export file so the import flow itself can be exercised:
`[[SAMPLE_EXPORT_URL]]` — a link in the notes, from your own TikTok account.

### PASTE — App Review Notes

```
HOW TO GET IN
1. Tap "Sign in with Apple" and use your own Apple ID. Stash requests NO name and NO email
   from Apple — we only receive the app-specific user identifier.
2. Stash is an invitation-only beta. When asked for an invite code, enter:
       STASH-JJGG-7HW9
   This code stays valid for as long as this version is in review.
3. Redeeming that code seeds your account with a demo library of about 20 already-processed
   videos, so you can browse, search and open detail views straight away. No TikTok account
   is needed to review the app. That demo content is sample data we wrote, not real saves:
   the creator handles are invented and the video links do not open on TikTok. Everything
   else in the app behaves exactly as it does with a real library.

TO TEST THE IMPORT FLOW (optional)
Download this sample TikTok data export from our own TikTok account:
    [[SAMPLE_EXPORT_URL]]
Save it to Files, then in Stash: Import -> "Submit TikTok export" -> pick the file. The card
directly above that button names Groq and AWS Bedrock and what each one receives.

WHY AN INVITE CODE
Every imported video costs us real money in transcription and analysis, and the whole service
runs on one small server. The invite gate plus a per-account quota (500 videos initially, then
100 per calendar month, counter visible in-app) is how we keep the beta solvent. It is not a
paywall — Stash is free, there are no in-app purchases, and no payment is ever requested.

WHERE DATA GOES (Guideline 5.1.2(i))
The sign-in screen names both providers, in plain words, before an account exists and therefore
before anything leaves the device: captions and transcripts are analysed on AWS Bedrock in
eu-central-1, and audio extracted from a saved video is transcribed by Groq. The same screen
says "By continuing you agree to the Terms and Privacy Policy", with both linked and tappable;
signing in with Apple is the act of accepting, which is what the terms at
https://stash.dmitrijs.dev/terms describe. Both providers are named again in the privacy policy
at https://stash.dmitrijs.dev/privacy along with the transfer basis.

ACCOUNT DELETION (Guideline 5.1.1(v))
Exact path: Library tab (bottom bar) -> gear button, top right of the Library header ->
"Delete account". It deletes the account and all server-side data, and revokes the Sign in
with Apple grant so Stash disappears from the Apple ID settings list. The same screen has
"Export my data", which returns the full library as JSON, and "Legal", which links the
privacy policy and terms for a signed-in user, who has no way back to the sign-in screen.

MEDIA PLAYBACK (Guideline 5.2.3)
Stash does not download, save or convert TikTok videos for the user. Playback uses TikTok's
official embedded player in a web view restricted to a single video ID — there is no address
bar and no arbitrary browsing. To transcribe, the server fetches a video briefly, extracts the
audio and deletes the file immediately afterwards. To read the text burned into the frames, that
same transient copy is streamed to the device, sampled and read with Apple's on-device Vision
OCR, and discarded — nothing is written to a permanent location on either side.

LOCAL NETWORKING
NSAllowsLocalNetworking is enabled for an optional developer-only local model endpoint. The
shipping configuration talks to our HTTPS server; no user data is sent over plaintext HTTP.

BACKGROUND PROCESSING
UIBackgroundModes "processing" is used with BGTaskScheduler so a large first import can
continue while the app is backgrounded. It does no work when there is no import in progress.

Contact: support@stash.dmitrijs.dev
```

---

## 7. TestFlight

External testing needs a beta description, a feedback email, the privacy policy URL, and Beta App
Review. Reuse the App Review Notes above verbatim in the beta review information — the same three
walls exist.

### PASTE — Beta App Description

```
Stash turns the TikTok videos you saved into a searchable library. Recipes become recipe cards,
music becomes a track list, how-to videos become summaries with the links you need. You bring your
own TikTok data export; Stash reads only your Favourites and ignores everything else in the file.

This is an early beta on a small server. Imports are capped (500 videos to start, then 100 a month)
and things will break. Tell us when they do.
```

### PASTE — What to Test

```
WHAT'S NEW IN THIS BUILD
- Accounts: Sign in with Apple, invite codes, and a visible import quota.
- Export my data and Delete account in Settings.

PLEASE TRY
1. Sign in with Apple and redeem your invite code. Tell us if any screen in that flow is
   confusing or if the code is rejected.
2. Import your TikTok data export. Watch the progress counter — does it match how many videos
   you actually saved? Leave the app mid-import and come back; it should resume, not restart.
3. Browse the library. Are the categories right? Recipes should look like recipe cards, music
   should land in the track list. Wrong categories are the single most useful thing to report.
4. Open a few videos. Check the summary against the actual video: is it accurate, or confidently
   wrong? Send us the ones that are confidently wrong.
5. Search for something you know is in there. Does it come back?
6. Check your quota counter in Settings — Library tab, gear button top right. Does the
   number match what you imported?
7. Settings -> Export my data. Open the file. Is anything missing?
8. Only if you are done testing: Settings -> Delete account. It is permanent and there is no
   undo. Tell us if anything survives that should not have.

KNOWN LIMITS
- Continuous sync with TikTok is not live yet; imports are from a data export file you download
  from TikTok yourself.
- Summaries come from a language model and are sometimes wrong. Do not cook from a recipe card
  without checking the video.
- Videos that were deleted or made private on TikTok show as unavailable.

Feedback: shake the device or use the TestFlight feedback button, or email support@stash.dmitrijs.dev.
```

---

## 8. App Store listing copy

### Name (30 char max)
```
Stash
```

### Subtitle (30 char max)
**PASTE:**
```
Your saved videos, organized
```
28 characters. Alternatives if you want the search term in it: `Your saved TikToks, organized`
(29). See the trademark note below before using it.

### Promotional text (170 char max, editable without a new build)
```
Invitation-only beta. Bring your TikTok data export and Stash turns everything you saved into a searchable library of recipe cards, tracks and how-to summaries.
```

### Keywords (100 char max, comma-separated, no spaces, do not repeat the app name or subtitle)
**PASTE:**
```
tiktok,favourites,favorites,saved,bookmarks,library,recipes,transcript,summary,organize,videos
```
94 characters.

**Trademark note.** Apple sometimes rejects third-party brand names in metadata under Guideline 5.2.1
even when the usage is descriptive. Stash's use is descriptive and disclaimed in the terms, which is
the defensible position. Keep this fallback ready in case a reviewer objects, and drop "TikToks" from
the subtitle at the same time:
```
saved,bookmarks,favourites,favorites,library,recipes,transcript,summary,organize,videos,notes
```

### Description
```
You save videos. Dozens of them. Recipes you meant to cook, songs you meant to look up, a
three-minute explanation of something you needed once and will need again. Then they sit in a
grid of thumbnails you will never scroll back through.

Stash fixes that.

Give Stash your TikTok data export and it reads the videos you saved to your Favourites —
and only those. Then it does the work you were never going to do: it listens to each video,
reads the text on screen, and turns the pile into something you can actually search.

WHAT YOU GET

Recipe cards. Cooking videos come out as clean recipe cards with the ingredients and the steps
written down, so you are not scrubbing a video back and forth with wet hands.

A track list. Every song you saved, collected in one place. That one you liked in March is
findable again.

How-to summaries. Coding and tutorial videos become short summaries with the links you need to
follow along.

Topics. Everything else gets grouped by what it is, so the library stays skimmable instead of
becoming another endless feed.

Search that works. Search across captions, summaries, transcripts and the text shown on screen
— not just titles. If someone said it out loud in a video you saved, you can find it.

HOW IT WORKS

You download your data export from TikTok yourself and hand the file to Stash. Stash reads the
Favourite Videos entries out of it and ignores every other category — messages, watch history,
profile and the rest are never sent anywhere and never stored. Analysis runs on our servers in
the EU; the privacy policy names every provider involved and exactly what each one receives.

Export your whole library as JSON whenever you want. Delete your account from Settings and
everything on our servers goes with it.

BEFORE YOU DOWNLOAD

Stash is a free, invitation-only beta running on a small server. You need an invite code, and
each account has an import budget: 500 videos to start, then 100 per calendar month, with the
counter visible in the app.

Summaries and categories are generated by a language model. They are usually right and
occasionally confidently wrong. Check the video before you cook from a recipe card.

Stash is an independent app. It is not affiliated with, endorsed by, or sponsored by TikTok or
ByteDance.
```

### URLs
- Support URL: `https://stash.dmitrijs.dev` — **must** have a visible way to contact support on it.
- Marketing URL: `https://stash.dmitrijs.dev`
- Privacy Policy URL: `https://stash.dmitrijs.dev/privacy`
- Copyright: `2026 Dmitrijs Sabelniks`
- Category: Primary **Productivity**, Secondary **Utilities**. Matches the TikTok developer portal
  entry, which also says Productivity.
- Price: Free. No in-app purchases.
- Availability: `[[decide]]` — the privacy policy and terms are written for EU/EEA users under Dutch
  law. Shipping worldwide on day one means answering questions from jurisdictions the documents do
  not address. Starting EEA + UK is the smaller promise.

---

## 9. Assets

| Asset | Requirement | Status |
|---|---|---|
| App icon | 1024x1024, no alpha, no rounded corners | `App/branding/stash-logo-needle-branch-1024.png` — the needle-branch logo submitted to TikTok. Use the same one. |
| iPhone 6.9" screenshots | 3–10, 1290x2796 or 1320x2868 | `[[capture]]` — library grid, a recipe card detail, search results, the quota counter in Settings. |
| iPhone 6.5" screenshots | Required if 6.9" alone is not accepted for your device set | `[[capture]]` |
| App preview video | Optional | `docs/api-application/stash-demo.mp4` exists but is a 17-second TikTok-application demo; re-cut before using. |

Screenshots must show the app as submitted, so capture from a Release build: `ConnectFlowView`
still compiles under `#if DEBUG`, and a Debug screenshot showing it is a metadata rejection for a
feature the shipped binary does not have.

---

## 10. Submit sequence

1. Close out the row still open in §0 — the legal placeholders. Nothing below matters until that
   is true.
2. Fill the `[[TOKEN]]` placeholders in `privacy.html` and `terms.html`, deploy the site, and open
   both URLs in a browser to confirm no `[[` survives.
3. Create the reviewer invite code **with `--demo`** and verify end-to-end on a clean device: fresh
   install → Sign in with Apple → redeem code → demo library appears → Library → gear →
   Delete account works.
4. Bump `CURRENT_PROJECT_VERSION` in `App/project.yml`, archive, upload.
5. Confirm the privacy manifest shipped in the build.
6. Answer App Privacy (§1) and the age rating (§4).
7. Paste the review notes (§6) and the TestFlight copy (§7).
8. Submit for Beta App Review. Ship to external testers.
9. Keep the reviewer code alive until the version clears review, then revoke it.

## 11. Loose ends this checklist cannot close

- `services/webhook/site/index.html` still claims "Your library lives with you" and its step 1 is
  "Connect TikTok — sign in once with TikTok", a Login flow that is not live. Both contradict the
  rewritten privacy policy, which says only the data-export route works, and a reviewer who reads
  the policy will land on the home page next.
- `index.html` gives `dmitryschab@gmail.com` as the contact, while `terms.html` and `privacy.html`
  promise a `support@stash.dmitrijs.dev` on the `stash.dmitrijs.dev` domain. The support URL and the legal
  pages have to name the same mailbox.
- Groq's data-residency and EU-U.S. Data Privacy Framework status were not verifiable from this
  repository. `privacy.html` carries an HTML comment marking exactly what to check and what wording
  to switch to. Verify before publishing, not after.
