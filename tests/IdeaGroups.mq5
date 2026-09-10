#property strict
#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
input string FixtureOtherSymbol="TEST_OTHER";
int FaultMode=0,CloseCalls=0,PnlPhase=0;
ulong A=0,B=0,Opposite=0,Other=0,Late=0;
double FixtureProfit(ENUM_POSITION_PROPERTY_DOUBLE property)
{
   if(!MQLInfoInteger(MQL_TESTER))return PositionGetDouble(property);
   if(property!=POSITION_PROFIT && property!=POSITION_SWAP)return PositionGetDouble(property);
   ulong ticket=(ulong)PositionGetInteger(POSITION_TICKET);
   // Inject valuations only. Selection, grouping, volume, closes and persistence remain native.
   if(ticket==A || ticket==B)
   {
      if(PnlPhase==1)return property==POSITION_PROFIT ? -60.0 : -2.5;
      if(PnlPhase==2)return property==POSITION_PROFIT ? 120.0 : 5.0;
   }
   return 0.0;
}
class CFaultIdeaTrade:public CTrade
{
private:uint fake;
public:
   CFaultIdeaTrade(){fake=0;}
   bool PositionClose(ulong ticket,ulong deviation=ULONG_MAX)
   {
      if(!MQLInfoInteger(MQL_TESTER))return false;
      CloseCalls++;
      if(FaultMode==1){fake=TRADE_RETCODE_REJECT;return false;}
      if(FaultMode==2){fake=TRADE_RETCODE_CONNECTION;return false;}
      if(FaultMode==3){fake=TRADE_RETCODE_DONE_PARTIAL;return CTrade::PositionClosePartial(ticket,SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),deviation);}
      return CTrade::PositionClose(ticket,deviation);
   }
   uint ResultRetcode() const{return fake>0?fake:CTrade::ResultRetcode();}
};
#define PositionGetDouble FixtureProfit
#define HC_CLOSE_TRADE_CLASS CFaultIdeaTrade
#define OnInit HCOriginalInit
#define OnTimer HCOriginalTimer
#define OnDeinit HCOriginalDeinit
#define OnTradeTransaction HCOriginalTransaction
#include "../HCPropsController.mq5"
#undef PositionGetDouble
#undef OnInit
#undef OnTimer
#undef OnDeinit
#undef OnTradeTransaction
#include "EntryGate.mqh"
int Checks=0,Failures=0,Stage=0;
bool Finished=false;
void Check(string name,bool ok){Checks++;if(!ok)Failures++;Print("HC_TEST|",name,"|",ok?"PASS":"FAIL");}
void Expire(){for(int i=0;i<ArraySize(g_ideaGroups);i++)g_ideaGroups[i].nextAttempt=0;}
int Group(){for(int i=0;i<ArraySize(g_ideaGroups);i++)if(g_ideaGroups[i].symbol==_Symbol && g_ideaGroups[i].dir==POSITION_TYPE_BUY)return i;return -1;}
bool Latched(ulong ticket){if(!PositionSelectByTicket(ticket))return false;return HCIdeaPositionLatched((ulong)PositionGetInteger(POSITION_IDENTIFIER),(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE));}
bool Survivors(){return PositionSelectByTicket(Opposite) && PositionSelectByTicket(Other) && OrdersTotal()==1;}
int OnInit()
{
   if(!MQLInfoInteger(MQL_TESTER))return INIT_FAILED;
   Print("HC_FIXTURE|P/L profit+swap injected for exact boundaries/rebound; real tickets and native group implementation");
   GlobalVariablesDeleteAll("HCPropsController");GlobalVariablesDeleteAll("HCI1_");GlobalVariablesDeleteAll("HCT1_");
   GlobalVariableSet(GV_INIT_BAL,10000); // Isolate threshold math from the tester deposit needed for margin.
   SymbolSelect(FixtureOtherSymbol,true);
   int rc=HCOriginalInit();Check("groups_native_init",rc==INIT_SUCCEEDED);return rc;
}
void OnTick()
{
   if(!MQLInfoInteger(MQL_TESTER) || Finished)return;
   MqlTick q,o;if(!SymbolInfoTick(_Symbol,q) || !SymbolInfoTick(FixtureOtherSymbol,o) || q.bid<=0 || o.bid<=0)return;
   CTrade t;t.SetTypeFillingBySymbol(_Symbol);double lot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   if(Stage==0)
   {
      bool ok=t.Buy(2*lot,_Symbol);A=t.ResultOrder();t.SetExpertMagicNumber(123);
      ok=t.Buy(2*lot,_Symbol)&&ok;B=t.ResultOrder();ok=t.Sell(lot,_Symbol)&&ok;Opposite=t.ResultOrder();
      t.SetTypeFillingBySymbol(FixtureOtherSymbol);ok=t.Buy(SymbolInfoDouble(FixtureOtherSymbol,SYMBOL_VOLUME_MIN),FixtureOtherSymbol)&&ok;Other=t.ResultOrder();
      t.SetTypeFillingBySymbol(_Symbol);
      ok=t.BuyLimit(lot,NormalizeDouble(q.bid-1000*_Point,_Digits),_Symbol)&&ok;
      Check("group_fixture_two_buys_opposite_other_pending",ok && PositionsTotal()==4 && OrdersTotal()==1);
      PnlPhase=1;FaultMode=1;CheckIdeaLimits();int g=Group();
      Check("loss_sum_profit_swap_exact_boundary",g>=0 && g_ideaGroups[g].count==2 && g_ideaGroups[g].pnl==-125 && g_ideaGroups[g].reason==1);
      Check("loss_members_individually_below",HCIdeaBreach(-62.5)==0 && HCIdeaBreach(-125)==1);
      Check("reject_durable_all_members",Latched(A) && Latched(B) && Survivors());
      int calls=CloseCalls;CheckIdeaLimits();Check("reject_backoff_no_resend",CloseCalls==calls);
      Check("reject_one_second_deadline",g>=0 && g_ideaGroups[g].nextAttempt>GetTickCount64());
      FaultMode=2;Expire();CheckIdeaLimits();g=Group();
      Check("connection_five_second_deadline",g>=0 && g_ideaGroups[g].nextAttempt>GetTickCount64()+4000);
      PnlPhase=0;CheckIdeaLimits();g=Group();
      Check("rebound_keeps_intent",g>=0 && g_ideaGroups[g].reason==1 && g_ideaGroups[g].pnl==0 && Latched(A) && Latched(B));
      Check("idea_does_not_close_gate_or_account",HCEntradaPermitida() && !TotalLocked && !IsDailyLimitTradingDisabled);
      Stage=1;return;
   }
   if(Stage==1)
   {
      Check("late_real_position_during_backoff",t.Buy(lot,_Symbol));Late=t.ResultOrder();
      int calls=CloseCalls;CheckIdeaLimits();
      Check("late_intent_durable_before_retry",Latched(Late) && CloseCalls==calls && Survivors());
      // Real lifecycle restart with a different persisted baseline and zero injected P/L.
      HCOriginalDeinit(REASON_PARAMETERS);GlobalVariableSet(GV_INIT_BAL,20000);
      Check("restart_real_init",HCOriginalInit()==INIT_SUCCEEDED);
      Check("restart_changed_base_and_intent",AccountDepositsAndWithdrawals==20000 && Latched(A) && Latched(B) && Latched(Late));
      FaultMode=3;Expire();CheckIdeaLimits();
      Check("partial_volume_not_flat",PositionSelectByTicket(A) && MathAbs(PositionGetDouble(POSITION_VOLUME)-lot)<1e-8 && Latched(A));
      Check("partial_segmented_survivors",Survivors());
      FaultMode=0;Expire();CheckIdeaLimits();
      Check("partial_rebound_late_finish",!PositionSelectByTicket(A) && !PositionSelectByTicket(B) && !PositionSelectByTicket(Late) && Survivors());
      Check("closed_latches_cleaned",GlobalVariablesTotal()>0 && Group()<0);
      Check("new_idea_no_cooldown",t.Buy(lot,_Symbol));A=t.ResultOrder();B=0;CheckIdeaLimits();
      Check("new_idea_not_latched",PositionSelectByTicket(A) && !Latched(A) && Survivors());
      t.PositionClose(A);A=0;AccountDepositsAndWithdrawals=10000;
      bool ok=t.Buy(lot,_Symbol);A=t.ResultOrder();ok=t.Buy(lot,_Symbol)&&ok;B=t.ResultOrder();
      Check("profit_real_group_fixture",ok);
      PnlPhase=2;FaultMode=1;CheckIdeaLimits();int g=Group();
      Check("profit_sum_swap_exact_boundary",g>=0 && g_ideaGroups[g].count==2 && g_ideaGroups[g].pnl==250 && g_ideaGroups[g].reason==2);
      Check("profit_members_individually_below",HCIdeaBreach(125)==0 && HCIdeaBreach(250)==2);
      Check("profit_latches_segmented",Latched(A) && Latched(B) && Survivors());
      PnlPhase=0;FaultMode=0;Expire();CheckIdeaLimits();
      Check("profit_rebound_finish_only_group",!PositionSelectByTicket(A) && !PositionSelectByTicket(B) && Survivors());
      Check("idea_final_no_account_lock",HCEntradaPermitida() && !TradingIsDisabled() && !TotalLocked);
      Finished=true;Print("HC_SUMMARY|checks=",Checks,"|failed=",Failures);TesterStop();
   }
}
void OnTimer(){if(MQLInfoInteger(MQL_TESTER) && !Finished)HCOriginalTimer();}
void OnDeinit(const int reason){if(MQLInfoInteger(MQL_TESTER)){HCOriginalDeinit(reason);if(!Finished)Print("HC_INCOMPLETE|groups");}}
