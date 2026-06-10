//+------------------------------------------------------------------+
//|                                            HCPropsController.mq5 |
//|  Copy-trading (Master/Slave) + prop-firm guardian + news filter  |
//|  Single EA, file-based sync on the same VPS. No backend/license. |
//+------------------------------------------------------------------+
#property strict
#property version "2.10"
#property description "HCPropsController: Master/Slave copy trading, prop-firm limits and news filter in a single EA."
#property description "v2.10: sequence-stamped sync file v2 (point value, torn-read safe), auto lot scaling,"
#property description "200 ms reaction, and Slave->Master close propagation."

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
   MODE_MASTER = 0, // Master (executes trades)
   MODE_SLAVE  = 1  // Slave (replicates trades)
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
input HCMode Mode                 = MODE_MASTER; // Operation mode
input bool   PropFirmMode         = true;        // Enable limits guardian (MASTER only)
input double ForceInitialBalance  = 0.0;         // Force initial balance (0 = auto-detect)
input bool   ResetCountersOnInit  = false;       // Reset counters and locks on init (MASTER only)

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
input double     SlaveTotalProfitLimitPercent = 0.0; // Slave total profit limit (%); 0 = none

input group "=== CLOSE PROPAGATION (Master and Slave) ==="
input bool PropagateSlaveClose = true; // Slave close (SL/TP/manual/lock) also closes the Master position

input group "=== EQUITY LIMITS (MASTER mode only) ==="
input double DailyProfitLimitPercent = 4.6; // Daily profit limit (%); 0 = no limit
input double DailyLossLimitPercent   = 4.6; // Daily loss limit (%); 0 = no limit
input double TotalProfitLimitPercent = 8.1; // Total profit limit (%); 0 = no limit
input double TotalLossLimitPercent   = 8.1; // Total loss limit (%); 0 = no limit

input group "=== TRADING LIMITS (MASTER mode only) ==="
input int    MaxParallelTrades      = 1; // Parallel trades limit; 0 = no limit
input int    MaxTradesPerDay        = 1; // Trades per day limit; 0 = no limit
input int    MaxConsecLossesPerDay  = 0; // Consecutive losses per day limit; 0 = no limit
input int    MaxConsecWinsPerDay    = 0; // Consecutive wins per day limit; 0 = no limit

input group "=== DAILY RESET (MASTER mode only) ==="
input int    DailyResetHour   = 0; // Daily reset hour (0-23)
input int    DailyResetMinute = 0; // Daily reset minute (0-59)

input group "=== TRADING HOURS (MASTER mode only) ==="
input bool   LimitTradingHours  = true; // Limit new entries to the specified hours
input int    TradingStartHour   = 6;    // Trading start hour (0-23)
input int    TradingStartMinute = 0;    // Trading start minute (0-59)
input int    TradingEndHour     = 20;   // Trading end hour (0-23)
input int    TradingEndMinute   = 0;    // Trading end minute (0-59)

input group "=== FORCED CLOSE (MASTER mode only) ==="
input bool   ForceExitEnabled = true; // Force close at the specified time
input int    TradingExitHour   = 22;  // Forced close hour (0-23)
input int    TradingExitMinute = 0;   // Forced close minute (0-59)

input group "=== NEWS PROTECTION (MASTER mode only) ==="
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

// Slave
bool SlaveProfitLocked = false;

// Dashboard
string LastDashboardValues[];
bool   DashboardNeedsUpdate = true;

// Synchronization
string   LastPositionsHash   = "";
bool     SyncFileInitialized = false;
bool     MasterFileExists    = false;
int      LastSlaveDay        = -1;
bool     SlaveWarningShown   = false;
ulong    g_syncSeq           = 0;  // Master: write sequence (monotonic across EA restarts)
int      g_timerTick         = 0;  // 200 ms timer tick counter (every 5th = ~1 s work)

// News (cache)
datetime g_newsTimes[];
string   g_newsCurr[];
string   g_newsName[];
datetime g_lastNewsFetch = 0;
string   g_activeNews    = "";

//===================================================================
// SYNCED POSITION STRUCTURE
//===================================================================
struct SyncPos
  {
   ulong    ticket;
   string   symbol;
   int      type;      // 0 = BUY, 1 = SELL (ENUM_POSITION_TYPE)
   double   volume;    // real Master lots
   double   openPrice;
   double   sl;
   double   tp;
   datetime openTime;
  };

//+------------------------------------------------------------------+
//| String utilities                                                 |
//+------------------------------------------------------------------+
// Is 'symbol' in the CSV 'list'? (empty list = all)
bool SymbolInList(string symbol, string list)
  {
   StringTrimLeft(list); StringTrimRight(list);
   if(list == "")
      return true;
   string items[];
   int n = StringSplit(list, ',', items);
   for(int i = 0; i < n; i++)
     {
      StringTrimLeft(items[i]); StringTrimRight(items[i]);
      if(items[i] == symbol)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Sync file path (relative to Common\Files)                        |
//+------------------------------------------------------------------+
// The shared file is identified purely by FileName (or CustomFilePath).
// Master and Slave use the same value, so both resolve to the same file.
string GetSyncFilePath()
  {
   if(CustomFilePath != "")
      return CustomFilePath;
   return HCPROPS_KEY + "\\" + FileName;
  }

// Human-friendly name for the panel.
string SyncFileLabel()
  {
   return (CustomFilePath != "") ? CustomFilePath : FileName;
  }

//===================================================================
// INIT
//===================================================================
int OnInit()
  {
   Print("HCPropsController v2 initialized. Mode: ", (Mode == MODE_MASTER ? "MASTER" : "SLAVE"));

   // Time-range validations (MASTER)
   if(Mode == MODE_MASTER)
     {
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

   CalculateAccountDepositsAndWithdrawals();

   if(Mode == MODE_MASTER)
     {
      // Reset persistent state if requested
      if(ResetCountersOnInit)
        {
         GlobalVariableDel(GV_TOTAL_LOCK);
         GlobalVariableDel(GV_DAILY_LOCK);
         GlobalVariableDel(GV_INIT_BAL);
         GlobalVariableDel(GV_INIT_EQD);
         GlobalVariableDel(GV_NEXT_RESET);
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

      Print("MASTER OnInit: PropFirmMode=", PropFirmMode, " TradesToday=", TradesOpenedToday, "/", MaxTradesPerDay);
     }
   else // SLAVE
     {
      CalculateInitialEquityDailySlave();
      MqlDateTime ct; TimeToStruct(TimeCurrent(), ct);
      LastSlaveDay = ct.day;
      CalculateTotalLimits();
      CalculateDailyLimits();
     }

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
   else
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
     }

   return INIT_SUCCEEDED;
  }

//===================================================================
// STATE PERSISTENCE (GlobalVariables)
//===================================================================
void PersistState()
  {
   if(Mode != MODE_MASTER || !PropFirmMode)
      return;
   GlobalVariableSet(GV_INIT_BAL,   AccountDepositsAndWithdrawals);
   GlobalVariableSet(GV_INIT_EQD,   InitialEquityDaily);
   GlobalVariableSet(GV_NEXT_RESET, (double)NextDailyResetTime);
   GlobalVariableSet(GV_TOTAL_LOCK, TotalLocked ? 1.0 : 0.0);
   GlobalVariableSet(GV_DAILY_LOCK, IsDailyLimitTradingDisabled ? 1.0 : 0.0);
  }

//===================================================================
// DEPOSITS AND WITHDRAWALS (initial balance)
//===================================================================
void CalculateAccountDepositsAndWithdrawals()
  {
   if(ForceInitialBalance > 0.0)
     {
      AccountDepositsAndWithdrawals = ForceInitialBalance;
      return;
     }
   AccountDepositsAndWithdrawals = 0.0;
   if(!HistorySelect(0, TimeCurrent()))
      return;
   int total = HistoryDealsTotal();
   CDealInfo deal;
   for(int i = 0; i < total; i++)
     {
      if(!deal.SelectByIndex(i))
         continue;
      if(deal.DealType() == DEAL_TYPE_BALANCE || deal.DealType() == DEAL_TYPE_CREDIT || deal.DealType() == DEAL_TYPE_CHARGE)
         AccountDepositsAndWithdrawals += deal.Profit();
     }
  }

//===================================================================
// DAILY INITIAL EQUITY (MASTER, per reset time)
//===================================================================
void CalculateInitialEquityDaily()
  {
   MqlDateTime ct; TimeToStruct(TimeCurrent(), ct);
   ct.hour = DailyResetHour; ct.min = DailyResetMinute; ct.sec = 0;
   datetime todayReset = StructToTime(ct);
   datetime lastReset  = (TimeCurrent() >= todayReset) ? todayReset : todayReset - 86400;

   CAccountInfo acc;
   double currentBalance = acc.Balance();
   if(!HistorySelect(lastReset + 1, TimeCurrent()))
     { InitialEquityDaily = AccountDepositsAndWithdrawals; return; }

   int total = HistoryDealsTotal();
   double change = 0.0;
   CDealInfo deal;
   for(int i = 0; i < total; i++)
      if(deal.SelectByIndex(i))
         change += deal.Profit() + deal.Commission() + deal.Swap();

   InitialEquityDaily = currentBalance - change;
   if(InitialEquityDaily <= 0.0 && currentBalance > 0.0 && AccountDepositsAndWithdrawals > 0.0)
      InitialEquityDaily = currentBalance;
  }

//===================================================================
// DAILY INITIAL EQUITY (SLAVE, midnight)
//===================================================================
void CalculateInitialEquityDailySlave()
  {
   MqlDateTime ct; TimeToStruct(TimeCurrent(), ct);
   ct.hour = 0; ct.min = 0; ct.sec = 0;
   datetime midnight = StructToTime(ct);

   CAccountInfo acc;
   double currentBalance = acc.Balance();
   if(!HistorySelect(midnight + 1, TimeCurrent()))
     { InitialEquityDaily = AccountDepositsAndWithdrawals; return; }

   int total = HistoryDealsTotal();
   double change = 0.0;
   CDealInfo deal;
   for(int i = 0; i < total; i++)
      if(deal.SelectByIndex(i))
         change += deal.Profit() + deal.Commission() + deal.Swap();

   InitialEquityDaily = currentBalance - change;
   if(InitialEquityDaily <= 0.0 && currentBalance > 0.0 && AccountDepositsAndWithdrawals > 0.0)
      InitialEquityDaily = currentBalance;
  }

//===================================================================
// LIMITS
//===================================================================
void CalculateTotalLimits()
  {
   TotalUpperLimitEquity = (TotalProfitLimitPercent > 0) ? AccountDepositsAndWithdrawals * (1.0 + TotalProfitLimitPercent / 100.0) : 0.0;
   TotalLowerLimitEquity = (TotalLossLimitPercent   > 0) ? AccountDepositsAndWithdrawals * (1.0 - TotalLossLimitPercent   / 100.0) : 0.0;
  }

void CalculateDailyLimits()
  {
   double basis = MathMin(InitialEquityDaily, AccountDepositsAndWithdrawals);
   DailyUpperLimitEquity = (DailyProfitLimitPercent > 0) ? InitialEquityDaily + basis * DailyProfitLimitPercent / 100.0 : 0.0;
   DailyLowerLimitEquity = (DailyLossLimitPercent   > 0) ? InitialEquityDaily - basis * DailyLossLimitPercent   / 100.0 : 0.0;
  }

//===================================================================
// TRADE / STREAK COUNTERS
//===================================================================
datetime LastResetAnchor()
  {
   MqlDateTime ct; TimeToStruct(TimeCurrent(), ct);
   ct.hour = DailyResetHour; ct.min = DailyResetMinute; ct.sec = 0;
   datetime todayReset = StructToTime(ct);
   return (TimeCurrent() >= todayReset) ? todayReset : todayReset - 86400;
  }

void CountTradesOpenedToday()
  {
   TradesOpenedToday = 0;
   datetime from = LastResetAnchor();
   if(!HistorySelect(from, TimeCurrent() + 60))
      return;
   int total = HistoryDealsTotal();
   CDealInfo deal;
   for(int i = 0; i < total; i++)
     {
      if(!deal.SelectByIndex(i))
         continue;
      long dt = deal.DealType();
      if(deal.Entry() == DEAL_ENTRY_IN && (dt == DEAL_TYPE_BUY || dt == DEAL_TYPE_SELL))
         TradesOpenedToday++;
     }
  }

void CountCurrentTrades()
  {
   CurrentTradesCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) > 0)
         CurrentTradesCount++;
  }

void CountConsecutiveWinsLosses()
  {
   ConsecutiveWinsToday = 0;
   ConsecutiveLossesToday = 0;
   datetime from = LastResetAnchor();
   datetime to   = TimeCurrent() + 60;
   if(!HistorySelect(from, to))
      return;
   HistorySelect(0, TimeCurrent());
   HistorySelect(from, to);

   int total = HistoryDealsTotal();
   CDealInfo deal;
   double profits[];
   ArrayResize(profits, 0);
   for(int i = total - 1; i >= 0; i--)
     {
      if(!deal.SelectByIndex(i))
         continue;
      long dt = deal.DealType();
      if(deal.Entry() == DEAL_ENTRY_OUT && (dt == DEAL_TYPE_BUY || dt == DEAL_TYPE_SELL))
        {
         int sz = ArraySize(profits);
         ArrayResize(profits, sz + 1);
         profits[sz] = deal.Profit();
        }
     }
   int n = ArraySize(profits);
   if(n == 0)
      return;
   if(profits[0] > 0.0)
     {
      ConsecutiveWinsToday = 1;
      for(int i = 1; i < n; i++) { if(profits[i] > 0.0) ConsecutiveWinsToday++; else break; }
     }
   else if(profits[0] < 0.0)
     {
      ConsecutiveLossesToday = 1;
      for(int i = 1; i < n; i++) { if(profits[i] < 0.0) ConsecutiveLossesToday++; else break; }
     }
  }

void CalculateNextDailyResetTime()
  {
   MqlDateTime ct; TimeToStruct(TimeCurrent(), ct);
   ct.hour = DailyResetHour; ct.min = DailyResetMinute; ct.sec = 0;
   datetime today = StructToTime(ct);
   NextDailyResetTime = (TimeCurrent() >= today) ? today + 86400 : today;
  }

void CalculateNextForceExitTime()
  {
   MqlDateTime ct; TimeToStruct(TimeCurrent(), ct);
   ct.hour = TradingExitHour; ct.min = TradingExitMinute; ct.sec = 0;
   datetime today = StructToTime(ct);
   NextForceExitTime = (TimeCurrent() >= today) ? today + 86400 : today;
  }

//===================================================================
// FULL DAILY RESET
//===================================================================
void PerformDailyReset()
  {
   CAccountInfo acc;
   InitialEquityDaily = acc.Equity();
   CalculateNextDailyResetTime();
   CalculateDailyLimits();
   TradesOpenedToday = 0;
   ConsecutiveWinsToday = 0;
   ConsecutiveLossesToday = 0;
   IsDailyLimitTradingDisabled = false;
   IsDailyNumberTradingDisabled = false;
   IsConsecWinsDisabled = false;
   IsConsecLossesDisabled = false;
   GlobalVariableDel(GV_DAILY_LOCK);
   DashboardNeedsUpdate = true;
   PersistState();
   Print("Daily reset executed. InitialEquityDaily=", InitialEquityDaily, " (next: ", TimeToString(NextDailyResetTime), ")");
  }

//===================================================================
// TRADING STATE (enable/disable + closes)
//===================================================================
void CheckAndUpdateTradingStatus()
  {
   bool anyBlock = IsGlobalTradingDisabled || IsDailyLimitTradingDisabled || IsDailyNumberTradingDisabled ||
                   IsParallelTradesDisabled || IsTradingHoursDisabled || IsConsecWinsDisabled ||
                   IsConsecLossesDisabled || IsNewsBlocked;

   if(!anyBlock)
     {
      DidCloseOrders = false;
      DidClosePositions = false;
      EnableTrading();
      return;
     }

   DisableTrading();

   // Flatten EVERYTHING for: equity/total limits, consecutive win/loss streaks, or CLOSE_ALL news.
   bool closeActivePositions = IsGlobalTradingDisabled || IsDailyLimitTradingDisabled ||
                               IsConsecWinsDisabled || IsConsecLossesDisabled ||
                               (IsNewsBlocked && NewsMode == NEWS_CLOSE_ALL);

   if(!DidCloseOrders || (!DidClosePositions && closeActivePositions))
     {
      DidCloseOrders = true;
      if(closeActivePositions)
         DidClosePositions = true;
      CloseAllPositions(closeActivePositions);
     }

   // Parallel-trades limit: primarily block new entries; only close the NEWEST excess
   // position(s) when the open count actually exceeds the limit (avoids churn/fees when
   // the count merely equals the limit).
   if(IsParallelTradesDisabled && !closeActivePositions && MaxParallelTrades > 0)
     {
      int excess = CurrentTradesCount - MaxParallelTrades;
      if(excess > 0)
        {
         CloseNewestPositions(excess);
         CountCurrentTrades();
        }
     }
  }

void CheckTradingHours()
  {
   if(!LimitTradingHours)
     { IsTradingHoursDisabled = false; return; }
   MqlDateTime ct; TimeToStruct(TimeCurrent(), ct);
   int cur = ct.hour * 60 + ct.min;
   int s   = TradingStartHour * 60 + TradingStartMinute;
   int e   = TradingEndHour   * 60 + TradingEndMinute;
   bool outside;
   if(s <= e) outside = (cur < s || cur >= e);
   else       outside = (cur < s && cur >= e); // window crossing midnight
   IsTradingHoursDisabled = outside;
  }

//===================================================================
// GUARD RULES (only if PropFirmMode)
//===================================================================
void CheckGuardRules()
  {
   if(Mode != MODE_MASTER || !PropFirmMode)
      return;

   CAccountInfo acc;
   double eq = acc.Equity();

   // --- Total limit (sticky) ---
   bool totalBreach = (TotalUpperLimitEquity > 0 && eq >= TotalUpperLimitEquity) ||
                      (TotalLowerLimitEquity > 0 && eq <= TotalLowerLimitEquity);
   if(totalBreach || TotalLocked)
     {
      IsGlobalTradingDisabled = true;
      if(!TotalLocked)
        {
         TotalLocked = true;
         GlobalVariableSet(GV_TOTAL_LOCK, 1.0);
         Print("TOTAL limit reached (persistent lock until ResetCountersOnInit). Equity: ", eq);
        }
     }
   else
      IsGlobalTradingDisabled = false;

   // --- Daily equity limit (sticky until reset) ---
   if(DailyUpperLimitEquity > 0 && eq >= DailyUpperLimitEquity)
     {
      if(!IsDailyLimitTradingDisabled)
        { IsDailyLimitTradingDisabled = true; GlobalVariableSet(GV_DAILY_LOCK, 1.0);
          Print("Daily upper limit reached. Equity: ", eq); }
     }
   else if(DailyLowerLimitEquity > 0 && eq <= DailyLowerLimitEquity)
     {
      if(!IsDailyLimitTradingDisabled)
        { IsDailyLimitTradingDisabled = true; GlobalVariableSet(GV_DAILY_LOCK, 1.0);
          Print("Daily lower limit reached. Equity: ", eq); }
     }

   // --- Trades per day ---
   IsDailyNumberTradingDisabled = (MaxTradesPerDay > 0 && TradesOpenedToday >= MaxTradesPerDay);
   // --- Parallel trades ---
   IsParallelTradesDisabled = (MaxParallelTrades > 0 && CurrentTradesCount >= MaxParallelTrades);
   // --- Streaks ---
   IsConsecWinsDisabled   = (MaxConsecWinsPerDay   > 0 && ConsecutiveWinsToday   >= MaxConsecWinsPerDay);
   IsConsecLossesDisabled = (MaxConsecLossesPerDay > 0 && ConsecutiveLossesToday >= MaxConsecLossesPerDay);

   CheckTradingHours();
   CheckAndUpdateTradingStatus();
  }

//===================================================================
// NEWS
//===================================================================
int CurrencyList(string &out[])
  {
   string src = NewsCurrencies;
   StringTrimLeft(src); StringTrimRight(src);
   if(src == "")
     {
      // Derive from the chart symbol (base + profit currency)
      string base = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
      string prof = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
      ArrayResize(out, 0);
      if(base != "") { ArrayResize(out, ArraySize(out) + 1); out[ArraySize(out) - 1] = base; }
      if(prof != "" && prof != base) { ArrayResize(out, ArraySize(out) + 1); out[ArraySize(out) - 1] = prof; }
      return ArraySize(out);
     }
   int n = StringSplit(src, ',', out);
   for(int i = 0; i < n; i++) { StringTrimLeft(out[i]); StringTrimRight(out[i]); }
   return n;
  }

void FetchNewsMT5(datetime from, datetime to, string &curr[])
  {
   for(int c = 0; c < ArraySize(curr); c++)
     {
      MqlCalendarValue values[];
      int cnt = CalendarValueHistory(values, from, to, NULL, curr[c]);
      for(int i = 0; i < cnt; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev))
            continue;
         if((int)ev.importance < (int)NewsMinImpact)
            continue;
         int sz = ArraySize(g_newsTimes);
         ArrayResize(g_newsTimes, sz + 1);
         ArrayResize(g_newsCurr,  sz + 1);
         ArrayResize(g_newsName,  sz + 1);
         g_newsTimes[sz] = values[i].time;
         g_newsCurr[sz]  = curr[c];
         g_newsName[sz]  = ev.name;
        }
     }
  }

void FetchNews()
  {
   ArrayResize(g_newsTimes, 0);
   ArrayResize(g_newsCurr, 0);
   ArrayResize(g_newsName, 0);
   if(NewsMode == NEWS_OPERATE)
      return;

   string curr[];
   if(CurrencyList(curr) == 0)
     { Print("NEWS: no currencies to watch"); return; }

   datetime from = LastResetAnchor() - 86400;
   datetime to   = TimeCurrent() + 2 * 86400;

   FetchNewsMT5(from, to, curr);

   Print("NEWS: ", ArraySize(g_newsTimes), " news scheduled (impact>=", (int)NewsMinImpact, ")");
  }

// Returns true if we are inside the window of any news event
bool InNewsWindow()
  {
   g_activeNews = "";
   datetime now = TimeCurrent();
   for(int i = 0; i < ArraySize(g_newsTimes); i++)
     {
      if(now >= g_newsTimes[i] - NewsDuration && now <= g_newsTimes[i] + NewsDuration)
        {
         g_activeNews = g_newsCurr[i] + " " + g_newsName[i];
         return true;
        }
     }
   return false;
  }

void CheckNews()
  {
   if(Mode != MODE_MASTER)
      return;

   // Refresh the calendar once per hour (and on first startup)
   if(NewsMode != NEWS_OPERATE && (g_lastNewsFetch == 0 || TimeCurrent() - g_lastNewsFetch >= 3600))
     {
      FetchNews();
      g_lastNewsFetch = TimeCurrent();
     }

   bool wasBlocked = IsNewsBlocked;
   IsNewsBlocked = (NewsMode != NEWS_OPERATE) ? InNewsWindow() : false;

   if(IsNewsBlocked && !wasBlocked)
      Print("NEWS: entering protection window (", g_activeNews, ") - mode ", EnumToString(NewsMode));
   if(!IsNewsBlocked && wasBlocked)
      Print("NEWS: leaving news window. Trading re-enabled.");

   CheckAndUpdateTradingStatus();
  }

//===================================================================
// TIMER
//===================================================================
void OnTimer()
  {
   g_timerTick++;
   bool fullTick = (g_timerTick % 5 == 0); // timer runs at 200 ms; ~1 s cadence for heavy work

   if(Mode == MODE_MASTER)
     {
      ProcessCloseRequests(); // every tick: honor Slave close requests fast

      if(!fullTick)
         return;

      if(PropFirmMode)
        {
         if(TimeCurrent() >= NextDailyResetTime)
            PerformDailyReset();

         if(ForceExitEnabled && NextForceExitTime > 0 && TimeCurrent() >= NextForceExitTime)
           {
            CloseAllPositions(true);
            CalculateNextForceExitTime();
            Print("Forced close executed. Next: ", TimeToString(NextForceExitTime));
           }

         CheckGuardRules();
        }

      CheckNews();        // also manages trading state when PropFirmMode=false
      SyncPositionsToFile();
      UpdateDashboard();
     }
   else // SLAVE
     {
      if(fullTick)
        {
         MqlDateTime ct; TimeToStruct(TimeCurrent(), ct);
         if(LastSlaveDay != ct.day)
           {
            CalculateInitialEquityDailySlave();
            LastSlaveDay = ct.day;
            DashboardNeedsUpdate = true;
           }

         // Slave profit limit
         if(SlaveTotalProfitLimitPercent > 0 && !SlaveProfitLocked)
           {
            CAccountInfo acc;
            double cap = AccountDepositsAndWithdrawals * (1.0 + SlaveTotalProfitLimitPercent / 100.0);
            if(AccountDepositsAndWithdrawals > 0 && acc.Equity() >= cap)
              {
               SlaveProfitLocked = true;
               if(PropagateSlaveClose)
                  EnqueueAllReplicatedCloses("PROFIT_LOCK"); // Master (and the other Slaves) follow
               CloseAllPositions(true);
               Print("SLAVE: profit limit reached (", SlaveTotalProfitLimitPercent, "%). Replication stopped.");
              }
           }
        }

      if(!SlaveProfitLocked)
         SlaveSync();
      FlushCloseRequests(); // retried every tick until the request file is written
      if(fullTick)
         UpdateDashboard();
     }
  }

//===================================================================
// TRADE DETECTION ON MASTER
//===================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(Mode == MODE_MASTER)
     {
      if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
        {
         HistorySelect(0, TimeCurrent());
         bool ok = HistoryDealSelect(trans.deal);
         int retry = 0;
         while(!ok && retry < 3) { Sleep(10); HistorySelect(0, TimeCurrent()); ok = HistoryDealSelect(trans.deal); retry++; }

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
         SyncPositionsToFile();
        }

      if(trans.type == TRADE_TRANSACTION_POSITION)
         SyncPositionsToFile();
      return;
     }

   // ---- SLAVE: detect broker/user-initiated closes of mirrored positions ----
   // When the Slave's own SL/TP (or a manual close / stop out) closes a mirrored
   // position while the Master still holds it, ask the Master to close it too,
   // so the Master and every other Slave flatten immediately.
   if(!PropagateSlaveClose)
      return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   HistorySelect(0, TimeCurrent());
   bool ok = HistoryDealSelect(trans.deal);
   int retry = 0;
   while(!ok && retry < 3) { Sleep(10); HistorySelect(0, TimeCurrent()); ok = HistoryDealSelect(trans.deal); retry++; }
   if(!ok)
      return;

   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != MagicNumber)
      return;
   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;
   ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal, DEAL_REASON);
   // DEAL_REASON_EXPERT = our own sync close (Master already flat) -> never propagate.
   bool propagate = (reason == DEAL_REASON_SL || reason == DEAL_REASON_TP || reason == DEAL_REASON_SO ||
                     reason == DEAL_REASON_CLIENT || reason == DEAL_REASON_MOBILE || reason == DEAL_REASON_WEB);
   if(!propagate)
      return;

   ulong posId = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
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
   FlushCloseRequests();
  }

//===================================================================
// CLOSE POSITIONS / ORDERS
//===================================================================
void CloseAllPositions(bool closeActivePositions = false)
  {
   CTrade trade;
   trade.SetDeviationInPoints(Slippage);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
         trade.OrderDelete(ticket);
     }

   if(closeActivePositions)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0)
           {
            CPositionInfo p;
            if(p.SelectByTicket(ticket))
               trade.SetTypeFillingBySymbol(p.Symbol());
            trade.PositionClose(ticket);
           }
        }
     }
  }

// Close the 'howMany' most recently opened positions (used for the parallel-trades limit).
void CloseNewestPositions(int howMany)
  {
   if(howMany <= 0)
      return;

   ulong    tickets[];
   datetime times[];
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      CPositionInfo p;
      if(!p.SelectByTicket(ticket))
         continue;
      ArrayResize(tickets, n + 1);
      ArrayResize(times,   n + 1);
      tickets[n] = ticket;
      times[n]   = p.Time();
      n++;
     }

   // Sort by open time, newest first (selection sort; position counts are tiny).
   for(int i = 0; i < n - 1; i++)
      for(int j = i + 1; j < n; j++)
         if(times[j] > times[i])
           {
            datetime tt = times[i];   times[i]   = times[j];   times[j]   = tt;
            ulong    uu = tickets[i]; tickets[i] = tickets[j]; tickets[j] = uu;
           }

   int toClose = (howMany < n) ? howMany : n;
   CTrade trade;
   trade.SetDeviationInPoints(Slippage);
   for(int i = 0; i < toClose; i++)
     {
      CPositionInfo p;
      if(p.SelectByTicket(tickets[i]))
         trade.SetTypeFillingBySymbol(p.Symbol());
      trade.PositionClose(tickets[i]);
     }
   Print("Parallel-trades limit: closed ", toClose, " newest position(s) over the limit of ", MaxParallelTrades);
  }

//===================================================================
// SYMBOL MAPPING (format MAST:SLAV;MAST2:SLAV2)
//===================================================================
string MapSymbol(string masterSymbol)
  {
   string m = SymbolMapping;
   StringTrimLeft(m); StringTrimRight(m);
   if(m == "")
      return masterSymbol;
   string pairs[];
   int n = StringSplit(m, ';', pairs);
   for(int i = 0; i < n; i++)
     {
      string kv[];
      if(StringSplit(pairs[i], ':', kv) == 2)
        {
         StringTrimLeft(kv[0]); StringTrimRight(kv[0]);
         StringTrimLeft(kv[1]); StringTrimRight(kv[1]);
         if(kv[0] == masterSymbol)
            return kv[1];
        }
     }
   return masterSymbol;
  }

//===================================================================
// SYNCHRONIZATION: MASTER WRITES
//===================================================================
int GetSyncPositions(SyncPos &arr[])
  {
   ArrayResize(arr, 0);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      CPositionInfo p;
      if(!p.SelectByTicket(ticket))
         continue;
      if(!SymbolInList(p.Symbol(), Symbols))
         continue;
      int sz = ArraySize(arr);
      ArrayResize(arr, sz + 1);
      arr[sz].ticket    = ticket;
      arr[sz].symbol    = p.Symbol();
      arr[sz].type      = (int)p.PositionType();
      arr[sz].volume    = p.Volume();
      arr[sz].openPrice = p.PriceOpen();
      arr[sz].sl        = p.StopLoss();
      arr[sz].tp        = p.TakeProfit();
      arr[sz].openTime  = p.Time();
     }
   // Sort by ticket (stable order for the hash)
   int count = ArraySize(arr);
   for(int i = 0; i < count - 1; i++)
      for(int j = i + 1; j < count; j++)
         if(arr[i].ticket > arr[j].ticket)
           { SyncPos t = arr[i]; arr[i] = arr[j]; arr[j] = t; }
   return count;
  }

string PositionsHash()
  {
   SyncPos arr[];
   int n = GetSyncPositions(arr);
   string s = "";
   for(int i = 0; i < n; i++)
     {
      int dg = (int)SymbolInfoInteger(arr[i].symbol, SYMBOL_DIGITS);
      s += IntegerToString(arr[i].ticket) + "|" + arr[i].symbol + "|" + IntegerToString(arr[i].type) + "|" +
           DoubleToString(arr[i].volume, 2) + "|" + DoubleToString(arr[i].sl, dg) + "|" +
           DoubleToString(arr[i].tp, dg) + "\n";
     }
   return s;
  }

// Value (account currency) of a 1.0 price move per 1 lot. Lets the Slave
// equalize money-per-point when contract sizes differ between brokers.
double PointValuePerLot(string symbol)
  {
   double tv = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   return (tv > 0 && ts > 0) ? tv / ts : 0.0;
  }

// File format v2:
//   SEQ,<n>
//   ticket,symbol,type,volume,openPrice,sl,tp,openTime,pointValuePerLot
//   ...
//   END,<n>
// The SEQ/END pair detects both unchanged content (same seq) and torn reads
// (Slave reading while the Master rewrites): a file without a matching END
// is discarded and re-read on the next 200 ms tick.
bool WriteSyncFile()
  {
   string rel = GetSyncFilePath();

   // Ensure folder (Common\Files\HCPropsController)
   ResetLastError();
   FolderCreate(HCPROPS_KEY, FILE_COMMON); // if it already exists, returns error 5019 (ignored)

   if(g_syncSeq == 0)
      g_syncSeq = (ulong)GetTickCount64(); // survives EA restarts without repeating old values
   g_syncSeq++;

   ResetLastError();
   int h = FileOpen(rel, FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE, ',');
   int retry = 0;
   while(h == INVALID_HANDLE && retry < 2) { Sleep(10); ResetLastError(); h = FileOpen(rel, FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE, ','); retry++; }
   if(h == INVALID_HANDLE)
     { Print("ERROR: could not open sync file: ", rel, " err=", GetLastError()); return false; }

   FileWrite(h, "SEQ", IntegerToString((long)g_syncSeq));

   SyncPos arr[];
   int n = GetSyncPositions(arr);
   for(int i = 0; i < n; i++)
     {
      int dg = (int)SymbolInfoInteger(arr[i].symbol, SYMBOL_DIGITS);
      FileWrite(h,
                IntegerToString(arr[i].ticket),
                arr[i].symbol,
                IntegerToString(arr[i].type),
                DoubleToString(arr[i].volume, 2),
                DoubleToString(arr[i].openPrice, dg),
                DoubleToString(arr[i].sl, dg),
                DoubleToString(arr[i].tp, dg),
                IntegerToString((long)arr[i].openTime),
                DoubleToString(PointValuePerLot(arr[i].symbol), 5));
     }

   FileWrite(h, "END", IntegerToString((long)g_syncSeq));
   FileClose(h);
   return true;
  }

void SyncPositionsToFile()
  {
   if(Mode != MODE_MASTER)
      return;
   string h = PositionsHash();
   if(!SyncFileInitialized || h != LastPositionsHash)
     {
      if(WriteSyncFile())
        { LastPositionsHash = h; SyncFileInitialized = true; }
     }
  }

//===================================================================
// SYNCHRONIZATION: SLAVE READS AND REPLICATES (by Master ticket)
//===================================================================
struct TargetPos
  {
   ulong              masterTicket;
   string             symbol;     // symbol already mapped to the Slave
   ENUM_POSITION_TYPE dir;        // direction already inverted if applicable
   double             volume;     // normalized Slave lots
   double             rawVolume;  // requested lots before min/max/step normalization (clamp warning)
   double             slDist;     // SL offset from the Master entry, applied to the Slave's own fill price
   double             tpDist;     // TP offset from the Master entry, applied to the Slave's own fill price
   bool               hasSL;
   bool               hasTP;
   bool               matched;
  };

//===================================================================
// SYNC v2 STATE (cached targets, close propagation)
//===================================================================
ulong     g_lastSeqSeen = 0;     // last sequence successfully parsed by the Slave
bool      g_haveTargets = false; // at least one complete parse done (gate for reconciliation)
TargetPos g_targets[];           // cached Master targets, reconciled every 200 ms tick

// Slave position ticket -> Master ticket (rebuilt on every reconcile pass; used
// to identify which Master position a broker-side close belonged to)
ulong g_mapSlaveTicket[];
ulong g_mapMasterTicket[];

// Master tickets this Slave closed on its own (SL/TP/manual/lock). They are not
// reopened while the Master processes the close request; pruned when the ticket
// leaves the Master file, or after 120 s (Master unreachable / propagation off).
ulong    g_closedMasterTicket[];
datetime g_closedMasterWhen[];

// Pending close requests for the Master (flushed to <syncfile>.close.<login>)
ulong  g_closeReqTicket[];
string g_closeReqReason[];

// Per-ticket throttle: failed opens retry every ~1.5 s instead of every tick
ulong g_openTryTicket[];
ulong g_openTryWhenMs[];

double NormalizeVolume(string symbol, double vol)
  {
   CSymbolInfo si;
   if(!si.Name(symbol))
      return 0.0;
   si.RefreshRates();
   double mn = si.LotsMin();
   double mx = si.LotsMax();
   double st = si.LotsStep();
   if(st > 0)
      vol = MathFloor(vol / st + 0.5) * st;
   if(vol < mn) vol = mn;
   if(vol > mx) vol = mx;
   return vol;
  }

ulong ParseMasterTicketFromComment(string comment)
  {
   int pos = StringFind(comment, "HC");
   if(pos < 0)
      return 0;
   string digits = StringSubstr(comment, pos + 2);
   return (ulong)StringToInteger(digits);
  }

// Set SL/TP on the just-opened Slave position, measured as a distance from its
// ACTUAL fill price (so slippage / broker price differences don't change the stop distance).
void ApplySlaveLevels(CTrade &trade, ulong masterTicket, ENUM_POSITION_TYPE dir,
                      double slDist, double tpDist, bool hasSL, bool hasTP)
  {
   if(!hasSL && !hasTP)
      return;
   CPositionInfo p;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!p.SelectByIndex(i))
         continue;
      if((long)p.Magic() != MagicNumber)
         continue;
      if(ParseMasterTicketFromComment(p.Comment()) != masterTicket || p.PositionType() != dir)
         continue;
      CSymbolInfo si; si.Name(p.Symbol());
      int    dg    = (int)si.Digits();
      double entry = p.PriceOpen();
      double sl    = hasSL ? NormalizeDouble(entry + slDist, dg) : 0.0;
      double tp    = hasTP ? NormalizeDouble(entry + tpDist, dg) : 0.0;
      trade.SetTypeFillingBySymbol(p.Symbol());
      trade.PositionModify(p.Ticket(), sl, tp);
      return;
     }
  }

//-------------------------------------------------------------------
// Closed-ticket memory (Slave): tickets we closed on our own and asked
// the Master to close. Prevents the open-phase from re-opening them.
//-------------------------------------------------------------------
bool IsClosedMasterTicket(ulong mTicket)
  {
   for(int i = 0; i < ArraySize(g_closedMasterTicket); i++)
      if(g_closedMasterTicket[i] == mTicket)
         return true;
   return false;
  }

void RememberClosedMasterTicket(ulong mTicket)
  {
   if(IsClosedMasterTicket(mTicket))
      return;
   int n = ArraySize(g_closedMasterTicket);
   ArrayResize(g_closedMasterTicket, n + 1);
   ArrayResize(g_closedMasterWhen,   n + 1);
   g_closedMasterTicket[n] = mTicket;
   g_closedMasterWhen[n]   = TimeLocal();
  }

void PruneClosedMasterTickets()
  {
   for(int i = ArraySize(g_closedMasterTicket) - 1; i >= 0; i--)
     {
      bool inTargets = false;
      for(int t = 0; t < ArraySize(g_targets); t++)
         if(g_targets[t].masterTicket == g_closedMasterTicket[i])
           { inTargets = true; break; }
      // Gone from the Master file (processed), or stale for 120 s (Master off or
      // propagation disabled there) -> forget; mirroring resumes for that ticket.
      if(!inTargets || (TimeLocal() - g_closedMasterWhen[i] > 120))
        {
         if(inTargets)
            Print("SLAVE: Master did not process close request for #", g_closedMasterTicket[i], " in 120 s - resuming mirror");
         ArrayRemove(g_closedMasterTicket, i, 1);
         ArrayRemove(g_closedMasterWhen,   i, 1);
        }
     }
  }

//-------------------------------------------------------------------
// Close requests: Slave -> Master  (file <syncfile>.close.<login>)
//-------------------------------------------------------------------
string CloseRequestPath()
  {
   return GetSyncFilePath() + ".close." + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
  }

void EnqueueMasterClose(ulong mTicket, string reason)
  {
   if(mTicket == 0)
      return;
   for(int i = 0; i < ArraySize(g_closeReqTicket); i++)
      if(g_closeReqTicket[i] == mTicket)
         return;
   int n = ArraySize(g_closeReqTicket);
   ArrayResize(g_closeReqTicket, n + 1);
   ArrayResize(g_closeReqReason, n + 1);
   g_closeReqTicket[n] = mTicket;
   g_closeReqReason[n] = reason;
   RememberClosedMasterTicket(mTicket);
  }

void EnqueueAllReplicatedCloses(string reason)
  {
   CPositionInfo p;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!p.SelectByIndex(i))
         continue;
      if((long)p.Magic() != MagicNumber)
         continue;
      ulong mt = ParseMasterTicketFromComment(p.Comment());
      if(mt > 0)
         EnqueueMasterClose(mt, reason);
     }
  }

// Write the queued requests, merging any tickets the Master has not consumed
// yet. On any open failure we simply keep the queue and retry next tick.
void FlushCloseRequests()
  {
   if(Mode != MODE_SLAVE || ArraySize(g_closeReqTicket) == 0)
      return;

   string rel = CloseRequestPath();

   ulong  tk[]; string rs[];
   if(FileIsExist(rel, FILE_COMMON))
     {
      int hr = FileOpen(rel, FILE_READ | FILE_CSV | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE, ',');
      if(hr == INVALID_HANDLE)
         return; // Master is reading/deleting it right now -> retry next tick
      while(!FileIsEnding(hr))
        {
         string t = FileReadString(hr);
         if(StringLen(t) == 0)
            break;
         string r = FileIsLineEnding(hr) ? "" : FileReadString(hr);
         ulong v = (ulong)StringToInteger(t);
         if(v == 0)
            continue;
         int n = ArraySize(tk);
         ArrayResize(tk, n + 1); ArrayResize(rs, n + 1);
         tk[n] = v; rs[n] = r;
        }
      FileClose(hr);
     }

   for(int i = 0; i < ArraySize(g_closeReqTicket); i++)
     {
      bool dup = false;
      for(int j = 0; j < ArraySize(tk); j++)
         if(tk[j] == g_closeReqTicket[i])
           { dup = true; break; }
      if(dup)
         continue;
      int n = ArraySize(tk);
      ArrayResize(tk, n + 1); ArrayResize(rs, n + 1);
      tk[n] = g_closeReqTicket[i]; rs[n] = g_closeReqReason[i];
     }

   ResetLastError();
   int h = FileOpen(rel, FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
      return; // retry next tick
   for(int i = 0; i < ArraySize(tk); i++)
      FileWrite(h, IntegerToString((long)tk[i]), rs[i]);
   FileClose(h);

   Print("SLAVE: close request file written (", ArraySize(tk), " ticket(s))");
   ArrayResize(g_closeReqTicket, 0);
   ArrayResize(g_closeReqReason, 0);
  }

// MASTER: poll <syncfile>.close.* every 200 ms and close the requested tickets.
// The resulting DEAL_ADD transactions rewrite the sync file, so every other
// Slave flattens on its next tick.
void ProcessCloseRequests()
  {
   if(Mode != MODE_MASTER || !PropagateSlaveClose)
      return;

   string base = GetSyncFilePath();

   // Folder part of the sync path (FileFindFirst returns bare names)
   string folder = "";
   string parts[];
   int np = StringSplit(base, '\\', parts);
   if(np > 1)
     {
      folder = parts[0];
      for(int i = 1; i < np - 1; i++)
         folder += "\\" + parts[i];
     }

   string found;
   long fh = FileFindFirst(base + ".close.*", found, FILE_COMMON);
   if(fh == INVALID_HANDLE)
      return;
   string files[];
   do
     {
      int n = ArraySize(files);
      ArrayResize(files, n + 1);
      files[n] = found;
     }
   while(FileFindNext(fh, found));
   FileFindClose(fh);

   CTrade trade;
   trade.SetDeviationInPoints(Slippage);
   bool closedAny = false;

   for(int f = 0; f < ArraySize(files); f++)
     {
      string rel = (folder == "") ? files[f] : folder + "\\" + files[f];
      int h = FileOpen(rel, FILE_READ | FILE_CSV | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE, ',');
      if(h == INVALID_HANDLE)
         continue; // a Slave is writing it right now -> retry next tick
      while(!FileIsEnding(h))
        {
         string t = FileReadString(h);
         if(StringLen(t) == 0)
            break;
         string r = FileIsLineEnding(h) ? "" : FileReadString(h);
         ulong ticket = (ulong)StringToInteger(t);
         if(ticket == 0)
            continue;
         if(PositionSelectByTicket(ticket))
           {
            trade.SetTypeFillingBySymbol(PositionGetString(POSITION_SYMBOL));
            if(trade.PositionClose(ticket))
              {
               closedAny = true;
               Print("MASTER: position #", ticket, " closed on Slave request (", r, ") [", files[f], "]");
              }
            else
               Print("MASTER: FAILED to close #", ticket, " on Slave request (", r, ") ret=",
                     trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
           }
         else
            Print("MASTER: Slave close request for #", ticket, " (", r, ") - already closed");
        }
      FileClose(h);
      FileDelete(rel, FILE_COMMON);
     }

   if(closedAny)
      SyncPositionsToFile();
  }

//-------------------------------------------------------------------
// Slave position ticket -> Master ticket
//-------------------------------------------------------------------
void RebuildSlaveMasterMap()
  {
   ArrayResize(g_mapSlaveTicket, 0);
   ArrayResize(g_mapMasterTicket, 0);
   CPositionInfo p;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!p.SelectByIndex(i))
         continue;
      if((long)p.Magic() != MagicNumber)
         continue;
      ulong mt = ParseMasterTicketFromComment(p.Comment());
      if(mt == 0)
         continue;
      int n = ArraySize(g_mapSlaveTicket);
      ArrayResize(g_mapSlaveTicket, n + 1);
      ArrayResize(g_mapMasterTicket, n + 1);
      g_mapSlaveTicket[n]  = p.Ticket();
      g_mapMasterTicket[n] = mt;
     }
  }

ulong MasterTicketForSlavePosition(ulong posId)
  {
   for(int i = 0; i < ArraySize(g_mapSlaveTicket); i++)
      if(g_mapSlaveTicket[i] == posId)
         return g_mapMasterTicket[i];

   // Fallback (EA just restarted): take the comment of the position's IN deal
   if(HistorySelectByPosition(posId))
     {
      int n = HistoryDealsTotal();
      for(int i = 0; i < n; i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0)
            continue;
         if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN)
            continue;
         ulong mt = ParseMasterTicketFromComment(HistoryDealGetString(d, DEAL_COMMENT));
         if(mt > 0)
            return mt;
        }
     }
   return 0;
  }

//-------------------------------------------------------------------
// Open-attempt throttle (failed opens retry every ~1.5 s, not 200 ms)
//-------------------------------------------------------------------
bool OpenRecentlyTried(ulong mTicket)
  {
   ulong now = (ulong)GetTickCount64();
   for(int i = 0; i < ArraySize(g_openTryTicket); i++)
      if(g_openTryTicket[i] == mTicket)
        {
         if(now - g_openTryWhenMs[i] < 1500)
            return true;
         g_openTryWhenMs[i] = now;
         return false;
        }
   int n = ArraySize(g_openTryTicket);
   ArrayResize(g_openTryTicket, n + 1);
   ArrayResize(g_openTryWhenMs, n + 1);
   g_openTryTicket[n] = mTicket;
   g_openTryWhenMs[n] = now;
   return false;
  }

//-------------------------------------------------------------------
// Parse the Master file into 'out'.
// Returns 0 = parsed new content, 1 = unchanged (same SEQ), 2 = torn/incomplete.
//-------------------------------------------------------------------
int ParseMasterFile(int h, TargetPos &out[])
  {
   ArrayResize(out, 0);
   bool  isSeq = false, gotEnd = false, first = true;
   ulong seq = 0;

   while(!FileIsEnding(h))
     {
      string f1 = FileReadString(h);
      if(StringLen(f1) == 0)
         break;

      if(first && f1 == "SEQ")
        {
         first = false;
         isSeq = true;
         seq   = (ulong)StringToInteger(FileReadString(h));
         if(g_haveTargets && seq == g_lastSeqSeen)
            return 1; // nothing new
         continue;
        }
      first = false;

      if(f1 == "END")
        {
         string s2 = FileIsLineEnding(h) ? "" : FileReadString(h);
         gotEnd = !isSeq || ((ulong)StringToInteger(s2) == seq);
         break;
        }

      // ---- position record ----
      string sSymbol = FileReadString(h);
      string sType   = FileReadString(h);
      string sVol    = FileReadString(h);
      string sOpen   = FileReadString(h);   // Master entry: SL/TP distances are measured from here
      string sSL     = FileReadString(h);
      string sTP     = FileReadString(h);
      string sTime   = FileReadString(h);   // openTime (informational)
      string sPV     = FileIsLineEnding(h) ? "" : FileReadString(h); // v2: Master point value per lot

      ulong  mTicket = (ulong)StringToInteger(f1);
      int    mType   = (int)StringToInteger(sType);
      double mVol    = StringToDouble(sVol);
      double mEntry  = StringToDouble(sOpen);
      double mSL     = StringToDouble(sSL);
      double mTP     = StringToDouble(sTP);
      double mPV     = StringToDouble(sPV);
      if(mTicket == 0 || StringLen(sSymbol) == 0)
         continue;

      // SL/TP as signed distances from the Master's entry (broker/slippage-independent).
      bool   hSL = (mSL != 0.0);
      bool   hTP = (mTP != 0.0);
      double dSL = hSL ? mSL - mEntry : 0.0;
      double dTP = hTP ? mTP - mEntry : 0.0;

      string slaveSymbol = MapSymbol(sSymbol);
      ENUM_POSITION_TYPE mDir = (mType == 0) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      ENUM_POSITION_TYPE sDir = mDir;
      double slDist = dSL, tpDist = dTP;
      bool   sHasSL = hSL, sHasTP = hTP;
      if(InverseMode)
        {
         // Mirror around the entry: the Master's TP distance becomes the Slave's SL, and vice versa.
         sDir   = (mDir == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
         slDist = dTP; sHasSL = hTP;
         tpDist = dSL; sHasTP = hSL;
        }

      // Equalize money-per-point across brokers (e.g. one broker's index contract
      // is worth 2x the other's): scale by the point-value ratio, then apply
      // RiskMultiplier as a pure user preference on top.
      double scale = 1.0;
      if(AutoLotScaling && mPV > 0)
        {
         double spv = PointValuePerLot(slaveSymbol);
         if(spv > 0)
            scale = mPV / spv;
        }

      double req = mVol * RiskMultiplier * scale;
      double vol = NormalizeVolume(slaveSymbol, req);
      if(vol <= 0)
         continue;

      int sz = ArraySize(out);
      ArrayResize(out, sz + 1);
      out[sz].masterTicket = mTicket;
      out[sz].symbol    = slaveSymbol;
      out[sz].dir       = sDir;
      out[sz].volume    = vol;
      out[sz].rawVolume = req;
      out[sz].slDist    = slDist;
      out[sz].tpDist    = tpDist;
      out[sz].hasSL     = sHasSL;
      out[sz].hasTP     = sHasTP;
      out[sz].matched   = false;
     }

   if(isSeq && !gotEnd)
      return 2; // Master was mid-write: discard, keep the previous state, retry next tick
   if(isSeq)
      g_lastSeqSeen = seq;
   return 0;
  }

void SlaveSync()
  {
   if(Mode != MODE_SLAVE)
      return;

   string rel = GetSyncFilePath();

   if(!FileIsExist(rel, FILE_COMMON))
     {
      if(MasterFileExists)
        { MasterFileExists = false; Print("SLAVE: Master disconnected. Waiting for reconnection..."); }
      else if(!SlaveWarningShown)
        { Print("SLAVE: Master file not found: ", rel); SlaveWarningShown = true; }
      return; // never reconcile without a Master file (it may be restarting)
     }
   if(!MasterFileExists)
     { MasterFileExists = true; SlaveWarningShown = false; g_lastSeqSeen = 0; Print("SLAVE: Master connected. Syncing..."); }

   ResetLastError();
   int h = FileOpen(rel, FILE_READ | FILE_CSV | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE, ',');
   if(h == INVALID_HANDLE)
      return; // collision with a Master write: retry in 200 ms

   TargetPos fresh[];
   int rc = ParseMasterFile(h, fresh);
   FileClose(h);

   if(rc == 2)
      return; // torn read
   if(rc == 0)
     {
      int n = ArraySize(fresh);
      ArrayResize(g_targets, n);
      for(int i = 0; i < n; i++)
         g_targets[i] = fresh[i];
      g_haveTargets = true;
     }

   // Reconcile on EVERY tick (not just on file changes): retries failed
   // opens/level-applies and keeps positions aligned at a 200 ms cadence.
   if(g_haveTargets)
     {
      PruneClosedMasterTickets(); // every tick, so the 120 s fallback works even if the file never changes
      ReconcileSlavePositions();
     }
  }

void ReconcileSlavePositions()
  {
   CTrade trade;
   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   CPositionInfo pos;

   RebuildSlaveMasterMap();

   for(int t = 0; t < ArraySize(g_targets); t++)
      g_targets[t].matched = false;

   // ---- Iterate Slave positions (filtered by magic) ----
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))
         continue;
      if((long)pos.Magic() != MagicNumber)
         continue;

      ulong mt = ParseMasterTicketFromComment(pos.Comment());
      int   idx = -1;
      // 1) match by Master ticket
      if(mt != 0)
         for(int t = 0; t < ArraySize(g_targets); t++)
            if(!g_targets[t].matched && g_targets[t].masterTicket == mt)
              { idx = t; break; }
      // 2) fallback: by symbol + direction if the comment was lost
      if(idx < 0)
         for(int t = 0; t < ArraySize(g_targets); t++)
            if(!g_targets[t].matched && g_targets[t].symbol == pos.Symbol() && g_targets[t].dir == pos.PositionType())
              { idx = t; break; }

      if(idx < 0)
        {
         // The Master no longer has this position -> close
         trade.SetTypeFillingBySymbol(pos.Symbol());
         trade.PositionClose(pos.Ticket());
         continue;
        }

      g_targets[idx].matched = true;

      // Different direction -> close and reopen
      if(pos.PositionType() != g_targets[idx].dir)
        {
         trade.SetTypeFillingBySymbol(pos.Symbol());
         trade.PositionClose(pos.Ticket());
         continue; // reopened below in the open phase
        }

      // Volume adjustment (reduction only; respects Master partial close)
      double cur = pos.Volume();
      double diff = g_targets[idx].volume - cur;
      CSymbolInfo si; si.Name(pos.Symbol());
      double step = si.LotsStep();
      double tol  = (step > 0) ? step : 0.0001;
      if(diff < -tol)
        {
         double closeVol = cur - g_targets[idx].volume;
         if(step > 0) closeVol = MathFloor(closeVol / step + 0.5) * step;
         if(closeVol >= si.LotsMin() && closeVol < cur)
           {
            trade.SetTypeFillingBySymbol(pos.Symbol());
            trade.PositionClosePartial(pos.Ticket(), closeVol);
           }
        }

      if(CopyMode == COPY_NORMAL)
        {
         // Replicate SL/TP, measured from THIS position's own entry price.
         int    dg = (int)si.Digits();
         double entry  = pos.PriceOpen();
         double wantSL = g_targets[idx].hasSL ? NormalizeDouble(entry + g_targets[idx].slDist, dg) : 0.0;
         double wantTP = g_targets[idx].hasTP ? NormalizeDouble(entry + g_targets[idx].tpDist, dg) : 0.0;
         if(MathAbs(pos.StopLoss() - wantSL) > si.Point() || MathAbs(pos.TakeProfit() - wantTP) > si.Point())
            trade.PositionModify(pos.Ticket(), wantSL, wantTP);
        }
      else if(pos.StopLoss() == 0.0 && pos.TakeProfit() == 0.0 &&
              (g_targets[idx].hasSL || g_targets[idx].hasTP))
        {
         // INCOGNITO: levels are only set on open, but if that initial modify
         // failed the position would stay unprotected - retry until it sticks.
         int    dg = (int)si.Digits();
         double entry = pos.PriceOpen();
         double sl = g_targets[idx].hasSL ? NormalizeDouble(entry + g_targets[idx].slDist, dg) : 0.0;
         double tp = g_targets[idx].hasTP ? NormalizeDouble(entry + g_targets[idx].tpDist, dg) : 0.0;
         trade.SetTypeFillingBySymbol(pos.Symbol());
         trade.PositionModify(pos.Ticket(), sl, tp);
        }
     }

   // ---- Open the Master positions the Slave does not have yet ----
   for(int t = 0; t < ArraySize(g_targets); t++)
     {
      bool present = false;
      for(int i = 0; i < PositionsTotal(); i++)
        {
         if(!pos.SelectByIndex(i))
            continue;
         if((long)pos.Magic() != MagicNumber)
            continue;
         if(ParseMasterTicketFromComment(pos.Comment()) == g_targets[t].masterTicket && pos.PositionType() == g_targets[t].dir)
           { present = true; break; }
        }
      if(present)
         continue;

      // Closed here on purpose (own SL/TP/manual/lock): the Master is being asked
      // to close it; do NOT reopen.
      if(PropagateSlaveClose && IsClosedMasterTicket(g_targets[t].masterTicket))
         continue;

      if(OpenRecentlyTried(g_targets[t].masterTicket))
         continue;

      string sym = g_targets[t].symbol;
      if(!SymbolSelect(sym, true))
        { Print("SLAVE: symbol not available at the broker: ", sym); continue; }

      if(g_targets[t].volume < g_targets[t].rawVolume - 1e-8)
         Print("SLAVE: WARNING volume clamped by broker limits: requested ",
               DoubleToString(g_targets[t].rawVolume, 2), " -> trading ",
               DoubleToString(g_targets[t].volume, 2), " (hedge coverage reduced!)");

      trade.SetTypeFillingBySymbol(sym);
      string comment = "HC" + IntegerToString((long)g_targets[t].masterTicket);
      bool ok;
      // Open at market WITHOUT SL/TP first; they are set right after, measured from the real fill price.
      if(g_targets[t].dir == POSITION_TYPE_BUY)
         ok = trade.Buy(g_targets[t].volume, sym, 0.0, 0.0, 0.0, comment);
      else
         ok = trade.Sell(g_targets[t].volume, sym, 0.0, 0.0, 0.0, comment);
      if(!ok)
        { Print("SLAVE: error opening ", sym, " vol=", g_targets[t].volume, " ret=", trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")"); continue; }

      ApplySlaveLevels(trade, g_targets[t].masterTicket, g_targets[t].dir,
                       g_targets[t].slDist, g_targets[t].tpDist, g_targets[t].hasSL, g_targets[t].hasTP);
     }
  }

//===================================================================
// DASHBOARD
//===================================================================
color BandColor(double frac)
  {
   if(frac >= 1.0)  return clrRed;
   if(frac >= 0.75) return clrOrange;
   if(frac >= 0.5)  return clrYellow;
   return clrLime;
  }

double CalculateDailyPercent(double eq, double base)
  { return (base <= 0) ? 0.0 : ((eq - base) / base) * 100.0; }

double CalculateTotalPercent(double eq, double base)
  { return (base <= 0) ? 0.0 : ((eq - base) / base) * 100.0; }

string FormatPercent(double p)
  { return p >= 0 ? "+" + DoubleToString(p, 2) + "%" : DoubleToString(p, 2) + "%"; }

void CreateOrUpdateLabel(string name, int x, int y, string text, color clr, int fontSize, bool bold, int valueIndex = -1)
  {
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
      ObjectSetString(0, name, OBJPROP_FONT, bold ? "Arial Bold" : "Arial");
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      if(valueIndex >= 0 && valueIndex < ArraySize(LastDashboardValues))
         LastDashboardValues[valueIndex] = text;
      return;
     }
   if(valueIndex >= 0 && valueIndex < ArraySize(LastDashboardValues) && !DashboardNeedsUpdate && LastDashboardValues[valueIndex] == text)
     {
      color cc = (color)ObjectGetInteger(0, name, OBJPROP_COLOR);
      long cx = ObjectGetInteger(0, name, OBJPROP_XDISTANCE);
      long cy = ObjectGetInteger(0, name, OBJPROP_YDISTANCE);
      if(cc != clr || cx != x || cy != y)
        {
         ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
         ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
         ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
        }
      return;
     }
   if(valueIndex >= 0 && valueIndex < ArraySize(LastDashboardValues))
      LastDashboardValues[valueIndex] = text;
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

void CreateDashboard()
  {
   DeleteDashboard();
   string panel = "HCProps_Dashboard_Panel";
   ObjectCreate(0, panel, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panel, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, panel, OBJPROP_YDISTANCE, 10);
   ObjectSetInteger(0, panel, OBJPROP_XSIZE, 420);
   ObjectSetInteger(0, panel, OBJPROP_YSIZE, 100);
   ObjectSetInteger(0, panel, OBJPROP_BGCOLOR, clrDarkSlateGray);
   ObjectSetInteger(0, panel, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panel, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panel, OBJPROP_BACK, false);
   ObjectSetInteger(0, panel, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panel, OBJPROP_HIDDEN, true);
   UpdateDashboard();
  }

void SizePanel(int yPos)
  {
   string panel = "HCProps_Dashboard_Panel";
   if(ObjectFind(0, panel) < 0)
      return;
   int marginTop = 10, marginBottom = 10, startY = 20;
   int height = (yPos - startY) + marginTop + marginBottom;
   int panelY = startY - marginTop;
   if(DashboardNeedsUpdate || ObjectGetInteger(0, panel, OBJPROP_YDISTANCE) != panelY || ObjectGetInteger(0, panel, OBJPROP_YSIZE) != height)
     {
      ObjectSetInteger(0, panel, OBJPROP_YDISTANCE, panelY);
      ObjectSetInteger(0, panel, OBJPROP_YSIZE, height);
     }
  }

void UpdateDashboard()
  {
   if(Mode == MODE_SLAVE) { UpdateDashboardSlave(); return; }

   CAccountInfo acc;
   double eq = acc.Equity();
   int y = 20, lh = 20;

   CreateOrUpdateLabel("HCProps_Title", 20, y, "=== HC Props Controller ===", clrDodgerBlue, 12, true, 0); y += lh + 5;
   string modeText = PropFirmMode ? "MASTER (guardian ON)" : "MASTER (sync only)";
   CreateOrUpdateLabel("HCProps_Mode", 20, y, "Mode: " + modeText, clrYellow, 11, true, 1); y += lh + 3;
   CreateOrUpdateLabel("HCProps_File", 20, y, "File: " + SyncFileLabel(), clrAqua, 10, false, 2); y += lh + 5;

   string status = TradingIsDisabled() ? "DISABLED" : "ENABLED";
   CreateOrUpdateLabel("HCProps_Status", 20, y, "Trading Status: " + status, TradingIsDisabled() ? clrRed : clrLime, 11, true, 4); y += lh;

   if(IsNewsBlocked)
     { CreateOrUpdateLabel("HCProps_News", 20, y, "NEWS ACTIVE: " + g_activeNews, clrRed, 10, true, 5); y += lh; }
   else if(NewsMode != NEWS_OPERATE)
     { CreateOrUpdateLabel("HCProps_News", 20, y, "News: watching (" + IntegerToString(ArraySize(g_newsTimes)) + ")", clrLime, 9, false, 5); y += lh; }
   else
     { ObjectDelete(0, "HCProps_News"); LastDashboardValues[5] = ""; } // OPERATE: no news line (don't stack an empty label on "Locks:")

   if(PropFirmMode)
     {
      string flags = "";
      if(IsGlobalTradingDisabled) flags += "Total ";
      if(IsDailyLimitTradingDisabled) flags += "Daily ";
      if(IsDailyNumberTradingDisabled) flags += "Trades/Day ";
      if(IsParallelTradesDisabled) flags += "Parallel ";
      if(IsConsecWinsDisabled) flags += "WinsStreak ";
      if(IsConsecLossesDisabled) flags += "LossStreak ";
      if(IsTradingHoursDisabled) flags += "Hours ";
      if(flags == "") flags = "None";
      CreateOrUpdateLabel("HCProps_FlagsList", 20, y, "Locks: " + flags, flags == "None" ? clrLime : clrOrange, 9, false, 6); y += lh + 5;

      CreateOrUpdateLabel("HCProps_BalanceInit", 20, y, "Initial Balance: " + DoubleToString(AccountDepositsAndWithdrawals, 2), clrSilver, 10, false, 7); y += lh;
      CreateOrUpdateLabel("HCProps_EquityInit", 20, y, "Day Start Equity: " + DoubleToString(InitialEquityDaily, 2), clrSilver, 10, false, 8); y += lh;

      double dp = CalculateDailyPercent(eq, InitialEquityDaily);
      double tp = CalculateTotalPercent(eq, AccountDepositsAndWithdrawals);
      CreateOrUpdateLabel("HCProps_Equity", 20, y, "Equity: " + DoubleToString(eq, 2) + " | Day: " + FormatPercent(dp) + " | Total: " + FormatPercent(tp), clrWhite, 10, false, 9); y += lh;

      if(DailyUpperLimitEquity > 0)
        { color c = BandColor(DailyProfitLimitPercent > 0 ? dp / DailyProfitLimitPercent : 0);
          CreateOrUpdateLabel("HCProps_DailyUpper", 30, y, "Day +: " + DoubleToString(DailyUpperLimitEquity, 2) + " (" + DoubleToString(DailyProfitLimitPercent, 2) + "%)", c, 9, false, 10); y += lh - 2; }
      if(DailyLowerLimitEquity > 0)
        { color c = BandColor(DailyLossLimitPercent > 0 ? (-dp) / DailyLossLimitPercent : 0);
          CreateOrUpdateLabel("HCProps_DailyLower", 30, y, "Day -: " + DoubleToString(DailyLowerLimitEquity, 2) + " (" + DoubleToString(DailyLossLimitPercent, 2) + "%)", c, 9, false, 11); y += lh; }
      if(TotalUpperLimitEquity > 0)
        { color c = BandColor(TotalProfitLimitPercent > 0 ? tp / TotalProfitLimitPercent : 0);
          CreateOrUpdateLabel("HCProps_TotalUpper", 30, y, "Total +: " + DoubleToString(TotalUpperLimitEquity, 2) + " (" + DoubleToString(TotalProfitLimitPercent, 2) + "%)", c, 9, false, 12); y += lh - 2; }
      if(TotalLowerLimitEquity > 0)
        { color c = BandColor(TotalLossLimitPercent > 0 ? (-tp) / TotalLossLimitPercent : 0);
          CreateOrUpdateLabel("HCProps_TotalLower", 30, y, "Total -: " + DoubleToString(TotalLowerLimitEquity, 2) + " (" + DoubleToString(TotalLossLimitPercent, 2) + "%)", c, 9, false, 13); y += lh + 3; }

      if(MaxTradesPerDay > 0)
        { color c = BandColor((double)TradesOpenedToday / MaxTradesPerDay);
          CreateOrUpdateLabel("HCProps_TradesToday", 30, y, "Trades today: " + IntegerToString(TradesOpenedToday) + " / " + IntegerToString(MaxTradesPerDay), c, 9, false, 14); y += lh - 2; }
      if(MaxParallelTrades > 0)
        { color c = BandColor((double)CurrentTradesCount / MaxParallelTrades);
          CreateOrUpdateLabel("HCProps_TradesParallel", 30, y, "Parallel: " + IntegerToString(CurrentTradesCount) + " / " + IntegerToString(MaxParallelTrades), c, 9, false, 15); y += lh - 2; }
      if(MaxConsecWinsPerDay > 0)
        { color c = BandColor((double)ConsecutiveWinsToday / MaxConsecWinsPerDay);
          CreateOrUpdateLabel("HCProps_ConsecWins", 30, y, "Win streak: " + IntegerToString(ConsecutiveWinsToday) + " / " + IntegerToString(MaxConsecWinsPerDay), c, 9, false, 16); y += lh - 2; }
      if(MaxConsecLossesPerDay > 0)
        { color c = BandColor((double)ConsecutiveLossesToday / MaxConsecLossesPerDay);
          CreateOrUpdateLabel("HCProps_ConsecLosses", 30, y, "Loss streak: " + IntegerToString(ConsecutiveLossesToday) + " / " + IntegerToString(MaxConsecLossesPerDay), c, 9, false, 17); y += lh + 3; }

      if(LimitTradingHours)
        {
         MqlDateTime ct; TimeToStruct(TimeCurrent(), ct);
         string txt = StringFormat("Hours: %02d:%02d | %02d:%02d-%02d:%02d", ct.hour, ct.min, TradingStartHour, TradingStartMinute, TradingEndHour, TradingEndMinute);
         CreateOrUpdateLabel("HCProps_Hours", 30, y, txt, IsTradingHoursDisabled ? clrRed : clrLime, 9, false, 18); y += lh; }

      if(NextDailyResetTime > 0)
        { MqlDateTime r; TimeToStruct(NextDailyResetTime, r);
          CreateOrUpdateLabel("HCProps_Reset", 20, y, StringFormat("Daily reset: %02d:%02d", r.hour, r.min), clrCyan, 9, false, 19); y += lh - 2; }
      if(ForceExitEnabled && NextForceExitTime > 0)
        { MqlDateTime e; TimeToStruct(NextForceExitTime, e);
          CreateOrUpdateLabel("HCProps_Exit", 20, y, StringFormat("Forced close: %02d:%02d", e.hour, e.min), clrMagenta, 9, false, 20); y += lh; }
     }

   SizePanel(y);
   DashboardNeedsUpdate = false;
   ChartRedraw(0);
  }

void UpdateDashboardSlave()
  {
   CAccountInfo acc;
   int y = 20, lh = 20;
   CreateOrUpdateLabel("HCProps_Title", 20, y, "=== HC Props Controller ===", clrDodgerBlue, 12, true, 0); y += lh + 5;
   CreateOrUpdateLabel("HCProps_Mode", 20, y, "Mode: SLAVE", clrYellow, 11, true, 1); y += lh + 3;
   CreateOrUpdateLabel("HCProps_File", 20, y, "File: " + SyncFileLabel(), clrAqua, 10, false, 2); y += lh;
   CreateOrUpdateLabel("HCProps_Rev", 20, y, "Invert: " + (InverseMode ? "YES" : "NO") + " | Mult: " + DoubleToString(RiskMultiplier, 2) + " | " + (CopyMode == COPY_NORMAL ? "NORMAL" : "INCOGNITO"), clrAqua, 9, false, 4); y += lh + 5;
   string st = MasterFileExists ? "CONNECTED" : "WAITING FOR MASTER";
   CreateOrUpdateLabel("HCProps_MStatus", 20, y, "Master Status: " + st, MasterFileExists ? clrLime : clrOrange, 11, true, 5); y += lh;
   if(SlaveProfitLocked)
     { CreateOrUpdateLabel("HCProps_SLock", 20, y, "PROFIT LOCK: replication stopped", clrRed, 10, true, 6); y += lh; }
   else
     { ObjectDelete(0, "HCProps_SLock"); LastDashboardValues[6] = ""; } // no empty label stacked on "Equity:"
   CreateOrUpdateLabel("HCProps_SEq", 20, y, "Equity: " + DoubleToString(acc.Equity(), 2), clrWhite, 10, false, 7); y += lh;
   SizePanel(y);
   DashboardNeedsUpdate = false;
   ChartRedraw(0);
  }

void DeleteDashboard()
  {
   ObjectsDeleteAll(0, "HCProps_");
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
     {
      string n = ObjectName(0, i, 0, -1);
      if(n != "" && StringFind(n, "HCProps_") == 0)
         ObjectDelete(0, n);
     }
   ChartRedraw(0);
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

      // If the EA is removed for good (not a recompile), release the lock signal.
      if(reason == REASON_REMOVE || reason == REASON_CHARTCLOSE)
         EnableTrading();
     }
  }
//+------------------------------------------------------------------+
