//+------------------------------------------------------------------+
//|                                              GoldScalperPro.mq5   |
//|                                                                  |
//|   A dedicated XAUUSD (gold) scalping Expert Advisor.             |
//|                                                                  |
//|   Strategy (trend-filtered momentum pullback)                    |
//|   ------------------------------------------                     |
//|   1. A higher/slower EMA defines the prevailing trend, so the    |
//|      EA only ever trades WITH the dominant direction.            |
//|   2. Inside that trend it waits for a short pullback: price      |
//|      dips back to the fast EMA and RSI leaves an oversold        |
//|      (long) / overbought (short) extreme - i.e. it buys dips in  |
//|      an uptrend and sells rallies in a downtrend.                |
//|   3. An ATR filter makes sure there is enough volatility to pay  |
//|      for the spread, and an ATR-based stop/target adapts the     |
//|      trade size to current gold volatility.                      |
//|   4. Position size is derived from a fixed % risk of equity, so  |
//|      a small account never over-leverages on a single trade.     |
//|   5. Hard daily-loss and daily-profit circuit breakers, a max    |
//|      trades-per-day cap, a spread guard and a trading-session    |
//|      window keep the scalper out of bad conditions.              |
//|                                                                  |
//|   This EA is completely independent of any other strategy and    |
//|   manages only its own orders (identified by the magic number).  |
//|                                                                  |
//|   All times are broker/server time.                              |
//+------------------------------------------------------------------+
#property copyright "Sam Watts"
#property version   "1.00"
#property strict
#property description "Trend-filtered momentum pullback scalper for XAUUSD (gold)."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Position sizing mode
enum ENUM_SIZING_MODE
  {
   SIZE_FIXED_LOT,      // Fixed lot size
   SIZE_RISK_PERCENT    // Risk a % of equity per trade
  };

//--- Stop loss / take profit calculation mode
enum ENUM_STOP_MODE
  {
   STOP_ATR,            // ATR multiple (adapts to volatility)
   STOP_POINTS          // Fixed distance in points
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Strategy / signal ==="
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_M5;  // Working timeframe
input int            InpFastEmaPeriod      = 21;    // Fast EMA (pullback level)
input int            InpSlowEmaPeriod      = 100;   // Slow EMA (trend filter)
input int            InpRsiPeriod          = 14;    // RSI period
input double         InpRsiBuyLevel        = 40.0;  // Buy when RSI rises back above this
input double         InpRsiSellLevel       = 60.0;  // Sell when RSI falls back below this
input int            InpPullbackPoints     = 150;   // Max distance price..fast EMA to allow entry (points)

input group "=== Volatility / filters ==="
input int            InpAtrPeriod          = 14;    // ATR period
input int            InpMinAtrPoints       = 80;    // Skip if ATR below this (points, 0 = ignore)
input int            InpMaxSpreadPoints    = 50;    // Max allowed spread (points, 0 = ignore)

input group "=== Position sizing ==="
input ENUM_SIZING_MODE InpSizingMode       = SIZE_RISK_PERCENT; // How to size trades
input double         InpFixedLots          = 0.01;  // Lot size (fixed-lot mode)
input double         InpRiskPercent        = 1.0;   // Risk per trade (% of equity)

input group "=== Stops / exits ==="
input ENUM_STOP_MODE InpStopMode           = STOP_ATR; // SL/TP calculation mode
input double         InpAtrSLMult          = 1.5;   // Stop loss = ATR x this
input double         InpAtrTPMult          = 2.0;   // Take profit = ATR x this
input int            InpStopLossPoints     = 200;   // Stop loss (points, fixed mode)
input int            InpTakeProfitPoints   = 300;   // Take profit (points, fixed mode)
input bool           InpUseBreakEven       = true;  // Move SL to break-even
input int            InpBreakEvenPoints    = 150;   // Profit (points) to trigger break-even
input int            InpBreakEvenLock      = 20;    // Points locked in at break-even
input bool           InpUseTrailing        = true;  // Use trailing stop
input int            InpTrailStartPoints   = 200;   // Profit (points) before trailing starts
input int            InpTrailStepPoints    = 120;   // Trailing distance (points)

input group "=== Trade control / risk caps ==="
input int            InpMaxPositions       = 1;     // Max concurrent positions (this EA)
input int            InpMaxTradesPerDay    = 6;     // Max new trades per day (0 = no limit)
input double         InpDailyLossLimit     = 5.0;   // Stop for the day after losing this % of equity (0 = off)
input double         InpDailyProfitTarget  = 0.0;   // Stop for the day after gaining this % of equity (0 = off)
input int            InpMinSecondsBetween  = 60;    // Min seconds between entries

input group "=== Session window (server time) ==="
input bool           InpUseSession         = true;  // Restrict trading to a window
input int            InpSessionStartHour   = 7;     // Session start hour (0-23)
input int            InpSessionEndHour     = 20;    // Session end hour (0-23)

input group "=== General ==="
input long           InpMagicNumber        = 20240530; // Magic number
input string         InpComment            = "GoldScalperPro"; // Order comment

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade        trade;
CPositionInfo posInfo;

int      g_fastEmaHandle = INVALID_HANDLE;
int      g_slowEmaHandle = INVALID_HANDLE;
int      g_rsiHandle     = INVALID_HANDLE;
int      g_atrHandle     = INVALID_HANDLE;

datetime g_lastBarTime   = 0;     // last processed bar of the working timeframe
datetime g_currentDay    = 0;     // day (00:00) the daily counters belong to
datetime g_lastTradeTime = 0;     // time of the last entry
int      g_tradesToday   = 0;     // entries opened today
double   g_dayStartEquity = 0.0;  // equity at the start of the trading day
bool     g_dayBlocked    = false; // daily circuit breaker tripped

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(20);

   if(InpFastEmaPeriod <= 0 || InpSlowEmaPeriod <= 0 ||
      InpFastEmaPeriod >= InpSlowEmaPeriod)
     {
      Print("Fast EMA period must be > 0 and smaller than the slow EMA period.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpRsiPeriod <= 0 || InpAtrPeriod <= 0)
     {
      Print("RSI and ATR periods must be greater than zero.");
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

   g_fastEmaHandle = iMA(_Symbol, InpTimeframe, InpFastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_slowEmaHandle = iMA(_Symbol, InpTimeframe, InpSlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_rsiHandle     = iRSI(_Symbol, InpTimeframe, InpRsiPeriod, PRICE_CLOSE);
   g_atrHandle     = iATR(_Symbol, InpTimeframe, InpAtrPeriod);

   if(g_fastEmaHandle == INVALID_HANDLE || g_slowEmaHandle == INVALID_HANDLE ||
      g_rsiHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
     {
      Print("Failed to create one or more indicator handles.");
      return(INIT_FAILED);
     }

   ResetDailyCounters(DayStart(TimeCurrent()));

   PrintFormat("GoldScalperPro initialised on %s (%s) | magic %I64d",
               _Symbol, EnumToString(InpTimeframe), InpMagicNumber);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_fastEmaHandle != INVALID_HANDLE) IndicatorRelease(g_fastEmaHandle);
   if(g_slowEmaHandle != INVALID_HANDLE) IndicatorRelease(g_slowEmaHandle);
   if(g_rsiHandle     != INVALID_HANDLE) IndicatorRelease(g_rsiHandle);
   if(g_atrHandle     != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now = TimeCurrent();

   //--- New trading day: reset the daily counters / circuit breaker.
   datetime today = DayStart(now);
   if(today != g_currentDay)
      ResetDailyCounters(today);

   //--- Manage what is already open on every tick (responsive exits).
   ManageOpenPositions();

   //--- Trip / hold the daily circuit breaker.
   CheckDailyLimits();

   //--- Only evaluate fresh signals once per closed bar.
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
//| Reset the per-day counters and snapshot starting equity          |
//+------------------------------------------------------------------+
void ResetDailyCounters(const datetime today)
  {
   g_currentDay      = today;
   g_tradesToday     = 0;
   g_dayBlocked      = false;
   g_dayStartEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
  }

//+------------------------------------------------------------------+
//| Daily loss / profit circuit breaker                              |
//+------------------------------------------------------------------+
void CheckDailyLimits()
  {
   if(g_dayBlocked)
      return;
   if(g_dayStartEquity <= 0.0)
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
//| Evaluate the entry signal on the latest closed bar               |
//+------------------------------------------------------------------+
void EvaluateEntry()
  {
   //--- Respect all the gates before doing any work.
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
   if(!SpreadOK())
      return;

   //--- Pull indicator values for the just-closed bar (shift 1) and the
   //--- previous one (shift 2) so we can detect an RSI cross.
   double fastEma[2], slowEma[2], rsi[2], atr[1];
   if(CopyBuffer(g_fastEmaHandle, 0, 1, 2, fastEma) < 2) return;
   if(CopyBuffer(g_slowEmaHandle, 0, 1, 2, slowEma) < 2) return;
   if(CopyBuffer(g_rsiHandle,     0, 1, 2, rsi)     < 2) return;
   if(CopyBuffer(g_atrHandle,     0, 1, 1, atr)     < 1) return;

   double atrPoints = atr[0] / _Point;
   if(InpMinAtrPoints > 0 && atrPoints < InpMinAtrPoints)
      return;

   double closePrice = iClose(_Symbol, InpTimeframe, 1);
   if(closePrice <= 0.0)
      return;

   bool   trendUp   = (fastEma[0] > slowEma[0]) && (closePrice > slowEma[0]);
   bool   trendDown = (fastEma[0] < slowEma[0]) && (closePrice < slowEma[0]);

   double distToFast = MathAbs(closePrice - fastEma[0]) / _Point;
   bool   nearFast   = (distToFast <= InpPullbackPoints);

   //--- Long: uptrend, price pulled back near the fast EMA, RSI turning up
   //--- out of the buy zone.
   bool buySignal  = trendUp   && nearFast &&
                     rsi[1] < InpRsiBuyLevel && rsi[0] >= InpRsiBuyLevel;

   //--- Short: downtrend, price pulled back near the fast EMA, RSI turning
   //--- down out of the sell zone.
   bool sellSignal = trendDown && nearFast &&
                     rsi[1] > InpRsiSellLevel && rsi[0] <= InpRsiSellLevel;

   if(buySignal)
      OpenTrade(ORDER_TYPE_BUY, atr[0]);
   else if(sellSignal)
      OpenTrade(ORDER_TYPE_SELL, atr[0]);
  }

//+------------------------------------------------------------------+
//| Open a market order with ATR/points based SL & TP                |
//+------------------------------------------------------------------+
void OpenTrade(const ENUM_ORDER_TYPE type, const double atrValue)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double slDist = StopDistance(InpStopMode == STOP_ATR ? InpAtrSLMult : InpStopLossPoints, atrValue);
   double tpDist = StopDistance(InpStopMode == STOP_ATR ? InpAtrTPMult : InpTakeProfitPoints, atrValue);

   //--- Respect the broker's minimum stop distance.
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(slDist < minStop) slDist = minStop;
   if(tpDist < minStop) tpDist = minStop;
   if(slDist <= 0.0)
     {
      Print("Computed stop distance is zero - aborting entry.");
      return;
     }

   double price = (type == ORDER_TYPE_BUY) ? ask : bid;
   double sl, tp;
   if(type == ORDER_TYPE_BUY)
     {
      sl = NormalizeDouble(price - slDist, _Digits);
      tp = NormalizeDouble(price + tpDist, _Digits);
     }
   else
     {
      sl = NormalizeDouble(price + slDist, _Digits);
      tp = NormalizeDouble(price - tpDist, _Digits);
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
      PrintFormat("%s %.2f lots @ %.*f  SL %.*f  TP %.*f  (trade %d/%d today)",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), lots,
                  _Digits, price, _Digits, sl, _Digits, tp,
                  g_tradesToday, InpMaxTradesPerDay);
     }
   else
      PrintFormat("Order failed: %d - %s",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| Convert an SL/TP setting to a price distance                     |
//+------------------------------------------------------------------+
double StopDistance(const double value, const double atrValue)
  {
   if(value <= 0.0)
      return(0.0);
   if(InpStopMode == STOP_ATR)
      return(value * atrValue);
   return(value * _Point);          // STOP_POINTS
  }

//+------------------------------------------------------------------+
//| Position size from fixed lot or % risk of equity                 |
//+------------------------------------------------------------------+
double CalcLots(const double slDistance)
  {
   if(InpSizingMode == SIZE_FIXED_LOT)
      return(NormalizeLots(InpFixedLots));

   //--- Risk-percent sizing: lots = riskMoney / (slDistance valued per lot).
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney  = equity * InpRiskPercent / 100.0;

   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return(NormalizeLots(InpFixedLots));

   double lossPerLot = slDistance / tickSize * tickValue;
   if(lossPerLot <= 0.0)
      return(NormalizeLots(InpFixedLots));

   double lots = riskMoney / lossPerLot;
   return(NormalizeLots(lots));
  }

//+------------------------------------------------------------------+
//| Break-even and trailing-stop management for our positions        |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   if(!InpUseBreakEven && !InpUseTrailing)
      return;

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
         double profitPts = (bid - openPrice) / _Point;

         if(InpUseBreakEven && profitPts >= InpBreakEvenPoints)
           {
            double be = NormalizeDouble(openPrice + InpBreakEvenLock * _Point, _Digits);
            if(be > newSL)
               newSL = be;
           }
         if(InpUseTrailing && profitPts >= InpTrailStartPoints)
           {
            double trail = NormalizeDouble(bid - InpTrailStepPoints * _Point, _Digits);
            if(trail > newSL)
               newSL = trail;
           }
         if(newSL > curSL && newSL < bid)
            trade.PositionModify(ticket, newSL, curTP);
        }
      else if(type == POSITION_TYPE_SELL)
        {
         double profitPts = (openPrice - ask) / _Point;

         if(InpUseBreakEven && profitPts >= InpBreakEvenPoints)
           {
            double be = NormalizeDouble(openPrice - InpBreakEvenLock * _Point, _Digits);
            if(curSL == 0.0 || be < newSL)
               newSL = be;
           }
         if(InpUseTrailing && profitPts >= InpTrailStartPoints)
           {
            double trail = NormalizeDouble(ask + InpTrailStepPoints * _Point, _Digits);
            if(curSL == 0.0 || trail < newSL)
               newSL = trail;
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
      return(true);                              // 24h
   if(InpSessionStartHour < InpSessionEndHour)
      return(hour >= InpSessionStartHour && hour < InpSessionEndHour);
   //--- window that wraps past midnight
   return(hour >= InpSessionStartHour || hour < InpSessionEndHour);
  }

//+------------------------------------------------------------------+
//| Spread check                                                     |
//+------------------------------------------------------------------+
bool SpreadOK()
  {
   if(InpMaxSpreadPoints <= 0)
      return(true);
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return(spread <= InpMaxSpreadPoints);
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
//| On-chart status read-out                                         |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPct = (g_dayStartEquity > 0.0)
                   ? (equity - g_dayStartEquity) / g_dayStartEquity * 100.0 : 0.0;
   long   spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   string state = g_dayBlocked ? "HALTED (daily limit)"
                  : (InpUseSession && !InSession()) ? "outside session" : "active";

   string txt = StringFormat(
      "GoldScalperPro  [%s %s]\n"
      "State: %s\n"
      "Open positions: %d / %d\n"
      "Trades today: %d / %d\n"
      "Day P/L: %.2f%%\n"
      "Spread: %d pts (max %d)",
      _Symbol, EnumToString(InpTimeframe),
      state, CountOpenPositions(), InpMaxPositions,
      g_tradesToday, InpMaxTradesPerDay,
      dayPct, (int)spread, InpMaxSpreadPoints);
   Comment(txt);
  }
//+------------------------------------------------------------------+
