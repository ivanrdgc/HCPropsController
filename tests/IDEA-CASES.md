# Open-Idea Regression Cases

Prepared cases, not an execution report. No new EX5 or native validation is supplied
with this implementation. Preserve earlier heartbeat test logs, including the two
backoff failures; a later run gets a new report, not an overwritten result.

Use the existing isolated development tester workflow in [README](README.md).
Use generic synthetic fixtures, never account-specific presets. Preserve existing
`Lifecycle.mq5` / `Trades.mq5` evidence and run them again with both new inputs zero.
Their close-trade injection (`HC_CLOSE_TRADE_CLASS`) also covers the new idea module.

## Arithmetic Wrapper

`IdeaMath.mq5` includes the real source, renames all production event handlers and
does not invoke them. It checks actual arithmetic/key helpers only; no orders,
GV writes, account initialization or copier behavior. Prepare separate runs with
zero/zero, synthetic loss 1.25 / profit 2.5, loss only, profit only and negative
inputs. Tiny thresholds below one cent require a smaller fixture delta than its
default 0.01. Non-finite inputs and overflowing/underflowing threshold amounts
require native fault injection; arithmetic PASS does not prove OnInit fail-closed.

## Integration Matrix

| Case | Required observations |
|---|---|
| Identity | Defaults zero, no old `HCI1_`/`HCT1_` state: identical existing positions/orders/locks, daily formulas, news behavior and sync records. Total-limit settings remain untouched. |
| Group loss | Two BUY positions of one symbol, different magics (include manual magic zero), individually below but jointly at the loss boundary. Both close; a SELL on the same symbol and a BUY on a second symbol survive. Pending orders survive this rule. |
| Group profit | Same test at the positive boundary; opposite/other-symbol losses must not offset the group profit. Include swap in the triggering sum. |
| Boundaries | One cent inside, exact threshold, one cent outside, both signs. Also a fractional percentage whose multiplication order exposes rounding. No historical realized profit or already charged commissions included. |
| Init validation | Negative, NaN, infinities: `INIT_PARAMETERS_INCORRECT`. Enabled limit with zero/negative/non-finite base or invalid monetary amount: failed init, heartbeat absent, entry permission absent, including `ResetCountersOnInit=true`. |
| Init execution | Pre-existing breached positions on restart: latches durable and close attempts occur before the first heartbeat. Other account locks are preserved. |
| Rejection/backoff | Inject REJECT and then CONNECTION/MARKET_CLOSED. Inventory remains, GV latches remain, no repeated close at 200 ms; normal retry >=1 s, connectivity/market retry >=5 s. Logs bounded to one failure per group per 30 s. |
| Partial/rebound | Real partial close, then P/L moves inside both thresholds. Remaining volume still closes after backoff; no latch removal based on retcode alone. |
| Late positions | While a latched member remains, add a new position of the same group during backoff. Its intent must be persisted on the next pass, and it must close even below threshold. Opposite/new-symbol positions survive. |
| Restart | Persist a partial/rejected group, restart with no in-memory groups and valid changed base. Same position identifiers/direction still finish. Repeat with both inputs zero. |
| Cleanup/new idea | Confirm flat, verify only closed local latches removed, account locks unchanged; open new same-symbol/direction tickets below threshold and ensure no inherited cooldown. Also close an anchor externally between passes. |
| Netting reversal | In guardian-only/master netting fixture, reverse a latched position retaining identifier. The opposite direction is not closed by old intent. Slave mode must still reject netting accounts. |
| Guardian off | Fresh positive inputs with `PropFirmMode=false`: no idea closes. Previous liquidation is locally suspended, and stored copier anti-reopen memory is retained as documented. |
| News | Under real `NEWS_PAUSE_OPEN` pipeline, below-threshold positions remain; a monetary breach closes only its group. No new preventive/news-forced exit, no SL/TP removal. Existing news pending deletion is a separate rule. |
| Inverse local-only | SLAVE inverse copy, propagation false: close only mapped local group, persist its Master-ticket tombstones, no CLOSE requests or new account LOCK caused by the idea. Same original tickets cannot reopen after >120 s or restart. Unrelated/new targets still copy. |
| Inverse propagated | Propagation true: before local closes, status contains only corresponding original tickets with IDEA_LOSS/IDEA_PROFIT. Master closes those originals through normal processing; other positions survive. Requests persist >120 s and restart until ack. Repeat normal copying. |
| Ack validity | Missing/unreadable file, torn END, malformed records, legacy non-SEQ file, or same-SEQ torn rewrite must not purge tombstones. A complete raw snapshot still containing a ticket must retain it even if its normalized target cannot be generated. |
| Ack cleanup | A valid snapshot omitting the ticket plus confirmed local close removes its tombstone and request; later unrelated tickets copy. If local close still fails, retain intent and re-read unchanged SEQ fully until cleanup can finish. |
| Ordinary TTL | Non-idea SL/TP/manual requests retain existing 120-second fallback. An ordinary request upgraded by an idea must never be downgraded by a later ordinary request. |
| Settings changes | Zero both limits while latched: liquidation finishes. Daily reset/ResetCountersOnInit do not erase idea state. Local-only tombstones do not become Master close requests merely by enabling propagation. |
| Panel | Both optional lines show the correct percent and monetary amount per group/account currency; each disappears at zero. No account-wide idea lock line. |
| Persistence/key scope | IDs above 2^53 and uint64 maximum do not collide/truncate; BUY/SELL differ; account and copier magic isolate namespaces. Flush precedes first request. Simulated GV-write failure must not silently lose group intent or publish successful init. |

For real native integration, retain compile logs, exact source/binary hashes,
inputs, complete tester output and inventory/status/GV observations. Label all
clock, P/L, retcode, calendar and persistence substitutions explicitly. A wrapped
test with injected data is not an unmodified controller/broker execution claim.
