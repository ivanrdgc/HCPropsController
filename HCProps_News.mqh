//+------------------------------------------------------------------+
//|  HCProps_News.mqh                                                |
//|  News filter (MT5 native economic calendar)                      |
//|  Module of HCPropsController.mq5 - not compilable standalone.    |
//+------------------------------------------------------------------+

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
   if(ArraySize(g_newsTimes) == 0)
      Print("NEWS: WARNING protection is enabled but the calendar returned ZERO events - this broker may not serve ",
            "the MT5 calendar (check View -> Toolbox -> Calendar). The news filter is effectively INACTIVE!");
  }

// "in 45m" / "in 2h05m" / "<1m" - minute granularity keeps the panel calm
string FmtIn(long secs)
  {
   if(secs < 60)
      return "<1m";
   long m = secs / 60;
   if(m < 60)
      return IntegerToString(m) + "m";
   return IntegerToString(m / 60) + "h" + StringFormat("%02d", (int)(m % 60)) + "m";
  }

// Indices (into the g_news* arrays) of the next up-to-maxCount events whose
// protection window has not started yet, sorted by time.
int NextNewsEvents(int &idx[], int maxCount)
  {
   ArrayResize(idx, 0);
   datetime now = TimeCurrent();
   int used[];
   ArrayResize(used, ArraySize(g_newsTimes));
   ArrayInitialize(used, 0);
   for(int k = 0; k < maxCount; k++)
     {
      int best = -1;
      for(int i = 0; i < ArraySize(g_newsTimes); i++)
        {
         if(used[i] == 1)
            continue;
         if(g_newsTimes[i] - NewsDuration <= now)
            continue; // already started (or past)
         if(best < 0 || g_newsTimes[i] < g_newsTimes[best])
            best = i;
        }
      if(best < 0)
         break;
      used[best] = 1;
      int n = ArraySize(idx);
      ArrayResize(idx, n + 1);
      idx[n] = best;
     }
   return ArraySize(idx);
  }

// Returns true if we are inside the window of any news event
bool InNewsWindow()
  {
   g_activeNews = "";
   g_activeNewsEnd = 0;
   datetime now = TimeCurrent();
   for(int i = 0; i < ArraySize(g_newsTimes); i++)
     {
      if(now >= g_newsTimes[i] - NewsDuration && now <= g_newsTimes[i] + NewsDuration)
        {
         g_activeNews    = g_newsCurr[i] + " " + g_newsName[i];
         g_activeNewsEnd = g_newsTimes[i] + NewsDuration;
         return true;
        }
     }
   return false;
  }

void CheckNews()
  {
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

