---
title: Evals, after putting them off
description: I'd read the posts, nodded at the rubrics, never quite got round to building one. Last week I did, and the things it surfaced weren't the things I expected to surface.
pubDate: 2026-05-27
draft: false
tags: [llm, agents, evals, llm-as-judge, fpl]
---

Until last week I'd never built evals for anything. I'd read the posts. I'd nodded at the rubrics. I'd thought "sensible" and never quite got round to it. The agent in my FPL project had been changing roughly weekly for a couple of months; my way of knowing whether the changes were improvements was to ask it a few questions by hand and read the responses. This worked when the change set was small. It stopped working when I was changing the planner prompt, the tool registry, and the recommender simultaneously and couldn't tell whether the resulting answers were better than the answers before.

I built the eval framework partly out of necessity and partly because I'd run out of excuses. I expected it to confirm a few things I already suspected: that some cases were borderline, that the agent hedged occasionally when it shouldn't, that the recommender's prose got woolly under squad-context load. Most of what I expected was true. The interesting things were three I didn't expect at all.

The first came on a case I'd written as a fabrication guard. The question is "Tell me about Xherdan Shaqiri", who isn't in the Premier League this season, and the case's deterministic check (`must_have_empty_players_list=True`) asserts that the response's `players` array should be empty because there's no data to populate it. The framework runs two grading layers per case: deterministic checks against the structured output, plus a Claude Haiku judge scoring the response against a per-case rubric. I'd built both layers because the posts I'd read had recommended it. I'd half-assumed they'd agree on the easy cases, including this one.

They didn't. The Haiku judge gave the response a 4.25 out of 5. The deterministic check correctly flagged it as broken.

The agent had done something I hadn't anticipated. It acknowledged the absence exhaustively in the analysis text, explained why Shaqiri isn't in the dataset, recommended the user not pick him, caveated every assumed value, and then filled the `PlayerAnalysis` slot with placeholder zeros (price=£0.0, form=0.0, confidence=0.1). The prose was honest about the absence. The schema fabricated it anyway. The judge read the prose first and scored sympathetically; the hard check read the schema and asked the question the judge wouldn't have thought rude to ask, which is whether the structured field is actually empty.

A dashboard that rendered the `players[]` array would put "Xherdan Shaqiri, MID, £0.0m" on the page with a confidence bar. The prose disclaiming this would sit alongside, in a different column. The reader's eye would land on the row first.

I think the reason I'd half-assumed the layers would agree on cases like this is that the failure is obvious to a person reading carefully. It isn't obvious to an LLM reading the prose first and weighing prose heavily, because the prose carries most of the apparent signal. The hard check is doing the thing the judge would feel impolite doing.

The second surprise came when I sat down to hand-rate three cases against the judge's scores to calibrate. I'd picked one case I expected the judge to nail, one I expected disagreement on, and one I wasn't sure about. The point was to check that the judge wasn't systematically lenient or harsh. Mean absolute delta across eleven rubric bullets came out to exactly 1.0, which is right on the line I'd set for "publish-able vs needs-tightening". Most bullets agreed within a point. One bullet disagreed by four.

It was on a squad-aware case. The question is "Salah's fixtures look tough; should I bench him this week?". The rubric asks for a verdict shaped as start, bench, or captain elsewhere. The judge scored that rubric bullet 1 out of 5. I scored it 5 out of 5. We had read the same response.

The agent had noticed that Salah wasn't in the user's squad and pivoted to the closest defensible question ("don't make a panic transfer for Salah given his form and fixtures"). I read that as obviously the right move. The judge read the rubric, looked for the verdict shape, didn't find one, and scored accordingly.

Both of us were right. The judge was right about the rubric. I was right that the rubric had a broken premise: the canned `UserSquad` fixture the case ran against didn't contain Salah, so the question "should I bench him" had no concrete subject. The agent did the human thing. The judge did the literal thing.

LLM judges read rubrics as contracts and execute them literally, which I hadn't anticipated either. If the contract has an unstated assumption ("Salah is in the squad"), the judge will not detect the break, will score against the literal contract, and will look biased when actually the rubric author has slipped. The fix isn't a smarter judge model; it's writing tests for the rubric the same way I'd write tests for the agent.

I patched the squad fixture to force-include Salah as a non-captain starter and re-ran the case. Same judge, same agent, same rubric. The judge moved from 2.75 to 4.80. The agent hadn't changed. The fixture had. The judge had been honest the whole time.

The third surprise wasn't about LLM grading at all, and was the one I'd anticipated least. The agent reads from a snapshot of the FPL player table, dumped from Neon to a parquet file committed to the repo, so the eval is reproducible across gameweeks; scores only move when the agent changes, not when Salah scores a hat-trick or van Dijk picks up a knock. I'd added a pre-write assertion layer to the snapshot regeneration script as a "let's be careful" gesture, more out of habit than out of conviction it would do anything. Before the script writes a new parquet, it walks every eval case, pulls the named players, and confirms they're present in the snapshot it's about to commit. If any aren't, the script refuses to write.

I'd half-expected this to do nothing. The first time I ran it against the live database, two cases failed. Maddison had been quietly filtered out of FPL's active player pool. Alexander-Arnold had transferred to Real Madrid the previous summer. Both were absent from the new snapshot. Both would have caused silent failures in the eval, surfacing as "the agent fabricated injury data" and "the agent couldn't resolve a famous nickname", when actually the agent was operating correctly against missing data.

This one isn't really about evals; it's about the data layer of reproducibility, which I'd never thought about properly. The call-layer reproducibility tricks are well-trodden. Everyone caches LLM outputs, everyone version-pins prompts, everyone records seeds. The data layer shifts under you on a slower but more consequential timescale, and nothing in the standard kit catches it. A snapshot you commit, plus an assertion gate that refuses to overwrite it with something that would silently break your tests, costs a couple of hours to set up and removes a class of failure I'd otherwise have spent weeks debugging when the symptoms surfaced as score drift.

None of the three things above were what I'd written the framework to catch. They were what happened on Friday evening when I ran it for the first time, and the kind of thing that would have shipped silently if I'd kept doing what I was doing before. That's a better return than I expected for a couple of days of work. Most of the value is still ahead, in the runs I'll do next week and the week after, when I have a stable yardstick to measure against.

The framework lives at [github.com/ikuzuki/fpl-platform](https://github.com/ikuzuki/fpl-platform), under `services/agent/src/fpl_agent/evaluation/`. The full baseline writeup is in [docs/evals/baseline.md](https://github.com/ikuzuki/fpl-platform/blob/main/docs/evals/baseline.md). The agent it grades is the [Scout Agent](/projects/scout-agent/), live at [fpl.isseikuzuki.co.uk/chat](https://fpl.isseikuzuki.co.uk/chat). Paste a team ID, ask for a transfer recommendation, watch the four-node loop run.
