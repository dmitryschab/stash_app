# Stash — TikTok Data Portability API, resubmission

**Date:** 2026-08-15 · **App ID:** `7660891902371416072` · Supersedes the application submitted 2026-07-11.

The 2026-07-11 submission was **rejected**. This file is the resubmission: the diagnosis, the
paste-ready portal text, and the checklist that has to be green before pressing Submit.
`data-portability-application.md` is left as the historical record of what was submitted.

## Revision — 2026-09-01

Four corrections, all verified against live sources today. **Where this block conflicts with anything
below, this block wins** — the sections further down were written when 1.0 was still unshipped.

1. **The app is live and the pricing changed.** 1.2 is `READY_FOR_SALE` and visible in LV/NL/DE/US/GB
   (checked via `itunes.apple.com/lookup`), **free** with a Stash Pro subscription at EUR 2.99/month.
   Every "€5 upfront", "paid app" and "TestFlight join URL" below is superseded. The EU trader-status
   block that hid the listing in EU storefronts on 28 Aug has cleared.
2. **The scope is `portability.activity.ongoing`, not `portability.all.ongoing`.** Favourites live
   under Activity — `docs/api-application/sample-tiktok-export.json` has them at
   `Activity > Favorite Videos > FavoriteVideoList`. The old claim that `all` was the narrowest scope
   reaching them was wrong, and asking for `all` weakens the application.
3. **No portability scope has ever been granted.** The Data Portability API *is* attached as a product
   alongside Login Kit and Webhooks, but every scope reads "Need to apply" and the app's only live
   scope is `user.info.basic`. So this is a *first* portability request, not a resubmission of one.
   The portal also states: **"The Data Portability API requires Login Kit approval in addition to this
   application… both approvals are needed before you can make data requests."** Two approvals, two
   tracks, and the Login Kit one is what needs the demo video.

   The portal grants ongoing access as a pair — the scope row is literally
   `portability.activity.single,portability.activity.ongoing`.

5. **Step 2 of the application requires a PDF of high-fidelity UX mocks** covering four named screens:
   TikTok Connection page, Connecting to TikTok, Confirmation of connection, Final output / result.
   PDF only, max 5MB. This does not exist yet and is the immediate blocker on submitting.
4. **The API covers EEA/UK TikTok users only.** Auto-sync will never work for buyers outside that
   region; they stay on manual export + the share extension. The App Store copy has to say so, and
   the application now commits us to distinguishing EEA/UK users at sign-in — **that gate is not
   built yet**.

---

## The rejection, verbatim

> App will not be approved for personal or company internal use.
> Please use sandbox feature for personal or internal use.
> TikTok for Developers currently does not support personal or internal company use.
> Not acceptable: Display posts from the TikTok account(s) you or your team manage on your website.

## Diagnosis

Not a technical finding. The reviewer classified Stash as a personal project, and every artifact
they could see supported that reading:

| Evidence the reviewer had | Where |
|---|---|
| "Stash is a single-user personal tool; there is no shared multi-tenant datastore" | submitted use-case text |
| "processed by a model service **the user controls**" | submitted data-handling text |
| "Personal library for your saved videos" — the page's own eyebrow headline | `https://stash.dmitrijs.dev` |
| `dmitryschab@gmail.com` as the sole contact, on all three public pages | landing, `/privacy`, `/terms` |
| No download link, no App Store listing, no signup, no waitlist — nothing a member of the public could act on | landing page |
| `/privacy` still reading "Controller: Dmitrijs Šabeļņiks (individual developer)", dated 10 July | live site (the 25 July rewrite was never deployed) |

The last row matters most: the rewritten legal pages exist in the repo but were never shipped, so
the reviewer read the *individual developer* version.

The architecture changed on 2026-07-25 — per-user accounts, invite codes, quotas, shared AWS
infrastructure, TestFlight distribution. The submitted text described the product as it was in
early July. Nothing needs to be invented to answer this rejection; it needs to be *stated*, and
the public surfaces need to stop contradicting it.

## The one thing to prove

**That a member of the public who is not Dmitrijs can get Stash and use it on their own TikTok
account.** Every item below exists to make that provable in the sixty seconds a reviewer spends.

## What TikTok actually requires (checked against the guidelines, 2026-08-16)

Two separate rules in the [App Review Guidelines](https://developers.tiktok.com/doc/app-review-guidelines/),
and the second one is a trap:

1. **"Apps must not be for private or personal use."** — the rule we were rejected under.
2. **"Apps that are still in development or testing will not be approved."** — this kills any
   "closed beta" or "TestFlight build" framing. Saying either is saying "testing version" in TikTok's
   own vocabulary, and the reply is another pointer to Sandbox.

**Never use the words beta, test, pilot or early access anywhere in the application, the demo video,
or the website.** Stash is available to the public. That is the only frame that survives both rules.

What is *not* required, per the documented criteria: a published App Store listing. What is required
instead, and what the website has to carry:

- **"You must have an externally facing fully developed website"**, and it must be "live and working
  as expected, and not a holding page or otherwise incomplete website".
- The app must be **functioning during the review process**.
- **Demo accounts must be provided to approvers free of charge** if requested.

That last point resolves the invite-code tension. The codes stay (locked decision, capacity control),
but a reviewer who downloads Stash and hits an invite wall sees a non-functioning app *and* a private
one — both rejection criteria at once. Ship a reviewer account plus a live invite code in the
submission notes.

### Sandbox is the demo environment, not a consolation prize

The reviewer's "please use sandbox" was dismissive, but sandbox is also the *mandatory* path here:

> If your app has not been approved before, you are required to use a sandbox environment on the
> Developer Portal to demonstrate the integration.

5 sandboxes per app, each shareable with up to 10 target TikTok accounts. This removes the
chicken-and-egg problem — the OAuth and archive flow can be exercised and recorded before the
production scope is ever granted.

### Two tracks, not one

| Track | Artifact it wants | Can be submitted when |
|---|---|---|
| **App Review** | demo video covering every requested product and scope | app in Staging |
| **Data Portability API application** | screenshots of UX mockups, four screens, end-to-end journey | app can still be in Draft |

Approval on the Data Portability track runs 3–4 weeks and is separate from App Review. Do not
conflate them; the previous submission's assets were built for one and judged against both.

---

## Paste-ready portal text

### Use case

> Stash is a consumer iOS application published on the App Store worldwide — Apple ID 6789977520,
> https://apps.apple.com/app/id6789977520 — first released 26 August 2026. It is free to download,
> with an optional subscription (Stash Pro, EUR 2.99 per month). It is not an internal business tool,
> not a personal project, and it does not display our own TikTok content anywhere.
>
> Each user signs in to Stash with their own Apple ID and connects their own TikTok account. Stash
> retrieves that user's Favourite Videos through the Data Portability API and turns them into a
> searchable personal library: cooking videos become structured recipe cards, music videos become a
> track list with the releases named in the video, how-to and coding videos become short summaries
> with the links needed to follow along, and everything else is grouped by topic. The user's only
> action is bookmarking a video inside TikTok, exactly as they already do.
>
> A user's TikTok data is visible only to that user. It is never shown to another user, never
> aggregated across users, never published, and never used to display any account's posts on a
> website or to any third party. There is no shared feed and no public surface for TikTok content.
>
> Stash is sold worldwide. The Data Portability integration will be offered only to users we identify
> as being in the EEA or the UK from their App Store storefront at sign-in; everyone else imports
> their data manually from TikTok's own export.
>
> This serves the portability purpose of the DMA directly: continuous access to, and useful control
> over, data a user generated on TikTok, in a form TikTok's own app does not provide.

### Scope justification — `portability.activity.ongoing`

> Favourite Videos are delivered inside the **Activity** category of the export — in the archive they
> appear at `Activity > Favorite Videos > FavoriteVideoList`, each entry a date and a video link.
> Activity is therefore the narrowest scope that reaches them, and we do not request
> `portability.all.*`. Within the Activity export we read only the Favorite Videos entries and
> discard every other category in memory before anything is written to storage.
>
> `ongoing` keeps each user's library in sync with their new saves without forcing them to
> re-authorise. Each request returns the full Activity dataset rather than a delta, so we diff it
> against what the user already holds and create nothing twice.

### App-review explanation (portal caps this at 1000 characters)

> Stash is a consumer iOS app on the App Store worldwide (Apple ID 6789977520), released 26 Aug 2026.
> Free download, optional Stash Pro subscription, EUR 2.99/month. It is not for internal or personal use.
>
> Each user connects their own TikTok account and sees only their own Favourites, turned into a
> searchable library of recipe cards, track lists and how-to summaries. No user sees another user's
> data. We display no TikTok content publicly, and none of our own posts anywhere.
>
> We request only portability.activity.ongoing. From the Activity export we read only the Favorite
> Videos entries; every other category is discarded in memory before any write, and the archive
> deleted immediately after extraction. Offered only to users we identify as EEA/UK.
>
> Sub-processors: AWS (hosting eu-north-1, Bedrock summarisation eu-central-1) and Groq (US,
> speech-to-text on audio only), both named in our privacy policy.
>
> Users can export their library and delete their account and all data in-app.

987 characters, verified against the portal's 1000-character cap.

### App description (portal caps this at 120 characters)

> Stash organizes the TikTok videos you save into a searchable library of recipes, music, and how-to summaries.

109 characters. Unchanged — it was never the problem.

---

## Public-availability evidence to build before resubmitting

The reviewer must land on a page that reads as a shipping consumer product.

1. **A public "Get Stash" CTA above the fold**, linking to the public TestFlight join URL. Without a
   link anyone can click, the personal-project reading survives every wording change.
2. **Delete the word "personal" as a description of the product.** "Personal library for your saved
   videos" as the page eyebrow is the single most damaging line on the site. The library is personal
   *to each user* — that framing is fine and worth keeping in body copy — but the product is not a
   personal project. Headline should lead with what it is: an app you can get.
3. **Contact on the domain.** `hello@stash.dmitrijs.dev` on the landing page,
   `privacy@stash.dmitrijs.dev` in the policy, `support@stash.dmitrijs.dev` in the terms. TikTok's
   application form makes the domain match explicit, and a gmail address reads as a hobby project.
4. **Company identity in the footer** — legal name and KvK number, matching the legal pages.
5. **A price and a Download on the App Store button.** Decided 2026-08-16: Stash ships at **€5
   upfront** and **invite codes are removed**. A paid App Store listing is the strongest available
   proof that this is a commercial product rather than a personal one, and it means anyone who lands
   on the page can become a user in one tap. Reviewer access is handled with App Store promo codes
   (100 per version, 4-week validity), which is exactly what "provide demo accounts free of charge"
   asks for.
6. **More than a landing page.** The guidelines require a "fully developed website", explicitly not a
   holding page. One scrolling page with a CTA is thin. Support page, FAQ, a contact route that
   works — enough that the site reads as a product's home rather than a poster for one.

## Live blockers found 2026-08-15 (independent of the rejection, all still broken)

| # | Problem | Evidence | Fix |
|---|---|---|---|
| 1 | The 25 July legal-page rewrite was never deployed. Live `/privacy` is the 10 July version: "individual developer", gmail contact. | live 7,083 bytes vs local 18,407; live dated "10 July 2026" | deploy `services/webhook/site/` |
| 2 | `POST /webhook/tiktok` returns **401 to everything**. No `TIKTOK_CLIENT_SECRET` in Secrets Manager, receiver is fail-closed. TikTok's "Test URL" would fail. | `/health` → `"verify": false` | `put-secret-value` with the portal's client secret, restart |
| 3 | No mailbox exists. `dig MX stash.dmitrijs.dev` and `dig MX dmitrijs.dev` both empty — the domain addresses in the local legal pages are dead. | `dig` | Cloudflare Email Routing → forward to gmail |
| 4 | `ConnectFlowView` is a UI prototype: "there is no OAuth, no networking, and no secrets" (`App/Sources/ConnectFlowView.swift:3`). The flow the application describes is not built. | source comment | see below |
| 5 | Legal entity placeholders unfilled: legal name, KvK number, registered address. | memory + local pages | owner action |

Fix 1 before anything else. A reviewer who opens `/privacy` and reads "individual developer" has
already reached their verdict, whatever the application text says.

---

## The demo video

The 2026-07-11 video (`stash-demo.mp4`, 17s) shows the old single-user app and now works against us.
The replacement has to show a member of the public using the product on their own account.

Sequence to record:

1. Public landing page → tap **Get Stash** → TestFlight listing. Establishes public availability.
2. App launch → **Sign in with Apple** → account created. Establishes per-user accounts.
3. **Connect TikTok** → TikTok's own authorization screen → consent → return to Stash. This is the
   scope in use, and it is the shot the reviewer most needs to see.
4. Import runs → library fills with recipe cards, the track list, how-to summaries.
5. Settings → **Export my data** → share sheet; **Delete account** → confirmation. Proves the user
   rights the application claims.

Steps 2, 4 and 5 are shipped and recordable today. **Step 3 does not exist** — blocker 4 above. A
video that fakes it is worse than no video, so the OAuth flow is the prerequisite for the recording,
and therefore for the whole resubmission.

Record step 3 **against a sandbox**, which is what TikTok requires of a never-approved app anyway.
Every product and scope requested in the portal has to appear in the recording, and any product or
scope not demonstrated should be removed from the request before submitting — undemonstrated scopes
are a documented cause of delay and rejection.

The recording must show the app being opened from the home screen (mobile-app requirement), and the
domain shown on screen must match the website URL given in the portal.

### What step 3 needs

- iOS: replace `ConnectFlowView`'s enum-advancing prototype with a real `ASWebAuthenticationSession`
  against TikTok's authorize URL.
- Backend: `GET /v1/tiktok/authorize` + `POST /v1/tiktok/callback` — code exchange, per-user grant
  storage, refresh handling.
- Backend: request the portability archive for the connected user.
- Webhook: on `tiktok.data.portability`, download the archive, extract Favourite Videos only, discard
  the rest in memory, delete the archive, enqueue into the existing `/v1/imports` pipeline. The
  pipeline itself needs no changes — it already accepts normalized bookmarks.
- iOS: connect state and import progress in place of the prototype's "Open library".

Build and exercise all of this **inside a sandbox**. The production `portability.all.ongoing` scope
stays gated until approval, but sandbox is the environment TikTok expects a never-approved app to
demonstrate in, so the flow can be driven end to end and recorded without waiting on the grant.

---

## Strategy, decided 2026-08-16 — App Store first, TikTok second

The order in the original plan was backwards. TikTok wants proof that Stash is a real product sold to
real people; a live paid App Store listing *is* that proof. And Stash does not need TikTok's API to be
worth €5 today — the manual data-export import and the share extension both work with no approval at
all.

So version 1.0 ships **without** the Data Portability integration, at €5, and the resulting App Store
URL becomes the centrepiece of the TikTok resubmission. The OAuth flow ships afterwards as a free
upgrade to people who already bought.

The "temporary" solution is what 1.0 sells. That is the whole inversion.

**Consequence for the site and the store listing:** the live landing page currently promises "Connect
TikTok — sign in once with TikTok" and "Stash reads the videos you saved". That feature is not in 1.0.
Selling against that copy means paying customers who cannot do what they paid for, and an App Store
rejection for described functionality that does not exist. The copy has to describe the export +
share-extension flow that actually ships.

## Order of work

**Entity details resolved 2026-08-16.** KvK 70958416, BTW-id NL002463368B81 (validated against EU
VIES), registered in Tilburg — all already present in `privacy.html` and `terms.html`, which just
need deploying. The VAT number was added to both pages: a published BTW-id is cheap evidence of a
real trading business, which is the exact thing the rejection disputed.

**Blocking, owner only:** the Paid Applications agreement, signed by the Account Holder, then tax
forms, then banking (IBAN typed by the owner — it does not belong in this repo), then ~24h to
activate. Until that is Active there is no €5 price and no paid listing.

1. Remove the invite gate from the app and the backend; keep quotas. *(code)*
2. Rewrite the site: legal pages deployed, "personal" framing gone, copy describing the flow that
   actually ships, App Store CTA, support page so it is not "a holding page". *(blockers 1 + 6)*
3. Cloudflare Email Routing for the three domain addresses. *(blocker 3)*
4. Set the €5 price tier and submit 1.0 to the App Store. *(no StoreKit code — a paid-upfront app is
   a price-tier setting)*
5. Set `TIKTOK_CLIENT_SECRET`, confirm `/health` shows `"verify": true`. *(blocker 2)*
6. Create a sandbox; build the OAuth + archive-extraction flow against it. *(blocker 4 — the project)*
7. Record the demo video against the sandbox flow.
8. Resubmit to TikTok with the App Store URL, the video, and promo codes for the reviewers.

Steps 1–5 are days, mostly waiting on Apple. Step 6 is the project. Note that the TikTok resubmission
no longer blocks the product shipping — only the automatic-sync upgrade depends on it.
