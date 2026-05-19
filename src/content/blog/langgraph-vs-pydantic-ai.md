---
title: LangGraph vs Pydantic AI — a use-case-shape decision
description: Six weeks apart I picked opposite frameworks for two agent systems. Same engineer, opposite call. The decision rule that made both right.
pubDate: 2026-05-19
draft: true
tags: [llm, agents, langgraph, pydantic-ai, architecture]
---

In March I wrote an ADR rejecting LangGraph for our LLM-Ops layer at work. We went with Pydantic AI on top of a custom asyncio graph instead. In May I wrote a second ADR choosing LangGraph for a personal project. Same engineer, opposite call, ~six weeks apart.

That isn't a contradiction, or a vibe shift, or framework fashion. It's because the two systems are different shapes of problem, and the durable thing to take from either decision is the framing — *use-case shape, not capability count, picks the framework*.

This post is the framing, made concrete with the two cases that produced it.

## The two systems

The first one is request-scoped. A user asks the system to do a thing; under the hood, a constellation of small agents fan out, do their work in parallel, and the results get assembled into a response. Latency budget is single-digit seconds. Each agent has a narrow job — extract this field, classify that intent, summarise this passage. They don't talk to each other; they don't loop; they each produce one structured output and return. The orchestration is parallel-fan-out with deterministic joins.

The second one is conversational. A user asks the agent for transfer recommendations on their FPL team. The agent forms a plan, executes some tools (pgvector search, fixture lookup, player history), looks at the results, decides whether the plan still makes sense, possibly amends it, and eventually produces a recommendation. Latency budget is tens of seconds; the user is sitting there watching a streaming response come back. The orchestration is a conditional loop over shared state.

Two different shapes. Stateful-loop versus parallel-fan-out.

## What each framework is built for

LangGraph is built for stateful, multi-step, conditional execution. You declare a graph of nodes; each node mutates a shared state; edges can be conditional; the framework manages the state, the iteration count, the streaming, the cancellation. It includes durable execution if you want it — long-running graphs that survive process restarts, that resume from checkpoints. The mental model is "a state machine you can describe in Python."

Pydantic AI is closer to "type-safe agent primitives." An `Agent[DepsT, OutputT]` is a typed function that takes dependencies and produces a structured output, with tool calling built in, streaming built in, dependency injection built in. There's no graph. If you want orchestration, you compose agents with `asyncio.gather` or a `TaskGroup`. The framework gets out of the way; the language does the rest.

Both frameworks can be made to do either shape of problem. That isn't the question. The question is what each is *built for* — what shape of problem it makes simple, and what shape it makes possible but awkward.

LangGraph on parallel-fan-out: possible, but you're declaring a graph with N parallel nodes that don't share state, which is a graph DSL describing what `asyncio.gather` already does in five lines.

Pydantic AI on stateful-loop: possible, but you're writing your own state machine, your own iteration limit, your own conditional-edge logic. The framework gives you typed agents; the loop logic is on you.

The "capability count" comparison — *which framework can do more things* — is the wrong question. Both can do everything. The right question is which framework's natural shape matches your problem's natural shape.

## The Curve call

For request-scoped fan-out, Pydantic AI plus a custom asyncio graph wins.

A single user request fires off, say, five parallel agents: one extracting structured fields from a document, one classifying intent, one running entity linkage, one ranking candidates, one generating a short summary. They don't depend on each other; their outputs go into a deterministic merge step. Latency is dominated by the slowest agent (a couple of seconds), not by orchestration overhead.

The asyncio version is short and obvious:

```python
async with asyncio.TaskGroup() as tg:
    field_task = tg.create_task(extract_fields.run(...))
    intent_task = tg.create_task(classify_intent.run(...))
    # ...
final = merge(field_task.result(), intent_task.result(), ...)
```

That's ten lines. The LangGraph version would be a graph with a START node, five parallel branches to a JOIN node, then a final node. Same logical structure, more ceremony, plus a graph DSL to learn and debug. And LangGraph's durable execution — the thing that justifies the abstraction cost — buys nothing here because the request is gone in three seconds. There's nothing to durably persist.

Bonus argument: every agent in this system already has Pydantic models flowing through the FastAPI layer. Pydantic AI's `OutputT` is the same type. Type-safety end-to-end, no model duplication between API boundary and agent.

The ADR explicitly named the rejection: "LangGraph is not worse than asyncio; it is built for a different shape of problem. Request-scoped agents that run for seconds do not need durable execution, and forcing them through a graph DSL pays the abstraction cost without collecting the abstraction benefit."

## The FPL call

For the Scout Agent, LangGraph wins.

Four nodes: a planner that turns the user query into a sequence of tool calls; a tool executor that runs them; a reflector that reads the results and decides if the plan needs another iteration; a recommender that produces the final answer. The conditional edge from reflector back to planner is the load-bearing thing — without it, the agent commits to its first plan and can't recover. With it, the agent has up to three passes to course-correct, capped explicitly to bound cost.

You could write that in asyncio. It's a while loop with a state dict and some functions. It would be 200 lines, and it would slowly accrete the things LangGraph already does: max-iteration logic, conditional routing, state-shape validation, streaming, checkpointing for testing, observable tracing per node. Each of those is small; together they're the abstraction LangGraph already pre-built.

The shape matches. The framework gives you the affordances the problem actually has. Use it.

## The rule

*Use-case shape, not capability count, picks the framework.*

A capability-count comparison reads "LangGraph has durable execution, checkpointing, sub-graphs; Pydantic AI has type-safe outputs, dependency injection. They each have things the other doesn't, so pick the one with more capabilities relevant to your problem."

That's true but useless. It treats frameworks as feature lists and your problem as a set of feature requirements. Frameworks aren't feature lists. They're opinions about what shape of work you're doing.

The shape-matching rule cuts the decision differently:

If your problem is parallel-fan-out with deterministic joins, the framework you want is the language plus typed agents. Anything more is ceremony. Pydantic AI sits exactly there.

If your problem is a stateful conditional loop with branching and iteration caps, the framework you want is something that pre-builds those primitives so you're not re-implementing them under the time pressure of a real deadline. LangGraph sits exactly there.

If your problem is sequential pipelines with no branching, pick the lightest thing. Both frameworks would work; the difference doesn't matter; pick on import-line ergonomics and move on.

If your problem is human-in-the-loop multi-turn — emails, approvals, week-long workflows — pick the one with durable execution. That's LangGraph in this comparison; it's also Temporal, also Inngest, also a dozen others.

## What this is and isn't

This isn't "Pydantic AI good, LangGraph bad" or vice versa. The single most important sentence I can write here is that both frameworks are well-designed for what they're built for. They make different choices about what's primitive and what's composable. Picking between them on capability count means measuring them by the wrong axis.

It also isn't "always rewrite to match the framework." If you have a working LangGraph system that's fan-out shaped, leave it. Switching framework to save 20 lines of orchestration code is almost always the wrong trade.

The thing to internalise is the diagnostic. When you find yourself reading framework comparison posts and counting checkmarks, stop. Describe your problem in one sentence — *what's the shape of orchestration this thing needs* — and let the answer pick itself. If two frameworks both fit cleanly, pick on local-context reasons (already-installed dependencies, team familiarity, latency profile). If one of them is awkward for your shape, that's the signal.

The six-weeks-apart Curve and FPL decisions both came out clean because the shape was named first and the framework picked second. The opposite order — "we should use LangGraph because it's powerful" or "we should use Pydantic AI because it's lighter" — produces decisions that look right in isolation and break six months in when the system has grown into a shape the framework wasn't built for.

Diagnose the shape. Pick the framework that fits. Re-evaluate when the shape changes.
