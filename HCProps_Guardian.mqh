//+------------------------------------------------------------------+
//|  HCProps_Guardian.mqh                                            |
//|  Prop-firm guardian: limits, counters, locks, closes             |
//|  Module of HCPropsController.mq5 - not compilable standalone.    |
//+------------------------------------------------------------------+

//===================================================================
// STATE PERSISTENCE (GlobalVariables)
//===================================================================
void PersistState()
  {
   if(!PropFirmMode)
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

   // Account-reset support: with HistoryFromDate set, the account is treated as
   // if it started at that moment - the initial balance is the BALANCE AS OF
   // that time (prop firms reset the balance with a correction deal but keep
   // the old trade history; summing balance ops would double-count it).
   // Reconstruction: current balance minus every deal change since the date.
   if(HistoryFromDate > 0)
     {
      CAccountInfo acc;
      double currentBalance = acc.Balance();
      if(HistorySelect(HistoryFromDate, TimeCurrent()))
        {
         double change = 0.0;
         int total = HistoryDealsTotal();
         CDealInfo deal;
         for(int i = 0; i < total; i++)
            if(deal.SelectByIndex(i))
               change += deal.Profit() + deal.Commission() + deal.Swap();
         double balAtDate = currentBalance - change;
         if(balAtDate > 0.0)
           {
            AccountDepositsAndWithdrawals = balAtDate;
            return;
           }
         Print("WARNING: balance as of HistoryFromDate computed as ", balAtDate,
               " - falling back to the full-history deposit sum");
        }
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
   if(HistoryFromDate > lastReset)
      lastReset = HistoryFromDate; // account reset mid-day: the day starts there

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
   datetime anchor = (TimeCurrent() >= todayReset) ? todayReset : todayReset - 86400;
   if(HistoryFromDate > anchor)
      anchor = HistoryFromDate; // ignore trades from before an account reset
   return anchor;
  }

bool InUlongArray(const ulong &arr[], ulong v)
  {
   for(int i = 0; i < ArraySize(arr); i++)
      if(arr[i] == v)
         return true;
   return false;
  }

// Counts DISTINCT trades, not IN deals: partial fills produce several IN deals
// for one position (dedupe by position id), and on a Slave a re-replicated
// Master ticket (direction flip, reopen after a missed close request) must not
// inflate the count (dedupe by the HC<masterTicket> comment when present).
void CountTradesOpenedToday()
  {
   TradesOpenedToday = 0;
   datetime from = LastResetAnchor();
   if(!HistorySelect(from, TimeCurrent() + 60))
      return;
   int total = HistoryDealsTotal();
   CDealInfo deal;
   ulong seen[];
   for(int i = 0; i < total; i++)
     {
      if(!deal.SelectByIndex(i))
         continue;
      long dt = deal.DealType();
      if(deal.Entry() != DEAL_ENTRY_IN || (dt != DEAL_TYPE_BUY && dt != DEAL_TYPE_SELL))
         continue;
      ulong key = 0;
      if(Mode == MODE_SLAVE)
         key = ParseMasterTicketFromComment(HistoryDealGetString(deal.Ticket(), DEAL_COMMENT));
      if(key == 0)
         key = (ulong)HistoryDealGetInteger(deal.Ticket(), DEAL_POSITION_ID);
      if(key == 0 || InUlongArray(seen, key))
         continue;
      int n = ArraySize(seen);
      ArrayResize(seen, n + 1);
      seen[n] = key;
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
// Human-readable list of the active locks (dashboard, lock file, close reasons)
string ActiveLockFlags()
  {
   string flags = "";
   if(IsGlobalTradingDisabled)      flags += "Total ";
   if(IsDailyLimitTradingDisabled)  flags += "Daily ";
   if(IsDailyNumberTradingDisabled) flags += "Trades/Day ";
   if(IsParallelTradesDisabled)     flags += "Parallel ";
   if(IsConsecWinsDisabled)         flags += "WinsStreak ";
   if(IsConsecLossesDisabled)       flags += "LossStreak ";
   if(IsTradingHoursDisabled)       flags += "Hours ";
   if(IsNewsBlocked)                flags += "News ";
   if(IsSlaveLockTradingDisabled)   flags += "SlaveLock ";
   if(IsSlaveDownTradingDisabled)   flags += "SlaveDown ";
   StringTrimRight(flags);
   return flags;
  }

void CheckAndUpdateTradingStatus()
  {
   bool anyBlock = IsGlobalTradingDisabled || IsDailyLimitTradingDisabled || IsDailyNumberTradingDisabled ||
                   IsParallelTradesDisabled || IsTradingHoursDisabled || IsConsecWinsDisabled ||
                   IsConsecLossesDisabled || IsNewsBlocked || IsSlaveLockTradingDisabled ||
                   IsSlaveDownTradingDisabled;

   if(!anyBlock)
     {
      DidCloseOrders = false;
      DidClosePositions = false;
      EnableTrading();
      NotifyLockStateIfChanged();
      return;
     }

   DisableTrading();

   // Flatten EVERYTHING for: equity/total limits, consecutive win/loss streaks, or CLOSE_ALL news.
   // (a Slave lock / missing heartbeat on the Master only blocks new entries:
   //  position closes arrive via close requests)
   bool closeActivePositions = IsGlobalTradingDisabled || IsDailyLimitTradingDisabled ||
                               IsConsecWinsDisabled || IsConsecLossesDisabled ||
                               (IsNewsBlocked && NewsMode == NEWS_CLOSE_ALL);

   if(!DidCloseOrders || (!DidClosePositions && closeActivePositions))
     {
      DidCloseOrders = true;
      if(closeActivePositions)
        {
         DidClosePositions = true;
         // SLAVE breach that flattens: ask the Master to close the originals first
         // (status file hits the disk BEFORE we start closing), so the Master and
         // every other Slave flatten too.
         if(Mode == MODE_SLAVE && PropagateSlaveClose)
           {
            EnqueueAllReplicatedCloses("GUARD:" + ActiveLockFlags());
            WriteSlaveStatusFile();
           }
        }
      CloseAllPositions(closeActivePositions);
     }

   NotifyLockStateIfChanged();

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
// Equity limits are split out so they can run on EVERY 200 ms tick: a fast
// spike must not run a full second past a daily/total limit before we react.
void CheckEquityLimits()
  {
   if(!PropFirmMode)
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
  }

void CheckGuardRules()
  {
   if(!PropFirmMode)
      return;

   CheckEquityLimits();

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

