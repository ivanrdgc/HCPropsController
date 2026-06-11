//+------------------------------------------------------------------+
//|  HCProps_Slave.mqh                                               |
//|  Slave side: replication, status file, ticket mapping            |
//|  Module of HCPropsController.mq5 - not compilable standalone.    |
//+------------------------------------------------------------------+

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
string    g_masterCurrency       = ""; // Master account currency from the SEQ line
string    g_masterCurrencyWarned = ""; // last mismatching currency we warned about

// Slave position ticket -> Master ticket (rebuilt on every reconcile pass; used
// to identify which Master position a broker-side close belonged to)
ulong g_mapSlaveTicket[];
ulong g_mapMasterTicket[];

// Master tickets this Slave closed on its own (SL/TP/manual/lock). They are not
// reopened while the Master processes the close request (the request stays in
// our status file until the ticket leaves the Master file = the ack); pruned
// when acked, or after 120 s (Master unreachable / propagation off there).
ulong    g_closedMasterTicket[];
datetime g_closedMasterWhen[];
string   g_closedMasterReason[];

// Per-ticket millisecond throttles (open retries, Master close retries, logs)
ulong g_openTryTicket[];  ulong g_openTryWhenMs[];
ulong g_closeTryTicket[]; ulong g_closeTryWhenMs[];
ulong g_ackLogTicket[];   ulong g_ackLogWhenMs[];

// Generic per-key throttle: true = seen within intervalMs (caller should skip);
// false = not seen recently (timestamp is refreshed).
bool ThrottledMs(ulong &keys[], ulong &whenMs[], ulong key, ulong intervalMs)
  {
   ulong now = (ulong)GetTickCount64();
   for(int i = 0; i < ArraySize(keys); i++)
      if(keys[i] == key)
        {
         if(now - whenMs[i] < intervalMs)
            return true;
         whenMs[i] = now;
         return false;
        }
   int n = ArraySize(keys);
   ArrayResize(keys, n + 1);
   ArrayResize(whenMs, n + 1);
   keys[n] = key;
   whenMs[n] = now;
   return false;
  }

void PruneThrottle(ulong &keys[], ulong &whenMs[], ulong maxAgeMs)
  {
   ulong now = (ulong)GetTickCount64();
   for(int i = ArraySize(keys) - 1; i >= 0; i--)
      if(now - whenMs[i] > maxAgeMs)
        {
         ArrayRemove(keys, i, 1);
         ArrayRemove(whenMs, i, 1);
        }
  }

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
// the Master to close. Prevents the open-phase from re-opening them and
// feeds the CLOSE lines of the status file (kept until acked = the ticket
// disappears from the Master file).
//-------------------------------------------------------------------
bool IsClosedMasterTicket(ulong mTicket)
  {
   for(int i = 0; i < ArraySize(g_closedMasterTicket); i++)
      if(g_closedMasterTicket[i] == mTicket)
         return true;
   return false;
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
         ArrayRemove(g_closedMasterReason, i, 1);
         g_statusDirty = true; // drop the CLOSE line from the status file
        }
     }
  }

void EnqueueMasterClose(ulong mTicket, string reason)
  {
   if(mTicket == 0 || IsClosedMasterTicket(mTicket))
      return;
   int n = ArraySize(g_closedMasterTicket);
   ArrayResize(g_closedMasterTicket, n + 1);
   ArrayResize(g_closedMasterWhen,   n + 1);
   ArrayResize(g_closedMasterReason, n + 1);
   g_closedMasterTicket[n] = mTicket;
   g_closedMasterWhen[n]   = TimeLocal();
   g_closedMasterReason[n] = reason;
   g_statusDirty = true;
   Print("SLAVE: queuing Master close request #", mTicket, " (", reason, ")");
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
      ulong mt = MasterTicketOfPosition(p);
      if(mt > 0)
         EnqueueMasterClose(mt, reason);
     }
  }

//-------------------------------------------------------------------
// Slave status file: <syncfile>.slave.<login>
//   HB,<TimeLocal stamp>
//   LOCK,<0|1>,<active lock flags>
//   CLOSE,<masterTicket>,<reason>     (0..n lines, until acked)
//   END,<same stamp>
// One file per Slave carries heartbeat + lock state + close requests.
// TimeLocal is the shared machine clock (broker server times differ).
// The END stamp lets the Master discard torn reads.
//-------------------------------------------------------------------
string SlaveStatusPath()
  {
   return GetSyncFilePath() + ".slave." + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
  }

void WriteSlaveStatusFile()
  {
   if(Mode != MODE_SLAVE)
      return;

   string rel    = SlaveStatusPath();
   long   stamp  = (long)TimeLocal();
   bool   locked = PropagateSlaveClose && TradingIsDisabled();
   string reason = locked ? ActiveLockFlags() : "";
   if(locked && reason == "")
      reason = "LOCKED";

   int h = FileOpen(rel, FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE, ',');
   if(h == INVALID_HANDLE)
     { g_statusDirty = true; return; } // retry next 200 ms tick
   FileWrite(h, "HB", IntegerToString(stamp));
   FileWrite(h, "LOCK", (locked ? "1" : "0"), reason);
   if(PropagateSlaveClose)
      for(int i = 0; i < ArraySize(g_closedMasterTicket); i++)
         FileWrite(h, "CLOSE", IntegerToString((long)g_closedMasterTicket[i]), g_closedMasterReason[i]);
   FileWrite(h, "END", IntegerToString(stamp));
   FileClose(h);
   g_statusDirty = false;

   if(locked != g_lastLockState)
     {
      if(locked)
         Print("SLAVE: trading locked (", reason, ") -> Master notified: new entries blocked everywhere");
      else
         Print("SLAVE: trading enabled again -> Master lock released");
      g_lastLockState = locked;
     }
  }

// Called from CheckAndUpdateTradingStatus so a lock transition reaches the
// Master immediately (not only on the next 1 s heartbeat).
void NotifyLockStateIfChanged()
  {
   if(Mode != MODE_SLAVE)
      return;
   bool nowLocked = PropagateSlaveClose && TradingIsDisabled();
   if(nowLocked != g_lastLockState)
      WriteSlaveStatusFile();
  }

// Folder part of the sync path (FileFindFirst returns bare names)
string SyncFolder()
  {
   string base = GetSyncFilePath();
   string parts[];
   int np = StringSplit(base, '\\', parts);
   if(np <= 1)
      return "";
   string folder = parts[0];
   for(int i = 1; i < np - 1; i++)
      folder += "\\" + parts[i];
   return folder;
  }

//-------------------------------------------------------------------
// Slave position ticket -> Master ticket
// Primary source: the HC<ticket> order comment. Backup: a GlobalVariable
// per position ("HCProps_Map_<slaveTicket>") written on every reconcile -
// some brokers strip/overwrite comments, and GVs also survive restarts.
//-------------------------------------------------------------------
string MapGVName(ulong slaveTicket)
  {
   return "HCProps_Map_" + IntegerToString((long)slaveTicket);
  }

// Resolve the Master ticket of a SELECTED slave position (comment, then GV).
ulong MasterTicketOfPosition(CPositionInfo &p)
  {
   ulong mt = ParseMasterTicketFromComment(p.Comment());
   if(mt == 0 && GlobalVariableCheck(MapGVName(p.Ticket())))
      mt = (ulong)GlobalVariableGet(MapGVName(p.Ticket()));
   return mt;
  }

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
      ulong mt = MasterTicketOfPosition(p);
      if(mt == 0)
         continue;
      GlobalVariableSet(MapGVName(p.Ticket()), (double)mt); // keep the backup fresh
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

   // GV backup (comment stripped by the broker and map not rebuilt yet)
   if(GlobalVariableCheck(MapGVName(posId)))
      return (ulong)GlobalVariableGet(MapGVName(posId));

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

// Delete map GVs of positions closed over an hour ago (keeps the GV pool bounded
// while leaving a generous window for post-close lookups).
void PruneMapGVs()
  {
   int total = GlobalVariablesTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      string name = GlobalVariableName(i);
      if(StringFind(name, "HCProps_Map_") != 0)
         continue;
      ulong tk = (ulong)StringToInteger(StringSubstr(name, 12));
      if(tk > 0 && PositionSelectByTicket(tk))
         continue;
      if(TimeLocal() - GlobalVariableTime(name) > 3600)
         GlobalVariableDel(name);
     }
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
         string mcur = FileIsLineEnding(h) ? "" : FileReadString(h);
         if(mcur != "")
           {
            g_masterCurrency = mcur;
            string own = AccountInfoString(ACCOUNT_CURRENCY);
            if(mcur != own && g_masterCurrencyWarned != mcur)
              {
               g_masterCurrencyWarned = mcur;
               Print("SLAVE: WARNING Master account currency is ", mcur, " but this account uses ", own,
                     " - AutoLotScaling compares raw tick values and may MIS-SCALE the lots!");
              }
           }
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

      ulong mt = MasterTicketOfPosition(pos); // comment, with GV backup
      int   idx = -1;
      // 1) match by Master ticket
      if(mt != 0)
         for(int t = 0; t < ArraySize(g_targets); t++)
            if(!g_targets[t].matched && g_targets[t].masterTicket == mt)
              { idx = t; break; }
      // 2) fallback: by symbol + direction if the mapping was lost entirely
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
         if(MasterTicketOfPosition(pos) == g_targets[t].masterTicket && pos.PositionType() == g_targets[t].dir)
           { present = true; break; }
        }
      if(present)
         continue;

      // Closed here on purpose (own SL/TP/manual/lock): the Master is being asked
      // to close it; do NOT reopen.
      if(PropagateSlaveClose && IsClosedMasterTicket(g_targets[t].masterTicket))
         continue;

      if(ThrottledMs(g_openTryTicket, g_openTryWhenMs, g_targets[t].masterTicket, 1500))
         continue; // failed opens retry every ~1.5 s, not every 200 ms

      // Guardian lock on this Slave: never replicate NEW positions while locked.
      // A Master position can only appear here through the lock-propagation race
      // window (or mismatched settings) - ask the Master to close it so the
      // "all accounts enabled or no new trades" invariant holds.
      if(TradingIsDisabled())
        {
         if(PropagateSlaveClose)
            EnqueueMasterClose(g_targets[t].masterTicket, "SLAVE_LOCKED:" + ActiveLockFlags());
         else
            Print("SLAVE: trading locked (", ActiveLockFlags(), ") - NOT replicating Master #",
                  g_targets[t].masterTicket);
         continue;
        }

      string sym = g_targets[t].symbol;
      if(!SymbolSelect(sym, true))
        { Print("SLAVE: symbol not available at the broker: ", sym); continue; }

      // Both clamp directions are dangerous: down = under-hedged, up = oversized risk.
      double raw = g_targets[t].rawVolume;
      if(raw > 0 && g_targets[t].volume > raw + 1e-8)
         Print("SLAVE: WARNING volume forced UP by broker min/step: requested ",
               DoubleToString(raw, 4), " -> trading ", DoubleToString(g_targets[t].volume, 2),
               " (OVERSIZED hedge x", DoubleToString(g_targets[t].volume / raw, 1), "!)");
      else if(g_targets[t].volume < raw - 1e-8)
         Print("SLAVE: WARNING volume clamped by broker limits: requested ",
               DoubleToString(raw, 2), " -> trading ",
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

