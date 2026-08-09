---
title: Billing amounts
description: How invoice totals are computed, and why the entity getter lies.
keywords: billing, invoice, amount, vat, total
---

Totals are **not** stored. `getAmountVatOut()` is overridden by `BillingTotalsTrait`
and recomputed from the line items on every call (`src/Billing/Totals.php:88`).

Writing to `amount_vat_out` directly appears to work — and is silently discarded on
the next read.

## Modules

Billing
