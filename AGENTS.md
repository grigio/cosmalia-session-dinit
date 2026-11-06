# Dinit Usage Notes for Cosmalia Session

## Service Description Format

Dinit uses **single files** in `/etc/dinit.d/user/` (or `$XDG_CONFIG_HOME/dinit.d/`) — NOT directories with `start/dependencies/type` files.

Each service file is a plain-text key-value format:
```
property = value
property += value-addendum   # additive for some properties
# comment
```

## Key Learnings from Debugging

### 1. dinitctl environment propagation
- `dinitctl --user import-environment` **does not exist** in dinitctl
- Use `dinitctl --user setenv VAR=value ...` instead
- Always propagate `WAYLAND_DISPLAY`, `XDG_CURRENT_DESKTOP`, `XDG_SESSION_TYPE`, `XDG_SESSION_DESKTOP`, `XDG_RUNTIME_DIR`, `PATH` to user dinit after compositor starts

### 2. Graphical target dependency
- Turnstiled provides `graphical.target` but may not be running in minimal setups
- **Don't depend on `graphical.target`** unless turnstiled is guaranteed
- Session launcher should manage its own target (`cosmalia-session.target`)

### 3. Compositor + shell ordering
- `cosmic-comp` must start first and create Wayland socket
- Shell (`noctalia`) needs `WAYLAND_DISPLAY` env var to connect
- Launcher script should: start compositor → find socket → set env → start dinit target

### 4. Greetd greeters
- `cosmic-greeter` requires `cosmic-comp` (runs as `cosmic-greeter-start`)
- `regreet`/`tuigreet` are GTK/Wayland apps - **need compositor**, don't work bare
- `agreety` is framebuffer TUI - works without compositor, proper greetd greeter
- Use `agreety --cmd /usr/bin/cosmalia-session` for simple default session

### 5. DRM device conflicts
- Two DRM compositors can't share GPU simultaneously
- Stop greetd/greeter before testing session manually
- `cosmic-greeter` holds GPU on VT1; session fails with "Permission denied" on `/dev/dri/card*`

### 6. Service reload after package upgrade
- User dinit may cache old service definitions
- Always run `dinitctl --user reload <service>` in launcher after socket found
- Then `dinitctl --user start cosmalia-session.target`

## Service Types

| Type | Description |
|------|-------------|
| `process` | Single supervised process (start/stop with service) |
| `bgprocess` | Daemonizing process that writes PID file |
| `scripted` | Started/stopped by executing commands |
| `internal` | No external process; for grouping via dependencies |
| `triggered` | Like internal but waits for external trigger |

## Dependency Properties

| Property | Behavior | systemd equivalent |
|----------|----------|-------------------|
| `depends-on: svc` | Hard dep: start svc first, stop dependent if svc stops | `Requires=` + `After=` |
| `depends-ms: svc` | Milestone: start svc first, but stop doesn't affect dependent | `Wants=` + `After=` |
| `waits-for: svc` | Wait for svc to start/fail, but don't require it | `After=` (weak) |
| `after: svc` | Ordering only: if svc is starting, wait for it; no dep implied | `After=` (no Requires) |

**Key distinction**: `depends-on` is bidirectional (stop cascade), `depends-ms` is start-only.

**Cycles are rejected at load time** — `dinit-check` / `dinitctl reload` fail fast if a cycle exists (e.g. `A → depends-ms: B` and `B → depends-on: A`).

## Target Pattern (like systemd `.target`)

Use `type = internal` for targets. They don't run commands — they only express dependencies.

```ini
# cosmalia-session.target
type = internal
depends-on: graphical.target     # like BindsTo=
depends-ms: noctalia                     # like Wants=
depends-ms: cosmic-settings-daemon
```

## Service Pattern (like systemd `.service`)

```ini
# noctalia
type = process
command = /usr/bin/noctalia
after: cosmic-settings-daemon            # ordering
restart = on-failure
restart-delay = 1
stop-timeout = 5
```

Do **not** add `depends-on: cosmalia-session.target` to the service. The target already
has `depends-ms` on it, and dinit refuses to load the loop (`has cyclic dependency`),
so `dinitctl --user start cosmalia-session.target` fails and nothing starts. A service
that is only running as a dependency of the target is stopped when the target stops, so
no back-dependency is needed for the `PartOf=` behaviour.

## User Instance Paths

Default user service directories (in order):
1. `$XDG_CONFIG_HOME/dinit.d`
2. `$HOME/.config/dinit.d`
3. `/etc/dinit.d/user`
4. `/usr/lib/dinit.d/user`
5. `/usr/local/lib/dinit.d/user`

Package installs to `/etc/dinit.d/user/`.

## dinitctl Commands

| Command | Description |
|---------|-------------|
| `dinitctl --user start <svc>` | Start service + deps |
| `dinitctl --user stop <svc>` | Stop service + dependents |
| `dinitctl --user restart <svc>` | Restart service |
| `dinitctl --user reload <svc>` | Reload service description |
| `dinitctl --user verify <svc>` | Verify service resolves |
| `dinitctl --user setenv VAR=value ...` | Set environment variables |
| `dinitctl --user is-active <svc>` | Check if active |
| `dinitctl --user catlog <svc>` | Dump service log buffer (no `-f` follow) |
| `dinitctl --user status <svc>` | Show service state + PID |
| `dinitctl --user list` | List all loaded services |
| `dinitctl --user shutdown` | Stop all services + exit dinit |

## Cosmalia Session Mapping

| systemd | dinit |
|---------|-------|
| `cosmalia-session.target` (BindsTo=graphical.target) | `type=internal` + `depends-on: graphical.target` |
| `Wants=noctalia.service` | `depends-ms: noctalia` |
| `PartOf=cosmalia-session.target` | nothing: started via the target's `depends-ms`, stopped when the target stops (a back-dependency is a cycle) |
| `Restart=on-failure` | `restart = on-failure` |
| `After=` | `after:` or `depends-on:` |
| `systemctl --user daemon-reload` | `dinitctl --user reload` |
| `systemctl --user is-active` | `dinitctl --user is-active` |

## Environment Propagation

```sh
# In session launcher, after compositor socket found:
dbus-update-activation-environment \
    WAYLAND_DISPLAY XDG_CURRENT_DESKTOP ...
dinitctl --user setenv \
    WAYLAND_DISPLAY XDG_CURRENT_DESKTOP ...
```

> **Note:** `dbus-update-activation-environment` without `--systemd` works for both systemd and dinit user sessions (it uses the DBUS_SESSION_BUS_ADDRESS).

## Restart Behavior

- `restart = on-failure` only restarts on non-zero exit or signal (not SIGHUP/SIGINT/SIGUSR1/SIGUSR2/SIGTERM)
- `smooth-recovery = yes` restarts process without stopping dependents or changing service state
- `restart-limit-count = 3` / `restart-limit-interval = 10` (default) limits restart loops
- `restart = always` restarts on any exit (including clean stop via `dinitctl stop`)
- Use `restart-delay` to add backoff between restarts

## File Permissions

Service files should be `644`. The `command` is executed as the user running the user instance.