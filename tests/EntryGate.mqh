// Consumer contract: gate new requests only, never position/SL/TP management.
bool HCEntradaPermitida()
{
   if(GlobalVariableCheck("HCPropsController_TotalLocked") && GlobalVariableGet("HCPropsController_TotalLocked")==1.0) return false;
   if(GlobalVariableCheck("HCPropsController_DailyLocked") && GlobalVariableGet("HCPropsController_DailyLocked")==1.0) return false;
   if(GlobalVariableCheck("HCPropsControllerDisableTrading") && GlobalVariableGet("HCPropsControllerDisableTrading")==1.0) return false;
   if(!GlobalVariableCheck("HCPropsControllerHeartbeat")) return false;
   double age=(double)TimeLocal()-GlobalVariableGet("HCPropsControllerHeartbeat");
   return age>=0 && age<=5;
}
bool HCEsEntrada(const MqlTradeRequest &r)
{
   return r.action==TRADE_ACTION_PENDING || (r.action==TRADE_ACTION_DEAL && r.position==0 && r.position_by==0);
}
