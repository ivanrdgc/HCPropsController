# Native HC Tests

These wrappers include the actual controller source with renamed event handlers.
They refuse to run outside the Strategy Tester. Never deploy their EX5 files.
Copy the repository tree under a development terminal's `MQL5/Experts` folder,
compile the wrappers, and use the matching synthetic `.set` files. Use a short
cached interval, local agents only, no optimization/cloud/remote testing, and
disable live trading on an empty terminal profile.

- `Lifecycle.mq5`: real initialization/timers/deinitialization, exclusive file
  ownership, injected timer failure, persistence and the consumer heartbeat gate.
  Also run with `DailyResetHour=24` to cover validation failure cleanup.
- `Trades.mq5`: real tester positions, pending orders, partial close and late
  arrival. CFaultTrade injects rejected requests; retry deadlines are explicitly
  advanced after asserting scheduling and request suppression. Calendar APIs are
  substituted only in this tester wrapper to exercise the real news pipeline.
- `EntryGate.mqh`: consumer contract for new entries, with no account policy.
- `ForceExit.mq5` with `force-exit.set`: native scheduled timer, existing
  pending-only backoff, rejected and real partial closes, pending-only remainder,
  in-memory deinit/init and news-pause coexistence. The fixture must get a quote
  before its 01:01 due time; choose a short cached day with trading at 01:00.
  Retry deadlines are explicitly advanced only after asserting scheduling and
  suppression. No complete message or next-day schedule is allowed before flat.
  The lifecycle calls simulate retained runtime globals, not a full terminal restart.
- `IdeaMath.mq5`: tester-only arithmetic/key checks using real idea helpers, without
  invoking the production lifecycle or sending trades. Prepared, not run here.
- [IDEA-CASES.md](IDEA-CASES.md): prepared per-group, persistence, copying and news
  integration matrix. Existing lifecycle/trade fixtures are not replaced.
- `IdeaIntegrationMath.mq5`: actual OnInit validation plus arithmetic/key helpers;
  with Mode MASTER and limits zero, real positions and selective Master CLOSE handling.
- `IdeaGroups.mq5`: real hedging inventory, grouping, rejection/partial/restart,
  late arrivals and cleanup. Requires two cached symbols, specified by the fixture.
  Synthetic per-ticket profit/swap values reach exact loss/profit boundaries and
  simulate rebounds; grouping and liquidation are the included production code.
- `IdeaCopier.mq5`: actual Slave frame parsing, mapped/inverse directions, signed
  distances, selective propagation, durable tombstones and acknowledgement rules.
  Run once inverse/propagation on and once normal/propagation off. Only selected
  ticket valuations and close rejection are injected, never the group algorithm.
  Its malformed-frame matrix covers every numeric column, canonical epoch time,
  short/cross-line records, extra fields, trailing delimiters/data, invalid SEQ/END,
  duplicate tickets and same-SEQ torn rewrites. Rejection must return 2 without
  advancing SEQ, acknowledging tombstones or reconciling cached targets.

The current Master writer emits integer epoch seconds for openTime. Formatted
dates are not its wire format. Unframed legacy snapshots are rejected; peers
using the pre-v2 protocol need a coordinated upgrade, not partial reconciliation.
The Master fixture now retains both an opposite position and a second-symbol
position, then verifies the real writer/parser roundtrip exports only survivors.

`idea-positive.set` is a synthetic baseline for `IdeaIntegrationMath`. For its
disabled/master case set both idea inputs to zero and Mode to MASTER. Negative
validation uses negative idea inputs. `IdeaGroups` requires ForceInitialBalance=0
(its fixture seeds a synthetic persisted base for restart testing), a hedging
account and a cached `FixtureOtherSymbol`. Give its tester deposit enough margin
for simultaneous opposite positions; the synthetic threshold base remains 10000.
For `IdeaCopier`, use SLAVE, loss1.25/profit0, map REMOTE to the chart symbol,
AutoLotScaling=false and a unique synthetic sync filename. None of these are
account presets. Check native margin rejection rather than counting absent fixture
positions as evidence of correct liquidation.

Look for `HC_TEST|name|PASS/FAIL` and exactly one `HC_SUMMARY` in the native agent
log. Missing summary or `HC_INCOMPLETE` is not success. A heartbeat-only fixture
does not validate the controller; lifecycle assertions require native cycles.
The tester equates TimeLocal and simulated server time: this does not demonstrate
real-world timer scheduling under a stalled terminal or broker connectivity.
Tests do not establish complete daily-limit, per-idea or strategy risk policy.
Idea accounting is open-position floating profit plus swap, not fees, realized
history or a historical ten-minute grouping. These fixtures do not cover every
case in IDEA-CASES (notably netting reversal, non-finite inputs and GV-write faults).
