//+------------------------------------------------------------------+
//|                                        AsianSessionBreakout.mq5   |
//|                                                                  |
//|   Asian (Tokyo) session range breakout Expert Advisor.           |
//|                                                                  |
//|   Strategy                                                       |
//|   --------                                                       |
//|   1. During the Asian session window the EA records the highest  |
//|      high and lowest low (the "session range").                  |
//|   2. When the session closes it places a Buy Stop a few points   |
//|      above the range high and a Sell Stop a few points below the |
//|      range low (a One-Cancels-the-Other style breakout).         |
//|   3. As soon as one pending order is triggered the opposite      |
//|      pending order is deleted.                                   |
//|   4. Stop loss / take profit are attached to each order, with    |
//|      an optional break-even and trailing stop.                   |
//|   5. State resets at the start of every new trading day so only  |
//|      one breakout setup is armed per day.                        |
//|                                                                  |
//|   All times are broker/server time.                              |
//+------------------------------------------------------------------+
#property copyright "Sam Watts"
#property version   "1.00"
#property strict
#property description "Asian session range breakout EA for MetaTrader 5."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- Stop loss / take profit calculation mode
enum ENUM_SLTP_MODE
  {
   SLTP_POINTS,        // Fixed distance in points
   SLTP_RANGE_FACTOR   // Multiple of the session range
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Session window (server time) ==="
input int            InpSessionStartHour = 0;     // Session start hour (0-23)
input int            InpSessionStartMin  = 0;     // Session start minute (0-59)
input int            InpSessionEndHour   = 8;     // Session end hour (0-23)
input int            InpSessionEndMin    = 0;     // Session end minute (0-59)

input group "=== Order placement ==="
input double         InpLots             = 0.10;  // Lot size
input int            InpBufferPoints     = 20;    // Buffer above/below range (points)
input int            InpMinRangePoints   = 50;    // Skip day if range smaller than this (points)
input int            InpMaxRangePoints   = 1000;  // Skip day if range larger than this (0 = no limit)
input int            InpTradeStopHour    = 20;    // Cancel un-triggered orders at this hour
input bool           InpOneCancelsOther  = true;  // Delete opposite order when one fills

input group "=== Risk / exits ==="
input ENUM_SLTP_MODE InpSLTPMode         = SLTP_RANGE_FACTOR; // SL/TP mode
input double         InpStopLoss         = 1.0;   // Stop loss (points or range factor)
input double         InpTakeProfit       = 1.5;   // Take profit (points or range factor)
input bool           InpUseBreakEven     = true;  // Move SL to break-even
input int            InpBreakEvenPoints  = 200;   // Profit (points) to trigger break-even
input int            InpBreakEvenLock    = 20;    // Points locked in at break-even
input bool           InpUseTrailing      = true;  // Use trailing stop
input int            InpTrailStartPoints = 300;   // Profit (points) before trailing starts
input int            InpTrailStepPoints  = 150;   // Trailing distance (points)

input group "=== General ==="
input int            InpMaxSpreadPoints  = 30;    // Max allowed spread (points, 0 = ignore)
input long           InpMagicNumber      = 20240529; // Magic number
input string         InpComment          = "AsianBreakout"; // Order comment

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     orderInfo;

datetime g_lastSetupDay   = 0;     // day (00:00) the current setup belongs to
bool     g_ordersPlaced   = false; // pending orders placed for the current day
double   g_rangeHigh      = 0.0;
double   g_rangeLow       = 0.0;
double   g_rangeSize       = 0.0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(10);

   if(InpSessionStartHour < 0 || InpSessionStartHour > 23 ||
      InpSessionEndHour   < 0 || InpSessionEndHour   > 23 ||
      InpSessionStartMin  < 0 || InpSessionStartMin  > 59 ||
      InpSessionEndMin    < 0 || InpSessionEndMin    > 59)
     {
      Print("Invalid session time inputs.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpLots <= 0.0)
     {
      Print("Lot size must be greater than zero.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   Print("AsianSessionBreakout initialised on ", _Symbol,
         " | session ", SessionTimeString());
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   Comment("");
  }

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now      = TimeCurrent();
   datetime today    = DayStart(now);

   //--- New day: reset the daily state
   if(today != g_lastSetupDay)
     {
      g_lastSetupDay = today;
      g_ordersPlaced = false;
      g_rangeHigh    = 0.0;
      g_rangeLow     = 0.0;
      g_rangeSize    = 0.0;
     }

   MqlDateTime st;
   TimeToStruct(now, st);
   int nowMinutes = st.hour * 60 + st.min;

   int sessionStart = InpSessionStartHour * 60 + InpSessionStartMin;
   int sessionEnd   = InpSessionEndHour   * 60 + InpSessionEndMin;

   //--- Cancel any un-triggered pending orders after the trading cut-off
   if(st.hour >= InpTradeStopHour)
      DeletePendingOrders();

   //--- One-Cancels-the-Other handling
   if(InpOneCancelsOther && HasOpenPosition())
      DeletePendingOrders();

   //--- Trade management for open positions
   ManageOpenPositions();

   //--- Are we still inside the Asian session?  Nothing to arm yet.
   if(InSession(nowMinutes, sessionStart, sessionEnd))
      return;

   //--- After session close, before the cut-off, arm the breakout once.
   if(!g_ordersPlaced && nowMinutes >= sessionEnd && st.hour < InpTradeStopHour)
     {
      if(ComputeSessionRange(today, sessionStart, sessionEnd))
         PlaceBreakoutOrders();
     }

   UpdateDashboard();
  }

//+------------------------------------------------------------------+
//| True while the clock is inside the session window                |
//+------------------------------------------------------------------+
bool InSession(const int nowMin, const int startMin, const int endMin)
  {
   if(startMin == endMin)
      return(false);
   if(startMin < endMin)            // same-day session, e.g. 00:00-08:00
      return(nowMin >= startMin && nowMin < endMin);
   //--- session that wraps past midnight, e.g. 23:00-06:00
   return(nowMin >= startMin || nowMin < endMin);
  }

//+------------------------------------------------------------------+
//| Compute the high/low of the just-closed session from M1 bars     |
//+------------------------------------------------------------------+
bool ComputeSessionRange(const datetime today, const int startMin, const int endMin)
  {
   //--- Build the absolute session start/end timestamps.
   datetime sessStart = today + startMin * 60;
   datetime sessEnd   = today + endMin   * 60;
   if(endMin <= startMin)           // wrapped session ends the next day
      sessEnd += 86400;

   //--- A wrapped session that started "yesterday" relative to now.
   datetime now = TimeCurrent();
   if(sessStart > now)
     {
      sessStart -= 86400;
      sessEnd   -= 86400;
     }

   double hi = -DBL_MAX;
   double lo =  DBL_MAX;

   MqlRates rates[];
   int copied = CopyRates(_Symbol, PERIOD_M1, sessStart, sessEnd, rates);
   if(copied <= 0)
     {
      Print("Could not copy M1 rates for the session range.");
      return(false);
     }

   for(int i = 0; i < copied; i++)
     {
      if(rates[i].time < sessStart || rates[i].time >= sessEnd)
         continue;
      if(rates[i].high > hi) hi = rates[i].high;
      if(rates[i].low  < lo) lo = rates[i].low;
     }

   if(hi <= 0.0 || lo >= DBL_MAX || hi <= lo)
     {
      Print("Invalid session range computed.");
      return(false);
     }

   double rangePoints = (hi - lo) / _Point;
   if(rangePoints < InpMinRangePoints)
     {
      Print("Session range ", DoubleToString(rangePoints, 0),
            " pts below minimum (", InpMinRangePoints, ") - skipping day.");
      g_ordersPlaced = true;       // mark as handled so we don't retry all day
      return(false);
     }
   if(InpMaxRangePoints > 0 && rangePoints > InpMaxRangePoints)
     {
      Print("Session range ", DoubleToString(rangePoints, 0),
            " pts above maximum (", InpMaxRangePoints, ") - skipping day.");
      g_ordersPlaced = true;
      return(false);
     }

   g_rangeHigh = hi;
   g_rangeLow  = lo;
   g_rangeSize = hi - lo;
   return(true);
  }

//+------------------------------------------------------------------+
//| Place the Buy Stop / Sell Stop breakout orders                   |
//+------------------------------------------------------------------+
void PlaceBreakoutOrders()
  {
   if(!SpreadOK())
     {
      Print("Spread too wide, postponing order placement.");
      return;
     }

   double buffer   = InpBufferPoints * _Point;
   double buyPrice  = NormalizeDouble(g_rangeHigh + buffer, _Digits);
   double sellPrice = NormalizeDouble(g_rangeLow  - buffer, _Digits);

   double slDist = StopDistance(InpStopLoss);
   double tpDist = StopDistance(InpTakeProfit);

   double buySL = (slDist > 0) ? NormalizeDouble(buyPrice - slDist, _Digits) : 0.0;
   double buyTP = (tpDist > 0) ? NormalizeDouble(buyPrice + tpDist, _Digits) : 0.0;
   double selSL = (slDist > 0) ? NormalizeDouble(sellPrice + slDist, _Digits) : 0.0;
   double selTP = (tpDist > 0) ? NormalizeDouble(sellPrice - tpDist, _Digits) : 0.0;

   //--- Orders expire at the trading cut-off of the current day.
   datetime expiry = DayStart(TimeCurrent()) + InpTradeStopHour * 3600;
   if(expiry <= TimeCurrent())
      expiry += 86400;

   double lots = NormalizeLots(InpLots);

   bool okBuy = trade.BuyStop(lots, buyPrice, _Symbol, buySL, buyTP,
                              ORDER_TIME_SPECIFIED, expiry, InpComment);
   if(!okBuy)
      Print("BuyStop failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());

   bool okSell = trade.SellStop(lots, sellPrice, _Symbol, selSL, selTP,
                                ORDER_TIME_SPECIFIED, expiry, InpComment);
   if(!okSell)
      Print("SellStop failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());

   g_ordersPlaced = true;

   PrintFormat("Breakout armed: range %.5f-%.5f (%.0f pts) | BuyStop %.5f  SellStop %.5f",
               g_rangeLow, g_rangeHigh, g_rangeSize / _Point, buyPrice, sellPrice);
  }

//+------------------------------------------------------------------+
//| Convert SL/TP input to a price distance                          |
//+------------------------------------------------------------------+
double StopDistance(const double value)
  {
   if(value <= 0.0)
      return(0.0);
   if(InpSLTPMode == SLTP_POINTS)
      return(value * _Point);
   return(value * g_rangeSize);    // SLTP_RANGE_FACTOR
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
//| Delete this EA's pending orders on the current symbol            |
//+------------------------------------------------------------------+
void DeletePendingOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(!orderInfo.Select(ticket))
         continue;
      if(orderInfo.Symbol() != _Symbol || orderInfo.Magic() != InpMagicNumber)
         continue;
      trade.OrderDelete(ticket);
     }
  }

//+------------------------------------------------------------------+
//| Is there an open position for this EA on this symbol?            |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!posInfo.SelectByTicket(ticket))
         continue;
      if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
         return(true);
     }
   return(false);
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
      lots = MathRound(lots / lotStep) * lotStep;
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
//| Human-readable session window                                    |
//+------------------------------------------------------------------+
string SessionTimeString()
  {
   return(StringFormat("%02d:%02d-%02d:%02d",
          InpSessionStartHour, InpSessionStartMin,
          InpSessionEndHour, InpSessionEndMin));
  }

//+------------------------------------------------------------------+
//| On-chart status read-out                                         |
//+------------------------------------------------------------------+
void UpdateDashboard()
  {
   string state = g_ordersPlaced ? "armed/handled" : "waiting for session close";
   string txt = StringFormat(
      "Asian Session Breakout\nSession: %s\nState: %s\nRange: %.5f - %.5f (%.0f pts)",
      SessionTimeString(), state, g_rangeLow, g_rangeHigh,
      (g_rangeSize > 0 ? g_rangeSize / _Point : 0.0));
   Comment(txt);
  }
//+------------------------------------------------------------------+
