//+------------------------------------------------------------------+
//|                                       GoldConfluenceScalper.mq5   |
//|                                                                  |
//|   XAUUSD (gold) 1-minute confluence scalper.                     |
//|                                                                  |
//|   What it does                                                  |
//|   ------------                                                  |
//|   * Reads several independent indicators and counts how many    |
//|     agree on a direction (a "confluence" vote). It only enters   |
//|     when at least N of them line up - buy OR sell, whichever     |
//|     side has the votes. That is the "clever trigger".            |
//|   * Each trade is closed purely on a fixed MONEY target (e.g.    |
//|     +$10 floating profit). There is NO stop loss by default.     |
//|   * Trades all day while the market is open (session optional).  |
//|                                                                  |
//|   !! RISK WARNING !!                                            |
//|   With no stop loss a losing trade stays open until price comes  |
//|   back to the profit target - drawdown can be very large and an  |
//|   adverse spike can margin-call a small account. An OPTIONAL     |
//|   emergency money-stop and an optional daily loss limit are      |
//|   provided; both are off by default to honour the no-SL request. |
//|                                                                  |
//|   Manages only its own orders (by magic number). Server time.    |
//+------------------------------------------------------------------+
#property copyright "Sam Watts"
#property version   "1.00"
#property strict
#property description "1-minute multi-indicator confluence scalper with a fixed money target, no stop loss."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Exit (money based) ==="
input ENUM_TIMEFRAMES InpTimeframe        = PERIOD_M1;  // Working timeframe
input double         InpProfitTargetUSD    = 10.0;  // Close the trade at this floating profit ($)
input bool           InpUseEmergencyStop   = false; // OPTIONAL catastrophe money-stop
input double         InpEmergencyLossUSD   = 100.0; // Close if floating loss reaches this ($)

input group "=== Confluence trigger ==="
input int            InpMinConfirmations   = 3;     // Min indicators that must agree to enter
input bool           InpUseEma             = true;  // 1) EMA trend (fast vs slow)
input int            InpFastEmaPeriod      = 20;    // Fast EMA
input int            InpSlowEmaPeriod      = 50;    // Slow EMA
input bool           InpUseRsi             = true;  // 2) RSI vs midline
input int            InpRsiPeriod          = 14;    // RSI period
input bool           InpUseMacd            = true;  // 3) MACD main vs signal
input bool           InpUseStoch           = true;  // 4) Stochastic %K vs %D
input bool           InpUseBands           = true;  // 5) Price vs Bollinger middle
input int            InpBandsPeriod        = 20;    // Bollinger period
input bool           InpUseAdx             = true;  // 6) ADX +DI vs -DI (needs ADX >= min)
input int            InpAdxPeriod          = 14;    // ADX period
input double         InpAdxMin             = 20.0;  // ADX must be at least this to vote

input group "=== Position / sizing ==="
input double         InpLots               = 0.10;  // Fixed lot size
input int            InpMaxPositions       = 1;     // Max concurrent positions (this EA)
input int            InpMinSecondsBetween  = 30;    // Min seconds between entries
input int            InpMaxSpreadPoints    = 60;    // Max spread to enter (points, 0 = ignore)

input group "=== Optional safety ==="
input double         InpDailyLossLimit     = 0.0;   // Halt for the day after losing this % (0 = off)

input group "=== Session window ==="
input bool           InpUseSession         = false; // Restrict to a window (off = all day)
input bool           InpSessionInUTC       = false; // Treat the hours below as UTC (convert via offset)
input int            InpBrokerGmtOffset    = 3;     // Broker server time minus UTC (hours)
input int            InpSessionStartHour   = 0;     // Session start hour
input int            InpSessionEndHour     = 23;    // Session end hour

input group "=== General ==="
input long           InpMagicNumber        = 20240606; // Magic number
input string         InpComment            = "GoldConfluenceScalper"; // Order comment

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade        trade;
CPositionInfo posInfo;

int      g_emaFastH = INVALID_HANDLE;
int      g_emaSlowH = INVALID_HANDLE;
int      g_rsiH     = INVALID_HANDLE;
int      g_macdH    = INVALID_HANDLE;
int      g_stochH   = INVALID_HANDLE;
int      g_bandsH   = INVALID_HANDLE;
int      g_adxH     = INVALID_HANDLE;

datetime g_lastBarTime   = 0;
datetime g_currentDay    = 0;
datetime g_lastTradeTime = 0;
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

   if(InpProfitTargetUSD <= 0.0)
     {
      Print("Profit target must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpLots <= 0.0)
     {
      Print("Lot size must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpMinConfirmations < 1)
     {
      Print("Minimum confirmations must be at least 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpUseEma)
     {
      if(InpFastEmaPeriod <= 0 || InpSlowEmaPeriod <= 0 || InpFastEmaPeriod >= InpSlowEmaPeriod)
        {
         Print("EMA periods must satisfy 0 < fast < slow.");
         return(INIT_PARAMETERS_INCORRECT);
        }
      g_emaFastH = iMA(_Symbol, InpTimeframe, InpFastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
      g_emaSlowH = iMA(_Symbol, InpTimeframe, InpSlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
     }
   if(InpUseRsi)   g_rsiH   = iRSI(_Symbol, InpTimeframe, InpRsiPeriod, PRICE_CLOSE);
   if(InpUseMacd)  g_macdH  = iMACD(_Symbol, InpTimeframe, 12, 26, 9, PRICE_CLOSE);
   if(InpUseStoch) g_stochH = iStochastic(_Symbol, InpTimeframe, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
   if(InpUseBands) g_bandsH = iBands(_Symbol, InpTimeframe, InpBandsPeriod, 0, 2.0, PRICE_CLOSE);
   if(InpUseAdx)   g_adxH   = iADX(_Symbol, InpTimeframe, InpAdxPeriod);

   if((InpUseEma   && (g_emaFastH == INVALID_HANDLE || g_emaSlowH == INVALID_HANDLE)) ||
      (InpUseRsi   && g_rsiH   == INVALID_HANDLE) ||
      (InpUseMacd  && g_macdH  == INVALID_HANDLE) ||
      (InpUseStoch && g_stochH == INVALID_HANDLE) ||
      (InpUseBands && g_bandsH == INVALID_HANDLE) ||
      (InpUseAdx   && g_adxH   == INVALID_HANDLE))
     {
      Print("Failed to create one or more indicator handles.");
      return(INIT_FAILED);
     }

   ResetDay(DayStart(TimeCurrent()));
   PrintFormat("GoldConfluenceScalper initialised on %s (%s) | target $%.2f | no SL%s",
               _Symbol, EnumToString(InpTimeframe), InpProfitTargetUSD,
               InpUseEmergencyStop ? " (emergency stop ON)" : "");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_emaFastH != INVALID_HANDLE) IndicatorRelease(g_emaFastH);
   if(g_emaSlowH != INVALID_HANDLE) IndicatorRelease(g_emaSlowH);
   if(g_rsiH     != INVALID_HANDLE) IndicatorRelease(g_rsiH);
   if(g_macdH    != INVALID_HANDLE) IndicatorRelease(g_macdH);
   if(g_stochH   != INVALID_HANDLE) IndicatorRelease(g_stochH);
   if(g_bandsH   != INVALID_HANDLE) IndicatorRelease(g_bandsH);
   if(g_adxH     != INVALID_HANDLE) IndicatorRelease(g_adxH);
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
      ResetDay(today);

   //--- Money-based exit runs on every tick (the only way trades close).
   ManageMoneyExit();

   //--- Optional daily loss circuit breaker.
   if(!g_dayBlocked && InpDailyLossLimit > 0.0 && g_dayStartEquity > 0.0)
     {
      double pct = (AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartEquity) / g_dayStartEquity * 100.0;
      if(pct <= -InpDailyLossLimit)
        {
         g_dayBlocked = true;
         PrintFormat("Daily loss limit hit (%.2f%%). No new trades today.", pct);
        }
     }

   //--- Evaluate entries once per closed bar.
   datetime barTime = (datetime)SeriesInfoInteger(_Symbol, InpTimeframe, SERIES_LASTBAR_DATE);
   if(barTime != g_lastBarTime)
     {
      g_lastBarTime = barTime;
      EvaluateEntry();
     }

   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| Reset the per-day state                                          |
//+------------------------------------------------------------------+
void ResetDay(const datetime today)
  {
   g_currentDay     = today;
   g_dayBlocked     = false;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
  }

//+------------------------------------------------------------------+
//| Close our positions at the money target (or emergency stop)      |
//+------------------------------------------------------------------+
void ManageMoneyExit()
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

      double money = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();

      if(money >= InpProfitTargetUSD)
        {
         if(trade.PositionClose(ticket))
            PrintFormat("Target hit: closed #%I64u at +$%.2f", ticket, money);
        }
      else if(InpUseEmergencyStop && money <= -MathAbs(InpEmergencyLossUSD))
        {
         if(trade.PositionClose(ticket))
            PrintFormat("EMERGENCY stop: closed #%I64u at $%.2f", ticket, money);
        }
     }
  }

//+------------------------------------------------------------------+
//| Tally the confluence votes and enter if a side has enough        |
//+------------------------------------------------------------------+
void EvaluateEntry()
  {
   if(g_dayBlocked) return;
   if(InpUseSession && !InSession()) return;
   if(CountOpenPositions() >= InpMaxPositions) return;
   if(g_lastTradeTime > 0 && (TimeCurrent() - g_lastTradeTime) < InpMinSecondsBetween) return;
   if(!SpreadOK()) return;

   int buyVotes = 0, sellVotes = 0;
   double close = iClose(_Symbol, InpTimeframe, 1);

   //--- 1) EMA trend
   if(InpUseEma)
     {
      double f[], s[];
      ArraySetAsSeries(f, true); ArraySetAsSeries(s, true);
      if(CopyBuffer(g_emaFastH, 0, 1, 1, f) < 1) return;
      if(CopyBuffer(g_emaSlowH, 0, 1, 1, s) < 1) return;
      if(f[0] > s[0]) buyVotes++; else if(f[0] < s[0]) sellVotes++;
     }
   //--- 2) RSI vs midline
   if(InpUseRsi)
     {
      double r[]; ArraySetAsSeries(r, true);
      if(CopyBuffer(g_rsiH, 0, 1, 1, r) < 1) return;
      if(r[0] > 50.0) buyVotes++; else if(r[0] < 50.0) sellVotes++;
     }
   //--- 3) MACD main vs signal
   if(InpUseMacd)
     {
      double m[], sg[];
      ArraySetAsSeries(m, true); ArraySetAsSeries(sg, true);
      if(CopyBuffer(g_macdH, 0, 1, 1, m)  < 1) return;
      if(CopyBuffer(g_macdH, 1, 1, 1, sg) < 1) return;
      if(m[0] > sg[0]) buyVotes++; else if(m[0] < sg[0]) sellVotes++;
     }
   //--- 4) Stochastic %K vs %D
   if(InpUseStoch)
     {
      double k[], d[];
      ArraySetAsSeries(k, true); ArraySetAsSeries(d, true);
      if(CopyBuffer(g_stochH, 0, 1, 1, k) < 1) return;
      if(CopyBuffer(g_stochH, 1, 1, 1, d) < 1) return;
      if(k[0] > d[0]) buyVotes++; else if(k[0] < d[0]) sellVotes++;
     }
   //--- 5) Price vs Bollinger middle
   if(InpUseBands)
     {
      double mid[]; ArraySetAsSeries(mid, true);
      if(CopyBuffer(g_bandsH, 0, 1, 1, mid) < 1) return;
      if(close > mid[0]) buyVotes++; else if(close < mid[0]) sellVotes++;
     }
   //--- 6) ADX directional (only when a trend is present)
   if(InpUseAdx)
     {
      double adx[], plus[], minus[];
      ArraySetAsSeries(adx, true); ArraySetAsSeries(plus, true); ArraySetAsSeries(minus, true);
      if(CopyBuffer(g_adxH, 0, 1, 1, adx)   < 1) return;
      if(CopyBuffer(g_adxH, 1, 1, 1, plus)  < 1) return;
      if(CopyBuffer(g_adxH, 2, 1, 1, minus) < 1) return;
      if(adx[0] >= InpAdxMin)
        {
         if(plus[0] > minus[0]) buyVotes++; else if(plus[0] < minus[0]) sellVotes++;
        }
     }

   //--- Decide: the side with enough agreeing votes and a clear majority.
   if(buyVotes >= InpMinConfirmations && buyVotes > sellVotes)
      OpenTrade(ORDER_TYPE_BUY, buyVotes, sellVotes);
   else if(sellVotes >= InpMinConfirmations && sellVotes > buyVotes)
      OpenTrade(ORDER_TYPE_SELL, sellVotes, buyVotes);
  }

//+------------------------------------------------------------------+
//| Open a market order with NO stop loss and NO take profit         |
//| (the trade is closed by the money target instead).               |
//+------------------------------------------------------------------+
void OpenTrade(const ENUM_ORDER_TYPE type, const int forVotes, const int againstVotes)
  {
   double price = (type == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lots = NormalizeLots(InpLots);

   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lots, _Symbol, price, 0.0, 0.0, InpComment)
             : trade.Sell(lots, _Symbol, price, 0.0, 0.0, InpComment);

   if(ok)
     {
      g_lastTradeTime = TimeCurrent();
      PrintFormat("%s %.2f lots @ %.*f  | confluence %d vs %d (need %d)",
                  (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), lots, _Digits, price,
                  forVotes, againstVotes, InpMinConfirmations);
     }
   else
      PrintFormat("Order failed: %d - %s",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
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
//| Session window check                                             |
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
//| Spread check (points)                                            |
//+------------------------------------------------------------------+
bool SpreadOK()
  {
   if(InpMaxSpreadPoints <= 0)
      return(true);
   return(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPoints);
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
//| Midnight of the day a timestamp belongs to                       |
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
   double openMoney = 0.0;
   int    openCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !posInfo.SelectByTicket(ticket))
         continue;
      if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
        {
         openMoney += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
         openCount++;
        }
     }

   string state = g_dayBlocked ? "HALTED (daily limit)"
                  : (InpUseSession && !InSession()) ? "outside session" : "active";

   string txt = StringFormat(
      "GoldConfluenceScalper  [%s %s]\n"
      "State: %s\n"
      "Target: +$%.2f   Stop loss: %s\n"
      "Confirmations needed: %d\n"
      "Open: %d/%d   Floating: $%.2f",
      _Symbol, EnumToString(InpTimeframe), state,
      InpProfitTargetUSD, (InpUseEmergencyStop ? StringFormat("emergency $-%.0f", MathAbs(InpEmergencyLossUSD)) : "NONE"),
      InpMinConfirmations, openCount, InpMaxPositions, openMoney);
   Comment(txt);
  }
//+------------------------------------------------------------------+
