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
