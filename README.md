# Agent Meter

<img src="Resources/AppIcon-preview.png" alt="Agent Meter icon in light, dark, tinted and clear appearances" width="640">

A small macOS app that shows which **Claude Code** and **Codex** sessions — and the processes and sub-agents
they spawn — are using your CPU and memory.

When you run many agent sessions in parallel, Activity Monitor shows dozens of `claude`, `node`, `vitest`, `tsc`
and `npm` processes with no hint of which session started them. Agent Meter groups them by session and labels each
group with the session's name.

## Features

- Claude Code and Codex sessions in one list, tagged by source and labeled with the session name
- CPU and memory totals per session, expandable to every process with its full command line
- Finds processes left running by sessions that have already ended, such as dev servers started in the background
- Codex sub-agents are nested under their parent thread
- End a session, its leftover processes or a single process, after a confirmation
- **Clean Up** in one click: ends the processes of sessions that are over, keeping shared services such as Colima
- Samples on demand: press **Refresh** (⌘R); nothing runs in the background between refreshes
- A **Disk** tab shows what each session leaves on disk (scratch files, worktrees, dependencies), how much of it can
  be deleted, and deletes it after a confirmation. Conversations are never deleted

## Requirements

- macOS 14 or later
- Xcode 26 or later to build (the app icon is an Icon Composer document compiled with `actool`)

## Build

```bash
./build.sh            # builds build/Agent Meter.app
./build.sh install    # also copies it to ~/Applications
```

To print the same data as plain text: `swift build -c release && .build/release/AgentMeter --dump`
(processes) or `--dump-disk` (disk usage).

## How it works

### Measurements

- **CPU**: two samples 1.5 seconds apart, computed from accumulated CPU time. 100% means one core fully busy,
  the same scale as `top` and Activity Monitor.
- **Memory**: physical footprint, the same figure as Activity Monitor's *Memory* column. It includes compressed and
  swapped-out memory, so the total across processes can exceed physical RAM.
- Only your own processes are visible; processes owned by root or system accounts cannot be read.

### Attributing processes to sessions

The first matching rule wins:

1. The process is a Claude Code session process, registered in `~/.claude/sessions/<pid>.json`.
   The session name comes from this file.
2. The process environment contains `CLAUDE_CODE_SESSION_ID` or `CODEX_THREAD_ID`. Claude Code and Codex set
   these for the commands they run, so processes that outlived their parent (for example a dev server started in
   the background) are still attributed to the session that started them. For sessions that have ended, the name is
   read from the session transcript.
3. The Claude desktop app's `disclaimer` launcher belongs to the session it launched.
4. Otherwise, walk up the parent process chain.
5. Remaining processes of the Claude desktop app and the Codex / ChatGPT app are shown as the apps themselves;
   everything else is listed as *Not attributed to any session*.

Codex thread names and the parent of each sub-agent come from `~/.codex/state_5.sqlite`. Sub-agents have no title
of their own, so they are shown under the task name their parent gave them (for example *research active schema
detection*), with the generated nickname in the details.

Only the two session ID variables are taken from a process environment. Every other variable, including tokens,
is skipped and never stored or displayed. Nothing leaves your machine.

### Ending sessions

Select a row and press **End…** (⌘⌫), or right-click it:

| Row | What is ended |
|---|---|
| Claude Code session | The session process and every process attributed to it, including background services. The conversation can be resumed later: reopen it in the desktop app, or `claude --resume` |
| Ended session's leftovers | The processes it left running |
| Codex thread | The processes it and its sub-agents started. The thread itself lives in the Codex app and is not affected |
| Single process | Just that process |
| Claude desktop app, Codex / ChatGPT app | Not offered |

### Clean Up

**Clean Up** ends, without asking, every process that meets both conditions:

1. Its session is over:
   - a Claude Code session whose session process has exited, or
   - a Claude Code CLI session that has been idle for 6 hours. The whole session is ended, session process included;
     resume it with `claude --resume`. Sessions started with channels (`--channels`,
     `--dangerously-load-development-channels`) are message-driven bots that sit idle by design and are never
     ended. Desktop sessions are not ended this way, or
   - a Codex thread that is archived in the Codex app, or has had no activity for 24 hours. Codex threads run
     inside the app server and have no process of their own, so inactivity is the signal.
2. It is not a shared service and does not run under one. A session sometimes happens to start a service that other
   sessions and apps rely on, such as the Colima VM (`colima`, `limactl`), Docker, `ssh-agent`, `gpg-agent` or the
   `adb` server; these and their child processes are kept.

The button shows how many processes qualify, and the list marks them with a sparkle; kept shared services in a
finished session show a lock. Clean Up takes a fresh sample before acting, so a session resumed since the last
refresh keeps its processes, and a session that became busy again is left alone.

### How processes are ended

Agent Meter sends `SIGTERM`, waits up to 3 seconds, then sends `SIGKILL` to whatever is still running, and
refreshes. Before signaling, it checks each process's start time, so a PID that was reused since the last refresh
is left alone. It never ends itself.

## Disk usage

The **Disk** tab lists every Claude Code session and Codex thread that occupies more than its conversation, and
splits each into parts. Press **Scan Disk** (⌘R): it reads every file under the folders below, which takes 30 to 60
seconds, and runs only when you ask. Scanning changes nothing.

| Part | Where it lives | Counted as deletable |
|---|---|---|
| Scratch files | `/tmp/claude-<uid>/<project>/<session id>/` | Always, once the session is not running |
| Dependencies and caches | Git-ignored `node_modules`, `.venv`, `__pycache__`, `dist`, `build`, `target`, `.terraform` and the like inside a worktree | Always, once the session is not running |
| Worktree files | `<repo>/.claude/worktrees/<name>` (Claude Code, including those sub-agents create) or `~/.codex/worktrees/<hash>/<repo>` (Codex) | Only if git reports no uncommitted changes, every commit is on some remote branch, and the worktree holds no other git-ignored files, which would be lost with it |
| Ignored files | Git-ignored files in a worktree that are not known to be rebuildable, such as a `.memo/` folder | Never |
| Conversation history | `~/.claude/projects/.../<id>.jsonl` and its folder, `~/.codex/sessions/.../rollout-*.jsonl` | Never: deleting it loses the ability to resume |

A part is held back, with the reason shown, while its session is running (a Codex thread counts as running if it
was active in the last hour) or while any process has its working directory inside it. Sizes are the space
allocated on disk, as `du` reports; hard-linked files count once.

A worktree shared by several sessions (a resumed conversation, or the sub-agents of a Codex thread) is shown under
the one that was active last. Codex agents often create worktrees by hand (`git worktree add
~/.codex/worktrees/<name>/<repo>`), which no thread records as its working directory. Those are matched to the
earliest thread that was running when the directory was created and whose conversation log mentions it, which is
usually the thread that made it. Worktrees that still cannot be matched are listed under their directory name with
*No session found*.

### Deleting

Select a session or one of its parts and press **Delete…** (⌘⌫), right-click it, or use **Delete All** for everything
marked deletable. A dialog lists what will be removed and its size. Deleting is permanent and never touches
conversations.

- Scratch files and dependency directories are deleted from disk.
- A worktree is removed with `git worktree remove`; its branch and commits stay.

The scan can be minutes old, so each part is checked again right before it is deleted and skipped, with the reason
shown, if it is no longer safe: the session is running again, a process started in it, the worktree gained uncommitted
changes or unpushed commits, or a directory is no longer ignored by git. Only paths of the expected shapes are
deleted (`/tmp/claude-<uid>/<project>/<session id>`, `<repo>/.claude/worktrees/<name>`, `~/.codex/worktrees/<hash>/<repo>`),
and never a symbolic link.

## Limitations

- Disk usage: a branch that was squash-merged and deleted on the remote still has commits no remote branch contains,
  so its worktree is reported as having unpushed commits and is not counted as deletable.
- Disk usage: space used by Codex outside the per-thread files, such as `~/.codex/thread_history_1.sqlite`, is not
  attributed to any thread.

- macOS does not expose the environment of platform binaries (`/bin`, `/usr/bin`, such as `sleep` or `bash`).
  These are attributed through their parent while it is alive; once orphaned, they fall into *Not attributed*.
- Claude Code sub-agents run inside the session process, so their usage is counted on the session.
- Session names rely on internal files of Claude Code and Codex (`~/.claude/sessions`, `~/.codex/state_5.sqlite`),
  which may change between versions.

## App icon

`Resources/AppIcon.icon` is an Icon Composer document: a gauge split into an orange (Claude) and a blue (Codex) arc.
Open it with Icon Composer to edit. `build.sh` compiles it into the app bundle.

## License

[MIT](LICENSE)

Not affiliated with Anthropic or OpenAI. Claude and Codex are trademarks of their respective owners.
