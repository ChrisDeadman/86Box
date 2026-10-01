# AGENTS.md

Rules for working with this 86Box fork.

This is a fork of 86Box, mainly for fixing issues or using it as a vehicle for `.scratch/projects`.
The local develop branch is ours; the base is upstream/master.

## Local Additions

```
.agents/
└── skills/     # Agent-maintained 86Box skills (automation, build, host/guest debug, profiling, etc.)
.scratch/
├── archive/    # Old/archived investigations, findings, scripts
├── projects/   # Self-contained 86Box-based projects
└── VM/         # Symlink to external VM data (disk images, shaders, game media)
```

## Skills

Skills are the tooling: read the owning `SKILL.md` before building, driving, or
debugging. If you can't reliably observe or act, or you're looping on a
workaround, the skill set is the gap: extend the owning skill or add a new one,
rather than improvising or concluding on a broken channel.

## Greppable landmarks

@Agent working on this: please update this as you go.

## Pitfalls seen in this repository

@Agent working on this: please update this as you go.
- Host kernel 7.0 blocks user-mode `lgdt` (SIGSEGV, SI_KERNEL): 16-bit
  guest code cannot run natively here; pin its contracts in source or
  verify in 86Box.

## User Preferences

- Avoid em-dashes in code comments and documentation.
- Ask follow-up questions when requirements are ambiguous, require clarification, or likely to cause rework.
- Use bounded timeouts for long-running commands and tests. Do not use infinite timeout unless explicitly requested.
- Prefer extending an existing skill over adding an ad hoc script; if a skill does not fit, document why.

## Engineering principles

Apply to every contribution, human or agent. When in doubt, prefer the option
that makes the code easier to understand and change.

### 1. Single-responsibility modules

- One cohesive job per file. If its purpose needs "and", split it.
- No hidden global state. Modules communicate through interfaces, not
  module-level mutable variables.
- New files go where the architecture places them. If you cannot tell, fix the
  structure, not the file.

### 2. Error handling

- Fail fast and loudly. Validate at boundaries, never fall back silently.
- `LOG()` for diagnostics, `fatal()` for unrecoverable. Messages carry context.
- Fix root causes, not symptoms; no temporary bandaids or indirection that makes debugging harder.

### 3. Documentation that stays correct

- Comments explain why, not what.
- Record non-obvious architecture decisions, with the why.
- Prose describes responsibility and data flow, not signatures.

### 4. Incremental progress

- Commits are atomic: one logical change, `Component: description` style.
- Do not mix refactoring with feature work.

### 5. AI-agent readability

- Explicit over implicit. No clever macro tricks or indirection.
- One name per concept, across the whole tree.
- A module's purpose is readable from its header, not its implementation.

### 6. Documentation before source

- For a documented API, ABI, protocol, or format, the primary reference is the
  published spec or manual, never the source of one implementation.
- Pull references into the project's `refs/` (documentation, not source) and
  index each in `refs/README.md`: what it is, URL, version/hash, what it
  settles. Keep pulling as new questions arise.
- Read implementation source only when the spec is silent, ambiguous, or
  host-specific behavior matters; say which case applies when you do.
- If the spec, or one instrumented run with a clear verdict, settles a
  question, do not spend long stretches deriving it from source.

### 7. No rambling, ever

- A comment or log message: max 2 lines.
- A table row, list bullet, or doc entry: one short sentence, the same shape as its neighbors.
- Write only the non-obvious reason (a why / invariant / workaround). Never restate
  what the code, name, test, or neighboring row already says; never narrate the mechanism.
- Before finishing an edit to a comment or doc line, check it against the lines around
  it: if it is longer, or explains the obvious, it is rambling and must be cut.
- Commit messages stay short and focused. Past 8 lines, they are rambling; cut them.
