#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
# Bats libraries documentation https://github.com/ztombol/bats-docs

# For local tests, install bats-core, bats-assert, bats-file, bats-support
# And run this in the add-on root directory:
#   bats ./tests/test.bats
# To exclude release tests:
#   bats ./tests/test.bats --filter-tags '!release'
# For debugging:
#   bats ./tests/test.bats --show-output-of-passing-tests --verbose-run --print-output-on-failure

setup() {
  set -eu -o pipefail

  # Override this variable for your add-on:
  export GITHUB_REPO=mxr576/ddev-pi

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p "${HOME}/tmp"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site
  assert_success
  run ddev start -y
  assert_success
}

health_checks() {
  # Do something useful here that verifies the add-on

  # You can check for specific information in headers:
  # run curl -sfI https://${PROJNAME}.ddev.site
  # assert_output --partial "HTTP/2 200"
  # assert_output --partial "test_header"

  # Or check if some command gives expected output:
  DDEV_DEBUG=true run ddev launch
  assert_success
  assert_output --partial "FULLURL https://${PROJNAME}.ddev.site"
}

teardown() {
  set -eu -o pipefail
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1
  # Persist TESTDIR if running inside GitHub Actions. Useful for uploading test result artifacts
  # See example at https://github.com/ddev/github-action-add-on-test#preserving-artifacts
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

@test "install from directory" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}

@test "entrypoint.d: empty directory does not cause errors" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart && ddev start --profiles=pi
  assert_success
  run ddev exec --service pi echo "container is up"
  assert_success
  assert_output --partial "container is up"
}

@test "entrypoint readiness flag is created after startup" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart && ddev start --profiles=pi
  assert_success
  run ddev exec --service pi test -f /tmp/.entrypoint_finished
  assert_success
}

@test "entrypoint.d: hooks run in lexicographic order" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  HOOK_DIR="${TESTDIR}/.ddev/pi/entrypoint.d"
  mkdir -p "${HOOK_DIR}"

  cat > "${HOOK_DIR}/10-first.sh" <<'EOF'
#!/usr/bin/env bash
echo "10-first" >> /tmp/hook-order.log
EOF
  chmod +x "${HOOK_DIR}/10-first.sh"

  cat > "${HOOK_DIR}/50-second.sh" <<'EOF'
#!/usr/bin/env bash
echo "50-second" >> /tmp/hook-order.log
EOF
  chmod +x "${HOOK_DIR}/50-second.sh"

  run ddev restart && ddev start --profiles=pi
  assert_success

  run ddev exec --service pi cat /tmp/hook-order.log
  assert_success
  assert_output --partial "10-first"
  assert_output --partial "50-second"

  # Verify 10-first appears before 50-second in the file.
  run ddev exec --service pi bash -c 'grep -n "10-first" /tmp/hook-order.log | cut -d: -f1'
  assert_success
  FIRST_LINE="${output}"

  run ddev exec --service pi bash -c 'grep -n "50-second" /tmp/hook-order.log | cut -d: -f1'
  assert_success
  SECOND_LINE="${output}"

  [ "${FIRST_LINE}" -lt "${SECOND_LINE}" ]
}

@test "entrypoint.d: failing hook emits warning but container keeps running" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  HOOK_DIR="${TESTDIR}/.ddev/pi/entrypoint.d"
  mkdir -p "${HOOK_DIR}"

  cat > "${HOOK_DIR}/10-failing.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "${HOOK_DIR}/10-failing.sh"

  cat > "${HOOK_DIR}/20-after-failure.sh" <<'EOF'
#!/usr/bin/env bash
echo "still-running" >> /tmp/post-failure.log
EOF
  chmod +x "${HOOK_DIR}/20-after-failure.sh"

  run ddev restart && ddev start --profiles=pi
  assert_success

  # Container must still be reachable.
  run ddev exec --service pi echo "alive"
  assert_success
  assert_output --partial "alive"

  # The hook that follows the failing one must still have run.
  run ddev exec --service pi cat /tmp/post-failure.log
  assert_success
  assert_output --partial "still-running"

  # Verify the warning was emitted in the container logs.
  run ddev logs -s pi
  assert_success
  assert_output --partial "WARNING: 10-failing.sh exited with a non-zero status"
}

@test "entrypoint.d: successful hook produces observable side effects" {
  set -eu -o pipefail
  run ddev add-on get "${DIR}"
  assert_success

  HOOK_DIR="${TESTDIR}/.ddev/pi/entrypoint.d"
  mkdir -p "${HOOK_DIR}"

  cat > "${HOOK_DIR}/50-side-effect.sh" <<'EOF'
#!/usr/bin/env bash
touch /tmp/hook-ran.marker
EOF
  chmod +x "${HOOK_DIR}/50-side-effect.sh"

  run ddev restart && ddev start --profiles=pi
  assert_success

  run ddev exec --service pi test -f /tmp/hook-ran.marker
  assert_success
}

@test "build.d: contributed script installs package into PI container" {
  set -eu -o pipefail
  echo "# Testing build.d/ seam with project ${PROJNAME} in $(pwd)" >&3

  run ddev add-on get "${DIR}"
  assert_success

  # Copy the fixture build script into .ddev/pi/build.d/ so it is picked
  # up when the PI image is (re)built.
  BUILD_D_DIR="${TESTDIR}/.ddev/pi/build.d"
  mkdir -p "${BUILD_D_DIR}"
  cp "${DIR}/tests/testdata/build.d/50-test-package.sh" "${BUILD_D_DIR}/50-test-package.sh"
  chmod +x "${BUILD_D_DIR}/50-test-package.sh"

  run ddev restart && ddev start --profiles=pi
  assert_success

  # The fixture script installs 'tree', which must now be present inside the
  # running PI container.
  run ddev exec --service pi which tree
  assert_success

  run ddev exec --service pi tree --version
  assert_success
}

@test "bashrc.d: contributed script defines alias available in interactive shell" {
  set -eu -o pipefail
  echo "# Testing bashrc.d/ seam with project ${PROJNAME} in $(pwd)" >&3

  run ddev add-on get "${DIR}"
  assert_success

  # Copy the fixture bashrc.d script into .ddev/pi/bashrc.d/ so it is
  # mounted into the container at /home/pi/.bashrc.d and sourced by ~/.bashrc.
  BASHRC_D_DIR="${TESTDIR}/.ddev/pi/bashrc.d"
  mkdir -p "${BASHRC_D_DIR}"
  cp "${DIR}/tests/testdata/bashrc.d/50-test-alias.sh" "${BASHRC_D_DIR}/50-test-alias.sh"
  chmod +x "${BASHRC_D_DIR}/50-test-alias.sh"

  run ddev restart && ddev start --profiles=pi
  assert_success

  # Open an interactive login shell so ~/.bashrc is sourced, then check
  # that the alias defined in the fixture is available.
  run ddev exec --service pi bash -i -c 'type pi-test-alias'
  assert_success
  assert_output --partial "pi-test-alias"
}

@test "entrypoint.d: fixture sentinel script writes marker file on startup" {
  set -eu -o pipefail
  echo "# Testing entrypoint.d/ sentinel fixture with project ${PROJNAME} in $(pwd)" >&3

  run ddev add-on get "${DIR}"
  assert_success

  # Copy the fixture sentinel script into .ddev/pi/entrypoint.d/ so it is
  # mounted and executed by entrypoint.sh on container startup.
  ENTRYPOINT_D_DIR="${TESTDIR}/.ddev/pi/entrypoint.d"
  mkdir -p "${ENTRYPOINT_D_DIR}"
  cp "${DIR}/tests/testdata/entrypoint.d/50-sentinel.sh" "${ENTRYPOINT_D_DIR}/50-sentinel.sh"
  chmod +x "${ENTRYPOINT_D_DIR}/50-sentinel.sh"

  run ddev restart && ddev start --profiles=pi
  assert_success

  # The sentinel file must exist, proving the hook ran during startup.
  run ddev exec --service pi test -f /tmp/entrypoint-sentinel.marker
  assert_success
}

@test "entrypoint.d: failing fixture script does not crash the container" {
  set -eu -o pipefail
  echo "# Testing entrypoint.d/ warning-not-crash behavior with project ${PROJNAME} in $(pwd)" >&3

  run ddev add-on get "${DIR}"
  assert_success

  # Copy the fixture failing script into .ddev/pi/entrypoint.d/.
  ENTRYPOINT_D_DIR="${TESTDIR}/.ddev/pi/entrypoint.d"
  mkdir -p "${ENTRYPOINT_D_DIR}"
  cp "${DIR}/tests/testdata/entrypoint.d/60-failing.sh" "${ENTRYPOINT_D_DIR}/60-failing.sh"
  chmod +x "${ENTRYPOINT_D_DIR}/60-failing.sh"

  run ddev restart && ddev start --profiles=pi
  assert_success

  # The container must still be reachable and healthy despite the failing hook.
  run ddev exec --service pi echo "still-healthy"
  assert_success
  assert_output --partial "still-healthy"

  # Verify the warning was emitted in the container logs.
  run ddev logs -s pi
  assert_success
  assert_output --partial "WARNING: 60-failing.sh exited with a non-zero status"
}

@test "clipboard: container interceptor and host helper work in tandem" {
  set -eu -o pipefail
  echo "# Testing clipboard integration with project ${PROJNAME} in $(pwd)" >&3

  run ddev add-on get "${DIR}"
  assert_success

  run ddev restart && ddev start --profiles=pi
  assert_success

  # 1. Test Container-side Interceptor
  # xclip, xsel, wl-copy should write to the shared volume file bridge.
  run ddev exec --service pi bash -c "echo 'interceptor-test-content' | xclip"
  assert_success

  # Verify the pending file exists and contains the correct data.
  assert_file_exists "${TESTDIR}/.ddev/pi/.clipboard_pending"
  run cat "${TESTDIR}/.ddev/pi/.clipboard_pending"
  assert_output --partial "interceptor-test-content"

  # 2. Test Host-side Python Helper
  # Start the helper on the host pointing to the pending file.
  python3 "${TESTDIR}/.ddev/pi/clipboard-helper.py" "${TESTDIR}/.ddev/pi/.clipboard_pending" > "${TESTDIR}/.ddev/clipboard-test.log" 2>&1 &
  HELPER_PID=$!

  # Wait a moment for the helper to process and delete the file.
  for i in $(seq 1 20); do
    [ ! -f "${TESTDIR}/.ddev/pi/.clipboard_pending" ] && break
    sleep 0.1
  done

  # Terminate helper
  kill "${HELPER_PID}" || true
  wait "${HELPER_PID}" 2>/dev/null || true

  # The pending file should have been deleted by the helper.
  assert_file_not_exists "${TESTDIR}/.ddev/pi/.clipboard_pending"

  # Verify in logs that the helper started and attempted copying.
  run cat "${TESTDIR}/.ddev/clipboard-test.log"
  assert_output --partial "Starting clipboard helper"
}

@test "web toolchain proxies: transparently forward commands to web container" {
  set -eu -o pipefail
  echo "# Testing web toolchain proxy shims with project ${PROJNAME} in $(pwd)" >&3

  run ddev add-on get "${DIR}"
  assert_success

  run ddev restart && ddev start --profiles=pi
  assert_success

  # Verify shims are installed and executable on $PATH
  run ddev exec --service pi which php composer drush phpunit yarn npm
  assert_success

  # Verify direct invocation works and reaches web container
  run ddev exec --service pi php -v
  assert_success
  assert_output --partial "PHP"

  run ddev exec --service pi composer --version
  assert_success
  assert_output --partial "Composer"

  run ddev exec --service pi yarn --version
  assert_success

  run ddev exec --service pi npm --version
  assert_success
}

@test "make: executes targets calling proxied web tools" {
  set -eu -o pipefail
  echo "# Testing make calling proxied web tools with project ${PROJNAME} in $(pwd)" >&3

  run ddev add-on get "${DIR}"
  assert_success

  run ddev restart && ddev start --profiles=pi
  assert_success

  # Verify make is installed in the PI container
  run ddev exec --service pi which make
  assert_success

  # Execute a Makefile target that invokes a proxied tool (php).
  # Under the old bash alias approach, make subshells (/bin/sh) could not resolve
  # bash functions. The /usr/local/bin proxy shim resolves seamlessly.
  run ddev exec --service pi bash -c '
    cat << "EOF" > /var/www/html/Makefile.test
test:
	php -r "echo \"make-proxy-works\n\";"
EOF
    make -f /var/www/html/Makefile.test test
    rm -f /var/www/html/Makefile.test
  '
  assert_success
  assert_output --partial "make-proxy-works"
}

@test "extension management: pi install and list extensions work end-to-end" {
  set -eu -o pipefail
  echo "# Testing extension installation e2e with project ${PROJNAME} in $(pwd)" >&3

  run ddev add-on get "${DIR}"
  assert_success

  run ddev restart && ddev start --profiles=pi
  assert_success

  # Create a local extension fixture inside the project directory
  mkdir -p "${TESTDIR}/pi-test-extension"
  cat << 'EOF' > "${TESTDIR}/pi-test-extension/package.json"
{
  "name": "pi-test-extension",
  "version": "1.0.0",
  "type": "module",
  "main": "index.js"
}
EOF
  cat << 'EOF' > "${TESTDIR}/pi-test-extension/index.js"
export default function (pi) {}
EOF

  # 1. Test global scope install
  run ddev exec --service pi pi install /var/www/html/pi-test-extension
  assert_success

  # Verify extension appears in pi list
  run ddev exec --service pi pi list
  assert_success
  assert_output --partial "pi-test-extension"

  # Clean up global extension
  run ddev exec --service pi pi remove /var/www/html/pi-test-extension
  assert_success

  # 2. Test project scope install (-l)
  run ddev exec --service pi pi install -l /var/www/html/pi-test-extension
  assert_success

  # Verify extension appears in pi list
  run ddev exec --service pi pi list
  assert_success
  assert_output --partial "pi-test-extension"

  # Clean up project extension
  run ddev exec --service pi pi remove -l /var/www/html/pi-test-extension
  assert_success
}


