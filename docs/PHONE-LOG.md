# The phone log

The phone web app records what goes wrong on it and posts it to the Mac. The
Mac keeps it in a file. An agent reads it with `mux phone-log`, so a phone
problem is diagnosed from the log and not from a description.

Local only: the lines go from the phone to this Mac over the tailnet, and
nowhere else.

## Read it

```sh
mux phone-log                         # the last 20 warnings and errors, oldest first
mux phone-log --severity error        # errors only (info | warn | error; default warn)
mux phone-log --since 2h              # s, m, h or d
mux phone-log --project acme-app      # one project: a tmux session, as `mux sessions` names it
mux phone-log --last 100 --json       # whole lines, one JSON object each (with the stack)
mux phone-log --projects --since 1d   # project|errors|warnings|last line
```

The default output is one line per problem:

```
time|severity|project|build|kind|message
2026-10-04 11:02:11|error|acme-app|a5c3b32afc8b|error|x is not a function @ /_app/immutable/chunks/a.js:1
2026-10-04 11:02:14|warn|-|a5c3b32afc8b (stale: Mac serves 77d01c9e4b10)|stale|the phone runs build …
```

`mux` lives at `~/Library/Application Support/MuxMaestro/manager/bin/mux`. The
command is read-only and never opens `manager.db`.

## Where it is

| | |
| --- | --- |
| Directory | `~/Library/Application Support/MuxMaestro/logs`, or the directory in the `phone.logDir` setting |
| Active file | `phone.jsonl` |
| Older files | `phone.1.jsonl` (newest) to `phone.7.jsonl` (oldest) |

Move it with:

```sh
defaults write is.rebar.MuxMaestro phone.logDir /path/to/logs   # then restart MuxMaestro
```

`mux phone-log` reads the same setting. `MUX_PHONE_LOG_DIR` overrides it.

## How large it gets

The limits are in `MobileLogFile.Limits` and the code enforces them on every
write.

| Limit | Value |
| --- | --- |
| Total size | 4 MiB: 8 files of at most 512 KiB |
| Age | 8 days: a file is closed after 1 day and deleted 7 days after its last line |
| One line | 4096 bytes |
| One batch | 64 KiB and 100 lines |
| Rate | 300 lines a minute; the rest of that minute is dropped, and one line says so |

A file is rotated before a line would take it past 512 KiB. A full disk gives
up the oldest file for the new lines; if that does not help, the new lines are
dropped and the next line that is written says how many. The file is written
on its own queue: the phone's request is answered first, and the app never
waits for the disk.

## What a line holds

One JSON object per line. Every line has:

| Field | Meaning |
| --- | --- |
| `t` | When it happened, UTC, by this Mac's clock |
| `sev` | `info`, `warn` or `error` |
| `kind` | `session`, `error`, `rejection`, `resource`, `fetch`, `sw`, `life`, `net`, `sse`, `socket`, `stale`, `mac`, `dropped` |
| `project` | The tmux session of the thread the line is about; empty when it is about no thread |
| `host` | That session's host |
| `build` | The build the phone runs: the bundle's version hash |
| `served` | The build this Mac serves. Different from `build`: the phone is on an old bundle |
| `sid` | One page load. The `session` line with the same `sid` describes the device |
| `msg` | What happened |

Other fields depend on the kind: `stack`, `src`, `line`, `col` (errors);
`method`, `url`, `status`, `ms` (failed requests; the API sends no request
id); `sw`, `cache`, `caches` (the service worker's build and caches); `ios`,
`standalone`, `viewport`, `net` (the device, once per page load); `n` (how
many times the same line happened before it was sent).

Two lines are written by the Mac itself. `mac`: the phone server started, with
the bundle it serves and the build time of the app binary. `stale`: a phone
sent lines from a build this Mac no longer serves (once per page load).

## What it never holds

No message text and nothing a person typed. An address is logged as its path
only, without the query. Text between double quotes is removed from error
messages, because a parse error quotes the text it could not read. A thrown
value that is not an error is logged as its type only.

## How the phone sends

Lines wait in memory and go in batches: 2 seconds after the last line, at
most 10 seconds after the first, and at once when the app goes to the
background. The buffer holds 200 lines; a repeated line is counted, not added.
A batch the Mac did not receive is kept and sent again, with a longer wait
each time (5 s to 60 s).
