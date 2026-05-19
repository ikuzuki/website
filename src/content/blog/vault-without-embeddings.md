---
title: Why I ripped out my embedding pipeline and went back to plain markdown
description: I built a hybrid FTS5 + LanceDB MCP server with an Ollama embedding pipeline for my personal knowledge vault. After two months I deleted all of it.
pubDate: 2026-05-19
draft: true
tags: [llm, rag, personal-knowledge, claude-code]
---

In 2026 everyone is building RAG. The shape is familiar: ingest some documents, chunk them, embed them, index the embeddings, do hybrid retrieval at query time, stuff the top-k into the model's context. I spent April building exactly this for my personal knowledge vault. Then I deleted all of it.

This is the writeup of why, because I think the lesson generalises beyond my use case — and because most "we built a RAG" posts don't ever get the "and then we deleted it" follow-up they deserve.

## What I built

My personal knowledge vault is a curated set of markdown files — strategy notes, ADRs, project hubs, people notes, design playbooks, voice guides. The folder taxonomy is fairly disciplined; the frontmatter on each file is enforced (title, created date, tags, explicit links to neighbours). About 216 files when I started building the retrieval layer, growing slowly.

The system I built around it:

- A FastMCP server (`knowledge-mcp`) exposing search and read tools to Claude Code over the MCP protocol.
- SQLite FTS5 for lexical search — full-text indexes over every markdown file, refreshed by a file watcher.
- LanceDB for vector search — Ollama's `nomic-embed-text:v1.5` running locally, embedding chunks at 768 dimensions.
- A hybrid scorer that combined FTS rank and vector similarity, weighted and re-ranked.
- A file watcher (`watchdog`) that triggered re-indexing on every change.
- A sidecar of frontmatter for structured filters — search by `tag`, by `created` range, by `folder`.

About 600 lines of plumbing. It worked. Claude could call a `search` tool, get back the top-k chunks, use them. Quality was decent.

## Why I deleted it

Three things happened in the same week.

The first was a measurement. I had a calibration set of about thirty test queries I'd written against the vault, with known-good answers. I ran them against the MCP-served hybrid search, then ran the equivalent through a plain `Glob` + `Grep` + `Read` pipeline — letting Claude grep across the vault, read the matching files, and synthesise an answer from raw markdown.

The hybrid system was 3-5% better, on a search-quality metric I'd defined fairly generously. Not nothing. Also not 600 lines of plumbing and a daemon dependency.

The second was three bugs surfacing in the same week. The Windows file watcher missed MCP-authored files — when the MCP wrote a new note via its own tool, the watcher didn't fire because `os.replace` on Windows doesn't reliably trigger `on_modified` on the renamed target. Result: I'd write a note, and then it wouldn't appear in search until I touched it manually. FTS and vector writes weren't atomic; I caught a 20% retrieval gap once where the FTS index had ingested a batch but the vector index hadn't. The chunk tokenizer in my retrieval code didn't match the tokenizer the embedder used, so the vector index was scoring against slightly-different chunks than I was searching against.

Each bug was findable and fixable. Together they were a maintenance load on a system that was supposed to make my life easier.

The third was reading Karpathy's note on his LLM wiki — plain markdown files, no vector store, the LLM "compiles" answers by reading the files directly. About 100 articles at his scale. My vault was about twice that and growing. The architecture matched: markdown files, frontmatter, no daemon, no index.

The decision became obvious. The fancier system was solving a problem I didn't have (retrieval at scales beyond the context window) while creating problems I did have (a brittle indexing pipeline with three coupled bugs). The simpler system was already what I needed and was what I'd revert to anyway every time the fancier system broke.

I deleted the MCP server, the FTS5 layer, the LanceDB layer, the Ollama dependency, the file watcher, and the 600 lines around them. I replaced them with three skills in a Claude Code plugin.

## What replaced it

Three skills in a personal Claude Code plugin (`issei-plugin`), each replacing a different role of the MCP:

`search-vault` is a Glob + Grep + Read pipeline. The skill description tells Claude when to use it (any time the user references something likely to be in the vault); the skill body explains the folder taxonomy and the search strategy; Claude runs the appropriate combination of file pattern matching, content search, and direct reads. No index, no daemon, no embedding. The latency is whatever Grep takes — usually well under a second for the whole vault.

`distil-vault` takes raw inbox material (a meeting note, a chat dump, a freewrite) and produces a curated vault note. The interesting part: it doesn't just write the new file. It updates 5-15 cross-referenced neighbours — adding backlinks, updating "related" sections, promoting tags across files that mention the same concept. The compile step happens at write time, not query time. This is the load-bearing thing in the new design.

`lint-vault` runs whole-vault consistency checks. Missing backlinks. Orphan files. Frontmatter drift. Files in the wrong folder for their content. Runs on demand, takes maybe ten seconds for the full vault.

Combined, these three skills do what the MCP did and more — because the MCP only handled retrieval. The new design handles synthesis (`distil-vault`) and consistency (`lint-vault`) too, which the MCP architecture didn't really have a natural home for.

## Why this works at this scale and won't at others

The whole approach rests on one constraint: the vault has to fit in Claude's context. If I had 10,000 documents, Glob + Grep wouldn't work. If documents were heterogeneous in length and structure, the "Claude reads relevant files" affordance would break down. If retrieval quality was a competitive moat — for example, if I were building a customer-facing RAG product — 3-5% would matter.

For a personal vault at a few hundred curated files, with disciplined frontmatter and links, the constraint is satisfied and the simpler architecture wins.

This is the more general point. Vector retrieval is the right answer for a class of problem — long corpora, mixed-domain knowledge, multi-tenant systems, RAG over content you don't control. Plain markdown + grep is the right answer for a different class — curated personal-scale knowledge that fits in context, where the bottleneck isn't retrieval quality but synthesis discipline.

The mistake I made — and that I see in a lot of personal RAG projects on Twitter — was reaching for the platform-level solution before checking whether the platform-level problem existed. RAG is a powerful tool for the cases that need it; reaching for it on cases that don't is engineering theatre.

## The synthesis-at-write-time insight

The most durable thing I learned from this project isn't "don't use RAG for small corpora." It's about *when* synthesis should happen.

The MCP-based system synthesised at query time: I ask a question, the system retrieves chunks, Claude reads them and produces an answer. The synthesis cost is paid every time I ask a question.

The new system synthesises at write time. When I drop a new note into the inbox, `distil-vault` produces the curated version *and* updates the neighbours that need to know about it. The cross-references, the backlinks, the related sections — they're all updated then, by an LLM that has the new content and the affected files in context at the same time. By the time I'm querying, the synthesis is already done; the vault is already coherent.

The trade-off: write-time synthesis is more expensive than query-time retrieval if you only ever read a given note once. But on a personal vault, the same content gets read dozens of times over its life. Front-loading the synthesis cost pays back many times over.

There's an analogy with compiled vs interpreted languages here that I won't push too hard. The right framing is: synthesis at write time keeps the vault navigable as it grows; synthesis at query time makes you depend on retrieval being good enough. Different problems, different tradeoffs.

## What I'd tell someone considering RAG over a personal vault

Three questions, in order.

How many documents do you have? If the answer is "fewer than the model's context window allows," start with plain markdown plus Claude's built-in Read/Grep/Glob. You can always add retrieval later if the corpus grows past the threshold. The other direction — building retrieval, then trying to delete it — is harder, because you'll have accumulated dependencies on the indexing pipeline (file watcher quirks, frontmatter assumptions, tokenizer choices) that don't come out cleanly.

How disciplined is your frontmatter? RAG can work over messy documents because retrieval treats them as opaque chunks. The simpler architecture demands more discipline at write time — folder taxonomy, explicit links, schema-enforced frontmatter. If you're not willing to enforce that, RAG might be the right call because it'll work despite the mess. But the cost is that you've offloaded the discipline to an unreliable retriever.

What's your read-to-write ratio? If you write once and read many times — and most personal knowledge bases are like this — write-time synthesis is the better investment. If you read once and move on, query-time retrieval makes more sense.

The reflexive answer in 2026 is to build the embedding pipeline because that's what everyone's doing. The contrarian answer, for personal-scale curated knowledge, is to delete it. It turns out the harder skill isn't building the pipeline; it's recognising when you don't need one.
