//+------------------------------------------------------------------+
//|                                            HCPropsController.mq5 |
//|  Copy-trading (Master/Slave) + prop-firm guardian + news filter  |
//|  Single EA, file-based sync on the same VPS. No backend/license. |
//+------------------------------------------------------------------+
#property strict
#property version "2.41"
#property description "HCPropsController: Master/Slave copy trading, prop-firm limits and news filter in a single EA."
#property description "v2.40: NONE mode (risk management on a single account, no replication files) and"
#property description "HistoryFromDate for prop-firm account resets (ignore history before a chosen moment;"
#property description "initial balance becomes the balance as of that time)."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\DealInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//===================================================================
// ENUMS
//===================================================================
enum HCMode
  {
   MODE_MASTER = 0, // Master (executes trades and replicates to Slaves)
   MODE_SLAVE  = 1, // Slave (replicates trades from a Master)
   MODE_NONE   = 2  // None (risk management only; no replication, no shared files)
  };

enum HCCopyMode
  {
   COPY_NORMAL    = 0, // NORMAL (also replicates SL/TP modifications)
   COPY_INCOGNITO = 1  // INCOGNITO (SL/TP only on open; ignores changes)
  };

enum HCNewsMode
  {
   NEWS_OPERATE    = 0, // OPERATE (do nothing)
   NEWS_PAUSE_OPEN = 1, // PAUSE_OPEN (block new entries; keep positions)
   NEWS_CLOSE_ALL  = 2  // CLOSE_ALL (close all + block)
  };

// Values aligned with ENUM_CALENDAR_EVENT_IMPORTANCE (LOW=1, MODERATE=2, HIGH=3)
enum HCNewsImpact
  {
   NEWS_IMP_LOW      = 1, // Low or higher
   NEWS_IMP_MODERATE = 2, // Moderate or higher
   NEWS_IMP_HIGH     = 3  // High impact only
  };

//===================================================================
// INPUT PARAMETERS
//===================================================================
input group "=== GENERAL SETTINGS ==="
input HCMode   Mode                = MODE_MASTER; // Operation mode
input bool     PropFirmMode        = true;        // Enable limits guardian (all modes)
input double   ForceInitialBalance = 0.0;         // Force initial balance (0 = auto-detect)
input datetime HistoryFromDate     = 0;           // Ignore history before this time (account reset); 0 = full history
input bool     ResetCountersOnInit = false;       // Reset counters and locks on init

input group "=== SYNC FILE ==="
input string FileName             = "master_00001.csv"; // Shared file name (Master and Slave must match; bump 00001 for more)
input string CustomFilePath       = "";          // Custom path inside Common\Files (overrides FileName)
input string Symbols              = "";          // (MASTER) Symbols to replicate, comma-sep (empty = all)

input group "=== SLAVE SETTINGS (SLAVE mode only) ==="
input string     SymbolMapping       = "";        // Mapping MAST:SLAV;MAST2:SLAV2 (optional)
input HCCopyMode CopyMode            = COPY_NORMAL;// Copy mode
input bool       InverseMode         = true;      // Invert Master trades (reverse direction; mirror SL/TP)
input double     RiskMultiplier      = 1.0;       // Lot multiplier (Slave lot = Master lot x mult)
input bool       AutoLotScaling      = true;      // Auto-scale lots by point value (contract size differences)
input int        Slippage            = 10;        // Allowed slippage (points)
input long       MagicNumber         = 987654;    // Magic Number of the Slave orders

input group "=== PROPAGATION (set the same on Master and Slaves) ==="
input bool PropagateSlaveClose = true; // Slave closes AND trading locks propagate to the Master

input group "=== MULTI-ACCOUNT SAFETY (MASTER mode only) ==="
input int ExpectedSlaves           = 0;  // Fresh Slave heartbeats required for new entries; 0 = off
input int SlaveHeartbeatTimeoutSec = 15; // Slave heartbeat considered stale after (seconds)

input group "=== LOGGING ==="
input bool TradePairLog = true; // Per-account trade log (<syncfile>.trades.<login>.csv) for hedge reconciliation

// The guardian below runs in BOTH modes. On the Master it gates the order-placing
// EA (global variable + deletes pendings) and closes positions on breach. On a
// Slave it does the same on its own account and, with PropagateSlaveClose=true,
// reports its lock to the Master: the Master only accepts new orders while EVERY
// account (Master and all Slaves) has trading enabled. Slave breaches that close
// positions also close the originals on the Master (and so on every other Slave).
input group "=== EQUITY LIMITS ==="
input double DailyProfitLimitPercent = 4.6; // Daily profit limit (%); 0 = no limit
input double DailyLossLimitPercent   = 4.6; // Daily loss limit (%); 0 = no limit
input double TotalProfitLimitPercent = 8.1; // Total profit limit (%); 0 = no limit
input double TotalLossLimitPercent   = 8.1; // Total loss limit (%); 0 = no limit

input group "=== TRADING LIMITS ==="
input int    MaxParallelTrades      = 1; // Parallel trades limit; 0 = no limit
input int    MaxTradesPerDay        = 1; // Trades per day limit; 0 = no limit
input int    MaxConsecLossesPerDay  = 0; // Consecutive losses per day limit; 0 = no limit
input int    MaxConsecWinsPerDay    = 0; // Consecutive wins per day limit; 0 = no limit

input group "=== DAILY RESET ==="
input int    DailyResetHour   = 0; // Daily reset hour (0-23)
input int    DailyResetMinute = 0; // Daily reset minute (0-59)

input group "=== TRADING HOURS ==="
input bool   LimitTradingHours  = true; // Limit new entries to the specified hours
input int    TradingStartHour   = 6;    // Trading start hour (0-23)
input int    TradingStartMinute = 0;    // Trading start minute (0-59)
input int    TradingEndHour     = 20;   // Trading end hour (0-23)
input int    TradingEndMinute   = 0;    // Trading end minute (0-59)

input group "=== FORCED CLOSE ==="
input bool   ForceExitEnabled = true; // Force close at the specified time
input int    TradingExitHour   = 22;  // Forced close hour (0-23)
input int    TradingExitMinute = 0;   // Forced close minute (0-59)

input group "=== NEWS PROTECTION ==="
input HCNewsMode   NewsMode       = NEWS_OPERATE;   // News handling mode
input int          NewsDuration   = 120;            // Protection before and after (seconds)
input string       NewsCurrencies = "";             // Currencies to watch (e.g. EUR,USD,GBP); empty = chart symbol
input HCNewsImpact NewsMinImpact  = NEWS_IMP_HIGH;  // Minimum impact to consider

//===================================================================
// GLOBAL VARIABLES (keys)
//===================================================================
string HCPROPS_KEY    = "HCPropsController";
string GV_DISABLE     = "HCPropsControllerDisableTrading"; // signal respected by patched SQX EAs
string GV_TOTAL_LOCK  = "HCPropsController_TotalLocked";
string GV_DAILY_LOCK  = "HCPropsController_DailyLocked";
string GV_INIT_BAL    = "HCPropsController_InitBalance";
string GV_INIT_EQD    = "HCPropsController_InitEquityDaily";
string GV_NEXT_RESET  = "HCPropsController_NextReset";

//===================================================================
// TRADING HELPERS (global lock signal)
//===================================================================
void DisableTrading()    { GlobalVariableSet(GV_DISABLE, 1.0); }
void EnableTrading()     { GlobalVariableDel(GV_DISABLE); }
bool TradingIsDisabled() { return(GlobalVariableCheck(GV_DISABLE) && GlobalVariableGet(GV_DISABLE) == 1.0); }

string ModeName() { return (Mode == MODE_MASTER ? "MASTER" : (Mode == MODE_SLAVE ? "SLAVE" : "NONE")); }

//===================================================================
// RUNTIME STATE
//===================================================================
double   AccountDepositsAndWithdrawals = 0.0; // initial balance (reference for total %)
double   InitialEquityDaily            = 0.0;
datetime NextDailyResetTime            = 0;
datetime NextForceExitTime             = 0;

double DailyUpperLimitEquity = 0.0;
double DailyLowerLimitEquity = 0.0;
double TotalUpperLimitEquity = 0.0;
double TotalLowerLimitEquity = 0.0;

int TradesOpenedToday   = 0;
int CurrentTradesCount  = 0;
int ConsecutiveWinsToday   = 0;
int ConsecutiveLossesToday = 0;

// Lock flags
bool IsGlobalTradingDisabled    = false; // total limit (sticky until ResetCountersOnInit)
bool IsDailyLimitTradingDisabled= false; // daily equity limit (sticky until daily reset)
bool IsDailyNumberTradingDisabled = false;
bool IsParallelTradesDisabled   = false;
bool IsTradingHoursDisabled     = false;
bool IsConsecWinsDisabled       = false;
bool IsConsecLossesDisabled     = false;
bool IsNewsBlocked              = false;
bool TotalLocked                = false; // persistent state of the total lock
bool DidCloseOrders             = false;
bool DidClosePositions          = false;

// Lock + heartbeat propagation (Slave guardian -> Master)
bool   IsSlaveLockTradingDisabled = false; // MASTER: some Slave reports trading disabled
bool   IsSlaveDownTradingDisabled = false; // MASTER: fewer fresh Slave heartbeats than ExpectedSlaves
string g_slaveLockInfo            = "";    // MASTER: which Slave(s)/reason(s), for log + panel
string g_slaveDownInfo            = "";    // MASTER: heartbeat summary, for log + panel
int    g_slvFreshCount            = 0;     // MASTER: Slaves with a fresh heartbeat

// MASTER: cached per-Slave status (survives torn reads of a status file)
string   g_slvLogin[];
datetime g_slvHb[];      // heartbeat stamp (TimeLocal of the Slave = same machine clock)
bool     g_slvLocked[];
string   g_slvReason[];

// SLAVE: status file state
bool g_statusDirty   = true;  // a write is pending (new close request / failed write)
bool g_lastLockState = false; // last lock state written (for transition logging)

// Dashboard
string LastDashboardValues[];
bool   DashboardNeedsUpdate = true;

// Synchronization
string   LastPositionsHash   = "";
bool     SyncFileInitialized = false;
bool     MasterFileExists    = false;
bool     SlaveWarningShown   = false;
ulong    g_syncSeq           = 0;  // Master: write sequence (monotonic across EA restarts)
int      g_timerTick         = 0;  // 200 ms timer tick counter (every 5th = ~1 s work)

// News (cache)
datetime g_newsTimes[];
string   g_newsCurr[];
string   g_newsName[];
datetime g_lastNewsFetch  = 0;
string   g_activeNews     = "";
datetime g_activeNewsEnd  = 0; // end of the currently active protection window

//===================================================================
// MODULES
//===================================================================
#include "HCProps_Util.mqh"
#include "HCProps_Guardian.mqh"
#include "HCProps_News.mqh"
#include "HCProps_Master.mqh"
#include "HCProps_Slave.mqh"
#include "HCProps_Panel.mqh"

//===================================================================
// INIT
//===================================================================
int OnInit()
  {
   Print("HCPropsController v2 initialized. Mode: ", ModeName());

   // Time-range validations (the guardian runs in BOTH modes)
   if(DailyResetHour < 0 || DailyResetHour > 23 || DailyResetMinute < 0 || DailyResetMinute > 59)
     { Print("ERROR: Daily reset out of range"); return INIT_PARAMETERS_INCORRECT; }
   if(LimitTradingHours &&
      (TradingStartHour < 0 || TradingStartHour > 23 || TradingStartMinute < 0 || TradingStartMinute > 59 ||
       TradingEndHour   < 0 || TradingEndHour   > 23 || TradingEndMinute   < 0 || TradingEndMinute   > 59))
     { Print("ERROR: Trading hours out of range"); return INIT_PARAMETERS_INCORRECT; }
   if(ForceExitEnabled &&
      (TradingExitHour < 0 || TradingExitHour > 23 || TradingExitMinute < 0 || TradingExitMinute > 59))
     { Print("ERROR: Forced close out of range"); return INIT_PARAMETERS_INCORRECT; }
   if(NewsMode != NEWS_OPERATE && NewsDuration < 0)
     { Print("ERROR: NewsDuration must be >= 0"); return INIT_PARAMETERS_INCORRECT; }
   if(ExpectedSlaves < 0)
     { Print("ERROR: ExpectedSlaves must be >= 0"); return INIT_PARAMETERS_INCORRECT; }
   if(ExpectedSlaves > 0 && SlaveHeartbeatTimeoutSec < 5)
     { Print("ERROR: SlaveHeartbeatTimeoutSec must be >= 5"); return INIT_PARAMETERS_INCORRECT; }
   if(HistoryFromDate > 0)
     {
      if(HistoryFromDate > TimeCurrent())
        { Print("ERROR: HistoryFromDate is in the future"); return INIT_PARAMETERS_INCORRECT; }
      Print("HistoryFromDate active: ignoring account history before ",
            TimeToString(HistoryFromDate, TIME_DATE | TIME_SECONDS),
            " (initial balance = balance as of that moment)");
     }

   // SLAVE validation: needs a shared file name to read from
   if(Mode == MODE_SLAVE)
     {
      if(FileName == "" && CustomFilePath == "")
        {
         Print("ERROR: In SLAVE mode set FileName (must match the Master's FileName), or CustomFilePath");
         return INIT_PARAMETERS_INCORRECT;
        }
     }

   // The per-ticket replication model needs a hedging account.
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      if(Mode == MODE_SLAVE)
        {
         Print("ERROR: SLAVE mode requires a HEDGING account (per-ticket mapping breaks on netting accounts).");
         return INIT_PARAMETERS_INCORRECT;
        }
      Print("WARNING: this account is not HEDGING - per-ticket replication may misbehave on netting accounts.");
     }

   // MASTER: refuse a second Master instance on the same FileName in this terminal.
   if(Mode == MODE_MASTER)
     {
      long other = GlobalVariableCheck(MasterMutexGVName()) ? (long)GlobalVariableGet(MasterMutexGVName()) : 0;
      if(other != 0 && other != ChartID() && ChartPeriod(other) > 0)
        {
         Print("ERROR: another MASTER (chart ", other, ") already serves '", SyncFileLabel(),
               "' in this terminal. Remove one of them (or use a different FileName).");
         return INIT_PARAMETERS_INCORRECT;
        }
      GlobalVariableSet(MasterMutexGVName(), (double)ChartID());
     }

   if(Mode != MODE_NONE)
      CleanupLegacySideFiles(); // v2.20 .close.*/.lock.* files are replaced by .slave.<login>

   CalculateAccountDepositsAndWithdrawals();

   // ---- Guardian init (both modes; on the Slave it protects its own account) ----
   // Reset persistent state if requested
   if(ResetCountersOnInit)
     {
      GlobalVariableDel(GV_TOTAL_LOCK);
      GlobalVariableDel(GV_DAILY_LOCK);
      GlobalVariableDel(GV_INIT_BAL);
      GlobalVariableDel(GV_INIT_EQD);
      GlobalVariableDel(GV_NEXT_RESET);
      // An inputs-change reinit keeps the program's globals alive: clear the
      // in-memory latches too, or PersistState() below would write the stale
      // lock straight back into the GlobalVariables.
      TotalLocked = false;
      IsGlobalTradingDisabled = false;
      IsDailyLimitTradingDisabled = false;
      DidCloseOrders = false;
      DidClosePositions = false;
      EnableTrading();
      Print("ResetCountersOnInit: state cleared");
     }

   // Restore baseline + locks from GlobalVariables (survives restarts/VPS crashes)
   bool restored = false;
   if(PropFirmMode && !ResetCountersOnInit && GlobalVariableCheck(GV_INIT_BAL))
     {
      if(GlobalVariableGet(GV_INIT_BAL) > 0)
         AccountDepositsAndWithdrawals = GlobalVariableGet(GV_INIT_BAL);
      InitialEquityDaily = GlobalVariableGet(GV_INIT_EQD);
      NextDailyResetTime = (datetime)GlobalVariableGet(GV_NEXT_RESET);
      TotalLocked = (GlobalVariableCheck(GV_TOTAL_LOCK) && GlobalVariableGet(GV_TOTAL_LOCK) == 1.0);
      IsDailyLimitTradingDisabled = (GlobalVariableCheck(GV_DAILY_LOCK) && GlobalVariableGet(GV_DAILY_LOCK) == 1.0);
      restored = (InitialEquityDaily > 0 && NextDailyResetTime > 0);
      if(restored)
         Print("State restored from GlobalVariables. TotalLocked=", TotalLocked, " InitEquityDaily=", InitialEquityDaily);
     }

   if(!restored)
     {
      CalculateInitialEquityDaily();
      CalculateNextDailyResetTime();
     }

   CalculateTotalLimits();
   CalculateDailyLimits();
   if(ForceExitEnabled)
      CalculateNextForceExitTime();

   Sleep(100);
   CountTradesOpenedToday();
   CountCurrentTrades();
   CountConsecutiveWinsLosses();

   // If the reset time passed while the EA was off, reset now
   if(restored && TimeCurrent() >= NextDailyResetTime)
      PerformDailyReset();

   PersistState();

   if(PropFirmMode)
      CheckGuardRules();
   CheckNews();

   Print(ModeName(), " OnInit: PropFirmMode=", PropFirmMode,
         " TradesToday=", TradesOpenedToday, "/", MaxTradesPerDay);

   // 200 ms timer: fast Slave reaction / close-request processing.
   // Heavy 1-second work runs on every 5th tick (see OnTimer).
   EventSetMillisecondTimer(200);

   ArrayResize(LastDashboardValues, 64);
   for(int i = 0; i < 64; i++)
      LastDashboardValues[i] = "";
   DashboardNeedsUpdate = true;
   CreateDashboard();

   if(Mode == MODE_MASTER)
     {
      Sleep(50);
      LastPositionsHash = "";
      SyncFileInitialized = false;
      Print("OnInit: syncing initial positions. Positions: ", PositionsTotal());
      SyncPositionsToFile();
     }
   else if(Mode == MODE_SLAVE)
     {
      string rel = GetSyncFilePath();
      MasterFileExists = FileIsExist(rel, FILE_COMMON);
      if(MasterFileExists)
         Print("SLAVE: Master file found: ", rel);
      else
        {
         Print("SLAVE: Master file NOT found on start: ", rel);
         Print("SLAVE: check that FileName matches the Master's FileName exactly.");
         SlaveWarningShown = true;
        }
      WriteSlaveStatusFile(); // publish heartbeat + lock state right away
     }
   // MODE_NONE: guardian only - no shared files of any kind

   return INIT_SUCCEEDED;
  }

//===================================================================
// TIMER
//===================================================================
void OnTimer()
  {
   g_timerTick++;
   bool fullTick = (g_timerTick % 5 == 0); // timer runs at 200 ms; ~1 s cadence for heavy work

   // ---- every 200 ms: the fast paths ----
   if(Mode == MODE_MASTER)
      ProcessSlaveStatusFiles();  // close requests + lock flags + heartbeats
   else if(Mode == MODE_SLAVE)
     {
      SlaveSync();                // replicate / reconcile
      if(g_statusDirty)
         WriteSlaveStatusFile();  // pending close requests / failed write retry
     }

   // Equity limits react to fast spikes: check at the full 200 ms cadence.
   if(PropFirmMode)
     {
      CheckEquityLimits();
      CheckAndUpdateTradingStatus();
     }

   if(!fullTick)
      return;

   // ---- ~1 s: guardian, news, status propagation, dashboard (both modes) ----
   if(PropFirmMode)
     {
      if(TimeCurrent() >= NextDailyResetTime)
         PerformDailyReset();

      if(ForceExitEnabled && NextForceExitTime > 0 && TimeCurrent() >= NextForceExitTime)
        {
         if(Mode == MODE_SLAVE && PropagateSlaveClose)
           {
            EnqueueAllReplicatedCloses("FORCE_EXIT"); // flatten the Master legs too
            WriteSlaveStatusFile();
           }
         CloseAllPositions(true);
         CalculateNextForceExitTime();
         Print("Forced close executed. Next: ", TimeToString(NextForceExitTime));
        }

      CheckGuardRules();
     }

   CheckNews();        // also manages trading state when PropFirmMode=false

   if(Mode == MODE_MASTER)
      SyncPositionsToFile();
   else if(Mode == MODE_SLAVE)
      WriteSlaveStatusFile(); // heartbeat (and lock/close lines) refresh

   // Housekeeping: keep the per-ticket throttle/warn arrays bounded.
   PruneThrottle(g_openTryTicket, g_openTryWhenMs, 600000);
   PruneThrottle(g_closeTryTicket, g_closeTryWhenMs, 600000);
   PruneThrottle(g_ackLogTicket, g_ackLogWhenMs, 600000);
   if(Mode == MODE_SLAVE)
      PruneMapGVs();
   else if(Mode == MODE_MASTER)
      PruneWarnedExcluded();

   UpdateDashboard();
  }

//===================================================================
// TRADE DETECTION ON MASTER
//===================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      HistorySelect(0, TimeCurrent());
      bool ok = HistoryDealSelect(trans.deal);
      int retry = 0;
      while(!ok && retry < 3) { Sleep(10); HistorySelect(0, TimeCurrent()); ok = HistoryDealSelect(trans.deal); retry++; }

      // Counters feed the guardian in BOTH modes
      if(ok)
        {
         CDealInfo deal; deal.Ticket(trans.deal);
         if(deal.Entry() == DEAL_ENTRY_IN)
            CountTradesOpenedToday();
         else if(deal.Entry() == DEAL_ENTRY_OUT)
           {
            Sleep(10);
            CountConsecutiveWinsLosses();
            DashboardNeedsUpdate = true;
           }
        }
      else
         CountTradesOpenedToday();

      CountCurrentTrades();
      if(PropFirmMode)
         CheckGuardRules();

      if(ok && Mode != MODE_NONE)
         LogClosedDeal(trans.deal); // hedge-reconciliation trade log (no shared files in NONE)

      if(Mode == MODE_MASTER)
         SyncPositionsToFile();
      else if(Mode == MODE_SLAVE && ok)
         SlavePropagateCloseFromDeal(trans.deal);
     }

   if(trans.type == TRADE_TRANSACTION_POSITION && Mode == MODE_MASTER)
      SyncPositionsToFile();
  }

// SLAVE: when our own SL/TP (or a manual close / stop out) closes a mirrored
// position while the Master still holds it, ask the Master to close it too,
// so the Master and every other Slave flatten immediately.
void SlavePropagateCloseFromDeal(ulong dealTicket)
  {
   if(!PropagateSlaveClose)
      return;
   if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != MagicNumber)
      return;
   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;
   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON);
   // DEAL_REASON_EXPERT = our own sync/guardian close (already propagated or Master-initiated).
   bool propagate = (reason == DEAL_REASON_SL || reason == DEAL_REASON_TP || reason == DEAL_REASON_SO ||
                     reason == DEAL_REASON_CLIENT || reason == DEAL_REASON_MOBILE || reason == DEAL_REASON_WEB);
   if(!propagate)
      return;

   ulong posId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   if(posId == 0)
      return;
   if(PositionSelectByTicket(posId))
      return; // partial close: the position is still open, keep mirroring

   ulong mTicket = MasterTicketForSlavePosition(posId);
   if(mTicket == 0)
      return;

   string rs = (reason == DEAL_REASON_SL ? "SL" :
                reason == DEAL_REASON_TP ? "TP" :
                reason == DEAL_REASON_SO ? "STOPOUT" : "MANUAL");
   Print("SLAVE: mirrored position closed by ", rs, " -> requesting Master close of #", mTicket);
   EnqueueMasterClose(mTicket, rs);
   WriteSlaveStatusFile(); // get the request on disk immediately
  }

//===================================================================
// DEINIT
//===================================================================
void OnDeinit(const int reason)
  {
   EventKillTimer();
   DeleteDashboard();

   if(Mode == MODE_MASTER)
     {
      // We do not force EnableTrading here to avoid lifting a limit lock on a mere recompile.
      // Delete the sync file so Slaves detect the disconnection.
      string rel = GetSyncFilePath();
      if(FileIsExist(rel, FILE_COMMON))
         FileDelete(rel, FILE_COMMON);

      // If the EA is removed for good (not a recompile), release the lock signal
      // and the one-Master-per-file mutex.
      if(reason == REASON_REMOVE || reason == REASON_CHARTCLOSE)
        {
         EnableTrading();
         if(GlobalVariableCheck(MasterMutexGVName()) &&
            (long)GlobalVariableGet(MasterMutexGVName()) == ChartID())
            GlobalVariableDel(MasterMutexGVName());
        }
     }
   else if(Mode == MODE_SLAVE)
     {
      // Removed for good: take this Slave out of the system (its status file is
      // the Master's heartbeat/lock source). On a mere recompile/restart the file
      // stays put; the heartbeat goes briefly stale and refreshes on re-init.
      // NOTE: with ExpectedSlaves > 0 on the Master, removing a Slave makes the
      // Master block new entries until ExpectedSlaves is adjusted - intended.
      if(reason == REASON_REMOVE || reason == REASON_CHARTCLOSE)
        {
         string st = SlaveStatusPath();
         if(FileIsExist(st, FILE_COMMON))
            FileDelete(st, FILE_COMMON);
         EnableTrading();
        }
     }
   else // NONE: nothing on disk to clean up; just release the lock signal on removal
     {
      if(reason == REASON_REMOVE || reason == REASON_CHARTCLOSE)
         EnableTrading();
     }
  }
//+------------------------------------------------------------------+
