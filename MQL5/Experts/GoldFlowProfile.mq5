//+------------------------------------------------------------------+
//|                                            GoldFlowProfile.mq5    |
//|                                                                  |
//|   XAUUSD (gold) scalper driven by Volume Profile + order-flow    |
//|   delta.                                                         |
//|                                                                  |
//|   Honest data note                                              |
//|   ----------------                                              |
//|   Retail MT5 gold is a CFD: it exposes TICK volume (number of    |
//|   price changes), not real exchange contract volume, and usually |
//|   no usable order book. So this EA builds the *proxy* tools that  |
//|   desk traders use on MT5:                                       |
//|     * Volume Profile  - volume binned by price over a lookback,  |
//|       giving the Point of Control (POC) and Value Area (VAH/VAL).|
//|     * Order-flow delta - estimated buy vs sell pressure per bar  |
//|       from where the bar closes inside its range x its volume.   |
//|   If your broker provides real volume it is used automatically.  |
//|                                                                  |
//|   Strategy (value-area rejection + delta confirmation)          |
//|   ----------------------------------------------------          |
//|   * LONG : price pokes BELOW the Value Area Low then closes back |
//|     inside the value area, and bar delta is positive (buyers     |
//|     absorbing) - a failed auction lower. Target the POC.         |
//|   * SHORT: price pokes ABOVE the Value Area High then closes back |
//|     inside, and bar delta is negative.                           |
//|   * Optional EMA trend filter, ATR stops, % risk sizing, daily   |
//|     circuit breakers, session window, break-even & trailing.     |
//|                                                                  |
//|   Manages only its own orders (by magic number). Server time.    |
//+------------------------------------------------------------------+
#property copyright "Sam Watts"
#property version   "1.00"
#property strict
#property description "Volume Profile + order-flow delta scalper for XAUUSD (gold)."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Position sizing mode
enum ENUM_SIZING_MODE
  {
   SIZE_FIXED_LOT,      // Fixed lot size
   SIZE_RISK_PERCENT    // Risk a % of equity per trade
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Volume Profile ==="
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_M5;  // Working timeframe
input int            InpProfileBars        = 200;   // Lookback bars for the profile
input int            InpProfileBins        = 50;    // Number of price bins (resolution)
input double         InpValueAreaPct       = 70.0;  // Value area (% of volume around POC)
input bool           InpUseRealVolume      = false; // Use real volume if the broker provides it
input bool           InpShowLevels         = true;  // Draw POC / VAH / VAL on the chart

input group "=== Order-flow delta ==="
input double         InpMinDeltaPct        = 15.0;  // Min bar imbalance to confirm (% of bar volume)
input bool           InpUseCumDelta        = true;  // Require cumulative delta to agree
input int            InpCumDeltaBars       = 10;    // Bars for the cumulative delta window

input group "=== Trend filter (optional) ==="
input bool           InpUseTrendFilter     = false; // Only trade with the EMA trend
input int            InpTrendEmaPeriod      = 100;   // Trend EMA period

input group "=== Volatility ==="
input int            InpAtrPeriod          = 14;    // ATR period
input int            InpMinAtrPoints       = 0;     // Skip if ATR below this (points, 0 = ignore)
input double         InpMaxSpreadAtrPct    = 25.0;  // Max spread as % of ATR (0 = ignore)

input group "=== Position sizing ==="
input ENUM_SIZING_MODE InpSizingMode       = SIZE_RISK_PERCENT; // How to size trades
input double         InpFixedLots          = 0.01;  // Lot size (fixed-lot mode)
input double         InpRiskPercent        = 1.0;   // Risk per trade (% of equity)

input group "=== Stops / exits ==="
input double         InpAtrSLMult          = 1.5;   // Stop loss = ATR x this
input double         InpAtrTPMult          = 2.0;   // Take profit = ATR x this (fallback)
input bool           InpTargetPOC          = true;  // Take profit at the POC when it is beyond entry
input double         InpMinRewardRisk      = 0.0;   // Skip setups below this reward:risk ratio (0 = off)
input bool           InpUseBreakEven       = false; // Move SL to break-even
input double         InpBreakEvenAtr       = 1.0;   // Profit (x ATR) to trigger break-even
input double         InpBreakEvenLockAtr   = 0.1;   // Profit locked in at break-even (x ATR)
input bool           InpUseTrailing        = false; // Use trailing stop (off: mean-reversion lets TP work)
input double         InpTrailStartAtr      = 1.2;   // Profit (x ATR) before trailing starts
input double         InpTrailStepAtr       = 1.0;   // Trailing distance (x ATR)

input group "=== Trade control / risk caps ==="
input int            InpMaxPositions       = 1;     // Max concurrent positions (this EA)
input int            InpMaxTradesPerDay    = 8;     // Max new trades per day (0 = no limit)
input double         InpDailyLossLimit     = 5.0;   // Stop for the day after losing this % (0 = off)
input double         InpDailyProfitTarget  = 0.0;   // Stop for the day after gaining this % (0 = off)
input int            InpMinSecondsBetween  = 60;    // Min seconds between entries

input group "=== Session window (server time) ==="
input bool           InpUseSession         = true;  // Restrict trading to a window
input int            InpSessionStartHour   = 7;     // Session start hour (0-23)
input int            InpSessionEndHour     = 20;    // Session end hour (0-23)

input group "=== General ==="
input long           InpMagicNumber        = 20240602; // Magic number
input string         InpComment            = "GoldFlowProfile"; // Order comment

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade        trade;
CPositionInfo posInfo;

int      g_atrHandle     = INVALID_HANDLE;
int      g_emaHandle     = INVALID_HANDLE;

datetime g_lastBarTime   = 0;
datetime g_currentDay    = 0;
datetime g_lastTradeTime = 0;
int      g_tradesToday   = 0;
double   g_dayStartEquity = 0.0;
bool     g_dayBlocked    = false;

//--- Last computed profile (for the dashboard / targets)
double   g_poc = 0.0, g_vah = 0.0, g_val = 0.0;
double   g_lastDelta = 0.0, g_cumDelta = 0.0;

const string OBJ_POC = "GFP_POC";
const string OBJ_VAH = "GFP_VAH";
const string OBJ_VAL = "GFP_VAL";

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(20);

   if(InpProfileBars < 20 || InpProfileBins < 5)
     {
      Print("Profile needs at least 20 bars and 5 bins.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpValueAreaPct <= 0.0 || InpValueAreaPct >= 100.0)
     {
      Print("Value area % must be between 0 and 100.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpAtrPeriod <= 0)
     {
      Print("ATR period must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpSizingMode == SIZE_FIXED_LOT && InpFixedLots <= 0.0)
     {
      Print("Fixed lot size must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpSizingMode == SIZE_RISK_PERCENT && InpRiskPercent <= 0.0)
     {
      Print("Risk percent must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_atrHandle = iATR(_Symbol, InpTimeframe, InpAtrPeriod);
   if(InpUseTrendFilter)
      g_emaHandle = iMA(_Symbol, InpTimeframe, InpTrendEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(g_atrHandle == INVALID_HANDLE ||
      (InpUseTrendFilter && g_emaHandle == INVALID_HANDLE))
     {
      Print("Failed to create indicator handles.");
      return(INIT_FAILED);
     }

   ResetDailyCounters(DayStart(TimeCurrent()));

   PrintFormat("GoldFlowProfile initialised on %s (%s) | magic %I64d",
               _Symbol, EnumToString(InpTimeframe), InpMagicNumber);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_emaHandle != INVALID_HANDLE) IndicatorRelease(g_emaHandle);
   ObjectDelete(0, OBJ_POC);
   ObjectDelete(0, OBJ_VAH);
   ObjectDelete(0, OBJ_VAL);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now   = TimeCurrent();
   datetime today = DayStart(now);
   if(today != g_currentDay)
      ResetDailyCounters(today);

   ManageOpenPositions();
   CheckDailyLimits();

   //--- Work once per closed bar.
   datetime barTime = (datetime)SeriesInfoInteger(_Symbol, InpTimeframe, SERIES_LASTBAR_DATE);
   if(barTime == g_lastBarTime)
     {
      UpdateDashboard();
      return;
     }
   g_lastBarTime = barTime;

   EvaluateEntry();
   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Reset per-day counters and snapshot starting equity              |
//+------------------------------------------------------------------+
void ResetDailyCounters(const datetime today)
  {
   g_currentDay     = today;
   g_tradesToday    = 0;
   g_dayBlocked     = false;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
  }

//+------------------------------------------------------------------+
//| Daily loss / profit circuit breaker                              |
//+------------------------------------------------------------------+
void CheckDailyLimits()
  {
   if(g_dayBlocked || g_dayStartEquity <= 0.0)
      return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double pct    = (equity - g_dayStartEquity) / g_dayStartEquity * 100.0;

   if(InpDailyLossLimit > 0.0 && pct <= -InpDailyLossLimit)
     {
      g_dayBlocked = true;
      PrintFormat("Daily loss limit hit (%.2f%%). Trading halted for the day.", pct);
     }
   else if(InpDailyProfitTarget > 0.0 && pct >= InpDailyProfitTarget)
     {
      g_dayBlocked = true;
      PrintFormat("Daily profit target hit (%.2f%%). Trading halted for the day.", pct);
     }
  }

//+------------------------------------------------------------------+
//| Volume of a bar (real volume when available, else tick volume)   |
//+------------------------------------------------------------------+
double VolumeOf(const MqlRates &r)
  {
   if(InpUseRealVolume && r.real_volume > 0)
      return((double)r.real_volume);
   return((double)r.tick_volume);
  }

//+------------------------------------------------------------------+
//| Estimated order-flow delta of a single bar (buy vol - sell vol)  |
//+------------------------------------------------------------------+
double BarDelta(const MqlRates &r)
  {
   double v     = VolumeOf(r);
   double range = r.high - r.low;
   if(range <= 0.0)
      return(r.close >= r.open ? v : -v);
   double buy  = v * (r.close - r.low) / range;
   double sell = v * (r.high - r.close) / range;
   return(buy - sell);
  }

//+------------------------------------------------------------------+
//| Build the volume profile -> POC, Value Area High / Low           |
//+------------------------------------------------------------------+
bool BuildVolumeProfile(const MqlRates &rates[], const int count,
                        double &poc, double &vah, double &val)
  {
   double hi = -DBL_MAX, lo = DBL_MAX;
   for(int i = 0; i < count; i++)
     {
      if(rates[i].high > hi) hi = rates[i].high;
      if(rates[i].low  < lo) lo = rates[i].low;
     }
   if(hi <= lo)
      return(false);

   int    bins    = InpProfileBins;
   double binSize = (hi - lo) / bins;
   if(binSize <= 0.0)
      return(false);

   double vol[];
   ArrayResize(vol, bins);
   ArrayInitialize(vol, 0.0);

   double totalVol = 0.0;
   for(int i = 0; i < count; i++)
     {
      double v = VolumeOf(rates[i]);
      if(v <= 0.0)
         continue;
      //--- Spread the bar's volume across every bin it covers.
      int b1 = (int)((rates[i].low  - lo) / binSize);
      int b2 = (int)((rates[i].high - lo) / binSize);
      if(b1 < 0)      b1 = 0;
      if(b2 > bins-1) b2 = bins - 1;
      if(b2 < b1)     b2 = b1;
      double share = v / (b2 - b1 + 1);
      for(int b = b1; b <= b2; b++)
         vol[b] += share;
      totalVol += v;
     }
   if(totalVol <= 0.0)
      return(false);

   //--- Point of Control = busiest price bin.
   int    pocBin = 0;
   double maxv   = -1.0;
   for(int b = 0; b < bins; b++)
      if(vol[b] > maxv) { maxv = vol[b]; pocBin = b; }

   //--- Grow the value area out from the POC until it holds the target %.
   double target = totalVol * InpValueAreaPct / 100.0;
   double acc    = vol[pocBin];
   int    loBin  = pocBin, hiBin = pocBin;
   while(acc < target && (loBin > 0 || hiBin < bins - 1))
     {
      double below = (loBin > 0)        ? vol[loBin - 1] : -1.0;
      double above = (hiBin < bins - 1) ? vol[hiBin + 1] : -1.0;
      if(above >= below) { hiBin++; acc += vol[hiBin]; }
      else               { loBin--; acc += vol[loBin]; }
     }

   poc = lo + (pocBin + 0.5) * binSize;
   val = lo + loBin * binSize;
   vah = lo + (hiBin + 1) * binSize;
   return(true);
  }

//+------------------------------------------------------------------+
//| Evaluate the entry signal on the latest closed bar               |
//+------------------------------------------------------------------+
void EvaluateEntry()
  {
   if(g_dayBlocked)
      return;
   if(InpUseSession && !InSession())
      return;
   if(InpMaxTradesPerDay > 0 && g_tradesToday >= InpMaxTradesPerDay)
      return;
   if(CountOpenPositions() >= InpMaxPositions)
      return;
   if(g_lastTradeTime > 0 && (TimeCurrent() - g_lastTradeTime) < InpMinSecondsBetween)
      return;

   //--- Bars for the profile (index 0 = last closed bar, shift 1).
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, InpTimeframe, 1, InpProfileBars, rates);
   if(copied < 20)
      return;

   double poc, vah, val;
   if(!BuildVolumeProfile(rates, copied, poc, vah, val))
      return;
   g_poc = poc; g_vah = vah; g_val = val;
   if(InpShowLevels)
      DrawLevels();

   //--- ATR / spread / volatility gates.
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_atrHandle, 0, 1, 1, atr) < 1)
      return;
   double atrNow = atr[0];
   if(atrNow <= 0.0)
      return;
   if(InpMinAtrPoints > 0 && (atrNow / _Point) < InpMinAtrPoints)
      return;
   if(!SpreadOK(atrNow))
      return;

   //--- Order-flow delta on the signal bar (+ optional cumulative).
   double delta = BarDelta(rates[0]);
   g_lastDelta  = delta;

   double vol         = VolumeOf(rates[0]);
   double minDelta    = vol * InpMinDeltaPct / 100.0;
   bool   strongBuy   = (delta >=  minDelta);
   bool   strongSell  = (delta <= -minDelta);

   double cum = 0.0;
   int cumN = (int)MathMin(InpCumDeltaBars, copied);
   for(int i = 0; i < cumN; i++)
      cum += BarDelta(rates[i]);
   g_cumDelta = cum;
   bool cumBuyOK  = (!InpUseCumDelta || cum > 0.0);
   bool cumSellOK = (!InpUseCumDelta || cum < 0.0);

   //--- Optional EMA trend filter.
   bool trendBuyOK = true, trendSellOK = true;
   if(InpUseTrendFilter)
     {
      double ema[];
      ArraySetAsSeries(ema, true);
      if(CopyBuffer(g_emaHandle, 0, 1, 1, ema) < 1)
         return;
      trendBuyOK  = (rates[0].close > ema[0]);
      trendSellOK = (rates[0].close < ema[0]);
     }

   //--- Value-area rejection: poked outside the value area, closed back in.
   bool buySignal  = (rates[0].low  < val) && (rates[0].close > val) &&
                     strongBuy  && cumBuyOK  && trendBuyOK;
   bool sellSignal = (rates[0].high > vah) && (rates[0].close < vah) &&
                     strongSell && cumSellOK && trendSellOK;

   if(buySignal)
      OpenTrade(ORDER_TYPE_BUY, atrNow);
   else if(sellSignal)
      OpenTrade(ORDER_TYPE_SELL, atrNow);
  }

//+------------------------------------------------------------------+
//| Open a market order with ATR/POC based SL & TP                   |
//+------------------------------------------------------------------+
void OpenTrade(const ENUM_ORDER_TYPE type, const double atrValue)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double slDist = InpAtrSLMult * atrValue;
   double tpDist = InpAtrTPMult * atrValue;

   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(slDist < minStop) slDist = minStop;

   double price = (type == ORDER_TYPE_BUY) ? ask : bid;
   double sl, tp;

   if(type == ORDER_TYPE_BUY)
     {
      sl = NormalizeDouble(price - slDist, _Digits);
      //--- Prefer the POC as a target when it sits above entry.
      tp = (InpTargetPOC && g_poc > price + minStop)
           ? NormalizeDouble(g_poc, _Digits)
           : NormalizeDouble(price + tpDist, _Digits);
     }
   else
     {
      sl = NormalizeDouble(price + slDist, _Digits);
      tp = (InpTargetPOC && g_poc < price - minStop)
           ? NormalizeDouble(g_poc, _Digits)
           : NormalizeDouble(price - tpDist, _Digits);
     }

   //--- Only take setups with an acceptable reward:risk. With a high win
   //--- rate this is what keeps the average win >= the average loss.
   double risk   = MathAbs(price - sl);
   double reward = MathAbs(tp - price);
   if(risk <= 0.0 || reward < InpMinRewardRisk * risk)
     {
      PrintFormat("Skipped %s: reward:risk %.2f below minimum %.2f",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                  (risk > 0.0 ? reward / risk : 0.0), InpMinRewardRisk);
      return;
     }

   double lots = CalcLots(slDist);
   if(lots <= 0.0)
     {
      Print("Computed lot size is zero - aborting entry.");
      return;
     }

   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lots, _Symbol, price, sl, tp, InpComment)
             : trade.Sell(lots, _Symbol, price, sl, tp, InpComment);

   if(ok)
     {
      g_tradesToday++;
      g_lastTradeTime = TimeCurrent();
      PrintFormat("%s %.2f lots @ %.*f  SL %.*f  TP %.*f  | delta %.0f  POC %.*f  VA %.*f-%.*f",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), lots,
                  _Digits, price, _Digits, sl, _Digits, tp,
                  g_lastDelta, _Digits, g_poc, _Digits, g_val, _Digits, g_vah);
     }
   else
      PrintFormat("Order failed: %d - %s",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Position size from fixed lot or % risk of equity                 |
//+------------------------------------------------------------------+
double CalcLots(const double slDistance)
  {
   if(InpSizingMode == SIZE_FIXED_LOT)
      return(NormalizeLots(InpFixedLots));

   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return(NormalizeLots(InpFixedLots));

   double lossPerLot = slDistance / tickSize * tickValue;
   if(lossPerLot <= 0.0)
      return(NormalizeLots(InpFixedLots));

   return(NormalizeLots(riskMoney / lossPerLot));
  }

//+------------------------------------------------------------------+
//| Break-even and trailing-stop management for our positions        |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   if(!InpUseBreakEven && !InpUseTrailing)
      return;

   //--- ATR-based exits, so break-even / trailing scale with volatility
   //--- and are independent of the symbol's digits.
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_atrHandle, 0, 0, 1, atr) < 1)
      return;
   double atrNow = atr[0];
   if(atrNow <= 0.0)
      return;

   double beTrigger = InpBreakEvenAtr     * atrNow;
   double beLock    = InpBreakEvenLockAtr * atrNow;
   double trailStart = InpTrailStartAtr   * atrNow;
   double trailStep  = InpTrailStepAtr    * atrNow;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!posInfo.SelectByTicket(ticket))
         continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber)
         continue;

      long   type      = posInfo.PositionType();
      double openPrice = posInfo.PriceOpen();
      double curSL     = posInfo.StopLoss();
      double curTP     = posInfo.TakeProfit();
      double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double newSL     = curSL;

      if(type == POSITION_TYPE_BUY)
        {
         double profit = bid - openPrice;
         if(InpUseBreakEven && profit >= beTrigger)
           {
            double be = NormalizeDouble(openPrice + beLock, _Digits);
            if(be > newSL) newSL = be;
           }
         if(InpUseTrailing && profit >= trailStart)
           {
            double trail = NormalizeDouble(bid - trailStep, _Digits);
            if(trail > newSL) newSL = trail;
           }
         if(newSL > curSL && newSL < bid)
            trade.PositionModify(ticket, newSL, curTP);
        }
      else if(type == POSITION_TYPE_SELL)
        {
         double profit = openPrice - ask;
         if(InpUseBreakEven && profit >= beTrigger)
           {
            double be = NormalizeDouble(openPrice - beLock, _Digits);
            if(curSL == 0.0 || be < newSL) newSL = be;
           }
         if(InpUseTrailing && profit >= trailStart)
           {
            double trail = NormalizeDouble(ask + trailStep, _Digits);
            if(curSL == 0.0 || trail < newSL) newSL = trail;
           }
         if(newSL != curSL && (curSL == 0.0 || newSL < curSL) && newSL > ask)
            trade.PositionModify(ticket, newSL, curTP);
        }
     }
  }

//+------------------------------------------------------------------+
//| Count this EA's open positions on this symbol                    |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!posInfo.SelectByTicket(ticket))
         continue;
      if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| True while the clock is inside the trading session window        |
//+------------------------------------------------------------------+
bool InSession()
  {
   MqlDateTime st;
   TimeToStruct(TimeCurrent(), st);
   int hour = st.hour;

   if(InpSessionStartHour == InpSessionEndHour)
      return(true);
   if(InpSessionStartHour < InpSessionEndHour)
      return(hour >= InpSessionStartHour && hour < InpSessionEndHour);
   return(hour >= InpSessionStartHour || hour < InpSessionEndHour);
  }

//+------------------------------------------------------------------+
//| Spread check relative to ATR (digit-agnostic)                    |
//+------------------------------------------------------------------+
bool SpreadOK(const double atrValue)
  {
   if(InpMaxSpreadAtrPct <= 0.0 || atrValue <= 0.0)
      return(true);
   double spreadPrice = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   return(spreadPrice <= atrValue * InpMaxSpreadAtrPct / 100.0);
  }

//+------------------------------------------------------------------+
//| Normalize lots to the symbol's volume constraints                |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep > 0.0)
      lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   return(lots);
  }

//+------------------------------------------------------------------+
//| Midnight (00:00) of the day a timestamp belongs to               |
//+------------------------------------------------------------------+
datetime DayStart(const datetime t)
  {
   return(t - (t % 86400));
  }

//+------------------------------------------------------------------+
//| Draw / refresh the POC, VAH and VAL lines                        |
//+------------------------------------------------------------------+
void DrawLevels()
  {
   DrawHLine(OBJ_POC, g_poc, clrGold,       STYLE_SOLID);
   DrawHLine(OBJ_VAH, g_vah, clrDodgerBlue, STYLE_DOT);
   DrawHLine(OBJ_VAL, g_val, clrDodgerBlue, STYLE_DOT);
  }

void DrawHLine(const string name, const double price, const color clr, const int style)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| On-chart status read-out                                         |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPct = (g_dayStartEquity > 0.0)
                   ? (equity - g_dayStartEquity) / g_dayStartEquity * 100.0 : 0.0;

   string state = g_dayBlocked ? "HALTED (daily limit)"
                  : (InpUseSession && !InSession()) ? "outside session" : "active";

   string txt = StringFormat(
      "GoldFlowProfile  [%s %s]\n"
      "State: %s\n"
      "POC: %.*f   VA: %.*f - %.*f\n"
      "Last bar delta: %.0f   Cum delta(%d): %.0f\n"
      "Open: %d/%d   Trades today: %d/%d\n"
      "Day P/L: %.2f%%",
      _Symbol, EnumToString(InpTimeframe), state,
      _Digits, g_poc, _Digits, g_val, _Digits, g_vah,
      g_lastDelta, InpCumDeltaBars, g_cumDelta,
      CountOpenPositions(), InpMaxPositions, g_tradesToday, InpMaxTradesPerDay,
      dayPct);
   Comment(txt);
  }
//+------------------------------------------------------------------+
