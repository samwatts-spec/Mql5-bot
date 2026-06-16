//+------------------------------------------------------------------+
//|                                     QuantumGold_ARTS_v11.mq5      |
//|   XAUUSD all-weather trend system — REGIME-GATED shorts.          |
//|                                                                  |
//|   v10: partial-runner exit (bank 50%@1.5ATR, BE, ride 4ATR trail).|
//|   v11: SHORTS RE-ENABLED but REGIME-GATED. Validated on 16y gold  |
//|   daily incl. 2011-15 bear (cycle_test2.py): naive both-direction |
//|   LOSES (gold drifts up), but LONG + short-only-when-daily-SMA200- |
//|   FALLING BEATS long-only across the full cycle (Sharpe 0.41->0.46,|
//|   +34%->+42%; 2019-26 Sharpe 0.77->0.96 w/ smaller DD).           |
//|   => Long by default; short only in a confirmed bear.            |
//|   NOTE: regime-short validated on DAILY trend; intraday short is   |
//|   an extrapolation until intraday bear data exists.              |
//|   Hard stop every trade, vol-targeted compounding, NO martingale. |
//+------------------------------------------------------------------+
#property copyright "Quantum Gold research"
#property version   "11.00"
#property strict

#include <Trade/Trade.mqh>

enum ENUM_LOT_METHOD { LOT_RISK_PCT, LOT_FIXED, LOT_FIXED_PER_BALANCE };
enum ENUM_DIRECTION  { DIR_BUYS_ONLY, DIR_SELLS_ONLY, DIR_BUYS_AND_SELLS };
enum ENUM_ENTRY_MODE { ENTRY_PULLBACK, ENTRY_MOMENTUM, ENTRY_BREAKOUT };
enum ENUM_EXIT_MODE  { EXIT_TREND_TRAIL, EXIT_FIXED_SCALP, EXIT_PARTIAL_RUNNER };

//--- inputs -------------------------------------------------------------
input group "=== General Settings ==="
input bool             InpStartPaused   = false;           // Start EA paused (no new trades)
input ENUM_LOT_METHOD  InpLotMethod     = LOT_RISK_PCT;    // Lot calculation method
input double           InpRiskPct       = 1.0;             // Risk per trade (% of balance) [Risk% method]
input double           InpMaxRiskPct    = 2.0;             // Hard cap on risk %
input double           InpFixedLot      = 0.01;            // Fixed lot [Fixed / per-balance methods]
input double           InpFixedPerBal   = 500.0;           // Balance per FixedLot [FixedPerBalance method]
input ENUM_DIRECTION   InpDirection     = DIR_BUYS_AND_SELLS; // Long always; shorts are REGIME-GATED (see below)
input bool             InpShortRegimeOnly = true;           // Shorts only when regime-MA is FALLING (confirmed bear)
input ENUM_TIMEFRAMES  InpRegimeTF      = PERIOD_D1;        // Regime timeframe for the bear filter (daily = validated)
input int              InpRegimeMAperiod= 200;              // Regime MA period (200-day = validated)
input int              InpRegimeSlopeBars= 60;              // MA must be below its value N bars ago to allow shorts
input long             InpMagic         = 20260615;        // Magic number
input int              InpMaxSpread     = 100;             // Max spread (points), 0 = ignore
input int              InpMaxSlippage   = 100;             // Max slippage (points)
input string           InpTradeComment  = "QGoldDip";      // Trade comment

input group "=== Strategy / Signal ==="
input ENUM_ENTRY_MODE  InpEntryMode     = ENTRY_MOMENTUM;     // Entry: Pullback=dips, Momentum/Breakout=strength
input ENUM_EXIT_MODE   InpExitMode      = EXIT_PARTIAL_RUNNER;// Exit: PartialRunner=bank half+ride (best), TrendTrail, FixedScalp
input double           InpTP_ATR        = 2.5;             // [Scalp] Take profit = N * ATR
input double           InpSL_ATR        = 1.5;             // [Scalp/Partial] Initial stop = N * ATR
input double           InpPartialTP_ATR = 1.5;             // [Partial] Bank first half at N * ATR (then BE + ride)
input double           InpPartialPct    = 50.0;            // [Partial] % of position banked at first target
input int              InpBreakoutBars  = 6;               // [Breakout] N-bar high to break
input ENUM_TIMEFRAMES  InpSignalTF      = PERIOD_H1;       // Entry timeframe (H1 for momentum-scalp, H4 for trend)
input ENUM_TIMEFRAMES  InpTrendTF       = PERIOD_H4;       // Higher-TF trend filter (set = SignalTF for single-TF)
input int              InpSMAfast       = 50;              // Fast SMA (trend dir + trail exit)
input int              InpSMAslow       = 200;             // Slow SMA (trend filter)
input int              InpSMApull       = 20;              // Pullback SMA
input int              InpRSIperiod     = 14;              // RSI period
input double           InpRSIpullback   = 45.0;            // Long if RSI<this (short if RSI>100-this)
input int              InpATRperiod     = 14;              // ATR period
input double           InpStopATR       = 2.0;             // [Trail] Initial stop = N * ATR
input double           InpTrailATR      = 4.0;             // Chandelier/runner trail = N * ATR (4.0 = exit_lab best)
input bool             InpUseADX        = false;           // ADX filter (tested: hurt — leave OFF)
input int              InpADXperiod     = 14;              // ADX period
input double           InpADXmin        = 20.0;            // Min ADX to allow entries
input bool             InpUseRegime     = false;           // Efficiency-Ratio regime filter (OFF: didn't help on bull data)
input int              InpERperiod      = 10;              // Efficiency Ratio lookback (signal-TF bars)
input double           InpERmin         = 0.30;            // Min trendiness (ER) to allow entries when regime ON

input group "=== Trading Days ==="
input bool             InpMon           = true;            // Trade Monday
input bool             InpTue           = true;            // Trade Tuesday
input bool             InpWed           = true;            // Trade Wednesday
input bool             InpThu           = true;            // Trade Thursday
input bool             InpFri           = true;            // Trade Friday

input group "=== Trading Hours (server time) ==="
input bool             InpUseHourFilter = false;           // Session filter OFF (it hurt live: PF 1.13->1.03)
input int              InpStartHour     = 10;              // Start hour incl. (~London open, server GMT+2)
input int              InpEndHour       = 22;              // End hour excl. (~NY close, server GMT+2)

input group "=== Safety ==="
input int              InpMaxPositions  = 1;               // Max concurrent positions (this symbol/magic)
input double           InpMaxEquityDD   = 0.0;             // Halt new trades if equity DD% exceeds (0 = off)

//--- globals ------------------------------------------------------------
CTrade   trade;
int      hMAfast, hMAslow, hMApull, hRSI, hATR, hADX;
int      hTrendFast, hTrendSlow;   // SMAs on the higher-TF trend filter
int      hRegimeMA;                // regime MA (e.g. daily SMA200) for the bear gate
datetime g_lastBar = 0;
bool     g_pending = false;
double   g_extreme = 0.0;     // highest high (long) / lowest low (short) since entry
double   g_peakEq  = 0.0;     // for equity-DD safety halt
bool     g_partialDone = false; // partial-runner: first half already banked?
double   g_entryPx = 0.0;       // entry price of the live position

//+------------------------------------------------------------------+
int OnInit()
{
   hMAfast = iMA (_Symbol, InpSignalTF, InpSMAfast, 0, MODE_SMA, PRICE_CLOSE);
   hMAslow = iMA (_Symbol, InpSignalTF, InpSMAslow, 0, MODE_SMA, PRICE_CLOSE);
   hMApull = iMA (_Symbol, InpSignalTF, InpSMApull, 0, MODE_SMA, PRICE_CLOSE);
   hRSI    = iRSI(_Symbol, InpSignalTF, InpRSIperiod, PRICE_CLOSE);
   hATR    = iATR(_Symbol, InpSignalTF, InpATRperiod);
   hADX    = iADX(_Symbol, InpSignalTF, InpADXperiod);
   hTrendFast = iMA(_Symbol, InpTrendTF, InpSMAfast, 0, MODE_SMA, PRICE_CLOSE);
   hTrendSlow = iMA(_Symbol, InpTrendTF, InpSMAslow, 0, MODE_SMA, PRICE_CLOSE);
   hRegimeMA  = iMA(_Symbol, InpRegimeTF, InpRegimeMAperiod, 0, MODE_SMA, PRICE_CLOSE);
   if(hMAfast==INVALID_HANDLE||hMAslow==INVALID_HANDLE||hMApull==INVALID_HANDLE||
      hRSI==INVALID_HANDLE||hATR==INVALID_HANDLE||hADX==INVALID_HANDLE||
      hTrendFast==INVALID_HANDLE||hTrendSlow==INVALID_HANDLE||hRegimeMA==INVALID_HANDLE)
   { Print("Indicator handle creation failed"); return(INIT_FAILED); }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(InpMaxSlippage);
   g_peakEq = AccountInfoDouble(ACCOUNT_EQUITY);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hMAfast); IndicatorRelease(hMAslow); IndicatorRelease(hMApull);
   IndicatorRelease(hRSI);    IndicatorRelease(hATR);    IndicatorRelease(hADX);
   IndicatorRelease(hTrendFast); IndicatorRelease(hTrendSlow); IndicatorRelease(hRegimeMA);
}

//+------------------------------------------------------------------+
//| helpers                                                          |
//+------------------------------------------------------------------+
int CountPositions()
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(PositionGetTicket(i)==0) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic) n++;
   }
   return(n);
}

double Buf(int handle,int shift)
{ double v[]; if(CopyBuffer(handle,0,shift,1,v)<1) return(EMPTY_VALUE); return(v[0]); }

bool SpreadOK()
{ if(InpMaxSpread<=0) return(true); return(SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)<=InpMaxSpread); }

// Kaufman Efficiency Ratio on the signal TF: trendiness in [0,1]
double EfficiencyRatio(int N)
{
   double change = MathAbs(iClose(_Symbol,InpSignalTF,1) - iClose(_Symbol,InpSignalTF,1+N));
   double vol=0.0;
   for(int i=1;i<=N;i++) vol += MathAbs(iClose(_Symbol,InpSignalTF,i)-iClose(_Symbol,InpSignalTF,i+1));
   if(vol<=0.0) return(0.0);
   return(change/vol);
}

bool MarketOpen()
{
   MqlDateTime mt; TimeToStruct(TimeCurrent(),mt);
   int secs=mt.hour*3600+mt.min*60+mt.sec; datetime from,to;
   for(int i=0;SymbolInfoSessionTrade(_Symbol,(ENUM_DAY_OF_WEEK)mt.day_of_week,i,from,to);i++)
      if(secs>=(int)from && secs<=(int)to) return(true);
   return(false);
}

bool DayOK()
{
   MqlDateTime mt; TimeToStruct(TimeCurrent(),mt);
   switch(mt.day_of_week){
      case 1: return InpMon; case 2: return InpTue; case 3: return InpWed;
      case 4: return InpThu; case 5: return InpFri; default: return false; }
}

bool HourOK()
{
   if(!InpUseHourFilter) return(true);
   MqlDateTime mt; TimeToStruct(TimeCurrent(),mt); int h=mt.hour;
   if(InpStartHour<=InpEndHour) return(h>=InpStartHour && h<InpEndHour);
   return(h>=InpStartHour || h<InpEndHour); // wrap past midnight
}

double NormLots(double lots)
{
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double vmin=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   lots=MathFloor(lots/step)*step;
   return(MathMax(vmin,MathMin(vmax,lots)));
}

double CalcLots(double stopDistPrice)
{
   if(InpLotMethod==LOT_FIXED) return(NormLots(InpFixedLot));
   if(InpLotMethod==LOT_FIXED_PER_BALANCE)
   {
      if(InpFixedPerBal<=0) return(0.0);
      double lots=(AccountInfoDouble(ACCOUNT_BALANCE)/InpFixedPerBal)*InpFixedLot;
      return(NormLots(lots));
   }
   // LOT_RISK_PCT
   double riskMoney=AccountInfoDouble(ACCOUNT_BALANCE)*MathMin(InpRiskPct,InpMaxRiskPct)/100.0;
   double tickVal=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0||tickVal<=0||stopDistPrice<=0) return(0.0);
   double moneyPerLot=(stopDistPrice/tickSize)*tickVal;
   return(NormLots(riskMoney/moneyPerLot));
}

bool EquityHalt()
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   g_peakEq=MathMax(g_peakEq,eq);
   if(InpMaxEquityDD<=0) return(false);
   return((g_peakEq-eq)/g_peakEq*100.0 >= InpMaxEquityDD);
}

// Per-tick management for TrendTrail and PartialRunner exit modes.
void ManagePosTick(bool newBar, double atr)
{
   if(!PositionSelect(_Symbol)) return;
   long   type  =PositionGetInteger(POSITION_TYPE);
   double entry =PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL =PositionGetDouble(POSITION_SL);
   double vol   =PositionGetDouble(POSITION_VOLUME);
   ulong  ticket=(ulong)PositionGetInteger(POSITION_TICKET);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double maF=Buf(hMAfast,1);

   if(type==POSITION_TYPE_BUY)
   {
      g_extreme=MathMax(g_extreme,bid);
      if(InpExitMode==EXIT_PARTIAL_RUNNER)
      {
         if(!g_partialDone && bid>=entry+InpPartialTP_ATR*atr)
         {
            double cv=NormLots(vol*InpPartialPct/100.0);
            if(cv>0 && cv<vol) trade.PositionClosePartial(ticket,cv);
            g_partialDone=true;
            trade.PositionModify(ticket,NormalizeDouble(entry,_Digits),0.0); // stop -> breakeven
         }
         if(g_partialDone)
         {
            double trail=g_extreme-InpTrailATR*atr;
            if(trail>curSL && trail<bid) trade.PositionModify(ticket,NormalizeDouble(trail,_Digits),0.0);
         }
      }
      else // EXIT_TREND_TRAIL
      {
         double trail=g_extreme-InpTrailATR*atr;
         if(trail>curSL && trail<bid) trade.PositionModify(ticket,NormalizeDouble(trail,_Digits),0.0);
         if(newBar && iClose(_Symbol,InpSignalTF,1)<maF) trade.PositionClose(ticket);
      }
   }
   else // SELL
   {
      g_extreme=(g_extreme==0.0)?ask:MathMin(g_extreme,ask);
      if(InpExitMode==EXIT_PARTIAL_RUNNER)
      {
         if(!g_partialDone && ask<=entry-InpPartialTP_ATR*atr)
         {
            double cv=NormLots(vol*InpPartialPct/100.0);
            if(cv>0 && cv<vol) trade.PositionClosePartial(ticket,cv);
            g_partialDone=true;
            trade.PositionModify(ticket,NormalizeDouble(entry,_Digits),0.0);
         }
         if(g_partialDone)
         {
            double trail=g_extreme+InpTrailATR*atr;
            if((curSL==0.0||trail<curSL) && trail>ask) trade.PositionModify(ticket,NormalizeDouble(trail,_Digits),0.0);
         }
      }
      else
      {
         double trail=g_extreme+InpTrailATR*atr;
         if((curSL==0.0||trail<curSL) && trail>ask) trade.PositionModify(ticket,NormalizeDouble(trail,_Digits),0.0);
         if(newBar && iClose(_Symbol,InpSignalTF,1)>maF) trade.PositionClose(ticket);
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   double atrNow=Buf(hATR,1);

   // ---- manage any open position EVERY tick (trail/partial); scalp = broker-managed ----
   datetime t=iTime(_Symbol,InpSignalTF,0);
   bool newBar=(t!=g_lastBar);
   if(newBar) g_lastBar=t;

   if(CountPositions()>0)
   {
      if(InpExitMode!=EXIT_FIXED_SCALP && atrNow>0) ManagePosTick(newBar, atrNow);
      return; // one position at a time — no new entries while in a trade
   }

   // ---- entries: evaluate once per closed signal bar ----
   if(newBar) g_pending=true;
   if(!g_pending) return;
   if(!MarketOpen()) return;

   double cl1=iClose(_Symbol,InpSignalTF,1);
   double cl2=iClose(_Symbol,InpSignalTF,2);
   double cl3=iClose(_Symbol,InpSignalTF,3);
   double hi1=iHigh (_Symbol,InpSignalTF,1);
   double lo1=iLow  (_Symbol,InpSignalTF,1);
   double maF=Buf(hMAfast,1), maS=Buf(hMAslow,1), maP=Buf(hMApull,1);
   double rsi=Buf(hRSI,1), atr=Buf(hATR,1);
   if(atr==EMPTY_VALUE||maS==EMPTY_VALUE||maF==EMPTY_VALUE||atr<=0) return;
   double brkHi=0.0, brkLo=0.0;
   if(InpEntryMode==ENTRY_BREAKOUT)
   {
      int ih=iHighest(_Symbol,InpSignalTF,MODE_HIGH,InpBreakoutBars,2);
      int il=iLowest (_Symbol,InpSignalTF,MODE_LOW, InpBreakoutBars,2);
      if(ih>=0) brkHi=iHigh(_Symbol,InpSignalTF,ih);
      if(il>=0) brkLo=iLow (_Symbol,InpSignalTF,il);
   }

   //---------------- entry gating ----------------
   g_pending=false; // decision made this bar unless an order is retried below
   if(InpStartPaused) return;
   if(EquityHalt()) return;
   if(!DayOK() || !HourOK()) return;
   if(CountPositions()>=InpMaxPositions) return;
   if(InpUseADX)
   {
      double adx=Buf(hADX,1);
      if(adx==EMPTY_VALUE || adx<InpADXmin) return; // not trending enough — skip the chop
   }
   if(InpUseRegime)
   {
      if(EfficiencyRatio(InpERperiod) < InpERmin) return; // not a trending regime
   }
   if(!SpreadOK()){ g_pending=true; return; } // valid window, wait for spread

   // trend filter on the higher timeframe (InpTrendTF)
   double tSlow=Buf(hTrendSlow,1), tFast=Buf(hTrendFast,1);
   if(tSlow==EMPTY_VALUE||tFast==EMPTY_VALUE){ g_pending=true; return; }
   bool upTrend = (cl1>tSlow)&&(tFast>tSlow);
   bool dnTrend = (cl1<tSlow)&&(tFast<tSlow);

   // entry trigger depends on the selected ENTRY MODE
   bool longTrig=false, shortTrig=false;
   if(InpEntryMode==ENTRY_PULLBACK)
   {
      longTrig  = ((rsi<InpRSIpullback)||(cl1<maP)) && (cl1>cl2);
      shortTrig = ((rsi>100-InpRSIpullback)||(cl1>maP)) && (cl1<cl2);
   }
   else if(InpEntryMode==ENTRY_MOMENTUM)
   {
      longTrig  = (cl1>cl2)&&(cl2>cl3);   // two consecutive up-closes (buy strength)
      shortTrig = (cl1<cl2)&&(cl2<cl3);
   }
   else // ENTRY_BREAKOUT
   {
      longTrig  = (brkHi>0 && cl1>brkHi);
      shortTrig = (brkLo>0 && cl1<brkLo);
   }
   bool longSetup  = upTrend && longTrig;
   bool shortSetup = dnTrend && shortTrig;

   bool allowLong  = (InpDirection==DIR_BUYS_ONLY||InpDirection==DIR_BUYS_AND_SELLS);
   bool allowShort = (InpDirection==DIR_SELLS_ONLY||InpDirection==DIR_BUYS_AND_SELLS);

   // REGIME GATE: shorts only when the regime MA (daily SMA200) is FALLING (confirmed bear).
   // Validated on 16y cycle: naive shorts lose, regime-gated shorts add Sharpe.
   if(allowShort && InpShortRegimeOnly)
   {
      double rmaNow = Buf(hRegimeMA,1);
      double rmaPast= Buf(hRegimeMA,1+InpRegimeSlopeBars);
      if(rmaNow==EMPTY_VALUE || rmaPast==EMPTY_VALUE || rmaNow>=rmaPast)
         allowShort=false; // not a confirmed downtrend → no shorts
   }

   // initial stop: scalp & partial use SL_ATR (tight); trend-trail uses StopATR
   double slDist = (InpExitMode==EXIT_TREND_TRAIL) ? InpStopATR*atr : InpSL_ATR*atr;

   if(allowLong && longSetup)
   {
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double stop0=ask-slDist;
      double tp   =(InpExitMode==EXIT_FIXED_SCALP) ? ask+InpTP_ATR*atr : 0.0; // partial/trail manage exit
      double lots =CalcLots(ask-stop0);
      if(lots>0 && trade.Buy(lots,_Symbol,ask,NormalizeDouble(stop0,_Digits),NormalizeDouble(tp,_Digits),InpTradeComment))
      { g_extreme=hi1; g_partialDone=false; g_entryPx=ask; }
   }
   else if(allowShort && shortSetup)
   {
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double stop0=bid+slDist;
      double tp   =(InpExitMode==EXIT_FIXED_SCALP) ? bid-InpTP_ATR*atr : 0.0;
      double lots =CalcLots(stop0-bid);
      if(lots>0 && trade.Sell(lots,_Symbol,bid,NormalizeDouble(stop0,_Digits),NormalizeDouble(tp,_Digits),InpTradeComment))
      { g_extreme=lo1; g_partialDone=false; g_entryPx=bid; }
   }
}
//+------------------------------------------------------------------+
