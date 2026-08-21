# Stash — App Store submission checklist

Everything App Store Connect will ask for, answered. Copy the blocks marked **PASTE** straight into
the matching field. Fields in `[[ ]]` need a real value from you before submitting.

Target: **a paid App Store release at €5, first release, no TestFlight beta phase.** That order was
inverted on 2026-08-16 and the reasoning is in
[`docs/api-application/resubmission-2026-08-15.md`](api-application/resubmission-2026-08-15.md):
TikTok rejected the Data Portability application as "personal or company internal use", their
guidelines separately refuse anything "still in development or testing", and a live paid listing is
the single artifact that answers both. So 1.0 sells the TikTok-export import and the share extension
— the two things that work with no TikTok API approval at all — and the OAuth sync ships later as a
free upgrade to people who already bought.

**Two words must not appear anywhere a TikTok reviewer can read them: *beta* and *free*.** That
includes the App Store description, the promotional text, the subtitle and the support site. Apple
does not care; TikTok reads the listing as evidence and both words are disqualifying in their
vocabulary.

Current build: bundle ID `dev.dmitryschab.Stash`, team `S76KJ8Y6C3`, deployment target iOS 17.0,
iPhone only, marketing version 1.0, build 16 (`App/project.yml`). Ships with a share extension
(`App/ShareExtension/`) — a second target, so the provisioning profile set is two, not one.

---

## 0. Blockers

Submitting before these are true means a rejection, not a question.

| # | Blocker | Status | Why | Where |
|---|---|---|---|---|
| 1 | `PrivacyInfo.xcprivacy` in the app target | **Done** | Required since May 2024; upload is rejected without it when required-reason APIs are used. Content in §3. | `App/PrivacyInfo.xcprivacy` — bundle root, not `Resources/` |
| 2 | `com.apple.developer.applesignin` entitlement | **Done in the project** | Sign in with Apple does not work without it. The provisioning profile still has to carry the capability. | `App/Stash.entitlements`, `App/project.yml` |
| 3 | In-app **Delete account** that also revokes the Apple grant | **Done** | Guideline 5.1.1(v). Revocation needs a `refresh_token`, so `SignInView` sends Apple's one-time `authorizationCode` at sign-in and `DELETE /v1/me` revokes with it — and `deploy.sh` refuses to deploy without `APPLE_TEAM_ID`/`APPLE_KEY_ID`/`APPLE_PRIVATE_KEY`, because a box missing them signs users in it can never revoke. | `stash_auth.py`, `deploy.sh`, Library → gear → Delete account |
| 4 | In-app **Export my data** | **Done** | Promised in the privacy policy. `GET /v1/me/export` streams the server side, the app appends the on-device library. | `stash_auth.py`, Library → gear → Export my data |
| 5 | Third-party AI named before anything leaves the device | **Done** | Guideline 5.1.2(i). The sign-in screen names Groq and AWS Bedrock and carries "By continuing you agree to the Terms and Privacy Policy" with both linked; the Import screen repeats the split above the submit button. Consent is by continuation — there is no checkbox anywhere, and `terms.html` says so. | `App/Sources/SignInView.swift`, `ImportView.swift` |
| 6 | No reachable non-functional prototype | **Done** | Guideline 2.2. `ConnectFlowView` (hardcoded "1,868 favourites imported") is behind `#if DEBUG`, so no release build can reach it. | `App/Sources/ImportView.swift` |
| 7 | No persistent offline video copies | **Done** | Guideline 5.2.3. "KEEP OFFLINE" and the local-file playback path are gone; only the transient fetch for transcription and OCR remains. | `App/Sources/WatchSection.swift` |
| 8 | Legal pages carry real entity details and are **deployed** | **Done 2026-08-16** | Reviewers open both URLs. `/privacy`, `/terms` and `/support` return 200 with the Dutch eenmanszaak, KvK 70958416 and BTW NL002463368B81 on them, dated 16 August 2026. No `[[TOKEN]]` survives in `services/webhook/site/`. | `services/webhook/site/` |
| 9 | A reviewer can get in **and** see something | **Done** | Sign-up is open (the price is the gate), so there is no wall — but a fresh account is an empty app. The demo library still rides on a `--demo` code, now entered behind the sign-in screen's "Have a code?" button. §6. | `manage_invites.py`, `SignInView.swift`, `SampleData.swift` |
| 10 | **Paid Applications agreement Active** | **Open — owner only** | No signed agreement, no price tier, no paid app. Account Holder signs it, then tax forms, then banking (the IBAN is typed by the owner in App Store Connect and belongs nowhere in this repo), then ~24h to activate. | App Store Connect → Business |
| 11 | **DSA trader declaration** | **Open — owner only** | Apple blocks EU distribution without it. It will display Latvia, because the App Store account is `Individual · Riga · Latvia` and the country cannot be self-service changed; the legal pages say Netherlands. That inconsistency resolves on the app transfer to a Dutch account, which requires a released version to be possible at all. | App Store Connect → App Information |
| 12 | Screenshots from a **Release** build | **Open** | §9. `ConnectFlowView` still compiles under `#if DEBUG`; a Debug screenshot showing it is a metadata rejection for a feature the shipped binary does not have. | — |

---

## 1. App Privacy — nutrition label answers

App Store Connect → App Privacy. Answer per data type. "Linked to you" means associated with the
user's identity; every Stash record is keyed to the Apple user identifier, so anything collected is
linked. **Nothing is used for tracking**, and there is no advertising SDK, no analytics SDK and no
data broker in the picture.

### Collected — declare these

| Data type | Collected | Linked to identity | Tracking | Purposes | What it actually is |
|---|---|---|---|---|---|
| Identifiers → **User ID** | Yes | Yes | No | App Functionality | The Apple app-specific user identifier and the quota counters keyed to it. |
| User Content → **Other User Content** | Yes | Yes | No | App Functionality | The saved-video list (video ID, link, save date, creator handle, caption, hashtags, thumbnail URL, duration) and everything derived from it: category, title, summary, topics, recipe/track/code cards, the transcript, and the on-screen text. |
| **Other Data** | Yes | Yes | No | App Functionality | Server access logs (timestamp, path, status, IP) kept 30 days for uptime and abuse prevention. |

### Not collected — and be able to say why

| Data type | Answer | Reason |
|---|---|---|
| Contact Info → Name | No | Stash requests no name from Apple. |
| Contact Info → Email Address | No | Stash requests no email from Apple. Not even a private-relay address. |
| Contact Info → Phone, Address, Other | No | Never asked for. |
| Health & Fitness, Financial Info, Location, Sensitive Info, Contacts | No | Never touched. No location API, no contacts API, no payments in-app. |
| User Content → **Audio Data** | No | The audio track is extracted from a saved video, sent to Groq, transcribed, and deleted — processed to service the request and not retained. That is Apple's "not collected" case. The *transcript* is retained and is declared under Other User Content. |
| User Content → **Photos or Videos** | No | Same shape: the server streams a saved video to the device, Vision reads the on-screen text from sampled frames locally, and both copies are deleted. No offline video copies are kept anywhere. |
| User Content → Emails or Text Messages, Gameplay Content, Customer Support | No | — |
| Browsing History | No | — |
| Search History | No | In-app search runs against the local library and is not stored or sent anywhere. |
| **Purchases** | No | The app is paid up front. Apple takes the money and Stash never sees a transaction, a receipt or a payment method — there is no StoreKit code in the binary at all. |
| Usage Data → Product Interaction / Advertising Data / Other | No | No analytics SDK. |
| Diagnostics → Crash / Performance / Other | No | No crash-reporting SDK. App Store crash reports are collected by Apple, not by us, and are not declared here. |
| Identifiers → Device ID | No | No IDFA, no IDFV collection, no ATT prompt. |

**"Does your app use data for tracking?" → No.** Nothing is linked with third-party data for
advertising, and no data goes to a data broker. Therefore no App Tracking Transparency prompt.

**If you add an analytics or crash SDK later, this label is wrong the day you add it.** The label is
per-version and must be re-answered.

---

## 2. Privacy policy URL and account-deletion URL

- Privacy Policy URL: `https://stash.dmitrijs.dev/privacy`
- Account deletion: App Store Connect asks how an account is deleted. Answer that deletion is
  **inside the app** (Library tab → gear → Delete account). Only supply a URL if there is a web path
  too; there is not, and an in-app path is what the guideline wants.

---

## 3. Privacy manifest — `App/PrivacyInfo.xcprivacy`

It sits at `App/`, not under `App/Resources/`: Apple looks for it at the bundle root, and anything
inside `Resources/` is copied as a nested folder. `App/project.yml` therefore lists it on its own
with `buildPhase: resources` instead of letting the folder glob pick it up. The file itself is the
source of truth — read it rather than a copy pasted here — and it declares:

- **One required-reason API.** `NSPrivacyAccessedAPICategoryUserDefaults` → **CA92.1**: the app
  reads and writes its own defaults (`boxBaseURL`, the model names, `initialTab`, cloud-import
  state, and the one-time removal of the legacy `boxApiKey`) and nothing shared, in this app's
  domain only. `NSPrivacyAccessedAPICategoryFileTimestamp` used to be here for the "KEEP OFFLINE"
  size label's `FileManager.attributesOfItem` call; that call died with blocker #7 and the entry
  went with it. Each entry is a claim, so do not add one back "just in case".
- **Two collected data types**, both linked and both App Functionality: `…TypeUserID` and
  `…TypeOtherUserContent`. The nutrition label in §1 declares a third, Other Data, for the server's
  30-day access logs — that is deliberate and not a mismatch to "fix": the manifest covers what the
  app itself sends, the label covers what the service holds.

The share extension is a separate bundle. It writes the shared link into the app-group container and
does no networking and no `UserDefaults` access of its own, so it needs no manifest of its own —
verify that stays true if it ever grows.

Confirm the manifest actually shipped rather than assuming: `unzip -l Stash.ipa | grep xcprivacy`.

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
| In-app purchases / ads | No | Paid up front, no IAP, no ads. |

Because UGC is displayed, be ready for Guideline 1.2 (UGC moderation) questions. The honest answer:
content is never user-to-user and never public — each user sees only videos they themselves saved on
TikTok, which TikTok already moderates. There is nothing to report or block because there is no other
user to be exposed to.

---

## 5. Export compliance

- `ITSAppUsesNonExemptEncryption` is already `false` in the `info` block of `App/project.yml` —
  that suppresses the per-build question in App Store Connect. Set it there, not in
  `App/Info.plist`: that file is generated by XcodeGen on every run and is not in git. It is on the
  app target only (`project.yml:50`); the share extension's `info` block does not carry it and does
  not need to, because the question is answered from the containing app's bundle.
- It is the correct answer: the app uses only standard HTTPS/TLS provided by the OS and implements
  no proprietary or non-exempt cryptography.
- Consequence: no CCATS, no ERN, no annual self-classification report, no French declaration.
- If custom encryption of the local library is ever added, this flips and the answer must change.
- `NSAllowsLocalNetworking` is set for the local model shim. Unencrypted local HTTP does not affect
  export compliance, but expect it to be noticed — see the review notes.

---

## 6. App Review Information

Two walls, down from three. The invite gate is gone (sign-up is open — the price is the gate), so
what is left is Sign in with Apple having no credentials to hand over, and a fresh account being an
empty app.

**Wall 1 — no username/password to give them.** Reviewers sign in with their own Apple ID. Tick
"Sign-in required" and put `N/A — Sign in with Apple` in both credential fields, then explain in the
notes.

**Wall 2 — an empty app.** The reviewer has no TikTok data export, so the demo library rides on a
code. A `--demo` code stamps `demo: true` on the account it creates; `/v1/auth/apple` and `/v1/me`
echo that; `StashSession.isDemoAccount` carries it in the Keychain blob, and `RootView` calls
`SampleData.seedDemoLibrary` once per user id — ~21 already-analysed videos covering recipes, tracks,
how-tos, six more segments and one deliberately unavailable row, enough for Library, Cook, Music,
Today, Search and the mind map to each have real content.

Since sign-up is open, **the code field is hidden behind a "Have a code?" button** on the sign-in
screen. A reviewer who does not tap it signs in successfully and lands in an empty library, so the
notes below name the button explicitly. Mint the code on the box — there is no admin endpoint,
deliberately:

```
sudo bash -c 'set -a; . /etc/stash-webhook/env; set +a; \
  /opt/stash-webhook/venv/bin/python /opt/stash-webhook/manage_invites.py mint \
    --uses 50 --expires-days 120 --label "app review" --demo'
```

`--demo` is not optional — without it the account comes back `"demo": false`, the app seeds nothing,
and the reviewer lands in the empty library this section exists to prevent. `manage_invites.py list`
prints `demo` next to the code, so check it there before pasting the code into the notes. Every code
carries an `expiresAt` by construction, so "never expires" is not on offer; pick a horizon that
survives a rejection and a resubmission.

- Reviewer code: **`STASH-W73N-E7HX`** — minted 2026-08-21 against the deployed open-sign-up build,
  50 uses, expires 2026-12-19, and `manage_invites.py list` shows it as `demo`. The older
  `STASH-JJGG-7HW9` predates the change and should be revoked once this version is through review.
- Keep it live until the version clears review, then `manage_invites.py revoke <CODE>`, which
  expires it in place so `list` still shows it was used.

The seeding is client-side, deliberately: the library is local SwiftData, so a server-side seed would
mean inventing a discovery path for imports the client never created. The ceiling is that the content
is obviously invented — made-up handles, no thumbnails, and video ids that do not resolve on TikTok.
The notes say so rather than let a reviewer find out by tapping OPEN IN TIKTOK. For the same reason
the per-video "Re-run pipeline" control is hidden on a demo account.

Also attach a sample TikTok export file so the import flow can be exercised:
`[[SAMPLE_EXPORT_URL]]` — a link in the notes, from your own TikTok account.

### PASTE — App Review Notes

```
HOW TO GET IN
1. Tap "Sign in with Apple" and use your own Apple ID. Stash requests NO name and NO email
   from Apple — we only receive the app-specific user identifier. Anyone who buys the app can
   sign in; there is no invitation, no waitlist and no approval step.
2. IMPORTANT, so you do not land in an empty app: on the sign-in screen, tap "Have a code?"
   below the button and enter
       STASH-W73N-E7HX
   before signing in. That code seeds your account with a demo library of about 20 already-
   processed videos, so you can browse, search and open detail views straight away without a
   TikTok account. It is a reviewer convenience, not a gate: signing in without it works and
   gives you a normal, empty library.
3. The demo content is sample data we wrote, not real saves: the creator handles are invented
   and the video links do not open on TikTok. Everything else behaves exactly as it does with
   a real library.

THE TWO WAYS CONTENT GETS IN
a) Share extension. In TikTok, share any video -> Stash. The link lands in Stash and is
   analysed on next launch. This is the everyday path and needs nothing set up.
b) TikTok data export. Download this sample export from our own TikTok account:
       [[SAMPLE_EXPORT_URL]]
   Save it to Files, then in Stash: Import -> "Submit TikTok export" -> pick the file. The
   card directly above that button names Groq and AWS Bedrock and what each one receives.

WHY THERE IS A LIMIT
Every video costs real money in transcription and analysis and the service runs on one small
server, so each account has a budget: 500 videos to start, then 100 per calendar month, with
the counter visible in Settings. It is not a subscription and not an in-app purchase — the
app is paid once, up front, and no further payment is ever requested.

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

Not a release phase any more — 1.0 goes straight to the App Store. TestFlight is still where the
uploaded build lands, so use **internal testing only** (up to 100 of your own devices, no Beta App
Review) to check the build on hardware before you submit it for App Review. Do not open external
testing: an external TestFlight link is a "testing version" in TikTok's vocabulary, which is a
documented refusal reason for the Data Portability application.

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
28 characters. Alternative with the search term in it: `Your saved TikToks, organized` (29). See the
trademark note below before using it.

### Promotional text (170 char max, editable without a new build)
**PASTE:**
```
Share a TikTok into Stash and get it back as a recipe card, a track, or a summary you can actually search. Bring your whole export and do it for everything you saved.
```
165 characters.

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

TWO WAYS IN

Share one. In TikTok, tap Share and pick Stash. That video comes back as something you can
read: a recipe card, a track, a summary.

Bring all of them. Download your data export from TikTok and hand the file to Stash. It reads
the videos you saved to your Favourites — and only those — and works through the pile.

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

YOUR DATA

Stash reads the Favourite Videos entries out of your export and ignores every other category —
messages, watch history, profile and the rest are never sent anywhere and never stored.
Analysis runs on servers in the EU; the privacy policy names every provider involved and
exactly what each one receives.

Export your whole library as JSON whenever you want. Delete your account from Settings and
everything on our servers goes with it.

BEFORE YOU BUY

One purchase, no subscription, no in-app purchases. Because every video costs real money to
transcribe and analyse, each account has a budget: 500 videos to start, then 100 per calendar
month, with the counter visible in the app.

Summaries and categories are generated by a language model. They are usually right and
occasionally confidently wrong. Check the video before you cook from a recipe card.

Stash is an independent app. It is not affiliated with, endorsed by, or sponsored by TikTok or
ByteDance.
```

### URLs and settings
- Support URL: `https://stash.dmitrijs.dev/support` — live, and it names `support@stash.dmitrijs.dev`,
  the same mailbox the legal pages promise.
- Marketing URL: `https://stash.dmitrijs.dev`
- Privacy Policy URL: `https://stash.dmitrijs.dev/privacy`
- Copyright: `2026 Dmitrijs Sabelniks`
- Category: Primary **Productivity**, Secondary **Utilities**. Matches the TikTok developer portal
  entry, which also says Productivity.
- **Price: €5 tier, paid up front. No in-app purchases, so no StoreKit code** — a paid app is a price
  setting in App Store Connect and nothing in the binary. Requires blocker #10.
- Availability: `[[decide]]` — the privacy policy and terms are written for EU/EEA users under Dutch
  law. Shipping worldwide on day one means answering questions from jurisdictions the documents do
  not address. EEA + UK is the smaller promise; note that TikTok's reviewer has to be able to buy or
  redeem it from wherever they are, so check that before narrowing.

---

## 9. Assets

| Asset | Requirement | Status |
|---|---|---|
| App icon | 1024x1024, no alpha, no rounded corners | `App/branding/stash-logo-needle-branch-1024.png` — the needle-branch logo submitted to TikTok. Use the same one. |
| iPhone 6.9" screenshots | 3–10, 1290x2796 or 1320x2868 | `[[capture]]` — library grid, a recipe card detail, the track list, search results, the quota counter in Settings. |
| iPhone 6.5" screenshots | Required if 6.9" alone is not accepted for your device set | `[[capture]]` |
| App preview video | Optional | `docs/api-application/stash-demo.mp4` exists but is a 17-second TikTok-application demo; re-cut before using. |

Screenshots must show the app as submitted, so capture from a **Release** build on a demo account
(see §6), because a real signed-in library is the only other way to get content on screen.

---

## 10. Submit sequence

1. **Owner:** sign Paid Applications, file the tax forms, enter banking. Nothing below can be
   completed until it reads Active — allow ~24h after the last field.
2. **Owner:** complete the DSA trader declaration (blocker #11).
3. Deploy the open-sign-up backend to the box, then mint a fresh `--demo` reviewer code and verify
   end-to-end on a clean device: fresh install → Sign in with Apple with no code → ordinary empty
   account → delete it → sign in again via "Have a code?" with the demo code → seeded library →
   Library → gear → Delete account works.
4. Capture Release-build screenshots (§9).
5. Bump `CURRENT_PROJECT_VERSION` in `App/project.yml`, archive, upload. Both targets sign.
6. Confirm the privacy manifest shipped in the build.
7. Answer App Privacy (§1) and the age rating (§4). Set the €5 price tier and availability.
8. Paste the review notes (§6) and the listing copy (§8).
9. Submit for App Review.
10. Keep the reviewer code alive until the version clears review, then revoke it.
11. Once live, the App Store URL is what unblocks the TikTok resubmission — go back to
    `docs/api-application/resubmission-2026-08-15.md` step 5 onward, and generate promo codes for the
    TikTok reviewers (100 per version, 4 weeks, single use).

## 11. Loose ends this checklist cannot close

- Groq's data-residency and EU-U.S. Data Privacy Framework status were not verifiable from this
  repository. `privacy.html` carries an HTML comment marking exactly what to check and what wording
  to switch to. Verify it is right rather than assuming — the page is already published.
- The DSA trader display will say Latvia while the legal pages say Netherlands, until the app is
  transferred to a Dutch developer account. That transfer needs a released version to exist, so it
  cannot be done first. Known and accepted; see the launch-decisions memory.
- Nothing on the public site or in the listing may call Stash a beta or call it free. Re-read the
  promotional text and the description against that rule every time either is edited.
