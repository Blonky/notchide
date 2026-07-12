# notchide — Claude Code hook integration

notchide reads your agents through [Claude Code's hook system](https://code.claude.com/docs/en/hooks).
A small sidecar, **`notchide-hook`**, is registered on a few hook events; on a permission gate it
bridges Claude Code to the notchide app over a local socket and blocks — **fail-open** — until you
decide. This document is the contract: which hooks, the exact `settings.json` snippet, the
fail-open guarantee, how to install/uninstall, and troubleshooting.

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

## 2. Installing

Run:

```sh
notchide-hook install
```

`install` **merges** (never overwrites) notchide's handlers into `~/.claude/settings.json`. It:

- resolves the **absolute path of the running `notchide-hook` binary** and writes that into each
  handler's `command` (so it works regardless of `PATH`);
- **backs up** the existing file to `settings.json.bak.<unix-timestamp>` before writing;
- writes the merged result **atomically**;
- creates `~/.claude/` and `settings.json` if they don't exist;
- asks for confirmation first (because it edits your Claude config).

Flags:

```sh
notchide-hook install --dry-run   # print the resulting settings.json; write nothing
notchide-hook install --yes       # skip the confirmation prompt
notchide-hook install --settings <path>   # operate on <path> instead of ~/.claude/settings.json
```

Existing settings and existing hooks from other tools are preserved; notchide's group is
**appended** to each event's array. Re-running `install` is **idempotent** — it never duplicates
notchide's entries (it detects any handler whose `command` contains `notchide-hook`), and it
refreshes the command if the binary path changed.

### What gets written

Each handler is invoked as **`<abs-path>/notchide-hook handle <EventName>`**. `PreToolUse` carries
`matcher: "*"`; `Notification` / `Stop` / `SubagentStop` omit the matcher (it is optional/ignored
for those events per the Claude Code hooks schema). With the binary installed at, e.g.,
`/usr/local/bin/notchide-hook`:

```jsonc
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          { "type": "command", "command": "/usr/local/bin/notchide-hook handle PreToolUse" }
        ]
      }
    ],
    "Notification": [
      {
        "hooks": [
          { "type": "command", "command": "/usr/local/bin/notchide-hook handle Notification" }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "/usr/local/bin/notchide-hook handle Stop" }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          { "type": "command", "command": "/usr/local/bin/notchide-hook handle SubagentStop" }
        ]
      }
    ]
  }
}
```

Notes on the shape (matches the [Claude Code hooks schema](https://code.claude.com/docs/en/hooks)):

- The top-level key is `hooks`; under it each **event name** maps to an **array of matcher
  groups**; each group has an optional `matcher` and a `hooks` array of command handlers.
- `matcher: "*"` matches every tool. `Notification` / `Stop` / `SubagentStop` are written without a
  matcher.
- Each handler is exactly `{ "type": "command", "command": "…" }`. notchide does **not** write an
  outer per-hook `timeout`; it governs its own hard timeout (§4) internally.
- The file is written pretty-printed with keys sorted, so on disk the event order and key order may
  differ from the snippet above; the structure is identical.

Claude Code passes the hook payload (`session_id`, `tool_name`, `tool_input`, `cwd`,
`hook_event_name`, …) to the command on **stdin**; `handle` reads it there. The `EventName`
argument is a convenience/override — if omitted, `handle` uses the payload's `hook_event_name`.

---

## 3. How a decision is returned to Claude Code

On `PreToolUse`, `notchide-hook handle` blocks awaiting your decision, then prints Claude Code's
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
gate. This applies to the **handler** (`handle` / a bare invocation); `install` / `uninstall` /
`doctor` are ordinary human-run CLIs and may exit non-zero on real errors.

`notchide-hook handle` fails open when it:

- cannot connect to `~/Library/Application Support/notchide/hook.sock` (app not running), or
- finds no socket at all (app not installed / not launched), or
- receives **no decision before its hard timeout**, or
- cannot parse its stdin payload.

In every one of those cases the handler writes **no decision** to stdout and exits **`0`**. Per the
Claude Code hooks contract, an exit-`0` `PreToolUse` hook that emits no `permissionDecision`
**defers to Claude Code's normal permission flow** — so you simply get Claude Code's usual prompt,
exactly as if notchide weren't installed.

- Exit `0` + no JSON → **defer** (fail-open). This is the notchide default on any failure.
- Exit `2` is *not* used by notchide for availability failures — that would block the tool and feed
  stderr back to the agent, the opposite of failing open.

The hard timeout defaults to 10 minutes (a permission prompt legitimately waits for a human) and is
overridable via `NOTCHIDE_HOOK_TIMEOUT_MS`. notchide always resolves the block itself — by deciding
or by deferring — rather than hanging.

---

## 5. Uninstall

```sh
notchide-hook uninstall
```

This removes **exactly** the handler entries notchide added to `~/.claude/settings.json` (any
handler whose `command` contains `notchide-hook`) and leaves every other hook untouched. If notchide
was the only handler under an event, the now-empty matcher group and event key are removed too. Like
`install`, it backs up the existing file first and writes atomically. The result is your
`settings.json` as if notchide had never been installed (modulo JSON key ordering).

It accepts the same flags:

```sh
notchide-hook uninstall --dry-run   # print what would remain, write nothing
notchide-hook uninstall --yes       # skip the confirmation prompt
notchide-hook uninstall --settings <path>
```

---

## 6. Troubleshooting

Start with:

```sh
notchide-hook doctor
```

`doctor` prints the resolved binary path, whether the socket
`~/Library/Application Support/notchide/hook.sock` is present, and which of the four events are
wired to notchide in `settings.json`. If the socket is absent it notes that the app isn't running
and hooks will fail open. It always exits `0`.

**Nothing shows up in the notch when an agent hits a permission gate.**

- Is the notchide app running? It owns the socket; without it the hook fails open and you get
  Claude Code's normal prompt. Launch notchide, then retry.
- Confirm the hook is registered: `notchide-hook doctor` shows each event as `wired` / `not wired`.
- Is the session's terminal frontmost? By design, **smart suppression** stays silent when the
  agent's terminal is already visible. Move the terminal to a background Space and retry, or use the
  summon hotkey.

**Every gate falls through to Claude Code's own prompt (never to notchide).**

- The sidecar is failing open. Check that the socket
  `~/Library/Application Support/notchide/hook.sock` exists (`doctor` reports this).
- Make sure the `command` in `settings.json` points at the real binary. `install` writes an
  absolute path; if you moved the binary, re-run `install` so the new path is written.

**`settings.json` didn't change after `install`.**

- `install` asks for confirmation before writing; if you didn't confirm, nothing is written. Re-run
  and confirm, pass `--yes`, or use `--dry-run` to inspect the result first.
- If `~/.claude/settings.json` is invalid JSON, the merge is aborted (non-zero exit) rather than
  risk corrupting it — fix the JSON and re-run.
- Every write is preceded by a `settings.json.bak.<unix-timestamp>` backup, so you can always
  restore the previous state.

**An agent hangs waiting on a permission.**

- This should be impossible given fail-open. If you see it, capture `notchide-hook doctor` output
  and file an issue — the hard timeout not firing is a bug, not expected behavior.
