---
title: What I let AI do on its own
description: Three positions, placed per activity and not per tool, and the one rule that does the real work: you can only hand an activity to the model if you can point at the human-owned layer upstream that makes it safe.
pubDate: 2026-09-16
draft: true
tags: [ai-engineering, ai-native, workflow, guardrails]
---

The question I get most often, in some form, is "can we just let it do that on its own?" Let the model open the pull request without a human in the loop. Let it write to the shared doc. Let it merge. It's a fair question, and "it depends" is a useless answer, so at some point I had to work out what it actually depends on. What came out is a simple spine I now use to place any piece of work, and one rule underneath it that does most of the real work.

Three positions, chosen per activity, not per tool. Human-Led: the person makes the call, and the model can inform but doesn't draft or recommend. AI-Assisted: the person owns the outcome, the model drafts, and the person reviews and approves. AI-Driven: the model executes on its own, and the person spot-checks or reviews the exceptions. The labels are the easy part. The placing is where the thinking goes, and the most common mistake is to place by tool, "we use Claude, so we're AI-driven", rather than by activity. The same team, on the same day, should be Human-Led on some things and AI-Driven on others.

A few placements carry the whole model, so they're worth stating plainly.

Coding standards are Human-Led. Not assisted, not driven. People decide what good code looks like on this codebase, and they write it down. Design decisions are AI-Assisted: the model can propose an approach, suggest a technology, sketch the topology, but adoption needs a human, because design lives or dies on business context and the model doesn't have it. Writing the code, though, is AI-Driven, and it's allowed to be. Documentation splits by direction of travel: retrospective docs like release notes and PR descriptions are AI-Driven, because they're a synthesis of work that already happened and the model has every input; forward-looking docs like specs and design records need a human to seed them, because the decisions are still being made. And anything that leaves the building for a client keeps a hard human review gate regardless of how routine it looks.

Here's the part that took me longest to see, and it's the whole point: those rows are not independent. It is only safe to let the model write code on its own because the standards it writes against are human-owned and enforced upstream of it. Pull the standards layer out and "AI-Driven coding" quietly becomes "the model writes whatever it likes and a person cleans up afterwards", which is slower and worse than either doing it yourself or doing it properly. The autonomy downstream is borrowed against the human ownership upstream.

So the test I actually apply, every time someone wants to move an activity toward more autonomy, is a single question: point at the human-led layer upstream that makes it safe. Want the model to merge its own PRs? Show me the review gate and the standards it's being held to. Want it to write the code unattended? Show me where the conventions live and how they're applied. If you can't point at that upstream layer, you're not ready to move the activity down the spectrum. You're just hoping, and hope is not a guardrail.

A placement is only real if it's enforced, which is the other half of this. "Coding standards are Human-Led" means nothing if applying them depends on whoever happens to be reviewing remembering to. The standards have to be wired into the tooling so they fire on every change on their own, a point I've [made before about hooks and skills doing the enforcing rather than prompts](/writing/cursor-to-claude-code-migration/). A placement you don't enforce is a preference, and preferences drift the first busy week. The spectrum is a description of where the work sits; the enforcement is what stops it sliding.

There's a natural pull, once this is working, to keep pushing activities into the AI-Driven column, and mostly that's the right instinct. The thing to notice is that as you do, the human's remaining job concentrates rather than disappears. It collects at the two ends of each activity, defining the work clearly going in and checking it honestly coming out, which is its [own bottleneck and its own post](/writing/the-bottleneck-moved-to-verification/). Moving something to AI-Driven doesn't remove the human. It relocates them to the edges and makes what they do there matter more.<sup>1</sup>

None of these placements are permanent. An activity that's AI-Assisted today becomes a candidate for AI-Driven the moment the upstream human-led layer it depends on gets solid enough to hold the weight. That's actually most of what going AI-native is: not flipping everything to autonomous at once, but building the human-owned layers, standards, specs, review gates, enforcement, that let you move one activity at a time down the spectrum without lowering the bar. The autonomy is the visible part. The upstream ownership is the part that earns it.

---

<sup>1</sup> This is why I distrust the framing of AI adoption as "how much can we automate". The more useful question is "which human-owned layer would we need to build to make this safe to automate", because that names the actual work. The automation tends to follow cheaply once the layer exists, and stays dangerous when it doesn't.
