// Open-position floating guard. No account locks, pending deletes or SL/TP edits.
// Module of HCPropsController.mq5, not a standalone EA.

struct HCIdeaGroup
  {
   string symbol;
   ENUM_POSITION_TYPE dir;
   double pnl;
   int count;
   int reason; // 1 = loss, 2 = profit; sticky until this group is flat
   ulong anchor; // in-memory fallback if the persistence write itself fails
   bool latched;
   ulong nextAttempt;
   ulong nextLog;
  };
HCIdeaGroup g_ideaGroups[];
bool g_ideaPersistenceOK = true;

bool HCIdeaInputsValid()
  {
   return MathIsValidNumber(MaxLossPercentPerIdea) && MaxLossPercentPerIdea >= 0.0 &&
          MathIsValidNumber(MaxProfitPercentPerIdea) && MaxProfitPercentPerIdea >= 0.0;
  }

bool HCIdeaLimitsEnabled()
  { return MaxLossPercentPerIdea > 0.0 || MaxProfitPercentPerIdea > 0.0; }

bool HCIdeaBaseValid()
  {
   double base = AccountDepositsAndWithdrawals;
   if(!MathIsValidNumber(base) || base <= 0.0)
      return false;
   double loss = base * MaxLossPercentPerIdea / 100.0;
   double profit = base * MaxProfitPercentPerIdea / 100.0;
   return MathIsValidNumber(loss) && MathIsValidNumber(profit) &&
          (MaxLossPercentPerIdea == 0.0 || loss > 0.0) &&
          (MaxProfitPercentPerIdea == 0.0 || profit > 0.0);
  }

int HCIdeaBreach(double pnl)
  {
   if(!HCIdeaBaseValid() || !MathIsValidNumber(pnl))
      return 0;
   if(MaxLossPercentPerIdea > 0.0 && pnl <= -AccountDepositsAndWithdrawals * MaxLossPercentPerIdea / 100.0)
      return 1;
   if(MaxProfitPercentPerIdea > 0.0 && pnl >= AccountDepositsAndWithdrawals * MaxProfitPercentPerIdea / 100.0)
      return 2;
   return 0;
  }

string HCIdeaReason(int reason)
  { return reason == 1 ? "IDEA_LOSS" : "IDEA_PROFIT"; }

// Fixed-width full 64-bit fields: no hashing, truncation or double ticket encoding.
string HCIdeaHex(ulong value) { return StringFormat("%016I64X", value); }
string HCIdeaLatchPrefix()
  { return "HCI1_" + HCIdeaHex((ulong)AccountInfoInteger(ACCOUNT_LOGIN)) + "_"; }
string HCIdeaLatchKey(ulong id, ENUM_POSITION_TYPE dir)
  { return HCIdeaLatchPrefix() + HCIdeaHex(id) + "_" + IntegerToString((int)dir); }
bool HCIdeaPositionLatched(ulong id, ENUM_POSITION_TYPE dir)
  { return PropFirmMode && GlobalVariableCheck(HCIdeaLatchKey(id, dir)); }
string HCIdeaTombPrefix()
  { return "HCT1_" + HCIdeaHex((ulong)AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + HCIdeaHex((ulong)MagicNumber) + "_"; }
string HCIdeaTombKey(ulong ticket)
  { return HCIdeaTombPrefix() + HCIdeaHex(ticket); }

ulong HCIdeaFromHex(string text)
  {
   ulong value = 0;
   for(int i = 0; i < StringLen(text); i++)
     {
      int c = (int)StringGetCharacter(text, i);
      int digit = c >= '0' && c <= '9' ? c - '0' : c - 'A' + 10;
      if(digit < 0 || digit > 15)
         return 0;
      value = (value << 4) | (ulong)digit;
     }
   return value;
  }

bool HCIdeaIsTombstoned(ulong ticket)
  {
   string key = HCIdeaTombKey(ticket);
   if(!GlobalVariableCheck(key))
      return false;
   GlobalVariableGet(key); // refresh MT5's four-week unused-GV lifetime
   return true;
  }

// Positive value = propagate, negative = local only, captured at activation.
// Requests are restored even with both limits zero; current propagation OFF still
// suppresses their publication. Tombstones themselves always suppress reopening.
void HCIdeaRestoreSlaveCloses()
  {
   if(Mode != MODE_SLAVE)
      return;
   g_ideaHasTombstones = false;
   string prefix = HCIdeaTombPrefix();
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
     {
      string key = GlobalVariableName(i);
      if(StringFind(key, prefix) != 0 || StringLen(key) != StringLen(prefix) + 16)
         continue;
      g_ideaHasTombstones = true;
      double value = GlobalVariableGet(key);
      if(value > 0 && PropagateSlaveClose)
         EnqueueMasterClose(HCIdeaFromHex(StringSubstr(key, StringLen(prefix))), HCIdeaReason((int)value));
     }
  }

// Only a freshly parsed, structurally complete Master inventory may acknowledge
// these tickets. Use raw inventory, not targets filtered by symbol/lot availability.
void HCIdeaAckSlaveCloses(const ulong &masterTickets[])
  {
   string prefix = HCIdeaTombPrefix();
   bool changed = false;
   g_ideaHasTombstones = false;
   for(int i = GlobalVariablesTotal() - 1; i >= 0; i--)
     {
      string key = GlobalVariableName(i);
      if(StringFind(key, prefix) != 0 || StringLen(key) != StringLen(prefix) + 16)
         continue;
      GlobalVariableGet(key);
      ulong ticket = HCIdeaFromHex(StringSubstr(key, StringLen(prefix)));
      if(InUlongArray(masterTickets, ticket))
        { g_ideaHasTombstones = true; continue; }
      // A close can still be pending locally. Do not recreate a tombstone for a
      // ticket already acknowledged until that local inventory has gone too.
      bool local = false;
      CPositionInfo p;
      for(int j = PositionsTotal() - 1; j >= 0; j--)
         if(p.SelectByIndex(j) && (long)p.Magic() == MagicNumber && MasterTicketOfPosition(p) == ticket)
           { local = true; break; }
      if(local)
        { g_ideaHasTombstones = true; continue; }
      if(GlobalVariableDel(key))
        {
         changed = true;
         for(int j = ArraySize(g_closedMasterTicket) - 1; j >= 0; j--)
            if(g_closedMasterTicket[j] == ticket)
              {
               ArrayRemove(g_closedMasterTicket, j, 1);
               ArrayRemove(g_closedMasterWhen, j, 1);
               ArrayRemove(g_closedMasterReason, j, 1);
               g_statusDirty = true;
              }
        }
      else
         g_ideaHasTombstones = true;
     }
   if(changed)
      GlobalVariablesFlush();
  }

bool HCIdeaPersistPosition(ulong ticket, int reason, bool &changed)
  {
   if(!PositionSelectByTicket(ticket))
      return true;
   string key = HCIdeaLatchKey((ulong)PositionGetInteger(POSITION_IDENTIFIER),
                              (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE));
   if(!GlobalVariableCheck(key))
     {
      if(GlobalVariableSet(key, (double)reason) == 0)
         return false;
      changed = true;
     }
   if(Mode != MODE_SLAVE || PositionGetInteger(POSITION_MAGIC) != MagicNumber)
      return true;
   CPositionInfo p;
   if(!p.SelectByTicket(ticket))
      return true;
   ulong mt = MasterTicketOfPosition(p);
   if(mt == 0)
      return true; // not a known replicated position
   key = HCIdeaTombKey(mt);
   if(!GlobalVariableCheck(key))
     {
      if(GlobalVariableSet(key, PropagateSlaveClose ? (double)reason : -(double)reason) == 0)
         return false;
      changed = true;
     }
   double value = GlobalVariableGet(key);
   g_ideaHasTombstones = true;
   if(PropagateSlaveClose && value > 0)
      EnqueueMasterClose(mt, HCIdeaReason((int)value));
   return true;
  }

void CheckIdeaLimits(bool closePositions = true)
  {
   if(!PropFirmMode)
      return;
   g_ideaPersistenceOK = true;
   ulong now = GetTickCount64();
   for(int g = 0; g < ArraySize(g_ideaGroups); g++)
     { g_ideaGroups[g].pnl = 0.0; g_ideaGroups[g].count = 0; g_ideaGroups[g].latched = false; }

   // One snapshot of ALL open positions, irrespective of EA, magic or copy filter.
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      string symbol = PositionGetString(POSITION_SYMBOL);
      ENUM_POSITION_TYPE dir = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      int idx = -1;
      for(int g = 0; g < ArraySize(g_ideaGroups); g++)
         if(g_ideaGroups[g].symbol == symbol && g_ideaGroups[g].dir == dir)
           { idx = g; break; }
      if(idx < 0)
        {
         idx = ArraySize(g_ideaGroups);
         ArrayResize(g_ideaGroups, idx + 1);
         g_ideaGroups[idx].symbol = symbol; g_ideaGroups[idx].dir = dir;
         g_ideaGroups[idx].pnl = 0.0; g_ideaGroups[idx].count = 0;
         g_ideaGroups[idx].reason = 0;
         g_ideaGroups[idx].anchor = 0; g_ideaGroups[idx].latched = false;
         g_ideaGroups[idx].nextAttempt = 0; g_ideaGroups[idx].nextLog = 0;
        }
      g_ideaGroups[idx].pnl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      g_ideaGroups[idx].count++;
      ulong id = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      string key = HCIdeaLatchKey(id, dir);
      if(GlobalVariableCheck(key))
        { g_ideaGroups[idx].reason = (int)GlobalVariableGet(key); g_ideaGroups[idx].latched = true; }
      else if(id == g_ideaGroups[idx].anchor && g_ideaGroups[idx].reason != 0)
         g_ideaGroups[idx].latched = true;
     }

   bool changed = false;
   for(int g = ArraySize(g_ideaGroups) - 1; g >= 0; g--)
     {
      if(g_ideaGroups[g].count == 0)
        { ArrayRemove(g_ideaGroups, g, 1); continue; }
      if(!g_ideaGroups[g].latched)
        {
         // No old position remains: neither intent nor retry delay belongs to the new idea.
         g_ideaGroups[g].reason = 0;
         g_ideaGroups[g].nextAttempt = 0; g_ideaGroups[g].nextLog = 0;
        }
      if(g_ideaGroups[g].reason == 0)
        {
         g_ideaGroups[g].reason = HCIdeaBreach(g_ideaGroups[g].pnl);
         if(g_ideaGroups[g].reason != 0)
           {
            double pct = g_ideaGroups[g].reason == 1 ? MaxLossPercentPerIdea : MaxProfitPercentPerIdea;
            Print("HC ", HCIdeaReason(g_ideaGroups[g].reason), " symbol=", g_ideaGroups[g].symbol,
                  " dir=", EnumToString(g_ideaGroups[g].dir), " pnl=", g_ideaGroups[g].pnl,
                  " base=", AccountDepositsAndWithdrawals, " threshold=",
                  (g_ideaGroups[g].reason == 1 ? -1.0 : 1.0) * AccountDepositsAndWithdrawals * pct / 100.0);
           }
        }
      if(g_ideaGroups[g].reason == 0)
         continue;

      // Persist the whole group BEFORE the first request, including late arrivals
      // even during backoff. A rejection/partial/rebound never cancels intent.
      ulong tickets[];
      bool durable = true;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != g_ideaGroups[g].symbol ||
            PositionGetInteger(POSITION_TYPE) != g_ideaGroups[g].dir)
            continue;
         int n = ArraySize(tickets); ArrayResize(tickets, n + 1); tickets[n] = ticket;
         g_ideaGroups[g].anchor = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
         if(!HCIdeaPersistPosition(ticket, g_ideaGroups[g].reason, changed))
            durable = false;
        }
      if(changed)
        { GlobalVariablesFlush(); changed = false; }
      if(!durable)
        {
         g_ideaPersistenceOK = false;
         if(now >= g_ideaGroups[g].nextLog)
           { Print("HC idea persistence failed: ", g_ideaGroups[g].symbol, " error=", GetLastError());
             g_ideaGroups[g].nextLog = now + 30000; }
         continue;
        }
      if(!closePositions)
         continue;
      if(Mode == MODE_SLAVE && PropagateSlaveClose && g_statusDirty)
         WriteSlaveStatusFile(); // queue/publish only this group's mapped tickets before local close
      if(now < g_ideaGroups[g].nextAttempt)
         continue;
      if(!TerminalInfoInteger(TERMINAL_CONNECTED))
        { g_ideaGroups[g].nextAttempt = now + 5000; continue; }
      ulong delay = 1000;
      HC_CLOSE_TRADE_CLASS trade;
      trade.SetAsyncMode(false); trade.SetDeviationInPoints(Slippage);
      for(int i = 0; i < ArraySize(tickets); i++)
        {
         if(!PositionSelectByTicket(tickets[i]) || PositionGetString(POSITION_SYMBOL) != g_ideaGroups[g].symbol ||
            PositionGetInteger(POSITION_TYPE) != g_ideaGroups[g].dir)
            continue; // in particular, never close a netting reversal in the other direction
         trade.SetTypeFillingBySymbol(g_ideaGroups[g].symbol);
         bool accepted = trade.PositionClose(tickets[i]);
         uint rc = trade.ResultRetcode();
         if(rc == TRADE_RETCODE_MARKET_CLOSED || rc == TRADE_RETCODE_CONNECTION)
            delay = 5000;
         if((!accepted || rc != TRADE_RETCODE_DONE || PositionSelectByTicket(tickets[i])) && now >= g_ideaGroups[g].nextLog)
           {
            Print("HC ", HCIdeaReason(g_ideaGroups[g].reason), " retry symbol=", g_ideaGroups[g].symbol,
                  " dir=", EnumToString(g_ideaGroups[g].dir), " ticket=", tickets[i], " retcode=", rc);
            g_ideaGroups[g].nextLog = now + 30000;
           }
        }
      g_ideaGroups[g].nextAttempt = GetTickCount64() + delay;
      CountCurrentTrades();

      bool remaining = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0 || PositionGetString(POSITION_SYMBOL) != g_ideaGroups[g].symbol ||
            PositionGetInteger(POSITION_TYPE) != g_ideaGroups[g].dir)
            continue;
         remaining = true;
         if(!HCIdeaPersistPosition(ticket, g_ideaGroups[g].reason, changed))
            g_ideaPersistenceOK = false;
        }
      if(!remaining)
         ArrayRemove(g_ideaGroups, g, 1); // flat confirmed: no cooldown for a genuinely new idea
     }

   // Never infer closure from missing/offline inventory on disconnection.
   if(TerminalInfoInteger(TERMINAL_CONNECTED))
     {
      string prefix = HCIdeaLatchPrefix();
      for(int k = GlobalVariablesTotal() - 1; k >= 0; k--)
        {
         string key = GlobalVariableName(k);
         if(StringFind(key, prefix) != 0)
            continue;
         bool live = false;
         for(int i = PositionsTotal() - 1; i >= 0; i--)
            if(PositionGetTicket(i) > 0 && key == HCIdeaLatchKey((ulong)PositionGetInteger(POSITION_IDENTIFIER),
                                                               (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)))
              { live = true; break; }
         if(!live && GlobalVariableDel(key))
            changed = true;
        }
     }
   if(changed)
      GlobalVariablesFlush();
  }
