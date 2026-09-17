# Extending DDEV PI

This document explains the two ways to add functionality to the DDEV PI environment: through Pi's built-in extension management and through the DDEV PI add-on's extensibility seams.

## Managing Pi Extensions

Pi supports two types of extensions:

- **Global extensions:** Install with `ddev pi install <addon-ref>`. These are stored in `.ddev/pi/global/` and are local to your environment. Do not commit this directory to VCS.
- **Project extensions:** Install with `ddev pi install -l <addon-ref>`. These are stored in the project's `.pi/` directory. **Commit this directory to VCS** so that extensions are shared across your team.

To remove extensions, use `ddev pi remove` (global) or `ddev pi remove -l` (project).

## DDEV PI Extensibility Seams

DDEV PI exposes four extensibility seams so addon authors and project maintainers can customize or extend the environment without forking the base addon. Each seam has a different lifecycle, execution context, and activation cost.

### Seam overview

| Seam | Runs as | Activated by | Notes |
|---|---|---|---|
| `build.d/` | `root` (or `pi` via `sudo -u`) | Rebuild | Scripts execute during image build |
| `bashrc.d/` | `pi` (interactive) | Restart | Interactive shell only |
| `entrypoint.d/` | `pi` (with `sudo` available) | Restart | Container startup hooks |
| `global/agent/extensions/` | Pi agent | Restart | Independent command listeners |

### `build.d/` — build-time package installation

Place shell scripts here to install additional packages or make system-level changes during the Docker image build. Scripts run as `root` in lexicographic (sorted) order. Use numeric prefixes to control execution order and to avoid conflicts with existing scripts.

The naming bands are:

- `00–09`: core image setup (reserved)
- `10–49`: runtimes and infrastructure
- `50–89`: tools and utilities
- `90–99`: project-specific overrides

#### Environment Variables in build.d/ Scripts

The execution context of all `build.d/` scripts is pre-populated with several useful environment variables:
- `USERNAME`: The name of the non-root user (defaults to `pi`).
- `USER_HOME`: The home directory path of the non-root user (defaults to `/home/pi`).
- `USER_UID`: The UID of the non-root user (corresponds to the host user's UID to prevent permission issues).
- `USER_GID`: The GID of the non-root user (corresponds to the host user's GID).

If you need to run a step as the `pi` user inside a build script, prefix the command with `sudo -u ${USERNAME}`. For example:
```bash
sudo -u "${USERNAME}" touch "${USER_HOME}/some-file"
```

#### Handling PATH and Non-Interactive Shells

Because Pi commands and background agent tasks (e.g., executing tools/skills) are executed in **non-interactive contexts** (such as via `ddev exec` or direct container process execution), **they do not source `~/.bashrc` or scripts under `bashrc.d/`**.

If your build script installs custom binaries or tools, **do not rely on `bashrc.d/` to modify the `PATH`**. Instead, use one of the following standard approaches:

1. **The Symlink Pattern (Recommended for custom locations):**
   If you install a tool into a custom directory (e.g., `/opt/my-tool`), create a symbolic link to its executable in `/usr/local/bin` (which is always in the system `PATH` for all contexts):
   ```bash
   # Inside a build.d/ script running as root:
   ln -sf /opt/my-tool/bin/my-tool-executable /usr/local/bin/my-tool
   ```

2. **Standard User-space Binaries (Recommended for user-level tools):**
   The static `ENV PATH` configured inside the container's `Dockerfile` includes the following user-space paths:
   - `/home/pi/.npm-global/bin`
   - `/home/pi/.local/bin`
   - `/home/pi/bin`

   Any executables placed in these directories (e.g., via `pip install --user` or manual copies) will be automatically available in all execution contexts:
   ```bash
   # Inside a build.d/ script:
   sudo -u pi mkdir -p /home/pi/.local/bin
   sudo -u pi cp my-binary /home/pi/.local/bin/
   ```

> **Changes to `build.d/` require a full image rebuild** to take effect. Run `ddev debug rebuild -s pi && ddev restart && ddev start --profiles=pi`.

### `bashrc.d/` — interactive shell ergonomics

Place scripts here to customize the interactive shell experience inside the PI container. Scripts are sourced in sorted order whenever a user enters the container (e.g., via `ddev ssh --service=pi`).

This seam is **for interactive shells only**. Scripts placed here do not affect PI's autonomous tool execution or entrypoint hooks.

> **A `ddev restart && ddev start --profiles=pi` is sufficient** to pick up changes. No rebuild is needed.

### `entrypoint.d/` — runtime startup hooks

Place scripts here to run initialization logic on every container startup. Scripts execute as the `pi` user in sorted order. `sudo` is available inside these scripts if you need root-level steps.

Hook failures emit a warning but do not crash the container, so a broken hook will not prevent the PI service from starting.

> **A `ddev restart && ddev start --profiles=pi` is sufficient** to pick up changes. No rebuild is needed.

### `global/agent/extensions/` — PI agent command routing

This directory is a mounted path where the PI agent discovers additional command extension files. Extensions are independent listeners and are not processed as an ordered pipeline, so **numeric prefixes have no effect** here.

To avoid filename collisions with other addons, use an addon-specific prefix in every filename, for example:

```
myaddon-summarize.ts
myaddon-review.ts
```

> **A `ddev restart && ddev start --profiles=pi` is sufficient** to pick up new or updated extensions. No rebuild is needed.

## Web Container Toolchain Proxies (`npm`, `yarn`, `php`, etc.)

To allow the Pi agent to build, test, and interact with your web application, standard CLI development tools (`php`, `composer`, `drush`, `phpunit`, `phpstan`, `phpcs`, `phpcbf`, `yarn`, and `npm`) in the Pi container are configured as proxy shims in `/usr/local/bin/`. These shims forward invocations over a secure SSH bridge to execute directly inside the DDEV `web` container.

### Important for addon authors

Because `/usr/local/bin` takes precedence over `/usr/bin` in `$PATH`:
- **Running plain `npm` or `yarn` executes inside the `web` container** under the `ddev` user.
- Any attempt to access or create `/home/pi` paths via plain `npm` in the `web` container will fail with `EACCES: permission denied, mkdir '/home/pi'`.

### What to use instead

1. **Installing Pi extensions / skills:**
   Use Pi's built-in package manager CLI:
   ```bash
   pi install <addon-ref>     # Global extension (stored in .ddev/pi/global/)
   pi install -l <addon-ref>  # Project extension (stored in .pi/)
   ```
   This add-on configures `"npmCommand": ["/usr/bin/npm"]` in Pi's settings (`settings.json`), ensuring Pi automatically invokes the local container binary for internal package operations.

2. **Container-local npm operations in `build.d/` or `entrypoint.d/` scripts:**
   If your addon startup hook or build script needs to invoke npm locally inside the `pi` container (e.g., installing a tool or dependency into `/home/pi` or the container filesystem):
   ```bash
   # Use /usr/bin/npm explicitly to bypass the web container proxy shim
   /usr/bin/npm install -g <package>
   ```

