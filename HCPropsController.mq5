//+------------------------------------------------------------------+
//|                                            HCPropsController.mq5 |
//|  Copy-trading (Master/Slave) + prop-firm guardian + news filter  |
//|  Single EA, file-based sync on the same VPS. No backend/license. |
//+------------------------------------------------------------------+
#property strict
#property version "2.00"
#property description "HCPropsController: Master/Slave copy trading, prop-firm limits and news filter in a single EA."

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

enum HCNewsSource
  {
   NEWS_SOURCE_MT5 = 0, // Native MetaTrader 5 calendar (recommended)
   NEWS_SOURCE_URL = 1  // Custom CSV feed via WebRequest
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
input string FileName             = "";          // File name (empty = auto from server+account)
input string CustomFilePath       = "";          // Custom path inside Common\Files (optional)
input string Symbols              = "";          // (MASTER) Symbols to replicate, comma-sep (empty = all)

input group "=== SLAVE SETTINGS (SLAVE mode only) ==="
input string     MasterServer        = "";        // Master account server (if FileName is empty)
input long       MasterAccountNumber = 0;         // Master account number (if FileName is empty)
input string     SymbolMapping       = "";        // Mapping MAST:SLAV;MAST2:SLAV2 (optional)
input HCCopyMode CopyMode            = COPY_NORMAL;// Copy mode
input bool       InverseMode         = false;     // Invert Master trades (and SL/TP)
input double     RiskMultiplier      = 1.0;       // Lot multiplier (Slave lot = Master lot x mult)
input int        Slippage            = 10;        // Allowed slippage (points)
input long       MagicNumber         = 987654;    // Magic Number of the Slave orders
input double     SlaveTotalProfitLimitPercent = 0.0; // Slave total profit limit (%); 0 = none

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
input HCNewsSource NewsSource     = NEWS_SOURCE_MT5;// Calendar source
input string       NewsCalendarUrl= "";             // (NEWS_SOURCE_URL) CSV feed URL "epoch,CURRENCY,impact"

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
datetime LastSlaveFileTime   = 0;
bool     MasterFileExists    = false;
int      LastSlaveDay        = -1;
bool     SlaveWarningShown   = false;

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
string ReplaceString(string text, string search, string replace)
  {
   string result = text;
   StringReplace(result, search, replace);
   return result;
  }

string NormalizeServerName(string serverName)
  {
   StringTrimLeft(serverName);
   StringTrimRight(serverName);
   while(StringFind(serverName, "  ") >= 0)
      StringReplace(serverName, "  ", " ");
   return serverName;
  }

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
//| BASE64 for file name (auto fallback)                             |
//+------------------------------------------------------------------+
string Base64Encode(string data)
  {
   uchar src[], key[], dst[];
   StringToCharArray(data, src, 0, StringLen(data));
   ArrayResize(key, 0);
   int res = CryptEncode(CRYPT_BASE64, src, key, dst);
   if(res > 0)
     {
      string encoded = CharArrayToString(dst);
      encoded = ReplaceString(encoded, "\r\n", "");
      encoded = ReplaceString(encoded, "\n", "");
      encoded = ReplaceString(encoded, "\r", "");
      return encoded;
     }
   string safe = data;
   string repl[] = {"\\","/",":","*","?","\"","<",">","|"};
   for(int i = 0; i < ArraySize(repl); i++)
      safe = ReplaceString(safe, repl[i], "_");
   return safe;
  }

//+------------------------------------------------------------------+
//| File paths (relative to Common\Files)                            |
//+------------------------------------------------------------------+
// Returns the file path for a given server/account.
string BuildFilePath(string server, long account)
  {
   if(CustomFilePath != "")
      return CustomFilePath;
   if(FileName != "")
      return HCPROPS_KEY + "\\" + FileName;
   string enc = Base64Encode(NormalizeServerName(server) + "_" + IntegerToString(account));
   return HCPROPS_KEY + "\\" + enc + ".csv";
  }

string GetMyFilePath()       // Master: its own file
  {
   CAccountInfo acc;
   return BuildFilePath(acc.Server(), acc.Login());
  }

string GetMasterFilePath()   // Slave: the Master's file
  {
   return BuildFilePath(MasterServer, MasterAccountNumber);
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

   // SLAVE validation: needs either FileName/CustomFilePath, or server+account
   if(Mode == MODE_SLAVE)
     {
      bool hasFile   = (FileName != "" || CustomFilePath != "");
      bool hasServer = (MasterServer != "" && MasterAccountNumber != 0);
      if(!hasFile && !hasServer)
        {
         Print("ERROR: In SLAVE mode set FileName/CustomFilePath, or MasterServer + MasterAccountNumber");
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

   EventSetTimer(1);

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
      string rel = GetMasterFilePath();
      MasterFileExists = FileIsExist(rel, FILE_COMMON);
      if(MasterFileExists)
         Print("SLAVE: Master file found: ", rel);
      else
        {
         Print("SLAVE: Master file NOT found on start: ", rel);
         Print("SLAVE: check FileName, or that MasterServer matches EXACTLY (including spaces).");
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

void FetchNewsUrl(datetime from, datetime to, string &curr[])
  {
   if(NewsCalendarUrl == "")
      return;
   char post[], result[];
   string headers;
   ResetLastError();
   int code = WebRequest("GET", NewsCalendarUrl, "", "", 5000, post, 0, result, headers);
   if(code != 200)
     {
      Print("NEWS(URL): WebRequest returned ", code, " err=", GetLastError(), " (is the URL in the allowed list?)");
      return;
     }
   string body = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   string lines[];
   int nl = StringSplit(body, '\n', lines);
   for(int i = 0; i < nl; i++)
     {
      string line = lines[i];
      line = ReplaceString(line, "\r", "");
      if(StringLen(line) < 5)
         continue;
      string f[];
      if(StringSplit(line, ',', f) < 3)
         continue;
      datetime t = (datetime)StringToInteger(f[0]);
      string cy = f[1]; StringTrimLeft(cy); StringTrimRight(cy);
      int imp = (int)StringToInteger(f[2]);
      if(t < from || t > to || imp < (int)NewsMinImpact)
         continue;
      bool wanted = false;
      for(int c = 0; c < ArraySize(curr); c++) if(curr[c] == cy) { wanted = true; break; }
      if(!wanted)
         continue;
      int sz = ArraySize(g_newsTimes);
      ArrayResize(g_newsTimes, sz + 1);
      ArrayResize(g_newsCurr,  sz + 1);
      ArrayResize(g_newsName,  sz + 1);
      g_newsTimes[sz] = t; g_newsCurr[sz] = cy; g_newsName[sz] = "URL";
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

   if(NewsSource == NEWS_SOURCE_MT5)
      FetchNewsMT5(from, to, curr);
   else
      FetchNewsUrl(from, to, curr);

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
   if(Mode == MODE_MASTER)
     {
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
            CloseAllPositions(true);
            Print("SLAVE: profit limit reached (", SlaveTotalProfitLimitPercent, "%). Replication stopped.");
           }
        }

      if(!SlaveProfitLocked)
         SlaveSync();
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
   if(Mode != MODE_MASTER)
      return;

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

bool WriteSyncFile()
  {
   string rel = GetMyFilePath();

   // Ensure folder (Common\Files\HCPropsController)
   ResetLastError();
   FolderCreate(HCPROPS_KEY, FILE_COMMON); // if it already exists, returns error 5019 (ignored)

   ResetLastError();
   int h = FileOpen(rel, FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_SHARE_WRITE, ',');
   int retry = 0;
   while(h == INVALID_HANDLE && retry < 2) { Sleep(10); ResetLastError(); h = FileOpen(rel, FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_SHARE_WRITE, ','); retry++; }
   if(h == INVALID_HANDLE)
     { Print("ERROR: could not open sync file: ", rel, " err=", GetLastError()); return false; }

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
                IntegerToString((long)arr[i].openTime));
     }
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
   double             sl;
   double             tp;
   bool               matched;
  };

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

void SlaveSync()
  {
   if(Mode != MODE_SLAVE)
      return;

   string rel = GetMasterFilePath();

   if(!FileIsExist(rel, FILE_COMMON))
     {
      if(MasterFileExists)
        { MasterFileExists = false; Print("SLAVE: Master disconnected. Waiting for reconnection..."); }
      else if(!SlaveWarningShown)
        { Print("SLAVE: Master file not found: ", rel); SlaveWarningShown = true; }
      return;
     }
   if(!MasterFileExists)
     { MasterFileExists = true; SlaveWarningShown = false; Print("SLAVE: Master connected. Syncing..."); }

   // Optimization: only read if the modification date changed
   datetime mtime = (datetime)FileGetInteger(rel, FILE_MODIFY_DATE, true);
   if(mtime == 0)
      mtime = TimeCurrent();
   else if(mtime <= LastSlaveFileTime && LastSlaveFileTime > 0)
      return;

   ResetLastError();
   int h = FileOpen(rel, FILE_READ | FILE_CSV | FILE_COMMON | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
     {
      if(GetLastError() != 5002)
         Print("SLAVE: could not open the Master file. err=", GetLastError());
      return;
     }

   // ---- Build target list from the file ----
   TargetPos targets[];
   ArrayResize(targets, 0);
   while(!FileIsEnding(h))
     {
      string sTicket = FileReadString(h);
      if(StringLen(sTicket) == 0)
         break;
      string sSymbol = FileReadString(h);
      string sType   = FileReadString(h);
      string sVol    = FileReadString(h);
      string sOpen   = FileReadString(h);   // openPrice (not used for market orders)
      string sSL     = FileReadString(h);
      string sTP     = FileReadString(h);
      string sTime   = FileReadString(h);   // openTime (informational)

      ulong  mTicket = (ulong)StringToInteger(sTicket);
      int    mType   = (int)StringToInteger(sType);
      double mVol    = StringToDouble(sVol);
      double mSL     = StringToDouble(sSL);
      double mTP     = StringToDouble(sTP);

      string slaveSymbol = MapSymbol(sSymbol);
      ENUM_POSITION_TYPE mDir = (mType == 0) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      ENUM_POSITION_TYPE sDir = mDir;
      double sSLp = mSL, sTPp = mTP;
      if(InverseMode)
        {
         sDir = (mDir == POSITION_TYPE_BUY) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
         sSLp = mTP; // swap SL/TP when inverting
         sTPp = mSL;
        }

      double vol = NormalizeVolume(slaveSymbol, mVol * RiskMultiplier);
      if(vol <= 0)
         continue;

      int sz = ArraySize(targets);
      ArrayResize(targets, sz + 1);
      targets[sz].masterTicket = mTicket;
      targets[sz].symbol  = slaveSymbol;
      targets[sz].dir     = sDir;
      targets[sz].volume  = vol;
      targets[sz].sl      = sSLp;
      targets[sz].tp      = sTPp;
      targets[sz].matched = false;
     }
   FileClose(h);
   LastSlaveFileTime = mtime;

   CTrade trade;
   trade.SetExpertMagicNumber((ulong)MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   CPositionInfo pos;

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
         for(int t = 0; t < ArraySize(targets); t++)
            if(!targets[t].matched && targets[t].masterTicket == mt)
              { idx = t; break; }
      // 2) fallback: by symbol + direction if the comment was lost
      if(idx < 0)
         for(int t = 0; t < ArraySize(targets); t++)
            if(!targets[t].matched && targets[t].symbol == pos.Symbol() && targets[t].dir == pos.PositionType())
              { idx = t; break; }

      if(idx < 0)
        {
         // The Master no longer has this position -> close
         trade.SetTypeFillingBySymbol(pos.Symbol());
         trade.PositionClose(pos.Ticket());
         continue;
        }

      targets[idx].matched = true;

      // Different direction -> close and reopen
      if(pos.PositionType() != targets[idx].dir)
        {
         trade.SetTypeFillingBySymbol(pos.Symbol());
         trade.PositionClose(pos.Ticket());
         continue; // will be reopened below (stays matched=true but with no position; opened in the open phase)
        }

      // Volume adjustment (reduction only; respects Master partial close)
      double cur = pos.Volume();
      double diff = targets[idx].volume - cur;
      CSymbolInfo si; si.Name(pos.Symbol());
      double step = si.LotsStep();
      double tol  = (step > 0) ? step : 0.0001;
      if(diff < -tol)
        {
         double closeVol = cur - targets[idx].volume;
         if(step > 0) closeVol = MathFloor(closeVol / step + 0.5) * step;
         if(closeVol >= si.LotsMin() && closeVol < cur)
           {
            trade.SetTypeFillingBySymbol(pos.Symbol());
            trade.PositionClosePartial(pos.Ticket(), closeVol);
           }
        }

      // Replicate SL/TP in NORMAL mode
      if(CopyMode == COPY_NORMAL)
        {
         double pSL = pos.StopLoss();
         double pTP = pos.TakeProfit();
         if(MathAbs(pSL - targets[idx].sl) > si.Point() || MathAbs(pTP - targets[idx].tp) > si.Point())
            trade.PositionModify(pos.Ticket(), targets[idx].sl, targets[idx].tp);
        }
     }

   // ---- Open the Master positions the Slave does not have yet ----
   // (recount matched: a position whose direction changed was closed above and must be reopened)
   // Recompute which tickets are still present in the Slave
   for(int t = 0; t < ArraySize(targets); t++)
     {
      bool present = false;
      for(int i = 0; i < PositionsTotal(); i++)
        {
         if(!pos.SelectByIndex(i))
            continue;
         if((long)pos.Magic() != MagicNumber)
            continue;
         if(ParseMasterTicketFromComment(pos.Comment()) == targets[t].masterTicket && pos.PositionType() == targets[t].dir)
           { present = true; break; }
        }
      if(present)
         continue;

      string sym = targets[t].symbol;
      if(!SymbolSelect(sym, true))
        { Print("SLAVE: symbol not available at the broker: ", sym); continue; }

      trade.SetTypeFillingBySymbol(sym);
      string comment = "HC" + IntegerToString((long)targets[t].masterTicket);
      bool ok;
      if(targets[t].dir == POSITION_TYPE_BUY)
         ok = trade.Buy(targets[t].volume, sym, 0.0, targets[t].sl, targets[t].tp, comment);
      else
         ok = trade.Sell(targets[t].volume, sym, 0.0, targets[t].sl, targets[t].tp, comment);
      if(!ok)
         Print("SLAVE: error opening ", sym, " vol=", targets[t].volume, " ret=", trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
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
   CreateOrUpdateLabel("HCProps_Server", 20, y, "Server: " + acc.Server(), clrAqua, 10, false, 2); y += lh;
   CreateOrUpdateLabel("HCProps_Account", 20, y, "Account: " + IntegerToString(acc.Login()), clrAqua, 10, false, 3); y += lh + 5;

   string status = TradingIsDisabled() ? "DISABLED" : "ENABLED";
   CreateOrUpdateLabel("HCProps_Status", 20, y, "Trading Status: " + status, TradingIsDisabled() ? clrRed : clrLime, 11, true, 4); y += lh;

   if(IsNewsBlocked)
     { CreateOrUpdateLabel("HCProps_News", 20, y, "NEWS ACTIVE: " + g_activeNews, clrRed, 10, true, 5); y += lh; }
   else if(NewsMode != NEWS_OPERATE)
     { CreateOrUpdateLabel("HCProps_News", 20, y, "News: watching (" + IntegerToString(ArraySize(g_newsTimes)) + ")", clrLime, 9, false, 5); y += lh; }
   else
     { CreateOrUpdateLabel("HCProps_News", 20, y, "", clrLime, 9, false, 5); }

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
  }

void UpdateDashboardSlave()
  {
   CAccountInfo acc;
   int y = 20, lh = 20;
   CreateOrUpdateLabel("HCProps_Title", 20, y, "=== HC Props Controller ===", clrDodgerBlue, 12, true, 0); y += lh + 5;
   CreateOrUpdateLabel("HCProps_Mode", 20, y, "Mode: SLAVE", clrYellow, 11, true, 1); y += lh + 3;
   CreateOrUpdateLabel("HCProps_MS", 20, y, "Master: " + (FileName != "" ? FileName : MasterServer), clrAqua, 10, false, 2); y += lh;
   CreateOrUpdateLabel("HCProps_MA", 20, y, "Master Account: " + IntegerToString(MasterAccountNumber), clrAqua, 10, false, 3); y += lh;
   CreateOrUpdateLabel("HCProps_Rev", 20, y, "Invert: " + (InverseMode ? "YES" : "NO") + " | Mult: " + DoubleToString(RiskMultiplier, 2) + " | " + (CopyMode == COPY_NORMAL ? "NORMAL" : "INCOGNITO"), clrAqua, 9, false, 4); y += lh + 5;
   string st = MasterFileExists ? "CONNECTED" : "WAITING FOR MASTER";
   CreateOrUpdateLabel("HCProps_MStatus", 20, y, "Master Status: " + st, MasterFileExists ? clrLime : clrOrange, 11, true, 5); y += lh;
   if(SlaveProfitLocked)
     { CreateOrUpdateLabel("HCProps_SLock", 20, y, "PROFIT LOCK: replication stopped", clrRed, 10, true, 6); y += lh; }
   else
     { CreateOrUpdateLabel("HCProps_SLock", 20, y, "", clrLime, 9, false, 6); }
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
      string rel = GetMyFilePath();
      if(FileIsExist(rel, FILE_COMMON))
         FileDelete(rel, FILE_COMMON);

      // If the EA is removed for good (not a recompile), release the lock signal.
      if(reason == REASON_REMOVE || reason == REASON_CHARTCLOSE)
         EnableTrading();
     }
  }
//+------------------------------------------------------------------+
