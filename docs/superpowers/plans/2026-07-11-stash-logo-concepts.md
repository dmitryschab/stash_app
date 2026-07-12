# Stash Logo Concepts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate and validate three bookmark-led Stash app-icon concepts as production-ready 1024 × 1024 PNG files.

**Architecture:** Use the built-in image generator once per distinct concept, with each prompt sharing the approved bookmark-first constraints and using a distinct secondary metaphor. Copy every generated final into `App/branding/concepts/`, inspect it visually, and verify its format, dimensions, and byte size locally.

**Tech Stack:** Built-in image generation, PNG, macOS `sips`, shell file inspection

## Global Constraints

- The bookmark/stash silhouette is the dominant, immediately readable symbol.
- Music, coding, coffee, and source-control references remain secondary details.
- Use flat, vector-friendly geometry with restrained print texture.
- Include no lettering, words, trademarks, mascots, mockup devices, or photorealism.
- Keep critical artwork inside generous safe margins and use opaque edges.
- Each final must be a 1024 × 1024 PNG under 5 MB.

---

### Task 1: Generate Crate Digger

**Files:**
- Create: `App/branding/concepts/stash-crate-digger-1024.png`

**Interfaces:**
- Consumes: approved Stash logo design spec
- Produces: primary recommended app-icon concept

- [ ] **Step 1: Generate the concept**

Use the built-in image generator with a `logo-brand` prompt: a bold bookmark containing abstract vinyl grooves that also read as a sparse code branch, with a tiny generic commit-node motif. Use warm cream, espresso brown, muted coral, and Stash indigo; evoke an independent record sleeve and coffee shop. Require centered flat geometry, generous safe margins, no text, no letters, no trademarks, no GitHub mascot, no TikTok note, no device mockup, and no photorealism.

- [ ] **Step 2: Save the generated file**

Copy the selected generated PNG to `App/branding/concepts/stash-crate-digger-1024.png` without overwriting an unrelated existing asset.

- [ ] **Step 3: Validate the asset**

Run `sips -g pixelWidth -g pixelHeight -g format App/branding/concepts/stash-crate-digger-1024.png` and `stat -f %z App/branding/concepts/stash-crate-digger-1024.png`. Expect width `1024`, height `1024`, format `png`, and size below `5242880` bytes. Inspect the image and a 128 px thumbnail for bookmark-first readability and forbidden text or marks.

### Task 2: Generate Coffee Commit

**Files:**
- Create: `App/branding/concepts/stash-coffee-commit-1024.png`

**Interfaces:**
- Consumes: approved Stash logo design spec
- Produces: warm coffee-and-code app-icon concept

- [ ] **Step 1: Generate the concept**

Use the built-in image generator with a `logo-brand` prompt: a bookmark whose negative space subtly forms a coffee cup, with two steam strokes suggesting code brackets or a branching graph and one small circular vinyl groove. Make the bookmark read first and the cup/code details second. Use cream, coffee brown, muted teal, coral, and indigo; centered flat geometry, generous safe margins, no text, no letters, no trademarks, no mascots, no device mockup, and no photorealism.

- [ ] **Step 2: Save the generated file**

Copy the selected generated PNG to `App/branding/concepts/stash-coffee-commit-1024.png` without overwriting an unrelated existing asset.

- [ ] **Step 3: Validate the asset**

Run the same `sips` and `stat` checks as Task 1 against `stash-coffee-commit-1024.png`. Inspect the image and a 128 px thumbnail; require the bookmark to remain dominant and the secondary cup/code cues to remain legible but restrained.

### Task 3: Generate Midnight Stash and compare the set

**Files:**
- Create: `App/branding/concepts/stash-midnight-1024.png`

**Interfaces:**
- Consumes: approved Stash logo design spec and the two preceding concepts
- Produces: dark technical app-icon concept and a validated three-concept set

- [ ] **Step 1: Generate the concept**

Use the built-in image generator with a `logo-brand` prompt: layered bookmark cards on a near-black midnight background, restrained teal and coral offset-print accents, sparse generic commit nodes and connecting strokes, and one groove or waveform. Aim for an underground old-school hip-hop and quietly technical mood. Require centered flat geometry, generous safe margins, no text, no letters, no trademarks, no mascots, no device mockup, and no photorealism.

- [ ] **Step 2: Save the generated file**

Copy the selected generated PNG to `App/branding/concepts/stash-midnight-1024.png` without overwriting an unrelated existing asset.

- [ ] **Step 3: Validate all deliverables**

Run `sips` and `stat` checks for all three PNGs. Inspect each at full size and 128 px. Confirm that all three are bookmark-first, contain no unwanted text or protected brand marks, share a coherent family resemblance, and remain visibly distinct side by side.

