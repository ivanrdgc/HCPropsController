//+------------------------------------------------------------------+
//|  HCProps_Util.mqh                                                |
//|  Shared structures, paths, parsing and small helpers             |
//|  Module of HCPropsController.mq5 - not compilable standalone.    |
//+------------------------------------------------------------------+

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

//-------------------------------------------------------------------
// Misc safety helpers
//-------------------------------------------------------------------
// One Master per FileName per terminal (GlobalVariable mutex holding the chart id).
string MasterMutexGVName()
  {
   string label = SyncFileLabel();
   if(StringLen(label) > 40)
      label = StringSubstr(label, StringLen(label) - 40); // GV names are capped at 63 chars
   return "HCProps_Master_" + label;
  }

// v2.20 used <syncfile>.close.<login> and <syncfile>.lock.<login>; both are
// replaced by <syncfile>.slave.<login>. Clean leftovers up on init.
void CleanupLegacySideFiles()
  {
   string base   = GetSyncFilePath();
   string folder = SyncFolder();
   string suffixes[2] = {".close.", ".lock."};
   string ownLogin = IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));

   for(int s = 0; s < 2; s++)
     {
      string found;
      long fh = FileFindFirst(base + suffixes[s] + "*", found, FILE_COMMON);
      if(fh == INVALID_HANDLE)
         continue;
      string files[];
      do
        {
         int n = ArraySize(files);
         ArrayResize(files, n + 1);
         files[n] = found;
        }
      while(FileFindNext(fh, found));
      FileFindClose(fh);
      for(int f = 0; f < ArraySize(files); f++)
        {
         // The Master cleans everything; a Slave only its own leftovers.
         if(Mode == MODE_SLAVE && StringFind(files[f], suffixes[s] + ownLogin) < 0)
            continue;
         string rel = (folder == "") ? files[f] : folder + "\\" + files[f];
         if(FileDelete(rel, FILE_COMMON))
            Print("Removed legacy v2.2 side file: ", files[f]);
        }
     }
  }

//-------------------------------------------------------------------
// Trade log for hedge reconciliation: one CSV per account
// (<syncfile>.trades.<login>.csv). Join Master and Slave files on
// masterTicket to measure the per-pair leakage.
//-------------------------------------------------------------------
string ReasonText(ENUM_DEAL_REASON r)
  {
   switch(r)
     {
      case DEAL_REASON_SL:     return "SL";
      case DEAL_REASON_TP:     return "TP";
      case DEAL_REASON_SO:     return "STOPOUT";
      case DEAL_REASON_EXPERT: return "EA";
      case DEAL_REASON_CLIENT:
      case DEAL_REASON_MOBILE:
      case DEAL_REASON_WEB:    return "MANUAL";
      default:                 return EnumToString(r);
     }
  }

void LogClosedDeal(ulong dealTicket)
  {
   if(!TradePairLog)
      return;
   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;
   long dt = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   if(dt != DEAL_TYPE_BUY && dt != DEAL_TYPE_SELL)
      return;

   ulong posId   = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   ulong mTicket = (Mode == MODE_MASTER) ? posId : MasterTicketForSlavePosition(posId);

   string rel = GetSyncFilePath() + ".trades." + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".csv";
   int h = FileOpen(rel, FILE_READ | FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE, ',');
   if(h == INVALID_HANDLE)
      return; // logging must never block trading
   if(FileSize(h) == 0)
      FileWrite(h, "closeTimeLocal", "mode", "masterTicket", "positionId", "symbol", "side",
                "volume", "closePrice", "profit", "swap", "commission", "reason");
   else
      FileSeek(h, 0, SEEK_END);
   FileWrite(h,
             TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS),
             (Mode == MODE_MASTER ? "M" : "S"),
             IntegerToString((long)mTicket),
             IntegerToString((long)posId),
             HistoryDealGetString(dealTicket, DEAL_SYMBOL),
             (dt == DEAL_TYPE_BUY ? "SHORT" : "LONG"), // the deal closes the opposite-side position
             DoubleToString(HistoryDealGetDouble(dealTicket, DEAL_VOLUME), 2),
             DoubleToString(HistoryDealGetDouble(dealTicket, DEAL_PRICE), 5),
             DoubleToString(HistoryDealGetDouble(dealTicket, DEAL_PROFIT), 2),
             DoubleToString(HistoryDealGetDouble(dealTicket, DEAL_SWAP), 2),
             DoubleToString(HistoryDealGetDouble(dealTicket, DEAL_COMMISSION), 2),
             ReasonText((ENUM_DEAL_REASON)HistoryDealGetInteger(dealTicket, DEAL_REASON)));
   FileClose(h);
  }

