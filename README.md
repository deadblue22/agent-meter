# Mac Monitor

<img src="Resources/AppIcon-preview.png" alt="Mac Monitor icon in light, dark, tinted and clear appearances" width="640">

A small macOS app that shows which **Claude Code** and **Codex** sessions — and the processes and sub-agents
they spawn — are using your CPU and memory.

When you run many agent sessions in parallel, Activity Monitor shows dozens of `claude`, `node`, `vitest`, `tsc`
and `npm` processes with no hint of which session started them. Mac Monitor groups them by session and labels each
group with the session's name.

## Features

- Claude Code and Codex sessions in one list, tagged by source and labeled with the session name
- CPU and memory totals per session, expandable to every process with its full command line
- Finds processes left running by sessions that have already ended, such as dev servers started in the background
- Codex sub-agents are nested under their parent thread
- End a session, its leftover processes or a single process, after a confirmation
- Samples on demand: press **Refresh** (⌘R); nothing runs in the background between refreshes

## Requirements

- macOS 14 or later
- Xcode 26 or later to build (the app icon is an Icon Composer document compiled with `actool`)

## Build

```bash
./build.sh            # builds build/Mac Monitor.app
./build.sh install    # also copies it to ~/Applications
```

To print the same data as plain text: `swift build -c release && .build/release/MacMonitor --dump`

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

Codex thread names and the parent of each sub-agent come from `~/.codex/state_5.sqlite`.

Only the two session ID variables are taken from a process environment. Every other variable, including tokens,
is skipped and never stored or displayed. Nothing leaves your machine.

### Ending sessions

Select a row and press **End…** (⌘⌫), or right-click it:

| Row | What is ended |
|---|---|
| Claude Code session | The session process and every process attributed to it, including background services. A desktop session can be reopened in Claude later |
| Ended session's leftovers | The processes it left running |
| Codex thread | The processes it and its sub-agents started. The thread itself lives in the Codex app and is not affected |
| Single process | Just that process |
| Claude desktop app, Codex / ChatGPT app | Not offered |

Mac Monitor sends `SIGTERM`, waits up to 3 seconds, then sends `SIGKILL` to whatever is still running, and
refreshes. Before signaling, it checks each process's start time, so a PID that was reused since the last refresh
is left alone. It never ends itself.

## Limitations

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
