---
title: Assertion Invariants

---

# Assertion Invariants

This document describes the invariants being protected by the assertions in this directory.


## 1. NoSelfBadDebtCreationAssertion

### Invariant: NO_SELF_BAD_DEBT_CREATION

**Description:** Any user cannot cause bad debt to himself as a result of his transaction.

**Mathematical Definition:**

```
For any user U and any transaction T that interacts with user U:

Let:
- PnL_post(U) = PnL(U) after transaction T
- Collateral_post(U) = Collateral(U) after transaction T.

Then the following invariant must hold:
Collateral_post(U) + PnL_post(U) >= 0
```

### What This Protects Against

- **Protocol bugs** that cause unexpected losses
- **Economic attacks** that intentionally produce bad debt
- **Implementation errors** in protocol operations

### What This Allows

- **Normal protocol operations** (trades, liquidity deposits and withdrawals)
- **Legitimate liquidations** Liquidations can cause bad debt without failing

### Edge Cases Handled


## 2. WorsePriceThanSpotAssertion

### Invariant: WORSE_PRICE_THAN_SPOT

**Description:** The execution price for opening a long position (or closing a short one) should always be higher than the market price, even when fees are zero. Conversely, the execution price for closing a long position or opening a short should be lower than the market price.

**Mathematical Definition:**

```
For any trade T with input tradeSize(T) and return tradeReturn(T)

Let:
- tradeDirection = True if trade is long, false if short.
- spotPrice = Oracle price.
- execPrice = tradeReturn/tradeSize if tradeDirection, else tradeSize/tradeReturn

Then the following invariant must hold:
if tradeDirection:
    execPrice > spotPrice
else:
    execPrice < spotPrice
```

### What This Protects Against

- **Protocol bugs** that cause trade misfunctioning.
- **Economic attacks** that manipulate oracle price.
- **Implementation errors** in tradeing operations.

### What This Allows

- **Normal protocol operations** (trades, liquidity deposits and withdrawals).
- **Legitimate trades** All legitimate trades should respect this invariant.

### Edge Cases Handled

- **Zero trade size** This edge case is handled at protocol level.