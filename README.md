# ZARI Mobile

Offline-first Flutter app for ZARI ERP — **Login, Inventory and Sales**. It talks to the existing ZARI API unchanged; nothing in `SND/ZARI` was modified.

| Area | What the app does |
|---|---|
| Login | Online sign-in (`/api/identity/login`, refresh via `/api/identity/refresh`), profile + effective permissions cached. Offline sign-in for any account that has signed in on the device before (salted PBKDF2 hash in the keystore — never the password). |
| Inventory | Item lookup by code/name/camera scan with branch price and on-hand per warehouse. **Stock Count** (→ Stock Opname DRAFT) and **Stock Adjustment** (→ DRAFT, optionally submitted for approval). |
| Sales | **POS sale** with split tender, change, line/header and statutory (Senior/PWD) discounts, serials (→ `/api/pos/checkout`). **Sales Order** (→ DRAFT or submitted). |
| Truck Route | Route Sales for a delivery truck's driver (`ROUTE_SALES`): download the trip, count and accept the load, deliver orders / sell off the truck / record refusals with a reason / take returns / collect old balances, issue BIR invoices with the handheld's own number series, print them on a Bluetooth or built-in printer, capture the receiver's signature, end the trip with the count and cash. |
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
flutter test                       # 51 host-side unit tests (in-memory SQLite + fake HTTP)
ZARI_LIVE_URL=http://localhost:5000 flutter test test/live   # end-to-end against a running API
```

The live test signs in as `staff.hq@zari.coop`, downloads everything, syncs a Sales Order and a Stock Opname (both DRAFT, deleted again as `admin@zari.coop`), and probes POS checkout binding with a request ZARI rejects at validation — it never posts anything.

`test/live/route_live_test.dart` plans a trip (truck E2E55464, driver staff.hq), approves the load as manager.hq and
drives the handheld code through a whole trip — it **posts real documents** (invoice, void, return, close).

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

**Pull.** A *full* pull (every 24 h or on demand) re-downloads everything: items 500 per page from `/api/items/paged`, upserted, then items no longer in ZARI are pruned — an interrupted download never empties the catalog. A *quick* pull (after every successful push and every 15 min) asks only for prices, stock, customers and items changed since the last pull (`updatedSince`) and upserts them; deletions are caught by the next full pull. Prices and stock are requested per branch (`branchId`). The cursor is ZARI's own clock (the response's `Date` header) less a 2-minute overlap, so neither the device clock nor a transaction committing a moment late can skip a change. Entities the user may not read (403) are skipped, not fatal — except the company settings and branch names, which come from the read-only `/api/device-settings` when `/api/company` / `/api/branches` are refused (a cashier, encoder or driver).

**Push.** Each document is one outbox row holding the exact request body. Rows are sent oldest-first:

| Outcome | Row becomes | Why |
|---|---|---|
| 2xx | `synced` (ZARI id + document no. stored) | |
| Request never left the device (no route, connect timeout) | stays `pending`, run stops | always safe to resend |
| 401 and refresh fails | stays `pending`, user asked to sign in again | |
| 4xx / 5xx from ZARI | `failed` with ZARI's message | user fixes/discards |
| Sent, but no answer — idempotent row (POS, sales order, stock count/adjustment, route) | back to `pending` | ZARI returns the first send's document on a resend — see *Idempotent sends* |
| Sent, but no answer — other rows (and rows queued by an older app version) | `needs_review` | **never auto-resent** — see below |

For a row without an idempotency key, resending a request the server may already have committed could book it twice. A `needs_review` row tells the user exactly what to look for in ZARI web (terminal/time/total for POS; the `[MOB-XXXXXXXX]` tag stamped into Remarks for other documents) and offers *Found in ZARI — mark synced* or *Not in ZARI — retry*.

Two-step documents (create → `/submit`) record the ZARI id after step 1, so a retry only repeats the submit; the submit is skipped when a Company quick-post toggle already moved the document past DRAFT.

**POS safety.** `CreatePosSaleCommandHandler` commits the invoice, stock issue and payment as separate steps; with the sale's `clientReferenceId` a resend completes whatever step didn't finish, so a partial sale heals on retry. The app still checks on the device everything the handler would reject: active branch setting + default warehouse, serials present/unique, statutory ID, tenders (exact non-cash amount, change only from one cash tender), the discount approval threshold, and stock (cached on-hand at the default warehouse minus this device's unsynced sales).

**Receipts.** An offline sale shows a *PROVISIONAL — not an official receipt* receipt. The invoice no. / BIR OR series no. only exists once ZARI posts it; the receipt updates when the sale syncs.

## Truck Route (Route Sales)

`lib/features/route/` — `route_models.dart` (the `/api/trips/mine` download), `route_ledger.dart`, `route_service.dart`,
`printing/` (ESC/POS builder, invoice layout, Bluetooth printer), `ui/`.

* **Offline ledger.** The trip as first downloaded (the *baseline*) plus every action recorded on the device
  (`route_events`) gives exact truck stock, what each order still has open, what each customer owes and the cash
  the driver should hold — only the trip's driver can record on it, so nothing else can change it meanwhile.
* **Invoice numbers.** The handheld's series lives in `route_series`. A number is claimed in the same SQLite
  transaction that records the sale (or void) and queues it, so it's never used twice or skipped silently; a new
  download can only move the series forward. Voiding an unsynced invoice turns its queued sale into a void of the
  same number *in the same queue position*, so ZARI still receives the series in order.
* **Sync.** Route endpoints are idempotent server-side, so these outbox rows are `idempotent`: a send whose answer
  was lost goes back to *pending* and is simply retried (no "needs review"). ZARI accepts a truck's invoices only in
  number order, so once an invoice/void of a trip is rejected, that trip's later invoices wait behind it; Sync &
  Queue offers **Void this invoice number** to release them (invoice numbers can't be discarded). The end of trip
  waits until everything before it has gone. Signatures upload once their sale is in ZARI.
* **Checks before a number is used** (mirroring ZARI): sale only while on the road; never more than is on the truck
  or still open on the order; a reason for any ordered quantity not delivered; change only out of one cash tender;
  non-cash tenders need a reference; charges must fit the customer's credit limit.
* **Collections** are allocated oldest first: invoices open at download (by ZARI id), then charges issued earlier on
  this trip (by invoice number — ZARI resolves it, since the sale always syncs first). An invoice a collection was
  applied to can no longer be voided on the device.
* **Accepting the load needs a connection** (it's done at the warehouse); everything after works offline.
* **Printing.** `PrintBluetoothThermal` sends raw ESC/POS bytes to the paired printer chosen in *Printer* (58 or
  80 mm). Built-in handheld printers (e.g. Sunmi "InnerPrinter") appear as a paired device. The invoice layout
  carries the BIR essentials (seller name/TIN/address, invoice no./date, buyer, items, VAT breakdown, MIN/serial,
  PTU) — the seller details come with the trip download because a driver can't read Company Settings. The same
  lines drive the on-screen preview; reprints are marked REPRINT.

## Idempotent sends

POS sales, sales orders, stock counts and stock adjustments carry their outbox row id as ZARI's `clientReferenceId`.
A resend with the same key returns the document the first send created — for a POS sale it also finishes whatever
didn't complete (stock/COGS, payment), so a checkout is never booked twice or left half-done. These rows are therefore
`idempotent`: when an answer is lost they go back to *pending* and are retried, instead of to *needs review*. A
retried follow-up (submit for approval) first re-reads the document's status, so it's never submitted twice.
Rows queued by an older app version (no key) keep the old needs-review behaviour.

## Known limits

1. **Barcodes** — ZARI has no item-barcode master yet; scans match the item **code**. Hardware (keyboard-wedge) scanners work in any search field.
2. **Offline BIR compliance** — confirm with the accountant/RDO whether provisional offline receipts are acceptable for the accredited POS setup, or whether POS should require connectivity at checkout.
3. Printing POS receipts, sales returns, POS closing (Z-reading), goods receipt/issue and transfers are not in this first cut (route invoices do print).
4. **Route printing is untested on real hardware** — the emulator has no Bluetooth. The ESC/POS bytes and the layout are
   unit-tested; try the *Printer → Test print* on the actual handheld/printer before going live.

