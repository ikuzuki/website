---
title: Migrating a 20-engineer team from Cursor to Claude Code
description: What it took to move a working AI-coding setup from Cursor to Claude Code across a small engineering team, and what I'd do differently next time.
pubDate: 2026-05-19
draft: true
tags: [ai-engineering, tooling, claude-code, team]
---

The decision to move our team off Cursor and onto Claude Code didn't start as a tooling project. It started because a quiet thing was happening at the edges of every AI-coding conversation: people kept hitting context limits in the middle of useful sessions and starting over. The fix at the time was "open a new chat and re-paste the relevant files," which is the AI-coding equivalent of restarting the program every time you get a segfault. Useful in a pinch, expensive over a year.

Claude Code looked like the runtime that would actually move the bottleneck. A larger usable context, a real filesystem-level integration, hooks that fire at session boundaries, a plugin system that lets a team ship standards centrally instead of by Slack message. The migration itself took about three weeks of part-time work for me and one other engineer, and another month for the team to settle into. The interesting bits are the things I didn't expect.

## The tool isn't the thing

Cursor and Claude Code are both wrappers around frontier models. Both can read your code, edit files, run commands. If the abstraction was the model, the migration would have been a no-op. It wasn't, and the reason is that the differences sit one layer down — in how each tool wants you to *structure context*.

Cursor leans on @-mentions and a live-edit loop. You're sitting in your editor, you @ the files you want in context, you chat about them, edits happen in-place. The mental model is "AI as a pair programmer who can see what's on my screen." That's a fine model for in-the-moment work. It falls apart when you want consistency across people, across repos, across weeks — because what's "on the screen" is different every time.

Claude Code's model is closer to "AI as an agent that operates against a project." The project has files. Some files configure the agent (`CLAUDE.md`, plugins, skills, hooks). Some files are the work. The agent reads them all, decides what's relevant, and acts. The difference is that "what's in context" is no longer ad-hoc — it's defined by files you commit. A teammate joining the codebase next month gets the same context I have, automatically, because the standards are layered into files Claude loads.

This sounds like a small thing. It is not a small thing. The leverage in AI coding at team scale is in the second pattern, not the first.

## What we actually had to move

The literal migration was small. Most engineers had a `.cursorrules` file that mostly restated coding standards we already had documented elsewhere. The new structure was:

A per-repo `CLAUDE.md` carrying the things that are true of this specific repo and only this repo — the Python version, the active branch of work, the one weird gotcha about how this repo's release pipeline behaves. Deliberately thin. The rule we settled on after some debate is "only what the plugin cannot know."

A team plugin — `intech-ai-plugin` — carrying everything that's true across every repo: coding standards, branch-naming conventions, the commit-message format, the code-review checklist, the ADR template. Plugins ship skills (autoloaded on intent match) and hooks (autoloaded on session events), so a developer who installs the plugin gets all of it without having to know which file does what.

A confluence-fronted layer above both for the things that are too big to load into every session: HLDs, ADRs, architecture decisions. The plugin includes an Atlassian MCP, so Claude can fetch a Confluence page by name on demand. Not auto-loaded, just available.

That's the four-layer architecture we ended up with. Confluence at the top (broadest, lazy-loaded). Plugin skills below that (cross-repo patterns, eager-loaded on context match). Per-repo `CLAUDE.md` below that (instances, always-loaded when the repo is open). Nested per-directory `CLAUDE.md` at the bottom for the rare structurally-distinct subdirectories. Patterns versus instances; the rule that decides which layer something belongs in is *does it apply to one repo or to many*.

## The thing I didn't expect: plugin enforcement beats prompt nagging

The first version of the team's coding standards lived in a long `# Coding Standards` section of every per-repo `CLAUDE.md`. Half of every file was the same content. Drift was inevitable; within a couple of months three repos disagreed about whether to use `type | None` or `Optional[type]`. Standard problem with copy-paste configuration.

I assumed the fix was a `coding-standards.md` in the team plugin that the model would reference. It is — but the deeper fix turned out to be a different shape of artefact. Skills with strong descriptions outperform documents because the model loads them automatically when the user's intent matches the skill's description. A `code-review` skill described as "Use when reviewing PRs or pre-commit changes" fires every time someone asks for a code review, and *that* skill imports the coding-standards reference. The user doesn't have to remember to point at the standard; the standard finds the conversation.

This generalises into a stronger statement: hooks and skills enforce standards, prompts don't. If a rule has to be remembered to be applied, it'll be forgotten. If it's hooked into the entry point — a `SessionStart` hook that nudges the developer to scaffold `CLAUDE.md` when one is missing, a pre-commit hook that auto-formats, a skill that fires on code-review intent — it's enforced.

The corollary, which I wish I'd internalised earlier: every time you find yourself writing "remember to do X" in `CLAUDE.md`, you're admitting the standard isn't enforced. Move it into a hook or a skill, or accept that it'll be skipped half the time.

## Reviewer agents in parallel are the unlock

The single highest-leverage thing in the new setup isn't the larger context window or the plugin model. It's the `code-review` skill that fans out into ten specialist agents in parallel.

A single "review this PR" prompt can produce reasonable output, but it's a generalist. Asking one model to simultaneously check for breaking API changes, scope creep against the Jira ticket, test coverage gaps, silent failures, type-design weakness, comment accuracy, simplification opportunities, regression of previously-fixed bugs, and Confluence-cited standards violations means each check gets a small slice of the model's attention. Findings come back vague, miss the specific thing the team standard actually requires, and the developer learns to ignore them.

Splitting that into ten agents, each with its own prompt and its own narrow lens, produces sharper findings. The breaking-change detector knows what API surface looks like and ignores everything else. The silent-failure hunter knows what broad exception handling looks like and flags it specifically. They all run in parallel and the orchestrating skill collates the output.

The cost: ten parallel sub-agents in the context budget. The benefit: findings that cite the specific team standard, with the specific line number, that the developer can act on without arguing. That last bit is the adoption lever — devs stop arguing with the reviewer when it points at their own team's documented standard. Without the citation, every finding is contestable; with it, the conversation moves on.

## What broke

Three things, in order of how much time they cost.

The first was the `gh` versus GitHub MCP decision. The MCP looked cleaner — typed tool calls, no shell-out, principled. In practice every developer had `gh` on their machine already, authenticated, with the right org context cached. The MCP required separate auth, kept its own credential state, and broke when the dev's OS keychain rotated. We moved everything to `gh` shell calls. Less typed but actually works. The lesson: prefer the thing already on the machine.

The second was release-please. PR title prefixes silently miscategorise if you get them wrong — `feat:` instead of `feature:` matters, and so does the breaking-change footer. The plugin's `coding-standards` skill now spells out the conventional-commits format and the release-please rules in one place, and the commit hook validates the format before push. Before that, every release cycle had a quiet "why didn't this version bump?" conversation.

The third was migrating muscle memory. Engineers who'd built habits around Cursor's @-mention loop kept reaching for it in Claude Code and missing it. The honest answer was patience: the new model is better at team scale, but worse-feeling for a few weeks because the affordance you're used to is gone. After three to four weeks people stopped noticing.

## What I'd do differently

Two things.

One, I'd ship the plugin scaffold before the migration, not during. We migrated repos first and built the plugin in parallel, which meant the first month had no team-wide standards loaded — engineers were on whichever `CLAUDE.md` they'd hand-written, and consistency was worse than under Cursor. If the plugin had been the first artefact, the migration would have been a strict improvement from day one.

Two, I'd be more aggressive about deleting `CLAUDE.md` content. Our first per-repo files were 200 lines, mostly content that belonged in skills. The rule "only what the plugin cannot know" came late; if I'd started with that rule the files would have been 30 lines from day one and we wouldn't have spent the first quarter merging duplicated content out.

The migration's been net positive. The team's faster, the standards drift less, the PR review feedback loop is sharper. None of that is because Claude Code is a strictly better model than Cursor was — they're roughly equivalent at the model layer. It's because the tooling forced a structure that survives team scale, where the previous structure didn't.
