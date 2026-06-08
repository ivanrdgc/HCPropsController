//+------------------------------------------------------------------+
//|                                                CheckCalendar.mq5  |
//|  Verifica que el calendario económico nativo de MT5 está         |
//|  disponible en tu broker y que HCPropsController podrá leerlo.   |
//|                                                                  |
//|  Uso: compílalo (F7), arrástralo a un gráfico (es un Script).   |
//|  Mira la pestaña "Expertos"/"Journal" para el resultado.        |
//+------------------------------------------------------------------+
#property strict
#property script_show_inputs

input string InpCurrencies = "USD,EUR,GBP"; // Currencies a comprobar (vacío = todas)
input int    InpDaysAhead  = 7;             // Días hacia adelante a listar
input int    InpMinImpact  = 3;             // Impacto mínimo (1=Low,2=Moderate,3=High)

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
      PrintFormat("Total de eventos (todas las currencies): %d  (err=%d)", cnt, GetLastError());
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
         PrintFormat("  %s: %d eventos totales, %d con impacto>=%d  (err=%d)", curr[k], cnt, kept, InpMinImpact, GetLastError());
        }
     }

   if(grandTotal > 0)
      PrintFormat(">>> OK: el calendario funciona en este broker (%d eventos relevantes). HCPropsController podrá leer las noticias.", grandTotal);
   else
      Print(">>> ATENCIÓN: 0 eventos. Verifica: (1) terminal conectado, (2) View->Toolbox->Calendar muestra eventos, (3) el broker sirve el calendario de MetaQuotes. Si está vacío de forma persistente, usa NewsSource=URL en el EA.");
  }
//+------------------------------------------------------------------+
