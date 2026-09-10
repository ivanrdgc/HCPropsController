#property strict
bool FailTimer=false;
bool TestTimer(const int milliseconds)
{
   if(!MQLInfoInteger(MQL_TESTER) || FailTimer) return false;
   return EventSetMillisecondTimer(milliseconds);
}
#define EventSetMillisecondTimer TestTimer
#define OnInit HCOriginalInit
#define OnTimer HCOriginalTimer
#define OnDeinit HCOriginalDeinit
#include "../HCPropsController.mq5"
#undef EventSetMillisecondTimer
#undef OnInit
#undef OnTimer
#undef OnDeinit
#include "EntryGate.mqh"
int Failures=0,Checks=0,TimerEvents=0,FullCycles=0;
bool Finished=false;
double LastHeartbeat=0;
void Check(string name,bool ok)
{
   Checks++;
   if(!ok) Failures++;
   Print("HC_TEST|",name,"|",ok ? "PASS" : "FAIL");
}
void Finish()
{
   Finished=true;
   Print("HC_SUMMARY|checks=",Checks,"|failed=",Failures);
   TesterStop();
}
int OnInit()
{
   if(!MQLInfoInteger(MQL_TESTER)) return INIT_FAILED;
   GlobalVariablesDeleteAll("HCPropsController");
   GlobalVariableSet(GV_TOTAL_LOCK,1);
   GlobalVariableSet(GV_DAILY_LOCK,1);
   GlobalVariableSet(GV_INIT_BAL,7777);
   GlobalVariableSet(GV_INIT_EQD,10000);
   GlobalVariableSet(GV_NEXT_RESET,(double)TimeCurrent()+86400);
   if(DailyResetHour==24)
   {
      Check("invalid_parameters_rejected",HCOriginalInit()==INIT_PARAMETERS_INCORRECT);
      HCOriginalDeinit(REASON_INITFAILED);
      Check("invalid_init_keeps_economic_locks",GlobalVariableGet(GV_TOTAL_LOCK)==1 && GlobalVariableGet(GV_DAILY_LOCK)==1);
      Check("invalid_init_no_heartbeat",!GlobalVariableCheck(GV_HEARTBEAT));
      Check("invalid_init_entry_blocked",!HCEntradaPermitida());
      Check("invalid_init_releases_handle",g_instanceFile==INVALID_HANDLE);
      Finish();
      return INIT_SUCCEEDED;
   }
   // Simulate the other owner BEFORE starting this HC instance, avoiding handle leaks.
   int hold=FileOpen("HCPropsController.lock",FILE_READ|FILE_WRITE|FILE_BIN);
   Check("owner_handle_acquired",hold!=INVALID_HANDLE);
   GlobalVariableSet(GV_HEARTBEAT,12345);
   GlobalVariableSet(GV_DISABLE,0.25);
   Check("duplicate_exclusive_handle_rejected",HCOriginalInit()==INIT_FAILED);
   HCOriginalDeinit(REASON_INITFAILED);
   Check("duplicate_preserves_owner_heartbeat",GlobalVariableGet(GV_HEARTBEAT)==12345);
   Check("duplicate_preserves_owner_disable",GlobalVariableGet(GV_DISABLE)==0.25);
   Check("duplicate_preserves_owner_locks",GlobalVariableGet(GV_TOTAL_LOCK)==1 && GlobalVariableGet(GV_DAILY_LOCK)==1);
   Check("duplicate_preserves_owner_base",GlobalVariableGet(GV_INIT_BAL)==7777);
   if(hold!=INVALID_HANDLE) FileClose(hold);
   FailTimer=true;
   Check("timer_failure_rejected",HCOriginalInit()==INIT_FAILED);
   Check("timer_failure_no_heartbeat",!GlobalVariableCheck(GV_HEARTBEAT));
   HCOriginalDeinit(REASON_INITFAILED);
   Check("timer_failure_locks_preserved",GlobalVariableGet(GV_TOTAL_LOCK)==1 && GlobalVariableGet(GV_DAILY_LOCK)==1);
   Check("timer_failure_closed_handle",g_instanceFile==INVALID_HANDLE);
   Check("forced_base_beats_persisted",ForceInitialBalance==10000 && AccountDepositsAndWithdrawals==10000 && GlobalVariableGet(GV_INIT_BAL)==10000);
   FailTimer=false;
   GlobalVariableDel(GV_INIT_BAL);
   TotalLocked=false;IsGlobalTradingDisabled=false;IsDailyLimitTradingDisabled=false;
   Check("native_init_success",HCOriginalInit()==INIT_SUCCEEDED);
   Check("locks_restored_without_base",TotalLocked && IsDailyLimitTradingDisabled && TradingIsDisabled());
   Check("native_init_exact_local_heartbeat",GlobalVariableGet(GV_HEARTBEAT)==(double)TimeLocal());
   Check("fresh_heartbeat_does_not_override_lock",!HCEntradaPermitida());
   TotalLocked=false;IsGlobalTradingDisabled=false;IsDailyLimitTradingDisabled=false;
   PersistState();CheckAndUpdateTradingStatus();
   LastHeartbeat=GlobalVariableGet(GV_HEARTBEAT);
   return INIT_SUCCEEDED;
}
void OnTimer()
{
   if(!MQLInfoInteger(MQL_TESTER) || Finished) return;
   HCOriginalTimer();TimerEvents++;
   if(g_timerTick%5!=0)
   {
      Check("fast_cycle_does_not_publish",GlobalVariableGet(GV_HEARTBEAT)==LastHeartbeat);
      return;
   }
   FullCycles++;
   Check("full_cycle_exact_local_heartbeat",GlobalVariableGet(GV_HEARTBEAT)==(double)TimeLocal());
   Check("native_heartbeat_advances",GlobalVariableGet(GV_HEARTBEAT)>LastHeartbeat);
   Check("native_heartbeat_opens_real_gate",HCEntradaPermitida());
   LastHeartbeat=GlobalVariableGet(GV_HEARTBEAT);
   if(FullCycles<2) return;
   Check("two_cycles_at_ten_timer_events",TimerEvents==10);
   // Boundary corruption tests supplement, not replace, native heartbeat evidence.
   GlobalVariableDel(GV_HEARTBEAT);Check("gate_absent",!HCEntradaPermitida());
   GlobalVariableSet(GV_HEARTBEAT,(double)TimeLocal());Check("gate_age_0",HCEntradaPermitida());
   GlobalVariableSet(GV_HEARTBEAT,(double)TimeLocal()-5);Check("gate_age_5",HCEntradaPermitida());
   GlobalVariableSet(GV_HEARTBEAT,(double)TimeLocal()-6);Check("gate_age_6",!HCEntradaPermitida());
   GlobalVariableSet(GV_HEARTBEAT,(double)TimeLocal()+1);Check("gate_future",!HCEntradaPermitida());
   for(int i=0;i<5;i++) HCOriginalTimer();
   Check("real_cycle_recovers_corrupted_heartbeat",HCEntradaPermitida() && GlobalVariableGet(GV_HEARTBEAT)==(double)TimeLocal());
   GlobalVariableSet(GV_TOTAL_LOCK,1);Check("gate_total_lock",!HCEntradaPermitida());GlobalVariableDel(GV_TOTAL_LOCK);
   GlobalVariableSet(GV_DAILY_LOCK,1);Check("gate_daily_lock",!HCEntradaPermitida());GlobalVariableDel(GV_DAILY_LOCK);
   DisableTrading();Check("gate_disable",!HCEntradaPermitida());
   MqlTradeRequest r={};r.action=TRADE_ACTION_DEAL;
   Check("gate_classifies_entry_deal",HCEsEntrada(r));r.position=1;
   Check("gate_excludes_position_close",!HCEsEntrada(r));r.position=0;r.position_by=2;
   Check("gate_excludes_close_by",!HCEsEntrada(r));r.action=TRADE_ACTION_SLTP;
   Check("gate_excludes_sltp",!HCEsEntrada(r));r.action=TRADE_ACTION_REMOVE;
   Check("gate_excludes_pending_cancel",!HCEsEntrada(r));r.action=TRADE_ACTION_PENDING;
   Check("gate_classifies_pending_entry",HCEsEntrada(r));
   TotalLocked=true;IsGlobalTradingDisabled=true;IsDailyLimitTradingDisabled=true;PersistState();
   HCOriginalDeinit(REASON_REMOVE);
   Check("deinit_preserves_locks",GlobalVariableGet(GV_TOTAL_LOCK)==1 && GlobalVariableGet(GV_DAILY_LOCK)==1 && TradingIsDisabled());
   Check("deinit_removes_heartbeat",!GlobalVariableCheck(GV_HEARTBEAT));
   Check("deinit_releases_handle",g_instanceFile==INVALID_HANDLE);
   Finish();
}
void OnTick() {}
void OnDeinit(const int reason)
{
   if(!MQLInfoInteger(MQL_TESTER)) return;
   HCOriginalDeinit(reason);
   if(!Finished) Print("HC_INCOMPLETE|lifecycle");
}
