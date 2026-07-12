# notchide — Claude Code hook integration

notchide reads your agents through [Claude Code's hook system](https://code.claude.com/docs/en/hooks).
A small sidecar, **`notchide-hook`**, is registered on a few hook events; on a permission gate it
bridges Claude Code to the notchide app over a local socket and blocks — **fail-open** — until you
decide. This document is the contract: which hooks, the exact `settings.json` snippet, the
fail-open guarantee, how to uninstall, and troubleshooting.

---

## 1. Which hooks

| Hook           | What notchide does with it                                                     |
| -------------- | ------------------------------------------------------------------------------ |
| `PreToolUse`   | **The write path.** The sidecar sends the pending tool call to notchide and blocks awaiting your `Approve` / `Deny` / `Approve-and-remember` / redirect. |
| `Notification` | Surfaces Claude Code's own notifications into the cockpit.                     |
| `Stop`         | Marks the session's lane `done` when the agent finishes its turn.             |
| `SubagentStop` | Tracks subagent completion inside a session.                                  |

Only `PreToolUse` blocks. `Notification`, `Stop`, and `SubagentStop` are fast, non-blocking
status pings that update the glyph.

---

## 2. What the installer writes

Run:

```sh
notchide-hook install
```

It **merges** (never overwrites) the following into `~/.claude/settings.json`, shows you the
exact diff, and asks for confirmation before writing. Existing hooks are preserved; notchide's
entries are appended to each event's array.

```jsonc
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "notchide-hook handle PreToolUse",
            "timeout": 600
          }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "notchide-hook handle Notification" }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "notchide-hook handle Stop" }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          { "type": "command", "command": "notchide-hook handle SubagentStop" }
        ]
      }
    ]
  }
}
```

Notes on the shape (matches the Claude Code hooks schema):

- The top-level key is `hooks`; under it each **event name** maps to an **array of matcher
  groups**; each group has an optional `matcher` and a `hooks` array of command handlers.
- `matcher: "*"` matches every tool. `Stop` / `SubagentStop` are not tool events, so they carry
  no matcher.
- Each handler is `{ "type": "command", "command": "…" }`. `PreToolUse` sets a generous
  `timeout` (seconds) as an outer backstop; notchide's own hard timeout (§4) fires well inside
  it.
- The `command` invokes `notchide-hook` (ensure it is on `PATH`, or the installer writes an
  absolute path to the installed binary).

Claude Code passes the hook payload (`session_id`, `tool_name`, `tool_input`, `cwd`,
`hook_event_name`, …) to the command on **stdin**; `notchide-hook` reads it there.

---

## 3. How a decision is returned to Claude Code

On `PreToolUse`, `notchide-hook` blocks awaiting your decision, then prints Claude Code's
`PreToolUse` decision JSON to **stdout** and exits `0`. The mapping:

| Your action in notchide  | stdout `permissionDecision` | Effect                                                    |
| ------------------------ | --------------------------- | --------------------------------------------------------- |
| **Approve**              | `allow`                     | Claude Code runs the tool call.                           |
| **Deny**                 | `deny` (+ reason)           | Claude Code blocks the call and tells the agent why.      |
| **Redirect** (one line)  | `deny` (+ your line as the reason / context) | The agent gets a concrete steer, not a bare refusal. |
| **Approve-and-remember** | `allow`                     | Runs now; that **exact command string** auto-resolves next time. |

Approve example:

```jsonc
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow"
  }
}
```

Deny / redirect example:

```jsonc
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "redirect: run `swift build`, not a raw cc invocation"
  }
}
```

---

## 4. The fail-open guarantee

**notchide never bricks an agent.** The `PreToolUse` block is convenience, not a load-bearing
gate.

`notchide-hook` fails open when it:

- cannot connect to `~/Library/Application Support/notchide/hook.sock` (app not running), or
- finds no socket at all (app not installed / not launched), or
- receives **no decision before its hard timeout**.

In every one of those cases the sidecar writes **no decision** to stdout and exits **`0`**. Per
the Claude Code hooks contract, an exit-`0` `PreToolUse` hook that emits no
`permissionDecision` **defers to Claude Code's normal permission flow** — so you simply get
Claude Code's usual prompt, exactly as if notchide weren't installed.

- Exit `0` + no JSON → **defer** (fail-open). This is the notchide default on any failure.
- Exit `2` is *not* used by notchide for availability failures — that would block the tool and
  feed stderr back to the agent, the opposite of failing open.

The hard timeout is set comfortably below the outer hook `timeout` so notchide always resolves
the block itself (by deciding or by deferring), rather than letting Claude Code's timeout fire.

---

## 5. Uninstall

```sh
notchide-hook uninstall
```

This removes **exactly** the handler entries notchide added to `~/.claude/settings.json` and
leaves every other hook untouched. If notchide is the only hook under an event, the now-empty
event key is removed too. The installer is fully reversible by design; your `settings.json` ends
up byte-for-byte as if notchide had never been installed (modulo key ordering).

You can preview changes without writing:

```sh
notchide-hook install --dry-run     # print the merge diff, write nothing
notchide-hook uninstall --dry-run   # print what would be removed, write nothing
```

---

## 6. Troubleshooting

**Nothing shows up in the notch when an agent hits a permission gate.**

- Is the notchide app running? It owns the socket; without it the hook fails open and you get
  Claude Code's normal prompt. Launch notchide, then retry.
- Confirm the hook is registered: `notchide-hook doctor` checks that `~/.claude/settings.json`
  contains the notchide handlers and that the socket exists and is `0600`.
- Is the session's terminal frontmost? By design, **smart suppression** stays silent when the
  agent's terminal is already visible. Move the terminal to a background Space and retry, or use
  the summon hotkey.

**Every gate falls through to Claude Code's own prompt (never to notchide).**

- The sidecar is failing open. Check the socket path
  `~/Library/Application Support/notchide/hook.sock` exists and is owner-readable (`0600`).
- Make sure `notchide-hook` is on `PATH` for the environment Claude Code runs in, or reinstall so
  the absolute binary path is written into `settings.json`.

**`settings.json` didn't change after `install`.**

- The installer asks for confirmation before writing; if you didn't confirm, nothing is written.
  Re-run and confirm, or use `--dry-run` to inspect the diff first.
- If `~/.claude/settings.json` is invalid JSON, the merge is aborted rather than risk corrupting
  it — fix the JSON and re-run.

**An agent hangs waiting on a permission.**

- This should be impossible given fail-open. If you see it, capture `notchide-hook doctor` output
  and the hook `timeout` in `settings.json` and file an issue — the hard timeout not firing is a
  bug, not expected behavior.

> `notchide-hook doctor`, `--dry-run`, and the exact subcommand names above describe the intended
> CLI surface for v0.1; check `notchide-hook --help` on your build for the authoritative list.
