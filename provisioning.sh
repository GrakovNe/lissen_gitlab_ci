#!/usr/bin/env bash
#
# Provisions a bare Ubuntu host into a GitLab shell runner capable of running
# everything in lissen/.gitlab-ci.yml (Android SDK bootstrap, headless
# emulator via KVM, gradle/JDK 21, and the GitHub release step).
#
# Run as root on the target host:
#   GITLAB_URL=https://gitlab.example.com \
#   RUNNER_TOKEN=glrt-xxxxxxxxxxxxxxxxxxxx \
#   ./provision.sh
#
# RUNNER_TOKEN is a runner authentication token: GitLab UI ->
# Settings > CI/CD > Runners > "New project runner" (tag: android, shell executor).
#
# What this does NOT do (out of scope / must be done elsewhere):
#   - GitLab CI/CD variables (KEYSTORE_BASE64, KEYSTORE_PASSWORD, KEY_ALIAS,
#     KEY_PASSWORD, GITHUB_TOKEN) must be set in the GitLab project's
#     Settings > CI/CD > Variables (masked + protected), not on this host.
#   - If this host is itself an LXC container (as the original runner is,
#     per the comments in .gitlab-ci.yml), /dev/kvm must be passed through
#     from the Proxmox host first: lxc.cgroup2.devices.allow + a bind mount
#     of /dev/kvm in the container config, plus the container running
#     privileged or with the kvm device explicitly allowed. This script only
#     checks that /dev/kvm is visible and usable, it cannot create it.

set -euo pipefail

GITLAB_URL="${GITLAB_URL:?set GITLAB_URL, e.g. https://gitlab.example.com}"
RUNNER_TOKEN="${RUNNER_TOKEN:?set RUNNER_TOKEN, the runner authentication token from the GitLab UI}"
RUNNER_TAG="${RUNNER_TAG:-android}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)-android}"
CONCURRENT="${CONCURRENT:-1}"
RUNNER_USER="gitlab-runner"
BUILD_DIR="/build"
SDK_DIR="/opt/android-sdk"
MIN_FREE_GB=60

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this as root." >&2
  exit 1
fi

if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
  echo "Warning: this script targets Ubuntu; proceeding anyway." >&2
fi

echo "==> Installing base packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  ca-certificates curl wget unzip git gnupg sudo qemu-kvm

echo "==> Installing JDK 21 (required by gradle/AGP; not installed by the CI script itself)"
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openjdk-21-jdk-headless; then
  echo "openjdk-21-jdk-headless not in apt sources, falling back to Adoptium Temurin repo"
  curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
    | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg
  echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(awk -F= '/^VERSION_CODENAME/{print $2}' /etc/os-release) main" \
    > /etc/apt/sources.list.d/adoptium.list
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq temurin-21-jdk
fi

echo "==> Checking KVM availability (needed for the headless emulator's -accel auto)"
if [ -e /dev/kvm ]; then
  echo "/dev/kvm present"
else
  echo "WARNING: /dev/kvm not found. The instrumented-test job will fall back to" >&2
  echo "software emulation and likely blow the 600s boot timeout. If this host is" >&2
  echo "an LXC guest, pass /dev/kvm through from the Proxmox host first." >&2
fi

echo "==> Installing gitlab-runner"
if ! command -v gitlab-runner >/dev/null 2>&1; then
  curl -fsSL "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | bash
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gitlab-runner
fi

echo "==> Granting gitlab-runner access to /dev/kvm"
getent group kvm >/dev/null || groupadd kvm
usermod -aG kvm "$RUNNER_USER"

echo "==> Configuring passwordless sudo for $RUNNER_USER"
# The CI jobs run arbitrary `sudo apt-get install <whatever this job needs>`,
# so scoping this to a fixed command list would break on the next dependency
# bump. Trust boundary here is "anyone who can push to this CI config / this
# GitHub repo can run anything as root on this box" -- same as the existing
# runner.
cat > /etc/sudoers.d/gitlab-runner <<EOF
$RUNNER_USER ALL=(ALL) NOPASSWD: ALL
EOF
chmod 440 /etc/sudoers.d/gitlab-runner
visudo -c -f /etc/sudoers.d/gitlab-runner

echo "==> Pre-creating build/SDK directories"
mkdir -p "$BUILD_DIR" "$SDK_DIR"
chown -R "$RUNNER_USER:$RUNNER_USER" "$BUILD_DIR" "$SDK_DIR"

echo "==> Checking free disk space"
FREE_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [ "$FREE_GB" -lt "$MIN_FREE_GB" ]; then
  echo "WARNING: only ${FREE_GB}G free on /. Android SDK + system image + gradle caches" >&2
  echo "comfortably exceed that; recommend at least ${MIN_FREE_GB}G." >&2
fi

echo "==> Registering runner"
if grep -q "name = \"$RUNNER_NAME\"" /etc/gitlab-runner/config.toml 2>/dev/null; then
  echo "Runner '$RUNNER_NAME' already registered, skipping"
else
  gitlab-runner register \
    --non-interactive \
    --url "$GITLAB_URL" \
    --token "$RUNNER_TOKEN" \
    --executor shell \
    --tag-list "$RUNNER_TAG" \
    --description "$RUNNER_NAME" \
    --run-untagged="false" \
    --locked="false"
fi

echo "==> Setting concurrency to $CONCURRENT (emulator/KVM contention makes >1 risky)"
sed -i "s/^concurrent = .*/concurrent = $CONCURRENT/" /etc/gitlab-runner/config.toml

echo "==> Enabling gitlab-runner service"
systemctl enable --now gitlab-runner

cat <<EOF

Done. Remaining manual steps:
  1. In the GitLab project, set these CI/CD variables (masked + protected):
       KEYSTORE_BASE64, KEYSTORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD, GITHUB_TOKEN
  2. Confirm outbound network access from this host to:
       github.com, api.github.com, dl.google.com, services.gradle.org,
       repo.maven.apache.org, dl.google.com/android maven, and $GITLAB_URL
  3. If /dev/kvm was missing above, fix passthrough at the Proxmox host level,
     then re-run this script (it's idempotent) or just: usermod -aG kvm gitlab-runner
     and restart the container.
EOF
