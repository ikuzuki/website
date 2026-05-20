---
title: I deleted my embedding pipeline
description: I built a hybrid FTS5 plus LanceDB MCP server with an Ollama embedding pipeline for my personal knowledge vault. After two months I deleted all of it. This is the long version.
pubDate: 2026-05-14
draft: true
tags: [llm, rag, personal-knowledge, claude-code]
---

In May I ran `rm -rf` on about six hundred lines of code that worked. The retrieval pipeline I'd spent April building, with SQLite FTS5 for lexical search, LanceDB for vectors, an Ollama embedder, a file watcher, and a hybrid scorer that re-ranked the two together. Two months of evenings, gone in one command. The vault it served, my personal knowledge base of about 216 markdown files, now gets read by Claude directly, with no index in front of it.

This is the post-mortem on that decision, partly because friends keep asking why, and partly because I think the lesson is more general than I first thought.

The thing I'd built was, in 2026 terms, unremarkable. A FastMCP server exposing `search` and `read` tools to Claude Code over the Model Context Protocol. SQLite FTS5 for full-text search, refreshed by a `watchdog` file watcher on every change to the vault. LanceDB for vectors, with `nomic-embed-text:v1.5` running locally through Ollama at 768 dimensions. A custom scorer that combined FTS rank and vector cosine similarity, weighted and re-ranked. A sidecar of frontmatter for structured filters, so I could search "by tag" or "by created date range" or "by folder". It worked. Claude would call `search`, get the top-k chunks back, use them. Quality was decent.

Around early May three things landed at the same time and changed my mind on the whole approach.

I'd written a calibration set, about thirty queries against the vault with hand-graded "good answer" outputs. Mostly to tune the FTS-vs-vector blend in the hybrid scorer. On a whim I ran the same calibration set through a different setup: no MCP, no search tool, just Claude calling `Glob` and `Grep` and `Read` against the vault directly. I expected the difference to be obvious. It wasn't. Three to five percent better on the hybrid scorer, on a generous quality metric I'd defined myself. Not nothing, but not 600 lines of plumbing and a daemon dependency. I sat with that for a couple of days, ran it on a fresh calibration set in case I'd accidentally overfit the first one, got the same answer. The retrieval problem the MCP was solving wasn't really a problem at this corpus size.

In the same week three real bugs surfaced in the indexing path. The Windows file watcher missed MCP-authored files. When the MCP wrote a new note through its own tool, the watcher didn't fire, because Python's `os.replace` on Windows doesn't reliably trigger `on_modified` on the renamed target<sup>1</sup>. I'd write a note via Claude, ask Claude to find it, and it wouldn't be in the index until I touched the file manually. The FTS and vector writes weren't atomic. I caught a roughly 20% retrieval gap once where the FTS index had ingested a batch but the LanceDB writer had crashed quietly, leaving the two indexes out of sync. And the chunk tokenizer in my retrieval code didn't match the tokenizer that the embedder used, so the vector index was scoring against slightly-different chunks than I was searching against. Each bug was findable. Together, they were a maintenance load on a system that was meant to make my life easier.

The third thing was a Karpathy note on his LLM wiki: plain markdown files, no vector store, the model "compiles" answers by reading files directly. He was at about a hundred articles. I was at about two hundred and growing slowly. The architecture matched: markdown, frontmatter, no daemon, no index.

I deleted the MCP server, the FTS5 layer, the LanceDB layer, the Ollama dependency, the file watcher, the 600 lines around them. Took maybe ninety minutes including the commit message.

What replaced it isn't a like-for-like swap. The MCP only handled retrieval. Three skills in my personal Claude Code plugin do what the MCP did, plus the synthesis work I'd never had a clean home for.

`search-vault` is a `Glob` plus `Grep` plus `Read` pipeline. The skill description tells Claude when to fire it (any time the user references something likely to be in the vault); the skill body explains the folder taxonomy and the search strategy; Claude picks the right combination of file pattern matching, content search, and direct reads. No index, no daemon, no embedding step. Latency is whatever `Grep` takes, which is well under a second for the whole vault.

`distil-vault` takes raw inbox material, a Cowork transcript, a Claude Code session dump, a freewrite from the morning, and produces a curated vault note. Writing the new file is the obvious part; the load-bearing part is that the skill also updates 5 to 15 cross-referenced neighbours, adding backlinks, refreshing "related" sections, propagating new tags across files that mention the same concept. The synthesis happens once, by the LLM, at the moment a note enters the vault.

`lint-vault` runs whole-vault consistency checks. Missing backlinks, orphan files, frontmatter drift, files in the wrong folder for their content. Runs on demand. Maybe ten seconds on the full vault.

Combined, these three do more than the MCP did, because the MCP only did retrieval. Retrieval at write-time is half of what makes a personal vault useful (the other half is synthesis discipline, and the MCP had no opinion on that).

Now to the part that took me longer to internalise. The framing matters more than the architecture choice.

Synthesis can happen at query time or at write time. The MCP did query-time synthesis: I ask a question, the system retrieves chunks, Claude reads them and produces an answer. Every question pays a retrieval cost. The new design does write-time synthesis: when a new note lands, the LLM updates neighbours then and there, with the new content and the affected files in context at the same time. By the time I'm querying, the vault is already coherent. The trade is paying once per write versus paying once per read. On a personal vault, where the same content gets read dozens of times over its life, write-time is the cheaper end<sup>2</sup>.

The objection I'd expect, and which I asked myself out loud before deleting anything, is "you're trading retrieval quality for write-time effort". In my eyes this is the right trade for the corpus shape, but it really does only work because the corpus is small enough to fit in Claude's context. If I had ten thousand documents, `Glob` plus `Grep` would fall over and I'd be back to retrieval. If the documents were heterogeneous and long (a few hundred PDFs, say), the "Claude reads the relevant files" affordance would break down. If I were building a customer-facing RAG product, 3 to 5 percent retrieval quality might matter. None of those apply to a personal vault.

What I'd say to someone considering this for their own setup is roughly: start with plain markdown plus the model's built-in `Read`, `Grep`, `Glob`. You can always add retrieval later. The reverse direction is harder, because you'll have accumulated dependencies on the indexing pipeline (file watcher quirks, frontmatter assumptions, tokenizer choices) that don't come out cleanly.

In 2026 the reflex move is to build the embedding pipeline. The thing I'd missed in April was that recognising when not to build it is a separate skill, and arguably the more valuable one.

---

<sup>1</sup> The atomic-rename pattern (write to `.tmp`, then `os.replace` onto the target) is standard for safe file writes; I'd been using it for exactly that reason. The Windows kernel emits a `FILE_ACTION_RENAMED_OLD_NAME` and `FILE_ACTION_RENAMED_NEW_NAME` pair, which `watchdog`'s `FileSystemEventHandler.on_modified` doesn't see. The fix was to also listen for `on_moved` and treat moves to a known vault path as modifications. By the time I'd written the patch I'd already started doubting the whole stack.

<sup>2</sup> The analogy with compiled versus interpreted languages is tempting and I don't think it's quite right; the cost asymmetry is different. Write-time-synthesis is more like building a search index that's also a referential-integrity check. Anyway, the cost shape is what matters.
