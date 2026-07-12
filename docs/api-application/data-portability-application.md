# Stash — TikTok Data Portability API application draft

> Draft to adapt before submitting. Fields in `[[ ]]` are yours to fill (business/legal). Have your own counsel review the privacy text — this is a solid starting draft, not legal advice.

## Applicant details

- **Product name:** Stash
- **Business entity:** `[[legal business name]]`
- **Representative + email:** `[[name]]`, `[[name@your-business-domain]]` (must match the website domain)
- **Website:** `[[https://your-business-domain]]` (must be live and host the privacy policy below)
- **App ID:** `[[from TikTok developer portal once app reaches Staging]]`
- **Users served:** EEA + UK only (applicant and initial users based in Latvia / EU).

## Use case (paste into the application form)

Stash is a personal knowledge tool that helps a user make sense of the TikTok videos they have **saved to their own Favorites**. After the user connects their TikTok account, Stash retrieves their Favourite Videos, then organizes each saved video into a searchable personal library — recipes become structured recipe cards, music becomes a track list, coding/tech videos become summaries with links, and everything else is grouped by topic. The user's only action is bookmarking a video inside TikTok; Stash keeps their library in sync automatically.

This directly serves the portability purpose of the DMA: giving users continuous access to, and useful control over, data they have generated on TikTok.

## Requested scopes and justification

- **`portability.all.ongoing`** — Favourite Videos are exposed in the "Likes and Favourites" section of the full archive, so the `all` scope is required to reach them. **We extract only the Favourite Videos list and permanently discard every other category on receipt** (see data handling). `ongoing` is required so the user's library stays in sync with new saves without re-authorising each time.

We request no scope whose data we retain beyond what the stated use case needs. If TikTok can expose Favourite Videos under a narrower scope, we will switch to it.

## Data handling and retention (this is the core of the review)

1. **Minimisation on ingest.** When an archive arrives, our receiver extracts only the Favourite Videos entries (date + video link). All other categories in the archive (messages, watch history, profile, wallet, etc.) are **never persisted** — they are discarded in-memory before anything is written to storage.
2. **Where data lives.** Extracted favourites and the derived library live in the user's own environment: on the user's iOS device, and processed by a model service the user controls. Stash is a single-user personal tool; there is no shared multi-tenant datastore of TikTok content.
3. **Transient webhook receiver.** A small receiver accepts TikTok's "archive ready" webhook over HTTPS, downloads the archive, performs the extraction in step 1, and holds nothing else. Archives are deleted immediately after extraction.
4. **Retention.** Only the user's own favourites (and the analysis Stash derives from them) are retained, for as long as the user keeps them in the app. Nothing is shared with third parties.

## User rights and deletion (data-subject requests)

- **Access:** the user sees all stored data directly in the Stash app; it is their own library.
- **Export:** the user can export their library from the app at any time.
- **Deletion:** the user can delete any item, or wipe all Stash data, from within the app; disconnecting TikTok revokes the ongoing grant and stops all further transfers. A deletion request to `[[privacy@your-business-domain]]` is honoured within 30 days.
- **Revocation:** the user can revoke Stash's access from TikTok's own settings at any time.

---

# Privacy policy — Stash (draft)

**Last updated:** `[[date]]` · **Controller:** `[[legal business name]]`, `[[address]]` · **Contact:** `[[privacy@your-business-domain]]`

**What we access.** With your explicit authorisation via TikTok Login, Stash requests your TikTok data archive solely to obtain your **Favourite Videos** (the videos you have bookmarked). We do not use any other category of your TikTok data.

**What we keep.** We keep only your Favourite Videos list and the organized library Stash builds from it (titles, summaries, categories, and links). We **discard all other data** contained in the TikTok archive immediately on receipt and never store it.

**Why.** To provide the service you asked for: an organized, searchable library of the TikTok videos you saved. This is the lawful basis of performing a service at your request / your consent, which you may withdraw at any time.

**Where it is processed.** Your favourites are processed in your own environment (your device and a model service under your control) and are not sold or shared with third parties.

**How long.** For as long as you keep them in Stash. Delete individual items or wipe everything from within the app; disconnecting TikTok stops all future transfers.

**Your rights.** Access, export, correction, deletion, and withdrawal of consent. Contact `[[privacy@your-business-domain]]`; we respond within 30 days. You may also complain to your local data-protection authority (`[[for Latvia: Datu valsts inspekcija]]`).

**Changes.** We will post any changes to this policy at `[[policy URL]]` with an updated date.

---

# Application progress — 2026-07-10

**App created in TikTok developer portal:** "Stash", Individual ownership, type "Other", status Draft/Staging. App ID `7660891902371416072`. Client key + secret issued (kept out of this doc; secret belongs in the backend only).

**Products added:** Login Kit, Webhooks, Data Portability API (confirmed EEA/UK-only, Latvia qualifies).

**App-details fields filled in the portal:** app name `Stash`, category `Productivity`, description (see below), platform `iOS`.

**Description — paste this exact text (the field caps at 120 characters, so the long version gets truncated):**
> Stash organizes the TikTok videos you save into a searchable library of recipes, music, and how-to summaries.

**Assets ready:**
- App icon (1024²): `App/branding/stash-icon-1024.png` — upload to the App icon field.
- The 4 required UX mockups: real app screenshots in `docs/api-application/mockups/` — `01-connect.png`, `02-access.png`, `03-success.png` — plus TikTok's own authorization page (screenshot it live during the OAuth step) as mockup #3.

**Remaining before "Submit for review" (all either yours to host or infra to build):**
1. Upload the app icon (file above).
2. Terms of Service URL + Privacy Policy URL — host this doc's privacy text on your business site and paste the live links.
3. Webhooks Callback URL — stand up the endpoint (cloud function chosen). TikTok "Test URL"s it, so it must be live.
4. Login Kit redirect URI — set when wiring the real OAuth flow.
5. Data Portability API → "View scopes to apply" → request `portability.all.ongoing`, with the use-case text above.
6. Click Submit for review (yours) → ~3–4 week approval clock starts.

**Still blocking device/TestFlight install (separate from the API):** sign Xcode into the Apple ID (Xcode → Settings → Accounts → dmitryschab@gmail.com).

---

# Update — 2026-07-11

- **Platform: Web** (switched from iOS — TikTok required a live App Store URL for an iOS app, which Stash doesn't have; Data Portability is a web-OAuth + webhook flow anyway). Web/Desktop URL = `https://stash.dmitrijs.dev`.
- **Domain verified (DURABLE, persists server-side):** added Cloudflare TXT record on `stash` → `tiktok-developers-site-verification=gLuE4TFdxD0XicieRO0dK8d2f6HponRt`; TikTok shows `stash.dmitrijs.dev` under Verified properties, clearing the ToS/Privacy "not verified" errors.
- **Filled in the portal (EPHEMERAL — lives only in the open browser tab until a clean Save):** category Productivity; description; ToS `https://stash.dmitrijs.dev/terms`; Privacy `https://stash.dmitrijs.dev/privacy`; Login Kit redirect `https://stash.dmitrijs.dev/auth/callback`; Webhooks callback `https://stash.dmitrijs.dev/webhook/tiktok` (Test URL returned 200 + delivered a `tiktok.ping`); app-review explanation text; products Login Kit + Webhooks + Data Portability API.
- **Assets ready for upload:** icon `App/branding/stash-icon-1024.png`; demo video `docs/api-application/stash-demo.mp4` (17s walkthrough).
- **Only 2 errors remain — both are file uploads only the user can do:** App icon + demo video. TikTok blocks Save while any error exists, so the filled fields do NOT persist until both files are uploaded.
- **Data Portability scope (`portability.all.ongoing`) is gated** — "must be approved to turn on scopes." Submit the app with Login Kit + Data Portability API product; the scope enables after approval (normal flow).
- **To finish (one user sitting):** in the open portal tab (do NOT refresh it), upload the icon + demo video → Save → Submit for review. If the tab was refreshed and fields went blank, re-run the fill first.

---

# SUBMITTED — 2026-07-11 13:35

**Status: In review** (verified in the portal 2026-07-11 evening; changelog timestamps the submission at Jul 11, 1:35 PM). Portal banner: "This version of Stash is in review. There may be a delay in the app review process due to a high volume of requests."

Submitted version verified field-by-field in the portal:
- Icon: needle-branch logo (`App/branding/stash-logo-needle-branch-1024.png` — note: replaces the older `stash-icon-1024.png` referenced above)
- Name Stash · Category Productivity · Description (109/120 chars)
- ToS `https://stash.dmitrijs.dev/terms` · Privacy `https://stash.dmitrijs.dev/privacy`
- Platform Web · URL `https://stash.dmitrijs.dev`
- Login Kit redirect `https://stash.dmitrijs.dev/auth/callback`
- Webhooks callback `https://stash.dmitrijs.dev/webhook/tiktok`
- Products: Login Kit + Data Portability API + Webhooks · Scope: `user.info.basic`
- App-review explanation (705/1000 chars) + `stash-demo.mp4` uploaded
- No reviewer comments yet.

**Do NOT press "Recall"** — it withdraws the submission.

## While in review (~3–4 weeks) — prep so approval day is turnkey
1. Build the archive download/extract worker on the AWS box (webhook receiver exists; worker is the TODO): on `tiktok.data.portability` webhook → download archive → extract Favorite Videos only → discard rest (per data-handling promises above).
2. Set `TIKTOK_CLIENT_SECRET` in `/etc/stash-webhook/env` on the box → turns ON webhook signature verification (currently off).
3. Wire the real OAuth flow behind `https://stash.dmitrijs.dev/auth/callback`.

## On approval
- Data Portability API → "View scopes to apply" → request `portability.all.ongoing` with the use-case text above (scope application is gated until the app is approved — confirmed in portal).
