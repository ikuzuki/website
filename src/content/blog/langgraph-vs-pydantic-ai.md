---
title: LangGraph and Pydantic AI, six weeks apart
description: I picked opposite frameworks for two agent systems six weeks apart. Same engineer, opposite call. The framing that made both right.
pubDate: 2026-04-29
draft: false
tags: [llm, agents, langgraph, pydantic-ai, architecture]
---

In March I wrote an ADR rejecting LangGraph for an agent orchestration layer on another project I worked on. We went with Pydantic AI on top of a custom asyncio graph instead. Six weeks later, on a personal project, I picked LangGraph for the agent layer. Same engineer, opposite call.

I don't think it's a contradiction, or a change of mind, or framework fashion. The two systems are different shapes of problem, and the durable thing to take from either decision is the framing: use-case shape, not capability count, picks the framework.

The first system, on the other project, is request-scoped. A user asks the system to do a thing; under the hood, a constellation of small agents fan out, do their work in parallel, and the results get assembled into a response. Latency budget is single-digit seconds. Each agent has a narrow job (extract this field, classify that intent, summarise this passage). They don't talk to each other, they don't loop, they each produce one structured output and return. The orchestration is parallel-fan-out with deterministic joins.

The second system, the [Scout Agent](/projects/scout-agent/) on top of my FPL pipeline, is conversational. A user asks for transfer recommendations on their team. The agent forms a plan, executes some tools (pgvector search, fixture lookup, player history), looks at the results, decides whether the plan still makes sense, possibly amends it, and eventually produces a recommendation. Latency budget is tens of seconds. The user is sitting there watching a streaming response come back. The orchestration is a conditional loop over shared state.

Stateful-loop on one side, parallel-fan-out on the other.

LangGraph is built for stateful, multi-step, conditional execution. You declare a graph of nodes, each node mutates a shared state, edges can be conditional, the framework manages the state, the iteration count, the streaming, the cancellation. It includes durable execution if you want it, long-running graphs that survive process restarts, that resume from checkpoints. The mental model is "a state machine you can describe in Python".

Pydantic AI is closer to "type-safe agent primitives". An `Agent[DepsT, OutputT]` is a typed function that takes dependencies and produces a structured output, with tool calling built in, streaming built in, dependency injection built in. There's no graph. If you want orchestration, you compose agents with `asyncio.gather` or a `TaskGroup`. The framework gets out of the way; the language does the rest.

Both frameworks can be made to do either shape. I want to be clear about that, because every framework comparison post on the internet has a "but you could just use X to do Y" objection. Yes, you could. The question I find more useful is what each framework was built for, what shape of problem it makes simple, and what shape it makes possible but awkward. Capability-counting (which framework supports more features?) is a different question and, in my view, the less helpful one for picking between two well-designed tools.

For that orchestration problem, Pydantic AI plus a custom asyncio graph wins.

A single user request fires off, say, five parallel agents, each with a narrow job: extracting structured fields, classifying intent, applying topic tags, checking content quality, generating a short summary. They don't depend on each other, their outputs go into a deterministic merge step. Latency is dominated by the slowest agent (a couple of seconds), not by orchestration overhead. The asyncio version is short and obvious:

```python
async with asyncio.TaskGroup() as tg:
    field_task = tg.create_task(extract_fields.run(...))
    intent_task = tg.create_task(classify_intent.run(...))
    # ...
final = merge(field_task.result(), intent_task.result(), ...)
```

Ten lines. The LangGraph version would be a graph with a START node, five parallel branches to a JOIN node, then a final node. Same logical structure, more ceremony, plus a graph DSL to learn and debug. LangGraph's durable execution (the thing that justifies the abstraction cost) buys nothing on this workload because the request is gone in three seconds. There's nothing to durably persist.

A second reason worth noting: every agent in the system already had structured Pydantic outputs flowing through the rest of the codebase. Pydantic AI's `OutputT` slots into the same type hierarchy. Type-safety end-to-end, no model duplication between layers, no marshalling step in the middle. It's the same kind of small fit advantage as choosing your ORM to match your serialiser; not load-bearing on its own, but real when the alternative would force a parallel type hierarchy.

The ADR for that one is in Confluence; the relevant sentence is "LangGraph is not worse than asyncio; it is built for a different shape of problem". Worth landing that flatly. The Pydantic AI ADR is not a critique of LangGraph.

For the Scout Agent, LangGraph wins.

Four nodes: a planner that turns the user query into a sequence of tool calls; a tool executor that runs them; a reflector that reads the results and decides whether the plan needs another iteration; a recommender that produces the final answer. The conditional edge from reflector back to planner is the load-bearing thing. Without it, the agent commits to its first plan and can't recover. With it, the agent has up to three passes to course-correct, capped explicitly to bound cost.

You could write that in asyncio. It's a while loop with a state dict and some functions. It would be two hundred lines, and it would slowly accrete the things LangGraph already does: max-iteration logic, conditional routing, state-shape validation, streaming, checkpointing for testing, observable tracing per node. Each of those is small individually. Together they're the abstraction LangGraph already pre-built. The shape matches; the framework gives you the affordances the problem actually has; use it<sup>1</sup>.

<figure>
  <img src="/diagrams/langgraph-vs-pydantic-ai.svg" alt="Decision tree: what is the shape of the orchestration? Four branches lead to recommendations: parallel fan-out goes to Pydantic AI plus asyncio.TaskGroup; stateful loop goes to LangGraph; sequential pipeline lands on 'pick on context'; durable or human-in-the-loop lands on LangGraph with checkpointing or Temporal." />
  <figcaption>The diagnostic, in tree form. Four shapes, four answers.</figcaption>
</figure>

The diagnostic I find myself reaching for when other people ask me about this is roughly: describe your problem in one sentence, focused on the shape of orchestration. If it's parallel-fan-out with deterministic joins, asyncio plus typed agent primitives is enough. If it's a stateful conditional loop with branching and iteration caps, reach for something that pre-builds those primitives so you're not re-implementing them under deadline pressure. If two frameworks both fit cleanly, pick on local context (already-installed dependencies, team familiarity, latency profile). If one of them is awkward for your shape, that awkwardness is the signal.

I want to head off the "but if your shape changes, you'll regret the choice" objection. Real answer: yes, you will, and that's fine. Frameworks aren't forever. When that system starts needing durable execution for long-running workflows (it will, probably within a year), the relevant agents will get ported to LangGraph or Temporal and the migration cost paid. The system was right for the shape it had at the time of building. The same is true on the FPL side. If the Scout Agent ever needs to handle parallel users, fanning their requests out across nodes that don't share state, the LangGraph shape will start to feel heavy and I'll port the affected nodes back to plain asyncio. Both decisions are revisable; both will be revised; that's not the same as either being wrong.

The thing that surprised me most, looking back at the two ADRs side by side, is how clean the symmetry is once the framing is right. The two systems share roughly zero implementation, but they share a decision rule. That feels right to me. Most of the framework-choice posts I read are anti-X or pro-Y. The interesting position to defend is harder: same engineer, two opposite choices, both right.

---

<sup>1</sup> The two-week sanity check I ran before committing to LangGraph: prototype the four-node graph as a plain asyncio while-loop, time-box at four hours, ship if it's clean. Mine wasn't. By hour three I'd reinvented `state.update` plus an iteration counter plus a half-decent conditional router plus streaming. At that point you might as well take the framework.
