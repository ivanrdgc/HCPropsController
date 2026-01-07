//+------------------------------------------------------------------+
//|                                            HCPropsController.mq5 |
//+------------------------------------------------------------------+
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\DealInfo.mqh>
#include <Trade\AccountInfo.mqh>

//===================================================================
// INPUT PARAMETERS
//===================================================================

// Modo: Master (escribe archivo) / Slave (lee y replica)
enum HCMode
  {
   MODE_MASTER = 0, // Master (ejecuta operaciones)
   MODE_SLAVE  = 1 // Slave (replica operaciones)
  };

//===================================================================
// CONFIGURACIÓN GENERAL
//===================================================================
input group "=== CONFIGURACIÓN GENERAL ==="
input HCMode Mode = MODE_MASTER; // Modo de operación

//===================================================================
// CONFIGURACIÓN SLAVE (Solo se usa en modo SLAVE)
//===================================================================
input group "=== CONFIGURACIÓN SLAVE (Solo modo SLAVE) ==="
input string MasterServer = ""; // Servidor de la cuenta Master
input long   MasterAccountNumber = 0; // Número de la cuenta Master
input bool   RevertMasterPositions = true; // Invertir operaciones del Master
input string MasterSymbolNames = ""; // Símbolos Master (ej: EURUSD,WS30) - Opcional
input string SlaveSymbolNames = ""; // Símbolos Slave (ej: EURUSD.pro,US30) - Opcional
input string SlaveSymbolMultipliers = ""; // Multiplicadores de los volúmenes (ej: 0.1,1,10) - Opcional

//===================================================================
// CONFIGURACIÓN MASTER (Solo se usa en modo MASTER)
//===================================================================

//-------------------------------------------------------------------
// LÍMITES DE EQUITY (GANANCIAS/PÉRDIDAS) - Solo MASTER
//-------------------------------------------------------------------
input group "=== LÍMITES DE EQUITY (Solo modo MASTER) ==="
input double DailyProfitLimitPercent = 4.6;  // Límite diario de ganancia (%); 0 = no limitado
input double DailyLossLimitPercent   = 4.6;   // Límite diario de pérdida (%); 0 = no limitado
input double TotalProfitLimitPercent = 8.1;   // Límite total de ganancia (%); 0 = no limitado
input double TotalLossLimitPercent   = 8.1;   // Límite total de pérdida (%); 0 = no limitado

//-------------------------------------------------------------------
// LÍMITES DE TRADING (OPERACIONES) - Solo MASTER
//-------------------------------------------------------------------
input group "=== LÍMITES DE TRADING (Solo modo MASTER) ==="
input int    MaxParallelTrades = 1; // Límite de operaciones paralelas; 0 = no limitado
input int    MaxTradesPerDay   = 1; // Límite de trades por día; 0 = no limitado
input int    MaxConsecLosesPerDay = 0; // Límite de pérdidas consecutivas por día; 0 = no limitado
input int    MaxConsecWinsPerDay = 0; // Límite de ganancias consecutivas por día; 0 = no limitado

//-------------------------------------------------------------------
// CONFIGURACIÓN DE RESETEO DIARIO - Solo MASTER
//-------------------------------------------------------------------
input group "=== RESETEO DIARIO (Solo modo MASTER) ==="
input int    DailyResetHour    = 0; // Hora de reseteo diario
input int    DailyResetMinute  = 0; // Minuto de reseteo diario

//-------------------------------------------------------------------
// HORARIOS DE TRADING - Solo MASTER
//-------------------------------------------------------------------
input group "=== HORARIOS DE TRADING (Solo modo MASTER) ==="
input bool   LimitTradingHours = true; // Limitar aperturas a las horas especificadas
input int    TradingStartHour = 6; // Hora de inicio del trading
input int    TradingStartMinute = 0; // Minuto de inicio del trading
input int    TradingEndHour = 20; // Hora de fin del trading
input int    TradingEndMinute = 0; // Minuto de fin del trading

//-------------------------------------------------------------------
// CIERRE FORZADO - Solo MASTER
//-------------------------------------------------------------------
input group "=== CIERRE FORZADO (Solo modo MASTER) ==="
input bool   ForceExitHour = true; // Forzar cierre a la hora especificada
input int    TradingExitHour = 22; // Hora de cierre forzado
input int    TradingExitMinute = 0; // Minuto de cierre forzado

//===================================================================
// GLOBAL VARIABLE ÚNICA
//===================================================================
string HCPROPS_KEY = "HCPropsController";
string GV_DISABLE = HCPROPS_KEY + "DisableTrading";

//===================================================================
// HELPERS TRADING
//===================================================================
void DisableTrading()    { GlobalVariableSet(GV_DISABLE, 1.0); }
void EnableTrading()     { GlobalVariableDel(GV_DISABLE); }
bool TradingIsDisabled() { return(GlobalVariableCheck(GV_DISABLE) && GlobalVariableGet(GV_DISABLE) == 1.0); }

//===================================================================
// RUNTIME VARIABLES (solo memoria del EA)
//===================================================================
double   AccountDepositsAndWithdrawals   = 0.0;
double   InitialEquityDaily    = 0.0;
datetime NextDailyResetTime    = 0; // Fecha del próximo reseteo diario
datetime NextForceExitTime     = 0; // Fecha del próximo forzado de cierre

double DailyUpperLimitEquity   = 0.0;
double DailyLowerLimitEquity   = 0.0;

double TotalUpperLimitEquity   = 0.0;
double TotalLowerLimitEquity   = 0.0;

int TradesOpenedToday = 0; // Contador de trades abiertos hoy
int CurrentTradesCount = 0; // Contador de trades actual

int ConsecutiveWinsToday = 0; // Contador de ganancias consecutivas hoy
int ConsecutiveLossesToday = 0; // Contador de pérdidas consecutivas hoy

bool IsGlobalTradingDisabled = false;
bool IsDailyLimitTradingDisabled = false;
bool IsDailyNumberTradingDisabled = false;
bool IsParallelTradesDisabled = false;
bool IsTradingHoursDisabled = false;
bool IsConsecWinsDisabled = false;
bool IsConsecLossesDisabled = false;
bool DidCloseOrders = false;
bool DidClosePositions = false;

// Variables para optimización del dashboard (solo actualizar cuando cambien)
string LastDashboardValues[]; // Array dinámico para almacenar valores anteriores de las etiquetas
bool DashboardNeedsUpdate = true; // Flag para forzar actualización inicial

// Variables para sincronización Master/Slave
string LastPositionsHash = ""; // Hash para detectar cambios en posiciones
bool SyncFileInitialized = false; // Flag para forzar escritura inicial del archivo

// Variables para modo Slave
datetime LastSlaveFileTime = 0; // Timestamp de última lectura del archivo del Master
bool MasterFileExists = false; // Trackear si el archivo del Master existe
int LastSlaveDay = -1; // Día del último cálculo de InitialEquityDaily (para detectar cambio de día)
bool SlaveWarningShown = false; // Flag para saber si ya se mostró el mensaje de advertencia
string LastSlaveMasterServer = ""; // Último valor de MasterServer para detectar cambios
long LastSlaveMasterAccount = 0; // Último valor de MasterAccountNumber para detectar cambios

//===================================================================
// INIT
//===================================================================
int OnInit()
{
   Print("HCPropsController initialized");

   if(Mode == MODE_MASTER)
   {
      // Validación de parámetros de reseteo diario
      if(DailyResetHour < 0 || DailyResetHour > 23)
      {
         Print("ERROR: DailyResetHour debe estar entre 0 y 23");
         return INIT_PARAMETERS_INCORRECT;
      }
      if(DailyResetMinute < 0 || DailyResetMinute > 59)
      {
         Print("ERROR: DailyResetMinute debe estar entre 0 y 59");
         return INIT_PARAMETERS_INCORRECT;
      }
      
      // Validación de parámetros de horas de trading
      if(LimitTradingHours)
      {
         if(TradingStartHour < 0 || TradingStartHour > 23)
         {
            Print("ERROR: TradingStartHour debe estar entre 0 y 23");
            return INIT_PARAMETERS_INCORRECT;
         }
         if(TradingStartMinute < 0 || TradingStartMinute > 59)
         {
            Print("ERROR: TradingStartMinute debe estar entre 0 y 59");
            return INIT_PARAMETERS_INCORRECT;
         }
         if(TradingEndHour < 0 || TradingEndHour > 23)
         {
            Print("ERROR: TradingEndHour debe estar entre 0 y 23");
            return INIT_PARAMETERS_INCORRECT;
         }
         if(TradingEndMinute < 0 || TradingEndMinute > 59)
         {
            Print("ERROR: TradingEndMinute debe estar entre 0 y 59");
            return INIT_PARAMETERS_INCORRECT;
         }
      }
      
      // Validación de parámetros de cierre forzado
      if(ForceExitHour)
      {
         if(TradingExitHour < 0 || TradingExitHour > 23)
         {
            Print("ERROR: TradingExitHour debe estar entre 0 y 23");
            return INIT_PARAMETERS_INCORRECT;
         }
         if(TradingExitMinute < 0 || TradingExitMinute > 59)
         {
            Print("ERROR: TradingExitMinute debe estar entre 0 y 59");
            return INIT_PARAMETERS_INCORRECT;
         }
      }
   }
      
   // Validación: en modo SLAVE se requiere MasterServer y MasterAccountNumber
   if(Mode == MODE_SLAVE)
   {
      if(MasterServer == "")
      {
         Print("ERROR: En modo SLAVE se debe especificar MasterServer");
         return INIT_PARAMETERS_INCORRECT;
      }
      if(MasterAccountNumber == 0)
      {
         Print("ERROR: En modo SLAVE se debe especificar MasterAccountNumber");
         return INIT_PARAMETERS_INCORRECT;
      }
   }

   // Calcular depósitos y retiros totales
   CalculateAccountDepositsAndWithdrawals();
   
   // Calcular equity inicial diario y próximo reseteo (solo en modo MASTER)
   if(Mode == MODE_MASTER)
   {
      CalculateInitialEquityDaily();
      CalculateNextDailyResetTime();
      
      // Calcular límites totales (basados en AccountDepositsAndWithdrawals)
      CalculateTotalLimits();
      
      // Calcular límites diarios (basados en InitialEquityDaily)
      CalculateDailyLimits();
      
      // Calcular próximo tiempo de cierre forzado (si está habilitado)
      if(ForceExitHour)
      {
         CalculateNextForceExitTime();
      }
      
      // Pequeño delay para asegurar que el historial esté completamente cargado
      Sleep(100);
      
      // Contar trades abiertos desde el último reseteo
      CountTradesOpenedToday();
      
      // Contar trades abiertos actualmente
      CountCurrentTrades();
      
      // Contar ganancias y pérdidas consecutivas
      CountConsecutiveWinsLosses();
      
      // Verificar y aplicar reglas de guarda al inicio
      CheckGuardRules();
      
      Print("MASTER OnInit: TradesOpenedToday = ", TradesOpenedToday, " / ", MaxTradesPerDay);
   }
   else if(Mode == MODE_SLAVE)
   {
      // Calcular equity inicial diario para slave (usando medianoche como reseteo)
      CalculateInitialEquityDailySlave();
      
      // Inicializar LastSlaveDay con el día actual
      MqlDateTime currentTime;
      TimeToStruct(TimeCurrent(), currentTime);
      LastSlaveDay = currentTime.day;
      
      // Calcular próximo tiempo de cierre forzado (si está habilitado)
      if(ForceExitHour)
      {
         CalculateNextForceExitTime();
      }
      
      // Calcular límites totales (basados en AccountDepositsAndWithdrawals)
      CalculateTotalLimits();
      
      // Calcular límites diarios (basados en InitialEquityDaily)
      CalculateDailyLimits();
      
      // Contar trades abiertos desde el último reseteo
      CountTradesOpenedToday();
      
      // Contar trades abiertos actualmente
      CountCurrentTrades();
      
      // Verificar y aplicar reglas de guarda al inicio
      CheckGuardRules();
   }

   // Timer configurado a 1 segundo para sincronización optimizada
   EventSetTimer(1);
   
   // Inicializar array de valores del dashboard
   ArrayResize(LastDashboardValues, 50);
   // Inicializar strings manualmente (ArrayInitialize no funciona con strings)
   for(int i = 0; i < 50; i++)
   {
      LastDashboardValues[i] = "";
   }
   DashboardNeedsUpdate = true;
   
   // Crear dashboard visual
   CreateDashboard();
   
   // Sincronizar posiciones al archivo (solo en modo MASTER)
   if(Mode == MODE_MASTER)
   {
      // Delay mínimo para asegurar que las posiciones estén completamente cargadas
      // Reducido de 500ms a 50ms para inicialización más rápida
      Sleep(50);
      
      // Forzar escritura inicial del archivo (aunque esté vacío o con posiciones)
      // Resetear el hash para forzar la escritura
      LastPositionsHash = "";
      SyncFileInitialized = false;
      
      Print("OnInit: Sincronizando posiciones iniciales al archivo. Posiciones totales: ", PositionsTotal());
      
      // Crear archivo inicial aunque esté vacío
      SyncPositionsToFile();
   }
   else if(Mode == MODE_SLAVE)
   {
      // Verificar si el archivo del Master existe
      string filename = GetMasterFilePath();
      if(FileIsExist(filename, FILE_COMMON))
      {
         MasterFileExists = true;
         Print("SLAVE: Archivo del Master (" + filename + ") encontrado al inicializar");
      }
      else
      {
         MasterFileExists = false;
         string normalizedServer = NormalizeServerName(MasterServer);
         string stringToEncode = normalizedServer + "_" + IntegerToString(MasterAccountNumber);
         Print("SLAVE: Archivo del Master no encontrado al inicializar.");
         Print("SLAVE: Archivo buscado: ", filename);
         Print("SLAVE: MasterServer actual: '", MasterServer, "' | String codificado: '", stringToEncode, "'");
         Print("SLAVE: IMPORTANTE - Verifica que 'MasterServer' coincida EXACTAMENTE con el nombre del servidor del Master (incluyendo espacios).");
         SlaveWarningShown = true; // Ya se mostró el mensaje en OnInit
         LastSlaveMasterServer = MasterServer;
         LastSlaveMasterAccount = MasterAccountNumber;
      }
   }

   return INIT_SUCCEEDED;
}


//===================================================================
// CALCULAR DEPÓSITOS Y RETIROS
//===================================================================
void CalculateAccountDepositsAndWithdrawals()
{
   AccountDepositsAndWithdrawals = 0.0;
   
   // Seleccionar todo el historial de la cuenta desde el inicio
   if(!HistorySelect(0, TimeCurrent()))
   {
      Print("ERROR: No se pudo seleccionar el historial de la cuenta");
      return;
   }
   
   int totalDeals = HistoryDealsTotal();
   CDealInfo deal;
   
   for(int i = 0; i < totalDeals; i++)
   {
      if(!deal.SelectByIndex(i))
         continue;
      
      // Verificar si es una operación de balance (depósito o retiro)
      if(deal.DealType() == DEAL_TYPE_BALANCE || deal.DealType() == DEAL_TYPE_CREDIT || deal.DealType() == DEAL_TYPE_CHARGE)
      {
         // Obtener el monto del deal (positivo para depósitos, negativo para retiros)
         AccountDepositsAndWithdrawals += deal.Profit();
      }
   }
   
   Print("AccountDepositsAndWithdrawals calculado: ", AccountDepositsAndWithdrawals);
}

//===================================================================
// CALCULAR EQUITY INICIAL DIARIO
//===================================================================
void CalculateInitialEquityDaily()
{
   InitialEquityDaily = 0.0;
   
   // Calcular el tiempo del último reseteo diario
   MqlDateTime currentTime;
   TimeToStruct(TimeCurrent(), currentTime);
   
   datetime lastResetTime = 0;
   
   // Construir el tiempo de reseteo de hoy
   currentTime.hour = DailyResetHour;
   currentTime.min = DailyResetMinute;
   currentTime.sec = 0;
   datetime todayResetTime = StructToTime(currentTime);
   
   // Si el reseteo de hoy ya pasó, usar ese; si no, usar el de ayer
   if(TimeCurrent() >= todayResetTime)
   {
      lastResetTime = todayResetTime;
   }
   else
   {
      // Usar el reseteo de ayer
      lastResetTime = todayResetTime - 86400; // Restar un día (86400 segundos)
   }
   
   // Obtener el balance actual usando CAccountInfo
   CAccountInfo account;
   double currentBalance = account.Balance();
   
   // Seleccionar historial desde el reseteo hasta ahora
   if(!HistorySelect(lastResetTime + 1, TimeCurrent()))
   {
      Print("ERROR: No se pudo seleccionar el historial desde el reseteo diario");
      InitialEquityDaily = AccountDepositsAndWithdrawals; // Usar AccountDepositsAndWithdrawals actual como fallback
      return;
   }
   
   int totalDeals = HistoryDealsTotal();
   double totalChangeAfterReset = 0.0;
   CDealInfo deal;
   
   // Sumar todos los cambios que afectan el balance después del reseteo
   // IMPORTANTE: Siempre sumar Profit + Commission + Swap explícitamente
   // El cambio en el balance es siempre: Profit + Commission + Swap
   for(int i = 0; i < totalDeals; i++)
   {
      if(!deal.SelectByIndex(i))
         continue;
      
      // Calcular el cambio real en el balance para este deal
      double dealChange = deal.Profit() + deal.Commission() + deal.Swap();
      totalChangeAfterReset += dealChange;
   }
   
   // El balance al momento del reseteo = balance actual - todos los cambios después del reseteo
   // (incluye profits, comisiones, swaps, depósitos, retiros, créditos, cargos, etc.)
   InitialEquityDaily = currentBalance - totalChangeAfterReset;
   
   Print("InitialEquityDaily calculado: ", InitialEquityDaily, " (Reset time: ", TimeToString(lastResetTime), ")");
}

//===================================================================
// CALCULAR EQUITY INICIAL DIARIO (MODO SLAVE - usa medianoche)
//===================================================================
void CalculateInitialEquityDailySlave()
{
   InitialEquityDaily = 0.0;
   
   // Calcular el tiempo de medianoche de hoy
   MqlDateTime currentTime;
   TimeToStruct(TimeCurrent(), currentTime);
   
   datetime todayMidnight = 0;
   
   // Construir el tiempo de medianoche de hoy
   currentTime.hour = 0;
   currentTime.min = 0;
   currentTime.sec = 0;
   todayMidnight = StructToTime(currentTime);
   
   // Obtener el balance actual usando CAccountInfo
   CAccountInfo account;
   double currentBalance = account.Balance();
   
   // Seleccionar historial desde medianoche hasta ahora
   if(!HistorySelect(todayMidnight + 1, TimeCurrent()))
   {
      Print("ERROR: No se pudo seleccionar el historial desde medianoche");
      InitialEquityDaily = AccountDepositsAndWithdrawals; // Usar AccountDepositsAndWithdrawals actual como fallback
      return;
   }
   
   int totalDeals = HistoryDealsTotal();
   double totalChangeAfterMidnight = 0.0;
   CDealInfo deal;
   
   // Sumar todos los cambios que afectan el balance después de medianoche
   // IMPORTANTE: Siempre sumar Profit + Commission + Swap explícitamente
   // El cambio en el balance es siempre: Profit + Commission + Swap
   for(int i = 0; i < totalDeals; i++)
   {
      if(!deal.SelectByIndex(i))
         continue;
      
      // Calcular el cambio real en el balance para este deal
      double dealChange = deal.Profit() + deal.Commission() + deal.Swap();
      totalChangeAfterMidnight += dealChange;
   }
   
   // El balance al momento de medianoche = balance actual - todos los cambios después de medianoche
   // (incluye profits, comisiones, swaps, depósitos, retiros, créditos, cargos, etc.)
   InitialEquityDaily = currentBalance - totalChangeAfterMidnight;
   
   Print("InitialEquityDaily (SLAVE) calculado: ", InitialEquityDaily, " (Midnight: ", TimeToString(todayMidnight), ")");
}

//===================================================================
// CALCULAR LÍMITES TOTALES
//===================================================================
void CalculateTotalLimits()
{
   if(TotalProfitLimitPercent > 0)
   {
      TotalUpperLimitEquity = AccountDepositsAndWithdrawals * (1.0 + TotalProfitLimitPercent / 100.0);
   }
   else
   {
      TotalUpperLimitEquity = 0.0; // No limitado
   }
   
   if(TotalLossLimitPercent > 0)
   {
      TotalLowerLimitEquity = AccountDepositsAndWithdrawals * (1.0 - TotalLossLimitPercent / 100.0);
   }
   else
   {
      TotalLowerLimitEquity = 0.0; // No limitado
   }
}

//===================================================================
// CALCULAR LÍMITES DIARIOS
//===================================================================
void CalculateDailyLimits()
{
   if(DailyProfitLimitPercent > 0)
   {
      DailyUpperLimitEquity = InitialEquityDaily + MathMin(InitialEquityDaily, AccountDepositsAndWithdrawals) * DailyProfitLimitPercent / 100.0;
   }
   else
   {
      DailyUpperLimitEquity = 0.0; // No limitado
   }
   
   if(DailyLossLimitPercent > 0)
   {
      DailyLowerLimitEquity = InitialEquityDaily - MathMin(InitialEquityDaily, AccountDepositsAndWithdrawals) * DailyLossLimitPercent / 100.0;
   }
   else
   {
      DailyLowerLimitEquity = 0.0; // No limitado
   }
}

//===================================================================
// CONTAR TRADES ABIERTOS HOY
//===================================================================
void CountTradesOpenedToday()
{
   TradesOpenedToday = 0;
   
   // Calcular el tiempo del último reseteo diario
   MqlDateTime currentTime;
   TimeToStruct(TimeCurrent(), currentTime);
   
   datetime lastResetTime = 0;
   
   // Construir el tiempo de reseteo de hoy
   currentTime.hour = DailyResetHour;
   currentTime.min = DailyResetMinute;
   currentTime.sec = 0;
   datetime todayResetTime = StructToTime(currentTime);
   
   // Si el reseteo de hoy ya pasó, usar ese; si no, usar el de ayer
   if(TimeCurrent() >= todayResetTime)
   {
      lastResetTime = todayResetTime;
   }
   else
   {
      lastResetTime = todayResetTime - 86400; // Restar un día
   }
   
   // Seleccionar historial desde el último reseteo hasta ahora
   // Usar lastResetTime sin +1 para incluir el deal del reseteo mismo si existe
   if(!HistorySelect(lastResetTime, TimeCurrent() + 60)) // +60 segundos de margen para deals recientes
   {
      Print("WARNING: No se pudo seleccionar el historial para contar trades. LastResetTime: ", TimeToString(lastResetTime));
      return;
   }
   
   int totalDeals = HistoryDealsTotal();
   CDealInfo deal;
   // Contar deals de entrada (apertura de posiciones) desde el último reseteo
   // Solo contar deals de tipo BUY o SELL que abren posiciones (no balance, credit, etc.)
   for(int i = 0; i < totalDeals; i++)
   {
      if(!deal.SelectByIndex(i))
         continue;
      
      // Solo contar deals que abren posiciones (DEAL_ENTRY_IN) y son de tipo BUY o SELL
      long dealType = deal.DealType();
      if(deal.Entry() == DEAL_ENTRY_IN && (dealType == DEAL_TYPE_BUY || dealType == DEAL_TYPE_SELL))
      {
         TradesOpenedToday++;
      }
   }
   
   Print("CountTradesOpenedToday: LastResetTime = ", TimeToString(lastResetTime), 
         " | TotalDeals = ", totalDeals, " | TradesOpenedToday = ", TradesOpenedToday);
}

//===================================================================
// CONTAR TRADES ABIERTOS ACTUALMENTE
//===================================================================
void CountCurrentTrades()
{
   CurrentTradesCount = 0;
   
   // Contar posiciones abiertas actualmente
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         CurrentTradesCount++;
      }
   }
}

//===================================================================
// CONTAR GANANCIAS Y PÉRDIDAS CONSECUTIVAS HOY
//===================================================================
void CountConsecutiveWinsLosses()
{
   ConsecutiveWinsToday = 0;
   ConsecutiveLossesToday = 0;
   
   // Calcular el tiempo del último reseteo diario
   MqlDateTime currentTime;
   TimeToStruct(TimeCurrent(), currentTime);
   
   datetime lastResetTime = 0;
   
   // Construir el tiempo de reseteo de hoy
   currentTime.hour = DailyResetHour;
   currentTime.min = DailyResetMinute;
   currentTime.sec = 0;
   datetime todayResetTime = StructToTime(currentTime);
   
   // Si el reseteo de hoy ya pasó, usar ese; si no, usar el de ayer
   if(TimeCurrent() >= todayResetTime)
   {
      lastResetTime = todayResetTime;
   }
   else
   {
      lastResetTime = todayResetTime - 86400; // Restar un día
   }
   
   // Seleccionar historial desde el último reseteo hasta ahora
   // Usar un margen más amplio para asegurar que los deals recientes estén incluidos
   datetime endTime = TimeCurrent() + 60; // +60 segundos de margen para deals recientes
   if(!HistorySelect(lastResetTime, endTime))
   {
      Print("WARNING: No se pudo seleccionar el historial para contar ganancias/pérdidas consecutivas. LastResetTime: ", TimeToString(lastResetTime));
      return;
   }
   
   // Forzar actualización del historial para asegurar que los deals más recientes estén disponibles
   HistorySelect(0, TimeCurrent());
   HistorySelect(lastResetTime, endTime);
   
   int totalDeals = HistoryDealsTotal();
   CDealInfo deal;
   
   // Recolectar todos los deals de cierre (DEAL_ENTRY_OUT) en orden cronológico inverso (más reciente primero)
   // Usamos un array temporal para almacenar los resultados de los deals cerrados
   double closedDealProfits[];
   ArrayResize(closedDealProfits, 0);
   
   // Iterar desde el más reciente al más antiguo
   for(int i = totalDeals - 1; i >= 0; i--)
   {
      if(!deal.SelectByIndex(i))
         continue;
      
      // Solo contar deals que cierran posiciones (DEAL_ENTRY_OUT) y son de tipo BUY o SELL
      long dealType = deal.DealType();
      if(deal.Entry() == DEAL_ENTRY_OUT && (dealType == DEAL_TYPE_BUY || dealType == DEAL_TYPE_SELL))
      {
         // Obtener el profit del deal (incluye comisiones y swaps ya incluidos en el profit del deal)
         double dealProfit = deal.Profit();
         
         // Agregar a la lista (orden inverso: más reciente primero)
         int size = ArraySize(closedDealProfits);
         ArrayResize(closedDealProfits, size + 1);
         closedDealProfits[size] = dealProfit;
      }
   }
   
   // Contar consecutivos desde el más reciente
   // Si no hay deals cerrados, los contadores quedan en 0
   int numClosed = ArraySize(closedDealProfits);
   if(numClosed == 0)
   {
      return; // No hay trades cerrados, contadores en 0
   }
   
   // Determinar el resultado del trade más reciente
   double mostRecentProfit = closedDealProfits[0];
   bool isWin = (mostRecentProfit > 0.0);
   
   // Contar consecutivos del mismo tipo desde el más reciente
   if(isWin)
   {
      ConsecutiveWinsToday = 1;
      // Continuar contando wins consecutivos
      for(int i = 1; i < numClosed; i++)
      {
         if(closedDealProfits[i] > 0.0)
         {
            ConsecutiveWinsToday++;
         }
         else
         {
            // Streak roto, parar de contar
            break;
         }
      }
   }
   else
   {
      ConsecutiveLossesToday = 1;
      // Continuar contando losses consecutivos
      for(int i = 1; i < numClosed; i++)
      {
         if(closedDealProfits[i] < 0.0)
         {
            ConsecutiveLossesToday++;
         }
         else
         {
            // Streak roto, parar de contar
            break;
         }
      }
   }
   
   Print("CountConsecutiveWinsLosses: LastResetTime = ", TimeToString(lastResetTime), 
         " | Trades cerrados = ", numClosed, 
         " | ConsecutiveWins = ", ConsecutiveWinsToday, 
         " | ConsecutiveLosses = ", ConsecutiveLossesToday);
}

//===================================================================
// CALCULAR PRÓXIMO RESETEO DIARIO
//===================================================================
void CalculateNextDailyResetTime()
{
   MqlDateTime currentTime;
   TimeToStruct(TimeCurrent(), currentTime);
   
   // Construir el tiempo de reseteo de hoy
   MqlDateTime resetTime = currentTime;
   resetTime.hour = DailyResetHour;
   resetTime.min = DailyResetMinute;
   resetTime.sec = 0;
   datetime todayResetTime = StructToTime(resetTime);
   
   // Si el reseteo de hoy ya pasó, el próximo es mañana
   if(TimeCurrent() >= todayResetTime)
   {
      NextDailyResetTime = todayResetTime + 86400; // Sumar un día
   }
   else
   {
      // Si aún no ha llegado el reseteo de hoy, ese es el próximo
      NextDailyResetTime = todayResetTime;
   }
}

//===================================================================
// CALCULAR PRÓXIMO TIEMPO DE CIERRE FORZADO
//===================================================================
void CalculateNextForceExitTime()
{
   MqlDateTime currentTime;
   TimeToStruct(TimeCurrent(), currentTime);
   
   // Construir el tiempo de cierre forzado de hoy
   MqlDateTime exitTime = currentTime;
   exitTime.hour = TradingExitHour;
   exitTime.min = TradingExitMinute;
   exitTime.sec = 0;
   datetime todayExitTime = StructToTime(exitTime);
   
   // Si el cierre forzado de hoy ya pasó, el próximo es mañana
   if(TimeCurrent() >= todayExitTime)
   {
      NextForceExitTime = todayExitTime + 86400; // Sumar un día
   }
   else
   {
      // Si aún no ha llegado el cierre forzado de hoy, ese es el próximo
      NextForceExitTime = todayExitTime;
   }
}

//===================================================================
// VERIFICAR Y ACTUALIZAR ESTADO DE TRADING
//===================================================================
void CheckAndUpdateTradingStatus()
{
   // Si todas las flags están en false, habilitar trading
   // Si alguna está en true, deshabilitar trading
   if(!IsGlobalTradingDisabled && !IsDailyLimitTradingDisabled && !IsDailyNumberTradingDisabled && !IsParallelTradesDisabled && !IsTradingHoursDisabled && !IsConsecWinsDisabled && !IsConsecLossesDisabled)
   {
      DidCloseOrders = false;
      DidClosePositions = false;
      
      EnableTrading();
   }
   else
   {
      DisableTrading();
      
      // Si hay que desactivar trading, siempre cerrar órdenes pendientes
      // Si IsGlobalTradingDisabled o IsDailyLimitTradingDisabled están activos,
      // también cerrar posiciones abiertas
      bool closeActivePositions = IsGlobalTradingDisabled || IsDailyLimitTradingDisabled;
      if (!DidCloseOrders || (!DidClosePositions && closeActivePositions))
      {
         DidCloseOrders = true;
         if (closeActivePositions)
         {
            DidClosePositions = true;
         }
         CloseAllPositions(closeActivePositions);
      }
   }
}

//===================================================================
// VERIFICAR HORAS DE TRADING
//===================================================================
void CheckTradingHours()
{
   if(!LimitTradingHours)
   {
      IsTradingHoursDisabled = false;
      return;
   }
   
   MqlDateTime currentTime;
   TimeToStruct(TimeCurrent(), currentTime);
   
   // Construir tiempo de inicio y fin de trading
   int currentMinutes = currentTime.hour * 60 + currentTime.min;
   int startMinutes = TradingStartHour * 60 + TradingStartMinute;
   int endMinutes = TradingEndHour * 60 + TradingEndMinute;
   
   // Verificar si estamos fuera del horario de trading
   if(currentMinutes < startMinutes || currentMinutes >= endMinutes)
   {
      if(!IsTradingHoursDisabled)
      {
         IsTradingHoursDisabled = true;
         Print("Fuera del horario de trading. Hora actual: ", currentTime.hour, ":", currentTime.min, 
               " | Horario permitido: ", TradingStartHour, ":", TradingStartMinute, " - ", TradingEndHour, ":", TradingEndMinute);
      }
   }
   else
   {
      // Estamos dentro del horario de trading
      IsTradingHoursDisabled = false;
   }
}

//===================================================================
// VERIFICAR REGLAS DE GUARDA
//===================================================================
void CheckGuardRules()
{
   CAccountInfo account;
   double currentEquity = account.Equity();
   
   // Verificar límites totales
   if(TotalUpperLimitEquity > 0 && currentEquity >= TotalUpperLimitEquity)
   {
      if(!IsGlobalTradingDisabled)
      {
         IsGlobalTradingDisabled = true;
         Print("Límite total superior alcanzado. Equity: ", currentEquity, " >= Límite: ", TotalUpperLimitEquity);
      }
   }
   else if(TotalLowerLimitEquity > 0 && currentEquity <= TotalLowerLimitEquity)
   {
      if(!IsGlobalTradingDisabled)
      {
         IsGlobalTradingDisabled = true;
         Print("Límite total inferior alcanzado. Equity: ", currentEquity, " <= Límite: ", TotalLowerLimitEquity);
      }
   }
   else
   {
      // Si el equity está dentro de los límites totales, resetear la flag
      IsGlobalTradingDisabled = false;
   }
   
   // Verificar límites diarios
   // Nota: IsDailyLimitTradingDisabled solo se resetea en el reseteo diario, no aquí
   if(DailyUpperLimitEquity > 0 && currentEquity >= DailyUpperLimitEquity)
   {
      if(!IsDailyLimitTradingDisabled)
      {
         IsDailyLimitTradingDisabled = true;
         Print("Límite diario superior alcanzado. Equity: ", currentEquity, " >= Límite: ", DailyUpperLimitEquity);
      }
   }
   else if(DailyLowerLimitEquity > 0 && currentEquity <= DailyLowerLimitEquity)
   {
      if(!IsDailyLimitTradingDisabled)
      {
         IsDailyLimitTradingDisabled = true;
         Print("Límite diario inferior alcanzado. Equity: ", currentEquity, " <= Límite: ", DailyLowerLimitEquity);
      }
   }
   
   // Verificar límite de número de trades por día
   if(MaxTradesPerDay > 0 && TradesOpenedToday >= MaxTradesPerDay)
   {
      if(!IsDailyNumberTradingDisabled)
      {
         IsDailyNumberTradingDisabled = true;
         Print("Límite de trades por día alcanzado. Trades abiertos hoy: ", TradesOpenedToday, " >= Límite: ", MaxTradesPerDay);
      }
   }
   else
   {
      // Si no se ha alcanzado el límite, resetear la flag
      IsDailyNumberTradingDisabled = false;
   }
   
   // Verificar límite de trades paralelos
   if(MaxParallelTrades > 0 && CurrentTradesCount >= MaxParallelTrades)
   {
      if(!IsParallelTradesDisabled)
      {
         IsParallelTradesDisabled = true;
         Print("Límite de trades paralelos alcanzado. Trades actuales: ", CurrentTradesCount, " >= Límite: ", MaxParallelTrades);
      }
   }
   else
   {
      // Si no se ha alcanzado el límite, resetear la flag
      IsParallelTradesDisabled = false;
   }
   
   // Verificar límite de ganancias consecutivas
   if(MaxConsecWinsPerDay > 0 && ConsecutiveWinsToday >= MaxConsecWinsPerDay)
   {
      if(!IsConsecWinsDisabled)
      {
         IsConsecWinsDisabled = true;
         Print("Límite de ganancias consecutivas alcanzado. Ganancias consecutivas: ", ConsecutiveWinsToday, " >= Límite: ", MaxConsecWinsPerDay);
      }
   }
   else
   {
      // Si no se ha alcanzado el límite, resetear la flag
      IsConsecWinsDisabled = false;
   }
   
   // Verificar límite de pérdidas consecutivas
   if(MaxConsecLosesPerDay > 0 && ConsecutiveLossesToday >= MaxConsecLosesPerDay)
   {
      if(!IsConsecLossesDisabled)
      {
         IsConsecLossesDisabled = true;
         Print("Límite de pérdidas consecutivas alcanzado. Pérdidas consecutivas: ", ConsecutiveLossesToday, " >= Límite: ", MaxConsecLosesPerDay);
      }
   }
   else
   {
      // Si no se ha alcanzado el límite, resetear la flag
      IsConsecLossesDisabled = false;
   }
   
   // Verificar horarios de trading
   CheckTradingHours();
   
   // Actualizar estado de trading basado en todas las flags
   CheckAndUpdateTradingStatus();
}

//===================================================================
// TIMER LOOP
//===================================================================
void OnTimer()
{
   if(Mode == MODE_MASTER)
   {
      // Verificar reglas de guarda
      CheckGuardRules();
      
      // Actualizar dashboard
      UpdateDashboard();
      
      // Verificar si es momento de hacer el reseteo diario
      if(TimeCurrent() >= NextDailyResetTime)
      {
         // Guardar el equity actual como InitialEquityDaily usando CAccountInfo
         CAccountInfo account;
         InitialEquityDaily = account.Equity();
         
         // Calcular el próximo reseteo
         CalculateNextDailyResetTime();
         
         // Recalcular límites diarios (basados en el nuevo InitialEquityDaily)
         CalculateDailyLimits();
         
         // Reiniciar contador de trades abiertos hoy
         TradesOpenedToday = 0;
         
         // Reiniciar contadores de ganancias y pérdidas consecutivas
         ConsecutiveWinsToday = 0;
         ConsecutiveLossesToday = 0;
         
         // Resetear flags de límites diarios
         IsDailyLimitTradingDisabled = false;
         IsDailyNumberTradingDisabled = false;
         IsConsecWinsDisabled = false;
         IsConsecLossesDisabled = false;
         
         // Verificar y actualizar estado de trading
         CheckAndUpdateTradingStatus();
         
         // Forzar actualización del dashboard después del reseteo
         DashboardNeedsUpdate = true;
         
         Print("Reseteo diario ejecutado. InitialEquityDaily actualizado: ", InitialEquityDaily, " (Próximo reset: ", TimeToString(NextDailyResetTime), ")");
      }
      
      // Verificar si es momento de hacer el cierre forzado
      // Solo ejecutar si NextForceExitTime está configurado y es el momento correcto
      if(ForceExitHour && NextForceExitTime > 0 && TimeCurrent() >= NextForceExitTime)
      {
         // Cerrar todas las órdenes pendientes y posiciones abiertas
         CloseAllPositions(true);
         
         // Calcular el próximo tiempo de cierre forzado
         CalculateNextForceExitTime();
         
         Print("Cierre forzado ejecutado. Próximo cierre forzado: ", TimeToString(NextForceExitTime));
      }
   }
   else if(Mode == MODE_SLAVE)
   {
      // Verificar si cambió el día (medianoche) para recalcular InitialEquityDaily
      MqlDateTime currentTime;
      TimeToStruct(TimeCurrent(), currentTime);
      int currentDay = currentTime.day;
      
      if(LastSlaveDay != currentDay)
      {
         // Nuevo día, recalcular InitialEquityDaily
         CalculateInitialEquityDailySlave();
         LastSlaveDay = currentDay;
         DashboardNeedsUpdate = true;
         Print("SLAVE: Nuevo día detectado. InitialEquityDaily recalculado: ", InitialEquityDaily);
      }
      
      // Sincronizar posiciones desde el archivo del Master
      SlaveSync();
      
      // Actualizar dashboard
      UpdateDashboard();
   }
}


//===================================================================
// DETECCIÓN DE NUEVAS POSICIONES EN MASTER
//===================================================================
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
    // Solo procesar en modo MASTER
    if(Mode != MODE_MASTER)
        return;
    
    // Actualizar contadores cuando se agrega un deal
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
    {
        // Intentar acceder al deal inmediatamente, solo esperar si es necesario
        HistorySelect(0, TimeCurrent());
        bool dealAvailable = HistoryDealSelect(trans.deal);
        
        // Si no está disponible, intentar con reintentos rápidos (máximo 3 intentos, 10ms cada uno)
        int retryCount = 0;
        int maxRetries = 3;
        while(!dealAvailable && retryCount < maxRetries)
        {
            Sleep(10); // Delay mínimo
            HistorySelect(0, TimeCurrent());
            dealAvailable = HistoryDealSelect(trans.deal);
            retryCount++;
        }
        
        if(!dealAvailable)
        {
            Print("WARNING: No se pudo seleccionar el deal ", trans.deal, " después de ", maxRetries, " intentos - Recalculando desde historial...");
            // Si no se puede seleccionar el deal, recalcular desde el historial
            CountTradesOpenedToday();
            CountCurrentTrades();
            CheckGuardRules();
            // Escribir archivo inmediatamente sin esperar más
            SyncPositionsToFile();
            return;
        }
        
        CDealInfo deal;
        deal.Ticket(trans.deal); // Establecer el ticket del deal
        
        // Verificar si es una apertura de posición (DEAL_ENTRY_IN)
        if(deal.Entry() == DEAL_ENTRY_IN)
        {
            // Recalcular el contador desde el historial (más preciso que incrementar manualmente)
            // Esto asegura que contamos correctamente incluso si hay múltiples deals o si hay un reseteo
            int tradesBefore = TradesOpenedToday;
            CountTradesOpenedToday();
            int tradesAfter = TradesOpenedToday;
            
            Print("MASTER: Nueva posición abierta - Deal: ", trans.deal, " Symbol: ", deal.Symbol(), 
                  " | Trades antes: ", tradesBefore, " | Trades después: ", tradesAfter, 
                  " | Trades hoy: ", TradesOpenedToday, " / ", MaxTradesPerDay);
            
            // Si el contador no aumentó, puede ser que el deal no esté en el historial todavía
            // Reintentar una vez más con delay mínimo
            if(tradesAfter == tradesBefore)
            {
                Print("WARNING: El contador no aumentó. Reintentando...");
                Sleep(10); // Delay mínimo
                CountTradesOpenedToday();
                Print("MASTER: Trades después del reintento: ", TradesOpenedToday, " / ", MaxTradesPerDay);
            }
        }
        // Verificar si es un cierre de posición (DEAL_ENTRY_OUT)
        else if(deal.Entry() == DEAL_ENTRY_OUT)
        {
            // Pequeño delay para asegurar que el deal esté completamente disponible en el historial
            Sleep(10);
            
            // Recalcular contadores de ganancias y pérdidas consecutivas
            // Guardar valores antes para verificar si cambió
            int winsBefore = ConsecutiveWinsToday;
            int lossesBefore = ConsecutiveLossesToday;
            
            CountConsecutiveWinsLosses();
            
            // Si el contador no cambió, puede ser que el deal no esté en el historial todavía
            // Reintentar con delays adicionales (máximo 3 intentos)
            int retryCount = 0;
            int maxRetries = 3;
            while((ConsecutiveWinsToday == winsBefore && ConsecutiveLossesToday == lossesBefore) && retryCount < maxRetries)
            {
                Print("WARNING: Los contadores consecutivos no cambiaron. Reintentando... (", retryCount + 1, "/", maxRetries, ")");
                Sleep(10); // Delay mínimo
                CountConsecutiveWinsLosses();
                retryCount++;
            }
            
            Print("MASTER: Posición cerrada - Deal: ", trans.deal, " Symbol: ", deal.Symbol(), 
                  " | Profit: ", deal.Profit(), 
                  " | ConsecutiveWins: ", ConsecutiveWinsToday, " / ", MaxConsecWinsPerDay,
                  " | ConsecutiveLosses: ", ConsecutiveLossesToday, " / ", MaxConsecLosesPerDay);
            
            // Forzar actualización del dashboard para mostrar los nuevos valores
            DashboardNeedsUpdate = true;
        }
        
        // Recalcular el número de trades abiertos actualmente
        CountCurrentTrades();
        
        // Verificar reglas de guarda después de actualizar contadores
        CheckGuardRules();
        
        // Sincronizar posiciones al archivo cuando hay cambios (sin delay adicional)
        SyncPositionsToFile();
    }
    
    // También sincronizar cuando se modifica o cierra una posición
    // Las posiciones ya están actualizadas en este punto, no necesitamos esperar
    if(trans.type == TRADE_TRANSACTION_POSITION || trans.type == TRADE_TRANSACTION_DEAL_ADD)
    {
        // Escribir inmediatamente - las posiciones ya están actualizadas
        SyncPositionsToFile();
    }
}

//===================================================================
// CERRAR TODAS LAS POSICIONES PROGRAMADAS Y OPCIONALMENTE POSICIONES ABIERTAS
//===================================================================
void CloseAllPositions(bool closeActivePositions = false)
{
   CTrade trade;
   int closedCount = 0;
   int canceledCount = 0;
   
   // Cerrar todas las órdenes pendientes (límites/stops)
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         COrderInfo order;
         if(order.SelectByIndex(i))
         {
            if(trade.OrderDelete(ticket))
            {
               canceledCount++;
            }
         }
      }
   }
   
   if(canceledCount > 0)
   {
      Print("Canceladas ", canceledCount, " órdenes pendientes");
   }
   
   // Si se solicita, cerrar también todas las posiciones abiertas al mercado
   if(closeActivePositions)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0)
         {
            CPositionInfo position;
            if(position.SelectByTicket(ticket))
            {
               string symbol = position.Symbol();
               ulong magic = position.Magic();
               
               // Cerrar la posición
               if(position.PositionType() == POSITION_TYPE_BUY)
               {
                  if(trade.PositionClose(ticket))
                  {
                     closedCount++;
                  }
               }
               else if(position.PositionType() == POSITION_TYPE_SELL)
               {
                  if(trade.PositionClose(ticket))
                  {
                     closedCount++;
                  }
               }
            }
         }
      }
      
      if(closedCount > 0)
      {
         Print("Cerradas ", closedCount, " posiciones abiertas al mercado");
      }
   }
   
   if(canceledCount == 0 && closedCount == 0)
   {
      Print("No hay órdenes pendientes ni posiciones abiertas para cerrar");
   }
}

//===================================================================
// CREAR DASHBOARD
//===================================================================
void CreateDashboard()
{
   // Eliminar objetos existentes si los hay
   DeleteDashboard();
   
   // Crear fondo del panel (posición inicial, se ajustará dinámicamente en UpdateDashboard)
   string panelName = "HCProps_Dashboard_Panel";
   ObjectCreate(0, panelName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelName, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, panelName, OBJPROP_YDISTANCE, 10); // Se ajustará dinámicamente
   ObjectSetInteger(0, panelName, OBJPROP_XSIZE, 400);
   ObjectSetInteger(0, panelName, OBJPROP_YSIZE, 100); // Tamaño inicial mínimo, se ajustará en UpdateDashboard
   ObjectSetInteger(0, panelName, OBJPROP_BGCOLOR, clrDarkSlateGray);
   ObjectSetInteger(0, panelName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelName, OBJPROP_BACK, false);
   ObjectSetInteger(0, panelName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelName, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, panelName, OBJPROP_HIDDEN, true);
   
   // Título (se actualiza en UpdateDashboard)
   
   // Actualizar contenido
   UpdateDashboard();
}

//===================================================================
// ACTUALIZAR DASHBOARD
//===================================================================
void UpdateDashboard()
{
   if(Mode == MODE_SLAVE)
   {
      UpdateDashboardSlave();
      return;
   }
   
   if(Mode != MODE_MASTER)
      return;
   
   CAccountInfo account;
   double currentEquity = account.Equity();
   double currentBalance = account.Balance();
   
   int yPos = 20;
   int lineHeight = 20;
   
   // Título (estático, índice 0)
   CreateOrUpdateLabel("HCProps_Title", 20, yPos, "=== HCProps Controller ===", clrWhite, 12, true, 0);
   yPos += lineHeight + 5;
   
   // Modo de operación (estático, índice 1)
   string modeText = (Mode == MODE_MASTER) ? "MASTER" : "SLAVE";
   CreateOrUpdateLabel("HCProps_Mode", 20, yPos, "Modo: " + modeText, clrYellow, 11, true, 1);
   yPos += lineHeight + 5;
   
   // Información del Servidor y Cuenta (estáticos, índices 2-3)
   string serverName = account.Server();
   long accountNumber = account.Login();
   CreateOrUpdateLabel("HCProps_Server", 20, yPos, "Servidor: " + serverName, clrAqua, 10, false, 2);
   yPos += lineHeight;
   CreateOrUpdateLabel("HCProps_Account", 20, yPos, "Cuenta: " + IntegerToString(accountNumber), clrAqua, 10, false, 3);
   yPos += lineHeight + 5;
   
   // Estado de Trading (dinámico, índice 4)
   string tradingStatus = TradingIsDisabled() ? "DESHABILITADO" : "HABILITADO";
   color statusColor = TradingIsDisabled() ? clrRed : clrLime;
   CreateOrUpdateLabel("HCProps_Status", 20, yPos, "Estado Trading: " + tradingStatus, statusColor, 11, true, 4);
   yPos += lineHeight;
   
   // Flags de deshabilitación (estático título, dinámico lista)
   yPos += 5;
   CreateOrUpdateLabel("HCProps_Flags", 20, yPos, "--- Flags de Bloqueo ---", clrYellow, 10, false, 5);
   yPos += lineHeight;
   
   string flags = "";
   if(IsGlobalTradingDisabled) flags += "• Límite Total ";
   if(IsDailyLimitTradingDisabled) flags += "• Límite Diario ";
   if(IsDailyNumberTradingDisabled) flags += "• Max Trades/Día ";
   if(IsParallelTradesDisabled) flags += "• Max Paralelos ";
   if(IsConsecWinsDisabled) flags += "• Max Ganancias Consec ";
   if(IsConsecLossesDisabled) flags += "• Max Pérdidas Consec ";
   if(IsTradingHoursDisabled) flags += "• Fuera Horario ";
   if(flags == "") flags = "Ninguna";
   CreateOrUpdateLabel("HCProps_FlagsList", 20, yPos, flags, flags == "Ninguna" ? clrLime : clrOrange, 9, false, 6);
   yPos += lineHeight + 5;
   
   // Equity Actual con porcentajes (dinámico, índice 7-9)
   double dailyPercent = CalculateDailyPercent(currentEquity, InitialEquityDaily);
   double totalPercent = CalculateTotalPercent(currentEquity, AccountDepositsAndWithdrawals);
   string dailyPercentStr = FormatPercent(dailyPercent);
   string totalPercentStr = FormatPercent(totalPercent);
   
   // Balance inicial y Equity inicial (estáticos, índices 7-8)
   CreateOrUpdateLabel("HCProps_BalanceInit", 20, yPos, "Balance Inicial: " + DoubleToString(AccountDepositsAndWithdrawals, 2), clrSilver, 10, false, 7);
   yPos += lineHeight;
   CreateOrUpdateLabel("HCProps_EquityInit", 20, yPos, "Equity Inicio Día: " + DoubleToString(InitialEquityDaily, 2), clrSilver, 10, false, 8);
   yPos += lineHeight;

   string equityText = "Equity Actual: " + DoubleToString(currentEquity, 2) + 
               " | Diario: " + dailyPercentStr + " | Total: " + totalPercentStr;
   CreateOrUpdateLabel("HCProps_Equity", 20, yPos, equityText, clrWhite, 10, false, 9);
   yPos += lineHeight;
   
   // Límites Diarios (dinámicos, índices 10-13)
   if(DailyUpperLimitEquity > 0 || DailyLowerLimitEquity > 0)
   {
      CreateOrUpdateLabel("HCProps_DailyLimits", 20, yPos, "Límites Diarios:", clrAqua, 10, false, 10);
      yPos += lineHeight;
      if(DailyUpperLimitEquity > 0)
      {
         color limitColor = currentEquity >= DailyUpperLimitEquity ? clrRed : (dailyPercent > DailyProfitLimitPercent * 0.8 ? clrOrange : clrWhite);
         string dailyUpperText = "  Superior: " + DoubleToString(DailyUpperLimitEquity, 2) + 
                     " (" + DoubleToString(DailyProfitLimitPercent, 2) + "%)";
         CreateOrUpdateLabel("HCProps_DailyUpper", 30, yPos, dailyUpperText, limitColor, 9, false, 11);
         yPos += lineHeight - 2;
      }
      if(DailyLowerLimitEquity > 0)
      {
         color limitColor = currentEquity <= DailyLowerLimitEquity ? clrRed : (dailyPercent < -DailyLossLimitPercent * 0.8 ? clrOrange : clrWhite);
         string dailyLowerText = "  Inferior: " + DoubleToString(DailyLowerLimitEquity, 2) + 
                     " (" + DoubleToString(DailyLossLimitPercent, 2) + "%)";
         CreateOrUpdateLabel("HCProps_DailyLower", 30, yPos, dailyLowerText, limitColor, 9, false, 12);
         yPos += lineHeight;
      }
   }
   
   // Límites Totales (dinámicos, índices 13-16)
   if(TotalUpperLimitEquity > 0 || TotalLowerLimitEquity > 0)
   {
      CreateOrUpdateLabel("HCProps_TotalLimits", 20, yPos, "Límites Totales:", clrAqua, 10, false, 13);
      yPos += lineHeight;
      if(TotalUpperLimitEquity > 0)
      {
         color limitColor = currentEquity >= TotalUpperLimitEquity ? clrRed : (totalPercent > TotalProfitLimitPercent * 0.8 ? clrOrange : clrWhite);
         string totalUpperText = "  Superior: " + DoubleToString(TotalUpperLimitEquity, 2) + 
                     " (" + DoubleToString(TotalProfitLimitPercent, 2) + "%)";
         CreateOrUpdateLabel("HCProps_TotalUpper", 30, yPos, totalUpperText, limitColor, 9, false, 14);
         yPos += lineHeight - 2;
      }
      if(TotalLowerLimitEquity > 0)
      {
         color limitColor = currentEquity <= TotalLowerLimitEquity ? clrRed : (totalPercent < -TotalLossLimitPercent * 0.8 ? clrOrange : clrWhite);
         string totalLowerText = "  Inferior: " + DoubleToString(TotalLowerLimitEquity, 2) + 
                     " (" + DoubleToString(TotalLossLimitPercent, 2) + "%)";
         CreateOrUpdateLabel("HCProps_TotalLower", 30, yPos, totalLowerText, limitColor, 9, false, 15);
         yPos += lineHeight;
      }
   }
   
   yPos += 5;
   
   // Trades (estático título, dinámico contenido, índices 16-18)
   CreateOrUpdateLabel("HCProps_Trades", 20, yPos, "Trades:", clrAqua, 10, false, 16);
   yPos += lineHeight;
   
   // Trades abiertos hoy (dinámico, índice 17)
   if(MaxTradesPerDay > 0)
   {
      color tradesColor = TradesOpenedToday >= MaxTradesPerDay ? clrRed : (TradesOpenedToday >= MaxTradesPerDay * 0.8 ? clrOrange : clrWhite);
      string tradesTodayText = "  Hoy: " + IntegerToString(TradesOpenedToday) + " / " + IntegerToString(MaxTradesPerDay);
      CreateOrUpdateLabel("HCProps_TradesToday", 30, yPos, tradesTodayText, tradesColor, 9, false, 17);
      yPos += lineHeight - 2;
   }
   
   // Trades paralelos (dinámico, índice 18)
   if(MaxParallelTrades > 0)
   {
      color parallelColor = CurrentTradesCount >= MaxParallelTrades ? clrRed : (CurrentTradesCount >= MaxParallelTrades * 0.8 ? clrOrange : clrWhite);
      string tradesParallelText = "  Paralelos: " + IntegerToString(CurrentTradesCount) + " / " + IntegerToString(MaxParallelTrades);
      CreateOrUpdateLabel("HCProps_TradesParallel", 30, yPos, tradesParallelText, parallelColor, 9, false, 18);
      yPos += lineHeight - 2;
   }
   
   // Ganancias consecutivas (dinámico, índice 19)
   if(MaxConsecWinsPerDay > 0)
   {
      color winsColor = ConsecutiveWinsToday >= MaxConsecWinsPerDay ? clrRed : (ConsecutiveWinsToday >= MaxConsecWinsPerDay * 0.8 ? clrOrange : clrWhite);
      string consecWinsText = "  Ganancias Consec: " + IntegerToString(ConsecutiveWinsToday) + " / " + IntegerToString(MaxConsecWinsPerDay);
      CreateOrUpdateLabel("HCProps_ConsecWins", 30, yPos, consecWinsText, winsColor, 9, false, 19);
      yPos += lineHeight - 2;
   }
   
   // Pérdidas consecutivas (dinámico, índice 20)
   if(MaxConsecLosesPerDay > 0)
   {
      color lossesColor = ConsecutiveLossesToday >= MaxConsecLosesPerDay ? clrRed : (ConsecutiveLossesToday >= MaxConsecLosesPerDay * 0.8 ? clrOrange : clrWhite);
      string consecLossesText = "  Pérdidas Consec: " + IntegerToString(ConsecutiveLossesToday) + " / " + IntegerToString(MaxConsecLosesPerDay);
      CreateOrUpdateLabel("HCProps_ConsecLosses", 30, yPos, consecLossesText, lossesColor, 9, false, 20);
      yPos += lineHeight;
   }
   
   yPos += 5;
   
   // Horarios (dinámico, índice 21-22)
   if(LimitTradingHours)
   {
      CreateOrUpdateLabel("HCProps_Hours", 20, yPos, "Horario Trading:", clrAqua, 10, false, 21);
      yPos += lineHeight;
      MqlDateTime currentTime;
      TimeToStruct(TimeCurrent(), currentTime);
      string currentTimeStr = StringFormat("%02d:%02d", currentTime.hour, currentTime.min);
      string tradingHoursStr = StringFormat("%02d:%02d - %02d:%02d", TradingStartHour, TradingStartMinute, TradingEndHour, TradingEndMinute);
      color hoursColor = IsTradingHoursDisabled ? clrRed : clrLime;
      string hoursInfoText = "  " + currentTimeStr + " | Permitido: " + tradingHoursStr;
      CreateOrUpdateLabel("HCProps_HoursInfo", 30, yPos, hoursInfoText, hoursColor, 9, false, 22);
      yPos += lineHeight;
   }
   
   yPos += 5;
   
   // Próximos eventos (estático título, dinámico contenido, índices 23-25)
   CreateOrUpdateLabel("HCProps_Events", 20, yPos, "--- Próximos Eventos ---", clrYellow, 10, false, 23);
   yPos += lineHeight;
   
   // Próximo reseteo diario (dinámico cada segundo, índice 24)
   if(NextDailyResetTime > 0)
   {
      datetime timeToReset = NextDailyResetTime - TimeCurrent();
      int hoursToReset = (int)(timeToReset / 3600);
      int minsToReset = (int)((timeToReset % 3600) / 60);
      
      MqlDateTime resetTime;
      TimeToStruct(NextDailyResetTime, resetTime);
      string resetStr = StringFormat("Reseteo Diario: %02d:%02d (%dh %dm)", 
                                     resetTime.hour, resetTime.min, hoursToReset, minsToReset);
      CreateOrUpdateLabel("HCProps_Reset", 20, yPos, resetStr, clrCyan, 9, false, 24);
      yPos += lineHeight - 2;
   }
   
   // Próximo cierre forzado (dinámico cada segundo, índice 25)
   if(ForceExitHour && NextForceExitTime > 0)
   {
      datetime timeToExit = NextForceExitTime - TimeCurrent();
      int hoursToExit = (int)(timeToExit / 3600);
      int minsToExit = (int)((timeToExit % 3600) / 60);
      
      MqlDateTime exitTime;
      TimeToStruct(NextForceExitTime, exitTime);
      string exitStr = StringFormat("Cierre Forzado: %02d:%02d (%dh %dm)", 
                                     exitTime.hour, exitTime.min, hoursToExit, minsToExit);
      CreateOrUpdateLabel("HCProps_Exit", 20, yPos, exitStr, clrMagenta, 9, false, 25);
      yPos += lineHeight;
   }
   
   // Ajustar el tamaño y posición del panel al contenido dinámicamente (solo si cambió)
   string panelName = "HCProps_Dashboard_Panel";
   if(ObjectFind(0, panelName) >= 0)
   {
      // Posición inicial del contenido (donde empieza el título)
      int panelStartY = 20;
      // Margen superior e inferior
      int marginTop = 10;
      int marginBottom = 10;
      // Calcular altura: desde donde empieza el panel hasta donde termina el contenido + margen inferior
      int panelHeight = (yPos - panelStartY) + marginTop + marginBottom;
      // Posición del panel: un poco antes del contenido para cubrir desde el inicio
      int panelY = panelStartY - marginTop;
      
      // Obtener valores actuales del panel
      long currentPanelY = ObjectGetInteger(0, panelName, OBJPROP_YDISTANCE);
      long currentPanelHeight = ObjectGetInteger(0, panelName, OBJPROP_YSIZE);
      
      // Solo actualizar si cambió o es actualización forzada
      if(DashboardNeedsUpdate || currentPanelY != panelY || currentPanelHeight != panelHeight)
      {
         ObjectSetInteger(0, panelName, OBJPROP_YDISTANCE, panelY);
         ObjectSetInteger(0, panelName, OBJPROP_YSIZE, panelHeight);
      }
   }
   
   // Resetear flag después de la primera actualización
   DashboardNeedsUpdate = false;
}

//===================================================================
// ACTUALIZAR DASHBOARD (MODO SLAVE)
//===================================================================
void UpdateDashboardSlave()
{
   CAccountInfo account;
   double currentEquity = account.Equity();
   
   int yPos = 20;
   int lineHeight = 20;
   
   // Título (estático, índice 0)
   CreateOrUpdateLabel("HCProps_Title", 20, yPos, "=== HCProps Controller ===", clrWhite, 12, true, 0);
   yPos += lineHeight + 5;
   
   // Modo de operación (estático, índice 1)
   CreateOrUpdateLabel("HCProps_Mode", 20, yPos, "Modo: SLAVE", clrYellow, 11, true, 1);
   yPos += lineHeight + 5;
   
   // MasterServer (estático, índice 2)
   CreateOrUpdateLabel("HCProps_MasterServer", 20, yPos, "Servidor Master: " + MasterServer, clrAqua, 10, false, 2);
   yPos += lineHeight;
   
   // MasterAccountNumber (estático, índice 3)
   CreateOrUpdateLabel("HCProps_MasterAccount", 20, yPos, "Cuenta Master: " + IntegerToString(MasterAccountNumber), clrAqua, 10, false, 3);
   yPos += lineHeight;
   
   // RevertMasterPositions (estático, índice 4)
   string revertText = RevertMasterPositions ? "SÍ" : "NO";
   CreateOrUpdateLabel("HCProps_Revert", 20, yPos, "Invertir Posiciones: " + revertText, clrAqua, 10, false, 4);
   yPos += lineHeight + 5;
   
   // Estado de conexión con el Master (dinámico, índice 5)
   string masterStatus = MasterFileExists ? "CONECTADO" : "ESPERANDO MASTER";
   color statusColor = MasterFileExists ? clrLime : clrOrange;
   CreateOrUpdateLabel("HCProps_MasterStatus", 20, yPos, "Estado Master: " + masterStatus, statusColor, 11, true, 5);
   yPos += lineHeight + 5;
   
   // Calcular porcentajes usando funciones helper
   double dailyPercent = CalculateDailyPercent(currentEquity, InitialEquityDaily);
   double totalPercent = CalculateTotalPercent(currentEquity, AccountDepositsAndWithdrawals);
   string dailyPercentStr = FormatPercent(dailyPercent);
   string totalPercentStr = FormatPercent(totalPercent);
   
   // Balance inicial y Equity inicial (estáticos, índices 6-7)
   CreateOrUpdateLabel("HCProps_BalanceInit", 20, yPos, "Balance Inicial: " + DoubleToString(AccountDepositsAndWithdrawals, 2), clrSilver, 10, false, 6);
   yPos += lineHeight;
   CreateOrUpdateLabel("HCProps_EquityInit", 20, yPos, "Equity Inicio Día: " + DoubleToString(InitialEquityDaily, 2), clrSilver, 10, false, 7);
   yPos += lineHeight;
   
   // Equity Actual con porcentajes (dinámico, índice 8)
   string equityText = "Equity Actual: " + DoubleToString(currentEquity, 2) + 
               " | Diario: " + dailyPercentStr + " | Total: " + totalPercentStr;
   CreateOrUpdateLabel("HCProps_Equity", 20, yPos, equityText, clrWhite, 10, false, 8);
   yPos += lineHeight;
   
   // Actualizar tamaño del panel de fondo dinámicamente
   string panelName = "HCProps_Dashboard_Panel";
   if(ObjectFind(0, panelName) >= 0)
   {
      int panelStartY = 20;
      int marginTop = 10;
      int marginBottom = 10;
      int panelHeight = (yPos - panelStartY) + marginTop + marginBottom;
      int panelY = panelStartY - marginTop;
      
      long currentPanelY = ObjectGetInteger(0, panelName, OBJPROP_YDISTANCE);
      long currentPanelHeight = ObjectGetInteger(0, panelName, OBJPROP_YSIZE);
      
      if(DashboardNeedsUpdate || currentPanelY != panelY || currentPanelHeight != panelHeight)
      {
         ObjectSetInteger(0, panelName, OBJPROP_YDISTANCE, panelY);
         ObjectSetInteger(0, panelName, OBJPROP_YSIZE, panelHeight);
      }
   }
   
   DashboardNeedsUpdate = false;
   
   // Forzar actualización del gráfico al final
   ChartRedraw(0);
}

//===================================================================
// CALCULAR PORCENTAJE DIARIO
//===================================================================
double CalculateDailyPercent(double currentEquity, double initialEquityDaily)
{
   if(initialEquityDaily <= 0)
      return 0.0;
   return ((currentEquity - initialEquityDaily) / initialEquityDaily) * 100.0;
}

//===================================================================
// CALCULAR PORCENTAJE TOTAL
//===================================================================
double CalculateTotalPercent(double currentEquity, double accountDepositsAndWithdrawals)
{
   if(accountDepositsAndWithdrawals <= 0)
      return 0.0;
   return ((currentEquity - accountDepositsAndWithdrawals) / accountDepositsAndWithdrawals) * 100.0;
}

//===================================================================
// FORMATEAR PORCENTAJE COMO STRING
//===================================================================
string FormatPercent(double percent)
{
   return percent >= 0 ? "+" + DoubleToString(percent, 2) + "%" : DoubleToString(percent, 2) + "%";
}

//===================================================================
// CREAR/ACTUALIZAR ETIQUETA DE TEXTO (optimizado: solo actualiza si cambió)
//===================================================================
void CreateOrUpdateLabel(string name, int x, int y, string text, color clr, int fontSize, bool bold, int valueIndex = -1)
{
   // Crear objeto si no existe
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
      
      // Guardar valor inicial si se especificó índice
      if(valueIndex >= 0 && valueIndex < ArraySize(LastDashboardValues))
      {
         LastDashboardValues[valueIndex] = text;
      }
      return;
   }
   
   // Verificar si el valor cambió (solo si se proporciona índice y no es actualización forzada)
   if(valueIndex >= 0 && valueIndex < ArraySize(LastDashboardValues))
   {
      if(!DashboardNeedsUpdate && LastDashboardValues[valueIndex] == text)
      {
         // El texto no cambió, verificar solo si cambió el color o posición
         color currentColor = (color)ObjectGetInteger(0, name, OBJPROP_COLOR);
         long currentX = ObjectGetInteger(0, name, OBJPROP_XDISTANCE);
         long currentY = ObjectGetInteger(0, name, OBJPROP_YDISTANCE);
         
         // Solo actualizar si cambió color o posición
         if(currentColor != clr || currentX != x || currentY != y)
         {
            if(currentX != x) ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
            if(currentY != y) ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
            if(currentColor != clr) ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
         }
         else
         {
            // Nada cambió, no hacer nada
            return;
         }
      }
      else
      {
         // El valor cambió o es actualización forzada, actualizar todo
         LastDashboardValues[valueIndex] = text;
         ObjectSetString(0, name, OBJPROP_TEXT, text);
         ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
         ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
         ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      }
   }
   else
   {
      // Sin índice (elementos estáticos), siempre actualizar
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   }
}

// Función de compatibilidad para mantener el código existente
void CreateLabel(string name, int x, int y, string text, color clr, int fontSize, bool bold)
{
   CreateOrUpdateLabel(name, x, y, text, clr, fontSize, bold, -1);
}

//===================================================================
// ELIMINAR DASHBOARD
//===================================================================
void DeleteDashboard()
{
   // Eliminar todos los objetos del dashboard de forma explícita
   // Primero, eliminar el panel de fondo
   string panelName = "HCProps_Dashboard_Panel";
   if(ObjectFind(0, panelName) >= 0)
   {
      ObjectDelete(0, panelName);
   }
   
   // Eliminar todos los objetos que empiezan con "HCProps_"
   // Usar ObjectsDeleteAll con prefijo
   int deleted = ObjectsDeleteAll(0, "HCProps_");
   
   // Como respaldo, también eliminar manualmente los objetos conocidos
   string objNames[] = {
      "HCProps_Title",
      "HCProps_Mode",
      "HCProps_Server",
      "HCProps_Account",
      "HCProps_Status",
      "HCProps_Flags",
      "HCProps_FlagsList",
      "HCProps_BalanceInit",
      "HCProps_EquityInit",
      "HCProps_Equity",
      "HCProps_DailyLimits",
      "HCProps_DailyUpper",
      "HCProps_DailyLower",
      "HCProps_TotalLimits",
      "HCProps_TotalUpper",
      "HCProps_TotalLower",
      "HCProps_ParallelTrades",
      "HCProps_TradesPerDay",
      "HCProps_TradingHours",
      "HCProps_Exit",
      "HCProps_MasterServer",
      "HCProps_MasterAccount",
      "HCProps_Revert",
      "HCProps_MasterStatus"
   };
   
   for(int i = 0; i < ArraySize(objNames); i++)
   {
      if(ObjectFind(0, objNames[i]) >= 0)
      {
         ObjectDelete(0, objNames[i]);
      }
   }
   
   // Eliminar cualquier otro objeto que empiece con HCProps_ iterando manualmente
   // Iterar sobre todos los objetos en el gráfico principal (subwindow 0)
   // -1 significa todos los tipos de objetos
   int totalObjects = ObjectsTotal(0, 0, -1);
   for(int i = totalObjects - 1; i >= 0; i--)
   {
      string objName = ObjectName(0, i, 0, -1);
      if(objName != "" && StringFind(objName, "HCProps_") == 0)
      {
         ObjectDelete(0, objName);
      }
   }
   
   // Forzar actualización del gráfico para asegurar que se eliminen visualmente
   ChartRedraw(0);
}

//===================================================================
// FUNCIÓN AUXILIAR PARA REEMPLAZAR STRING (evita warnings del compilador)
//===================================================================
string ReplaceString(string text, string search, string replace)
{
   string result = text;
   StringReplace(result, search, replace);
   return result;
}

//===================================================================
// NORMALIZAR NOMBRE DE SERVIDOR (remover espacios múltiples y normalizar)
//===================================================================
string NormalizeServerName(string serverName)
{
   // Remover espacios al inicio y final
   StringTrimLeft(serverName);
   StringTrimRight(serverName);
   
   // Remover espacios múltiples consecutivos y reemplazarlos por un solo espacio
   // Usar StringReplace para reemplazar múltiples espacios por uno solo
   while(StringFind(serverName, "  ") >= 0)
   {
      StringReplace(serverName, "  ", " ");
   }
   
   return serverName;
}

//===================================================================
// BASE64 ENCODE (para codificar el nombre del archivo)
//===================================================================
string Base64Encode(string data)
{
   uchar src[], key[], dst[];
   StringToCharArray(data, src, 0, StringLen(data));
   ArrayResize(key, 0); // Key vacía para Base64
   int res = CryptEncode(CRYPT_BASE64, src, key, dst);
   if(res > 0)
   {
      // Remover caracteres de nueva línea que CryptEncode puede agregar
      string encoded = CharArrayToString(dst);
      string emptyStr = "";
      string crlfStr = "\r\n";
      string lfStr = "\n";
      string crStr = "\r";
      encoded = ReplaceString(encoded, crlfStr, emptyStr);
      encoded = ReplaceString(encoded, lfStr, emptyStr);
      encoded = ReplaceString(encoded, crStr, emptyStr);
      return encoded;
   }
   // Fallback: usar el nombre sin codificar si falla (reemplazar caracteres problemáticos)
   string safeName = data;
   string underscoreStr = "_";
   string backslashStr = "\\";
   string slashStr = "/";
   string colonStr = ":";
   string asteriskStr = "*";
   string questionStr = "?";
   string quoteStr = "\"";
   string ltStr = "<";
   string gtStr = ">";
   string pipeStr = "|";
   
   safeName = ReplaceString(safeName, backslashStr, underscoreStr);
   safeName = ReplaceString(safeName, slashStr, underscoreStr);
   safeName = ReplaceString(safeName, colonStr, underscoreStr);
   safeName = ReplaceString(safeName, asteriskStr, underscoreStr);
   safeName = ReplaceString(safeName, questionStr, underscoreStr);
   safeName = ReplaceString(safeName, quoteStr, underscoreStr);
   safeName = ReplaceString(safeName, ltStr, underscoreStr);
   safeName = ReplaceString(safeName, gtStr, underscoreStr);
   safeName = ReplaceString(safeName, pipeStr, underscoreStr);
   return safeName;
}

//===================================================================
// OBTENER RUTA DEL ARCHIVO CSV DE SINCRONIZACIÓN (relativa para FILE_COMMON)
//===================================================================
string GetSyncFilePath()
{
   CAccountInfo account;
   string serverName = account.Server();
   // Normalizar el nombre del servidor
   serverName = NormalizeServerName(serverName);
   long accountNumber = account.Login();
   
   string stringToEncode = serverName + "_" + IntegerToString(accountNumber);
   string fileName = Base64Encode(stringToEncode) + ".csv";
   // Ruta relativa: FILE_COMMON manejará la carpeta Common automáticamente
   // Usar subcarpeta como en el código antiguo
   string filePath = HCPROPS_KEY + "\\" + fileName;
   
   Print("MASTER: String a codificar: '", stringToEncode, "' | Archivo: ", fileName);
   
   return filePath;
}

//===================================================================
// OBTENER RUTA COMPLETA DEL ARCHIVO (solo para diagnóstico)
//===================================================================
string GetSyncFilePathFull()
{
   CAccountInfo account;
   string serverName = account.Server();
   // Normalizar el nombre del servidor
   serverName = NormalizeServerName(serverName);
   long accountNumber = account.Login();
   
   string fileName = Base64Encode(serverName + "_" + IntegerToString(accountNumber)) + ".csv";
   string commonPath = TerminalInfoString(TERMINAL_COMMONDATA_PATH);
   string filePath = commonPath + "\\" + HCPROPS_KEY + "\\" + fileName;
   
   return filePath;
}

//===================================================================
// ESTRUCTURA PARA ALMACENAR DATOS DE POSICIÓN
//===================================================================
struct PositionData
{
   ulong ticket;
   string symbol;
   double proportion;
};

//===================================================================
// OBTENER TODAS LAS POSICIONES ABIERTAS CON EXPOSICIÓN
//===================================================================
string GetPositionsCSVContent()
{
   CAccountInfo account;
   double accountDeposits = AccountDepositsAndWithdrawals;
   
   // Si no hay depósitos, usar equity actual como referencia mínima
   if(accountDeposits <= 0)
   {
      accountDeposits = account.Equity();
      if(accountDeposits <= 0)
         accountDeposits = 1.0; // Evitar división por cero
   }
   
   // Recolectar todas las posiciones en un array
   PositionData positions[];
   ArrayResize(positions, 0);
   
   // Iterar sobre todas las posiciones abiertas
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         CPositionInfo position;
         if(position.SelectByTicket(ticket))
         {
            string symbol = position.Symbol();
            double volume = position.Volume();
            ENUM_POSITION_TYPE posType = position.PositionType();
            
            // Calcular exposición: volumen con signo según tipo de posición
            double exposure = (posType == POSITION_TYPE_BUY) ? volume : -volume;
            
            // Calcular proporción: exposición / depósitos
            double proportion = exposure / accountDeposits;
            
            // Agregar a array
            int size = ArraySize(positions);
            ArrayResize(positions, size + 1);
            positions[size].ticket = ticket;
            positions[size].symbol = symbol;
            positions[size].proportion = proportion;
         }
      }
   }
   
   // Ordenar por ticket para garantizar orden consistente
   int count = ArraySize(positions);
   for(int i = 0; i < count - 1; i++)
   {
      for(int j = i + 1; j < count; j++)
      {
         if(positions[i].ticket > positions[j].ticket)
         {
            // Intercambiar
            PositionData temp = positions[i];
            positions[i] = positions[j];
            positions[j] = temp;
         }
      }
   }
   
   // Generar CSV en orden ordenado
   string csvContent = "";
   for(int i = 0; i < count; i++)
   {
      if(i > 0)
         csvContent += "\r\n";
      
      csvContent += IntegerToString(positions[i].ticket) + "," + 
                    positions[i].symbol + "," + 
                    DoubleToString(positions[i].proportion, 10);
   }
   
   return csvContent;
}

//===================================================================
// GENERAR HASH DE POSICIONES PARA DETECTAR CAMBIOS
//===================================================================
string GeneratePositionsHash()
{
   string csvContent = GetPositionsCSVContent();
   // Usar el contenido directamente para comparación (será pequeño normalmente)
   // Esto asegura detección exacta de cambios
   return csvContent;
}

//===================================================================
// ESCRIBIR ARCHIVO DE SINCRONIZACIÓN
//===================================================================
bool WriteSyncFile()
{
   string filePath = GetSyncFilePath(); // Ruta relativa
   string filePathFull = GetSyncFilePathFull(); // Ruta completa para diagnóstico
   
   // Intentar crear la carpeta primero (como en el código antiguo)
   string folderRel = HCPROPS_KEY;
   ResetLastError();
   
   // Intentar crear un archivo temporal para forzar la creación de la carpeta
   string testFile = folderRel + "\\_test.tmp";
   int testHandle = FileOpen(testFile, FILE_WRITE | FILE_COMMON | FILE_TXT);
   if(testHandle != INVALID_HANDLE)
   {
      FileClose(testHandle);
      FileDelete(testFile, FILE_COMMON);
   }
   else
   {
      // Si falla, intentar crear la carpeta explícitamente usando la ruta completa
      string folderFull = TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\" + HCPROPS_KEY;
      ResetLastError();
      FolderCreate(folderFull);
      int error = GetLastError();
      // Ignorar error 5019 (ya existe)
      if(error != 0 && error != 5019)
      {
         Print("ADVERTENCIA: No se pudo crear carpeta (error ", error, "): ", folderFull);
      }
   }
   
   // Generar contenido CSV
   string csvContent = GetPositionsCSVContent();
   
   // Escribir archivo usando ruta relativa (FILE_COMMON)
   // Intentar abrir inmediatamente, solo reintentar si falla
   ResetLastError();
   int fileHandle = FileOpen(filePath, FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_SHARE_WRITE, ',');
   if(fileHandle == INVALID_HANDLE)
   {
      int error = GetLastError();
      // Reintentar con delays mínimos (máximo 2 intentos adicionales)
      int retryCount = 0;
      int maxRetries = 2;
      while(fileHandle == INVALID_HANDLE && retryCount < maxRetries)
      {
         Sleep(10); // Delay mínimo para reintentos
         ResetLastError();
         fileHandle = FileOpen(filePath, FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_SHARE_WRITE, ',');
         retryCount++;
      }
      
      if(fileHandle == INVALID_HANDLE)
      {
         error = GetLastError();
         Print("ERROR: No se pudo crear archivo de sincronización después de ", maxRetries + 1, " intentos - Error: ", error);
         Print("Ruta relativa: ", filePath);
         Print("Ruta completa: ", filePathFull);
         return false;
      }
   }
   
   // Escribir contenido
   if(StringLen(csvContent) > 0)
   {
      // Dividir en líneas y escribir usando el carácter de nueva línea
      string lines[];
      ushort sep = StringGetCharacter("\n", 0); // Obtener código del carácter de nueva línea
      int lineCount = StringSplit(csvContent, sep, lines);
      for(int i = 0; i < lineCount; i++)
      {
         string line = lines[i];
         // Limpiar retorno de carro si existe
         string emptyStr = "";
         string crStr = "\r";
         line = ReplaceString(line, crStr, emptyStr);
         if(StringLen(line) > 0)
         {
            string values[];
            int valueCount = StringSplit(line, ',', values);
            if(valueCount >= 3)
            {
               // FileWrite con FILE_CSV escribe automáticamente separado por comas
               FileWrite(fileHandle, values[0], values[1], values[2]);
            }
         }
      }
   }
   // Si no hay posiciones, el archivo queda vacío (correcto)
   
   FileClose(fileHandle);
   return true;
}

//===================================================================
// SINCRONIZAR POSICIONES AL ARCHIVO (solo si hay cambios)
//===================================================================
void SyncPositionsToFile()
{
   if(Mode != MODE_MASTER)
      return;
   
   // Generar hash actual de posiciones
   string currentHash = GeneratePositionsHash();
   int positionsCount = PositionsTotal();
   
   // Comparar con hash anterior o forzar escritura la primera vez
   // Siempre escribir si no está inicializado, incluso si el hash está vacío (sin posiciones)
   if(!SyncFileInitialized || currentHash != LastPositionsHash)
   {
      // Hay cambios o es la primera vez, escribir archivo
      if(WriteSyncFile())
      {
         LastPositionsHash = currentHash;
         SyncFileInitialized = true;
         Print("Archivo de sincronización creado/actualizado: ", GetSyncFilePathFull(), 
               " | Posiciones: ", positionsCount);
      }
      else
      {
         Print("ERROR: No se pudo escribir el archivo de sincronización");
      }
   }
}

//===================================================================
// OBTENER RUTA DEL ARCHIVO DEL MASTER (modo Slave)
//===================================================================
string GetMasterFilePath()
{
   // Normalizar el nombre del servidor
   string normalizedServer = NormalizeServerName(MasterServer);
   
   string stringToEncode = normalizedServer + "_" + IntegerToString(MasterAccountNumber);
   string fileName = Base64Encode(stringToEncode) + ".csv";
   string filePath = HCPROPS_KEY + "\\" + fileName;
   
   // Solo imprimir en OnInit o cuando cambia el estado (no cada segundo)
   // El print se hace en OnInit y cuando cambia el estado en SlaveSync
   
   return filePath;
}

//===================================================================
// OBTENER RUTA COMPLETA DEL ARCHIVO DEL MASTER (solo para diagnóstico)
//===================================================================
string GetMasterFilePathFull()
{
   // Normalizar el nombre del servidor
   string normalizedServer = NormalizeServerName(MasterServer);
   
   string fileName = Base64Encode(normalizedServer + "_" + IntegerToString(MasterAccountNumber)) + ".csv";
   string commonPath = TerminalInfoString(TERMINAL_COMMONDATA_PATH);
   string filePath = commonPath + "\\" + HCPROPS_KEY + "\\" + fileName;
   return filePath;
}

//===================================================================
// MAPEAR SÍMBOLO DEL MASTER AL SÍMBOLO DEL SLAVE
//===================================================================
string MapSymbol(string masterSymbol)
{
   // Si no hay mapeo configurado, retornar el mismo símbolo
   if(MasterSymbolNames == "" || SlaveSymbolNames == "")
      return masterSymbol;
   
   // Dividir las listas de símbolos por comas
   string masterSymbols[];
   string slaveSymbols[];
   
   int masterCount = StringSplit(MasterSymbolNames, ',', masterSymbols);
   int slaveCount = StringSplit(SlaveSymbolNames, ',', slaveSymbols);
   
   // Verificar que ambas listas tengan el mismo número de elementos
   if(masterCount != slaveCount || masterCount == 0)
      return masterSymbol; // Si no coinciden, retornar el mismo símbolo
   
   // Buscar el símbolo del Master en la lista
   for(int i = 0; i < masterCount; i++)
   {
      // Eliminar espacios en blanco
      StringTrimLeft(masterSymbols[i]);
      StringTrimRight(masterSymbols[i]);
      StringTrimLeft(slaveSymbols[i]);
      StringTrimRight(slaveSymbols[i]);
      
      // Comparar (case-sensitive)
      if(masterSymbols[i] == masterSymbol)
      {
         return slaveSymbols[i]; // Retornar el símbolo mapeado del Slave
      }
   }
   
   // Si no se encuentra en el mapeo, retornar el mismo símbolo
   return masterSymbol;
}

//===================================================================
// OBTENER MULTIPLICADOR DEL SÍMBOLO (si está configurado)
//===================================================================
double GetSymbolMultiplier(string masterSymbol)
{
   // Si no hay multiplicadores configurados, retornar 1.0
   if(SlaveSymbolMultipliers == "")
      return 1.0;
   
   // Si no hay mapeo de símbolos, no podemos aplicar multiplicadores
   if(MasterSymbolNames == "")
      return 1.0;
   
   // Dividir las listas de símbolos y multiplicadores por comas
   string masterSymbols[];
   string multipliers[];
   
   int masterCount = StringSplit(MasterSymbolNames, ',', masterSymbols);
   int multiplierCount = StringSplit(SlaveSymbolMultipliers, ',', multipliers);
   
   // Verificar que ambas listas tengan el mismo número de elementos
   if(masterCount != multiplierCount || masterCount == 0)
      return 1.0; // Si no coinciden, retornar 1.0
   
   // Buscar el símbolo del Master en la lista
   for(int i = 0; i < masterCount; i++)
   {
      // Eliminar espacios en blanco
      StringTrimLeft(masterSymbols[i]);
      StringTrimRight(masterSymbols[i]);
      StringTrimLeft(multipliers[i]);
      StringTrimRight(multipliers[i]);
      
      // Comparar (case-sensitive)
      if(masterSymbols[i] == masterSymbol)
      {
         // Convertir el multiplicador a double
         double multiplier = StringToDouble(multipliers[i]);
         if(multiplier <= 0.0)
            return 1.0; // Si el valor es inválido, retornar 1.0
         return multiplier;
      }
   }
   
   // Si no se encuentra en el mapeo, retornar 1.0
   return 1.0;
}

//===================================================================
// INVERTIR DIRECCIÓN DE LA POSICIÓN (si RevertMasterPositions=true)
//===================================================================
ENUM_POSITION_TYPE ReverseDirection(ENUM_POSITION_TYPE masterDir)
{
   if(!RevertMasterPositions)
      return masterDir;
   
   return (masterDir == POSITION_TYPE_BUY ? POSITION_TYPE_SELL : POSITION_TYPE_BUY);
}

//===================================================================
// SINCRONIZAR POSICIONES DESDE EL ARCHIVO DEL MASTER (modo Slave)
//===================================================================
void SlaveSync()
{
   if(Mode != MODE_SLAVE)
      return;
   
   if(MasterAccountNumber == 0 || MasterServer == "")
      return;
   
   // Detectar cambios en los parámetros
   bool paramsChanged = (LastSlaveMasterServer != MasterServer || LastSlaveMasterAccount != MasterAccountNumber);
   if(paramsChanged)
   {
      // Los parámetros cambiaron, resetear flags
      LastSlaveMasterServer = MasterServer;
      LastSlaveMasterAccount = MasterAccountNumber;
      SlaveWarningShown = false;
      MasterFileExists = false; // Forzar verificación del estado
   }
   
   string filename = GetMasterFilePath();
   string filenameFull = GetMasterFilePathFull();
   
   // Verificar si el archivo existe usando FILE_COMMON
   if(!FileIsExist(filename, FILE_COMMON))
   {
      // Archivo no existe - actualizar estado y retornar sin hacer nada
      if(MasterFileExists)
      {
         MasterFileExists = false;
         Print("SLAVE: Master desconectado - Esperando reconexión...");
         SlaveWarningShown = false; // Resetear para mostrar mensaje si se vuelve a desconectar
      }
      
      // Mostrar mensaje solo la primera vez o si cambiaron los parámetros
      if(!SlaveWarningShown || paramsChanged)
      {
         string normalizedServer = NormalizeServerName(MasterServer);
         string stringToEncode = normalizedServer + "_" + IntegerToString(MasterAccountNumber);
         Print("SLAVE: Archivo del Master no encontrado - Esperando conexión...");
         Print("SLAVE: Archivo buscado: ", filename);
         Print("SLAVE: MasterServer actual: '", MasterServer, "' | String codificado: '", stringToEncode, "'");
         Print("SLAVE: Verifica que 'MasterServer' coincida EXACTAMENTE con el nombre del servidor del Master (incluyendo espacios).");
         SlaveWarningShown = true;
      }
      
      return;
   }
   
   // Archivo existe - actualizar estado si antes no existía
   if(!MasterFileExists)
   {
      MasterFileExists = true;
      Print("SLAVE: Master conectado - Iniciando sincronización...");
      SlaveWarningShown = false; // Resetear para que si se desconecta, muestre mensaje
   }
   
   // Optimización: verificar si el archivo fue modificado desde la última lectura
   datetime fileModifyTime = (datetime)FileGetInteger(filenameFull, FILE_MODIFY_DATE, false);
   
   if(fileModifyTime == 0)
   {
      // No se pudo obtener el timestamp, leer de todas formas
      fileModifyTime = TimeCurrent();
   }
   else if(fileModifyTime <= LastSlaveFileTime && LastSlaveFileTime > 0)
   {
      // El archivo no ha sido modificado desde la última lectura, no leer
      return;
   }
   
   ResetLastError();
   int handle = FileOpen(filename, FILE_READ | FILE_CSV | FILE_COMMON | FILE_SHARE_READ, ',');
   
   if(handle == INVALID_HANDLE)
   {
      int error = GetLastError();
      // Solo reportar error si no es que el archivo no existe (ya verificado arriba)
      if(error != 5002) // FILE_NOT_FOUND
      {
         Print("WARNING: Cannot open master file for reading (error ", error, ")");
         Print("Relative path: ", filename);
         Print("Full path: ", filenameFull);
      }
      return;
   }
   
   // ---------------------------
   // 1) Leer posiciones del Master
   // ---------------------------
   struct MasterPos
   {
      string symbol;
      ENUM_POSITION_TYPE direction;
      double volume;   // volumen final ya escalado
   };
   
   MasterPos masterList[];
   ArrayResize(masterList, 0);
   
   while(!FileIsEnding(handle))
   {
      string ticketStr = FileReadString(handle);
      string masterSymbol = FileReadString(handle);
      string proportionStr = FileReadString(handle);
      
      // Convertir valores
      ulong ticket = (ulong)StringToInteger(ticketStr);
      double proportion = StringToDouble(proportionStr);
      
      // Calcular volumen base: proportion * AccountDepositsAndWithdrawals del Slave
      double baseVolume = proportion * AccountDepositsAndWithdrawals;
      
      // Aplicar multiplicador si está configurado
      double multiplier = GetSymbolMultiplier(masterSymbol);
      double calculatedVol = baseVolume * multiplier;
      
      // Determinar dirección según el signo de la proporción
      ENUM_POSITION_TYPE masterDir = (proportion >= 0) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      double absVol = MathAbs(calculatedVol);
      
      // Reversión si procede
      ENUM_POSITION_TYPE slaveDir = ReverseDirection(masterDir);
      
      // Mapear símbolo del Master al símbolo del Slave
      string slaveSymbol = MapSymbol(masterSymbol);
      
      // Obtener límites del símbolo y normalizar volumen
      double minVol = SymbolInfoDouble(slaveSymbol, SYMBOL_VOLUME_MIN);
      double maxVol = SymbolInfoDouble(slaveSymbol, SYMBOL_VOLUME_MAX);
      double stepVol = SymbolInfoDouble(slaveSymbol, SYMBOL_VOLUME_STEP);
      
      // Redondear al step más cercano
      if(stepVol > 0)
         absVol = MathFloor(absVol / stepVol) * stepVol;
      
      // Asegurar que esté dentro de los límites
      absVol = MathMax(absVol, minVol);
      absVol = MathMin(absVol, maxVol);
      
      // Si el volumen es válido, agregar a la lista
      if(absVol >= minVol)
      {
         MasterPos mp;
         mp.symbol = slaveSymbol;
         mp.direction = slaveDir;
         mp.volume = absVol;
         
         int sz = ArraySize(masterList);
         ArrayResize(masterList, sz + 1);
         masterList[sz] = mp;
      }
   }
   
   FileClose(handle);
   
   // Actualizar timestamp de última lectura
   LastSlaveFileTime = fileModifyTime;
   
   // ---------------------------
   // 2) Mapa de posiciones actuales del Slave
   // ---------------------------
   CPositionInfo pos;
   string slaveSymbols[];
   ENUM_POSITION_TYPE slaveDir[];
   double slaveVol[];
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(pos.SelectByIndex(i))
      {
         int sz = ArraySize(slaveSymbols);
         ArrayResize(slaveSymbols, sz + 1);
         ArrayResize(slaveDir, sz + 1);
         ArrayResize(slaveVol, sz + 1);
         
         slaveSymbols[sz] = pos.Symbol();
         slaveDir[sz] = pos.PositionType();
         slaveVol[sz] = pos.Volume();
      }
   }
   
   CTrade trade;
   
   // ---------------------------
   // 3) Cerrar posiciones que el Master NO tiene
   // ---------------------------
   for(int i = 0; i < ArraySize(slaveSymbols); i++)
   {
      bool found = false;
      for(int j = 0; j < ArraySize(masterList); j++)
      {
         if(masterList[j].symbol == slaveSymbols[i])
         {
            found = true;
            break;
         }
      }
      if(!found)
      {
         // Cerrar posición que el Master no tiene
         if(pos.Select(slaveSymbols[i]))
            trade.PositionClose(pos.Ticket());
      }
   }
   
   // ---------------------------
   // 4) Crear/ajustar posiciones según el Master
   // ---------------------------
   for(int i = 0; i < ArraySize(masterList); i++)
   {
      string symbol = masterList[i].symbol;
      ENUM_POSITION_TYPE dir = masterList[i].direction;
      double vol = masterList[i].volume;
      
      bool slaveHasPos = false;
      int slavePosIdx = -1;
      
      // Buscar si ya existe
      for(int k = 0; k < ArraySize(slaveSymbols); k++)
      {
         if(slaveSymbols[k] == symbol)
         {
            slaveHasPos = true;
            slavePosIdx = k;
            break;
         }
      }
      
      if(!slaveHasPos)
      {
         // Abrir nueva posición
         double minVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
         if(vol >= minVol)
         {
            if(dir == POSITION_TYPE_BUY)
               trade.Buy(vol, symbol);
            else
               trade.Sell(vol, symbol);
         }
         continue;
      }
      
      // Si la dirección difiere → cerrar y reabrir
      if(slaveDir[slavePosIdx] != dir)
      {
         // Siempre se puede cerrar
         if(pos.Select(symbol))
            trade.PositionClose(pos.Ticket());
         
         // Reabrir
         double minVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
         if(vol >= minVol)
         {
            if(dir == POSITION_TYPE_BUY)
               trade.Buy(vol, symbol);
            else
               trade.Sell(vol, symbol);
         }
         continue;
      }
      
      // Ajustar volumen si es distinto
      double current = slaveVol[slavePosIdx];
      double diff = vol - current;
      double minVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      
      if(MathAbs(diff) > 0.0000001)
      {
         if(diff > 0)
         {
            // Añadir diferencia
            if(diff >= minVol)
            {
               if(dir == POSITION_TYPE_BUY)
                  trade.Buy(diff, symbol);
               else
                  trade.Sell(diff, symbol);
            }
         }
         else
         {
            // Reducir parcialmente
            double closeVol = MathAbs(diff);
            double stepVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
            if(stepVol > 0)
               closeVol = MathFloor(closeVol / stepVol) * stepVol;
            
            if(closeVol >= minVol && closeVol < current)
            {
               if(pos.Select(symbol))
                  trade.PositionClosePartial(symbol, closeVol);
            }
         }
      }
   }
}

//===================================================================
// DEINIT
//===================================================================
void OnDeinit(const int reason)
{
   EventKillTimer();
   
   // Eliminar dashboard completamente (tanto Master como Slave)
   DeleteDashboard();
   Print("HCPropsController: Dashboard eliminado");
   
   // Si es Master, eliminar el archivo de sincronización
   if(Mode == MODE_MASTER)
   {
      EnableTrading();

      string filePath = GetSyncFilePath(); // Ruta relativa para FILE_COMMON
      if(FileIsExist(filePath, FILE_COMMON))
      {
         if(FileDelete(filePath, FILE_COMMON))
         {
            Print("HCPropsController: Archivo de sincronización eliminado: ", GetSyncFilePathFull());
         }
         else
         {
            Print("HCPropsController: ADVERTENCIA - No se pudo eliminar archivo de sincronización: ", GetSyncFilePathFull(), " - Error: ", GetLastError());
         }
      }
   }
}