# Agent State Repo Layout

The agent state repo holds per-agent workspaces, memory databases, session
history, and shared knowledge files. This repo should be **private**. It is
cloned to each agent host by the `agent_state` Ansible role and symlinked
into the OpenClaw data directory.

## Directory Structure

```
my-agents/
├── shared/
│   └── knowledge/
│       └── employee-handbook.md        # Shared across all agents (memorySearch extraPaths)
├── agents/
│   ├── alice/
│   │   ├── workspace/
│   │   │   ├── SOUL.md                 # Personality and operating principles
│   │   │   ├── IDENTITY.md             # Name, emoji, avatar
│   │   │   ├── AGENTS.md               # System prompt and instructions
│   │   │   ├── TOOLS.md                # Tool-specific instructions
│   │   │   ├── MEMORY.md               # Always-in-context core memory (~3K tokens)
│   │   │   ├── BOOTSTRAP.md            # First-session setup instructions
│   │   │   ├── HEARTBEAT.md            # Periodic task schedule
│   │   │   └── skills/
│   │   │       ├── my-custom-skill/
│   │   │       │   └── SKILL.md
│   │   │       └── shared-skill -> ../../../bob/workspace/skills/shared-skill
│   │   ├── memory/
│   │   │   ├── memfacta.sqlite         # Structured fact database
│   │   │   ├── work.sqlite             # Work context database
│   │   │   ├── dumps/
│   │   │   │   └── memfacta.sql        # Portable SQL dump (for new host bootstrap)
│   │   │   ├── entities/               # Entity JSON exports
│   │   │   ├── pipelines/              # Memory extraction scripts
│   │   │   └── README-MEM-FACTA.md     # Memory system documentation
│   │   └── sessions/
│   │       ├── sessions.json           # Session index
│   │       └── *.jsonl                 # Session transcripts
│   └── bob/
│       ├── workspace/
│       │   ├── SOUL.md
│       │   ├── IDENTITY.md
│       │   └── skills/
│       │       └── shared-skill/
│       │           └── SKILL.md
│       ├── memory/
│       │   └── dumps/
│       └── sessions/
└── README.md
```

## Key Files

### Workspace Files

These files are loaded into the agent's context at session start. They define
who the agent is and how it operates.

| File | Purpose | Updated by |
|------|---------|-----------|
| `SOUL.md` | Personality, boundaries, security principles | Agent (with disclosure) |
| `IDENTITY.md` | Name, creature type, vibe, emoji, avatar | Agent (first session) |
| `AGENTS.md` | System prompt, behavioral instructions | Operator |
| `TOOLS.md` | Tool-specific guidance and restrictions | Operator |
| `MEMORY.md` | Core memory, always in context (~3K tokens) | Agent |
| `BOOTSTRAP.md` | First-session setup checklist | Operator |
| `HEARTBEAT.md` | Periodic tasks (memory extraction, health checks) | Operator + Agent |

### Skills

Skills are directories under `workspace/skills/` containing a `SKILL.md`
file. They extend the agent's capabilities with domain-specific instructions,
commands, and tool configurations.

**Sharing skills between agents:** Use relative symlinks:

```bash
cd agents/bob/workspace/skills
ln -s ../../../alice/workspace/skills/my-skill my-skill
```

Skills are referenced by name in the agent's `skills` config field:

```yaml
openclaw_agents:
  - id: "bob"
    skills: ["my-skill"]
```

### Memory System

The memory directory contains the agent's long-term memory. The default
system is MemFacta — a SQLite-backed fact database with FTS5 full-text
search.

| File | Purpose |
|------|---------|
| `memfacta.sqlite` | Fact database (entities, facts, daily notes, edges) |
| `work.sqlite` | Work context and project tracking |
| `dumps/*.sql` | Portable SQL dumps for bootstrapping new hosts |
| `entities/` | JSON exports of the knowledge graph |
| `pipelines/` | Shell scripts for memory extraction and querying |

SQL dumps are automatically restored to `.sqlite` files by the `agent_state`
Ansible role during deployment.

### Shared Knowledge

The `shared/knowledge/` directory is mounted into every agent's
`memorySearch.extraPaths`. Files here are indexed for semantic search across
all agents. Use this for organization-wide context: handbooks, policies,
reference material.

## How Deployment Works

1. The `agent_state` role collects unique `state_repo` URLs from `openclaw_agents`
2. Repos are cloned (or pulled if already present) via HTTPS through Pipelock
3. Per-agent directories are created under `~/.openclaw/agents/<id>/`
4. Workspace and memory directories are symlinked from the cloned repo
5. `shared/` is symlinked to `~/.openclaw/shared` (if it exists)
6. SQL dumps are restored to SQLite databases

## Creating a New Agent

1. Create the directory structure:
   ```bash
   mkdir -p agents/new-agent/{workspace/skills,memory/dumps,sessions}
   ```

2. Copy the template files:
   ```bash
   cp agents/alice/workspace/SOUL.md agents/new-agent/workspace/
   cp agents/alice/workspace/IDENTITY.md agents/new-agent/workspace/
   ```

3. Customize IDENTITY.md with the new agent's name and details

4. Symlink shared skills if needed:
   ```bash
   cd agents/new-agent/workspace/skills
   ln -s ../../../alice/workspace/skills/shared-skill shared-skill
   ```

5. Commit and push — the `agent_state` role will pick it up on next deploy

Or use the onboarding script in openclaw-hardened:
```bash
./scripts/onboard-agent.sh --id new-agent --name "New Agent"
```

## See Also

- [Operations Guide](../operations.md) — adding agents, managing skills
- [Site Config Schema](../site-config-schema.md) — `openclaw_agents` field reference
- [Installation Guide](../installation.md) — first-time setup
