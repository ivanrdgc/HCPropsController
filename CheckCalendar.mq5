//+------------------------------------------------------------------+
//|                                                CheckCalendar.mq5  |
//|  Verifies that the native MT5 economic calendar is              |
//|  available on your broker and that HCPropsController can read it.|
//|                                                                  |
//|  Usage: compile it (F7), drag it onto a chart (it is a Script).  |
//|  Look at the "Experts"/"Journal" tab for the result.            |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

input string InpCurrencies = "USD,EUR,GBP"; // Currencies to check (empty = all)
input int    InpDaysAhead  = 7;             // Days ahead to list
input int    InpMinImpact  = 3;             // Minimum impact (1=Low,2=Moderate,3=High)

void OnStart()
  {
   datetime from = TimeCurrent() - 86400;
   datetime to   = TimeCurrent() + InpDaysAhead * 86400;

   string curr[];
   int nCurr = 0;
   if(InpCurrencies != "")
     {
      nCurr = StringSplit(InpCurrencies, ',', curr);
      for(int i = 0; i < nCurr; i++) { StringTrimLeft(curr[i]); StringTrimRight(curr[i]); }
     }

   PrintFormat("=== CheckCalendar: %s -> %s ===", TimeToString(from), TimeToString(to));

   int grandTotal = 0;
   int shown = 0;

   if(nCurr == 0)
     {
      MqlCalendarValue values[];
      ResetLastError();
      int cnt = CalendarValueHistory(values, from, to);
      grandTotal = cnt;
      PrintFormat("Total events (all currencies): %d  (err=%d)", cnt, GetLastError());
      for(int i = 0; i < cnt && shown < 40; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev)) continue;
         if((int)ev.importance < InpMinImpact) continue;
         MqlCalendarCountry c; CalendarCountryById(ev.country_id, c);
         PrintFormat("%s | %s | imp=%d | %s", TimeToString(values[i].time), c.currency, (int)ev.importance, ev.name);
         shown++;
        }
     }
   else
     {
      for(int k = 0; k < nCurr; k++)
        {
         MqlCalendarValue values[];
         ResetLastError();
         int cnt = CalendarValueHistory(values, from, to, NULL, curr[k]);
         int kept = 0;
         for(int i = 0; i < cnt; i++)
           {
            MqlCalendarEvent ev;
            if(!CalendarEventById(values[i].event_id, ev)) continue;
            if((int)ev.importance < InpMinImpact) continue;
            kept++;
            grandTotal++;
            if(shown < 40)
              {
               PrintFormat("%s | %s | imp=%d | %s", TimeToString(values[i].time), curr[k], (int)ev.importance, ev.name);
               shown++;
              }
           }
         PrintFormat("  %s: %d total events, %d with impact>=%d  (err=%d)", curr[k], cnt, kept, InpMinImpact, GetLastError());
        }
     }

   if(grandTotal > 0)
      PrintFormat(">>> OK: the calendar works on this broker (%d relevant events). HCPropsController will be able to read the news.", grandTotal);
   else
      Print(">>> WARNING: 0 events. Check: (1) terminal connected, (2) View->Toolbox->Calendar shows events, (3) the broker serves the MetaQuotes calendar. If it is persistently empty, use NewsSource=URL in the EA.");
  }
//+------------------------------------------------------------------+
