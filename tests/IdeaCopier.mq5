#property strict
#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
bool InjectLoss=false;
int FaultMode=0,CloseCalls=0;
double CopierValue(ENUM_POSITION_PROPERTY_DOUBLE property)
{
   if(!MQLInfoInteger(MQL_TESTER) || (property!=POSITION_PROFIT && property!=POSITION_SWAP))return PositionGetDouble(property);
   string comment=PositionGetString(POSITION_COMMENT);
   bool selected=(comment=="HC101" || comment=="HC102");
   if(InjectLoss && selected)return property==POSITION_PROFIT?-60.0:-2.5;
   return 0;
}
class CFaultCopyTrade:public CTrade
{
private:uint fake;
public:
   CFaultCopyTrade(){fake=0;}
   bool PositionClose(ulong ticket,ulong deviation=ULONG_MAX)
   {
      if(!MQLInfoInteger(MQL_TESTER))return false;
      CloseCalls++;
      if(FaultMode==1){fake=TRADE_RETCODE_CONNECTION;return false;}
      return CTrade::PositionClose(ticket,deviation);
   }
   uint ResultRetcode()const{return fake>0?fake:CTrade::ResultRetcode();}
};
#define PositionGetDouble CopierValue
#define HC_CLOSE_TRADE_CLASS CFaultCopyTrade
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
int Checks=0,Failures=0;
bool Finished=false;
void Check(string name,bool ok){Checks++;if(!ok)Failures++;Print("HC_TEST|",name,"|",ok?"PASS":"FAIL");}
ulong Local(ulong master)
{
   CPositionInfo p;for(int i=0;i<PositionsTotal();i++)if(p.SelectByIndex(i) && p.Magic()==MagicNumber && MasterTicketOfPosition(p)==master)return p.Ticket();
   return 0;
}
void Frame(int kind=0,ulong seq=1)
{
   // 0 full; 1 omits closed group; 2 torn; 3 legacy; 4 malformed SL; 5 same full, signed levels.
   int h=FileOpen(GetSyncFilePath(),FILE_WRITE|FILE_CSV|FILE_COMMON,',');
   if(h==INVALID_HANDLE){Check("frame_write",false);return;}
   MqlTick q;SymbolInfoTick(_Symbol,q);
   if(kind!=3)FileWrite(h,"SEQ",seq,"USD");
   if(kind!=1 && kind!=4)
   {
      FileWrite(h,101,"REMOTE",0,0.02,q.ask,kind==5?q.ask-10:0,kind==5?q.ask+20:0,(long)TimeCurrent(),0);
      FileWrite(h,102,"REMOTE",0,0.02,q.ask,0,0,(long)TimeCurrent(),0);
   }
   if(kind==4)FileWrite(h,103,"REMOTE",1,0.02,q.bid,"BAD",0,(long)TimeCurrent(),0);
   else FileWrite(h,103,"REMOTE",1,0.02,q.bid,0,0,(long)TimeCurrent(),0);
   if(kind!=2 && kind!=3)FileWrite(h,"END",seq);
   FileClose(h);
}
string Status()
{
   int h=FileOpen(SlaveStatusPath(),FILE_READ|FILE_TXT|FILE_COMMON);string out="";
   if(h!=INVALID_HANDLE){while(!FileIsEnding(h))out+=FileReadString(h)+"\n";FileClose(h);}return out;
}
void Expire(){for(int i=0;i<ArraySize(g_ideaGroups);i++)g_ideaGroups[i].nextAttempt=0;}
void Malformed(string name,string wire)
{
   ulong seq=g_lastSeqSeen, survivor=Local(103);
   int targets=ArraySize(g_targets);
   int h=FileOpen(GetSyncFilePath(),FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(h==INVALID_HANDLE){Check("malformed_fixture_write",false);return;}
   FileWriteString(h,wire);FileClose(h);
   h=FileOpen(GetSyncFilePath(),FILE_READ|FILE_CSV|FILE_COMMON,',');
   TargetPos parsed[];int rc=ParseMasterFile(h,parsed);FileClose(h);
   Check(name+"_reject_without_seq_commit",rc==2 && g_lastSeqSeen==seq && !g_ideaMasterInventoryValid);
   SlaveSync();
   Check(name+"_no_ack_or_reconcile",HCIdeaIsTombstoned(777) && g_lastSeqSeen==seq &&
         ArraySize(g_targets)==targets && Local(103)==survivor && Local(101)==0 && Local(102)==0);
}
int OnInit()
{
   if(!MQLInfoInteger(MQL_TESTER))return INIT_FAILED;
   Print("HC_FIXTURE|copier real frame/tickets/groups; selected profit+swap injected; close rejection injected");
   GlobalVariablesDeleteAll("HCPropsController");GlobalVariablesDeleteAll("HCI1_");GlobalVariablesDeleteAll("HCT1_");
   FileDelete(GetSyncFilePath(),FILE_COMMON);FileDelete(SlaveStatusPath(),FILE_COMMON);
   int rc=HCOriginalInit();Check("copier_native_init",rc==INIT_SUCCEEDED);return rc;
}
void OnTick()
{
   if(!MQLInfoInteger(MQL_TESTER) || Finished)return;
   MqlTick q;if(!SymbolInfoTick(_Symbol,q)||q.bid<=0)return;
   Frame(5);TargetPos parsed[];int h=FileOpen(GetSyncFilePath(),FILE_READ|FILE_CSV|FILE_COMMON,',');
   int rc=ParseMasterFile(h,parsed);FileClose(h);
   Check("mapped_signed_target_direction",rc==0 && ArraySize(parsed)==3 && parsed[0].symbol==_Symbol && parsed[0].dir==(InverseMode?POSITION_TYPE_SELL:POSITION_TYPE_BUY));
   Check("mapped_signed_levels",ArraySize(parsed)==3 && MathAbs(parsed[0].slDist-(InverseMode?20:-10))<1e-7 && MathAbs(parsed[0].tpDist-(InverseMode?-10:20))<1e-7);
   Frame(0,2);SlaveSync();
   ulong a=Local(101),b=Local(102),other=Local(103);
   Check("copier_opens_real_mapped_tickets",a>0 && b>0 && other>0 && PositionsTotal()==3);
   InjectLoss=true;FaultMode=1;CheckIdeaLimits();
   Check("copier_group_tombstones_only_selected",HCIdeaIsTombstoned(101) && HCIdeaIsTombstoned(102) && !HCIdeaIsTombstoned(103));
   Check("tombstone_captures_propagation_sign",GlobalVariableGet(HCIdeaTombKey(101))==(PropagateSlaveClose?1:-1));
   WriteSlaveStatusFile();string status=Status();
   Check("status_group_only_no_account_lock",StringFind(status,"LOCK,0")>=0 && !TradingIsDisabled() && !TotalLocked);
   Check("status_propagation_exact_selected",PropagateSlaveClose ? (StringFind(status,"CLOSE,101,IDEA_LOSS")>=0 && StringFind(status,"CLOSE,102,IDEA_LOSS")>=0 && StringFind(status,"CLOSE,103")<0) : StringFind(status,"CLOSE,")<0);
   int calls=CloseCalls;SlaveSync();Check("reconcile_cannot_bypass_latched_backoff",CloseCalls==calls && Local(101)==a && Local(102)==b);
   InjectLoss=false;
   // An absent Master ticket is not an ACK while its local close is still pending.
   Frame(1,3);SlaveSync();Check("ack_waits_for_local_flat",HCIdeaIsTombstoned(101) && Local(101)==a);
   Frame(0,4);SlaveSync();FaultMode=0;Expire();CheckIdeaLimits();
   Check("copier_closes_only_local_group",Local(101)==0 && Local(102)==0 && Local(103)==other && PositionsTotal()==1);
   for(int i=0;i<ArraySize(g_closedMasterWhen);i++)g_closedMasterWhen[i]=TimeLocal()-121;
   PruneClosedMasterTickets();
   Check("idea_requests_no_120s_expiry",!PropagateSlaveClose || (IsClosedMasterTicket(101)&&IsClosedMasterTicket(102)));
   SlaveSync();Check("tombstones_prevent_reopen",Local(101)==0 && Local(102)==0 && Local(103)==other);
   HCOriginalDeinit(REASON_PARAMETERS);
   Check("copier_restart_init",HCOriginalInit()==INIT_SUCCEEDED);
   SlaveSync();Check("restart_tombstones_durable",HCIdeaIsTombstoned(101) && HCIdeaIsTombstoned(102) && Local(101)==0);
   FileDelete(GetSyncFilePath(),FILE_COMMON);SlaveSync();Check("missing_frame_no_ack",HCIdeaIsTombstoned(101));
   Frame(2,4);SlaveSync();Check("same_seq_torn_no_ack",HCIdeaIsTombstoned(101));
   Frame(3,4);SlaveSync();Check("legacy_frame_no_ack",HCIdeaIsTombstoned(101));
   Frame(0,5);SlaveSync();Check("valid_raw_inventory_keeps_tombstone",HCIdeaIsTombstoned(101));
   EnqueueMasterClose(999,"SL");EnqueueMasterClose(999,"IDEA_PROFIT");EnqueueMasterClose(999,"SL");
   int at=-1;for(int i=0;i<ArraySize(g_closedMasterTicket);i++)if(g_closedMasterTicket[i]==999)at=i;
   Check("ordinary_request_upgraded_not_downgraded",at>=0 && g_closedMasterReason[at]=="IDEA_PROFIT");
   EnqueueMasterClose(888,"SL");PruneClosedMasterTickets();Check("ordinary_ttl_behavior_preserved",!IsClosedMasterTicket(888));
   Frame(1,6);SlaveSync();
   Check("valid_absence_and_flat_ack_cleans",!HCIdeaIsTombstoned(101) && !HCIdeaIsTombstoned(102) && !IsClosedMasterTicket(101));
   // Independent tombstone probe: a malformed numeric field must never authorize ACK.
   GlobalVariableSet(HCIdeaTombKey(777),PropagateSlaveClose?1:-1);HCIdeaRestoreSlaveCloses();
   Frame(4,7);SlaveSync();
   Check("malformed_numeric_frame_no_ack",HCIdeaIsTombstoned(777) && !g_ideaMasterInventoryValid);
   string fields[9]={"103","REMOTE","1","0.02","4603.4","0","0","1787878800","0"};
   int numeric[5]={3,4,5,6,8};
   string bad[9]={"BAD","NaN","inf","-inf","1.0junk","1e","1e309","","1 2"};
   for(int f=0;f<5;f++)
      for(int b=0;b<9;b++)
      {
         string row="";
         for(int col=0;col<9;col++)row+=(col==0?"":",")+(col==numeric[f]?bad[b]:fields[col]);
         Malformed("numeric_"+IntegerToString(numeric[f])+"_"+IntegerToString(b),"SEQ,7,USD\r\n"+row+"\r\nEND,7\r\n");
      }
   string badTime[8]={"2026.08.28 01:00:00","1787878800junk","0","-1","+1787878800","01787878800","99999999999999999","NaN"};
   for(int b=0;b<8;b++)
   {
      string row="";
      for(int col=0;col<9;col++)row+=(col==0?"":",")+(col==7?badTime[b]:fields[col]);
      Malformed("time_"+IntegerToString(b),"SEQ,7,USD\r\n"+row+"\r\nEND,7\r\n");
   }
   string row="103,REMOTE,1,0.02,4603.4,0,0,1787878800,0\r\n";
   Malformed("short_line_cross_boundary","SEQ,7,USD\r\n103,REMOTE,1,0.02\r\n4603.4,0,0,1787878800,0\r\nEND,7\r\n");
   Malformed("position_extra_field","SEQ,7,USD\r\n103,REMOTE,1,0.02,4603.4,0,0,1787878800,0,extra\r\nEND,7\r\n");
   Malformed("position_trailing_delimiter","SEQ,7,USD\r\n103,REMOTE,1,0.02,4603.4,0,0,1787878800,0,\r\nEND,7\r\n");
   Malformed("header_extra_field","SEQ,7,USD,extra\r\n"+row+"END,7\r\n");
   Malformed("header_short_line","SEQ\r\n7,USD\r\n"+row+"END,7\r\n");
   Malformed("seq_noncanonical","SEQ,07,USD\r\n"+row+"END,7\r\n");
   Malformed("seq_garbage","SEQ,7x,USD\r\n"+row+"END,7\r\n");
   Malformed("seq_zero","SEQ,0,USD\r\n"+row+"END,0\r\n");
   Malformed("end_noncanonical","SEQ,7,USD\r\n"+row+"END,07\r\n");
   Malformed("end_garbage","SEQ,7,USD\r\n"+row+"END,7x\r\n");
   Malformed("end_trailing_delimiter","SEQ,7,USD\r\n"+row+"END,7,\r\n");
   Malformed("trailing_after_end","SEQ,7,USD\r\n"+row+"END,7\r\nGARBAGE\r\n");
   Malformed("trailing_record_after_end","SEQ,7,USD\r\n"+row+"END,7\r\n"+row);
   Malformed("duplicate_ticket","SEQ,7,USD\r\n"+row+row+"END,7\r\n");
   Malformed("same_seq_torn_rewrite","SEQ,6,USD\r\n"+row+"END,7\r\n");
   Malformed("unframed_legacy",row);
   Frame(1,8);SlaveSync();Check("valid_frame_cleans_probe",!HCIdeaIsTombstoned(777));
   Frame(0,9);ArrayResize(g_openTryTicket,0);ArrayResize(g_openTryWhenMs,0);SlaveSync();
   Check("ack_allows_new_copy_without_global_lock",Local(101)>0 && Local(102)>0 && Local(103)==other && !TradingIsDisabled());
   Finished=true;Print("HC_SUMMARY|checks=",Checks,"|failed=",Failures);TesterStop();
}
void OnTimer(){if(MQLInfoInteger(MQL_TESTER) && !Finished)HCOriginalTimer();}
void OnDeinit(const int reason){if(MQLInfoInteger(MQL_TESTER)){HCOriginalDeinit(reason);FileDelete(GetSyncFilePath(),FILE_COMMON);FileDelete(SlaveStatusPath(),FILE_COMMON);if(!Finished)Print("HC_INCOMPLETE|copier");}}
