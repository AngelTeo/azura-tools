# Kedai Runcit — Buying List + Warehouse
Approved 2026-11-27 (MYT) · implementation baseline v21 / reported DB v63
Status: APPROVED WORKFLOW; REFERENCE LOGIC TESTED; PRODUCTION INTEGRATION BLOCKED (Supabase connection).
Do not merge or deploy incomplete functionality. Main remains unchanged.

## User-approved operational rules
- Preserve existing Management home Buying List card and Food Order. Add only Warehouse entry; no duplicate Ready to Give home entry.
- Buying List three actionable tabs: 待购买 / 已订购 / 待交货. Tabs filter actual server-confirmed quantities; each can contain a portion of the same request. Use one consistent count unit (work lines per state), show quantities and explain split lines; do not silently interpret the existing screenshot count as pieces. Food Order stays separate. TOP UP remains its own card and service workflow, not a warehouse SKU.
- Existing product cards, photos, real IDs, grouped cable variants, farm grouping, request date, product checkbox and combined WhatsApp stay. WhatsApp draft/open never confirms order. Only a confirmed supplier order may enter Ordered; store supplier, quantities, date, references and actual received/remaining quantity. Pay and receipt are separate facts.
- Settings: independently choose stock-managed / on-request and fixed selling price / transaction-specific selling price. Service and per-bottle pricing remain separate rules; inventory tracking for any additional items requires owner confirmation. Existing price field semantics from v21 are not automatically rewritten. Clothes/shorts are on-request examples. Do not invent fixed prices, actual purchase prices, opening balances, suppliers, or product IDs.
- On-request: each actual purchase captures actual unit purchase price and actual agreed unit selling price, payer; partial receipt and partial delivery supported. Unfilled quantity stays open. Do not charge before actual handover and authorised deduction.
- Stock-managed: no new purchase when stock can satisfy demand. Confirm actual receipt against order or independent restock; quantity, unit cost, batch date, supplier and actual payer recorded independently. Never increase physical inventory just because ordered or paid. Reserve available inventory to requests, not duplicate allocation. Delivery consumes reserved batches, records historical cost and the agreed charge, and does not create a second supplier payment.
- Fixed selling price: default from confirmed catalogue setting, not overwritten by new purchase batch; snapshot the applicable agreed selling price, even if the catalogue later changes. Exceptions need an explicit authorised policy, not a casual price override. Historical amounts remain immutable except audited reversal. Pending demand and existing agreements require a migration decision if no historical price is known.
- FIFO reference cost policy; opening counts and batch cost provenance must be verified. User agreed to the overall warehouse workflow; FIFO is the recommended baseline. Confirm actual accounting policy before production migration. Unknown opening stock cost stays unresolved, never manufactured. Optional minimum levels / pack sizes / supplier minimum order only when configured; otherwise display shortage as information, not an invented supplier order.
- Warehouse: Stock In, Stock Balance (physical, reserved, available), Restock, Stock Take. Normal delivery remains in Buying List; special returns, damage, adjustments have audited reasons. No negative physical stock or available stock. Stock count changes that would invalidate reservations require explicit resolution. Do not release another worker's reservation silently. Keep batch unit cost immutable.
- Preserve existing alcohol approval, per-bottle participant and price rules, and TOP UP success vs supplier payment. Do not split an indivisible bottle or duplicate a payment. Stock handling of special categories needs verified unit and approval configuration, and lawful treatment. Actual worker-paid items must not trigger duplicate deductions or fictitious company expenditure.

## v21 verified integration points (frontend)
- Lines 673–674: open/toBuy currently select REQUESTED lines without warehouse routing.
- Lines 714–729: handLink and home Buying List; Ordered is an explicit placeholder, not data. Retain card layout, route tabs to server quantities.
- Lines 790+: buyPage/product grouping: only procurement lines eligible for supplier list; stock reservations and services must not be treated as goods purchases. Preserve existing alcohol gating and TOP UP card.
- Lines 825–883: itemPage, detailBuy, detailSaveBuy, detailSaveHand. Preserve on-demand actual buy + sell, distinguish warehouse reserve/receipt and stock delivery; do not reuse a purchase RPC to mark existing stock as bought.
- Existing shop_owner_buy / shop_owner_hand / shop_owner_spot / shop_owner_finish_trip / shop_owner_board / shop_owner_money and TOP UP, payments, reimbursements, legacy fills: inspect actual database definitions before integration. These are existing names, not a claim of new signatures.
- Lines 1171+: finishTrip currently forwards all toBuy IDs. Restrict to unfulfilled unordered portions eligible to carry forward; retain original request date, reservation and ordered portions. Exclude fulfilled or blocked portions; explicit separate treatment for TOP UP.
- Management At the Farm: distinguish issue from existing stock vs on-request purchase; never invent a payment at issue. Direct purchase and salary records remain subject to existing legal/authorised handling.

## Server-side implementation contract (proposed; names/schema to be verified)
1. Item mode + price policy; map real SKU and units. Preserve all IDs, historical prices, photographs and user permissions.
2. Purchase order line: ordered quantity, actual receipts, cancellation/remaining, link to request allocations and/or replenishment stock. Separate payment references, support unpaid/paid receipt cases without fake cash movement.
3. Receipt/batch: source receipt, actual received qty, actual cost, immutable unit cost, stock movements; opening stock migration based on actual count and verified cost evidence.
4. Reservations: request, batch, quantity; states reserved/consumed/released, unique identifiers. Requests and orders cannot be overallocated. Partial quantities and dates remain traceable.
5. Issue / handover: unique operation, quantity, actual allocation(s), historical cost snapshot, fixed/agreed selling price snapshot, actual payment/deduction status. Split batches in one transaction; avoid duplicate Salary entries; use integer sen or database exact decimals. Any reimbursement references existing actual payments only.
6. Payment ledger: reuse v21 ledger and management payer identities. Actual stock procurement payment produces one ledger entry; delivery produces no duplicate payment. Company cash vs manager advance vs worker cash separate.
7. Atomicity and security: server locks relevant stock / request / order rows in consistent order or serialisable transaction; check role, quantity, approval and idempotency before writing. Concurrency must be tested in the database, not merely mocked. Cancellation/reversal returns only actual allocations and uses compensating records; check closed salary periods and reimbursed payments; never silently change history.
8. Return board snapshot with authoritative counts, per-state portions, inventory balances, and action eligibility. Failure to read stock/ledger displays a retryable error, not zero or a route guess. Do not mix localStorage with production ledger.

## Reference logic available
- dev/warehouse/warehouse-core.mjs: pure planner, FIFO cost of reserved batches, on-request routing, replenishment suggestion, independent buy/sell calculation; no I/O. The planner output is a proposal only; never treat it as a committed reservation or authorisation. Production must validate that snapshot with actual database locks.
- dev/warehouse/warehouse-core.test.mjs: 21 tests executed successfully in a JS harness; rerun with Node (node dev/warehouse/warehouse-core.test.mjs). Mock data only, not an actual stock count or a DB test.
- This branch intentionally does not modify OPR/KedaiRuncit.html or production database.

## Acceptance gates — real operator, real database test environment
- [ ] Preserve home card layout and existing Food Order, TOP UP, salary, petty cash, reimbursement and legacy records.
- [ ] On request 5 pieces, 2 received, 1 ordered, 2 unpurchased: correct three states with no double count.
- [ ] Stock 20 / request 4: reserve 4, available 16, physical 20, no new purchase. Confirm delivery: physical 16, reservation released/consumed, no additional purchase payment.
- [ ] Stock 5 / demand 8: 5 ready, 3 shortage. Confirm supplier order of 3; then confirm receipt; no duplicate procurement. Configured carton MOQ may exceed shortage; extra units stay stock.
- [ ] Paid but not received: actual payment recorded once; physical stock unchanged.
- [ ] Different receipt batch unit costs: fixed selling price stays unchanged; FIFO cost accurately spans batches; actual source costs never overwritten. Variable sale entered per purchase and snapshotted.
- [ ] Two management devices reserve/issue at the same time; second conflicting transaction rejected/refreshed; no negative or double allocation.
- [ ] Request cancellation releases only its own unused reservation; partial handover leaves remainder; returns/damage/count correction audited.
- [ ] Worker cash already paid: no duplicate deduction; verify authorised deductions and salary period rules.
- [ ] Order confirmation explicit, WhatsApp open only leaves draft; carry-forward excludes already ordered/reserved/delivered quantities.
- [ ] Item settings updated once across devices; missing price, stock, or supplier facts remain clearly pending; no fabricated values.
- [ ] Compare actual worker phone and management workflows on mobile, using isolated test records, not live wages.
- [ ] Verify DB migrations, rollback/backup, GitHub commit, Pages build/deploy, real mobile acceptance before marking complete.

## Blocker
27 November: direct Azura Delta Supabase project call still returns "link_id must identify an eligible linked account". The user already connected it in UI; no repeat login requested. Need an authorised working connector or the existing Claude environment with confirmed access to inspect database v63 and implement real transaction boundaries. Do not ship a UI pretending the stock ledger is live.
