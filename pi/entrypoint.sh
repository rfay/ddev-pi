#!/usr/bin/env bash
#ddev-generated
set -e

# Verify the .pi configuration directory exists
if [ ! -d "${HOME}/.pi" ]; then
  echo "Error: .pi directory missing or not properly initialized."
  exit 1
fi

# Ensure keybindings.json is initialized and app.suspend is disabled
KEYBINDINGS_FILE="${HOME}/.pi/agent/keybindings.json"
mkdir -p "${HOME}/.pi/agent"
node -e "
const fs = require('fs');
const path = '${KEYBINDINGS_FILE}';
try {
  let data = {};
  try {
    data = JSON.parse(fs.readFileSync(path, 'utf8'));
  } catch (e) {}
  if (data['app.suspend'] !== '') {
    data['app.suspend'] = '';
    fs.writeFileSync(path, JSON.stringify(data, null, 2) + '\n');
  }
} catch (e) {}
"

# Ensure settings.json is initialized with npmCommand pointing to /usr/bin/npm
# TODO: Re-evaluate or remove this fallback once 1.0.0 stable is released.
SETTINGS_FILE="${HOME}/.pi/agent/settings.json"
node -e "
const fs = require('fs');
const path = '${SETTINGS_FILE}';
try {
  let data = {};
  try {
    data = JSON.parse(fs.readFileSync(path, 'utf8'));
  } catch (e) {}
  if (!Array.isArray(data.npmCommand)) {
    data.npmCommand = ['/usr/bin/npm'];
    fs.writeFileSync(path, JSON.stringify(data, null, 2) + '\n');
  }
} catch (e) {}
"

# Ensure pi wrapper script disables terminal suspension on invocation
mkdir -p "${HOME}/.pi/agent/bin"
cat <<'EOF' > "${HOME}/.pi/agent/bin/pi"
#!/usr/bin/env bash
stty susp undef 2>/dev/null || true
exec /home/pi/.npm-global/bin/pi "$@"
EOF
chmod +x "${HOME}/.pi/agent/bin/pi"

# Setup SSH connectivity to DDEV web container
SSH_KEY_DIR="/var/www/html/.ddev/.agent-ssh-keys"

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

# SSH client: copy private key for connecting to web
cp "$SSH_KEY_DIR/id_ed25519" "${HOME}/.ssh/ddev_agent_key" 2>/dev/null || true
chmod 600 "${HOME}/.ssh/ddev_agent_key" 2>/dev/null || true

# Wait for web-user file (web container writes it on startup, max 15s)
for i in $(seq 1 15); do
  [ -f "$SSH_KEY_DIR/web-user" ] && break
  sleep 1
done
WEB_USER=$(cat "$SSH_KEY_DIR/web-user" 2>/dev/null || echo "ddev")

# Patch ssh config with the detected username, but only once
if ! sed -n '/^Host web$/,/^Host /p' "${HOME}/.ssh/config" 2>/dev/null | grep -q "^    User "; then
  sed -i "/^Host web$/a\\    User $WEB_USER" "${HOME}/.ssh/config" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# entrypoint.d/ hooks
# Scripts placed in ${HOME}/.entrypoint.d are executed in lexicographic order.
# Naming convention mirrors build.d/: 00-09 core, 10-49 infrastructure,
# 50-89 tools, 90-99 overrides.
# A failing hook emits a warning and does NOT crash the container.
# ---------------------------------------------------------------------------
ENTRYPOINT_D="${HOME}/.entrypoint.d"
if [ -d "${ENTRYPOINT_D}" ]; then
  # Use find + sort to guarantee lexicographic order across all shells.
  while IFS= read -r hook; do
    [ -f "${hook}" ] || continue
    [ -x "${hook}" ] || continue
    echo "[entrypoint.d] Running $(basename "${hook}")"
    if ! "${hook}"; then
      echo "[entrypoint.d] WARNING: $(basename "${hook}") exited with a non-zero status. Continuing." >&2
    fi
  done < <(find "${ENTRYPOINT_D}" -maxdepth 1 -type f -name '*.sh' | sort)
fi

# Signal that container initialization and all entrypoint hooks are complete
touch /tmp/.entrypoint_finished
echo "[entrypoint] Pi sidecar initialization complete."

# Trap signals for graceful shutdown
trap 'echo "Shutting down Pi Workspace..."; exit 0' TERM INT

exec tail -f /dev/null
