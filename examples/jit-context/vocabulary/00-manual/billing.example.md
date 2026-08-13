---
title: Billing amounts
description: How invoice totals are computed, and why the entity getter lies.
keywords: billing, invoice, vat, amount vat out
---

Totals are **not** stored. `getAmountVatOut()` is overridden by `BillingTotalsTrait`
and recomputed from the line items on every call (`src/Billing/Totals.php:88`).

Writing to `amount_vat_out` directly appears to work — and is silently discarded on
the next read.

`amount` and `total` are not keywords here, and that is the point of this line. A
keyword is matched whole-word against the prompt, and the whole file is injected on a
hit — so `give me the total number of tests` would pull this entry into a session about
nothing of the sort, once per session, for as long as the entry exists. Key on the nouns
that only your product uses, and reach for a multi-word key like `amount vat out` when
the single word is ordinary English.

## Modules

Billing
