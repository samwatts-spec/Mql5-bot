# MetaTrader 5 Expert Advisors

This repo contains two **independent** MetaTrader 5 Expert Advisors. They
share nothing and each only manages its own orders (by magic number):

- **GoldScalperPro** — a dedicated XAUUSD (gold) scalper. *(See below.)*
- **Asian Session Breakout** — a Tokyo-session range breakout EA.

---

# GoldScalperPro EA

A dedicated **gold (XAUUSD) scalping** Expert Advisor. It trades *with* the
trend and buys dips / sells rallies, sized off a fixed % of equity so a small
account never over-leverages a single trade.

## What it does

1. A slow EMA defines the trend; the EA only trades in that direction.
2. It waits for a pullback to the fast EMA where RSI turns back out of an
   oversold (long) / overbought (short) extreme.
3. An ATR filter blocks dead, low-volatility conditions, and ATR-based
   stops/targets adapt to current gold volatility.
4. **Position size comes from a % risk of equity** and the stop distance, so
   each trade risks a known, fixed fraction of the account.
5. Risk caps: hard daily-loss / daily-profit circuit breakers, a max
   trades-per-day limit, a max concurrent positions limit, a spread guard and
   a trading-session window.
6. Optional break-even and trailing-stop management.

## Installing into MetaTrader 5

1. Copy `MQL5/Experts/GoldScalperPro.mq5` into your terminal's `MQL5\Experts`
   folder (in MT5: **File → Open Data Folder**, then `MQL5\Experts`).
2. Open **MetaEditor** (F4), find the file in the Navigator, and **Compile**
   (F7) to produce `GoldScalperPro.ex5`.
3. Refresh **Navigator → Expert Advisors** in MT5 and drag it onto an
   **XAUUSD** chart (M5 by default).
4. Enable **Algo Trading** and allow automated trading in the EA dialog.

## Key inputs

| Input | Meaning |
|-------|---------|
| `InpTimeframe` | Working timeframe (default M5) |
| `InpFastEmaPeriod` / `InpSlowEmaPeriod` | Pullback level / trend filter |
| `InpRsiPeriod` / `InpRsiBuyLevel` / `InpRsiSellLevel` | RSI signal thresholds |
| `InpPullbackPoints` | Max distance price→fast EMA to allow an entry |
| `InpAtrPeriod` / `InpMinAtrPoints` | Volatility filter |
| `InpMaxSpreadPoints` | Block entries when spread is too wide |
| `InpSizingMode` | Fixed lot or risk-% of equity |
| `InpRiskPercent` / `InpFixedLots` | Risk per trade / fixed lot size |
| `InpStopMode` | SL/TP as ATR multiple or fixed points |
| `InpAtrSLMult` / `InpAtrTPMult` | SL/TP as ATR multiples |
| `InpUseBreakEven` / `InpUseTrailing` | Optional exit management |
| `InpMaxPositions` / `InpMaxTradesPerDay` | Trade-frequency caps |
| `InpDailyLossLimit` / `InpDailyProfitTarget` | Daily circuit breakers (% equity) |
| `InpUseSession` / `InpSessionStartHour` / `InpSessionEndHour` | Trading window (server time) |
| `InpMagicNumber` | Identifies this EA's orders |

> **Small-account note:** the defaults risk 1% of equity per trade and halt
> for the day after a 5% loss. On a very small account the broker minimum lot
> (often 0.01) may risk *more* than your chosen %; the EA never goes below the
> broker minimum, so verify the real per-trade risk in the Strategy Tester
> before going live.

---

# Asian Session Breakout EA

A MetaTrader 5 Expert Advisor that trades the breakout of the Asian (Tokyo)
session range.

## What it does

1. During the Asian session window (server time) it records the session's
   high and low.
2. When the session closes it arms a **Buy Stop** above the high and a
   **Sell Stop** below the low, each with a buffer.
3. When one order is triggered, the opposite pending order is cancelled
   (One-Cancels-the-Other).
4. Each position gets a stop loss and take profit, with optional break-even
   and trailing stop.
5. State resets every new trading day, so only one breakout is armed per day.
   Un-triggered orders are cancelled at the daily cut-off hour.

## Installing into MetaTrader 5

1. Copy `MQL5/Experts/AsianSessionBreakout.mq5` into your terminal's
   `MQL5\Experts` folder.
   - In MT5: **File → Open Data Folder**, then go to `MQL5\Experts`.
2. Open **MetaEditor** (F4 in MT5), find the file in the Navigator, and press
   **Compile** (F7). This produces `AsianSessionBreakout.ex5`.
3. Back in MT5, refresh the **Navigator → Expert Advisors** list, then drag
   the EA onto a chart.
4. Enable **Algo Trading** (the toolbar button) and allow automated trading
   in the EA dialog.

## Key inputs

| Input | Meaning |
|-------|---------|
| `InpSessionStartHour/Min` | Asian session start (server time) |
| `InpSessionEndHour/Min`   | Asian session end (server time) |
| `InpLots`                 | Fixed lot size |
| `InpBufferPoints`         | Distance above/below the range for the stop orders |
| `InpMinRangePoints` / `InpMaxRangePoints` | Skip days with too small/large a range |
| `InpTradeStopHour`        | Cancel un-triggered orders at this hour |
| `InpSLTPMode`             | SL/TP as fixed points or a multiple of the range |
| `InpStopLoss` / `InpTakeProfit` | SL/TP value (points or range factor) |
| `InpUseBreakEven` / `InpUseTrailing` | Optional exit management |
| `InpMaxSpreadPoints`      | Block entries when the spread is too wide |
| `InpMagicNumber`          | Identifies this EA's orders |

> **Note on session times:** MT5 uses your *broker's* server time, which is
> usually not your local time. Check the server clock in the Market Watch and
> set the session hours accordingly. The Tokyo session is roughly 00:00–09:00
> Tokyo time (≈ 23:00–08:00 UTC depending on DST).

## Disclaimer

Test on a **demo account** and in the **Strategy Tester** before risking real
funds. Trading carries risk; this EA is provided as-is with no guarantee of
profitability.
