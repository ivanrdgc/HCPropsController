# v2.52 Validation

Tested on 2026-09-10 with MetaEditor/MetaTrader build 6182, in separate development
terminals with live trading disabled. Production controller sources are included by
the wrappers; only their event names and explicitly documented fixture boundaries
are substituted. The `.set` files in this directory are synthetic test fixtures,
not operational account configurations.

## Results

| Stage | Native checks | Scope |
|---|---:|---|
| Final lifecycle/copier stage | 393 PASS, 0 FAIL | 48 lifecycle, 163 inverse copier, 163 normal copier, 19 selective Master checks |
| Final forced-close stage | 56 PASS, 0 FAIL | 31 scheduled-close checks, 25 inventory/backoff/news checks |
| Earlier unchanged-function checks retained | 77 PASS | Invalid init, inventory/news, idea arithmetic/validation and per-group liquidation |

Counts describe assertion executions, not independent risk policies. Some checks
repeat across stages; do not add the counts as unique coverage. Earlier checks are
explicitly reused rather than represented as executions of the final binary.

All 46 generic compiled defaults were independently observed through native OnInit
without an external preset. The 44 existing defaults were unchanged; the two new
idea limits default to zero. The final generic controller and test wrappers compiled
without errors or warnings. A short strategy integration control using the real HC
also preserved the reference entry, exit, volume and prices; it is not a full-history
strategy revalidation.

The shipped generic `HCPropsController.ex5` has SHA256:

```text
866fa594028b65657944063c438a2eafa945fbe2a84e70fd9f90e03fc92c5e75
```

## Defects Found And Fixed

- Pending-only rejection initially failed to schedule the retry delay. The final
  inventory test verifies delay scheduling and suppression before retrying.
- Malformed Master numeric fields initially allowed a durable close acknowledgement.
  Both copier modes now reject malformed numbers, timestamps, record lengths and
  framing without advancing SEQ, acknowledging tombstones or reconciling targets.
- Pending cancellation backoff could consume a scheduled forced close without
  closing positions. The final forced-close test verifies the pending intent,
  first-attempt priority, rejection/partial retries and completion only when flat.
- Two early Master fixtures could not open their required opposite position because
  of custom-symbol hedged margin. These were failed fixtures, not selective-close
  successes. The final fixture provides sufficient synthetic margin and verifies
  that the opposite position and the second instrument survive and are exported.

## Limits

Tests use native positions, files, globals and execution inside the Strategy Tester.
Some fixtures inject per-ticket profit/swap, calendar responses and rejected close
requests; these boundaries are identified in the wrapper sources. They do not
demonstrate future broker fills, live calendar completeness, VPS scheduling under
failure, all netting reversals, or successful persistence under disk/GV failures.

Idea accounting covers floating profit plus swap for currently open positions by
symbol and direction, not historical trade-idea aggregation, realized profit or
fees. The daily-limit formula remains unchanged. A scheduled-close pending flag
survives a same-program in-memory reinitialization, but is not persisted across a
complete terminal restart. Review broker-specific policy separately.
