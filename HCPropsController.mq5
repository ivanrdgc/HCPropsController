//+------------------------------------------------------------------+
//|                                            HCPropsController.mq5 |
//|  Copy-trading (Master/Slave) + prop-firm guardian + news filter  |
//|  Single EA, file-based sync on the same VPS. No backend/license. |
//+------------------------------------------------------------------+
#property strict
#property version "2.00"
#property description "HCPropsController: Master/Slave copy trading, prop-firm limits y filtro de noticias en un solo EA."

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
   MODE_MASTER = 0, // Master (ejecuta operaciones)
   MODE_SLAVE  = 1  // Slave (replica operaciones)
  };

enum HCCopyMode
  {
   COPY_NORMAL    = 0, // NORMAL (replica también modificaciones de SL/TP)
   COPY_INCOGNITO = 1  // INCOGNITO (SL/TP solo al abrir; ignora cambios)
  };

enum HCNewsMode
  {
   NEWS_OPERATE    = 0, // OPERATE (no hacer nada)
   NEWS_PAUSE_OPEN = 1, // PAUSE_OPEN (bloquear aperturas; mantener posiciones)
   NEWS_CLOSE_ALL  = 2  // CLOSE_ALL (cerrar todo + bloquear)
  };

// Valores alineados con ENUM_CALENDAR_EVENT_IMPORTANCE (LOW=1, MODERATE=2, HIGH=3)
enum HCNewsImpact
  {
   NEWS_IMP_LOW      = 1, // Bajo o superior
   NEWS_IMP_MODERATE = 2, // Moderado o superior
   NEWS_IMP_HIGH     = 3  // Solo alto impacto
  };

enum HCNewsSource
  {
   NEWS_SOURCE_MT5 = 0, // Calendario nativo de MetaTrader 5 (recomendado)
   NEWS_SOURCE_URL = 1  // Feed CSV propio por WebRequest
  };

//===================================================================
// INPUT PARAMETERS
//===================================================================
input group "=== CONFIGURACIÓN GENERAL ==="
input HCMode Mode                 = MODE_MASTER; // Modo de operación
input bool   PropFirmMode         = true;        // Activar guardián de límites (solo MASTER)
input double ForceInitialBalance  = 0.0;         // Forzar balance inicial (0 = detectar automáticamente)
input bool   ResetCountersOnInit  = false;       // Resetear contadores y bloqueos al iniciar (solo MASTER)

input group "=== ARCHIVO DE SINCRONIZACIÓN ==="
input string FileName             = "";          // Nombre del archivo (vacío = auto por servidor+cuenta)
input string CustomFilePath       = "";          // Ruta personalizada dentro de Common\Files (opcional)
input string Symbols              = "";          // (MASTER) Símbolos a replicar, coma-sep (vacío = todos)

input group "=== CONFIGURACIÓN SLAVE (Solo modo SLAVE) ==="
input string     MasterServer        = "";        // Servidor de la cuenta Master (si FileName está vacío)
input long       MasterAccountNumber = 0;         // Número de la cuenta Master (si FileName está vacío)
input string     SymbolMapping       = "";        // Mapeo MAST:SLAV;MAST2:SLAV2 (opcional)
input HCCopyMode CopyMode            = COPY_NORMAL;// Modo de copia
input bool       InverseMode         = false;     // Invertir operaciones del Master (y SL/TP)
input double     RiskMultiplier      = 1.0;       // Multiplicador de lotaje (lote Slave = lote Master x mult)
input int        Slippage            = 10;        // Slippage permitido (puntos)
input long       MagicNumber         = 987654;    // Magic Number de las órdenes del Slave
input double     SlaveTotalProfitLimitPercent = 0.0; // Límite total de ganancia del Slave (%); 0 = no

input group "=== LÍMITES DE EQUITY (Solo modo MASTER) ==="
input double DailyProfitLimitPercent = 4.6; // Límite diario de ganancia (%); 0 = no limitado
input double DailyLossLimitPercent   = 4.6; // Límite diario de pérdida (%); 0 = no limitado
input double TotalProfitLimitPercent = 8.1; // Límite total de ganancia (%); 0 = no limitado
input double TotalLossLimitPercent   = 8.1; // Límite total de pérdida (%); 0 = no limitado

input group "=== LÍMITES DE TRADING (Solo modo MASTER) ==="
input int    MaxParallelTrades      = 1; // Límite de operaciones paralelas; 0 = no limitado
input int    MaxTradesPerDay        = 1; // Límite de trades por día; 0 = no limitado
input int    MaxConsecLossesPerDay  = 0; // Límite de pérdidas consecutivas por día; 0 = no limitado
input int    MaxConsecWinsPerDay    = 0; // Límite de ganancias consecutivas por día; 0 = no limitado

input group "=== RESETEO DIARIO (Solo modo MASTER) ==="
input int    DailyResetHour   = 0; // Hora de reseteo diario (0-23)
input int    DailyResetMinute = 0; // Minuto de reseteo diario (0-59)

input group "=== HORARIOS DE TRADING (Solo modo MASTER) ==="
input bool   LimitTradingHours  = true; // Limitar aperturas a las horas especificadas
input int    TradingStartHour   = 6;    // Hora de inicio del trading (0-23)
input int    TradingStartMinute = 0;    // Minuto de inicio del trading (0-59)
input int    TradingEndHour     = 20;   // Hora de fin del trading (0-23)
input int    TradingEndMinute   = 0;    // Minuto de fin del trading (0-59)

input group "=== CIERRE FORZADO (Solo modo MASTER) ==="
input bool   ForceExitEnabled = true; // Forzar cierre a la hora especificada
input int    TradingExitHour   = 22;  // Hora de cierre forzado (0-23)
input int    TradingExitMinute = 0;   // Minuto de cierre forzado (0-59)

input group "=== PROTECCIÓN DE NOTICIAS (Solo modo MASTER) ==="
input HCNewsMode   NewsMode       = NEWS_OPERATE;   // Modo de gestión de noticias
input int          NewsDuration   = 120;            // Protección antes y después (segundos)
input string       NewsCurrencies = "";             // Currencies a vigilar (ej: EUR,USD,GBP); vacío = símbolo del gráfico
input HCNewsImpact NewsMinImpact  = NEWS_IMP_HIGH;  // Impacto mínimo a considerar
input HCNewsSource NewsSource     = NEWS_SOURCE_MT5;// Fuente del calendario
input string       NewsCalendarUrl= "";             // (NEWS_SOURCE_URL) URL del feed CSV "epoch,CURRENCY,impact"

//===================================================================
// GLOBAL VARIABLES (claves)
//===================================================================
string HCPROPS_KEY    = "HCPropsController";
string GV_DISABLE     = "HCPropsControllerDisableTrading"; // señal que respetan los EA parcheados de SQX
string GV_TOTAL_LOCK  = "HCPropsController_TotalLocked";
string GV_DAILY_LOCK  = "HCPropsController_DailyLocked";
string GV_INIT_BAL    = "HCPropsController_InitBalance";
string GV_INIT_EQD    = "HCPropsController_InitEquityDaily";
string GV_NEXT_RESET  = "HCPropsController_NextReset";

//===================================================================
// HELPERS TRADING (señal global de bloqueo)
//===================================================================
void DisableTrading()    { GlobalVariableSet(GV_DISABLE, 1.0); }
void EnableTrading()     { GlobalVariableDel(GV_DISABLE); }
bool TradingIsDisabled() { return(GlobalVariableCheck(GV_DISABLE) && GlobalVariableGet(GV_DISABLE) == 1.0); }

//===================================================================
// RUNTIME STATE
//===================================================================
double   AccountDepositsAndWithdrawals = 0.0; // balance inicial (referencia para % totales)
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

// Flags de bloqueo
bool IsGlobalTradingDisabled    = false; // límite total (pegajoso hasta ResetCountersOnInit)
bool IsDailyLimitTradingDisabled= false; // límite diario equity (pegajoso hasta reseteo diario)
bool IsDailyNumberTradingDisabled = false;
bool IsParallelTradesDisabled   = false;
bool IsTradingHoursDisabled     = false;
bool IsConsecWinsDisabled       = false;
bool IsConsecLossesDisabled     = false;
bool IsNewsBlocked              = false;
bool TotalLocked                = false; // estado persistente del bloqueo total
bool DidCloseOrders             = false;
bool DidClosePositions          = false;

// Slave
bool SlaveProfitLocked = false;

// Dashboard
string LastDashboardValues[];
bool   DashboardNeedsUpdate = true;

// Sincronización
string   LastPositionsHash   = "";
bool     SyncFileInitialized = false;
datetime LastSlaveFileTime   = 0;
bool     MasterFileExists    = false;
int      LastSlaveDay        = -1;
bool     SlaveWarningShown   = false;

// Noticias (cache)
datetime g_newsTimes[];
string   g_newsCurr[];
string   g_newsName[];
datetime g_lastNewsFetch = 0;
string   g_activeNews    = "";

//===================================================================
// ESTRUCTURA DE POSICIÓN SINCRONIZADA
//===================================================================
struct SyncPos
  {
   ulong    ticket;
   string   symbol;
   int      type;      // 0 = BUY, 1 = SELL (ENUM_POSITION_TYPE)
   double   volume;    // lotes reales del Master
   double   openPrice;
   double   sl;
   double   tp;
   datetime openTime;
  };

//+------------------------------------------------------------------+
//| Utilidades de strings                                            |
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

// ¿Está 'symbol' en la lista CSV 'list'? (lista vacía = todos)
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
//| BASE64 para nombre de archivo (fallback auto)                    |
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
//| Rutas de archivo (relativas a Common\Files)                      |
//+------------------------------------------------------------------+
// Devuelve la ruta del archivo para un servidor/cuenta dados.
string BuildFilePath(string server, long account)
  {
   if(CustomFilePath != "")
      return CustomFilePath;
   if(FileName != "")
      return HCPROPS_KEY + "\\" + FileName;
   string enc = Base64Encode(NormalizeServerName(server) + "_" + IntegerToString(account));
   return HCPROPS_KEY + "\\" + enc + ".csv";
  }

string GetMyFilePath()       // Master: su propio archivo
  {
   CAccountInfo acc;
   return BuildFilePath(acc.Server(), acc.Login());
  }

string GetMasterFilePath()   // Slave: archivo del Master
  {
   return BuildFilePath(MasterServer, MasterAccountNumber);
  }

//===================================================================
// INIT
//===================================================================
int OnInit()
  {
   Print("HCPropsController v2 inicializado. Modo: ", (Mode == MODE_MASTER ? "MASTER" : "SLAVE"));

   // Validaciones de rangos horarios (MASTER)
   if(Mode == MODE_MASTER)
     {
      if(DailyResetHour < 0 || DailyResetHour > 23 || DailyResetMinute < 0 || DailyResetMinute > 59)
        { Print("ERROR: Reseteo diario fuera de rango"); return INIT_PARAMETERS_INCORRECT; }
      if(LimitTradingHours &&
         (TradingStartHour < 0 || TradingStartHour > 23 || TradingStartMinute < 0 || TradingStartMinute > 59 ||
          TradingEndHour   < 0 || TradingEndHour   > 23 || TradingEndMinute   < 0 || TradingEndMinute   > 59))
        { Print("ERROR: Horario de trading fuera de rango"); return INIT_PARAMETERS_INCORRECT; }
      if(ForceExitEnabled &&
         (TradingExitHour < 0 || TradingExitHour > 23 || TradingExitMinute < 0 || TradingExitMinute > 59))
        { Print("ERROR: Cierre forzado fuera de rango"); return INIT_PARAMETERS_INCORRECT; }
      if(NewsMode != NEWS_OPERATE && NewsDuration < 0)
        { Print("ERROR: NewsDuration debe ser >= 0"); return INIT_PARAMETERS_INCORRECT; }
     }

   // Validación SLAVE: hace falta o bien FileName/CustomFilePath, o bien servidor+cuenta
   if(Mode == MODE_SLAVE)
     {
      bool hasFile   = (FileName != "" || CustomFilePath != "");
      bool hasServer = (MasterServer != "" && MasterAccountNumber != 0);
      if(!hasFile && !hasServer)
        {
         Print("ERROR: En modo SLAVE define FileName/CustomFilePath, o MasterServer + MasterAccountNumber");
         return INIT_PARAMETERS_INCORRECT;
        }
     }

   CalculateAccountDepositsAndWithdrawals();

   if(Mode == MODE_MASTER)
     {
      // Resetear estado persistente si se pide
      if(ResetCountersOnInit)
        {
         GlobalVariableDel(GV_TOTAL_LOCK);
         GlobalVariableDel(GV_DAILY_LOCK);
         GlobalVariableDel(GV_INIT_BAL);
         GlobalVariableDel(GV_INIT_EQD);
         GlobalVariableDel(GV_NEXT_RESET);
         EnableTrading();
         Print("ResetCountersOnInit: estado limpiado");
        }

      // Restaurar baseline + bloqueos desde GlobalVariables (supervivencia a reinicios/caídas de VPS)
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
            Print("Estado restaurado desde GlobalVariables. TotalLocked=", TotalLocked, " InitEquityDaily=", InitialEquityDaily);
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

      // Si mientras el EA estaba apagado pasó la hora de reseteo, resetear ya
      if(restored && TimeCurrent() >= NextDailyResetTime)
         PerformDailyReset();

      PersistState();

      if(PropFirmMode)
         CheckGuardRules();
      CheckNews();

      Print("MASTER OnInit: PropFirmMode=", PropFirmMode, " TradesHoy=", TradesOpenedToday, "/", MaxTradesPerDay);
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
      Print("OnInit: sincronizando posiciones iniciales. Posiciones: ", PositionsTotal());
      SyncPositionsToFile();
     }
   else
     {
      string rel = GetMasterFilePath();
      MasterFileExists = FileIsExist(rel, FILE_COMMON);
      if(MasterFileExists)
         Print("SLAVE: archivo del Master encontrado: ", rel);
      else
        {
         Print("SLAVE: archivo del Master NO encontrado al iniciar: ", rel);
         Print("SLAVE: verifica FileName, o que MasterServer coincida EXACTAMENTE (incluyendo espacios).");
         SlaveWarningShown = true;
        }
     }

   return INIT_SUCCEEDED;
  }

//===================================================================
// PERSISTENCIA DE ESTADO (GlobalVariables)
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
// DEPÓSITOS Y RETIROS (balance inicial)
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
// EQUITY INICIAL DIARIO (MASTER, según hora de reseteo)
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
// EQUITY INICIAL DIARIO (SLAVE, medianoche)
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
// LÍMITES
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
// CONTADORES DE TRADES / RACHAS
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
// RESETEO DIARIO COMPLETO
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
   Print("Reseteo diario ejecutado. InitialEquityDaily=", InitialEquityDaily, " (próximo: ", TimeToString(NextDailyResetTime), ")");
  }

//===================================================================
// ESTADO DE TRADING (habilitar/deshabilitar + cierres)
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

   // Cerrar posiciones cuando se trata de límites de equity, total, o noticias CLOSE_ALL
   bool closeActivePositions = IsGlobalTradingDisabled || IsDailyLimitTradingDisabled ||
                               (IsNewsBlocked && NewsMode == NEWS_CLOSE_ALL);

   if(!DidCloseOrders || (!DidClosePositions && closeActivePositions))
     {
      DidCloseOrders = true;
      if(closeActivePositions)
         DidClosePositions = true;
      CloseAllPositions(closeActivePositions);
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
   else       outside = (cur < s && cur >= e); // ventana que cruza medianoche
   IsTradingHoursDisabled = outside;
  }

//===================================================================
// REGLAS DE GUARDA (solo si PropFirmMode)
//===================================================================
void CheckGuardRules()
  {
   if(Mode != MODE_MASTER || !PropFirmMode)
      return;

   CAccountInfo acc;
   double eq = acc.Equity();

   // --- Límite total (pegajoso) ---
   bool totalBreach = (TotalUpperLimitEquity > 0 && eq >= TotalUpperLimitEquity) ||
                      (TotalLowerLimitEquity > 0 && eq <= TotalLowerLimitEquity);
   if(totalBreach || TotalLocked)
     {
      IsGlobalTradingDisabled = true;
      if(!TotalLocked)
        {
         TotalLocked = true;
         GlobalVariableSet(GV_TOTAL_LOCK, 1.0);
         Print("Límite TOTAL alcanzado (bloqueo persistente hasta ResetCountersOnInit). Equity: ", eq);
        }
     }
   else
      IsGlobalTradingDisabled = false;

   // --- Límite diario equity (pegajoso hasta reseteo) ---
   if(DailyUpperLimitEquity > 0 && eq >= DailyUpperLimitEquity)
     {
      if(!IsDailyLimitTradingDisabled)
        { IsDailyLimitTradingDisabled = true; GlobalVariableSet(GV_DAILY_LOCK, 1.0);
          Print("Límite diario superior alcanzado. Equity: ", eq); }
     }
   else if(DailyLowerLimitEquity > 0 && eq <= DailyLowerLimitEquity)
     {
      if(!IsDailyLimitTradingDisabled)
        { IsDailyLimitTradingDisabled = true; GlobalVariableSet(GV_DAILY_LOCK, 1.0);
          Print("Límite diario inferior alcanzado. Equity: ", eq); }
     }

   // --- Trades por día ---
   IsDailyNumberTradingDisabled = (MaxTradesPerDay > 0 && TradesOpenedToday >= MaxTradesPerDay);
   // --- Trades paralelos ---
   IsParallelTradesDisabled = (MaxParallelTrades > 0 && CurrentTradesCount >= MaxParallelTrades);
   // --- Rachas ---
   IsConsecWinsDisabled   = (MaxConsecWinsPerDay   > 0 && ConsecutiveWinsToday   >= MaxConsecWinsPerDay);
   IsConsecLossesDisabled = (MaxConsecLossesPerDay > 0 && ConsecutiveLossesToday >= MaxConsecLossesPerDay);

   CheckTradingHours();
   CheckAndUpdateTradingStatus();
  }

//===================================================================
// NOTICIAS
//===================================================================
int CurrencyList(string &out[])
  {
   string src = NewsCurrencies;
   StringTrimLeft(src); StringTrimRight(src);
   if(src == "")
     {
      // Derivar del símbolo del gráfico (base + profit currency)
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
      Print("NEWS(URL): WebRequest devolvió ", code, " err=", GetLastError(), " (¿URL en la lista permitida?)");
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
     { Print("NEWS: no hay currencies que vigilar"); return; }

   datetime from = LastResetAnchor() - 86400;
   datetime to   = TimeCurrent() + 2 * 86400;

   if(NewsSource == NEWS_SOURCE_MT5)
      FetchNewsMT5(from, to, curr);
   else
      FetchNewsUrl(from, to, curr);

   Print("NEWS: ", ArraySize(g_newsTimes), " noticias programadas (impacto>=", (int)NewsMinImpact, ")");
  }

// Devuelve true si estamos dentro de la ventana de alguna noticia
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

   // Refrescar el calendario una vez por hora (y en el primer arranque)
   if(NewsMode != NEWS_OPERATE && (g_lastNewsFetch == 0 || TimeCurrent() - g_lastNewsFetch >= 3600))
     {
      FetchNews();
      g_lastNewsFetch = TimeCurrent();
     }

   bool wasBlocked = IsNewsBlocked;
   IsNewsBlocked = (NewsMode != NEWS_OPERATE) ? InNewsWindow() : false;

   if(IsNewsBlocked && !wasBlocked)
      Print("NEWS: entrando en ventana de protección (", g_activeNews, ") - modo ", EnumToString(NewsMode));
   if(!IsNewsBlocked && wasBlocked)
      Print("NEWS: saliendo del rango de noticias. Trading reactivado.");

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
            Print("Cierre forzado ejecutado. Próximo: ", TimeToString(NextForceExitTime));
           }

         CheckGuardRules();
        }

      CheckNews();        // gestiona también el estado de trading cuando PropFirmMode=false
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

      // Límite de profit del Slave
      if(SlaveTotalProfitLimitPercent > 0 && !SlaveProfitLocked)
        {
         CAccountInfo acc;
         double cap = AccountDepositsAndWithdrawals * (1.0 + SlaveTotalProfitLimitPercent / 100.0);
         if(AccountDepositsAndWithdrawals > 0 && acc.Equity() >= cap)
           {
            SlaveProfitLocked = true;
            CloseAllPositions(true);
            Print("SLAVE: límite de profit alcanzado (", SlaveTotalProfitLimitPercent, "%). Replicación detenida.");
           }
        }

      if(!SlaveProfitLocked)
         SlaveSync();
      UpdateDashboard();
     }
  }

//===================================================================
// DETECCIÓN DE OPERACIONES EN MASTER
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
// CERRAR POSICIONES / ÓRDENES
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

//===================================================================
// MAPEO DE SÍMBOLOS (formato MAST:SLAV;MAST2:SLAV2)
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
// SINCRONIZACIÓN: MASTER ESCRIBE
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
   // Ordenar por ticket (orden estable para el hash)
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

   // Asegurar carpeta (Common\Files\HCPropsController)
   ResetLastError();
   FolderCreate(HCPROPS_KEY, FILE_COMMON); // si ya existe, devuelve error 5019 (ignorado)

   ResetLastError();
   int h = FileOpen(rel, FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_SHARE_WRITE, ',');
   int retry = 0;
   while(h == INVALID_HANDLE && retry < 2) { Sleep(10); ResetLastError(); h = FileOpen(rel, FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_SHARE_WRITE, ','); retry++; }
   if(h == INVALID_HANDLE)
     { Print("ERROR: no se pudo abrir archivo de sync: ", rel, " err=", GetLastError()); return false; }

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
// SINCRONIZACIÓN: SLAVE LEE Y REPLICA (por ticket del Master)
//===================================================================
struct TargetPos
  {
   ulong              masterTicket;
   string             symbol;     // símbolo ya mapeado al Slave
   ENUM_POSITION_TYPE dir;        // dirección ya invertida si procede
   double             volume;     // lotes normalizados del Slave
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
        { MasterFileExists = false; Print("SLAVE: Master desconectado. Esperando reconexión..."); }
      else if(!SlaveWarningShown)
        { Print("SLAVE: archivo del Master no encontrado: ", rel); SlaveWarningShown = true; }
      return;
     }
   if(!MasterFileExists)
     { MasterFileExists = true; SlaveWarningShown = false; Print("SLAVE: Master conectado. Sincronizando..."); }

   // Optimización: solo leer si cambió la fecha de modificación
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
         Print("SLAVE: no se pudo abrir el archivo del Master. err=", GetLastError());
      return;
     }

   // ---- Construir lista objetivo desde el archivo ----
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
      string sOpen   = FileReadString(h);   // openPrice (no se usa en mercado)
      string sSL     = FileReadString(h);
      string sTP     = FileReadString(h);
      string sTime   = FileReadString(h);   // openTime (informativo)

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
         sSLp = mTP; // intercambiar SL/TP al invertir
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

   // ---- Recorrer posiciones del Slave (filtradas por magic) ----
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!pos.SelectByIndex(i))
         continue;
      if((long)pos.Magic() != MagicNumber)
         continue;

      ulong mt = ParseMasterTicketFromComment(pos.Comment());
      int   idx = -1;
      // 1) emparejar por ticket del Master
      if(mt != 0)
         for(int t = 0; t < ArraySize(targets); t++)
            if(!targets[t].matched && targets[t].masterTicket == mt)
              { idx = t; break; }
      // 2) fallback: por símbolo + dirección si el comentario se perdió
      if(idx < 0)
         for(int t = 0; t < ArraySize(targets); t++)
            if(!targets[t].matched && targets[t].symbol == pos.Symbol() && targets[t].dir == pos.PositionType())
              { idx = t; break; }

      if(idx < 0)
        {
         // El Master ya no tiene esta posición -> cerrar
         trade.SetTypeFillingBySymbol(pos.Symbol());
         trade.PositionClose(pos.Ticket());
         continue;
        }

      targets[idx].matched = true;

      // Dirección distinta -> cerrar y reabrir
      if(pos.PositionType() != targets[idx].dir)
        {
         trade.SetTypeFillingBySymbol(pos.Symbol());
         trade.PositionClose(pos.Ticket());
         continue; // se reabrirá abajo (queda matched=true pero sin posición; lo abrimos en la fase de apertura)
        }

      // Ajuste de volumen (solo reducción; respeta partial close del Master)
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

      // Replicar SL/TP en modo NORMAL
      if(CopyMode == COPY_NORMAL)
        {
         double pSL = pos.StopLoss();
         double pTP = pos.TakeProfit();
         if(MathAbs(pSL - targets[idx].sl) > si.Point() || MathAbs(pTP - targets[idx].tp) > si.Point())
            trade.PositionModify(pos.Ticket(), targets[idx].sl, targets[idx].tp);
        }
     }

   // ---- Abrir las posiciones del Master que el Slave todavía no tiene ----
   // (recontar matched: una posición cuya dirección cambió quedó cerrada arriba y debe reabrirse)
   // Recalcular qué tickets siguen presentes en el Slave
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
        { Print("SLAVE: símbolo no disponible en el broker: ", sym); continue; }

      trade.SetTypeFillingBySymbol(sym);
      string comment = "HC" + IntegerToString((long)targets[t].masterTicket);
      bool ok;
      if(targets[t].dir == POSITION_TYPE_BUY)
         ok = trade.Buy(targets[t].volume, sym, 0.0, targets[t].sl, targets[t].tp, comment);
      else
         ok = trade.Sell(targets[t].volume, sym, 0.0, targets[t].sl, targets[t].tp, comment);
      if(!ok)
         Print("SLAVE: error al abrir ", sym, " vol=", targets[t].volume, " ret=", trade.ResultRetcode(), " (", trade.ResultRetcodeDescription(), ")");
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
   string modeText = PropFirmMode ? "MASTER (guardián ON)" : "MASTER (solo sync)";
   CreateOrUpdateLabel("HCProps_Mode", 20, y, "Modo: " + modeText, clrYellow, 11, true, 1); y += lh + 3;
   CreateOrUpdateLabel("HCProps_Server", 20, y, "Servidor: " + acc.Server(), clrAqua, 10, false, 2); y += lh;
   CreateOrUpdateLabel("HCProps_Account", 20, y, "Cuenta: " + IntegerToString(acc.Login()), clrAqua, 10, false, 3); y += lh + 5;

   string status = TradingIsDisabled() ? "DESHABILITADO" : "HABILITADO";
   CreateOrUpdateLabel("HCProps_Status", 20, y, "Estado Trading: " + status, TradingIsDisabled() ? clrRed : clrLime, 11, true, 4); y += lh;

   if(IsNewsBlocked)
     { CreateOrUpdateLabel("HCProps_News", 20, y, "NOTICIA ACTIVA: " + g_activeNews, clrRed, 10, true, 5); y += lh; }
   else if(NewsMode != NEWS_OPERATE)
     { CreateOrUpdateLabel("HCProps_News", 20, y, "Noticias: vigilando (" + IntegerToString(ArraySize(g_newsTimes)) + ")", clrLime, 9, false, 5); y += lh; }
   else
     { CreateOrUpdateLabel("HCProps_News", 20, y, "", clrLime, 9, false, 5); }

   if(PropFirmMode)
     {
      string flags = "";
      if(IsGlobalTradingDisabled) flags += "Total ";
      if(IsDailyLimitTradingDisabled) flags += "Diario ";
      if(IsDailyNumberTradingDisabled) flags += "Trades/Día ";
      if(IsParallelTradesDisabled) flags += "Paralelos ";
      if(IsConsecWinsDisabled) flags += "WinsConsec ";
      if(IsConsecLossesDisabled) flags += "LossConsec ";
      if(IsTradingHoursDisabled) flags += "Horario ";
      if(flags == "") flags = "Ninguno";
      CreateOrUpdateLabel("HCProps_FlagsList", 20, y, "Bloqueos: " + flags, flags == "Ninguno" ? clrLime : clrOrange, 9, false, 6); y += lh + 5;

      CreateOrUpdateLabel("HCProps_BalanceInit", 20, y, "Balance Inicial: " + DoubleToString(AccountDepositsAndWithdrawals, 2), clrSilver, 10, false, 7); y += lh;
      CreateOrUpdateLabel("HCProps_EquityInit", 20, y, "Equity Inicio Día: " + DoubleToString(InitialEquityDaily, 2), clrSilver, 10, false, 8); y += lh;

      double dp = CalculateDailyPercent(eq, InitialEquityDaily);
      double tp = CalculateTotalPercent(eq, AccountDepositsAndWithdrawals);
      CreateOrUpdateLabel("HCProps_Equity", 20, y, "Equity: " + DoubleToString(eq, 2) + " | Día: " + FormatPercent(dp) + " | Total: " + FormatPercent(tp), clrWhite, 10, false, 9); y += lh;

      if(DailyUpperLimitEquity > 0)
        { color c = BandColor(DailyProfitLimitPercent > 0 ? dp / DailyProfitLimitPercent : 0);
          CreateOrUpdateLabel("HCProps_DailyUpper", 30, y, "Día +: " + DoubleToString(DailyUpperLimitEquity, 2) + " (" + DoubleToString(DailyProfitLimitPercent, 2) + "%)", c, 9, false, 10); y += lh - 2; }
      if(DailyLowerLimitEquity > 0)
        { color c = BandColor(DailyLossLimitPercent > 0 ? (-dp) / DailyLossLimitPercent : 0);
          CreateOrUpdateLabel("HCProps_DailyLower", 30, y, "Día -: " + DoubleToString(DailyLowerLimitEquity, 2) + " (" + DoubleToString(DailyLossLimitPercent, 2) + "%)", c, 9, false, 11); y += lh; }
      if(TotalUpperLimitEquity > 0)
        { color c = BandColor(TotalProfitLimitPercent > 0 ? tp / TotalProfitLimitPercent : 0);
          CreateOrUpdateLabel("HCProps_TotalUpper", 30, y, "Total +: " + DoubleToString(TotalUpperLimitEquity, 2) + " (" + DoubleToString(TotalProfitLimitPercent, 2) + "%)", c, 9, false, 12); y += lh - 2; }
      if(TotalLowerLimitEquity > 0)
        { color c = BandColor(TotalLossLimitPercent > 0 ? (-tp) / TotalLossLimitPercent : 0);
          CreateOrUpdateLabel("HCProps_TotalLower", 30, y, "Total -: " + DoubleToString(TotalLowerLimitEquity, 2) + " (" + DoubleToString(TotalLossLimitPercent, 2) + "%)", c, 9, false, 13); y += lh + 3; }

      if(MaxTradesPerDay > 0)
        { color c = BandColor((double)TradesOpenedToday / MaxTradesPerDay);
          CreateOrUpdateLabel("HCProps_TradesToday", 30, y, "Trades hoy: " + IntegerToString(TradesOpenedToday) + " / " + IntegerToString(MaxTradesPerDay), c, 9, false, 14); y += lh - 2; }
      if(MaxParallelTrades > 0)
        { color c = BandColor((double)CurrentTradesCount / MaxParallelTrades);
          CreateOrUpdateLabel("HCProps_TradesParallel", 30, y, "Paralelos: " + IntegerToString(CurrentTradesCount) + " / " + IntegerToString(MaxParallelTrades), c, 9, false, 15); y += lh - 2; }
      if(MaxConsecWinsPerDay > 0)
        { color c = BandColor((double)ConsecutiveWinsToday / MaxConsecWinsPerDay);
          CreateOrUpdateLabel("HCProps_ConsecWins", 30, y, "Wins consec: " + IntegerToString(ConsecutiveWinsToday) + " / " + IntegerToString(MaxConsecWinsPerDay), c, 9, false, 16); y += lh - 2; }
      if(MaxConsecLossesPerDay > 0)
        { color c = BandColor((double)ConsecutiveLossesToday / MaxConsecLossesPerDay);
          CreateOrUpdateLabel("HCProps_ConsecLosses", 30, y, "Losses consec: " + IntegerToString(ConsecutiveLossesToday) + " / " + IntegerToString(MaxConsecLossesPerDay), c, 9, false, 17); y += lh + 3; }

      if(LimitTradingHours)
        {
         MqlDateTime ct; TimeToStruct(TimeCurrent(), ct);
         string txt = StringFormat("Horario: %02d:%02d | %02d:%02d-%02d:%02d", ct.hour, ct.min, TradingStartHour, TradingStartMinute, TradingEndHour, TradingEndMinute);
         CreateOrUpdateLabel("HCProps_Hours", 30, y, txt, IsTradingHoursDisabled ? clrRed : clrLime, 9, false, 18); y += lh; }

      if(NextDailyResetTime > 0)
        { MqlDateTime r; TimeToStruct(NextDailyResetTime, r);
          CreateOrUpdateLabel("HCProps_Reset", 20, y, StringFormat("Reseteo diario: %02d:%02d", r.hour, r.min), clrCyan, 9, false, 19); y += lh - 2; }
      if(ForceExitEnabled && NextForceExitTime > 0)
        { MqlDateTime e; TimeToStruct(NextForceExitTime, e);
          CreateOrUpdateLabel("HCProps_Exit", 20, y, StringFormat("Cierre forzado: %02d:%02d", e.hour, e.min), clrMagenta, 9, false, 20); y += lh; }
     }

   SizePanel(y);
   DashboardNeedsUpdate = false;
  }

void UpdateDashboardSlave()
  {
   CAccountInfo acc;
   int y = 20, lh = 20;
   CreateOrUpdateLabel("HCProps_Title", 20, y, "=== HC Props Controller ===", clrDodgerBlue, 12, true, 0); y += lh + 5;
   CreateOrUpdateLabel("HCProps_Mode", 20, y, "Modo: SLAVE", clrYellow, 11, true, 1); y += lh + 3;
   CreateOrUpdateLabel("HCProps_MS", 20, y, "Master: " + (FileName != "" ? FileName : MasterServer), clrAqua, 10, false, 2); y += lh;
   CreateOrUpdateLabel("HCProps_MA", 20, y, "Cuenta Master: " + IntegerToString(MasterAccountNumber), clrAqua, 10, false, 3); y += lh;
   CreateOrUpdateLabel("HCProps_Rev", 20, y, "Invertir: " + (InverseMode ? "SÍ" : "NO") + " | Mult: " + DoubleToString(RiskMultiplier, 2) + " | " + (CopyMode == COPY_NORMAL ? "NORMAL" : "INCOGNITO"), clrAqua, 9, false, 4); y += lh + 5;
   string st = MasterFileExists ? "CONECTADO" : "ESPERANDO MASTER";
   CreateOrUpdateLabel("HCProps_MStatus", 20, y, "Estado Master: " + st, MasterFileExists ? clrLime : clrOrange, 11, true, 5); y += lh;
   if(SlaveProfitLocked)
     { CreateOrUpdateLabel("HCProps_SLock", 20, y, "PROFIT LOCK: replicación detenida", clrRed, 10, true, 6); y += lh; }
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
      // No forzamos EnableTrading aquí para no levantar un bloqueo de límite si solo se recompila.
      // Eliminar el archivo de sync para que los Slaves detecten la desconexión.
      string rel = GetMyFilePath();
      if(FileIsExist(rel, FILE_COMMON))
         FileDelete(rel, FILE_COMMON);

      // Si el EA se retira definitivamente (no recompilación), liberar la señal de bloqueo.
      if(reason == REASON_REMOVE || reason == REASON_CHARTCLOSE)
         EnableTrading();
     }
  }
//+------------------------------------------------------------------+
