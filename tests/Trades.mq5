#property strict
#include <Trade/Trade.mqh>
int FaultMode=0,DeleteCalls=0,CloseCalls=0;
string CalendarCurrency="";
class CFaultTrade : public CTrade
{
private:
   uint fake;
public:
   CFaultTrade(){fake=0;}
   bool OrderDelete(ulong ticket)
   {
      if(!MQLInfoInteger(MQL_TESTER)) return false;
      DeleteCalls++;
      if(FaultMode==1){fake=TRADE_RETCODE_MARKET_CLOSED;return true;}
      fake=0;return CTrade::OrderDelete(ticket);
   }
   bool PositionClose(ulong ticket,ulong deviation=ULONG_MAX)
   {
      if(!MQLInfoInteger(MQL_TESTER)) return false;
      CloseCalls++;
      if(FaultMode==1){fake=TRADE_RETCODE_CONNECTION;return false;}
      if(FaultMode==2)
      {
         fake=TRADE_RETCODE_DONE_PARTIAL;
         return CTrade::PositionClosePartial(ticket,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),deviation);
      }
      fake=0;return CTrade::PositionClose(ticket,deviation);
   }
   uint ResultRetcode() const {return fake>0 ? fake : CTrade::ResultRetcode();}
};
int TestCalendarHistory(MqlCalendarValue &values[],datetime from,datetime to,const string country=NULL,const string currency=NULL)
{
   ArrayResize(values,0);
   if(!MQLInfoInteger(MQL_TESTER) || currency!=CalendarCurrency || currency=="") return 0;
   ArrayResize(values,1);ZeroMemory(values[0]);
   values[0].event_id=1;values[0].time=TimeCurrent();
   return 1;
}
bool TestCalendarEvent(ulong id,MqlCalendarEvent &event)
{
   if(!MQLInfoInteger(MQL_TESTER)) return false;
   ZeroMemory(event);event.id=id;event.importance=CALENDAR_IMPORTANCE_HIGH;event.name="Synthetic high impact";
   return true;
}
#define HC_CLOSE_TRADE_CLASS CFaultTrade
#define CalendarValueHistory TestCalendarHistory
#define CalendarEventById TestCalendarEvent
#define OnInit HCOriginalInit
#define OnTimer HCOriginalTimer
#define OnDeinit HCOriginalDeinit
#include "../HCPropsController.mq5"
#undef CalendarValueHistory
#undef CalendarEventById
#undef OnInit
#undef OnTimer
#undef OnDeinit
#include "EntryGate.mqh"
int Checks=0,Failures=0,Stage=0;
bool Finished=false;
void Check(string name,bool ok)
{
   Checks++;if(!ok) Failures++;
   Print("HC_TEST|",name,"|",ok ? "PASS" : "FAIL");
}
int OnInit()
{
   if(!MQLInfoInteger(MQL_TESTER)) return INIT_FAILED;
   GlobalVariablesDeleteAll("HCPropsController");
   int rc=HCOriginalInit();
   Check("trades_native_init",rc==INIT_SUCCEEDED);
   return rc;
}
void OnTick()
{
   if(!MQLInfoInteger(MQL_TESTER) || Finished) return;
   MqlTick q;if(!SymbolInfoTick(_Symbol,q) || q.bid<=0) return;
   CTrade t;t.SetTypeFillingBySymbol(_Symbol);
   double lot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   if(Stage==0)
   {
      Check("fixture_open_position",t.Buy(2*lot,_Symbol) && PositionsTotal()==1);
      double distance=MathMax(1000*_Point,2*SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point);
      Check("fixture_open_pending",t.BuyLimit(lot,NormalizeDouble(q.bid-distance,_Digits),_Symbol) && OrdersTotal()==1);
      CalendarCurrency="USD";g_lastNewsFetch=0;
      for(int i=0;i<5;i++) HCOriginalTimer();
      Check("usd_news_real_pipeline",IsNewsBlocked && StringFind(g_activeNews,"USD")==0 && !HCEntradaPermitida());
      Check("pause_open_keeps_position",NewsMode==NEWS_PAUSE_OPEN && PositionsTotal()==1 && CloseCalls==0);
      Check("pause_open_removes_pending",OrdersTotal()==0 && DidCloseOrders);
      CalendarCurrency="JPY";g_lastNewsFetch=0;
      for(int i=0;i<5;i++) HCOriginalTimer();
      Check("jpy_news_real_pipeline",IsNewsBlocked && StringFind(g_activeNews,"JPY")==0 && !HCEntradaPermitida());
      Check("jpy_pause_keeps_position",PositionsTotal()==1 && CloseCalls==0);
      CalendarCurrency="";g_lastNewsFetch=0;
      for(int i=0;i<5;i++) HCOriginalTimer();
      Check("news_exit_real_gate_open",!IsNewsBlocked && HCEntradaPermitida());
      Check("fixture_reopen_pending",t.BuyLimit(lot,NormalizeDouble(q.bid-distance,_Digits),_Symbol) && OrdersTotal()==1);
      FaultMode=1;TotalLocked=true;IsGlobalTradingDisabled=true;
      CheckAndUpdateTradingStatus();
      Check("rejection_not_flat",PositionsTotal()==1 && OrdersTotal()==1 && !DidCloseOrders && !DidClosePositions);
      Check("rejection_five_second_backoff",HCNextCloseAttemptMs>GetTickCount64()+4000);
      int before=CloseCalls+DeleteCalls;
      FaultMode=0;CheckAndUpdateTradingStatus();
      Check("backoff_no_requests",CloseCalls+DeleteCalls==before);
      HCNextCloseAttemptMs=0; // Explicit deterministic deadline advance, not broker latency evidence.
      FaultMode=2;CheckAndUpdateTradingStatus();
      Check("pending_retry_confirmed",OrdersTotal()==0 && DidCloseOrders);
      Check("partial_real_volume",PositionSelect(_Symbol) && MathAbs(PositionGetDouble(POSITION_VOLUME)-lot)<0.0000001 && !DidClosePositions);
      Check("partial_one_second_backoff",HCNextCloseAttemptMs>GetTickCount64());
      HCNextCloseAttemptMs=0;FaultMode=0;CheckAndUpdateTradingStatus();
      Check("partial_retry_flat",PositionsTotal()==0 && OrdersTotal()==0 && DidClosePositions && DidCloseOrders);
      Check("flat_lock_remains",TotalLocked && TradingIsDisabled());
      Stage=1;
      return;
   }
   if(Stage==1)
   {
      Check("fixture_late_position_on_later_tick",t.Buy(lot,_Symbol) && PositionsTotal()==1);
      Stage=2;return;
   }
   if(Stage==2 && PositionsTotal()==0)
   {
      Check("late_position_closed_by_native_timer",DidClosePositions && TotalLocked && TradingIsDisabled());
      TotalLocked=false;IsGlobalTradingDisabled=false;PersistState();
      CalendarCurrency="USD";g_lastNewsFetch=0;CheckNews();
      double distance=MathMax(1000*_Point,2*SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point);
      Check("fixture_pending_only",t.BuyLimit(lot,NormalizeDouble(q.bid-distance,_Digits),_Symbol) && OrdersTotal()==1 && PositionsTotal()==0);
      FaultMode=1;HCNextCloseAttemptMs=0;CheckAndUpdateTradingStatus();
      Check("pending_only_reject_not_complete",OrdersTotal()==1 && !DidCloseOrders);
      Check("pending_only_backoff_scheduled",HCNextCloseAttemptMs>GetTickCount64()+4000);
      int before=DeleteCalls;CheckAndUpdateTradingStatus();
      Check("pending_only_backoff_respected",DeleteCalls==before);
      FaultMode=0;HCNextCloseAttemptMs=0;CheckAndUpdateTradingStatus();
      Check("pending_only_retry_confirmed",OrdersTotal()==0 && DidCloseOrders);
      Finished=true;
      Print("HC_SUMMARY|checks=",Checks,"|failed=",Failures);
      TesterStop();
   }
}
void OnTimer()
{
   if(!MQLInfoInteger(MQL_TESTER) || Finished) return;
   HCOriginalTimer();
}
void OnDeinit(const int reason)
{
   if(!MQLInfoInteger(MQL_TESTER)) return;
   HCOriginalDeinit(reason);
   if(!Finished) Print("HC_INCOMPLETE|trades|stage=",Stage);
}
