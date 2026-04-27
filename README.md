# Taskestro

A [Claude Code](https://claude.ai/code) skill that dispatches tasks from a TODO file into parallel development streams, each running in its own git worktree and tmux window.

> **Name.** *Taskestro* is Esperanto — `tasko` ("task") + `-estro` ("chief, master"). Literally: *taskmaster*. The skill itself is still registered with Claude Code as `task-orchestrator`; only the project / repo uses the Esperanto name.

## The problem

A typical Claude Code workflow looks like this: you write (or dictate) a list of tasks, hand them to Claude, wait for it to finish, run `/clear`, then feed it the next batch. If you want parallelism you open separate tmux windows manually — but then you can't dictate everything in one go, and you lose track of what's running where.

## How it works

1. You write a `TASKS.md` (or `TODO.md`) with everything you need done.
2. You ask Claude to dispatch — e.g. *"run my tasks"* or *"dispatch TODO.md"*.
3. The orchestrator parses the file, estimates complexity, picks a model (Haiku / Sonnet / Opus) per task, and presents a plan:

   ```
   Task                              | Model  | Branch
   ----------------------------------+--------+---------------------
   Redesign auth architecture        | opus   | wt/redesign-auth
   Add pagination to user list       | sonnet | wt/add-pagination
   Fix typo in README                | haiku  | wt/fix-readme-typo
   ```

4. After your OK it creates a git worktree per task in `.worktrees/<slug>/`, opens one tmux window per worktree running an interactive `claude` session, and a dedicated **monitor window** with `task-monitor -w` showing live status of all of them.
5. Each child writes a `.task.done` marker on exit. The orchestrator waits for all markers via `inotifywait` (push-mode, zero-poll), then merges the branches back, resolving simple conflicts automatically.
6. Final report: what was merged, what had conflicts, what produced no changes.

You save time, save tokens (smaller models handle simple tasks), and everything stays visible in one tmux session.

## Pipeline

```
TASKS.md → parse → estimate complexity → select model → create worktrees
        → launch tmux → claude CLI → inotifywait markers → merge → report
```

## The monitor (`task-monitor`)

A Fish function that renders the live dashboard. Scans every tmux pane in the current session whose `pane_current_path` matches `*/.worktrees/*` and reports:

- **State**: `awaiting-input` (!), `working` (●), `interrupted` (✗), `idle` (○), `done` (✓) — sorted by priority.
- **Age** since last Claude activity (from a `Notification` hook that timestamps prompts to `~/.cache/cc-monitor/`).
- **The actual question** when a task is waiting for your input.

Modes:
- `task-monitor` — single-shot table.
- `task-monitor -w` — refresh every 2s until Ctrl-C (what the orchestrator opens).
- `task-monitor --bar` — one-line summary suitable for the tmux status bar.

Source: [`scripts/task-monitor.fish`](scripts/task-monitor.fish). Helpers it shares with `task-pick` live in [`scripts/task-lib.fish`](scripts/task-lib.fish).

## The picker (`task-pick`)

Companion to the monitor. Where `task-monitor` *renders* the dashboard, `task-pick` lets you *act on* it interactively. Two modes:

- **fzf single-shot picker** (default) — lists worktree panes first, every other tmux pane below.
- **Full-screen TUI** (`task-pick --tui` or <kbd>Ctrl-T</kbd> from fzf) — redraws every 2s.

Keys: <kbd>Enter</kbd> jump to pane · <kbd>Ctrl-Y</kbd> send `1<Enter>` to accept the prompt the child is waiting on · <kbd>Ctrl-L</kbd> capture pane buffer to `less` · <kbd>Ctrl-X</kbd> kill pane (confirm) · <kbd>Ctrl-T</kbd> switch to TUI · <kbd>Ctrl-R</kbd> refresh. TUI also accepts <kbd>j</kbd>/<kbd>k</kbd>/<kbd>q</kbd>.

Source: [`scripts/task-pick.fish`](scripts/task-pick.fish).

## Installation

```bash
# Clone (or fork) this repo somewhere; everything below assumes you're in it.
cd ~/path/to/taskestro

# 1. Install the skill itself
mkdir -p ~/.claude/skills/task-orchestrator
ln -s "$PWD/SKILL.md" ~/.claude/skills/task-orchestrator/SKILL.md

# 2. Install the Fish functions (monitor + picker)
mkdir -p ~/.config/fish/functions
ln -s "$PWD/scripts/task-monitor.fish" ~/.config/fish/functions/task-monitor.fish
ln -s "$PWD/scripts/task-pick.fish"    ~/.config/fish/functions/task-pick.fish

# 3. Install inotify-tools (Linux; required for push-mode wait)
sudo apt install inotify-tools     # Debian/Ubuntu
# or: sudo dnf install inotify-tools / sudo pacman -S inotify-tools
# macOS users: install fswatch and adapt Step 7 in SKILL.md (not bundled).
```

### 4. Wire up the Notification hook

The hook timestamps each "awaiting-input" event so the monitor can display elapsed time and the prompt question. Without it the monitor still works — those columns just stay empty.

Add to `~/.claude/settings.json`, replacing `<absolute-path-to-this-repo>` with the result of `pwd` from inside the cloned repo:

```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash <absolute-path-to-this-repo>/hooks/cc-monitor-notify.sh"
          }
        ]
      }
    ]
  }
}
```

Restart Claude Code afterwards.

Symlinks keep the installed copy tracking the repo; a plain `cp` works too if you'd rather freeze a snapshot.

## Quick start

After installation, in any project directory:

```bash
# 1. Write a TASKS.md (or TODO.md) — see "Task format examples" below
# 2. Open Claude Code in that directory
claude

# 3. Tell it to dispatch (any of these phrasings work)
> dispatch the tasks in TASKS.md
> run the TODO list in parallel
> orchestrate my tasks
```

Claude will detect the skill, present a plan table, and wait for your OK before launching anything.

## Task format examples

**Checkbox format:**
```markdown
- [ ] Implement login screen
- [ ] [opus] Redesign authentication architecture
- [ ] [sonnet] Add pagination to user list
- [ ] [haiku] Fix typo in README
```

**Header-based format:**
```markdown
## TODO
### Implement login screen
Description of what needs to be done...
```

Use `[haiku]`, `[sonnet]`, or `[opus]` tags to override automatic model selection. `[branch:feature/xyz]` overrides the auto-generated worktree branch name.

## Requirements

- Git (for worktrees) and tmux.
- [Claude Code CLI](https://claude.ai/code).
- **Fish shell** (the monitor and picker are Fish functions).
- `inotify-tools` (Linux) — for push-mode completion detection. macOS support requires `fswatch` and a small adaptation; not bundled.
- A `Notification` hook configured in Claude Code settings — optional, enables activity-age and prompt text in the monitor.

## License

[MIT](LICENSE).
