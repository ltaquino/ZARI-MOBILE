# ZARI Mobile

Offline-first Flutter app for ZARI ERP — **Login, Inventory and Sales**. It talks to the existing ZARI API unchanged; nothing in `SND/ZARI` was modified.

| Area | What the app does |
|---|---|
| Login | Online sign-in (`/api/identity/login`, refresh via `/api/identity/refresh`), profile + effective permissions cached. Offline sign-in for any account that has signed in on the device before (salted PBKDF2 hash in the keystore — never the password). |
| Inventory | Item lookup by code/name/camera scan with branch price and on-hand per warehouse. **Stock Count** (→ Stock Opname DRAFT) and **Stock Adjustment** (→ DRAFT, optionally submitted for approval). |
| Sales | **POS sale** with split tender, change, line/header and statutory (Senior/PWD) discounts, serials (→ `/api/pos/checkout`). **Sales Order** (→ DRAFT or submitted). |
| Sync | Outbox pushes documents when online; master data (items, prices, stock, customers, payment methods, terminals, …) is downloaded into SQLite. |

Menus are gated by the same form permissions as ZARI web (`ITEMS`, `STOCK_OPNAMES`, `STOCK_ADJUSTMENTS`, `POS_MODE`, `SALES_ORDERS`).

## Run it

Toolchain: Flutter 3.16.7 / Dart 3.2.4 (package versions are pinned to what resolves there).

```bash
# 1. ZARI API reachable from the phone — e.g. on the dev machine:
cd ../ZARI/ZARI/src/Api
ASPNETCORE_ENVIRONMENT=Development ASPNETCORE_URLS=http://0.0.0.0:5000 dotnet run --no-launch-profile

# 2. The app (Android emulator reaches the host at 10.0.2.2, which is the default)
flutter run
# or bake in another server:
flutter run --dart-define=ZARI_API_URL=http://192.168.1.20:5000
```

The server URL can also be changed on the login screen (tap the URL under the Sign in button).

> `dotnet run --launch-profile ZARI.Api` currently fails to read `launchSettings.json` (it contains `//` comments) and falls back to Production, which refuses to start without a real JWT secret — hence the env-var form above.

Android notes: `minSdk 21`, `compileSdk 34` (CameraX), Kotlin 1.8.22. `usesCleartextTraffic="true"` is set only so a plain-http LAN dev server works — remove it once ZARI is served over HTTPS.

## Tests

```bash
flutter test                       # 32 host-side unit tests (in-memory SQLite + fake HTTP)
ZARI_LIVE_URL=http://localhost:5000 flutter test test/live   # end-to-end against a running API
```

The live test signs in as `staff.hq@zari.coop`, downloads everything, syncs a Sales Order and a Stock Opname (both DRAFT, deleted again as `admin@zari.coop`), and probes POS checkout binding with a request ZARI rejects at validation — it never posts anything.

## How offline sync works

```
lib/
  core/            api_client (Dio, refresh, failure classification) · app_database (SQLite) · token store · config
  features/auth/   online + offline login, session/permissions cache
  features/masterdata/  pull sync (paged catalog) + local queries
  features/sync/   outbox, push processor, sync controller, Sync & Queue screen
  features/inventory/   item list/detail, stock count/adjustment
  features/sales/  calculator (port of SalesInvoiceLineCalculator), POS, sales order, receipt
```

**Pull.** ZARI list endpoints have no "changed since" filter, so each entity is a full refresh. Items are fetched 500 per page from `/api/items/paged` and upserted, then items no longer in ZARI are pruned — an interrupted download never empties the catalog. Prices and stock are refreshed after every successful push and every 15 min; the catalog every 24 h or on demand. Entities the user may not read (403) are skipped, not fatal.

**Push.** Each document is one outbox row holding the exact request body. Rows are sent oldest-first:

| Outcome | Row becomes | Why |
|---|---|---|
| 2xx | `synced` (ZARI id + document no. stored) | |
| Request never left the device (no route, connect timeout) | stays `pending`, run stops | always safe to resend |
| 401 and refresh fails | stays `pending`, user asked to sign in again | |
| 4xx / 5xx from ZARI | `failed` with ZARI's message | user fixes/discards |
| Sent, but no answer (timeout, dropped connection, app killed mid-send) | `needs_review` | **never auto-resent** — see below |

ZARI's create endpoints have no idempotency key, so resending a request the server may already have committed could book a POS sale twice. A `needs_review` row tells the user exactly what to look for in ZARI web (terminal/time/total for POS; the `[MOB-XXXXXXXX]` tag stamped into Remarks for other documents) and offers *Found in ZARI — mark synced* or *Not in ZARI — retry*.

Two-step documents (create → `/submit`) record the ZARI id after step 1, so a retry only repeats the submit; the submit is skipped when a Company quick-post toggle already moved the document past DRAFT.

**POS safety.** `CreatePosSaleCommandHandler` commits the invoice, stock issue and payment as separate steps, so a sale rejected half-way leaves a partial document in ZARI. The app therefore checks on the device everything the handler would reject: active branch setting + default warehouse, serials present/unique, statutory ID, tenders (exact non-cash amount, change only from one cash tender), the discount approval threshold, and stock (cached on-hand at the default warehouse minus this device's unsynced sales).

**Receipts.** An offline sale shows a *PROVISIONAL — not an official receipt* receipt. The invoice no. / BIR OR series no. only exists once ZARI posts it; the receipt updates when the sale syncs.

## Known limits / backend follow-ups

1. **Idempotency key** — an optional `clientReferenceId` on `/api/pos/checkout`, `/api/sales-orders`, `/api/stock-opnames`, `/api/stock-adjustments` (unique index; return the existing document on repeat) would let ambiguous sends retry automatically and remove the `needs_review` step.
2. **POS checkout atomicity** — wrapping invoice + stock + payment in one transaction would remove the partial-document risk entirely.
3. **Delta sync** — `updatedSince` on items / item-branch-settings / balances / customers, and a `branchId` filter on `/api/item-branch-settings` and `/api/stock-ledger/balances` (both currently return every branch; the app filters client-side).
4. **POS config for encoders** — a Staff user gets 403 on `/api/company` and `/api/branches`, so the device can't know `maxUnapprovedDiscountPct` (the discount dialog warns instead) and shows branch ids instead of names. A small read-only "POS settings" endpoint gated by `POS_MODE` would fix both.
5. **Barcodes** — ZARI has no item-barcode master yet; scans match the item **code**. Hardware (keyboard-wedge) scanners work in any search field.
6. **Offline BIR compliance** — confirm with the accountant/RDO whether provisional offline receipts are acceptable for the accredited POS setup, or whether POS should require connectivity at checkout.
7. Printing receipts, sales returns, POS closing (Z-reading), goods receipt/issue and transfers are not in this first cut.
