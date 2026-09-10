#property strict
#include <Trade/Trade.mqh>
int FaultMode=0,DeleteCalls=0,CloseCalls=0;
bool CalendarActive=true;
class CForceFaultTrade:public CTrade
{
private:uint fake;
public:
   CForceFaultTrade(){fake=0;}
   bool OrderDelete(ulong ticket)
   {
      if(!MQLInfoInteger(MQL_TESTER))return false;
      DeleteCalls++;
      if(FaultMode==1 || FaultMode==3){fake=TRADE_RETCODE_MARKET_CLOSED;return false;}
      fake=0;return CTrade::OrderDelete(ticket);
   }
   bool PositionClose(ulong ticket,ulong deviation=ULONG_MAX)
   {
      if(!MQLInfoInteger(MQL_TESTER))return false;
      CloseCalls++;
      if(FaultMode==1){fake=TRADE_RETCODE_CONNECTION;return false;}
      if(FaultMode==2)
      {
         fake=TRADE_RETCODE_DONE_PARTIAL;
         return CTrade::PositionClosePartial(ticket,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),deviation);
      }
      fake=0;return CTrade::PositionClose(ticket,deviation);
   }
   uint ResultRetcode()const{return fake>0?fake:CTrade::ResultRetcode();}
};
int ForceCalendar(MqlCalendarValue &values[],datetime from,datetime to,const string country=NULL,const string currency=NULL)
{
   ArrayResize(values,0);
   if(!MQLInfoInteger(MQL_TESTER) || !CalendarActive || currency!="USD")return 0;
   ArrayResize(values,1);ZeroMemory(values[0]);values[0].event_id=1;values[0].time=TimeCurrent();return 1;
}
bool ForceCalendarEvent(ulong id,MqlCalendarEvent &event)
{
   if(!MQLInfoInteger(MQL_TESTER))return false;
   ZeroMemory(event);event.id=id;event.importance=CALENDAR_IMPORTANCE_HIGH;event.name="Synthetic pause";return true;
}
#define HC_CLOSE_TRADE_CLASS CForceFaultTrade
#define CalendarValueHistory ForceCalendar
#define CalendarEventById ForceCalendarEvent
#define OnInit HCOriginalInit
#define OnTimer HCOriginalTimer
#define OnDeinit HCOriginalDeinit
#define OnTradeTransaction HCOriginalTransaction
#include "../HCPropsController.mq5"
#undef CalendarValueHistory
#undef CalendarEventById
#undef OnInit
#undef OnTimer
#undef OnDeinit
#undef OnTradeTransaction
#include "EntryGate.mqh"
int Checks=0,Failures=0,Stage=0,SavedCalls=0;
datetime Due=0;
bool Finished=false;
void Check(string name,bool ok){Checks++;if(!ok)Failures++;Print("HC_TEST|",name,"|",ok?"PASS":"FAIL");}
bool PendingFixture()
{
   MqlTick q;if(!SymbolInfoTick(_Symbol,q))return false;
   CTrade trade;trade.SetTypeFillingBySymbol(_Symbol);
   double distance=MathMax(1000*_Point,2*SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point);
   return trade.BuyLimit(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),NormalizeDouble(q.bid-distance,_Digits),_Symbol);
}
int OnInit()
{
   if(!MQLInfoInteger(MQL_TESTER))return INIT_FAILED;
   Print("HC_FIXTURE|native HC timer, scheduled due time and real inventory; calendar/close faults injected; retry deadlines explicitly advanced after assertions");
   GlobalVariablesDeleteAll("HCPropsController");GlobalVariablesDeleteAll("HCI1_");GlobalVariablesDeleteAll("HCT1_");
   int rc=HCOriginalInit();Check("force_native_init",rc==INIT_SUCCEEDED);
   Check("forced_exit_enabled_in_fixture",ForceExitEnabled && PropFirmMode && NewsMode==NEWS_PAUSE_OPEN);
   Due=NextForceExitTime;
   return rc;
}
void OnTick()
{
   if(!MQLInfoInteger(MQL_TESTER) || Finished || Stage!=0)return;
   MqlTick q;if(!SymbolInfoTick(_Symbol,q) || q.bid<=0)return;
   CTrade trade;trade.SetTypeFillingBySymbol(_Symbol);
   double lot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   Check("force_position_fixture",trade.Buy(2*lot,_Symbol) && PositionsTotal()==1);
   Check("force_pending_fixture",PendingFixture() && OrdersTotal()==1);
   Check("scheduled_due_is_upcoming",Due>TimeCurrent() && Due-TimeCurrent()<=120);
   FaultMode=1;g_lastNewsFetch=0;CheckNews();
   Check("news_pause_keeps_position_before_due",IsNewsBlocked && CloseCalls==0 && PositionsTotal()==1);
   Check("pending_only_reject_sets_backoff",DeleteCalls>0 && HCNextCloseAttemptMs>GetTickCount64());
   Stage=1;
}
void OnTimer()
{
   if(!MQLInfoInteger(MQL_TESTER) || Finished)return;
   if(Stage==1 && !ForceExitPending && TimeCurrent()>=Due && g_timerTick%5==4)
   {
      // Reproduce a fresh cancellation backoff immediately before the scheduled full cycle.
      HCNextCloseAttemptMs=0;CloseAllPositions(false);
      Check("due_pending_backoff_present",HCNextCloseAttemptMs>GetTickCount64()+4000 && PositionsTotal()==1 && OrdersTotal()==1);
      SavedCalls=CloseCalls;Stage=2;
   }
   HCOriginalTimer();
   if(Stage==2)
   {
      Check("due_first_flatten_not_skipped",ForceExitPending && CloseCalls==SavedCalls+1);
      Check("rejected_force_not_rescheduled",NextForceExitTime==Due && PositionsTotal()==1 && OrdersTotal()==1);
      Check("force_gate_blocked",TradingIsDisabled() && !HCEntradaPermitida() && StringFind(ActiveLockFlags(),"ForceExit")>=0);
      Check("force_failure_five_second_backoff",HCNextCloseAttemptMs>GetTickCount64()+4000);
      SavedCalls=CloseCalls+DeleteCalls;Stage=3;return;
   }
   if(Stage==3)
   {
      Check("fast_path_respects_force_backoff",CloseCalls+DeleteCalls==SavedCalls && ForceExitPending && NextForceExitTime==Due);
      HCOriginalDeinit(REASON_PARAMETERS);
      Check("memory_deinit_preserves_force_intent",ForceExitPending && NextForceExitTime==Due);
      Check("memory_reinit_success",HCOriginalInit()==INIT_SUCCEEDED);
      Check("memory_reinit_preserves_due_and_retry",ForceExitPending && NextForceExitTime==Due && CloseCalls+DeleteCalls==SavedCalls);
      FaultMode=2;HCNextCloseAttemptMs=0;Stage=4;return;
   }
   if(Stage==4)
   {
      Check("force_partial_real_volume",PositionSelect(_Symbol) && MathAbs(PositionGetDouble(POSITION_VOLUME)-SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN))<1e-8);
      Check("partial_force_still_pending",ForceExitPending && NextForceExitTime==Due && !DidClosePositions && OrdersTotal()==0);
      Check("partial_one_second_backoff",HCNextCloseAttemptMs>GetTickCount64());
      SavedCalls=CloseCalls+DeleteCalls;Stage=5;return;
   }
   if(Stage==5)
   {
      Check("partial_backoff_no_starvation_or_resend",CloseCalls+DeleteCalls==SavedCalls && ForceExitPending && NextForceExitTime==Due);
      Check("late_pending_fixture",PendingFixture() && OrdersTotal()==1);
      FaultMode=3;HCNextCloseAttemptMs=0;Stage=6;return;
   }
   if(Stage==6)
   {
      Check("force_positions_flat_pending_rejected",PositionsTotal()==0 && OrdersTotal()==1);
      Check("orders_prevent_false_completion",ForceExitPending && NextForceExitTime==Due && !DidCloseOrders);
      Check("pending_retry_retains_five_seconds",HCNextCloseAttemptMs>GetTickCount64()+4000);
      FaultMode=0;HCNextCloseAttemptMs=0;Stage=7;return;
   }
   if(Stage==7 && !ForceExitPending)
   {
      Check("force_completed_only_with_flat_inventory",PositionsTotal()==0 && OrdersTotal()==0);
      Check("force_next_day_after_completion",NextForceExitTime==Due+86400);
      Check("completion_preserves_news_pause",IsNewsBlocked && TradingIsDisabled() && !HCEntradaPermitida());
      Check("force_did_not_create_economic_locks",!TotalLocked && !IsDailyLimitTradingDisabled && GlobalVariableGet(GV_TOTAL_LOCK)==0 && GlobalVariableGet(GV_DAILY_LOCK)==0);
      CalendarActive=false;g_lastNewsFetch=0;CheckNews();
      Check("no_stray_force_block_after_news",!ForceExitPending && !TradingIsDisabled() && HCEntradaPermitida());
      CTrade trade;trade.SetTypeFillingBySymbol(_Symbol);
      Check("new_position_after_completion",trade.Buy(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),_Symbol) && PositionsTotal()==1);
      SavedCalls=CloseCalls;Stage=8;return;
   }
   if(Stage==8)
   {
      Check("completed_force_does_not_reclose_new_position",PositionsTotal()==1 && CloseCalls==SavedCalls && !ForceExitPending && NextForceExitTime>TimeCurrent());
      Finished=true;Print("HC_SUMMARY|checks=",Checks,"|failed=",Failures);TesterStop();
   }
}
void OnDeinit(const int reason)
{
   if(!MQLInfoInteger(MQL_TESTER))return;
   HCOriginalDeinit(reason);
   if(!Finished)Print("HC_INCOMPLETE|force_exit|stage=",Stage);
}
