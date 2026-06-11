//+------------------------------------------------------------------+
//|  HCProps_Master.mqh                                              |
//|  Master side: sync file writer + Slave status processing         |
//|  Module of HCPropsController.mq5 - not compilable standalone.    |
//+------------------------------------------------------------------+

//===================================================================
// SYNCHRONIZATION: MASTER WRITES
//===================================================================
// MASTER: warn once per ticket when a position is excluded by the Symbols
// filter - it stays UNHEDGED, which is almost never what a hedge setup wants.
ulong g_warnedExcluded[];
void WarnExcludedOnce(ulong ticket, string sym)
  {
   if(InUlongArray(g_warnedExcluded, ticket))
      return;
   int n = ArraySize(g_warnedExcluded);
   ArrayResize(g_warnedExcluded, n + 1);
   g_warnedExcluded[n] = ticket;
   Print("MASTER: WARNING position #", ticket, " (", sym, ") is NOT replicated (Symbols filter) - it is UNHEDGED");
  }

void PruneWarnedExcluded()
  {
   for(int i = ArraySize(g_warnedExcluded) - 1; i >= 0; i--)
      if(!PositionSelectByTicket(g_warnedExcluded[i]))
         ArrayRemove(g_warnedExcluded, i, 1);
  }

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
        {
         WarnExcludedOnce(ticket, p.Symbol());
         continue;
        }
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
//   SEQ,<n>,<masterAccountCurrency>
//   ticket,symbol,type,volume,openPrice,sl,tp,openTime,pointValuePerLot
//   ...
//   END,<n>
// The SEQ/END pair detects both unchanged content (same seq) and torn reads
// (Slave reading while the Master rewrites): a file without a matching END
// is discarded and re-read on the next 200 ms tick. The currency lets Slaves
// validate the AutoLotScaling assumption (same account currency on both sides).
bool WriteSyncFile()
  {
   string rel = GetSyncFilePath();

   // Ensure folder (Common\Files\HCPropsController)
   ResetLastError();
   FolderCreate(HCPROPS_KEY, FILE_COMMON); // if it already exists, returns error 5019 (ignored)

   // Cross-terminal duplicate-Master detection: if the file's SEQ is not the one
   // we wrote last, somebody else is writing it (the same-terminal case is caught
   // by the chart mutex at init; this catches a second terminal).
   if(SyncFileInitialized && FileIsExist(rel, FILE_COMMON))
     {
      int hr = FileOpen(rel, FILE_READ | FILE_CSV | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE, ',');
      if(hr != INVALID_HANDLE)
        {
         string tag = FileIsEnding(hr) ? "" : FileReadString(hr);
         if(tag == "SEQ")
           {
            ulong fileSeq = (ulong)StringToInteger(FileReadString(hr));
            static datetime lastForeignWarn = 0;
            if(fileSeq != g_syncSeq && TimeLocal() - lastForeignWarn > 60)
              {
               lastForeignWarn = TimeLocal();
               Print("ERROR: sync file '", rel, "' was rewritten by ANOTHER Master (seq ", fileSeq,
                     " != ours ", g_syncSeq, "). Two Masters on the same FileName?!");
              }
           }
         FileClose(hr);
        }
     }

   if(g_syncSeq == 0)
      g_syncSeq = (ulong)GetTickCount64(); // survives EA restarts without repeating old values
   g_syncSeq++;

   ResetLastError();
   int h = FileOpen(rel, FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE, ',');
   int retry = 0;
   while(h == INVALID_HANDLE && retry < 2) { Sleep(10); ResetLastError(); h = FileOpen(rel, FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE, ','); retry++; }
   if(h == INVALID_HANDLE)
     { Print("ERROR: could not open sync file: ", rel, " err=", GetLastError()); return false; }

   FileWrite(h, "SEQ", IntegerToString((long)g_syncSeq), AccountInfoString(ACCOUNT_CURRENCY));

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

//-------------------------------------------------------------------
// MASTER: Slave status cache (per login; survives torn reads)
//-------------------------------------------------------------------
int SlvIndex(string login)
  {
   for(int i = 0; i < ArraySize(g_slvLogin); i++)
      if(g_slvLogin[i] == login)
         return i;
   return -1;
  }

void SlvUpsert(string login, datetime hb, bool locked, string reason)
  {
   int i = SlvIndex(login);
   if(i < 0)
     {
      i = ArraySize(g_slvLogin);
      ArrayResize(g_slvLogin, i + 1);
      ArrayResize(g_slvHb, i + 1);
      ArrayResize(g_slvLocked, i + 1);
      ArrayResize(g_slvReason, i + 1);
      Print("MASTER: Slave ", login, " status file discovered");
     }
   g_slvLogin[i]  = login;
   g_slvHb[i]     = hb;
   g_slvLocked[i] = locked;
   g_slvReason[i] = reason;
  }

void SlvRemoveMissing(string &present[])
  {
   for(int i = ArraySize(g_slvLogin) - 1; i >= 0; i--)
     {
      bool found = false;
      for(int j = 0; j < ArraySize(present); j++)
         if(present[j] == g_slvLogin[i])
           { found = true; break; }
      if(!found)
        {
         Print("MASTER: Slave ", g_slvLogin[i], " status file removed (EA deliberately unloaded)");
         ArrayRemove(g_slvLogin, i, 1);
         ArrayRemove(g_slvHb, i, 1);
         ArrayRemove(g_slvLocked, i, 1);
         ArrayRemove(g_slvReason, i, 1);
        }
     }
  }

// MASTER (every 200 ms): read all <syncfile>.slave.* files.
//  - executes CLOSE requests (idempotent: retried while the line persists),
//  - any LOCKed Slave -> IsSlaveLockTradingDisabled,
//  - fewer fresh heartbeats than ExpectedSlaves -> IsSlaveDownTradingDisabled.
// Torn reads keep the cached state for that Slave.
void ProcessSlaveStatusFiles()
  {
   if(Mode != MODE_MASTER)
      return;

   string base   = GetSyncFilePath();
   string folder = SyncFolder();

   string names[];
   string logins[];
   string found;
   long fh = FileFindFirst(base + ".slave.*", found, FILE_COMMON);
   if(fh != INVALID_HANDLE)
     {
      do
        {
         int n = ArraySize(names);
         ArrayResize(names, n + 1);
         names[n] = found;
        }
      while(FileFindNext(fh, found));
      FileFindClose(fh);
     }

   CTrade trade;
   trade.SetDeviationInPoints(Slippage);
   bool closedAny = false;

   for(int f = 0; f < ArraySize(names); f++)
     {
      string login = "";
      int p = StringFind(names[f], ".slave.");
      if(p >= 0)
         login = StringSubstr(names[f], p + 7);
      int ln = ArraySize(logins);
      ArrayResize(logins, ln + 1);
      logins[ln] = login;

      string rel = (folder == "") ? names[f] : folder + "\\" + names[f];
      int h = FileOpen(rel, FILE_READ | FILE_CSV | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE, ',');
      if(h == INVALID_HANDLE)
         continue; // Slave mid-write: keep cached state, retry next tick

      datetime hb = 0;
      bool     locked = false;
      string   reason = "";
      ulong    clTickets[];
      string   clReasons[];
      bool     gotEnd = false;

      while(!FileIsEnding(h))
        {
         string tag = FileReadString(h);
         if(StringLen(tag) == 0)
            break;
         if(tag == "HB")
            hb = (datetime)StringToInteger(FileReadString(h));
         else if(tag == "LOCK")
           {
            locked = (FileReadString(h) == "1");
            reason = FileIsLineEnding(h) ? "" : FileReadString(h);
           }
         else if(tag == "CLOSE")
           {
            ulong t = (ulong)StringToInteger(FileReadString(h));
            string r = FileIsLineEnding(h) ? "" : FileReadString(h);
            if(t > 0)
              {
               int n = ArraySize(clTickets);
               ArrayResize(clTickets, n + 1);
               ArrayResize(clReasons, n + 1);
               clTickets[n] = t;
               clReasons[n] = r;
              }
           }
         else if(tag == "END")
           {
            gotEnd = ((datetime)StringToInteger(FileReadString(h)) == hb);
            break;
           }
         else // unknown tag: skip the rest of the line (forward compatibility)
            while(!FileIsLineEnding(h) && !FileIsEnding(h))
               FileReadString(h);
        }
      FileClose(h);

      if(!gotEnd || hb == 0)
         continue; // torn read: keep cached state

      SlvUpsert(login, hb, locked, reason);

      // ---- execute close requests (idempotent; throttled per ticket) ----
      if(PropagateSlaveClose)
         for(int c = 0; c < ArraySize(clTickets); c++)
           {
            ulong ticket = clTickets[c];
            if(PositionSelectByTicket(ticket))
              {
               if(ThrottledMs(g_closeTryTicket, g_closeTryWhenMs, ticket, 2000))
                  continue;
               trade.SetTypeFillingBySymbol(PositionGetString(POSITION_SYMBOL));
               if(trade.PositionClose(ticket))
                 {
                  closedAny = true;
                  Print("MASTER: position #", ticket, " closed on Slave ", login, " request (", clReasons[c], ")");
                 }
               else
                  Print("MASTER: FAILED to close #", ticket, " on Slave request (", clReasons[c], ") ret=",
                        trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ") - will retry");
              }
            else if(!ThrottledMs(g_ackLogTicket, g_ackLogWhenMs, ticket, 60000))
               Print("MASTER: Slave ", login, " close request for #", ticket, " (", clReasons[c], ") - already closed");
           }
     }

   SlvRemoveMissing(logins);

   // ---- evaluate lock + heartbeat flags from the cache ----
   bool wasLock = IsSlaveLockTradingDisabled;
   bool wasDown = IsSlaveDownTradingDisabled;

   IsSlaveLockTradingDisabled = false;
   g_slaveLockInfo = "";
   g_slvFreshCount = 0;

   datetime now = TimeLocal();
   for(int i = 0; i < ArraySize(g_slvLogin); i++)
     {
      bool fresh = (now - g_slvHb[i] <= SlaveHeartbeatTimeoutSec);
      if(fresh)
         g_slvFreshCount++;
      if(PropagateSlaveClose && g_slvLocked[i])
        {
         IsSlaveLockTradingDisabled = true;
         if(g_slaveLockInfo != "")
            g_slaveLockInfo += " | ";
         g_slaveLockInfo += g_slvLogin[i] + " (" + g_slvReason[i] + (fresh ? "" : ", STALE") + ")";
        }
     }

   IsSlaveDownTradingDisabled = (ExpectedSlaves > 0 && g_slvFreshCount < ExpectedSlaves);
   g_slaveDownInfo = IntegerToString(g_slvFreshCount) + "/" + IntegerToString(ExpectedSlaves) + " Slaves alive";

   if(IsSlaveLockTradingDisabled && !wasLock)
      Print("MASTER: Slave reports trading disabled -> blocking new entries. [", g_slaveLockInfo, "]");
   if(!IsSlaveLockTradingDisabled && wasLock)
      Print("MASTER: all Slave locks released.");
   if(IsSlaveDownTradingDisabled && !wasDown)
      Print("MASTER: SLAVE HEARTBEAT MISSING (", g_slaveDownInfo, ") -> blocking new entries (unhedged risk!)");
   if(!IsSlaveDownTradingDisabled && wasDown)
      Print("MASTER: all expected Slave heartbeats present again (", g_slaveDownInfo, ")");

   if(wasLock != IsSlaveLockTradingDisabled || wasDown != IsSlaveDownTradingDisabled)
     {
      DashboardNeedsUpdate = true;
      CheckAndUpdateTradingStatus(); // apply immediately, not on the next 1 s pass
     }

   if(closedAny)
      SyncPositionsToFile();
  }

