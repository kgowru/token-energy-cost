---
title: "What Does a Coding Agent Actually Cost? Building AgentSpend"
description: "A macOS menu bar app that turns your Claude Code token logs into two honest numbers — dollars and watt-hours — and the reasoning behind every coefficient."
date: 2026-08-06
author: Kapil Gowru
tags: [ai, energy, claude-code, cost, sustainability, macos]
---

# What Does a Coding Agent Actually Cost? Building AgentSpend

I run coding agents all day. At some point a simple question started nagging at me: **what is this actually costing?** Not just my Anthropic bill — the whole thing. Every token I generate is a few joules burned in a datacenter somewhere, and I had no feel for the magnitude. Was a day of agentic coding closer to boiling a kettle or running my house?

So I built **AgentSpend**: a small macOS menu bar app that reads Claude Code's own local logs and shows two numbers — **dollars** and **watt-hours** — updated live as you work.

This post is about the reasoning behind those two numbers, because the second one is much harder to get honest than the first.

---

## Two numbers, two very different confidence levels

The core of the app is an estimator that takes token counts and produces `$` and `Wh`. It's worth being blunt about how much I trust each:

| Number | What it is | How confident |
| --- | --- | --- |
| **$** | Exact arithmetic on Anthropic's published API rates | Near-certain |
| **Wh** | A *modeled estimate* built from third-party research | A wide band, and I say so in the UI |

These are independent calculations that happen to share one input: the token counts parsed from your session logs. The dollar figure has nothing to do with electricity prices, and the energy figure has nothing to do with what you pay Anthropic. Conflating the two is the single most common mistake in this space, so I kept them structurally separate.

---

## The easy number: dollars

Every Claude Code session log records a `message.usage` block: input tokens, output tokens, cache-creation tokens, and cache-read tokens. Multiply each by Anthropic's published per-token rate and you have an exact, defensible cost.

```
$ = ( input · rate_in
    + cacheWrite · rate_in · writeMultiplier
    + cacheRead · rate_in · 0.1
    + output · rate_out ) / 1,000,000
```

Cache reads bill at 10% of the input rate; cache writes at 1.25× (5-minute) or 2× (1-hour). These are Anthropic's published numbers, so the dollar figure is essentially arithmetic. The only subtlety is bookkeeping — streamed messages get logged repeatedly with partial token counts, so I dedupe on `message.id` and keep the maximum `output_tokens`. Skip that and you undercount output by ~12%.

One honest caveat: this is what your usage *would* cost at API rates. If you're on a subscription plan, it's a usage-equivalent figure, not your invoice.

That's the whole of the easy half. Now the interesting part.

---

## The hard number: watt-hours

Here's the uncomfortable truth that motivated most of the engineering effort: **no frontier AI vendor publishes per-token energy, and Anthropic publishes nothing at all.** There is no ground-truth number to look up. Anyone who gives you a confident, precise "each message uses X watt-hours" is either measuring their own hardware or making it up.

So the energy number is a *model*, and I built it to be defensible rather than precise. Three principles guided it:

1. **Anchor to measured production data, not TDP napkin math.**
2. **Relative comparisons are trustworthy; absolute values are not.**
3. **Expose the biggest uncertainty as a user control instead of hiding it.**

### Anchoring to real measurements

For years the public discourse ran on a "ChatGPT uses ~3 Wh per query" figure that turned out to be roughly 10× too high. The last year finally produced credible, production-grade measurements, and I anchored the model to three of them, which — reassuringly — converge:

- **Google, Aug 2025:** the median Gemini Apps text prompt uses **0.24 Wh**, measured in production at global scale. Google also reported a **33× drop** in that figure over 12 months — a reminder that any energy number decays fast. ([MIT Technology Review](https://www.technologyreview.com/2025/08/21/1122288/google-gemini-ai-energy/), [Google Cloud blog](https://cloud.google.com/blog/products/infrastructure/measuring-the-environmental-impact-of-ai-inference), [technical paper](https://arxiv.org/abs/2508.15734))
- **Microsoft, Joule, Apr 2026:** a peer-reviewed study finding optimized frontier-scale inference at a **median of 0.31 Wh** per query (IQR 0.16–0.60), and **4–20× lower** than widely cited estimates. ([Joule](https://www.cell.com/joule/fulltext/S2542-4351(26)00114-5), [Microsoft Research](https://www.microsoft.com/en-us/research/publication/energy-use-of-ai-inference-efficiency-pathways-and-test-time-scaling/))
- **Epoch AI:** an independent FLOPs-based model putting a typical GPT-4o query near **0.3 Wh**, with a wide 0.1–4.0 Wh range. ([Epoch AI](https://epoch.ai/gradient-updates/how-much-energy-does-chatgpt-use))

Three different organizations, three different methodologies — measurement, peer review, and first-principles modeling — all landing around **0.3 Wh for a median query.** That convergence is the foundation the whole model sits on.

### Why relative beats absolute

The same model on the same GPU can vary in measured energy by **~100×** depending on how it's served — batch size and utilization dominate everything else. That's why I refuse to present a single confident number. But here's the saving grace: those serving-efficiency unknowns are *shared* across models. When you compare Opus to Haiku, the messy multipliers largely cancel, and the *ratio* survives even when the absolute values wobble. AgentSpend leans into that — the comparisons between your models are far more robust than any single total.

### Prefill vs. decode: why output costs more than input

Input and output tokens are not energetically equal. Per-token FLOPs are identical (2N), but *achieved efficiency* is not:

- **Prefill** (reading your prompt) is one big parallel matrix multiply — compute-bound, high utilization.
- **Decode** (generating output) streams the entire model's weights from memory for *every single token* — bandwidth-bound, much lower utilization.

Microsoft's Splitwise work instrumented per-phase GPU power directly to quantify this gap. I set output at **4× the energy of input** — comfortably between the physical floor and the point where "50–100×" claims turn out to be batching artifacts rather than real ratios. Notably, Anthropic's own pricing uses exactly 5× for the output-to-input ratio, which is a nice independent sanity check. ([Splitwise, ISCA '24](https://www.microsoft.com/en-us/research/wp-content/uploads/2023/12/Splitwise_ISCA24.pdf))

### The elephant: cache reads

This is the coefficient I lost the most sleep over. In Claude Code, roughly **95% of your token volume is cache reads** — the agent re-reads its accumulated context on every turn. So the single most important number in the entire energy model is: *how much energy does a cache hit actually use?*

And the honest answer is **nobody has measured it.** Architecturally, a cache hit should skip almost all of the prefill work, so it should be cheap. The 10% price discount hints at that — but a price is a business decision, not a physics measurement. I default this factor to **0.10** (a cache read costs 10% of a fresh input token) but I'll be the first to admit the real range is 0.01–0.30, and that this one dial swings the total by roughly **2×**.

Rather than bury that uncertainty, I put it on a slider. If you distrust my default, move it and watch the number respond. Honesty about the error bar felt more valuable than false precision.

### The boundary, and what it excludes

Every figure uses a **full-datacenter boundary** — the accelerator, host CPU/DRAM, networking, storage, and facility PUE. GPU-only accounting would be ~2.4× lower; I chose the wider boundary because it reflects the actual electricity drawn from the grid. And I'm explicit about what's left out:

- **Training energy** — excluded entirely; this is inference only.
- **Context length** — the model uses median-query anchors, but a long-context request can cost 10–100× the median, because prefill attention is O(n²) and every decode step re-reads a growing KV cache.
- **Where it happened** — this electricity was burned in a datacenter, not on your Mac.

Every constant in the model is timestamped, because — as Google's 33× number shows — these figures rot within a year.

---

## Making it relatable

Tens to hundreds of watt-hours is an abstraction. So the app translates the total into something you can feel — primarily **fraction of an average US home's daily electricity** (~29 kWh/day, per EIA). I deliberately avoided the zombie stats that infest this genre: the "0.3 Wh per Google search" figure is from 2009 and ~17 years stale, and the "4.6 tonnes CO₂ per car per year" number is superseded by the EPA's current 4.29 t. Every equivalence in the app traces to a current EPA, DOE, EIA, or IEA source.

---

## Why bother?

Two reasons.

**Feedback changes behavior.** You can't develop intuition for a cost you never see. Watching the counter tick has already made me more deliberate — reaching for a smaller model when a task doesn't need Opus, thinking twice before firing off ten parallel agents on a whim.

**Honesty is a feature.** The AI energy conversation is drowning in confident numbers that are wrong by an order of magnitude in both directions — activists inflating, vendors minimizing. I wanted to build the opposite: something that shows you a number *and* shows you exactly how much to trust it. The wide band isn't a bug; it's the most truthful thing the app displays.

The whole model — every anchor, coefficient, source, and caveat — ships as a single JSON file inside the app (`energy-model.json`). It's meant to be read and argued with. If you think a coefficient is wrong, the sources are right there. Tell me where the model is off and I'll fix it.

---

## Sources

- [Google — Measuring the environmental impact of AI inference](https://cloud.google.com/blog/products/infrastructure/measuring-the-environmental-impact-of-ai-inference) · [technical paper (arXiv)](https://arxiv.org/abs/2508.15734) · [MIT Technology Review coverage](https://www.technologyreview.com/2025/08/21/1122288/google-gemini-ai-energy/)
- [Microsoft — Energy use of AI inference (Joule, 2026)](https://www.cell.com/joule/fulltext/S2542-4351(26)00114-5) · [Microsoft Research](https://www.microsoft.com/en-us/research/publication/energy-use-of-ai-inference-efficiency-pathways-and-test-time-scaling/)
- [Epoch AI — How much energy does ChatGPT use?](https://epoch.ai/gradient-updates/how-much-energy-does-chatgpt-use)
- [Microsoft — Splitwise: prefill/decode phase power (ISCA '24)](https://www.microsoft.com/en-us/research/wp-content/uploads/2023/12/Splitwise_ISCA24.pdf)
- [NVIDIA — LLM inference optimization](https://developer.nvidia.com/blog/mastering-llm-techniques-inference-optimization/)
- [EIA — US residential electricity use](https://www.eia.gov/tools/faqs/faq.php?id=97&t=3) · [EPA — Greenhouse gas equivalencies](https://www.epa.gov/energy/greenhouse-gas-equivalencies-calculator-calculations-and-references) · [IEA — Carbon footprint of streaming video](https://www.iea.org/commentaries/the-carbon-footprint-of-streaming-video-fact-checking-the-headlines)
