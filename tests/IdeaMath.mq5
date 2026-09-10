#property strict
// Arithmetic/key tests against the actual source, without running its lifecycle.
// Tester only. This wrapper never submits trades or creates/deletes persistent state.
#define OnInit HCOriginalInit
#define OnTimer HCOriginalTimer
#define OnDeinit HCOriginalDeinit
#define OnTradeTransaction HCOriginalTradeTransaction
#include "../HCPropsController.mq5"
#undef OnInit
#undef OnTimer
#undef OnDeinit
#undef OnTradeTransaction

int Checks = 0, Failures = 0;
void Check(string name, bool ok)
  {
   Checks++;
   if(!ok) Failures++;
   Print("HC_TEST|", name, "|", ok ? "PASS" : "FAIL");
  }

int OnInit()
  {
   if(!MQLInfoInteger(MQL_TESTER))
      return INIT_FAILED;
   bool valid = MathIsValidNumber(MaxLossPercentPerIdea) && MaxLossPercentPerIdea >= 0 &&
                MathIsValidNumber(MaxProfitPercentPerIdea) && MaxProfitPercentPerIdea >= 0;
   Check("idea_input_validation", HCIdeaInputsValid() == valid);
   AccountDepositsAndWithdrawals = 10000.0; // synthetic arithmetic base, not an account policy
   if(valid && HCIdeaBaseValid())
     {
      Check("idea_zero_pnl", HCIdeaBreach(0.0) == 0);
      if(MaxLossPercentPerIdea > 0.0)
        {
         double money = AccountDepositsAndWithdrawals * MaxLossPercentPerIdea / 100.0;
         Check("idea_loss_inside", HCIdeaBreach(-money + 0.01) == 0);
         Check("idea_loss_equal", HCIdeaBreach(-money) == 1);
         Check("idea_loss_outside", HCIdeaBreach(-money - 0.01) == 1);
        }
      if(MaxProfitPercentPerIdea > 0.0)
        {
         double money = AccountDepositsAndWithdrawals * MaxProfitPercentPerIdea / 100.0;
         Check("idea_profit_inside", HCIdeaBreach(money - 0.01) == 0);
         Check("idea_profit_equal", HCIdeaBreach(money) == 2);
         Check("idea_profit_outside", HCIdeaBreach(money + 0.01) == 2);
        }
      if(!HCIdeaLimitsEnabled())
         Check("idea_zero_defaults_no_trigger", HCIdeaBreach(-100000.0) == 0 && HCIdeaBreach(100000.0) == 0);
     }
   AccountDepositsAndWithdrawals = 0.0;
   Check("idea_zero_base", !HCIdeaBaseValid() && HCIdeaBreach(-1000.0) == 0);
   AccountDepositsAndWithdrawals = -1.0;
   Check("idea_negative_base", !HCIdeaBaseValid());
   ulong id = ((ulong)1 << 53);
   Check("idea_id_no_double_rounding", HCIdeaHex(id) != HCIdeaHex(id + 1));
   Check("idea_full_uint64_roundtrip", HCIdeaFromHex(HCIdeaHex(ULONG_MAX)) == ULONG_MAX);
   Check("idea_latch_key_length", StringLen(HCIdeaLatchKey(ULONG_MAX, POSITION_TYPE_BUY)) == 40);
   Check("idea_direction_distinct", HCIdeaLatchKey(id, POSITION_TYPE_BUY) != HCIdeaLatchKey(id, POSITION_TYPE_SELL));
   Check("idea_tombstone_key_length", StringLen(HCIdeaTombKey(ULONG_MAX)) == 55);
   Print("HC_SUMMARY|checks=", Checks, "|failed=", Failures);
   return INIT_SUCCEEDED;
  }

void OnTick()
  {
   if(MQLInfoInteger(MQL_TESTER))
      TesterStop();
  }
