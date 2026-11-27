# mgba-r: mGBA for joypad-mcp

`angwdev/mgba-r` is a fork of [mgba-emu/mgba](https://github.com/mgba-emu/mgba) (MPL 2.0)
that joypad-mcp will drive through the program itself, without X11. This folder documents
how the fork is built, installed and kept up to date. The design of the fork's code changes
is in [PLAN.md](PLAN.md).

## Branches

| Branch | What it holds | Who writes to it |
|---|---|---|
| `master` | An exact copy of upstream `master` | Only the sync, and only as a fast-forward |
| `remote` | Upstream plus the fork's changes, workflows and these documents. The default branch | You, the sessions, and the sync's merge commits |

Upstream is merged into `remote`, never rebased onto it, so nothing published is ever
force-pushed.

## Build

Every push to `remote` (except one that only touches `docs/`, `joypad/` or Markdown files)
runs [`.github/workflows/build-linux.yml`](../../.github/workflows/build-linux.yml). It
builds `mgba-qt` in an `archlinux:latest` container with the AUR `mgba-git` options and
publishes a release tagged `remote-<short sha>`, marked as the latest release. You can also
run it by hand (`gh workflow run build-linux.yml -R angwdev/mgba-r`), and the sync calls it
after every merge.

Each release has two assets:

- `mgba-r-remote-<sha>-linux-x86_64.tar.zst`: one folder `remote-<sha>/` with `bin/mgba-qt`,
  `lib/libmgba.so*`, `share/mgba/` (shaders, scripts, `nointro.dat`), the licence and a
  `BUILDINFO` file (fork commit, upstream commit, version, CMake options, the Arch package
  versions it was built against);
- `SHA256SUMS`.

The release notes repeat the fork commit, the upstream commit (`git merge-base` with
upstream `master`), the mGBA version string and the CMake options. The workflow keeps the
newest 10 `remote-*` releases and deletes older ones with their tags.

The CMake options are the AUR package's (`-G Ninja -DCMAKE_INSTALL_LIBDIR=lib
-DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DUSE_MINIZIP=OFF`) plus
`-DDATADIR=../share/mgba`. Two steps make the archive run from any folder without changing
mGBA's source:

- **Data files.** A `DATADIR` that starts with `..` is compiled in as is and resolved
  against the program's folder (`src/platform/qt/CMakeLists.txt`, the `QT_DEFINES` block;
  `src/platform/qt/GBAApp.cpp`, `GBAApp::dataDir`). `install()` reads the same path relative
  to the prefix, so the data lands beside `/usr`, and the workflow moves it under it.
- **libmgba.** `CMakeLists.txt` sets no RPATH when the prefix is `/usr` (`CMAKE_SKIP_RPATH`),
  and sets `CMAKE_INSTALL_RPATH` with a plain `set()` otherwise, so a `-D` cannot change it.
  The workflow gives `mgba-qt` the RUNPATH `$ORIGIN/../lib` with `patchelf` after install.

The smoke check runs with `QT_QPA_PLATFORM=offscreen`: `ldd` finds every library and the
bundled `libmgba`, `--version` works, and `--help` lists `--script`.

ccache keeps repeat builds fast (`actions/cache`, one entry per run, restored from the newest).

Measured on the first runs (2026-11-27, `ubuntu-latest` runner):

| | Cold cache | Warm ccache (98.6 % hits) |
|---|---|---|
| Whole run | 5 min 37 s ([run](https://github.com/angwdev/mgba-r/actions/runs/46028868795)) | 3 min 12 s ([run](https://github.com/angwdev/mgba-r/actions/runs/46030875926)) |
| Compile step | 4 min 41 s | 2 min 6 s |
| Archive (`.tar.zst`) | 3.4 MB | |
| Unpacked | 11 MB | |

Most of a warm run is installing the build dependencies in the fresh container (about 25 s)
and starting it.

### Approaches considered (build)

| Decision | Options | Evidence | Choice | Why |
|---|---|---|---|---|
| Build environment | `archlinux:latest` container; Ubuntu + AppImage; Flatpak; a PKGBUILD built in CI into a pacman package | Upstream's own Linux builds use one distro container per target (`mgba-emu/mgba-infrastructure`, `buildbot/builders.yml`: Ubuntu `.deb`s, no AppImage). Flathub's `io.mgba.mGBA` builds release 0.10.5 on the Qt 5 KDE runtime, sandboxed with `--filesystem=host`. The AUR `mgba-git` builds in a plain Arch environment. Arch's `sdl2` is now `sdl2-compat`, and the build links SDL 3, the same as the installed `mgba-qt-git` | Arch container | Same libraries as this machine and the AUR package (Qt 6, Lua 5.5, ffmpeg, SDL 3); small; simple. AppImage would survive Arch updates but bundles Qt and ffmpeg, needs an old Ubuntu base and linuxdeploy, and is unlike today's build. Flatpak's sandbox would hide joypad-mcp's environment and folders. A pacman package needs `sudo` to install and conflicts with the stock package's files unless renamed and moved to `/opt` |
| Build options | the AUR options; upstream buildbot's options | AUR PKGBUILD `mgba-git` (`yay -G mgba-qt-git`) | AUR options + `DATADIR=../share/mgba` | Closest to the build the owner runs and whose tests pass |
| Running from any folder | `patchelf` RUNPATH; a wrapper setting `LD_LIBRARY_PATH`; static libmgba (`BUILD_SHARED=OFF`) | `CMakeLists.txt` RPATH logic (above); `patchelf` is in `extra/` | `patchelf` | One post-install step, no wrapper process, and the same shared `libmgba` layout as the AUR package |
| Breakage after an Arch update | rebuild on a schedule; `ldd` check at install; AppImage | Arch bumps sonames (ffmpeg, Lua) a few times a year | `ldd` in CI and in `joypad/install.sh`; the daily sync rebuilds when upstream moves | You can tell at once (`install.sh --list` or a fresh install says which library is missing), and `gh workflow run build-linux.yml` rebuilds against the new libraries |
| Cache | ccache with `actions/cache`; cached pacman packages; none | `ccache` is in `extra/`; pacman's own download is fast on GitHub runners | ccache | Most of the build time is compiling; one step and two environment variables |
| Publishing | a release per build; Actions artifacts only | Artifacts expire and need `gh run download`; releases have stable URLs and `gh release download` | releases, newest 10 kept | `joypad/install.sh` can install or roll back to any kept tag |
| Token | `GITHUB_TOKEN` with `contents: write`; a personal token | The repository's default token is read-only, so the workflow declares `contents: write` only | `GITHUB_TOKEN` | Enough to create and delete releases and tags |

## Install

```sh
~/Documents/Work/angwdev/mgba-r/joypad/install.sh              # the latest release
~/Documents/Work/angwdev/mgba-r/joypad/install.sh remote-<sha> # one release, or roll back to it
~/Documents/Work/angwdev/mgba-r/joypad/install.sh --list       # what is installed, * = current
```

It needs `gh` (logged in), `tar`, `zstd` and `sha256sum`, no `sudo`, and works from any
folder. It downloads the release's archive and `SHA256SUMS` with `gh release download` into a
temporary folder, checks the sums (and stops if they differ), and unpacks into:

| Path | What |
|---|---|
| `~/.local/opt/mgba-r/<tag>/` | one build (`bin/mgba-qt`, `lib/libmgba.so*`, `share/mgba/`, `BUILDINFO`); never unpacked over an existing folder |
| `~/.local/opt/mgba-r/current` | symlink to the build in use |
| `~/.local/bin/mgba-r` | symlink to `current/bin/mgba-qt` |

The stock `/usr/bin/mgba-qt` is not touched, and the fork has another name, so it never
shadows it. The newest 3 builds are kept. Running the script again says "already installed"
when nothing changed. It prints the tag, the fork commit and the upstream commit from the
release notes.

**Rolling back.** `install.sh <older tag>` switches `current` back at once if that build is
still installed, or downloads it if the release is still kept (the newest 10 are).

**A build broken by an Arch update.** Before switching to a build, the script runs `ldd` on it
and refuses one with a missing library, naming it. `--list` marks an installed build
`BROKEN` the same way. Then rebuild against the new libraries with
`gh workflow run build-linux.yml -R angwdev/mgba-r` and install again.

**joypad-mcp.** joypad-mcp picks the program from `$JOYPAD_MGBA`
(`src/joypad_mcp/config.py`, `mgba_program`). To use the fork, add this line to the `env`
of joypad-mcp's MCP server entry:

```json
"JOYPAD_MGBA": "/home/<you>/.local/bin/mgba-r"
```

`"mgba-r"` also works when `~/.local/bin` is on the `PATH` the MCP client passes on. The full
path does not depend on that. Remove the line to go back to stock mGBA.

### Drop-in check (2026-11-27)

| Check | Stock `mgba-qt` `0.11-9204-c4fe856f2` | `mgba-r` `remote-4b8e3a47f` |
|---|---|---|
| joypad-mcp `uv run pytest` | 500 passed, 0 skipped (53 s) | 500 passed, 0 skipped (50 s), with `JOYPAD_MGBA=mgba-r` |
| Program that ran | `/usr/bin/mgba-qt` | `~/.local/opt/mgba-r/remote-4b8e3a47f/bin/mgba-qt`, all 34 starts in the three mGBA test files (seen through a logging wrapper) |
| Saved moment made here, loaded in the other | loads, same counter at load and after 30 frames | loads, same counter at load and after 30 frames |

Both builds are at upstream `c4fe856f2`, so the state formats match. The tests run mGBA
offscreen or on their own Xvfb display, muted, with their own settings folder: no window
appeared on the desktop and nothing played sound. Saved moments were checked with joypad-mcp's
own mgba backend (`serialize`/`unserialize`, the bridge's `save`/`load`) on the ROM from
`tests/romgen.py`.

### Approaches considered (install)

| Decision | Options | Evidence | Choice | Why |
|---|---|---|---|---|
| How to install | a script that installs releases; a PKGBUILD (`mgba-r-bin`) installing the release beside the stock package; AppImage; Flatpak; `gh run download` of Actions artifacts | A package needs `sudo` for every install and rollback, and pacman keeps only one version installed (rollback means the package cache or `downgrade`). The build is not an AppImage or Flatpak (see Build). Actions artifacts expire (90 days at most) and need a run ID | `joypad/install.sh` | No `sudo`; several builds side by side, so a rollback is a symlink switch; one command |
| Not shadowing the stock program | the name `mgba-r` in `~/.local/bin`; a `mgba-qt` earlier on the `PATH`; only a path under `~/.local/opt` | `~/.local/bin` is on the `PATH` here, ahead of `/usr/bin` | the name `mgba-r` | `mgba-qt` stays the stock one wherever it is called |
| Link or wrapper | a symlink; a shell wrapper | The binary finds `libmgba` through `$ORIGIN/../lib` and its data through its own folder (`GBAApp::dataDir`); both follow the symlink to the real file (`/proc/self/exe`) | symlink | No extra process; joypad-mcp's process handling sees mGBA itself |
| Which builds to keep | all; the newest 3; only the current | Each build is 11 MB unpacked | the newest 3 (by build time), never the current one | Enough to roll back; small |
| Detecting a broken build | `ldd` at install and in `--list`; nothing | Arch bumps sonames (ffmpeg, Lua) a few times a year | `ldd` | Says which library is missing before the build is used |
| How joypad-mcp finds it | `JOYPAD_MGBA` with the full path; `JOYPAD_MGBA=mgba-r` through the `PATH` | `config.py`: a name on the `PATH` or a path | the full path in the MCP `env` | Works even when the MCP client's `PATH` lacks `~/.local/bin` |

## Staying up to date

[`.github/workflows/sync-upstream.yml`](../../.github/workflows/sync-upstream.yml) runs every
day at 05:37 UTC and by hand (`gh workflow run sync-upstream.yml -R angwdev/mgba-r`). It:

1. fetches upstream `mgba-emu/mgba` `master`;
2. fast-forwards the fork's `master` to it with a plain `git push` (no `--force`). If `master`
   has a commit upstream does not have, it changes nothing and fails;
3. if `remote` does not contain upstream `master` yet, merges it into `remote` with a merge
   commit and pushes;
4. after a clean merge, calls `build-linux.yml`, so a new release appears (a push made with
   the workflow's own token does not start other workflows by itself);
5. does nothing, and stays green, when upstream has not moved.

`joypad/sync.sh` does the same from this clone with your own login, for when you want a sync
now or the workflow is blocked. `joypad/sync.sh --dry-run` only reports what it would do.

### Default branch

`remote` is the default branch (changed 2026-11-27). The schedule needs it, because GitHub
runs scheduled workflows only from the default branch. What changes:

- the repository page shows `remote`, so visitors see the fork's work and these documents,
  not a bare copy of upstream;
- `gh repo clone angwdev/mgba-r` and `git clone` check out `remote`. `master` is still
  there (`git switch master`);
- "Sync fork" on the GitHub page and the "This branch is N commits ahead" line now compare
  `remote` with upstream. Do not press "Sync fork" on `remote`: the workflow does that job,
  and GitHub's button could discard the fork's commits if you pick "Discard";
- new pull requests inside the fork target `remote` by default.

### When a conflict issue appears

If upstream changed the same lines as the fork, the merge stops. The run then:

- pushes nothing to `remote` (`master` is still fast-forwarded, because it is only a copy);
- opens one issue titled **Upstream merge conflict**, listing the conflicting files and the
  upstream commits that are not in `remote` yet. Later runs update that issue and add a
  comment, and never open a second one;
- fails, so GitHub sends you its usual failed-run notice.

To resolve it by hand:

```sh
cd ~/Documents/Work/angwdev/mgba-r
joypad/sync.sh            # stops on the conflict, leaves the merge in progress on remote
git status                # the files marked "both modified"
# edit the files, keeping the fork's change and upstream's
git add <files>
git commit                # completes the merge commit
git push origin remote    # no --force; this push also starts build-linux.yml
```

`git merge --abort` gives up instead and leaves `remote` as it was. The next sync finds
upstream already merged and closes the issue with a comment.

### Workflow files from upstream

`GITHUB_TOKEN` may not push commits that change files under `.github/workflows/`. Upstream
has no workflows today, so its commits never touch them, and the merge commit changes no
workflow file relative to `remote` (the first real sync, run
[46029852087](https://github.com/angwdev/mgba-r/actions/runs/46029852087), pushed fine). If
upstream ever adds workflows, the run stops before merging and says so. Your options then:

1. run `joypad/sync.sh` (your `gh` login has the `workflow` scope), the simplest;
2. or create a fine-grained personal token for this repository only, with Contents and
   Workflows write access, store it as a secret, and use it in the checkout step. It
   expires and has to be renewed, so it is not set up now.

Upstream workflows would also run in the fork on its own triggers; disable the ones you do
not want with `gh workflow disable`.

### The 60-day rule

GitHub turns off a public repository's schedules after 60 days without activity, and a fork
starts with its schedules off. `sync-upstream` was added to the fork as a new workflow and is
`active` (`gh workflow list -R angwdev/mgba-r`). It stays active because every real sync is a
push: upstream's longest gap between commits over the last three years was 24 days
(`git log upstream/master --since=2023-11-01`). No artificial "keepalive" commits or API
calls are used; the best-known keepalive project, `gautamkrishnar/keepalive-workflow`, is
blocked by GitHub for a Terms of Service reason. If upstream ever goes quiet for 60 days,
GitHub disables the workflow and shows a banner on the Actions page; `joypad/sync.sh` then
prints a warning with the command to turn it back on
(`gh workflow enable sync-upstream.yml -R angwdev/mgba-r`).

### Runs made while setting this up (2026-11-27)

| Run | What it showed |
|---|---|
| [46029852087](https://github.com/angwdev/mgba-r/actions/runs/46029852087) | Real sync: `master` fast-forwarded 2 commits (`43193561` to `c4fe856f`), merged into `remote` as `89b61cf33`, build called, release `remote-89b61cf33` |
| [46030730138](https://github.com/angwdev/mgba-r/actions/runs/46030730138) | No-op: nothing changed, green, build skipped |
| [46030960163](https://github.com/angwdev/mgba-r/actions/runs/46030960163), [46031046890](https://github.com/angwdev/mgba-r/actions/runs/46031046890) | Conflict test on throwaway branches `test/sync-master` and `test/sync-remote` (a deliberate edit to `src/platform/sdl/sdl-events.c`): the first run opened the issue, the second updated it and added a comment; `test/sync-remote` was not changed; both runs failed. The test branches and the issue were deleted afterwards |

### Approaches considered (sync)

| Decision | Options | Evidence | Choice | Why |
|---|---|---|---|---|
| Sync mechanism | plain `git` in a scheduled workflow; the `merge-upstream` REST API; a Marketplace sync action (for example `aormsby/Fork-Sync-With-Upstream-action`); the Pull app (`wei/pull`); GitHub's "Sync fork" button; a local systemd timer running `joypad/sync.sh` | REST docs: `merge-upstream` returns `merge_type` `merge` when the branch has diverged, so it writes a merge commit, which `master` must never get. The Pull app opens pull requests or uses `hardreset` (a force-push). Marketplace actions are third-party code given a write token. "Sync fork" is manual. A systemd timer only runs when this machine is on | plain `git` in the workflow, plus `joypad/sync.sh` by hand | A non-forced `git push` can only fast-forward, so the no-force rule is enforced by git itself; no third-party code; conflicts become an issue and a failed run |
| Carrying the fork's changes | merge commits on `remote`; a patch series applied on top of upstream | A patch series has to be re-applied and pushed over the old one each time upstream moves: a force-push on a published branch, or a new branch each time | merge commits | Never rewrites history; `git diff master remote` still shows the fork's whole change at any time |
| Token | `GITHUB_TOKEN` (`contents: write`, `issues: write`); a personal token with workflow access | Docs: `GITHUB_TOKEN` cannot push workflow-file changes; upstream has none | `GITHUB_TOKEN` | Nothing to renew; the workflow-file case is detected and explained above |
| Conflict reporting | one issue, updated; a new issue per run; only a failed run | Daily runs would pile up issues | one issue, updated, plus a failed run | One place to look; the failure sends a notice |
| Schedule | daily; hourly; weekly | Upstream commits a few times a week | daily at 05:37 UTC | Fast enough; off the hour, when GitHub's scheduler is busiest |
| Keeping the schedule alive | real activity; keepalive commits or API calls; nothing | Upstream's longest gap is 24 days; the keepalive project is blocked by GitHub | real activity plus a warning in `sync.sh` | No artificial activity |
