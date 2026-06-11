# HCPropsController

A complete toolkit to manage and control trading activity on Prop Trading accounts in MetaTrader 5.

Everything is driven from **one single Expert Advisor**. There is no server, no login, and no license — it works **100% offline** on your own machine/VPS.

---

## Table of Contents

- [What's Included](#whats-included)
- [Features at a Glance](#features-at-a-glance)
- [Download](#download)
- [Quick Start](#quick-start)
- [The HCPropsController EA](#the-hcpropscontroller-ea)
  - [Installation](#installation)
  - [The Two Operating Modes](#the-two-operating-modes)
  - [MASTER Mode Parameters](#master-mode-parameters)
  - [SLAVE Mode Parameters](#slave-mode-parameters)
- [Feature: Prop-Firm Guardian](#feature-prop-firm-guardian)
- [Feature: Copy Trading (Master / Slave)](#feature-copy-trading-master--slave)
- [Feature: News Filter](#feature-news-filter)
- [Feature: Information Panel](#feature-information-panel)
- [Feature: Crash-Safe State Persistence](#feature-crash-safe-state-persistence)
- [Tool: Calendar Checker (CheckCalendar)](#tool-calendar-checker-checkcalendar)
- [Tool: StrategyQuant EA Patcher](#tool-strategyquant-ea-patcher)
- [How Synchronization Works (Technical)](#how-synchronization-works-technical)
- [Frequently Asked Questions](#frequently-asked-questions)
- [Important Notes](#important-notes)
- [Troubleshooting / Support](#troubleshooting--support)

---

## What's Included

| File | Type | Purpose |
|------|------|---------|
| `HCPropsController.mq5` | Expert Advisor | The core EA: Master/Slave copy trading + prop-firm risk guardian + news filter, all in one. |
| `CheckCalendar.mq5` | Script | Verifies that MT5's native economic calendar works on your broker (required for the news filter). |
| `Patch-SQX-GV-Disable.ps1` + `Run-Patcher.bat` | Windows tool | Patches EAs exported from StrategyQuant (SQX) so they obey HCPropsController's limits. |
| `patch-gv-disable.py` | Cross-platform tool | Same patcher as above, for Linux / macOS / any system with Python 3. |

> **Everything is controlled from a single EA.** The news filter is built into `HCPropsController` (it is **not** a separate EA). No backend, login, or `WebRequest` is required — the EA runs entirely offline.

---

## Features at a Glance

- **Prop-firm risk guardian (Master AND Slave)** — daily and total profit/loss limits, max parallel trades, max trades per day, consecutive win/loss streak limits, trading-hours window, and a forced close time, enforced independently on every account. When a limit is hit it closes positions, deletes pending orders, and disables trading. With `PropagateSlaveClose`, a Slave breach also closes the originals on the Master and **locks the Master**: new orders are only accepted while *every* account has trading enabled.
- **Copy trading** — replicate one MASTER account onto any number of SLAVE accounts on the same machine, with auto lot scaling by point value, lot multiplier, symbol mapping, inverse mode, distance-based SL/TP (measured from each account's own fill price), and Slave→Master close propagation (a Slave-side SL/TP/manual close flattens the Master and every other Slave within ~half a second).
- **News filter** — pause or close trading around economic news using MT5's native economic calendar (fully offline).
- **Live information panel** — an on-chart dashboard showing status, limits, counters, schedules, and connection state.
- **Crash-safe** — risk state is persisted in MT5 Global Variables and survives EA restarts and VPS reboots.
- **SQX integration** — a patcher that makes StrategyQuant EAs stop trading whenever HCPropsController blocks trading.

---

## Download

Go to the [**Releases**](https://github.com/ivanrdgc/HCPropsController/releases) section and download the latest version. Unzip the archive into your working folder.

> **Note on the compiled `.ex5` files:** if you edit any `.mq5` source, recompile it in MetaEditor (F7) so your changes take effect. The shipped `.ex5` reflects the source as released.

---

## Quick Start

1. Copy `HCPropsController.mq5` into your MT5 `MQL5/Experts/` folder and compile it (or use the provided `.ex5`).
2. Attach the EA to a chart on your **MASTER** account, choose your risk limits, and you're protected.
3. (Optional) Attach the same EA in **SLAVE** mode on other accounts/terminals to copy trades.
4. (Optional, for StrategyQuant users) Patch your SQX EAs so they pause when a limit is hit.
5. (Optional) Turn on the news filter and verify your broker serves the calendar with `CheckCalendar`.

---

## The HCPropsController EA

### Installation

1. Copy `HCPropsController.mq5` into the `MQL5/Experts/` folder of your MetaTrader 5.
2. Restart MetaTrader 5 or refresh the Navigator (F5), then compile the EA in MetaEditor (F7).
3. Drag the EA onto a chart.
4. In **Tools → Options → Expert Advisors**, allow algorithmic trading. (No `WebRequest` whitelist is needed — the EA never makes network requests.)

### The Two Operating Modes

#### 🔴 MASTER mode (primary account)

Meant to run **together with another EA that places the orders**. HCPropsController monitors the account, enforces the risk limits (when `PropFirmMode` is on), runs the news filter, gates the order-placing EA through the `HCPropsControllerDisableTrading` global variable, and writes a shared file describing its open positions so Slaves can copy them.

#### 🔵 SLAVE mode (replicating account)

Meant to run **alone** on its account: HCPropsController itself replicates the Master's positions. Since v2.20 it enforces the **same guardian limits** on its own account (configure them per account — each prop firm has its own rules). The only difference from the Master is who places the orders.

With `PropagateSlaveClose = true` the whole system behaves as one unit: a Slave-side close (SL/TP/manual/breach) closes the original on the Master and every other Slave, and a Slave whose trading is disabled (any lock) disables trading on the Master too — **new orders are only accepted while every account has trading enabled**.

---

### MASTER Mode Parameters

#### === GENERAL SETTINGS ===

| Parameter | Variable | Default | Description |
|-----------|----------|---------|-------------|
| Operation mode | `Mode` | `Master (executes trades)` | Select MASTER for this account. |
| Enable limits guardian | `PropFirmMode` | `true` | `true` = enforce all risk limits on this account (works in **both** modes since v2.20). `false` = pure relay/copy, no intervention in your trading. |
| Force initial balance | `ForceInitialBalance` | `0` | `0` = auto-detect the initial balance from deposits. `>0` = use this fixed value as the initial balance (basis for total/% limits). |
| Reset counters and locks on init | `ResetCountersOnInit` | `false` | `true` + reinitialize the EA = resets counters, daily initial equity, and **clears the sticky total lock**. Use it when starting a fresh account/challenge. |

#### === SYNC FILE ===

| Parameter | Variable | Default | Description |
|-----------|----------|---------|-------------|
| File name | `FileName` | `master_00001.csv` | Shared file name that links a Master to its Slave(s). The Slave must use the **same** value. For a second independent setup, bump the number (`master_00002.csv`, …) on both sides. |
| Custom path | `CustomFilePath` | `""` | Custom path inside `Common\Files` (optional). |
| Symbols | `Symbols` | `""` | (MASTER) Comma-separated symbols to replicate (empty = all). E.g. `EURUSD,US30`. |

#### === EQUITY LIMITS (Master and Slave) ===

| Parameter | Variable | Default | Description |
|-----------|----------|---------|-------------|
| Daily profit limit (%) | `DailyProfitLimitPercent` | `4.6` | Daily profit cap. `0` = disabled. |
| Daily loss limit (%) | `DailyLossLimitPercent` | `4.6` | Daily loss cap. `0` = disabled. |
| Total profit limit (%) | `TotalProfitLimitPercent` | `8.1` | Total profit cap. `0` = disabled. |
| Total loss limit (%) | `TotalLossLimitPercent` | `8.1` | Total loss cap. `0` = disabled. |

> Set any limit to `0` to disable it. See [Prop-Firm Guardian](#feature-prop-firm-guardian) for how the limits are calculated.

#### === TRADING LIMITS (Master and Slave) ===

| Parameter | Variable | Default | Description |
|-----------|----------|---------|-------------|
| Parallel trades limit | `MaxParallelTrades` | `1` | Max positions open at the same time. `0` = no limit. |
| Trades per day limit | `MaxTradesPerDay` | `1` | Max trades opened per day. `0` = no limit. |
| Consecutive losses per day limit | `MaxConsecLossesPerDay` | `0` | Max consecutive losing trades. `0` = no limit. |
| Consecutive wins per day limit | `MaxConsecWinsPerDay` | `0` | Max consecutive winning trades. `0` = no limit. |

#### === DAILY RESET (Master and Slave) ===

| Parameter | Variable | Default | Description |
|-----------|----------|---------|-------------|
| Daily reset hour | `DailyResetHour` | `0` | Hour of the daily reset (0–23). `0` = midnight. |
| Daily reset minute | `DailyResetMinute` | `0` | Minute of the daily reset (0–59). |

At the reset time, counters, daily initial equity, and the daily equity lock are reset/recalculated.

#### === TRADING HOURS (Master and Slave) ===

| Parameter | Variable | Default | Description |
|-----------|----------|---------|-------------|
| Limit new entries to the specified hours | `LimitTradingHours` | `true` | Enable the trading-hours window. |
| Trading start hour / minute | `TradingStartHour` / `TradingStartMinute` | `6` / `0` | Window start (e.g. 06:00). |
| Trading end hour / minute | `TradingEndHour` / `TradingEndMinute` | `20` / `0` | Window end (e.g. 20:00). Windows that cross midnight are supported. |

Outside the window, new entries are blocked and pending orders are removed; open positions are **not** force-closed by this rule.

#### === FORCED CLOSE (Master and Slave) ===

| Parameter | Variable | Default | Description |
|-----------|----------|---------|-------------|
| Force close at the specified time | `ForceExitEnabled` | `true` | Enable a daily forced close. |
| Forced close hour / minute | `TradingExitHour` / `TradingExitMinute` | `22` / `0` | At this time, **all positions are closed** and pending orders deleted. |

#### === NEWS PROTECTION (Master and Slave) ===

See the dedicated [News Filter](#feature-news-filter) section for full details.

| Parameter | Variable | Default | Description |
|-----------|----------|---------|-------------|
| News handling mode | `NewsMode` | `OPERATE` | `OPERATE` / `PAUSE_OPEN` / `CLOSE_ALL`. |
| Protection before and after (seconds) | `NewsDuration` | `120` | Half-window in seconds around each event. |
| Currencies to watch | `NewsCurrencies` | `""` | E.g. `EUR,USD,GBP`. Empty = derive from the chart symbol. |
| Minimum impact to consider | `NewsMinImpact` | `HIGH` | `LOW` / `MODERATE` / `HIGH`. |

#### Typical MASTER configuration

```
Operation mode                = Master (executes trades)
Enable limits guardian        = true
Daily profit limit (%)        = 4.6
Daily loss limit (%)          = 4.6
Total profit limit (%)        = 8.1
Total loss limit (%)          = 8.1
Parallel trades limit         = 1
Trades per day limit          = 1
Daily reset hour / minute     = 0 / 0
Limit new entries to hours    = true
Trading start                 = 06:00
Trading end                   = 20:00
Force close at time           = true
Forced close                  = 22:00
```

---

### SLAVE Mode Parameters

#### === GENERAL SETTINGS ===

| Parameter | Variable | Description |
|-----------|----------|-------------|
| Operation mode | `Mode` | Select `Slave (replicates trades)`. |

A Slave links to its Master purely through the **`FileName`** in the `=== SYNC FILE ===` group — set it to the same value the Master uses (default `master_00001.csv`). No server/account configuration is needed.

| Parameter | Variable | Default | Description |
|-----------|----------|---------|-------------|
| Symbol mapping | `SymbolMapping` | `""` | Format `MASTER:SLAVE;MASTER2:SLAVE2`. E.g. `EURUSD:EURUSD.pro;US30:US30Cash`. Empty = same names. |
| Copy mode | `CopyMode` | `NORMAL` | `NORMAL` also replicates SL/TP modifications; `INCOGNITO` sets SL/TP only at open and ignores later changes. |
| Invert Master trades (and SL/TP) | `InverseMode` | `true` | `true` = trade the opposite direction (BUY→SELL) and mirror SL/TP around the entry. `false` = copy in the same direction. |
| Lot multiplier | `RiskMultiplier` | `1.0` | Slave lot = Master lot × multiplier, applied **after** auto lot scaling. Keep `1.0` unless you deliberately want a smaller/larger hedge. |
| Auto lot scaling | `AutoLotScaling` | `true` | Equalizes **money per point** when contract sizes differ between brokers (e.g. an index worth $20/pt on the Slave vs $10/pt on the Master copies at half the lots automatically). Uses the point value the Master writes into the sync file. |
| Allowed slippage (points) | `Slippage` | `10` | Permitted deviation in points. |
| Magic Number | `MagicNumber` | `987654` | Magic of the Slave's orders. Must be unique per Slave within the **same** terminal. The EA only manages positions carrying this magic. |
| Slave closes/locks propagate | `PropagateSlaveClose` | `true` | Two effects, set the same value on the Master and all Slaves. **Closes:** a mirrored position closed on the Slave by its own SL/TP, a manual close, a stop out, or a guardian breach immediately closes the original on the Master — which in turn flattens every other Slave. **Locks:** while any Slave has trading disabled (any guardian lock), the Master disables trading too, so new orders are only accepted when every account is enabled. |

> The guardian groups (equity limits, trading limits, daily reset, trading hours, forced close, news) apply to the SLAVE as well — configure them with **this account's** prop-firm rules. The old `SlaveTotalProfitLimitPercent` was removed in v2.20: use `TotalProfitLimitPercent` with `PropFirmMode = true` instead.

#### Example SLAVE configuration

```
Operation mode        = Slave (replicates trades)
File name             = master_00001.csv     (must match the Master)
Symbol mapping        = "EURUSD:EURUSD.pro;US30:US30Cash"
Copy mode             = NORMAL
Invert Master trades  = true
Lot multiplier        = 1.0
Auto lot scaling      = true
Allowed slippage      = 10
Magic Number          = 987654
Slave close closes Master = true
```

> **Linking Master ↔ Slave:** they are paired solely by `FileName`. Leave the default (`master_00001.csv`) on one Master and its Slave(s) and they connect with no further setup. For a second, independent Master/Slave group on the same machine, set both of its EAs to `master_00002.csv`, and so on.

---

## Feature: Prop-Firm Guardian

Active in **both modes** when `PropFirmMode = true` (each account enforces its own configured limits). The guardian continuously monitors the account and enforces every configured limit.

On a **Slave**, two extra things happen when `PropagateSlaveClose = true`:

- A breach that closes positions (equity limits, streaks, `CLOSE_ALL` news, forced close) first asks the **Master** to close the mirrored originals, so the Master and every other Slave flatten with it.
- While the Slave has **any** lock active, it publishes a lock file that makes the Master disable trading too (`SLAVE LOCK` on the Master's panel). The Master deletes its pending orders and blocks new entries until **every** account is enabled again. A locked Slave also refuses to replicate new positions; if one slips through the race window, it requests the Master to close it.

### What each limit does when breached

| Limit | Action when hit | Re-enables when |
|-------|-----------------|-----------------|
| **Total** profit/loss (equity) | Closes all positions + deletes pending orders + disables trading. **Sticky** — stays locked even if equity recovers. | Only by setting `ResetCountersOnInit = true` and reinitializing. |
| **Daily** profit/loss (equity) | Closes all positions + deletes pending orders + disables trading. **Sticky** for the rest of the day. | At the next daily reset. |
| Max trades per day | Blocks new entries + deletes pending orders. Open positions are kept. | At the next daily reset. |
| Max parallel trades | Blocks new entries + deletes pending orders. If the open count **exceeds** the limit, closes the **newest** position(s) down to the limit (a position count merely *equal* to the limit is kept, to avoid open/close churn). | When position count drops below the limit. |
| Consecutive wins / losses | Closes all positions + deletes pending orders + disables trading. | At the next daily reset. |
| Outside trading hours | Blocks new entries + deletes pending orders. | Inside the trading window. |
| Forced close time | Closes all positions + deletes pending orders. | — (one-shot at the configured time). |

"Disabling trading" sets the MT5 Global Variable `HCPropsControllerDisableTrading` to `1.0`. Any EA that checks this variable — such as SQX EAs processed by the [patcher](#tool-strategyquant-ea-patcher) — will stop opening new positions while it is set.

### How the limits are calculated

- **Initial balance** (`AccountDepositsAndWithdrawals`) = sum of deposits/withdrawals/credits/charges detected from account history (or `ForceInitialBalance` if you set it). This is the basis for percentage limits.
- **Daily initial equity** = account equity at the daily reset time.

**Total limits** (percent of initial balance):

```
Total upper = InitialBalance × (1 + TotalProfitLimitPercent / 100)
Total lower = InitialBalance × (1 − TotalLossLimitPercent  / 100)
```

**Daily limits** use the more conservative of daily equity vs. initial balance as the basis (`basis = min(DailyInitialEquity, InitialBalance)`):

```
Daily upper = DailyInitialEquity + basis × DailyProfitLimitPercent / 100
Daily lower = DailyInitialEquity − basis × DailyLossLimitPercent  / 100
```

Using the smaller basis prevents the daily allowance from drifting larger than your account can support after a gain.

---

## Feature: Copy Trading (Master / Slave)

One MASTER account broadcasts its open positions to any number of SLAVE accounts running on the **same machine/VPS** (communication is via a shared file — see [How Synchronization Works](#how-synchronization-works-technical)).

- **Per-ticket mapping.** Each Master position is mapped to a Slave position via the order comment `HC<masterTicket>` plus the Slave's `MagicNumber`. The Slave only ever manages positions carrying its own magic.
- **Lot sizing.** `SlaveLot = NormalizeVolume(MasterLot × pointValueRatio × RiskMultiplier)`, clamped to the symbol's min/max/step. With `AutoLotScaling = true` the point-value ratio (Master $/point ÷ Slave $/point, from the value the Master writes per line) equalizes money-per-point across brokers with different contract sizes; `RiskMultiplier` is a pure preference on top. If the broker's min/max lots clamp the result, the Slave logs a **hedge coverage reduced** warning. It is **not** proportional to balance.
- **Slave-close propagation.** With `PropagateSlaveClose = true` (default), a mirrored position that closes on the Slave by its own SL/TP, a manual close, a stop out, or the Slave profit lock is propagated back: the Slave writes a close request file, the Master closes the original ticket (checked every 200 ms), the sync file updates, and every other Slave flattens. Sync-driven closes (the Master closed first) are never propagated back, so there are no loops. While a request is pending the Slave will not reopen that ticket; if the Master doesn't process it within 120 s (offline, or propagation disabled there) the Slave resumes plain mirroring.
- **Distance-based SL/TP.** The Slave doesn't copy the Master's absolute SL/TP prices — it copies the **distance** from the Master's entry and applies it to its **own actual fill price**. So if the Master enters at 1.04500 with a stop 0.01000 away (1.05500) and the Slave fills at 1.04700 (slippage / different quotes), the Slave's stop is set at 1.05700 — the same distance, preserving the intended risk. `CopyMode = NORMAL` keeps re-applying this when the Master moves its SL/TP; `INCOGNITO` sets it only at open.
- **Inverse trading.** `InverseMode = true` (the default) flips BUY↔SELL and **mirrors** SL/TP around the entry — the Master's TP distance becomes the Slave's SL, and vice versa.
- **Symbol mapping.** Use `SymbolMapping` (`MAST:SLAV;MAST2:SLAV2`) when broker symbol names differ.
- **Volume reduction tracking.** If the Master partially closes a position, the Slave reduces its volume to match (reduction only).
- **Per-Slave guardian.** The Slave runs the full prop-firm guardian on its own account (see [Prop-Firm Guardian](#feature-prop-firm-guardian)); breaches close the Master's originals and lock the Master via `PropagateSlaveClose`.

> **Account type:** designed for **hedging** accounts (and the common case of one position per symbol per account).
>
> **News interaction:** the news filter can run on any account. On the Master, pauses/closes replicate to the Slaves automatically. On a Slave (with `PropagateSlaveClose`), a news lock disables the Master too, and `CLOSE_ALL` closes the originals everywhere.

---

## Feature: News Filter

Available in both modes. The EA can pause or close trading around economic news using MetaTrader 5's **native economic calendar** — no email, API, or WebRequest required. It reads the calendar that MetaQuotes already delivers to the terminal. (On a Slave, verify the Slave broker serves the calendar too — see `CheckCalendar`.)

### Modes (`NewsMode`)

- `OPERATE` — do nothing (filter off).
- `PAUSE_OPEN` *(recommended)* — block **new** entries and cancel pending orders; **keep** open positions.
- `CLOSE_ALL` — close ALL positions + cancel pending orders + block new entries.

### Other parameters

- `NewsDuration` — seconds of protection **before and after** each event. E.g. `120` → protection from 2 min before to 2 min after (a 4-minute window).
- `NewsCurrencies` — uppercase, no spaces: `EUR,USD,GBP`. If left **empty**, the EA uses the base + profit currency of the chart symbol.
- `NewsMinImpact` — `LOW` / `MODERATE` / `HIGH` (default **HIGH**, high-impact events only).

### How it works

1. The EA queries the calendar on start and refreshes it **once per hour**.
2. It filters events by the chosen currencies and minimum impact.
3. When the clock enters the window `[event − NewsDuration, event + NewsDuration]`, it applies the `NewsMode` action.
4. On leaving the window, it re-enables trading automatically.

The panel shows `NEWS ACTIVE: ...` in red during protection, and `News: watching (N)` the rest of the time.

> The news filter reads only MT5's **native** economic calendar — no network requests, no external feeds. Because calendar access from MQL5 is **per-broker**, verify it works on your broker with [CheckCalendar](#tool-calendar-checker-checkcalendar) before relying on it.

---

## Feature: Information Panel

The EA draws an on-chart dashboard with everything important. It only redraws the labels that changed, to avoid flicker.

**Both modes show** (when `PropFirmMode = true`): mode (guardian on / sync- or copy-only), the sync **file** in use, trading status (ENABLED/DISABLED), active locks, initial balance, day-start equity, live equity with daily/total %, configured daily/total limits with color bands, trades today / parallel / win & loss streaks vs. their caps, the trading-hours window, news status, the next daily reset, and the forced-close time.

**SLAVE adds:** invert/multiplier/auto-lots/copy-mode summary and the connection status (CONNECTED / WAITING FOR MASTER).

**MASTER adds:** a red `SLAVE LOCK: <login> (<reason>)` line whenever a Slave's lock is currently disabling the Master.

**Color coding (graded by how close you are to a limit):**

| Color | Meaning |
|-------|---------|
| 🟢 Green | OK — below 50% of the limit |
| 🟡 Yellow | Caution — 50–75% of the limit |
| 🟠 Orange | Danger — 75–100% of the limit |
| 🔴 Red | Limit reached / trading blocked |

Connection and status labels also use green for the good state (trading enabled, Master connected, inside trading hours) and red/orange for the bad state.

---

## Feature: Crash-Safe State Persistence

When `PropFirmMode = true`, the guardian persists its state in MT5 Global Variables so it survives EA reinitialization, terminal restarts, and VPS reboots:

| Global Variable | Holds |
|-----------------|-------|
| `HCPropsController_InitBalance` | Detected initial balance |
| `HCPropsController_InitEquityDaily` | Day-start equity |
| `HCPropsController_NextReset` | Next daily reset timestamp |
| `HCPropsController_TotalLocked` | Sticky total-lock flag |
| `HCPropsController_DailyLocked` | Daily equity-lock flag |
| `HCPropsControllerDisableTrading` | Shared "stop trading" signal (read by patched SQX EAs) |

On startup the EA restores these values. If a daily reset time was missed while the EA was off, it performs the reset immediately. Set `ResetCountersOnInit = true` to wipe this state and start fresh.

---

## Tool: Calendar Checker (CheckCalendar)

The economic calendar is delivered by **MetaQuotes**, not your broker, but some brokers/builds restrict access to it from MQL5. Use `CheckCalendar.mq5` (a Script) to confirm the news filter will work before relying on it.

### Verify in three steps

1. **Interface:** In MT5, **View → Toolbox → Calendar**. If you see events listed, the terminal has calendar data.
2. **Script:** Compile and run `CheckCalendar.mq5` (drag it onto a chart). It prints, in the *Experts* tab, how many high-impact events exist over the next days. If it prints `>>> OK ...`, the EA can read news on this broker.
3. **EA log:** On start (with `NewsMode` other than `OPERATE`), the EA prints `NEWS: N news scheduled`. If this is always `0` on days with obvious news (NFP, CPI, FOMC), the broker is not serving the calendar.

`CheckCalendar` inputs: `InpCurrencies` (currencies to check, empty = all), `InpDaysAhead` (days ahead to list), `InpMinImpact` (1=Low, 2=Moderate, 3=High).

**Requirement:** the terminal must be **connected** to a trading server (the calendar syncs from there). In the Strategy Tester the calendar may be limited on older builds.

**If your broker doesn't serve the calendar:** the news filter cannot work on that terminal (the EA intentionally has no external-feed fallback, to stay fully offline). Options: run the EA on a terminal/broker whose build does serve the MQL5 calendar, or leave `NewsMode = OPERATE` to disable the news filter while still using the copy-trading and prop-firm features.

---

## Tool: StrategyQuant EA Patcher

If you export Expert Advisors from StrategyQuant (SQX), patch them so they obey HCPropsController's limits. The patcher injects, at the very start of `sqHandleTradingOptions()`, this check:

```mql5
// Check global variable to disable trading
if(GlobalVariableGet("HCPropsControllerDisableTrading") == 1.0) return false;
```

While HCPropsController holds that Global Variable at `1.0` (because a risk limit was hit or a news window is active), the patched EA will not open new positions — instead of immediately re-opening what HCPropsController just closed.

A `.backup` copy of each file is created before it is modified. The patcher is **idempotent**: files that are already patched, or that have no `sqHandleTradingOptions()`, are left unchanged. After patching, **recompile** the resulting `.mq5` in MetaEditor and use those instead of the originals.

### 🪟 Windows (PowerShell)

1. Keep `Run-Patcher.bat` and `Patch-SQX-GV-Disable.ps1` **in the same folder**.
2. Double-click **`Run-Patcher.bat`**.
3. Choose an option:
   - **Option 1** — process all `.mq5` files in a folder (recursive).
   - **Option 2** — process a single file.
4. Follow the on-screen instructions.

**Other ways to run it (Windows):**

- **Drag & drop** a `.mq5` file or a folder onto `Patch-SQX-GV-Disable.ps1`.
- **From PowerShell:**
  ```powershell
  .\Patch-SQX-GV-Disable.ps1 -Path "C:\Path\To\Your\Folder"
  .\Patch-SQX-GV-Disable.ps1 -Path "C:\Path\To\Your\File.mq5"
  ```

When it finishes you get a summary of **patched**, **skipped** (already patched / no SQX function), and **errors**.

### 🐧 Linux / macOS (Python, no Windows needed)

`patch-gv-disable.py` injects exactly the same line of code as the Windows patcher. It needs only Python 3 (no external dependencies), and the result is identical — use whichever you prefer.

```bash
# Option A — IN-PLACE: patch one file or every .mq5 in a folder (recursive).
#            A .backup copy is made before each file is modified.
python3 patch-gv-disable.py /path/to/MQL5/Experts
python3 patch-gv-disable.py /path/to/MyEA.mq5

# Option B — MIRROR: copy SRC into DST, patching along the way.
#            Originals in SRC are never touched; DST becomes a full mirror.
python3 patch-gv-disable.py /path/to/MQL5 /path/to/MQL5_Patched
```

The exit code is `1` if any file errored, `0` otherwise.

### Recommended order for SQX users

1. **First** patch your SQX-exported EAs with the patcher.
2. **Then** install and configure HCPropsController.
3. **Finally** run your patched EAs alongside HCPropsController.

---

## How Synchronization Works (Technical)

- **Transport:** a CSV file in `Common\Files\HCPropsController\` on the same machine, named by `FileName` (or a full path via `CustomFilePath`). The Master writes it and its Slave(s) read it — they're linked by using the same `FileName`. Run multiple independent groups on one machine by giving each its own file name (`master_00001.csv`, `master_00002.csv`, …).
- **CSV format v2** — a `SEQ` header, one line per Master ticket (9 comma-separated fields), and an `END` footer:
  ```
  SEQ,<n>
  ticket,symbol,type,volume,openPrice,sl,tp,openTime,pointValuePerLot
  END,<n>
  ```
  where `type`: `0` = BUY, `1` = SELL; `volume` = the Master's real lots; `openPrice`/`sl`/`tp` = prices; `pointValuePerLot` = account-currency value of a 1.0 price move per lot (used by `AutoLotScaling`). The `openPrice` is what lets the Slave compute SL/TP as a distance from the Master's entry. The `SEQ`/`END` pair (a write counter, monotonic across restarts) lets the Slave skip unchanged files and **discard torn reads** — a file caught mid-write has no matching `END` and is simply re-read 200 ms later. The old 1-second modification-time check (which could miss two writes within the same second) is gone.
- **Master writes** only when something changes (a content hash covering ticket, symbol, type, volume, SL, TP is compared each tick, and on every trade transaction). It also force-syncs immediately when a position opens or changes.
- **Slave reads** the header every 200 ms (full re-parse only when `SEQ` changed) and reconciles its positions against the cached targets **every tick**, so failed opens and failed SL/TP modifications are retried automatically:
  - closes Slave positions the Master no longer has,
  - reopens a position whose direction changed,
  - reduces volume to match a Master partial close,
  - sets/updates SL/TP as a distance from the Master's entry applied to the Slave's own fill price (re-applied each tick in `NORMAL` mode; in `INCOGNITO` set at open and re-tried only while the position has no levels at all),
  - opens any Master position it does not have yet (tagged with `HC<masterTicket>`; failed opens retry every ~1.5 s).
- **Close requests (Slave → Master):** with `PropagateSlaveClose = true`, Slave-initiated closes are written to `<syncfile>.close.<slaveLogin>` as `masterTicket,reason` lines. The Master polls `<syncfile>.close.*` every 200 ms, closes the requested tickets, deletes the request files, and rewrites the sync file so the remaining Slaves follow.
- **Lock files (Slave → Master):** while a Slave's guardian has trading disabled, it maintains `<syncfile>.lock.<slaveLogin>` (content = the active lock flags). The Master checks `<syncfile>.lock.*` every second: any file present → Master trading disabled (new entries blocked, pendings deleted) until all lock files are gone. The file is deleted when the Slave's lock clears, or when the Slave EA is deliberately removed from its chart; if a Slave terminal *crashes* while locked, the Master stays safely locked until the Slave comes back (or you delete the file manually).
- **Disconnect detection:** the Master deletes its sync file on shutdown; the Slave then shows `WAITING FOR MASTER`. Close requests queued while the Master is offline stay on disk and are processed when it returns.

> **Upgrading from v2.00:** the file format changed — update the EA on the **Master and every Slave at the same time** (an old Slave cannot parse a v2 file and vice versa). If you had set `RiskMultiplier` to compensate for a contract-size difference (e.g. `0.5` because the Slave's index contract is worth twice as much per point), set it **back to `1.0`**: `AutoLotScaling` now handles that per symbol, and a leftover manual multiplier would halve every other symbol's hedge.
>
> **Upgrading to v2.20:** the guardian inputs (equity/trading limits, hours, forced close, news) are now **active on Slaves** and load with their defaults the first time the new build attaches. Review every Slave's inputs after updating: either configure that account's actual prop-firm rules, or set `PropFirmMode = false` on the Slave to keep the old copy-only behavior. `SlaveTotalProfitLimitPercent` was removed — use `TotalProfitLimitPercent` instead.

---

## Frequently Asked Questions

**Q: Can I use the EA without patching my SQX EAs?**
A: Yes, but your EAs won't stop automatically when a limit is reached — only HCPropsController's own actions (closing positions, deleting pendings) apply.

**Q: What happens when I hit a limit?**
A: For equity limits and forced close, the EA closes all positions, deletes pending orders, and disables trading until the appropriate reset (daily, or `ResetCountersOnInit` for the sticky total lock). For count/streak/hours limits, it blocks new entries and removes pending orders but keeps open positions.

**Q: Can I connect multiple SLAVE accounts to one MASTER?**
A: Yes — as many Slaves as you want, all reading the same Master file. Give each Slave a unique `MagicNumber` within the same terminal.

**Q: Does the Slave copy the exact same volume?**
A: With `AutoLotScaling = true` it copies the volume that gives the **same money-per-point** as the Master (so a Slave broker whose contract is worth 2× per point trades half the lots), times `RiskMultiplier` (1.0 = same), normalized to the Slave symbol's lot step. If the broker's lot limits clamp the result, a "hedge coverage reduced" warning is logged.

**Q: What happens when the Slave's own SL/TP is hit before the Master's?**
A: With `PropagateSlaveClose = true` (default), the Slave asks the Master to close the original position immediately (the Master polls every 200 ms), and every other Slave flattens as soon as the sync file updates. With `false`, the Slave keeps mirroring the file and would reopen the position on the next change.

**Q: What happens when a Slave hits one of its own limits?**
A: The Slave's guardian acts on its own account exactly like on the Master (close positions for equity/streak breaches, block entries for count/hours breaches). With `PropagateSlaveClose = true` it also closes the originals on the Master (for closing breaches) and keeps the Master's trading disabled until the Slave's lock clears — so no account ever trades while another is locked.

**Q: Does the news filter work without internet / a server?**
A: It uses MT5's native calendar (no backend, login, or network requests). Confirm your broker serves it with `CheckCalendar.mq5`. If it doesn't, the news filter won't work on that terminal — leave `NewsMode = OPERATE` and the rest of the EA still works.

**Q: What does "0 = no limit" mean?**
A: Setting `0` on any limit disables that limit entirely.

**Q: How does a Slave know which Master to follow?**
A: Purely by `FileName` — set the Slave's `FileName` to the same value as its Master (default `master_00001.csv`). No server name or account number is involved.

---

## Important Notes

- Works with **MetaTrader 5** only.
- The Windows patcher requires PowerShell; on Linux/macOS use the Python patcher.
- Risk limits are computed from the account's detected initial balance (or `ForceInitialBalance`).
- The EA's internal timer runs every 200 ms (sync, close requests); guardian checks and the panel update every second.
- Copy trading requires the Master and Slave terminals to share the same `Common\Files` (i.e. run on the same machine/VPS).
- After editing any `.mq5`, recompile it in MetaEditor (F7).

---

## Troubleshooting / Support

If you run into issues:

1. Check the **Experts** and **Journal** tabs in MetaTrader 5 for messages.
2. Verify all parameters are set correctly (especially the Master/Slave linking — both must use the same `FileName`).
3. Make sure files are in the correct folders and the EAs are compiled.
4. For news, run `CheckCalendar.mq5` to confirm the calendar is available.

---

**Version:** 2.0
