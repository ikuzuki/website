---
title: Cost-engineering an LLM pipeline on the AWS free tier
description: How a weekly LLM enrichment pipeline ended up costing single-digit pounds a month, and what the actual cost shape of LLM-heavy serverless workloads looks like.
pubDate: 2026-05-19
draft: true
tags: [aws, llm, cost-engineering, lambda, serverless]
---

The cost of running my FPL enrichment pipeline is single-digit pounds a month, and most of that is the Claude API. The AWS side — Lambda, Step Functions, S3, CloudFront, DynamoDB, SSM — combined is rounding error. I deliberately engineered for that, and I want to write down what the cost shape actually looks like, because most "serverless cost" advice online is calibrated for the wrong workload.

Three things upfront.

First, "free tier" is doing a lot of work in this post. AWS free tier covers far more than people assume — 1M Lambda requests/month, 400K GB-seconds of Lambda compute, 5GB of S3 standard storage, 1TB of CloudFront egress, the first 4,000 Step Function transitions/month, 25GB-months of DynamoDB on-demand. For a personal-scale LLM workload running weekly, this is a generous envelope.

Second, this isn't a general "save money on AWS" post. It's specifically about workloads where LLM API calls dominate spend by orders of magnitude. The advice is different from a high-throughput data pipeline.

Third, the goal of cost engineering at this scale isn't to spend zero. It's to keep cost predictable and proportional to value, so you can make changes without flinching. That's a different objective from minimisation.

## The shape

The pipeline runs weekly. Inputs are scraped from the FPL API, Understat, and a handful of news sources by five Lambda collectors. Validation Lambdas promote to a clean layer. A Step Function orchestrates enrichment: per-player Lambdas call Anthropic Haiku for bulk summaries, Sonnet for the harder reasoning passes. Curated outputs land in S3 and are served via CloudFront. The whole graph runs in about 15 minutes.

The full cost breakdown for a typical week:

- Lambda compute: ~£0.00 (well under free tier)
- Step Functions: ~£0.00 (well under free tier)
- S3 storage + requests: ~£0.00
- CloudFront egress: ~£0.00 (dashboard traffic is low)
- DynamoDB on-demand: ~£0.00 (Scout Agent's budget cap state)
- SSM Parameter Store: £0.00 (standard tier is free)
- Anthropic API: £1.50–£3.00

The interesting number is the ratio. If I doubled the Lambda memory tomorrow, total monthly cost would change by pennies. If I switched one Haiku call to Sonnet across all 700 players per gameweek, total monthly cost would maybe double. The leverage is in the second knob, and only the second knob.

## The first lesson — pricing tells you what a call costs, rate limits tell you whether the call is possible

Most cost-optimisation thinking starts with pricing tables. That's the wrong place to start for LLM-heavy workloads. The pricing tells you the per-call cost in pence. The rate limits tell you whether the call can happen at all when the workload spikes.

Anthropic's rate limits are in tokens-per-minute, and they bind well before pricing does on a batch workload. The first time you try to enrich 700 players in parallel you'll hit the per-minute token cap, queue, and discover that your "should take 30 seconds" job actually takes 8 minutes because it spent 7 of them waiting on rate-limit windows.

The right first cost question is "what's the rate-limit shape, and what's the call schedule that respects it." Get that right and pricing falls out of it. Get it wrong and pricing is a meaningless number because you can't even run the job at the rate you want.

## The second lesson — the dominating cell

Pick any LLM workload and write down the cost matrix: rows for each model used, columns for each call type, cell = (model price per token) × (calls per period) × (tokens per call). For a batch workload at non-trivial volume, *one cell is always more than 90% of total spend.* Everything else is rounding error.

For the FPL pipeline that cell is "Sonnet calls on enrichment, ~700 per gameweek, ~2k tokens per call." Optimising the Haiku calls on summarisation saves pennies. Switching the Sonnet calls to a cheaper model would save pounds. Filtering the input list of 700 players down to 200 by relevance would save pounds. Batching ten enrichment requests into one prompt with structured output for ten players at once would save pounds.

The first cost optimisation isn't "switch to a cheaper model everywhere." It's identifying the dominating cell and attacking it specifically. The other cells will round off to zero whether you optimise them or not.

A corollary worth stating plainly: serverless infrastructure is rounding error against LLM spend. Lambda, Step Functions, S3, CloudFront, Secrets Manager combined run me about 5p a week. The Claude API costs roughly thirty times that. Optimising Lambda memory for cost reasons on an LLM-heavy workload is the wrong instinct. Spend the memory if it makes the cold start better; the cost barely moves.

## The third lesson — Secrets Manager is not free, and it's the most common surprise

The one piece of AWS that bit me on cost was Secrets Manager. £0.30 per secret per month, plus £0.04 per 10K API calls. Sounds trivial. With four secrets — Anthropic API key, Langfuse keys, Neon connection string, one for the agent shared-secret — that's £1.20/month, which doesn't move the needle but is a recurring line item that doesn't need to exist.

I moved everything to SSM Parameter Store. Standard-tier parameters are free, up to 10,000 of them, with no per-API-call charge. The only thing you lose is automatic rotation, and a solo personal project doesn't need automatic secret rotation. The migration was an afternoon; the savings are £14.40/year forever.

The rule: Secrets Manager is paying for rotation. If you're not using rotation, you're paying for nothing.

## The fourth lesson — DynamoDB on-demand at the smallest scale

The Scout Agent uses DynamoDB for two things: per-request budget caps (prevents runaway agent loops from blowing past £1 per request) and per-IP rate limiting (one read/write per request).

On-demand DynamoDB is generous at small scale. The always-free tier covers 25GB of storage and 25 WCU/RCU equivalent per second. At one DynamoDB operation per chat request, with maybe a few hundred chat requests a month, the table is invisible on the bill.

The mistake I almost made was provisioning the table with provisioned capacity to be "safe." Provisioned capacity has a minimum charge per WCU/RCU regardless of usage. On-demand is more expensive per request but charges only for actual usage; at a workload that's mostly idle, on-demand wins by a wide margin. The rule of thumb: provisioned makes sense when you have predictable steady traffic above ~10 ops/second sustained. Below that, on-demand is cheaper.

## The fifth lesson — Lambda memory is a latency knob, not a cost knob

Lambda pricing is per GB-second of compute. Doubling memory doubles the per-second cost, but it also typically halves the execution time on CPU-bound work, so the total cost stays the same. On I/O-bound work — which most LLM-calling Lambdas are, since most of the runtime is waiting for the model to respond — doubling memory often produces a small latency win and a small cost increase.

The interesting case is cold starts. My Scout Agent Lambda's cold start was 27 seconds at 1024 MB and 8–12 seconds at 3008 MB. The cost difference at the volume the agent gets called is fractions of a penny per month. The latency difference is the difference between a usable user experience and an unusable one. The decision is trivial: take the latency, eat the rounding-error cost.

The deeper point: at LLM-heavy serverless workloads, Lambda memory is the wrong place to look for cost savings. It's the right place to look for latency improvements, and you should set it whatever you need for latency without thinking about the cost line on the Lambda side.

## What I monitor

Two AWS Budgets, set up from day one. One at $1/month with an alarm at 100% of actuals — this is the "something went very wrong" tripwire; in months when the dashboard sees normal traffic, monthly AWS spend is ~$0.50, so any alert means a misconfigured cron or runaway loop. The second at $5/month forecast with an alarm at 80% — the "you're about to spend real money" warning.

On the LLM side, Langfuse tracks per-call cost across the pipeline. I can pull the dashboard and see exactly which prompt is generating which cost over a week. When I'm prompt-engineering a new enrichment pass, I run it on five players, look at Langfuse, see the per-call token count, and extrapolate before unleashing it on 700. This catches the "I added a 4K-token few-shot block and didn't realise" case before it costs anything visible.

## The takeaway

The cost shape of an LLM-heavy serverless pipeline is dominated by one number. Find that number; engineer around it. Everything else is rounding error and doesn't deserve the time.

The corollary is freeing once you internalise it. You stop worrying about whether a particular Lambda is 512MB or 3008MB. You stop second-guessing on whether to add an extra Step Function state. You stop treating S3 storage costs as a thing you have to think about. The single thing you watch is the LLM cell, and you build around it.

For my FPL pipeline that meant: smart filtering before the Sonnet pass (don't enrich players who aren't relevant this gameweek), aggressive caching of intermediate results so re-runs cost nothing, and Haiku for everything that doesn't strictly need Sonnet's reasoning. Those three moves together drop the Claude bill from "would have been £30/month" to "is £2-5/month" without affecting output quality.

The free-tier AWS bill is icing. It's nice that the infra is free, and the discipline to keep it free forces some healthy decisions. But it's not where the leverage is. The leverage is the LLM cell. That's where to spend your attention.
