//+------------------------------------------------------------------+
//|                                         GoldEMACrossScalper.mq5   |
//|                                                                  |
//|   XAUUSD (gold) 5-minute trend-following scalper.                |
//|                                                                  |
//|   Reconstructed from the common "Proven 5-Minute XAUUSD          |
//|   scalping" setup (EMA 9/21 crossover + RSI confirmation,        |
//|   traded in the London/NY session). This is a TREND-following    |
//|   strategy - deliberately the opposite style to the VWAP         |
//|   mean-reversion EA - so it lets winners run with a trailing     |
//|   stop instead of fading extremes.                               |
//|                                                                  |
//|   Strategy                                                       |
//|   --------                                                       |
//|   * LONG : fast EMA crosses ABOVE slow EMA, RSI above its        |
//|     midline, and (optionally) price above a higher trend EMA.    |
//|   * SHORT: mirror image.                                         |
//|   * ATR stop, ATR or RR target, optional break-even & trailing,  |
//|     optional exit on the opposite cross.                         |
//|   * % risk sizing, daily circuit breakers, session window        |
//|     (server time or UTC-with-offset), ATR-relative spread guard. |
//|                                                                  |
//|   Manages only its own orders (by magic number). Server time.    |
//+------------------------------------------------------------------+
#property copyright "Sam Watts"
#property version   "1.00"
#property strict
#property description "EMA 9/21 crossover + RSI trend-following scalper for XAUUSD (gold)."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

enum ENUM_SIZING_MODE
  {
   SIZE_FIXED_LOT,      // Fixed lot size
   SIZE_RISK_PERCENT    // Risk a % of equity per trade
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Signal ==="
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_M5;  // Working timeframe
input int            InpFastEmaPeriod      = 9;     // Fast EMA period
input int            InpSlowEmaPeriod      = 21;    // Slow EMA period
input bool           InpUseRsi             = true;  // Require RSI confirmation
input int            InpRsiPeriod          = 14;    // RSI period
input double         InpRsiMidline         = 50.0;  // RSI midline (long > , short <)
input bool           InpUseTrendEma        = true;  // Require a higher-EMA trend bias
input int            InpTrendEmaPeriod      = 200;   // Trend EMA period
input bool           InpExitOnCross        = true;  // Close on the opposite EMA cross

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
input double         InpAtrTPMult          = 2.5;   // Take profit = ATR x this (0 = none, ride trail)
input bool           InpUseBreakEven       = true;  // Move SL to break-even
input double         InpBreakEvenAtr       = 1.0;   // Profit (x ATR) to trigger break-even
input double         InpBreakEvenLockAtr   = 0.1;   // Profit locked in at break-even (x ATR)
input bool           InpUseTrailing        = true;  // Trail the stop (let trends run)
input double         InpTrailStartAtr      = 1.5;   // Profit (x ATR) before trailing starts
input double         InpTrailStepAtr       = 1.5;   // Trailing distance (x ATR)

input group "=== Trade control / risk caps ==="
input int            InpMaxPositions       = 1;     // Max concurrent positions (this EA)
input int            InpMaxTradesPerDay    = 6;     // Max new trades per day (0 = no limit)
input double         InpDailyLossLimit     = 5.0;   // Stop for the day after losing this % (0 = off)
input double         InpDailyProfitTarget  = 0.0;   // Stop for the day after gaining this % (0 = off)
input int            InpMinSecondsBetween  = 120;   // Min seconds between entries

input group "=== Session window ==="
input bool           InpUseSession         = true;  // Restrict to a session window
input bool           InpSessionInUTC       = false; // Treat the hours below as UTC (convert via offset)
input int            InpBrokerGmtOffset    = 3;     // Broker server time minus UTC (hours) - VERIFY yours
input int            InpSessionStartHour   = 13;    // Session start hour
input int            InpSessionEndHour     = 21;    // Session end hour

input group "=== General ==="
input long           InpMagicNumber        = 20240604; // Magic number
input string         InpComment            = "GoldEMACrossScalper"; // Order comment

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade        trade;
CPositionInfo posInfo;

int      g_fastHandle  = INVALID_HANDLE;
int      g_slowHandle  = INVALID_HANDLE;
int      g_rsiHandle   = INVALID_HANDLE;
int      g_trendHandle = INVALID_HANDLE;
int      g_atrHandle   = INVALID_HANDLE;

datetime g_lastBarTime   = 0;
datetime g_currentDay    = 0;
datetime g_lastTradeTime = 0;
int      g_tradesToday   = 0;
double   g_dayStartEquity = 0.0;
bool     g_dayBlocked    = false;

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
      Print("Fast EMA must be > 0 and smaller than the slow EMA.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpAtrPeriod <= 0 || (InpUseRsi && InpRsiPeriod <= 0))
     {
      Print("ATR / RSI periods must be greater than zero.");
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

   g_fastHandle = iMA(_Symbol, InpTimeframe, InpFastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_slowHandle = iMA(_Symbol, InpTimeframe, InpSlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_atrHandle  = iATR(_Symbol, InpTimeframe, InpAtrPeriod);
   if(InpUseRsi)
      g_rsiHandle = iRSI(_Symbol, InpTimeframe, InpRsiPeriod, PRICE_CLOSE);
   if(InpUseTrendEma)
      g_trendHandle = iMA(_Symbol, InpTimeframe, InpTrendEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(g_fastHandle == INVALID_HANDLE || g_slowHandle == INVALID_HANDLE ||
      g_atrHandle == INVALID_HANDLE ||
      (InpUseRsi      && g_rsiHandle   == INVALID_HANDLE) ||
      (InpUseTrendEma && g_trendHandle == INVALID_HANDLE))
     {
      Print("Failed to create indicator handles.");
      return(INIT_FAILED);
     }

   ResetDailyCounters(DayStart(TimeCurrent()));
   PrintFormat("GoldEMACrossScalper initialised on %s (%s) | magic %I64d",
               _Symbol, EnumToString(InpTimeframe), InpMagicNumber);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_fastHandle  != INVALID_HANDLE) IndicatorRelease(g_fastHandle);
   if(g_slowHandle  != INVALID_HANDLE) IndicatorRelease(g_slowHandle);
   if(g_rsiHandle   != INVALID_HANDLE) IndicatorRelease(g_rsiHandle);
   if(g_trendHandle != INVALID_HANDLE) IndicatorRelease(g_trendHandle);
   if(g_atrHandle   != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
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

   datetime barTime = (datetime)SeriesInfoInteger(_Symbol, InpTimeframe, SERIES_LASTBAR_DATE);
   if(barTime == g_lastBarTime)
     {
      UpdateDashboard();
      return;
     }
   g_lastBarTime = barTime;

   EvaluateSignals();
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
//| Evaluate crossover signals on the last closed bar                |
//+------------------------------------------------------------------+
void EvaluateSignals()
  {
   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   if(CopyBuffer(g_fastHandle, 0, 1, 2, fast) < 2) return;
   if(CopyBuffer(g_slowHandle, 0, 1, 2, slow) < 2) return;

   //--- fast[0]=last closed (shift 1), fast[1]=the bar before it (shift 2).
   bool bullCross = (fast[1] <= slow[1]) && (fast[0] > slow[0]);
   bool bearCross = (fast[1] >= slow[1]) && (fast[0] < slow[0]);

   //--- Optional exit on the opposite cross (managed regardless of session).
   if(InpExitOnCross)
     {
      if(bearCross) ClosePositions(POSITION_TYPE_BUY);
      if(bullCross) ClosePositions(POSITION_TYPE_SELL);
     }

   //--- Entry gates.
   if(g_dayBlocked) return;
   if(InpUseSession && !InSession()) return;
   if(InpMaxTradesPerDay > 0 && g_tradesToday >= InpMaxTradesPerDay) return;
   if(CountOpenPositions() >= InpMaxPositions) return;
   if(g_lastTradeTime > 0 && (TimeCurrent() - g_lastTradeTime) < InpMinSecondsBetween) return;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_atrHandle, 0, 1, 1, atr) < 1) return;
   double atrNow = atr[0];
   if(atrNow <= 0.0) return;
   if(InpMinAtrPoints > 0 && (atrNow / _Point) < InpMinAtrPoints) return;
   if(!SpreadOK(atrNow)) return;

   //--- RSI confirmation.
   double rsiVal = 50.0;
   if(InpUseRsi)
     {
      double rsi[];
      ArraySetAsSeries(rsi, true);
      if(CopyBuffer(g_rsiHandle, 0, 1, 1, rsi) < 1) return;
      rsiVal = rsi[0];
     }

   //--- Higher-EMA trend bias.
   double close = iClose(_Symbol, InpTimeframe, 1);
   double trendEma = 0.0;
   if(InpUseTrendEma)
     {
      double te[];
      ArraySetAsSeries(te, true);
      if(CopyBuffer(g_trendHandle, 0, 1, 1, te) < 1) return;
      trendEma = te[0];
     }

   bool buyOK  = bullCross &&
                 (!InpUseRsi      || rsiVal > InpRsiMidline) &&
                 (!InpUseTrendEma || close  > trendEma);
   bool sellOK = bearCross &&
                 (!InpUseRsi      || rsiVal < InpRsiMidline) &&
                 (!InpUseTrendEma || close  < trendEma);

   if(buyOK)
      OpenTrade(ORDER_TYPE_BUY, atrNow);
   else if(sellOK)
      OpenTrade(ORDER_TYPE_SELL, atrNow);
  }

//+------------------------------------------------------------------+
//| Open a market order with ATR stop & target                       |
//+------------------------------------------------------------------+
void OpenTrade(const ENUM_ORDER_TYPE type, const double atrValue)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double slDist = InpAtrSLMult * atrValue;
   double tpDist = InpAtrTPMult * atrValue;
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(slDist < minStop) slDist = minStop;
   if(slDist <= 0.0) return;

   double price = (type == ORDER_TYPE_BUY) ? ask : bid;
   double sl, tp;
   if(type == ORDER_TYPE_BUY)
     {
      sl = NormalizeDouble(price - slDist, _Digits);
      tp = (tpDist > 0.0) ? NormalizeDouble(price + tpDist, _Digits) : 0.0;
     }
   else
     {
      sl = NormalizeDouble(price + slDist, _Digits);
      tp = (tpDist > 0.0) ? NormalizeDouble(price - tpDist, _Digits) : 0.0;
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
      PrintFormat("%s %.2f lots @ %.*f  SL %.*f  TP %.*f",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), lots,
                  _Digits, price, _Digits, sl, _Digits, tp);
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
//| Break-even and trailing-stop management                          |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   if(!InpUseBreakEven && !InpUseTrailing)
      return;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_atrHandle, 0, 0, 1, atr) < 1)
      return;
   double atrNow = atr[0];
   if(atrNow <= 0.0)
      return;
   double beTrigger  = InpBreakEvenAtr     * atrNow;
   double beLock     = InpBreakEvenLockAtr * atrNow;
   double trailStart = InpTrailStartAtr    * atrNow;
   double trailStep  = InpTrailStepAtr     * atrNow;

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
//| Close this EA's positions of a given direction                   |
//+------------------------------------------------------------------+
void ClosePositions(const long wantType)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!posInfo.SelectByTicket(ticket))
         continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber)
         continue;
      if(posInfo.PositionType() == wantType)
         trade.PositionClose(ticket);
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
//| Convert a configured hour into the broker's server hour          |
//+------------------------------------------------------------------+
int ServerHour(const int configuredHour)
  {
   if(!InpSessionInUTC)
      return(configuredHour);
   int h = (configuredHour + InpBrokerGmtOffset) % 24;
   if(h < 0) h += 24;
   return(h);
  }

//+------------------------------------------------------------------+
//| True while the clock is inside the trading session window        |
//+------------------------------------------------------------------+
bool InSession()
  {
   MqlDateTime st;
   TimeToStruct(TimeCurrent(), st);
   int hour  = st.hour;
   int start = ServerHour(InpSessionStartHour);
   int end   = ServerHour(InpSessionEndHour);
   if(start == end)
      return(true);
   if(start < end)
      return(hour >= start && hour < end);
   return(hour >= start || hour < end);
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
      "GoldEMACrossScalper  [%s %s]\n"
      "State: %s\n"
      "Session (server): %02d:00-%02d:00\n"
      "EMA %d/%d  RSI(%d)>%.0f  Trend EMA %d\n"
      "Open: %d/%d   Trades today: %d/%d\n"
      "Day P/L: %.2f%%",
      _Symbol, EnumToString(InpTimeframe), state,
      ServerHour(InpSessionStartHour), ServerHour(InpSessionEndHour),
      InpFastEmaPeriod, InpSlowEmaPeriod, InpRsiPeriod, InpRsiMidline, InpTrendEmaPeriod,
      CountOpenPositions(), InpMaxPositions, g_tradesToday, InpMaxTradesPerDay,
      dayPct);
   Comment(txt);
  }
//+------------------------------------------------------------------+
