# mgba-r: plan for the joypad-mcp remote

Status: **design approved by the owner on 2026-11-27**, with the answers recorded in
[Decisions](#decisions-2026-11-27). Nothing in this plan is built yet.

Written 2026-11-27 against `remote` at `89b61cf33`, which is upstream `c4fe856f2` plus the
fork's CI. Every claim about mGBA cites a file and a function at that commit. Line numbers
are left out on purpose, because they move with every upstream merge.

The goal: joypad-mcp drives mgba-r completely through the program itself, with no X11,
XWayland or desktop tools, on any desktop. That covers the shared game, windows, pictures,
keys, every menu action, fast-forward, status and a live view. A copy of mgba-r started by
hand behaves exactly like stock mGBA.

Sources read for this plan:

- mGBA's source (below).
- joypad-mcp, read only:
  - `specs/003-nds-host/spec.md` (User Stories 6 to 8, FR-211 to FR-222, SC-206 to SC-212,
    Assumptions);
  - `specs/001-generic-gba-host/spec.md` (FR-015 to FR-018) and `research.md` (R18, R19);
  - `src/joypad_mcp/backend/mgba_bridge.lua`, `mgba_app.py` and `src/joypad_mcp/window.py`;
  - `tests/conftest.py`, `tests/integration/`;
  - the constitution;
  - `HANDOFF.md` ("Feature 003 and the emulator forks").
- Qt 6 documentation, through Context7.
- Prior art (see [Prior art](#prior-art)).
- A throwaway benchmark (see [The live view's transport](#the-live-views-transport)).

melonDSr had no `remote` branch and no `PLAN.md` when this was written. The command names
below follow joypad-mcp's bridge and the spec, so that prompt 5 can merge the two tables.

---

## Summary of the decisions

1. **The commands are built into the Qt frontend, in new files under
   `src/platform/qt/joypad/`. They do not live in Lua.** This agrees with the spec's assumption
   ("the mGBA fork has the commands built in and needs no Lua script"). Upstream files gain
   about 15 lines in total: 4 files, all hooks or one-line accessors. Stock mGBA keeps working
   with today's Lua bridge, unchanged.
2. **The game is held at the end of a frame with mGBA's own "core-set pause"**
   (`mTHREAD_REQ_WAIT`, `mCoreThreadWaitFromThread` in `src/core/thread.c`). The bridge
   instead blocks inside a callback. With the core-set pause, the owner's Pause, mGBA's menus
   and mGBA's dialogs keep working during a request, and the frames stay exact.
3. **The control channel works as it does today: mgba-r connects to a loopback TCP port that
   joypad-mcp opens.** It speaks a line protocol that extends the bridge's. A one-time token in
   the environment proves who started it. Without that variable, no fork code runs.
4. **Windows, pictures and keys are handled inside the process.**
   - Windows are listed with Qt's list of top-level widgets.
   - Pictures come from `QWidget::grab`, with the game frame painted in where mGBA's OpenGL
     display draws on its own thread.
   - Keys are synthetic Qt events sent to the target window's focus widget. A key that is a
     menu shortcut triggers the action directly.
   - Qt's own file dialogs are forced, and windows the agent opens are shown without
     activating them.
5. **Fast-forward, status and every menu action become direct commands.** Actions are listed
   by mGBA's own stable action names (`ActionMapper`). A refusal table protects quit, file
   dialogs and the settings joypad-mcp fixes.
6. **The live view sends a small record per frame (frame number, 64-bit screen hash, a
   15×10 change mask) over a second socket, not the frames themselves.** Pictures are taken on
   request. Waits are checked by joypad-mcp after each frame inside a request. Sprites are
   decoded by joypad-mcp from OAM. The fork adds about 32 µs of work per frame.
7. **Saved moments default to mGBA's raw format with save data and clock (flags 10).**
   joypad-mcp's mode without a window already uses that format (`retro_serialize` in
   `src/platform/libretro/libretro.c`), so states move between the modes. PNG states still
   load.

---

## 1. Where the commands live

### What the source says

The Lua route (option a) runs into five limits in mGBA itself:

- **Sockets are only serviced from the `frame` callback.** `_socketLuaSource` in
  `src/script/engines/lua.c` hooks every socket with `callbacks:add('frame', ...)`. The
  `frame` callback is the core's `videoFrameEnded` (`mScriptContextAttachCore` in
  `src/core/scripting.c`).

  So a script answers nothing in these cases:
  - while the owner has paused;
  - while a file dialog is open, because `GBAApp::getOpenFileName` and its siblings call
    `pauseAll` (`src/platform/qt/GBAApp.cpp`);
  - when no game is loaded.

  Feature 001's contract promises that `window` "answers while the game runs and while the
  owner has paused it". A Lua route cannot keep that promise.
- **The script is started only once a game has started.** It is also skipped when the owner
  has autorun scripts. `Window::setController` loads `--script` files only
  `if (!m_scripting)`, after `m_controller->start()`. The `Window` constructor calls
  `ensureScripting()` whenever `autorunSettings` is non-empty (both in
  `src/platform/qt/Window.cpp`).
- **`--script` opens the Scripting window** (`Window::scriptingOpen`), which the owner sees.
- **The bridge holds the game by blocking the emulation thread inside the callback**
  (`hold()` in `mgba_bridge.lua`). Any UI call that interrupts the core then waits:
  `CoreController::Interrupter::interrupt` → `mCoreThreadInterrupt` →
  `_waitUntilNotState(..., mTHREAD_INTERRUPTING)`, in `src/core/thread.c` and
  `CoreController.cpp`.

  A Lua binding for a window picture or a key would have to run on the UI thread. It would
  be called from the emulation thread and wait for the UI thread. If the UI thread is at the
  same moment waiting in an `Interrupter`, the two threads deadlock. This is a new timing
  race, not just a slow path.
- **No frontend bindings exist.** The scripting globals are:
  - `emu` (`src/core/scripting.c`);
  - `console`, `input`, `storage`, `canvas`, `image`, `socket`, `callbacks`, `util`, `C`,
    `system` (all in `src/script/`).

  None of them reaches windows, actions, pause or fast-forward. All of these would have to
  be added to `ScriptingController` (`src/platform/qt/scripting/ScriptingController.cpp`) as
  new `mScript` types, inside upstream files that change often.

A built-in server in the Qt frontend (option b) has none of these limits:

- It lives on the UI thread's event loop. That loop keeps running inside modal dialogs.
- It runs game commands with the same thread primitives mGBA's own menus use
  (`mCoreThreadRunFunction`, `CoreController::Interrupter`).
- It reaches everything through public API:
  - `GBAApp::windows()`;
  - `Window::controller()`;
  - `ActionMapper::getAction`, `menuItems`;
  - `ShortcutController::shortcut`;
  - `CoreController::forceFastForward`, `isPaused`, `frameCounter`, `getPixels`.

### The decision

**Option (b): a built-in command server, in new files under `src/platform/qt/joypad/`.** It
replaces the bridge script for mgba-r. The bridge stays in joypad-mcp for stock mGBA
(spec, User Story 6, scenario 5).

Diff against upstream, planned:

| Upstream file | Change | Why |
|---|---|---|
| `src/platform/qt/main.cpp` | 2 calls under `#ifdef ENABLE_JOYPAD`: `Joypad::prepare()` before `GBAApp` is constructed, `Joypad::start(&application)` after `w->argumentsPassed()` | `Qt::AA_DontUseNativeDialogs` must be set before the application object exists (Qt docs) |
| `src/platform/qt/CMakeLists.txt` | about 3 lines: `option(ENABLE_JOYPAD ... ON)` and `include(joypad/joypad.cmake)` | the new sources and the build-time version |
| `src/platform/qt/GBAApp.h` | 1 accessor: `CoreManager* coreManager()` | `CoreManager::coreLoaded` is the only signal that a new game is about to start, and `m_manager` is private |
| `src/platform/qt/Window.h` | 1 accessor: `ActionMapper* actions()` | `m_actions` is a private member with no parent, so `findChild` cannot reach it |

Everything else reaches mGBA through objects that are already public:

- `Display` is a child widget of `Window` (`Display::create(this)` in `Window.cpp`).
- `ShortcutController` is constructed with `this` as parent (`Window::Window`).

Both are found with `findChild`. Upstream merges can only conflict in these four spots.

**Timing.** The frames are exactly as exact as today (see
[Holding the game](#holding-the-game-take-run-release)). One race goes away: the deadlock
described above. One race is reduced: the UI thread no longer freezes during a request.

**Spec assumption: confirmed, not contradicted.** The spec changes this implies are small;
they are listed in [Spec changes to propose](#spec-changes-to-propose).

**Upstream.** Two pieces are general enough to be useful upstream one day:

- an `ActionMapper` method that lists every action;
- Lua bindings for pause and fast-forward.

Upstream's maintainer wrote on PR #3752 (closed): "We do not accept code written by LLMs."
So nothing from this fork is offered. The owner decided the fork's copy is enough, and no
piece is set aside for upstream (decision 10). Upstream is not contacted.

### Holding the game: take, run, release

How mGBA's emulation thread runs (`_mCoreThreadRun` in `src/core/thread.c`):

- It calls `core->runLoop` while the state is `mTHREAD_RUNNING`. For GBA that is
  `ARMRunLoop`, which runs to the next event and processes it (`src/arm/arm.c`).
- The frame's end is an event: `GBAFrameEnded` (`src/gba/gba.c`) calls every registered
  `videoFrameEnded` callback. After that, `runLoop` returns and the thread checks its state.
- A request posted from inside a frame-end callback therefore stops the game exactly at that
  frame's end. mGBA's own "Next frame" works this way (`CoreController::finishFrame`,
  `m_moreFrames`, then `mCoreThreadPauseFromThread`).

The fork registers its own `mCoreCallbacks` (`videoFrameEnded` and `keysRead`) on the new
core when `CoreManager::coreLoaded` fires. That happens before `CoreController::start`, so no
frame is missed.

| Step | Where it happens | What it does |
|---|---|---|
| `take` | UI thread sets a flag; the next `videoFrameEnded` on the emulation thread acts on it | Saves the owner's keys (`core->getKeys`), then calls `mCoreThreadWaitFromThread`, the "core-set pause" (`mTHREAD_REQ_WAIT`, `include/mgba/core/thread.h`). Replies with the frames run since the last take. |
| `run <keys> [n]` | UI thread | Stores the agent's keys and a frame count, then calls `mCoreThreadStopWaiting`. Each `videoFrameEnded` counts down; at 0 it waits again and queues the reply to the UI thread. The reply is not blocking. |
| keys inside a request | `keysRead` callback, at the moment the game reads `KEYINPUT` (`GBAIORead` in `src/gba/io.c`, `case GBA_REG_KEYINPUT`) | Sets exactly the agent's keys. This is the same hook the bridge uses, so the owner's input set in `CoreController::updateKeys` never reaches an agent frame. |
| `release` | UI thread | Restores the owner's keys and calls `mCoreThreadStopWaiting`. |
| memory, states, reset while taken | UI thread, through `CoreController::Interrupter` or `mCoreThreadRunFunction`, the same way `CoreController::loadState` does | The thread is parked at the frame's end, so these see exactly that frame. |

Why the core-set pause, and not the bridge's blocking wait or the owner's pause:

- It is separate from the owner's Pause (`mTHREAD_REQ_PAUSE`). `CoreController::setPaused`
  and `GBAApp::continueAll` cancel only `REQ_PAUSE`, so they cannot release the agent's
  hold.
- If the owner pauses, `REQ_PAUSE` keeps the thread stopped after `StopWaiting`, so a request
  waits instead of failing, as FR-016 asks.
- While the thread waits, interrupts still run (`_isActive` includes the waiting states). So
  mGBA's menus, its dialogs and the window commands never freeze.
- Its only upstream user is the link-cable lockstep (`src/core/lockstep.c`). The fork
  therefore refuses `multiWindow`, because multiplayer is out of scope.

Owner menu actions that change the game (reset, load state, rewind), used *during* a
request, would run between two agent frames. That is also true today: the bridge's `hold()`
returns between `run`s, and a pending interrupt runs then. The fork keeps that behaviour in
this plan and reports it, so nothing regresses. Deferring such actions until `release` would
need a hook in `Window::addGameAction`; the owner chose not to add it (decision 7).

---

## 2. Windows without X11

Everything below happens inside the process, on the UI thread. So it works the same with
`QT_QPA_PLATFORM=wayland`, `xcb` or `offscreen`, with `DISPLAY` unset, and needs no desktop
program.

**List.**

- The list is `QApplication::topLevelWidgets()`, filtered to visible ones. It includes:
  - the game window (`Window`, from `GBAApp::windows()`);
  - tool views (opened through `Window::openView`);
  - `QMessageBox`es;
  - Qt's own `QFileDialog`;
  - popup `QMenu`s (`Qt::Popup`).
- Each window gets a small id, kept for as long as the widget exists (a map from
  `QPointer<QWidget>` to an int). The game window is id 1.
- One line per window: `<id> <kind> <w>x<h> <active 0|1> <title>`. The kind is one of
  `game`, `dialog`, `filedialog`, `menu` or `tool`.
- On Wayland a client cannot know its windows' positions, so none are given. They were never
  in Feature 001's contract.

**Picture as the owner sees it.**

- `QWidget::grab()` renders a widget and all its children into a pixmap, through Qt's own
  painting. It needs no compositor and works for covered or background windows (Qt docs).
  That covers dialogs, tool views, menus and the game window's menu and status bars.
- The game picture is the exception. `DisplayGL` (`src/platform/qt/DisplayGL.cpp`) makes its
  widget a native window (`Qt::WA_NativeWindow`, `QSurface::OpenGLSurface`). `PainterGL`
  draws into it from its own "Painter Thread". Qt's documentation sends anyone who wants a
  GL widget's contents to `QOpenGLWidget::grabFramebuffer()`, which is expensive and not this
  case.
- So the fork paints the latest frame (`CoreController::getPixels`) into the `Display`
  widget's rectangle, scaled with the same `clampSize(...)` that `DisplayQt::paintEvent`
  uses (`src/platform/qt/utils.h`). It honours aspect-ratio and integer-scaling locks.
- Shaders and on-screen messages are not in the picture. This is documented. The software
  display (`DisplayQt`) needs no composition at all.
- The reply is raw RGBA with width and height. joypad-mcp encodes the PNG with Pillow, which
  it already uses.

**Keys without focus.**

- `keys <id> <key>...` builds `QKeyEvent` press/release pairs. Key names are joypad-mcp's
  (`window.py` `_key`). The events go with `QCoreApplication::sendEvent` to the target's
  `focusWidget()`, or to the window itself.
- Synthetic events go straight to the receiver; nothing about window activation changes
  (Qt docs, "Sending Events"). That is how Feature 001's XSendEvent keys worked.
- `QDialog`/`QMessageBox` handle Return and Escape in `keyPressEvent`, so dialogs can be
  answered.
- For the game window, `Window::keyPressEvent` and `ShortcutController::eventFilter` handle
  game keys and held actions (Tab = `holdFastForward`), as for the owner's keys.

**Menu shortcuts.**

- mGBA's ordinary shortcuts are `QAction` shortcuts with `Qt::WidgetShortcut` context
  (`ActionMapper::rebuildMenu`). Qt resolves them in its shortcut map only for the active
  window. That is exactly why Feature 001 found that Ctrl+P "does nothing".
- So before sending, the fork compares each key with every action's current shortcut
  (`ShortcutController::shortcut(name)->shortcut()`). On a match it triggers the action
  instead, under the same refusal rules, and replies `triggered <action>`.
- Held shortcuts (Tab) already work as events, because `ShortcutController::eventFilter`
  handles them.

**Popup menus.**

- Menus the owner opens appear in the list and can be pictured.
- Keys to an open popup go to `QApplication::activePopupWidget()`, which Qt routes all keys to
  anyway.
- The agent is not expected to open menus: every menu item is an action (section 5). Opening
  a popup without a real input event is unreliable on Wayland, because xdg-popup needs an
  input serial. The plan does not depend on it.

**File dialogs.**

- `GBAApp::getOpenFileName`, `getOpenFileNames`, `getSaveFileName` and
  `getExistingDirectory` are mGBA's only `QFileDialog` calls. They use the platform's
  dialog, which on a portal setup is another process that cannot be listed, pictured or sent
  keys.
- When joypad-mcp starts the fork, `Joypad::prepare()` sets `Qt::AA_DontUseNativeDialogs`
  before `GBAApp` is constructed. The Qt docs say it "must be set before QGuiApplication is
  constructed", which is why the hook sits in `main.cpp` and not in `GBAApp.cpp`. Every file
  dialog is then Qt's own widget dialog. Started by hand, nothing changes.
- The agent's keys to a `QFileDialog` are refused, except Escape, so that no file outside
  joypad-mcp's paths can be chosen (FR-217). Decided (decision 5).

**Never move the owner's focus.**

- Qt 6.8 on Wayland "will now also request activation from the compositor" whenever a window
  is shown, "except when `Qt::WA_ShowWithoutActivating` is set" (Qt 6.8 "What's new").
- While an agent action or agent keys run, the fork sets that attribute on every new
  top-level widget, on its `QEvent::Polish`, before the widget is shown.
- The fork never calls `raise()`, `activateWindow()` or `requestActivate()`.
- `status` reports `focus=1` when any fork window is active. SC-207 and SC-212 check exactly
  that.
- The game window itself also opens without activation when joypad-mcp starts the fork
  (decision 1): the fork sets `WA_ShowWithoutActivating` on the main window before it is
  first shown. The owner clicks the window to play. Started by hand, it takes focus as stock
  mGBA does.

---

## 3. Fast-forward

**It becomes a direct command, `ff on [speed]` / `ff off`.** No key is held any more.

- `on` calls `CoreController::forceFastForward(true)`, which is what the `fastForward` menu
  action does (`Window::setupMenu`). It also sets that action active, so the menu tick stays
  right.
- `speed` triggers the existing menu value `fastForwardRatio.<n>`: `-1` is unbounded, and
  `2` to `10` are the multiples (`Window::setupMenu`, the `ffspeed` `ConfigOption`).
- The speed goes through mGBA's own option on purpose. joypad-mcp must not fix
  `fastForwardRatio` with `-C`: a `-C` value beats whatever the menu sets
  (`_lookupValue` in `src/core/config.c` checks `overridesTable` first), so the menu, and
  the command, would stop working.

**When it is released:**

- **A game loads.** A new `CoreController` starts with `m_fastForwardForced = false`
  (`CoreController.h`). On `CoreManager::coreLoaded`, the fork also clears the `fastForward`
  action's active mark and releases any held `holdFastForward`.
- **joypad-mcp goes away.** When the socket closes, the fork turns fast-forward off, lets
  every held key go, puts back the owner's `fastForwardRatio` (read at hello), releases the
  game, and from then on behaves as stock mGBA.
- **The owner turns it off** (Shift+Tab or the menu). That is fine: `status` shows it.

Inside a request, frames stay exact at any speed. Fast-forward only removes the waiting
between frames (`CoreController::updateFastForward` → `setSync(false)`).

`window op=hold keys=["Tab"]` from Feature 001 keeps working: it is an ordinary held key.
joypad-mcp should map it to `ff on` for mgba-r.

---

## 4. Only when started by joypad-mcp

**The handshake:**

1. joypad-mcp opens a listening socket on `127.0.0.1`, port 0, as `MgbaAppBackend.load` does
   today.
2. It starts mgba-r with `JOYPAD_REMOTE=<port>:<token>`, where the token is 32 random bytes in
   hex, new for every start.
3. `Joypad::prepare()` reads the variable and removes it from the environment, so nothing
   mGBA starts inherits it. If the variable is absent or malformed, the function returns at
   once. Then no socket, no Qt attribute and no callback is created, and the program is stock
   mGBA.
4. mgba-r connects to `QHostAddress::LocalHost:<port>`. It never listens, so nothing on the
   machine or the network can connect to it. Its first line is
   `ok hello protocol=1 token=<token> ...` (the bridge also starts with `ok hello`).
5. joypad-mcp accepts only a peer that sends its token. It checks the token in constant time
   and closes any other connection.
6. A second connection with `ok live token=<token>` carries the live view (section 6).
7. If the connection fails or the token is refused, mgba-r logs one line and runs as stock
   mGBA, as the bridge does when "the server is gone".

Why this design:

- It keeps joypad-mcp's existing accept loop (`MgbaAppBackend._accept`).
- It satisfies FR-213 ("over the loopback address only", "only accept the host when the host
  started it").
- It avoids two mistakes the prior art makes: binding all interfaces (mGBA's own Lua
  `socket.bind(nil, ...)`, its Qt GDB stub, RetroArch's UDP commands) and having no token.

The environment of a process is readable only by the same user (`/proc/<pid>/environ`).

---

## 5. Version check

`version`, and the greeting, carry these fields:

```
ok hello protocol=1 token=<t> program=mGBA version=<projectVersion> fork=<gitCommit> upstream=<sha> qt=<qVersion()>
```

- `version` and `fork` are mGBA's own build constants (`src/core/version.c.in`, filled by
  `version.cmake`).
- `upstream` is the upstream commit the build is based on. CI already computes it:
  `build-linux.yml`, step `src`, `git merge-base HEAD refs/remotes/upstream/master`. CI
  passes it to CMake as `-DJOYPAD_UPSTREAM_COMMIT=<sha>`.
- Local builds use `joypad.cmake`, which runs the same `git merge-base` against
  `upstream/master` or `master`. If neither exists, it writes `(unknown)`.
- `protocol` is one integer. It goes up on any change joypad-mcp would misread: a removed or
  renamed command, a changed reply, a changed record format. New optional commands or fields
  do not raise it. A command mgba-r does not have is answered with `err unknown <name>`.

**How joypad-mcp refuses an unknown version (FR-216).**

- It knows the protocol versions it speaks. A greeting with another `protocol`, no greeting
  within `START_SECONDS`, or the process exiting first, all end in `unsupported`, naming the
  version found and the version needed (spec, Edge Cases). joypad-mcp then stops the process.
- Stock mGBA is never used silently instead: the program is chosen by configuration
  (FR-212).
- `status` shows `program`, `fork` and `upstream`, so the owner can see which build runs and
  whether its saved moments match stock mGBA (section 7).

---

## 6. Folders and files (FR-211)

The fork adds no file of its own:

- no shared-memory file;
- no socket file;
- no log beyond mGBA's stdout, which joypad-mcp already sends to `mgba.log`.

What mGBA itself writes is controlled exactly as today:

- **Game files go to joypad-mcp's data folder.** The `-C` options `savegamePath`,
  `savestatePath`, `screenshotPath`, `patchPath` and `cheatsPath` cover every per-game folder
  mGBA has: `mDirectorySetMapOptions` in `src/core/directories.c`; `struct mDirectorySet` has
  `save`, `patch`, `state`, `screenshot` and `cheats` beside `base` and `archive`.
- **A `-C` value is never saved.** `mCoreConfigSave` writes `configTable`, not
  `overridesTable` (`src/core/config.c`).
- **Settings are the owner's.** mGBA reads the owner's settings from `mCoreConfigDirectory`:
  `$XDG_CONFIG_HOME/<binary>` or `~/.config/mgba`. It keeps updating `qt.ini` with recent
  files, as Feature 001's FR-014 exception records.

Three facts found while reading, for joypad-mcp:

- **`mCoreConfigPortableIniPath` looks for `portable.ini` in the current directory** on Linux
  (`getcwd`). A `portable.ini` there would move all of mGBA's settings into that folder.
  joypad-mcp should start mgba-r with its game folder as the working directory. It does not
  set one today.
- **The Settings dialog saves what it shows** (`SettingsView::saveSetting` →
  `ConfigController::setOption`). If the owner presses OK in Settings while joypad-mcp runs,
  the `-C` folder paths can be written into the owner's `config.ini`. This is stock behaviour.
  The fork refuses the `settings` action for the agent, but cannot stop the owner without
  changing upstream code. The owner keeps sharing `~/.config/mgba` and accepts this risk
  (decision 3).
- **Recordings and state files the owner picks by hand go where the owner points the file
  dialog.** That is the owner's choice, and the agent cannot open those dialogs (section
  "Program actions").

---

## 7. Saved-moment compatibility (User Story 6, scenario 6)

**What makes a state load.**

- `GBADeserialize` (`src/gba/serialize.c`) refuses a state with a newer `versionMagic`
  (`GBASavestateMagic + GBASavestateVersion`, version `0x0B` here), another game id or title,
  or another ROM CRC.
- It also refuses some states made with another BIOS (`biosChecksum`, with the program
  counter inside the BIOS). For other states with a different BIOS it only warns, but the
  emulated BIOS then differs, so a replay can diverge.

**What makes it the same moment.** Same upstream commit, same game, same BIOS. The fork
changes no file under `src/gba` or `src/core`, so at the same upstream commit its states are
byte-compatible with stock mGBA's.

**Format.**

- `mCoreSaveStateNamed` (`src/core/serialize.c`) writes a PNG with the state inside when
  `SAVESTATE_SCREENSHOT` is set. Without it, it writes the raw state followed by extdata.
- `mCoreLoadStateNamed` → `mCoreExtractState` loads either one (`isPNG`).
- joypad-mcp's mode without a window uses libretro's `retro_serialize`, which is
  `mCoreSaveStateNamed(core, vfm, SAVESTATE_SAVEDATA | SAVESTATE_RTC)`: raw, flags 10
  (`src/platform/libretro/libretro.c`).
- Today the window backend saves flags 11 (PNG; `STATE_FLAGS` in `mgba_app.py`). Whether one
  mode's state loads in the other was never checked (`HANDOFF.md`).

**The decision.**

- mgba-r's `save` defaults to flags 10 (raw + save data + clock), the same bytes layout as
  the mode without a window.
- `load` accepts both formats.
- The test is a round trip in each direction: fork → stock mGBA → mode without a window →
  fork. Each leg is checked by identical memory and screens after 600 frames (SC-208).

**What joypad-mcp must also fix: the BIOS.**

- The window runs with the owner's `useBios`/`bios` settings. The libretro core may run its
  built-in BIOS.
- A state taken in one and replayed in the other can then diverge, or be refused.
- This may also explain the unexplained FireRed pixel differences from frame 500 on
  (`HANDOFF.md`: not checked).
- Decided (decision 4): joypad-mcp pins the built-in BIOS in both modes, `-C useBios=0`
  for the window and the libretro core's built-in BIOS for the mode without a window. The
  owner has no GBA BIOS file set (`gba.bios` is empty in `config.ini`), so the window already
  runs the built-in BIOS today and nothing visible changes.

---

## 8. Testing

**joypad-mcp's tests, against the fork.** `JOYPAD_MGBA=<path to mgba-r's mgba-qt>`
(`tests/conftest.py` `mgba_program`).

- **Drop-in.** Without `JOYPAD_REMOTE`, mgba-r is stock mGBA, so the existing suite with
  the Lua bridge must pass unchanged (SC-206; prompt 3 runs this).
- **Fork backend.** Once joypad-mcp has a backend for mgba-r, the same tests in
  `test_mgba_app.py` run through the built-in protocol. They use the `hidden_mgba` fixture:
  `QT_QPA_PLATFORM=offscreen`, `SDL_AUDIODRIVER=dummy`, its own `XDG_CONFIG_HOME` and
  `TMPDIR`.
- **Window tests.** `test_mgba_window.py` is tied to X11 (`x11_mgba`: Xvfb, `xdotool`,
  `import`). It needs fork versions. Because listing, pictures and keys are now in-process,
  those versions run under plain `offscreen`, with no Xvfb at all. They can also check the
  game's pixels, which captured black on Xvfb (R19).

**Proving SC-207 (no X11) in CI.**

- Run the window tests under a headless Wayland compositor:
  - `weston --backend=headless` (package `weston`, 15.0.1 in Arch `extra`, also in Ubuntu);
  - `kwin_wayland --virtual`, which is installed on the owner's machine (`kwin` 6.8.3).
- Use `QT_QPA_PLATFORM=wayland`, with `DISPLAY` and `WAYLAND_DISPLAY` pointing only at the
  test compositor.
- The focus check works like this:
  1. A small client is started first and holds focus.
  2. The test asserts that `status` keeps `focus=0` through 10 runs of: list, picture, a
     dialog answered with keys, `ff on`/`off`, and actions.
  3. It also asserts the compositor never activated a fork window: weston's debug log, or
     KWin's `activeWindow`.
- None of this shows on the owner's desktop: the compositor has no output.
- The weston job runs on every push to `remote` (decision 9), beside the build.

**Tests on the fork's side.**

- Qt tests under `BUILD_SUITE`, following the existing `TEST_QT_*_SRC` pattern in
  `src/platform/qt/CMakeLists.txt`:
  - the line parser and reply framing;
  - key names to `QKeyEvent`;
  - shortcut-to-action matching;
  - the refusal table;
  - the per-frame hash and change mask on fixed images.
- One end-to-end test starts mgba-r offscreen with a tiny Python client from `joypad/test/`
  and the generated test ROM: hello, take, 60 runs, release, windows, picture.
- CI builds with `-DBUILD_SUITE=ON` in a separate job. Release builds stay as they are.

Constitution IV ("real core") holds: every integration test drives the real mgba-r.

---

## 9. Work order

Each step builds, keeps stock behaviour when started by hand, and can be checked on its
own.

| Step | Content | Check |
|---|---|---|
| 0 | `src/platform/qt/joypad/` skeleton, `joypad.cmake`, the 4 upstream hooks; `prepare()` and `start()` do nothing without `JOYPAD_REMOTE` | CI green; `mgba-qt --version` unchanged; joypad-mcp's suite with the Lua bridge passes (drop-in) |
| 1 | **Prototype:** connect, `hello`, `windows`, `picture` for one window | On native Wayland (`QT_QPA_PLATFORM=wayland`, no `DISPLAY`) under `kwin_wayland --virtual`: the game window is listed and a correct picture comes back, menu bar plus game frame |
| 2 | `version` and `status`; `JOYPAD_UPSTREAM_COMMIT` from CI | `status` names fork and upstream; an unknown `protocol` is refused by a test client |
| 3 | `take`, `release`, `run`, `reset`, `screenshot`, `save`, `load`, `regions`, `read`, `write`: parity with the bridge | `test_mgba_app.py`'s cases through a fork backend: frame 0 on load, `free=`, the owner's keys between requests, a held request, closing, state replay |
| 4 | `keys`, `hold`, `unhold`; shortcut-to-action; `AA_DontUseNativeDialogs`; `WA_ShowWithoutActivating` | A dialog answered with Return; Ctrl+P pauses; `focus=0` throughout, offscreen and under headless weston |
| 5 | `actions`, `trigger`, the refusal table, `ff` | Every listed action triggered or refused (SC-212); pause, resume, ff at 2× and 4×, mute (User Story 7 test) |
| 6 | The live channel: per-frame records, skip counting | 2 s idle gives about 120 records with consecutive frame numbers; a host that stops reading sees `skipped=` and the game never slows; records identical on replay |
| 7 | Headless Wayland CI job for SC-207 | 10 of 10 runs pass in CI |
| later | Optional fork-side memory watches (see [The agent's eyes](#the-agents-eyes)) | only if joypad-mcp's measurements show request-side checks are too slow |

joypad-mcp's own side (a fork backend replacing `window.py` for mgba-r, the text view,
waits) is written in joypad-mcp after this plan and prompt 5. This plan does not change
joypad-mcp.

---

## 10. Licence

- mGBA is MPL 2.0, a file-level copyleft.
- The four upstream files that get hooks stay MPL 2.0 with their headers unchanged.
- Every new file under `src/platform/qt/joypad/` carries the standard MPL 2.0 header, the
  same as mGBA's own files, so the whole fork stays under one licence.
- Releases are built from public source on GitHub, which meets MPL's source requirement for
  the binaries.
- joypad-mcp contains none of the fork's code and talks to it only over a socket. It is a
  separate program, not a "Larger Work" in MPL's sense, so the MPL places no obligation on it.
- Ideas from GPL projects (RetroArch, pokebot-gen3) are used only as ideas. Their code goes
  neither here nor into joypad-mcp.

---

## The command table

The control connection is TCP on `127.0.0.1`, with mgba-r as the client.

**Framing.**

- One request per line: `<command> <arguments>`, UTF-8. Paths are the rest of the line, as in
  the bridge.
- One reply per line: `ok <payload>` or `err <kind> <message>`.
- A reply that ends with `+<n>` is followed by exactly `<n>` bytes: a text block of lines, or
  raw pixels.
- Requests are answered in order.
- *Taken* means the command needs the game taken first. As in the bridge, without it the
  reply is `err notaken`.
- `<keys>` in `run` is mGBA's key mask (`KEY_BITS` in `mgba_app.py`).

| Command | Arguments | Reply | Taken | Serves |
|---|---|---|---|---|
| (greeting) | (sent by mgba-r) | `ok hello protocol=1 token=<t> program= version= fork= upstream= qt=` | no | FR-213, FR-216 |
| `version` | none | the greeting's fields, without the token | no | FR-216 |
| `status` | none | `ok game=<0/1> paused=<0/1> taken=<0/1> ff=<0/1> speed=<-1/2..10> fps=<n.n> muted=<0/1> frame=<n> focus=<0/1> program= fork= upstream=` | no | FR-217, US7 s1 |
| `take` | none | `ok <frames run on their own>` | no | FR-215, FR-016 |
| `release` | none | `ok` | no | FR-215 |
| `run` | `<keys> [<n>]` | after the last frame: `ok f=<frame> h=<hash> m=<mask>` | yes | FR-215, FR-220 |
| `reset` | none | `ok f=0 h= m=` | yes | FR-202 |
| `screenshot` (alias `shot`) | `[<path>]` | no path: `ok rgba 240 160 +153600`; a path: PNG written there (as the bridge) and `ok` | yes | FR-202, FR-221 |
| `save` | `<flags> <path>` (default flags 10) | `ok` | yes | FR-202, US6 s6 |
| `load` | `<flags> <path>` | `ok` | yes | FR-202, US6 s6 |
| `regions` | none | `ok <name>:<start>:<length> ...` (as the bridge) | yes | FR-209 |
| `read` | `<domain> <offset> <length>` | `ok <hex>` | yes | FR-202, FR-220 |
| `write` | `<domain> <offset> <hex>` | `ok` | yes | FR-202 |
| `windows` | none | `ok +<n>`: lines `<id> <kind> <w>x<h> <active> <title>`, the game window first | no | FR-214 |
| `picture` | `<id>` | `ok rgba <w> <h> +<bytes>` | no | FR-214, FR-221 |
| `keys` | `<id> <key>...` (1 to 16 names) | `ok sent <keys> to <id>`, `ok triggered <action>`, or `ok closed` | no | FR-214 |
| `hold` | `<id> <key>...` | `ok holding <keys> in <id>` | no | FR-214 |
| `unhold` | `[<key>...]` | `ok released <keys>; holding <keys or nothing>` | no | FR-214 |
| `actions` | none | `ok +<n>`: lines `<name> <menu> <kind> <state> <allowed> <label>` | no | FR-217, US7 s2 |
| `trigger` | `<name> [on\|off]` | `ok <status line>` or `err refused <why>` | no | FR-217, US7 s3/s4 |
| `ff` | `on [<speed>]` or `off` | `ok <status line>` | no | FR-217, US6 s4, US7 s5 |
| (live greeting) | second connection, sent by mgba-r | `ok live protocol=1 token=<t>`, then one record per frame | no | FR-218 |

Error kinds:

- `unknown`: no such command;
- `args`: bad arguments;
- `nogame`;
- `notaken`;
- `refused`;
- `notfound`: no such window;
- `failed`: mGBA refused, for example a state for another game.

joypad-mcp maps them to its own error kinds (`invalid arguments`, `not found`,
`core error`).

---

## Program actions

**Names.** The names are mGBA's own stable action names, the second argument of every
`addAction`/`addGameAction`/`addBooleanAction`/`addHeldAction` call in `Window::setupMenu`.
Examples: `pause`, `fastForward`, `holdFastForward`, `fastForwardRatio.4`, `mute`, `reset`,
`screenshot`, `quickSave.3`, `frame.2x`, `videoLayer.bg0`.

**Listing.**

- The fork walks `ActionMapper::menuItems()` from the root. An entry starting with `.` is a
  submenu; this includes the hidden ones, such as `autofire`.
- For each name it reads `getAction(name)`: `visibleName()`, `isEnabled()`, `isActive()`,
  and whether it is checkable or held (`booleanAction()`, `isHeld()`).
- That needs no new upstream code beyond the `Window::actions()` accessor. The order is the
  menu order.

**Triggering.**

- `Action::trigger(bool)` runs on the UI thread, exactly what the menu item's `QAction`
  connection does (`ActionMapper::rebuildMenu`). No menu opens and no focus moves.
- A held action takes `on`/`off`. A checkable one takes `on`/`off` or toggles.

**Status.** Everything comes from what mGBA already has:

| Field | Source |
|---|---|
| game | `Window::controller()` |
| paused | `CoreController::isPaused` |
| fast-forward | the `fastForward` action's `isActive()`, plus the fork's own held state |
| speed | `ConfigController::getOption("fastForwardRatio")` |
| muted | the `mute` action |
| frame | the fork's counter |
| fps | the fork's own frame-end timing. mGBA computes fps only for the window title (`Window::showFPS`), and the fork does not touch that |

**Refused for the agent** (`err refused`, nothing changes; FR-217, US7 scenario 4). The
owner's own clicks are never affected.

| Why | Actions |
|---|---|
| Quits or closes the game | `quit`, `shutdown`, `multiWindow` |
| Opens a file dialog or another game | `loadROM`, `loadROMInArchive`, `addDirToLibrary`, `bootBIOS`, `replaceROM`, `mru.*`, `resetMru`, `loadAlternateSave`, `loadTemporarySave`, `convertSave`, `importShark`, `exportShark`, `loadPatch`, `loadStateFile`, `saveStateFile`, `scanCard`, `parseCard`, `loadCamImage`, `recordOutput`, `recordGIF`, `recordVL`, `memoryAccessView`, `createForwarder` |
| Changes settings joypad-mcp fixes, or the program itself | `settings`, `makePortable`, `overrideWindow`, `scripting` (runs arbitrary Lua), `cheatsWindow` |
| Opens a network listener or connection | `gdbWindow` (Qt's `GDBController` binds `0.0.0.0` by default: `m_bindAddress({ IPV4, {0} })`), `connectDolphin`, `bugReport` |
| Changes the game behind joypad-mcp's frame count; joypad-mcp has a request for it | `reset`, `frameAdvance`, `loadState`, `quickLoad.*`, `undoLoadState`, `rewind`, `frameRewind`, `holdRewind`, `yank` |
| Out of scope (multiplayer, debugger) | `debuggerWindow` |

Everything else is allowed:

- pause and resume;
- fast-forward and its speed;
- mute, frame size, full screen, display options, frameskip, FPS target, video layers and
  audio channels;
- screenshots and quick saves into joypad-mcp's folder;
- the read-only views (logs, ROM info, palette, sprites, tiles, map, frame inspector,
  memory, I/O registers);
- sensors, autofire and the GameShark button.

The settings joypad-mcp fixes are the `-C` options. They cannot change while it runs,
because `-C` beats the menus (`_lookupValue`).

Owner actions are not refused. A game-changing owner action during a request runs between
two agent frames, as today (section 1).

---

## The live view

**What travels.** Not frames: one small record per frame, on the second connection.

```
f=<frame> h=<16 hex: FNV-1a 64 of the RGBX8888 frame> m=<38 hex: 150-bit change mask> t=<0/1 taken> s=<records skipped before this one>
```

**Where it is computed.** In the fork's `videoFrameEnded` callback on the emulation thread:

1. Read the pixels with `core->getPixels`, as `mCoreSaveStateNamed` does for its screenshot.
2. Hash the frame.
3. Compare each 16×16-pixel cell (15×10 on GBA, tile-aligned) with the previous frame.
4. Push the record into a bounded queue (4,096 records, about 4 s at 1,000 fps).

This costs **32 µs per frame**, measured in C on this machine (benchmark below): 0.2% of a
core at 60 fps, 3% at 1,000 fps.

**Sending.** A sender on the UI thread writes the queue to the socket.

- It never blocks the emulation thread.
- If the queue is full because joypad-mcp fell behind, the oldest records are dropped and
  counted. The next record says `s=<n>` (FR-218, "MAY skip and MUST say so").
- Inside a request this cannot happen: every `run` reply carries its own frame's record, and
  the game only advances when joypad-mcp asks.

**What stays in joypad-mcp.**

- **Stillness:** consecutive equal `h`.
- **Changed areas since the agent's last look:** the OR of `m`. It can merge cells into a
  coarser grid for the text view.
- **Fingerprint and first seen:** the frame at which an `h` was first seen.
- **Sprites:** decoded from OAM (`read oam 0 1024`, plus `DISPCNT` for OBJ enable and
  mapping) when the text view is asked for, with the game taken.
- **Formatting the text** within 600 characters (FR-219).

The hash and mask algorithms are fixed in the protocol, so joypad-mcp can compute exactly
the same thing in the mode without a window. Text views are then the same in every mode.

**Why the fork does the hashing.**

- Measured in Python: hashing a frame costs 169 µs, and an 8×8 grid of cell checksums 355
  µs. joypad-mcp would fall behind at fast-forward speeds, which the owner uses (600 to
  1,300 fps in Feature 001).
- In C it is 32 µs, in a new file, with no merge cost.

**Determinism (FR-222).** Records depend only on the pixels. The same inputs from the same
saved moment give the same pixels in mGBA, so they give the same records. Frame numbers come
from the fork's counter, which `reset` and `load` set the way joypad-mcp already counts.

**Prerequisite.** mGBA's OpenGL renderer (`hwaccelVideo`) keeps frames on the GPU:
`CoreController::getPixels` needs an `Interrupter` then. joypad-mcp should start mgba-r
with `-C hwaccelVideo=0`, which is mGBA's default. Step 6 checks this.

## Waits

- A wait is checked **by joypad-mcp, after each frame inside a request.**
- Each `run 1` reply already carries the frame's `h` and `m`. A memory condition is one
  `read` at the same parked frame end.
- The wait therefore ends at the first frame end where the condition holds, or at the
  step's frame limit, exactly. It depends only on the game's state at that frame, so it
  replays identically (FR-220, FR-222, SC-211).
- Without a wait condition, joypad-mcp sends `run <keys> <n>` and saves the round trips.
- The cost is about one loopback round trip per frame. That is small next to a frame:
  Feature 001 measured 60 one-frame requests in 0.98 s at real speed.
- RetroArch's MCP server has a `RUN_UNTIL addr cond val`. A fork-side `run ... until` would
  only matter at fast-forward; it is listed as a later option, not built now.

## Area pictures

- An area of the screen: joypad-mcp asks for `screenshot` (153,600 raw bytes, about 40 µs
  over loopback) and crops it.
- Only what changed: joypad-mcp compares with its own copy of the agent's last picture, using
  the OR of the change masks since then. If nothing changed, it answers with text instead of
  a picture (FR-221).
- For windows, `picture` returns the whole window and joypad-mcp crops.
- The fork needs no area code at all.

---

## Prior art

| Source | Licence | Transport, framing | Exact frames, pause | Security, versioning | What to borrow |
|---|---|---|---|---|---|
| mGBA scripting socket (`src/script/socket.c`, `lua.c` `_socketLuaSource`) | MPL 2.0 | Lua TCP, polled in the `frame` callback | nothing served while paused | `bind` with no address binds all interfaces (`_mScriptSocketOpen`) | (pitfall) serve outside the frame callback |
| mGBA GDB stub (`src/debugger/gdb-stub.c`) | MPL 2.0 | TCP, polled on the emulation thread; blocks with a timeout while paused (`_gdbStubWait`) | answers while paused | the CLI binds `127.0.0.1`, Qt's `GDBController` `0.0.0.0` | keep answering while paused |
| joypad-mcp `mgba_bridge.lua` | joypad-mcp | lines, `ok`/`err`, mGBA connects out | take/run/release, `keysRead` override | no token, no version | the protocol shape, kept as the base |
| `../GBA/mgba-mcp` `bridge.lua` | ISC (`package.json`) | lines with ids, binds `127.0.0.1:8888` | queued presses per frame, no stepping | `version` returns 3 | per-game layer: `profile.json`, `gen3.js`, `mapgrid.js` (below) |
| `../nds/nds-mcp` with BizHawk | ISC; BizHawk MIT | BizHawk polls an HTTP server once per frame (`comm.httpGet`) | many commands per frame (`MAX_ROUNDS`), nothing while paused | `hello=1` fails stale calls | hello that resets stale state; several commands at one frame boundary |
| BizHawk `--socket_*`, `--mmf` | MIT | length-prefixed messages; named memory-mapped files | — | — | (pitfall) `socketServer*` can hang BizHawk on disconnect |
| RetroArch network commands (`command.c`) | GPL 3, ideas only | UDP 55355, off by default, replies echo the command | `FRAMEADVANCE`, `PAUSE_TOGGLE` | all interfaces, no auth | echoing the command name; `GET_STATUS`, `VERSION` |
| RetroArch MCP server (`network/mcp_server.c`, `docs/mcp-server.md`) | GPL 3, ideas only | HTTP on `127.0.0.1:55357` | `RUN_FRAMES`, `RUN_UNTIL`, `WATCH`; frames capped below the client's timeout | bearer token in constant time, Origin check, 64 KiB request cap | token compared in constant time; size caps; memory watches; a frame cap per request |
| libretro (`retro_run`, `retro_serialize`) | MIT header | in-process | one frame per call; determinism per core | — | already used by joypad-mcp's mode without a window |
| GitHub MCP emulator servers: nikouu/mGBA-http, dmang-dev/mcp-mgba, StealthC/bizhawk-mcp-native, zenitraM/pymgba-mcp, MoerAI/mgba-server, mario-andreschak/mcp-gameboy | MIT or none | Lua sockets (all interfaces), in-process bindings, or HTTP | mostly not frame-exact; bizhawk-mcp-native marshals to the UI thread | mostly no token | MoerAI's frame deltas with back-pressure that drops instead of queueing |

No mGBA fork with a C-level control server turned up in `gh search`. 40Cakes/pokebot-gen3
(libmgba, GPL 3) and xphileby/winuae-mcp-plugin (GPL, binds `0.0.0.0`) are ideas only.

**Pitfalls the plan avoids:**

- servers that stop answering when paused;
- default binds to all interfaces;
- fast-forward through synthetic keys and window-title fps (mgba-mcp `lib/fastforward.js`);
- calls made from the wrong thread;
- requests that run longer than the client's timeout. joypad-mcp already counts in frames;
  prompt 5 should still fix a frame cap per request.

---

## The agent's eyes

| Way to see | Tokens | Exact | General | Where it belongs |
|---|---|---|---|---|
| Full screenshot | highest (the constitution: a 2× screenshot costs more than 1,000 tokens, a state line about 60) | yes | any game | joypad-mcp, from `screenshot`/`picture` |
| Scaled, one area, only the changed area | lower, in proportion to pixels | yes | any game | joypad-mcp (crop, mask) |
| Pixel-derived text view: changed cells, stillness, fingerprint, sprites | tens of tokens | yes, frame-exact | any game, but says *where* and *when*, not *what* | records from the fork, text in joypad-mcp |
| Hardware sprites (OAM, 128 entries) and tile maps (VRAM) | small for sprites; tile maps are large | yes | any GBA game; meaning is game-specific | OAM decoding in joypad-mcp; tile maps left to a game layer |
| Memory watches: registered addresses reported when they change, usable as waits | smallest | yes | needs addresses, so per game | joypad-mcp (registration, reporting, waits); addresses come from the agent or a game layer |
| Per-game state (`../GBA/mgba-mcp`: `games/*/profile.json`, `lib/gen3.js` text and party decoding, `lib/mapgrid.js` collision grid and paths) | small, and the most meaningful | yes | one game family | a game layer on top of joypad-mcp (Feature 002's ground), never the fork |

**Recommendation.**

- **The fork** gives only what needs to be inside the program: exact frames, pixels, memory,
  and the per-frame record.
- **joypad-mcp** owns everything generic: the text view, waits, area pictures, OAM sprites
  and memory watches.
- **A game layer** owns meaning: text, party, maps.

**Memory watches belong in the spec.** They are the cheapest exact signal. FireRed's
measurements show that a generic "screen still" rarely fires (R19: the picture changed on 191
to 227 of 240 frames). joypad-mcp checks watches after each frame inside a request, and at
`take` for the time in between ("changed since the last look"). A per-frame sample between
requests would need a fork-side watch list added to the record; that is the "later" step in
the work order.

---

## The live view's transport

**Options:**

- frames over the socket;
- a shared-memory ring of frames (`QSharedMemory`, a POSIX `shm_open` segment, or a memfd);
- a pipe;
- Qt's own mechanisms (`QLocalSocket`, D-Bus);
- records only over the socket, with pictures on request.

**Measured** on this machine (Intel i5-1135G7, 8 threads, Python 3.14 consumer, 153,600-byte
frames, 3,000 frames, best of three; the benchmark is in the session scratchpad, not in the
repository):

| Transport | Per frame, received in Python | Ceiling |
|---|---|---|
| pipe | 42 µs | 23,700 fps |
| Unix socket (abstract) | 30 µs | 33,000 fps |
| TCP loopback | 41 µs | 24,500 fps |
| shared-memory ring, 8 slots | 8.6 µs to write; an unthrottled writer overran the Python reader, which kept 15 of 3,000 frames | — |
| fork-side record in C (copy, hash, 150-cell mask) | 32 µs | — |
| joypad-mcp-side analysis in Python: hash / 8×8 grid | 169 µs / 355 µs | about 1,900 fps |

**What the numbers say.**

- Any transport carries 60 fps (9.2 MB/s) easily. Even 1,300 fps (200 MB/s) fits.
- The bottleneck is Python analysing every frame, not moving it.
- Shared memory is cheapest to write, but it needs its own skip and consistency protocol,
  a segment name to pass and clean up, and per-platform code. It saves nothing once
  only records travel.

**The decision.** A second TCP loopback connection carrying records: about 80 bytes per frame,
5 KB/s at 60 fps, about 100 KB/s at 1,300 fps.

- It is the same mechanism and the same token check as the control channel.
- It works on any platform Qt runs on.
- It leaves no file behind (FR-211).

Pictures travel as replies on the control channel. A Unix socket would be about 25% cheaper
per byte. FR-213 says "loopback address" and joypad-mcp already uses TCP, so TCP stays.
Prompt 5 may revisit this for both forks.

---

## Approaches considered

| Decision | Options | Evidence | Choice | Why |
|---|---|---|---|---|
| Where the commands live | (a) extend Lua and keep the bridge; (a′) also make Lua sockets poll while paused; (b) built-in server in the Qt frontend; (c) a C server in `src/core` usable by the SDL frontend too; (d) the GDB stub or debugger as a channel | Lua sockets polled only in `frame` (`lua.c`); `--script` skipped with autorun and only after start (`Window::setController`); the UI↔emulation deadlock (`mCoreThreadInterrupt`); no frontend bindings; windows and actions exist only in Qt; GDB speaks only memory and registers | (b) | Smallest upstream diff (4 files, about 15 lines); answers while paused and in dialogs; no new race. (a′) touches `lua.c` and still lacks windows; (c) cannot reach Qt windows or actions; (d) has no windows, keys or actions |
| Holding the game | block in the frame callback (the bridge); the owner's pause (`REQ_PAUSE`); `frameAdvance`/`m_moreFrames`; the core-set pause (`REQ_WAIT`) | `thread.c` state machine; `CoreController::setPaused`, `GBAApp::continueAll`; `lockstep.c` is the only user of `REQ_WAIT` | `REQ_WAIT` from a fork `videoFrameEnded` callback | Stops exactly at the frame's end, independent of the owner's pause, keeps the UI responsive |
| Control transport | fork connects to joypad-mcp's TCP port; fork listens (TCP or `QLocalServer`); stdin/stdout; D-Bus | `mgba_app.py` already listens and accepts; prior art binding all interfaces; FR-213 "loopback address"; stdout carries mGBA's log | fork as client, TCP loopback, token | Nothing can connect to the fork; reuses joypad-mcp's code; portable |
| Handshake | env token; command-line option; none | `ConfigController` argument parsing is upstream code; `/proc/<pid>/environ` is private to the user | `JOYPAD_REMOTE=<port>:<token>`, removed from the environment at start | No upstream parser change; stock without it |
| Version | `--version` text; greeting fields; a separate file | `version()` in `src/feature/commandline.c` prints `projectVersion (gitCommit)` only; CI computes `merge-base` already | greeting and `version` with `protocol`, `fork`, `upstream` | One place, checked before any request |
| Window list | `QApplication::topLevelWidgets`; platform window ids; compositor APIs (KWin scripting, R19) | Wayland gives no global ids or positions; in-process lists everything Qt draws | `topLevelWidgets`, with ids per widget | Desktop-independent |
| Window picture | `QWidget::grab` plus a composited game frame; force the software display; `QScreen::grabWindow`; KWin `ScreenShot2` or a portal | `DisplayGL` is a native GL window drawn on its own thread; Qt docs point GL content to `grabFramebuffer`; `grabWindow` does not work on Wayland; KWin only on KDE | `grab` plus `getPixels` painted with `clampSize` | No desktop dependency; leaves the owner's display driver alone |
| Keys | `sendEvent` to the focus widget; `QTest` helpers; XSendEvent; uinput or portal | uinput and the portal type into the focused window (R19); `QTest` adds a library | `sendEvent` plus shortcut-to-action mapping | No focus change; shortcuts work, which Feature 001's could not |
| File dialogs | `Qt::AA_DontUseNativeDialogs`; `DontUseNativeDialog` at the 4 call sites; leave them native | Qt docs: the attribute "must be set before QGuiApplication is constructed"; portal dialogs are out of process | the attribute, in `main.cpp`, only when started by joypad-mcp | One hook, no change in `GBAApp.cpp` |
| Focus | `WA_ShowWithoutActivating` on windows opened for the agent; nothing | Qt 6.8 Wayland requests activation on show unless the attribute is set | the attribute, while agent calls run | SC-207, SC-212 |
| Fast-forward | held Tab; the `fastForward` action; direct `forceFastForward` plus ratio | `Window::setupMenu`, `CoreController::updateFastForward`, `_lookupValue` | direct, with the speed through mGBA's own option; released at load and disconnect | Exact control, no key state |
| Action list | a new "list all" method; walk `menuItems()` through an accessor; read the `QMenuBar`'s `QAction`s | `ActionMapper::menuItems` is public; `QAction`s carry only visible, translated names | `Window::actions()` plus the `menuItems` walk | Stable internal names, one-line upstream change |
| Refusals | refuse in the fork; refuse in joypad-mcp | Only the fork sees keys that map to actions | a fork-side table (above); joypad-mcp may refuse more | One rule for actions and shortcuts |
| Live view | frames over the socket; a shared-memory ring; a pipe; records only | benchmark above; Python analysis cost | records over a second socket, pictures on request | Never slows the game, skips are counted, no files |
| What the fork computes | nothing; hash and mask; the whole text view | 32 µs in C vs 524 µs in Python; spec: keep the fork small | hash and change mask only | Keeps up at fast-forward; the text stays in joypad-mcp, shared with the mode without a window |
| Sprites | fork decodes OAM; joypad-mcp decodes OAM | OAM is a memory region (`oam`, 1 KiB, `src/gba/core.c` memory blocks) in both modes | joypad-mcp | One decoder for both modes |
| Waits | joypad-mcp after each frame; a fork `run ... until` | round trip much shorter than a frame; RetroArch `RUN_UNTIL` | joypad-mcp | Exact, deterministic, no fork code |
| Saved-moment format | PNG (flags 11); raw (flags 10) | `mCoreSaveStateNamed`, `mCoreExtractState`, `retro_serialize` | raw by default, both accepted | Matches the mode without a window |
| Headless Wayland tests | `offscreen` only; weston headless; `kwin_wayland --virtual` | in-process windows work offscreen; SC-207 needs a real Wayland session | offscreen for most tests; weston headless in CI, kwin `--virtual` locally | Proves no X11 without showing anything |
| Upstream commit in the build | `merge-base` at configure time; a CI variable; a tracked file | `build-linux.yml` step `src` already outputs `upstream` | CI variable, `merge-base` as the fallback | No new file to keep in sync |

---

## Spec changes to propose

For the owner to make in `specs/003-nds-host/spec.md`; this plan changes nothing there.

1. **Assumptions, the forks' commands.** Confirmed: mgba-r has the commands built in and
   needs no Lua script. Add that mgba-r is the client of a loopback connection joypad-mcp
   opens, with a one-time token from the environment.
2. **FR-213.** Name the token. A fork with no token runs as the stock program, and nothing
   listens on any port.
3. **FR-214.** A key that is a menu shortcut triggers the action. The agent's keys to a file
   dialog are refused except Escape (if the owner agrees).
4. **FR-216.** Name the `protocol`, `fork` and `upstream` fields, and that status shows them.
5. **FR-218.** The live view carries a per-frame record (frame, hash, change mask), not
   frames. Pictures are taken on request. Name the 16×16 cell and the hash, so the mode
   without a window computes the same thing.
6. **User Story 6, scenario 6.**
   - Saved moments are the raw format with save data and clock in every mode.
   - Compatibility also needs the same BIOS setting.
   - The window backend's flags change from 11 to 10.
7. **A new FR for memory watches.** Registered addresses (1, 2 or 4 bytes), reported when
   they changed since the agent's last look, and usable as wait conditions (FR-220 already
   has the condition form).
8. **Edge Cases.** Owner menu actions during a request run between two agent frames.
   `status` reports `focus`.
9. **Testing.** SC-206's window tests need fork versions that run offscreen; SC-207 runs
   under a headless Wayland compositor.
10. **Naming.** The spec says `screenshot`; the bridge says `shot`. The protocol uses
    `screenshot`, with `shot` kept as an alias. The greeting (`ok hello`) should appear in the
    spec or in prompt 5's `PROTOCOL.md`.
11. **FR-211.** joypad-mcp sets the fork's working directory to the game folder, because of
    mGBA's `portable.ini` lookup in the current directory.

Already true today, and worth noting in the spec:

- The bridge has no token and no version check (FR-213 and FR-216 are new work), and mGBA is
  the client.
- joypad-mcp passes no config folder, so mGBA writes `~/.config/mgba/qt.ini` (FR-211's
  existing exception).

---

## Decisions (2026-11-27)

The owner answered the plan's open questions on 2026-11-27. Each answer is the plan's
recommendation, except decision 10, which had none.

| # | Question | Decision | What it means for the build |
|---|---|---|---|
| 1 | Focus at load | The game window opens **without taking focus** when joypad-mcp starts mgba-r | `WA_ShowWithoutActivating` on the main window too; the owner clicks the window to play. A copy started by hand takes focus as stock mGBA does |
| 2 | Fast-forward speed | **Put the owner's `fastForwardRatio` back** when joypad-mcp disconnects | Read at hello, restored on disconnect (section 3) |
| 3 | Settings folder | **Keep sharing `~/.config/mgba`** (FR-015) | The agent is refused the `settings` action. Accepted risk: if the owner presses OK in Settings during a session, joypad-mcp's `-C` folder paths can be saved into `config.ini` (stock behaviour) |
| 4 | BIOS for saved moments | **The built-in BIOS in both modes** | joypad-mcp passes `-C useBios=0` to the window and keeps the libretro core on its built-in BIOS. No visible change: the owner has no GBA BIOS file set |
| 5 | Keys to file dialogs | **Refused, except Escape** | The agent can only close a file dialog (FR-217) |
| 6 | Game actions for the agent | **Refused**: `reset`, `frameAdvance`, `loadState`, `quickLoad.*`, rewind | The agent uses joypad-mcp's own `reset`, `step` and saved moments, so frame counts stay exact |
| 7 | Owner's menu actions during a request | **Leave as today**: they run between two agent frames | No hook in `Window::addGameAction`; `status` reports it (spec Edge Cases) |
| 8 | Memory watches | **A new FR in the spec**; fork-side per-frame sampling deferred | joypad-mcp checks watches per request; the fork's sampling stays in the work order's "later" row |
| 9 | Headless Wayland CI | **On every push to `remote`** | A weston job beside `build-linux.yml` proves SC-207 on each build |
| 10 | Upstream | **The fork's copy is enough**; nothing set aside | No piece is marked for upstream; upstream is not contacted |

Not asked separately, and still the plan's proposal: `-C hwaccelVideo=0` for the runs
joypad-mcp starts, for the live view ([The live view](#the-live-view), "Prerequisite"). The
owner's own setting is `hwaccelVideo=1`, and the override applies only to the runs
joypad-mcp starts. To confirm when the live view is built (work order step 6).
