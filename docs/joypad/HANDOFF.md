# Handoff: mgba-r for joypad-mcp

Written 2026-11-27 at the end of the session that ran prompts 1 to 4 from `joypad-prompts/`
(the folder is untracked; see [Where things are](#where-things-are)). Read this first, then
[README.md](README.md) (build, install, sync) and [PLAN.md](PLAN.md) (the design).

## State

| What | State |
|---|---|
| `master` | `c4fe856f2`, equal to upstream `mgba-emu/mgba` master. Only the sync writes to it, as a fast-forward |
| `remote` | Default branch. Upstream merged in once (`89b61cf33`), plus CI, scripts and docs. **No fork code yet** |
| Releases | `remote-4b8e3a47f` (latest), `remote-89b61cf33`, `remote-27f1d506f`. Docs-only commits start no build, so `dd6da3701` has no release; it changes no code |
| Workflows | `build-linux` and `sync-upstream`, both `active`; the sync runs daily at 05:37 UTC |
| Installed here | `~/.local/opt/mgba-r/remote-4b8e3a47f`, run as `~/.local/bin/mgba-r`. Stock `/usr/bin/mgba-qt` (`aur/mgba-qt-git`, `0.11-9204-c4fe856f2`) untouched |
| GitHub settings | Default branch `remote`; Issues on; no open issues; Actions token read-only by default (each workflow declares its own `permissions:`) |
| Design | `PLAN.md` **approved by the owner 2026-11-27**. All 10 open questions are answered in its "Decisions" section |

## Done (prompts 1 to 4)

| Prompt | Result | Proof |
|---|---|---|
| 2 Build | `.github/workflows/build-linux.yml`: `archlinux:latest` container, AUR options + `-DDATADIR=../share/mgba`, `patchelf` RUNPATH `$ORIGIN/../lib`, ccache, release per build, newest 10 kept | Green runs [46028868795](https://github.com/angwdev/mgba-r/actions/runs/46028868795) (cold, 5 min 37 s) and [46030875926](https://github.com/angwdev/mgba-r/actions/runs/46030875926) (warm, 3 min 12 s); archive 3.4 MB |
| 4 Sync | `.github/workflows/sync-upstream.yml` + `joypad/sync.sh`: plain `git`, merge commits, never forced; one "Upstream merge conflict" issue on conflict | Real sync [46029852087](https://github.com/angwdev/mgba-r/actions/runs/46029852087), no-op [46030730138](https://github.com/angwdev/mgba-r/actions/runs/46030730138), conflict test on throwaway branches (opened, then updated one issue; test branches and issue deleted) |
| 3 Install | `joypad/install.sh`: `gh release download`, SHA256 check, `~/.local/opt/mgba-r/<tag>`, `current` link, newest 3 kept, `--list`, rollback by tag, `ldd` check | joypad-mcp `uv run pytest`: 500 passed / 0 skipped with stock and with `JOYPAD_MGBA=mgba-r` (34 fork starts confirmed by a logging wrapper); saved moments load stock to fork and back |
| 1 Plan | `docs/joypad/PLAN.md` (written by a sub-agent, spot-checked) | Decisions recorded in `dd6da3701` |

For joypad-mcp's MCP server `env` (not set; joypad-mcp is the owner's to change):
`"JOYPAD_MGBA": "/home/<owner>/.local/bin/mgba-r"`.

## The design in five lines

1. Commands are built into the Qt frontend (new files under `src/platform/qt/joypad/`), not
   Lua: Lua sockets only poll per frame, `--script` is skipped with autorun scripts, and
   there are no Lua bindings for windows, actions, pause or fast-forward.
2. mgba-r connects out to a loopback port joypad-mcp opens; `JOYPAD_REMOTE=<port>:<token>`.
   Without it no fork code runs and mgba-r behaves exactly like stock mGBA.
3. Windows via Qt itself (`QWidget::grab`, Qt key events, `AA_DontUseNativeDialogs`,
   `WA_ShowWithoutActivating`), no X11.
4. Live view: one small record per frame (frame, hash, 15×10 change mask) on a second
   socket; waits, sprites and pictures stay in joypad-mcp.
5. About 15 changed lines in 4 upstream files (`main.cpp`, Qt `CMakeLists.txt`, `GBAApp.h`,
   `Window.h`), to keep upstream merges easy. Nothing is offered upstream: the maintainer
   does not accept LLM-written code (PR #3752), and the owner chose not to set pieces aside.

## Next

In order of the prompts' README; the owner picks.

1. **melonDSr prompts 1 to 4** (`~/Documents/Work/angwdev/melonDSr/joypad-prompts/`).
   Nothing done there yet: no `remote` branch, no releases, no runs. Differences from mgba-r:
   upstream melonDS has its own workflows (`build-ubuntu.yml` and others), so the sync's
   `.github/workflows/` guard will trigger and the `GITHUB_TOKEN` limit matters; melonDS has
   no scripting at all.
2. **Prompt 5, the shared protocol** (`docs/joypad/PROTOCOL.md` in both forks), after
   melonDSr has its `PLAN.md` and before either fork's code is written.
3. **Spec changes in joypad-mcp** (owner, with Spec Kit): `PLAN.md`, "Spec changes to
   propose" (token and version fields, live-view record format, saved-moment format, a new
   FR for memory watches).
4. **Fork code, work order step 1** (`PLAN.md`, section 9): a native-Wayland prototype that
   lists one window and takes one picture. Each push to `remote` builds a release;
   `joypad/install.sh` installs it.
5. **Still to confirm when the live view is built:** `-C hwaccelVideo=0` for runs joypad-mcp
   starts (the owner's own setting is `hwaccelVideo=1`).

## Rules (fixed, from the prompts)

- `master` stays an exact copy of upstream; never commit to it, never force-push anything.
- All work on `remote`; upstream is merged in, never rebased.
- No pull requests or issues on `mgba-emu/mgba`. No changes in
  `~/Documents/Work/angwdev/joypad-mcp` (the owner has uncommitted work there: `HANDOFF.md`,
  `specs/003-nds-host/`).
- Search packages with `yay` (say `extra/` or `aur/`); library and GitHub docs through
  Context7.
- Tell the owner before any mGBA window opens. joypad-mcp's tests run mGBA offscreen or on a
  private Xvfb, muted, with their own config folder.

## Things learned the hard way

- **The fork has no git tags.** mGBA's Qt `CMakeLists.txt` builds the AppStream release list
  from tags and fails without any, so CI fetches upstream's (they are lightweight, so the
  version string is unchanged). CI also deletes local `remote-*` tags, which would otherwise
  become the version string.
- **Container jobs:** `${{ github.workspace }}` is the host path; use `$GITHUB_WORKSPACE`
  inside the container. Steps run under `sh`, not `bash`.
- **Push builds must pin `$GITHUB_SHA`.** Checking out the branch by name built a later
  commit the sync had pushed meanwhile. `version.cmake` needs HEAD on a branch named
  `remote`, so CI uses `git checkout -B remote "$GITHUB_SHA"`.
- **`DATADIR=../share/mgba`** is compiled in relative to the program, but `install()` reads
  it relative to the prefix, so CI moves the data under `usr/` after install.
  `CMAKE_INSTALL_RPATH` is set with a plain `set()` and cannot be changed with `-D`, hence
  `patchelf`.
- **Arch's `sdl2` is `sdl2-compat`**; mGBA builds against SDL 3, like the AUR package.
- **`merge-upstream` API** writes a merge commit on a diverged branch, so the sync uses a
  non-forced `git push` instead. A merge commit that changes no workflow file relative to
  `remote` pushes fine with `GITHUB_TOKEN`.
- **The 60-day schedule rule:** no keepalive (the best-known keepalive project is blocked by
  GitHub for a Terms of Service reason). Real sync pushes keep it alive: upstream's longest
  commit gap in three years was 24 days. `sync.sh` warns if the workflow is disabled.
- **`mgba-qt --version` prints its own path first**; strip the first word.

## Where things are

| Path | What |
|---|---|
| `~/Documents/Work/angwdev/mgba-r` | This clone. Remotes `origin` (fork) and `upstream`. Local git identity `angwdev` with the owner's GitHub noreply address (no email published) |
| `joypad-prompts/` | The five prompts; untracked, in `.git/info/exclude`. `.claude/` (agent worktrees) is excluded too |
| `docs/joypad/` | `README.md`, `PLAN.md`, this file |
| `joypad/install.sh`, `joypad/sync.sh` | Install releases; sync by hand (`--dry-run` reports only) |
| `~/Documents/Work/angwdev/melonDSr` | The other fork, same prompt set, untouched |
| `~/Documents/Work/angwdev/joypad-mcp` | The MCP server; read only for these sessions |
