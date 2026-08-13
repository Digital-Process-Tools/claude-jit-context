---
title: PHP conventions
match: \.php$
---

Always `declare(strict_types=1)` after the opening tag.

Concrete implementations are `final`. Type everything — parameters, return types
and properties. An untyped property is a bug waiting for a null.
