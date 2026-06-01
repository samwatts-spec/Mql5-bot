//+------------------------------------------------------------------+
//|                                          GoldVWAPReversion.mq5    |
//|                                                                  |
//|   XAUUSD (gold) intraday mean-reversion scalper built around the |
//|   session VWAP and its volume-weighted standard-deviation bands. |
//|                                                                  |
//|   Why this design                                               |
//|   --------------                                                |
//|   * VWAP is the institutional intraday fair-value reference.     |
//|     When gold stretches ~2 standard deviations away from the     |
//|     session VWAP it is statistically extended and tends to       |
//|     revert toward the mean.                                      |
//|   * Gold prints its daily high/low during the London/New York    |
//|     overlap ~70% of the time, with the tightest spreads, so the  |
//|     EA is built to trade a single high-quality session window    |
//|     and take FEW, selective trades (scalping's enemy is cost).   |
//|                                                                  |
//|   Strategy                                                       |
//|   --------                                                       |
//|   * LONG : price pierces BELOW VWAP - k*SD then closes back above |
//|     the band (a rejected stretch). Optional RSI(2) oversold       |
//|     confirmation. Target = VWAP (the mean). Stop = ATR below.     |
//|   * SHORT: symmetric at VWAP + k*SD.                              |
//|   * % risk sizing, ATR stop, minimum reward:risk, daily circuit  |
//|     breakers, session window, spread guard. Draws VWAP + bands.  |
//|                                                                  |
//|   Honest data note: retail MT5 gold is a CFD, so VWAP is built   |
//|   from TICK volume (real volume used automatically if provided). |
//|   All times are broker/server time.                              |
//+------------------------------------------------------------------+
#property copyright "Sam Watts"
#property version   "1.00"
#property strict
#property description "Session-VWAP standard-deviation mean-reversion scalper for XAUUSD (gold)."

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
input group "=== VWAP / signal ==="
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_M5;  // Working timeframe
input int            InpAnchorHour         = 0;     // Daily VWAP anchor hour (server time)
input double         InpBandMult           = 2.0;   // SD band multiple for the entry stretch
input bool           InpRequireCloseBack    = true;  // Need a close back inside the band
input int            InpMinSessionBars      = 12;    // Min bars since anchor before trading
input bool           InpUseRealVolume      = false; // Use real volume if the broker provides it
input bool           InpShowLevels         = true;  // Draw VWAP / bands on the chart

input group "=== RSI confirmation (optional) ==="
input bool           InpUseRsiFilter       = true;  // Require an RSI(2) extreme
input int            InpRsiPeriod          = 2;     // RSI period (2 = fast exhaustion)
input double         InpRsiBuyLevel        = 10.0;  // Long only if RSI <= this
input double         InpRsiSellLevel       = 90.0;  // Short only if RSI >= this

input group "=== Trend filter (optional) ==="
input bool           InpUseTrendFilter     = false; // Only trade with the EMA trend
input int            InpTrendEmaPeriod      = 200;   // Trend EMA period

input group "=== Volatility ==="
input int            InpAtrPeriod          = 14;    // ATR period
input int            InpMinAtrPoints       = 0;     // Skip if ATR below this (points, 0 = ignore)
input double         InpMaxSpreadAtrPct    = 20.0;  // Max spread as % of ATR (0 = ignore)

input group "=== Position sizing ==="
input ENUM_SIZING_MODE InpSizingMode       = SIZE_RISK_PERCENT; // How to size trades
input double         InpFixedLots          = 0.01;  // Lot size (fixed-lot mode)
input double         InpRiskPercent        = 1.0;   // Risk per trade (% of equity)

input group "=== Stops / exits ==="
input double         InpAtrSLMult          = 2.2;   // Stop loss = ATR x this beyond entry
input double         InpMinRewardRisk      = 1.0;   // Skip setups below this reward:risk (target=VWAP)
input bool           InpUseBreakEven       = false; // Move SL to break-even
input double         InpBreakEvenAtr       = 1.0;   // Profit (x ATR) to trigger break-even
input double         InpBreakEvenLockAtr   = 0.1;   // Profit locked in at break-even (x ATR)

input group "=== Trade control / risk caps ==="
input int            InpMaxPositions       = 1;     // Max concurrent positions (this EA)
input int            InpMaxTradesPerDay    = 4;     // Max new trades per day (0 = no limit)
input double         InpDailyLossLimit     = 4.0;   // Stop for the day after losing this % (0 = off)
input double         InpDailyProfitTarget  = 0.0;   // Stop for the day after gaining this % (0 = off)
input int            InpMinSecondsBetween  = 120;   // Min seconds between entries

input group "=== Session window ==="
input bool           InpUseSession         = true;  // Restrict to the London/NY overlap
input bool           InpSessionInUTC       = true;  // Treat the hours below as UTC (convert via offset)
input int            InpBrokerGmtOffset    = 3;     // Broker server time minus UTC (hours) - VERIFY yours
input int            InpSessionStartHour   = 13;    // Session start hour (13-17 UTC = London/NY overlap)
input int            InpSessionEndHour     = 17;    // Session end hour

input group "=== General ==="
input long           InpMagicNumber        = 20240603; // Magic number
input string         InpComment            = "GoldVWAPReversion"; // Order comment

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade        trade;
CPositionInfo posInfo;

int      g_atrHandle = INVALID_HANDLE;
int      g_rsiHandle = INVALID_HANDLE;
int      g_emaHandle = INVALID_HANDLE;

datetime g_lastBarTime   = 0;
datetime g_currentDay    = 0;
datetime g_lastTradeTime = 0;
int      g_tradesToday   = 0;
double   g_dayStartEquity = 0.0;
bool     g_dayBlocked    = false;

double   g_vwap = 0.0, g_upper = 0.0, g_lower = 0.0, g_sd = 0.0;

const string OBJ_VWAP = "GVR_VWAP";
const string OBJ_UP   = "GVR_UP";
const string OBJ_DN   = "GVR_DN";

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(20);

   if(InpBandMult <= 0.0)
     {
      Print("Band multiple must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpAtrPeriod <= 0 || InpRsiPeriod <= 0)
     {
      Print("ATR and RSI periods must be greater than zero.");
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
   if(InpUseRsiFilter)
      g_rsiHandle = iRSI(_Symbol, InpTimeframe, InpRsiPeriod, PRICE_CLOSE);
   if(InpUseTrendFilter)
      g_emaHandle = iMA(_Symbol, InpTimeframe, InpTrendEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(g_atrHandle == INVALID_HANDLE ||
      (InpUseRsiFilter   && g_rsiHandle == INVALID_HANDLE) ||
      (InpUseTrendFilter && g_emaHandle == INVALID_HANDLE))
     {
      Print("Failed to create indicator handles.");
      return(INIT_FAILED);
     }

   ResetDailyCounters(DayStart(TimeCurrent()));

   PrintFormat("GoldVWAPReversion initialised on %s (%s) | magic %I64d",
               _Symbol, EnumToString(InpTimeframe), InpMagicNumber);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   if(g_rsiHandle != INVALID_HANDLE) IndicatorRelease(g_rsiHandle);
   if(g_emaHandle != INVALID_HANDLE) IndicatorRelease(g_emaHandle);
   ObjectDelete(0, OBJ_VWAP);
   ObjectDelete(0, OBJ_UP);
   ObjectDelete(0, OBJ_DN);
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
//| Anchor time for today's VWAP (server time)                       |
//+------------------------------------------------------------------+
datetime AnchorTime()
  {
   datetime a = DayStart(TimeCurrent()) + InpAnchorHour * 3600;
   if(a > TimeCurrent())            // anchor still ahead -> use yesterday's
      a -= 86400;
   return(a);
  }

//+------------------------------------------------------------------+
//| Build the session VWAP and its volume-weighted SD bands          |
//| Returns the number of closed bars used (0 = failed / too few).   |
//+------------------------------------------------------------------+
int ComputeVWAP(double &vwap, double &sdev)
  {
   datetime anchor = AnchorTime();

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(_Symbol, InpTimeframe, anchor, TimeCurrent(), rates);
   if(copied <= 0)
      return(0);

   //--- Exclude the still-forming bar (the last one).
   datetime barTime = (datetime)SeriesInfoInteger(_Symbol, InpTimeframe, SERIES_LASTBAR_DATE);

   double sumPV = 0.0, sumV = 0.0, sumPV2 = 0.0;
   int    used  = 0;
   for(int i = 0; i < copied; i++)
     {
      if(rates[i].time < anchor || rates[i].time >= barTime)
         continue;                 // only closed bars within the session
      double tp = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
      double v  = (InpUseRealVolume && rates[i].real_volume > 0)
                  ? (double)rates[i].real_volume : (double)rates[i].tick_volume;
      if(v <= 0.0)
         continue;
      sumPV  += tp * v;
      sumPV2 += tp * tp * v;
      sumV   += v;
      used++;
     }
   if(sumV <= 0.0 || used < InpMinSessionBars)
      return(0);

   vwap = sumPV / sumV;
   double variance = sumPV2 / sumV - vwap * vwap;
   sdev = (variance > 0.0) ? MathSqrt(variance) : 0.0;
   return(used);
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

   double vwap, sd;
   if(ComputeVWAP(vwap, sd) <= 0 || sd <= 0.0)
      return;
   g_vwap  = vwap;
   g_sd    = sd;
   g_upper = vwap + InpBandMult * sd;
   g_lower = vwap - InpBandMult * sd;
   if(InpShowLevels)
      DrawLevels();

   //--- Volatility / spread gates.
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

   //--- Signal bar = last closed bar (shift 1).
   double sigHigh  = iHigh(_Symbol,  InpTimeframe, 1);
   double sigLow   = iLow(_Symbol,   InpTimeframe, 1);
   double sigClose = iClose(_Symbol, InpTimeframe, 1);
   if(sigClose <= 0.0)
      return;

   //--- Optional RSI(2) extreme.
   double rsiVal = 50.0;
   if(InpUseRsiFilter)
     {
      double rsi[];
      ArraySetAsSeries(rsi, true);
      if(CopyBuffer(g_rsiHandle, 0, 1, 1, rsi) < 1)
         return;
      rsiVal = rsi[0];
     }

   //--- Optional EMA trend filter.
   double ema = 0.0;
   if(InpUseTrendFilter)
     {
      double e[];
      ArraySetAsSeries(e, true);
      if(CopyBuffer(g_emaHandle, 0, 1, 1, e) < 1)
         return;
      ema = e[0];
     }

   //--- LONG: pierced below the lower band, (optionally) closed back inside,
   //--- RSI oversold, price not below a falling trend (if enabled).
   bool buyStretch = (sigLow <= g_lower) &&
                     (!InpRequireCloseBack || sigClose > g_lower);
   bool buyRsi     = (!InpUseRsiFilter || rsiVal <= InpRsiBuyLevel);
   bool buyTrend   = (!InpUseTrendFilter || sigClose > ema);
   bool buySignal  = buyStretch && buyRsi && buyTrend;

   //--- SHORT: symmetric at the upper band.
   bool sellStretch = (sigHigh >= g_upper) &&
                      (!InpRequireCloseBack || sigClose < g_upper);
   bool sellRsi     = (!InpUseRsiFilter || rsiVal >= InpRsiSellLevel);
   bool sellTrend   = (!InpUseTrendFilter || sigClose < ema);
   bool sellSignal  = sellStretch && sellRsi && sellTrend;

   if(buySignal)
      OpenTrade(ORDER_TYPE_BUY, atrNow);
   else if(sellSignal)
      OpenTrade(ORDER_TYPE_SELL, atrNow);
  }

//+------------------------------------------------------------------+
//| Open a market order: target the VWAP mean, stop ATR beyond entry |
//+------------------------------------------------------------------+
void OpenTrade(const ENUM_ORDER_TYPE type, const double atrValue)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double slDist  = InpAtrSLMult * atrValue;
   double minStop = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(slDist < minStop) slDist = minStop;

   double price = (type == ORDER_TYPE_BUY) ? ask : bid;
   double sl, tp;
   if(type == ORDER_TYPE_BUY)
     {
      sl = NormalizeDouble(price - slDist, _Digits);
      tp = NormalizeDouble(g_vwap, _Digits);          // revert to the mean
     }
   else
     {
      sl = NormalizeDouble(price + slDist, _Digits);
      tp = NormalizeDouble(g_vwap, _Digits);
     }

   //--- Reward:risk gate (target is the VWAP, risk is the ATR stop).
   double risk   = MathAbs(price - sl);
   double reward = MathAbs(tp - price);
   if(risk <= 0.0 || reward < InpMinRewardRisk * risk)
     {
      PrintFormat("Skipped %s: reward:risk %.2f below minimum %.2f",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
                  (risk > 0.0 ? reward / risk : 0.0), InpMinRewardRisk);
      return;
     }
   //--- Target must sit the correct side of entry.
   if((type == ORDER_TYPE_BUY && tp <= price) ||
      (type == ORDER_TYPE_SELL && tp >= price))
      return;

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
      PrintFormat("%s %.2f lots @ %.*f  SL %.*f  TP(VWAP) %.*f  | band %.*f  SD %.*f",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), lots,
                  _Digits, price, _Digits, sl, _Digits, tp,
                  _Digits, (type == ORDER_TYPE_BUY ? g_lower : g_upper), _Digits, g_sd);
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
//| ATR break-even management (trailing intentionally omitted)       |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   if(!InpUseBreakEven)
      return;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_atrHandle, 0, 0, 1, atr) < 1)
      return;
   double atrNow = atr[0];
   if(atrNow <= 0.0)
      return;
   double beTrigger = InpBreakEvenAtr     * atrNow;
   double beLock    = InpBreakEvenLockAtr * atrNow;

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

      if(type == POSITION_TYPE_BUY && (bid - openPrice) >= beTrigger)
        {
         double be = NormalizeDouble(openPrice + beLock, _Digits);
         if(be > curSL && be < bid)
            trade.PositionModify(ticket, be, curTP);
        }
      else if(type == POSITION_TYPE_SELL && (openPrice - ask) >= beTrigger)
        {
         double be = NormalizeDouble(openPrice - beLock, _Digits);
         if((curSL == 0.0 || be < curSL) && be > ask)
            trade.PositionModify(ticket, be, curTP);
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
//| Convert a configured hour into the broker's server hour.         |
//| When the hours are entered in UTC, server hour = UTC + offset.   |
//+------------------------------------------------------------------+
int ServerHour(const int configuredHour)
  {
   if(!InpSessionInUTC)
      return(configuredHour);          // already broker server time
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
//| Draw / refresh the VWAP and band lines                           |
//+------------------------------------------------------------------+
void DrawLevels()
  {
   DrawHLine(OBJ_VWAP, g_vwap,  clrGold,        STYLE_SOLID);
   DrawHLine(OBJ_UP,   g_upper, clrTomato,      STYLE_DOT);
   DrawHLine(OBJ_DN,   g_lower, clrDodgerBlue,  STYLE_DOT);
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
      "GoldVWAPReversion  [%s %s]\n"
      "State: %s\n"
      "Session (server): %02d:00-%02d:00\n"
      "VWAP: %.*f   Bands: %.*f / %.*f  (SD %.*f)\n"
      "Open: %d/%d   Trades today: %d/%d\n"
      "Day P/L: %.2f%%",
      _Symbol, EnumToString(InpTimeframe), state,
      ServerHour(InpSessionStartHour), ServerHour(InpSessionEndHour),
      _Digits, g_vwap, _Digits, g_lower, _Digits, g_upper, _Digits, g_sd,
      CountOpenPositions(), InpMaxPositions, g_tradesToday, InpMaxTradesPerDay,
      dayPct);
   Comment(txt);
  }
//+------------------------------------------------------------------+
