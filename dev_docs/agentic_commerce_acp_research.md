# Agentic Commerce / ACP — Research & Strategic Assessment

**Date:** 2026-06-14
**Author:** Claude (claude-opus-4-8)
**Status:** Research / watch-item — **no build recommended yet** (see §6)
**Trigger for this doc:** News item — *"Visa plugs its payment network into ChatGPT, letting AI agents shop and pay for users."* Max asked whether this is relevant to the PhoenixKit e-commerce/billing stack and whether we need to or can do anything.
**Companion doc (payment leg):** `phoenix_kit_billing/dev_docs/agentic_commerce_payments.md`

---

## TL;DR / Verdict

- The Visa headline is the **consumer payment-network** layer. The part that matters to **us as a merchant platform** is the layer underneath it: the **Agentic Commerce Protocol (ACP)**, co-developed by **OpenAI + Stripe** (Meta also involved), which powers ChatGPT "Instant Checkout."
- **Relevant?** Yes — `phoenix_kit_ecommerce` is a real seller/storefront, so agentic commerce is squarely in its domain. **Not a consumer-wallet concern.**
- **Need to act now?** **No.** Beta/pilot, US-centric, gated behind merchant enrollment with OpenAI. Only matters if a host app actually wants its PhoenixKit storefront discoverable/buyable inside ChatGPT and sells consumer goods people buy that way.
- **Can we?** Yes, and the architecture fits well. The **payment leg is nearly free** because `phoenix_kit_billing` already runs on Stripe (Stripe's Shared Payment Token is "one line of code" for existing Stripe merchants). The **net-new work** is a machine-facing **product feed + ACP checkout REST endpoints** in ecommerce, reusing the existing cart + `convert_cart_to_order/2` logic.
- **Recommendation:** Log as a strategic watch-item. Build only when (a) a host/customer asks to sell through ChatGPT, or (b) ACP exits beta with EU / self-serve onboarding. Cleanest shape is likely a **new bridge plugin** sitting on top of ecommerce + billing (mirrors how ecommerce sits on billing).

---

## 1. What actually happened

Two related but distinct announcements are getting blurred in the press:

1. **OpenAI + Stripe — Agentic Commerce Protocol (ACP) + ChatGPT Instant Checkout.** An open standard defining how an AI agent (ChatGPT) talks to a *merchant's* backend to find products and complete a purchase on the buyer's behalf. This is the merchant-facing substrate. Etsy is live; >1M Shopify merchants (Glossier, Skims, Vuori, …) following. (OpenAI previously shipped an earlier "Instant Checkout"; an older iteration was retired before this standardized ACP version.)
2. **Visa — Intelligent Commerce / Intelligent Commerce Connect.** The card-network layer: lets ChatGPT agents pay at (potentially) any Visa-accepting merchant, providing payment authorization + fraud monitoring at scale. Visa "Connect" offers a single integration that spans **four** agent protocols — Trusted Agent Protocol, Machine Payments Protocol, **Agentic Commerce Protocol**, and Universal Commerce Protocol — and ships an **MCP Server** + **Acceptance Agent Toolkit** for developers. Pilot partners: Aldar, AWS, Diddo, Highnote, Mesh, Payabli, Sumvin.

**Why ACP is the one that matters for us:** it's the protocol ChatGPT Instant Checkout actually uses, and its reference payment implementation is **Stripe** — which is exactly the provider `phoenix_kit_billing` already integrates.

---

## 2. The Agentic Commerce Protocol — what a merchant must implement

Per the OpenAI + Stripe specs, a merchant participating in ChatGPT Instant Checkout builds **three** things:

### 2a. Product feed
A secure, regularly refreshed (≈daily) **JSON/CSV feed** of products — identifiers/SKUs, descriptions, pricing, inventory, media, fulfillment options — **submitted to an OpenAI-provided endpoint** so ChatGPT can surface the catalog in search/shopping. (Discovery is *push to OpenAI*, not "OpenAI auto-crawls your site.")

### 2b. ACP checkout REST endpoints (agent-to-merchant, machine-to-machine)
The agent drives a programmatic checkout against the merchant's backend. Sources vary between **"four core"** and **"five"** endpoints; functionally the surface is:
- **Create checkout** — agent sends a SKU; merchant returns cart/checkout state incl. supported payment methods + fulfillment options.
- **Update checkout** — modify quantities, fulfillment method, customer details before payment.
- **Get / retrieve checkout** — current state.
- **Complete checkout** — finalize the order against a payment token.
- (Plus order-status / webhook back to the agent.)

> ⚠️ **Confirm exact endpoint set, names, payloads, and auth against the live spec before building** — sources disagreed on 4 vs 5. Canonical: `developers.openai.com/commerce/specs/checkout` and `docs.stripe.com/agentic-commerce/protocol/specification`. The ACP repo (`github.com/agentic-commerce-protocol/agentic-commerce-protocol`) is the source of truth and is in beta (moving target).

These are **token-authenticated JSON endpoints**, not browser pages. This is the key architectural delta vs. what we have today (human LiveView checkout — see §4).

### 2c. Payment integration
- **Stripe Shared Payment Token (SPT)** — a new payment primitive: after the buyer picks a payment method, Stripe issues a token **scoped to a specific merchant + cart total**; ChatGPT passes it to the merchant via API; the merchant charges it **without ever seeing raw card credentials**. SPT is the **first Delegated-Payment-Spec-compatible implementation**; for an existing Stripe merchant it's advertised as ≈**one line of code**.
- **Non-Stripe PSPs** participate via the ACP **Delegated Payments spec** / Shared Token API (broad interoperability). Visa Intelligent Commerce sits at this network layer too.

---

## 3. Where Visa fits

Visa is the **payment-network / authorization + fraud** layer, complementary to ACP's merchant surface. For *us*, Visa Intelligent Commerce is mostly relevant **only through the payment leg** — and that leg is already covered by Stripe (Visa cards flow through Stripe today). We would not integrate Visa's APIs directly unless we wanted card-network-native agentic tokens independent of a PSP, which is out of scope for this stack. Visa's MCP Server / Acceptance Agent Toolkit are dev conveniences, not a requirement for ACP-via-Stripe.

---

## 4. Mapping onto PhoenixKit (current state + gaps)

### What we already have (assets)
- **`phoenix_kit_ecommerce` ("shop")** — full storefront: products, categories, carts (`Cart`/`CartItem`, guest+user via `ShopSession` plug), shipping methods, and **`Shop.convert_cart_to_order/2`** (`lib/phoenix_kit_ecommerce.ex:2185`) which already does cart→order conversion (persisting the applied `tax_rate`). The product/category/price/options model needed for a feed already exists.
- **`phoenix_kit_billing` ("billing")** — payments behind a clean `Providers.Provider` behaviour (9 callbacks). **Stripe is the primary provider** (`lib/phoenix_kit_billing/providers/stripe.ex`): `create_checkout_session`, `charge_payment_method` (PaymentIntent off a saved method), refunds, **signed webhooks with idempotency** (duplicate → `:duplicate_event`). PayPal / Razorpay / EveryPay also implemented.
- **Order/invoice/transaction** lifecycle + multi-currency + tax already modeled in billing.

### Gaps (net-new work, by side)

| Side | Gap | Notes |
|------|-----|-------|
| **Discovery** | No product **feed** serializer/endpoint in ACP shape, nor a job to push it to OpenAI | Products already have title/slug/desc/price/images/SEO/status; a feed builder is largely a serializer + an Oban push job. Reuse `Product` + `SlugResolver`. |
| **Checkout** | No **machine-facing checkout API.** Today checkout is human LiveView pages (`/checkout`, `CheckoutPage`) with session-based carts via `ShopSession` | Needs token-authed JSON endpoints (create/update/get/complete) that drive the *existing* cart + `convert_cart_to_order/2` headlessly. This is the bulk of the work. |
| **Payment** | No SPT / delegated-payment path | **Cheapest part** — extend the billing `Provider` behaviour (or add a thin SPT path on the Stripe provider). See companion billing doc. |
| **Auth/security** | ACP endpoints are unauthenticated-by-session — they use bearer tokens + request signing from the agent | New concern: verify agent requests, idempotency on `complete`, replay protection. Billing already has the webhook-signature/`CacheBodyReader` pattern to model on. |

---

## 5. Feasibility & recommended shape (if/when we build)

The architecture is **well-suited** — additive, not a rewrite:

1. **Payment leg (small):** add SPT/delegated-payment support to billing's `Provider` behaviour. Stripe-first; the seam already exists. (See `phoenix_kit_billing/dev_docs/agentic_commerce_payments.md`.)
2. **Merchant surface (the real work):** a new **machine-facing module** exposing:
   - product-feed builder + push job, and
   - ACP checkout REST endpoints that reuse `Cart` / `CartItem` / `convert_cart_to_order/2`.
3. **Where it lives — recommended: a new bridge plugin** (e.g. `phoenix_kit_acp` / module key `"agentic_commerce"`) depending on **both** ecommerce + billing, mirroring how ecommerce depends on billing. Keeps the agent/API surface out of the human-storefront module and lets it evolve on its own release cadence. (Alternative: a `route_module/0`-style sub-surface inside ecommerce — simpler but couples a fast-moving beta protocol into the storefront's release train.)

**Realistic blockers / caveats:**
- Requires **enrollment/approval with OpenAI** (feed is submitted to them; not self-serve discovery).
- **US-centric**, beta — the spec is a moving target; building now risks churn.
- Only valuable for hosts selling **consumer goods** people buy via ChatGPT. Irrelevant for B2B/SaaS/internal uses of the kit.

---

## 6. Decision

**Watch-item. Do not build now.** Re-evaluate when **any** of:
- A host/customer explicitly wants to sell through ChatGPT (or another ACP agent).
- ACP exits beta and/or onboarding opens to **EU / self-serve** (removes the OpenAI-enrollment + geography blockers).
- A sibling protocol (Visa MPP/UCP, etc.) gets traction we'd want to cover via the same merchant surface.

When triggered, the first concrete step is a **scoping spike**: pin the live ACP checkout spec, map each endpoint onto `Cart`/`convert_cart_to_order/2` + the billing `Provider` behaviour, and decide bridge-plugin vs in-ecommerce. No code until then.

---

## 7. Open questions to resolve against the live spec

- Exact ACP checkout endpoint set (4 vs 5), payload schemas, and required headers/auth (bearer + signature scheme).
- Product-feed format details + refresh/push mechanics + the OpenAI submission endpoint.
- SPT lifecycle specifics: token scoping (merchant + amount), expiry, partial-capture/refund semantics vs our existing Stripe refund path.
- Idempotency + error contract ACP expects on `complete` (must align with billing's existing webhook idempotency).
- Fulfillment/shipping representation in ACP vs our `ShippingMethod` model.

---

## 8. Sources

- Visa plugs payment network into ChatGPT (ABC/AP): https://abcnews.com/US/wireStory/visa-plugs-payment-network-chatgpt-letting-ai-agents-133757718
- Visa Intelligent Commerce — Visa Developer: https://developer.visa.com/capabilities/visa-intelligent-commerce/overview
- Visa advances agentic commerce (MCP server + Acceptance Agent Toolkit): https://corporate.visa.com/en/sites/visa-perspectives/innovation/visa-mcp-server-agent-acceptance-toolkit.html
- Agentic Commerce Protocol — OpenAI key concepts: https://developers.openai.com/commerce/guides/key-concepts
- ACP checkout spec — OpenAI: https://developers.openai.com/commerce/specs/checkout
- ACP GitHub (source of truth, beta): https://github.com/agentic-commerce-protocol/agentic-commerce-protocol
- Agentic Commerce Protocol — Stripe Docs: https://docs.stripe.com/agentic-commerce/acp
- ACP checkout endpoints — Stripe spec: https://docs.stripe.com/agentic-commerce/protocol/specification
- Stripe powers Instant Checkout / Shared Payment Token: https://stripe.com/newsroom/news/stripe-openai-instant-checkout
- Buy it in ChatGPT (OpenAI): https://openai.com/index/buy-it-in-chatgpt/
