#property strict
#define OnInit HCOriginalInit
#define OnTimer HCOriginalTimer
#define OnDeinit HCOriginalDeinit
#define OnTradeTransaction HCOriginalTransaction
#include "../HCPropsController.mq5"
#undef OnInit
#undef OnTimer
#undef OnDeinit
#undef OnTradeTransaction
#include "EntryGate.mqh"
input string FixtureOtherSymbol="TEST_OTHER";
int Checks=0,Failures=0;
bool Finished=false,Started=false;
void Check(string name,bool ok){Checks++;if(!ok)Failures++;Print("HC_TEST|",name,"|",ok?"PASS":"FAIL");}
void Finish(){Finished=true;Print("HC_SUMMARY|checks=",Checks,"|failed=",Failures);TesterStop();}
int OnInit()
{
   if(!MQLInfoInteger(MQL_TESTER))return INIT_FAILED;
   if(Mode==MODE_MASTER)SymbolSelect(FixtureOtherSymbol,true);
   GlobalVariablesDeleteAll("HCPropsController");GlobalVariablesDeleteAll("HCI1_");GlobalVariablesDeleteAll("HCT1_");
   GlobalVariableSet(GV_TOTAL_LOCK,1);
   if(MaxLossPercentPerIdea<0 || MaxProfitPercentPerIdea<0)
   {
      Check("negative_idea_native_init_rejected",HCOriginalInit()==INIT_PARAMETERS_INCORRECT);
      HCOriginalDeinit(REASON_INITFAILED);
      Check("negative_idea_preserves_lock",GlobalVariableGet(GV_TOTAL_LOCK)==1);
      Check("negative_idea_no_heartbeat",!GlobalVariableCheck(GV_HEARTBEAT));
      Check("negative_idea_gate_closed",!HCEntradaPermitida());
      Check("negative_idea_handle_released",g_instanceFile==INVALID_HANDLE);
      Finish();return INIT_SUCCEEDED;
   }
   GlobalVariableDel(GV_TOTAL_LOCK);
   Check("idea_valid_native_init",HCOriginalInit()==INIT_SUCCEEDED);Started=g_initialized;
   Check("idea_valid_native_heartbeat",GlobalVariableGet(GV_HEARTBEAT)==(double)TimeLocal());
   AccountDepositsAndWithdrawals=10000;
   Check("idea_zero_pnl",HCIdeaBreach(0)==0);
   if(MaxLossPercentPerIdea>0)
   {
      double bound=10000*MaxLossPercentPerIdea/100;
      Check("loss_inside",HCIdeaBreach(-bound+0.01)==0);
      Check("loss_equal",HCIdeaBreach(-bound)==1);
      Check("loss_outside",HCIdeaBreach(-bound-0.01)==1);
   }
   if(MaxProfitPercentPerIdea>0)
   {
      double bound=10000*MaxProfitPercentPerIdea/100;
      Check("profit_inside",HCIdeaBreach(bound-0.01)==0);
      Check("profit_equal",HCIdeaBreach(bound)==2);
      Check("profit_outside",HCIdeaBreach(bound+0.01)==2);
   }
   if(!HCIdeaLimitsEnabled())Check("disabled_no_breach",HCIdeaBreach(-1e6)==0 && HCIdeaBreach(1e6)==0);
   AccountDepositsAndWithdrawals=0;Check("zero_base_invalid",!HCIdeaBaseValid());
   AccountDepositsAndWithdrawals=-1;Check("negative_base_invalid",!HCIdeaBaseValid());
   AccountDepositsAndWithdrawals=10000;
   ulong id=((ulong)1<<53);
   Check("ids_above_double_precision",HCIdeaHex(id)!=HCIdeaHex(id+1));
   Check("uint64_roundtrip",HCIdeaFromHex(HCIdeaHex(ULONG_MAX))==ULONG_MAX);
   Check("latch_key_40",StringLen(HCIdeaLatchKey(ULONG_MAX,POSITION_TYPE_BUY))==40);
   Check("tomb_key_55",StringLen(HCIdeaTombKey(ULONG_MAX))==55);
   Check("direction_separate",HCIdeaLatchKey(id,POSITION_TYPE_BUY)!=HCIdeaLatchKey(id,POSITION_TYPE_SELL));
   return INIT_SUCCEEDED;
}
void OnTick()
{
   if(!MQLInfoInteger(MQL_TESTER) || Finished)return;
   if(Mode==MODE_MASTER)
   {
      MqlTick quote;
      if(!SymbolInfoTick(FixtureOtherSymbol,quote) || quote.bid<=0)return;
      CTrade t;t.SetTypeFillingBySymbol(_Symbol);
      double lot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
      bool ok=t.Buy(lot,_Symbol);ulong first=t.ResultOrder();
      ok=t.Buy(lot,_Symbol) && ok;ulong second=t.ResultOrder();
      ok=t.Sell(lot,_Symbol) && ok;ulong other=t.ResultOrder();
      t.SetTypeFillingBySymbol(FixtureOtherSymbol);
      ok=t.Buy(SymbolInfoDouble(FixtureOtherSymbol,SYMBOL_VOLUME_MIN),FixtureOtherSymbol) && ok;ulong secondSymbol=t.ResultOrder();
      Check("master_fixture_four_real_positions",ok && PositionsTotal()==4);
      CheckIdeaLimits();Check("zero_inputs_preserve_inventory",PositionsTotal()==4);
      string path=GetSyncFilePath()+".slave.synthetic";
      int h=FileOpen(path,FILE_WRITE|FILE_CSV|FILE_COMMON,',');
      Check("master_status_fixture_open",h!=INVALID_HANDLE);
      if(h!=INVALID_HANDLE)
      {
         FileWrite(h,"HB",(long)TimeLocal());FileWrite(h,"LOCK",0,"");
         FileWrite(h,"CLOSE",first,"IDEA_LOSS");FileWrite(h,"CLOSE",second,"IDEA_LOSS");
         FileWrite(h,"END",(long)TimeLocal());FileClose(h);
         ProcessSlaveStatusFiles();
         Check("master_closes_only_named_originals",!PositionSelectByTicket(first) && !PositionSelectByTicket(second) && PositionSelectByTicket(other) && PositionSelectByTicket(secondSymbol) && PositionsTotal()==2);
         Check("master_no_whole_account_lock",!TradingIsDisabled() && !TotalLocked && !IsSlaveLockTradingDisabled);
         Check("master_writer_exports_survivors",WriteSyncFile());
         int masterFile=FileOpen(GetSyncFilePath(),FILE_READ|FILE_CSV|FILE_COMMON,',');
         TargetPos exported[];int parsed=ParseMasterFile(masterFile,exported);FileClose(masterFile);
         Check("real_writer_frame_roundtrip",parsed==0 && g_ideaMasterInventoryValid && ArraySize(exported)==2);
         Check("export_contains_only_unaffected_tickets",InUlongArray(g_ideaMasterInventory,other) && InUlongArray(g_ideaMasterInventory,secondSymbol) && !InUlongArray(g_ideaMasterInventory,first) && !InUlongArray(g_ideaMasterInventory,second));
         FileDelete(path,FILE_COMMON);
      }
   }
   Finish();
}
void OnTimer(){if(MQLInfoInteger(MQL_TESTER) && Started && !Finished)HCOriginalTimer();}
void OnDeinit(const int reason){if(MQLInfoInteger(MQL_TESTER) && Started)HCOriginalDeinit(reason);}
