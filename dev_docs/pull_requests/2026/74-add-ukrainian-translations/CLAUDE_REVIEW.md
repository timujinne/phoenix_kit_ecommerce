# PR #74: Add Ukrainian (uk) translations

- **Author:** Tymofii Shapovalov (@timujinne)
- **Reviewer:** Claude
- **Branch:** `timujinne:add-uk-locale` → `main` · head `eca408c` · up to date with `main` (`1a168f1`), mergeable
- **Files:** 3 (+4,954 / −2): `priv/gettext/uk/LC_MESSAGES/default.po` (new),
  `test/phoenix_kit_ecommerce/i18n_test.exs`, `AGENTS.md`
- **Verdict:** **REQUEST CHANGES.** The catalogue is complete and the storefront and checkout read naturally in
  Ukrainian. Four plural entries hard-code "1" and show the wrong number for 21, 31, 101…, and the file was
  not produced by `mix gettext.merge` as described. Both fixes are small; the rest are wording notes.

## Scope

A `uk` catalogue for all 1,097 msgids of `default.pot`, `uk` added to `@translated_locales` (so the
completeness test covers it), and the AGENTS.md gettext note. `mix.exs` and `CHANGELOG.md` are untouched,
which is correct: AGENTS.md:695 says version bumps and CHANGELOG entries land with the release commit.
`package files:` (`mix.exs:282`) ships `priv/gettext`, so `uk` reaches Hex.

## Verified

All entries were checked by a standalone `.po` parser (`python3 -I`), not a sample. The parser was first run
against a deliberately broken file to confirm it catches each defect class.

- **Header:** `Language: uk` and a three-form `Plural-Forms`, evaluated for n = 0…10,000; it matches the
  Ukrainian rule.
- **Coverage:** 1,097/1,097 msgids against `default.pot`. No extras, duplicates, obsolete entries, empty
  `msgstr` or `fuzzy`. All 55 plural entries have `msgstr[0..2]`.
- **Placeholders and markup:** `%{…}`, `{{…}}`, `%s`/`%d`, HTML tags (`<p>…</p>`), Markdown `**…**` and link
  targets, backtick code, URLs, `\n` counts and edge whitespace all match. The one exception is finding 1:
  plural forms were checked against `msgid_plural`, because Ukrainian form 0 also serves 21, 31, 101…
- **Script hygiene:** no Russian-only letters, no Latin/Cyrillic homoglyph words, apostrophe `'`, «…» quotes.
- **Glossary:** кошик, оформлення замовлення, спосіб доставки, проміжна сума, разом, стара ціна, виробник and
  артикул (SKU) are used consistently. The checkout step "Billing" is «Платіжні дані» and «Далі: платіжні
  дані», where the glossary says «оплата». That deviation is documented in the PR and works.
- **Tests:** `MIX_ENV=test PGDATABASE=pkecom_test_domovych_uk PGPOOL=10 mix test
  test/phoenix_kit_ecommerce/i18n_test.exs` → 17 tests, 0 failures.

## Findings

### BUG - MEDIUM: four plural entries hard-code "1", so 21, 31, 101… items read as one

In Ukrainian, form 0 is used for every number ending in 1 except 11 (1, 21, 31, 101…). These four entries
put a literal «1», or no number at all, into `msgstr[0]`. Runtime check
(`Gettext.dngettext(PhoenixKitEcommerce.Gettext, "default", "1 product", …)` under `uk`): n = 21 → **«1 товар»**,
n = 101 → **«1 товар»**. The Products page header (`web/products.ex:294`) therefore says «1 товар» for a shop
with 21 products. The other locales do this correctly: `ru` has «%{count} товар».

| line | msgid / msgid_plural | current `msgstr[0]` | proposed `msgstr[0]` |
|---|---|---|---|
| default.po:122 | 1 category / %{count} categories | 1 категорія | %{count} категорія |
| default.po:129 | 1 day / %{count} days | 1 день | %{count} день |
| default.po:136 | 1 product / %{count} products | 1 товар | %{count} товар |
| default.po:3585 | Apply the selected %{field} change from Shopify? / Apply %{count} selected … | Застосувати вибрану зміну поля «%{field}» з Shopify? | Застосувати %{count} вибрану зміну поля «%{field}» із Shopify? |

The PR's "placeholders were machine-checked against each msgid" passed these because form 0 was compared with
the singular msgid, which has no `%{count}`. Note that `:2321` ("1 item" → «%{count} товар») already does it
right. Adding a plural-aware check (form 0 must carry the `msgid_plural` bindings) to `i18n_test.exs`
would catch the next one.

### IMPROVEMENT - MEDIUM: not the output of `mix gettext.merge`: all 1,095 `#,` flags are missing

`default.pot` and every other locale carry `#, elixir-autogen, elixir-format` (1,095 entries); `uk/default.po`
has none. Re-running the merge the PR cites (`mix gettext.merge <copy> --locale uk --no-fuzzy`) reports "0 new,
0 removed, 1097 unchanged", and the result differs from the committed file **only** by +1,095 flag lines. The
next unrelated `gettext.extract --merge` will put those 1,095 lines into someone else's diff. **Fix:** run the
merge and commit it. No translation changes (verified).

### IMPROVEMENT - MEDIUM: "Reprice" → «Переоцінити» is ambiguous in the shopper's cart

`default.po:3870` Reprice at the current rate → «Переоцінити за поточним курсом», `:3874` «Не вдалося
переоцінити кошик», `:3886` «…доки ви не переоціните кошик». «Переоцінити» primarily means "to overestimate",
and «переоцінити кошик» reads that way. The neighbouring `:3882` already says «Ціни у вашому кошику
перераховано за поточним курсом».

| line | msgid | current | proposed |
|---|---|---|---|
| 3870 | Reprice at the current rate | Переоцінити за поточним курсом | Перерахувати за поточним курсом |
| 3874 | The cart could not be repriced — please try again | Не вдалося переоцінити кошик — спробуйте ще раз | Не вдалося перерахувати ціни в кошику — спробуйте ще раз |
| 3886 | …Your prices stay as shown unless you reprice. | …доки ви не переоціните кошик. | …доки ви не перерахуєте їх. |

### NITPICK: language polish (ecommerce)

**Storefront and checkout**

| line | msgid | current | proposed |
|---|---|---|---|
| 2913 | Proceed to Checkout | Перейти до оформлення замовлення (32 chars, the cart's main button) | Оформити замовлення |
| 2551 | Please complete the billing address - a physical order needs one | …— для фізичного замовлення вона обов'язкова | …— для замовлення з фізичними товарами вона обов'язкова |
| 3071 | Checking out as a guest | Оформлення як гість | Ви оформлюєте замовлення як гість |
| 3067 | An account with this email is already registered. … | Обліковий запис із цією електронною поштою вже зареєстровано. … | Обліковий запис із цією адресою email уже зареєстровано. … (as `:2176`) |

**Admin**

| line | msgid | current | proposed |
|---|---|---|---|
| 176, 555, 151, 849, 1163 | cart status filter: Active / Converted / Abandoned / Expired / Merged | Активний / Конвертовано / Покинуті / Прострочено / Об'єднано (three grammatical forms in one dropdown) | Активні / Оформлені / Покинуті / Прострочені / Об'єднані (or all singular masculine; "Active" is shared, so make the others agree with it) |
| 3714 | Pending changes | Відкладені зміни ("postponed") | Незастосовані зміни |
| 857 | Failed (migration stat title, over a number) | Не вдалося | Невдалих |
| 253 | Analyze & Configure (button) | Аналіз і налаштування | Проаналізувати й налаштувати |
| 811 | Editable (badge) | Редагований ("edited") | Можна змінювати |
| 1135 | Label (option display name) | Мітка | Підпис |
| 492 vs 3894 | Charge tax on this product / … item | Стягувати податок із цього товару / Нараховувати податок на цей товар | use one: Нараховувати податок на цей товар |
| 306 | Auto-generated from title | Генерується із заголовка | Генерується з назви (`:1546` Product title → «Назва товару») |
| 4740 vs 4815 | New in Shopify (%{count}) / New in Shopify | Нові в Shopify / Нове в Shopify | pick one, e.g. Нові в Shopify |
| 428, 460, 969, 1263 vs 1737 | Category Icons, Folder icon, No icons… vs Show icons next to category names… | іконки … vs значки | one term throughout (core uses «піктограма») |
| 1503 | Pricing | Ціноутворення ("price formation") | Ціни |
| 1637 | SEO-friendly URL for this language | SEO-зручний URL … | SEO-оптимізований URL … |
| 641 | Define options specific to this category… | …опції, специфічні для цієї категорії… | …опції, властиві лише цій категорії… |
| 1721 | Shopify or Prom.ua CSV format, max 50MB | Формат Shopify або Prom.ua CSV, макс. 50 МБ | CSV у форматі Shopify або Prom.ua, макс. 50 МБ |
| 2374 vs 3215 | Leave as "Default"… / Default | Залиште «Типове»… / За замовчуванням | quote the label as it appears: Залиште «За замовчуванням»… |

**Consistency with core and billing (pick one each):**
- Order status "Pending": ecommerce `:1425` «Очікує», billing «В очікуванні».
- "Street address": ecommerce checkout `:3331` «Вулиця, будинок», billing profile form «Адреса», core «Вулиця й
  будинок». A customer fills in both forms.
- Default currency: ecommerce `:3862` «Основну валюту не налаштовано», `:4030` «основна валюта» for *base*
  currency, while billing uses «валюта за замовчуванням» (default) and «базова» (base).
- Customer: «клієнт» (`:629`, billing) vs «покупець» (`:2180`, `:2378`). Both are fine, «покупець» on the
  storefront and «клієнт» in the admin, but it is mixed within the admin settings text.

## Not flagged (checked)

The cart, checkout, order-confirmation and storefront strings are natural and correct. The «Показано
%{shown} із %{total} товару/товарів» genitive forms (`:3317`, `:3134`), «Знайдено %{count} позицію/послугу»
(accusative), «Проміжна сума (%{count} товар)», the stock and option errors with their `\n`, and the
guest-checkout account notices are all right.

---

## Round 2 (2026-10-09): head `e7e239d`

- **Verdict:** **APPROVE.** Every round-1 finding is closed, the new test proves it catches the original bug,
  and the wording changes introduced no regressions. One NITPICK about where the new test sits; it does not
  block.

### Verified

- **Branch.** It is up to date with `main` (`1a168f1`), and the diff against `main` is the declared files plus
  `dev_docs/pull_requests/2026/74-add-ukrainian-translations/CLAUDE_REVIEW.md` (the round-1 review).
- **Literal `mix gettext.merge` output.** Re-running the merge on a copy reports "0 new, 0 removed, 1097
  unchanged" and produces a byte-identical file.
- **Full checker re-run.** 1,097/1,097 entries, 0 errors. Every form of all 55 plural entries carries the
  `msgid_plural` bindings. The language heuristics show no new hits.
- **Tests.** `MIX_ENV=test PGDATABASE=pkecom_test_domovych_uk PGPOOL=10 mix test
  test/phoenix_kit_ecommerce/i18n_test.exs` → 18 tests, 0 failures.
- **The new test catches the real bug.** I extracted its logic and ran it against the round-1 catalogue
  (`eca408c`). It reports exactly `[{"1 category", "msgstr[0]"}, {"1 day", "msgstr[0]"}, {"1 product",
  "msgstr[0]"}, {"Apply the selected %{field} change from Shopify?", "msgstr[0]"}]`. Against the current
  catalogue it reports `[]`.
- **Runtime under `uk`.** n = 21 → «21 товар», «21 категорія», «Застосувати 21 вибрану зміну поля «Ціна»
  із Shopify?»; n = 101 → «101 товар».

### Round-1 findings

| finding | status |
|---|---|
| BUG: four plural entries hard-code "1" | **closed**, and guarded by `i18n_test.exs` ("every uk plural form carries the msgid_plural's %{count}") |
| IMPROVEMENT: `#,` flags stripped | **closed.** Byte-identical to merge output |
| IMPROVEMENT: «Переоцінити» | **closed.** «Перерахувати ціни за поточним курсом», «…перерахувати ціни в кошику…», «…доки ви не перерахуєте їх.» |
| NITPICK: storefront (Proceed to Checkout, physical order, guest, email) | **applied.** «Оформити замовлення» etc. |
| NITPICK: cart status filter | **applied.** All masculine singular, agreeing with «кошик»: «Активний / Оформлений / Покинутий / Прострочений / Об'єднаний» (each msgid except the shared "Active" is used only in `carts.ex:144-148`) |
| NITPICK: admin wording table | **applied in full**, including «Невдалі», «Проаналізувати й налаштувати», «Можна змінювати», «Підпис», «піктограми» throughout, «Нараховувати податок…», «Ціни», «Нові в Shopify», «За замовчуванням» |
| Consistency with core and billing | **aligned.** "Pending" «Очікує» in both modules; "Street address" «Вулиця, будинок» in all three; «валюта за замовчуванням» for default and «базова» for base currency, matching billing |

### NITPICK: the new test was inserted under the fuzzy test's comment

`test/phoenix_kit_ecommerce/i18n_test.exs:180-186`. The three-line comment that explains the fuzzy test
("Fuzzy entries ship. The completeness check above only looks at empty msgstrs…") now runs straight into the
plural comment and sits above the new plural test. The fuzzy test at `:199` is left without its explanation.
Move the new test (with its own comment) below the fuzzy test, or move the fuzzy comment back down.

---

## Round 3 (2026-10-09): head `9cb4619`

- **Verdict:** **APPROVE** (confirmed; the round-2 NITPICK is fixed).
- **The NITPICK is closed.** In `c12338e` the fuzzy test returns directly under its own comment
  (`i18n_test.exs:180-191`), and the uk plural test follows with its own comment. The test bodies are
  unchanged; the commit only moves code.
- **Diff against `main` (`1a168f1`):** the declared files plus the review file (byte-identical to rounds 1–2).
  GitHub reports `MERGEABLE`.
- **Re-checked:** the catalogue is byte-identical to `mix gettext.merge` output (1097 unchanged); checker 0
  errors; `MIX_ENV=test PGDATABASE=pkecom_test_domovych_uk PGPOOL=10 mix test
  test/phoenix_kit_ecommerce/i18n_test.exs` → 18 tests, 0 failures.
