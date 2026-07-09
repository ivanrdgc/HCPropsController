//+------------------------------------------------------------------+
//|  HCProps_Panel.mqh                                               |
//|  On-chart information panel                                      |
//|  Module of HCPropsController.mq5 - not compilable standalone.    |
//+------------------------------------------------------------------+

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
   CAccountInfo acc;
   double eq = acc.Equity();
   int y = 20, lh = 20;

   CreateOrUpdateLabel("HCProps_Title", 20, y, "=== HC Props Controller ===", clrDodgerBlue, 12, true, 0); y += lh + 5;
   string modeText;
   if(Mode == MODE_MASTER)
      modeText = PropFirmMode ? "MASTER (guardian ON)" : "MASTER (sync only)";
   else if(Mode == MODE_SLAVE)
      modeText = PropFirmMode ? "SLAVE (guardian ON)" : "SLAVE (copy only)";
   else
      modeText = PropFirmMode ? "GUARDIAN ONLY (no copy)" : "NONE (guardian OFF - idle!)";
   CreateOrUpdateLabel("HCProps_Mode", 20, y, "Mode: " + modeText,
                       (Mode == MODE_NONE && !PropFirmMode) ? clrRed : clrYellow, 11, true, 1); y += lh + 3;
   if(Mode != MODE_NONE)
     { CreateOrUpdateLabel("HCProps_File", 20, y, "File: " + SyncFileLabel(), clrAqua, 10, false, 2); y += lh + 5; }
   else
     { ObjectDelete(0, "HCProps_File"); LastDashboardValues[2] = ""; }

   if(Mode == MODE_SLAVE)
     {
      CreateOrUpdateLabel("HCProps_Rev", 20, y, "Invert: " + (InverseMode ? "YES" : "NO") +
                          " | Mult: " + DoubleToString(RiskMultiplier, 2) +
                          (AutoLotScaling ? " | AutoLots" : "") +
                          " | " + (CopyMode == COPY_NORMAL ? "NORMAL" : "INCOGNITO"), clrAqua, 9, false, 3); y += lh;
      string mst = MasterFileExists ? "CONNECTED" : "WAITING FOR MASTER";
      CreateOrUpdateLabel("HCProps_MStatus", 20, y, "Master Status: " + mst, MasterFileExists ? clrLime : clrOrange, 11, true, 21); y += lh + 3;
     }

   string status = TradingIsDisabled() ? "DISABLED" : "ENABLED";
   CreateOrUpdateLabel("HCProps_Status", 20, y, "Trading Status: " + status, TradingIsDisabled() ? clrRed : clrLime, 11, true, 4); y += lh;

   if(Mode == MODE_MASTER && IsSlaveLockTradingDisabled)
     { CreateOrUpdateLabel("HCProps_SlaveLock", 20, y, "SLAVE LOCK: " + g_slaveLockInfo, clrRed, 9, true, 22); y += lh; }
   else
     { ObjectDelete(0, "HCProps_SlaveLock"); LastDashboardValues[22] = ""; }

   if(Mode == MODE_MASTER && (ExpectedSlaves > 0 || ArraySize(g_slvLogin) > 0))
     {
      string slvTxt = "Slaves alive: " + IntegerToString(g_slvFreshCount);
      if(ExpectedSlaves > 0)
         slvTxt += " / " + IntegerToString(ExpectedSlaves) + " required";
      if(IsSlaveDownTradingDisabled)
         slvTxt += "  (BLOCKING)";
      CreateOrUpdateLabel("HCProps_Slaves", 20, y, slvTxt,
                          IsSlaveDownTradingDisabled ? clrRed : clrLime, 9,
                          IsSlaveDownTradingDisabled, 23); y += lh;
     }
   else
     { ObjectDelete(0, "HCProps_Slaves"); LastDashboardValues[23] = ""; }

   if(IsNewsBlocked)
     {
      string ends = (g_activeNewsEnd > TimeCurrent())
                    ? " (ends in " + FmtIn(g_activeNewsEnd - TimeCurrent()) + ")" : "";
      CreateOrUpdateLabel("HCProps_News", 20, y, "NEWS ACTIVE: " + g_activeNews + ends, clrRed, 10, true, 5); y += lh;
     }
   else if(NewsMode != NEWS_OPERATE)
     {
      color wc = (ArraySize(g_newsTimes) == 0) ? clrOrange : clrLime; // 0 = broker likely serves no calendar
      CreateOrUpdateLabel("HCProps_News", 20, y, "News: watching (" + IntegerToString(ArraySize(g_newsTimes)) + ")", wc, 9, false, 5); y += lh;
     }
   else
     { ObjectDelete(0, "HCProps_News"); LastDashboardValues[5] = ""; } // OPERATE: no news line (don't stack an empty label on "Locks:")

   // Upcoming events that will pause trading (next 2), shown whenever the filter is on
   int nidx[];
   int ncnt = (NewsMode != NEWS_OPERATE) ? NextNewsEvents(nidx, 2) : 0;
   for(int k = 0; k < 2; k++)
     {
      string lname = "HCProps_NewsNext" + IntegerToString(k);
      int    lidx  = 24 + k;
      if(k < ncnt)
        {
         int      i     = nidx[k];
         datetime ev    = g_newsTimes[i];
         datetime start = ev - NewsDuration;
         string   nm    = g_newsName[i];
         if(StringLen(nm) > 30)
            nm = StringSubstr(nm, 0, 28) + "..";
         bool   soon = (start - TimeCurrent() <= 1800);
         string when = TimeToString(ev, (ev - TimeCurrent() > 86400) ? TIME_DATE | TIME_MINUTES : TIME_MINUTES);
         CreateOrUpdateLabel(lname, 30, y, "> " + when + " " + g_newsCurr[i] + " " + nm +
                             " (blocks in " + FmtIn(start - TimeCurrent()) + ")",
                             soon ? clrOrange : clrSilver, 9, false, lidx); y += lh - 2;
        }
      else
        { ObjectDelete(0, lname); LastDashboardValues[lidx] = ""; }
     }

   if(PropFirmMode)
     {
      string flags = ActiveLockFlags();
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
      if(MaxTradesTotal > 0)
        { color c = BandColor((double)TradesOpenedTotal / MaxTradesTotal);
          CreateOrUpdateLabel("HCProps_TradesTotal", 30, y, "Trades total: " + IntegerToString(TradesOpenedTotal) + " / " + IntegerToString(MaxTradesTotal), c, 9, false, 27); y += lh - 2; }
      if(MaxParallelTrades > 0)
        { color c = BandColor((double)CurrentTradesCount / MaxParallelTrades);
          CreateOrUpdateLabel("HCProps_TradesParallel", 30, y, "Parallel: " + IntegerToString(CurrentTradesCount) + " / " + IntegerToString(MaxParallelTrades), c, 9, false, 15); y += lh - 2; }
      if(MaxConsecWinsPerDay > 0)
        { color c = BandColor((double)ConsecutiveWinsToday / MaxConsecWinsPerDay);
          CreateOrUpdateLabel("HCProps_ConsecWins", 30, y, "Win streak: " + IntegerToString(ConsecutiveWinsToday) + " / " + IntegerToString(MaxConsecWinsPerDay), c, 9, false, 16); y += lh - 2; }
      if(MaxConsecLossesPerDay > 0)
        { color c = BandColor((double)ConsecutiveLossesToday / MaxConsecLossesPerDay);
          CreateOrUpdateLabel("HCProps_ConsecLosses", 30, y, "Loss streak: " + IntegerToString(ConsecutiveLossesToday) + " / " + IntegerToString(MaxConsecLossesPerDay), c, 9, false, 17); y += lh + 3; }
      if(MaxDailyNetWins > 0 || MaxDailyNetLosses > 0)
        {
         double nf = 0.0;
         if(NetTradesToday > 0 && MaxDailyNetWins   > 0) nf = (double)NetTradesToday    / MaxDailyNetWins;
         if(NetTradesToday < 0 && MaxDailyNetLosses > 0) nf = (double)(-NetTradesToday) / MaxDailyNetLosses;
         string up = MaxDailyNetWins   > 0 ? "+" + IntegerToString(MaxDailyNetWins)   : "off";
         string dn = MaxDailyNetLosses > 0 ? "-" + IntegerToString(MaxDailyNetLosses) : "off";
         string ns = (NetTradesToday >= 0 ? "+" : "") + IntegerToString(NetTradesToday);
         CreateOrUpdateLabel("HCProps_NetWL", 30, y, "Net W/L: " + ns + "  (max " + up + " / min " + dn + ")",
                             BandColor(nf), 9, false, 26); y += lh + 3;
        }

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

