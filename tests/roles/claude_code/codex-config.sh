#!/usr/bin/env bash
# The claude_code role makes ~/.codex/config.toml list CLAUDE.md in its
# top-level project_doc_fallback_filenames, touching nothing else, and fails
# loudly where it can't. Each case starts from a config.toml shape, runs the
# role's codex.yml twice, and compares the whole file with what it should be,
# so a step that silently changes nothing shows up as a wrong file.
#
# The role writes into a home directory, so this runs in a throwaway
# ubuntu:24.04 container, never on the host. It needs Docker and uv, takes a
# couple of minutes, and isn't part of tests/run.
# Usage: bash tests/roles/claude_code/codex-config.sh
set -u

if [[ "${1:-}" != --in-container ]]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO="$(cd "$HERE/../../.." && pwd)"
  for c in docker uv; do
    command -v "$c" >/dev/null || { echo "codex-config.sh needs $c on the host" >&2; exit 2; }
  done
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  # Only codex.yml's tasks are under test: link the role without meta/, so its
  # dependencies (node, go, ...) aren't pulled in.
  mkdir -p "$WORK/roles/claude_code"
  for d in defaults files handlers tasks; do ln -s "/srcrole/$d" "$WORK/roles/claude_code/$d"; done
  cat > "$WORK/test.yml" <<'EOF'
- name: Run the claude_code role's codex.yml
  hosts: all
  vars:
    setup_user: tim
    setup_user_home: /home/tim
  tasks:
    - name: Run codex.yml
      ansible.builtin.include_role:
        name: claude_code
        tasks_from: codex.yml
EOF
  exec docker run --rm \
    -v "$REPO":/app:ro -v "$REPO/ansible/roles/claude_code":/srcrole:ro \
    -v "$REPO/tests":/tests:ro -v "$WORK":/work:ro -v "$(command -v uv)":/usr/local/bin/uv:ro \
    ubuntu:24.04 bash /tests/roles/claude_code/codex-config.sh --in-container
fi

# --- inside the container ---------------------------------------------------
source /tests/lib/rows.sh
apt-get update -qq >/dev/null && apt-get install -y -qq ca-certificates acl sudo python3 python3-apt >/dev/null 2>&1
useradd -m -s /bin/bash tim
# codex.yml first asks nvm's codex for its version; a stub skips the npm install.
mkdir -p /home/tim/.nvm/bin /home/tim/.config/zsh/update
printf '#!/bin/sh\necho codex-cli 0.169.0\n' > /home/tim/.nvm/bin/codex && chmod +x /home/tim/.nvm/bin/codex
echo 'export PATH=/home/tim/.nvm/bin:$PATH' > /home/tim/.nvm/nvm.sh
chown -R tim:tim /home/tim
export UV_PROJECT_ENVIRONMENT=/opt/venv ANSIBLE_CONFIG=/app/ansible.cfg ANSIBLE_ROLES_PATH=/work/roles
cd /app/ansible && uv sync -q --project /app --locked

C=/home/tim/.codex/config.toml
play() {
  uv run -q --project /app --locked ansible-playbook -i localhost, -c local /work/test.yml \
    -e ansible_python_interpreter=/usr/bin/python3 "$@" 2>&1
}
recap() { grep -oE 'changed=[0-9]+ .*failed=[0-9]+' <<<"$1"; }
same_file() { cmp -s <(printf '%s' "$1") "$C"; }

# case <label> <starting config.toml, empty for none> <expected file, default: unchanged> [error text]
case_() {
  local label="$1" start="$2" want="${3:-$2}" error="${4:-}" out1 out2
  rm -rf /home/tim/.codex
  if [[ -n "$start" ]]; then
    mkdir -p /home/tim/.codex && printf '%s' "$start" > "$C"
    chown -R tim:tim /home/tim/.codex && chmod 644 "$C"
  fi
  out1="$(play)"; out2="$(play)"
  if [[ -n "$error" ]]; then
    if grep -qF "$error" <<<"$out1" && [[ "$(recap "$out1")" == *failed=1 ]]; then
      pass "$label" "fails with: $error"
    else bad "$label" "fails with: $error" "$(recap "$out1")"; fi
  else
    [[ "$(recap "$out1")" == *failed=0 ]] && pass "$label" "first run succeeds" || bad "$label" "first run succeeds" "$(recap "$out1")"
    [[ "$(recap "$out2")" == changed=0*failed=0 ]] && pass "$label" "second run changes nothing" || bad "$label" "second run changes nothing" "$(recap "$out2")"
  fi
  same_file "$want" && pass "$label" "config.toml is as expected" || bad "$label" "config.toml is as expected" "$(cat "$C" 2>&1)"
}

L='project_doc_fallback_filenames'
case_ "no config" "" "$L = [\"CLAUDE.md\"]"$'\n'
[[ "$(stat -c %a /home/tim/.codex)" == 700 ]] && pass "no config" "~/.codex is 0700" || bad "no config" "~/.codex is 0700" "$(stat -c %a /home/tim/.codex)"
[[ "$(stat -c %a "$C")" == 600 ]] && pass "no config" "config.toml is 0600" || bad "no config" "config.toml is 0600" "$(stat -c %a "$C")"

case_ "no key, tables after" \
  $'model = "m"\n\n[projects."/x"]\ntrust_level = "trusted"\n' \
  "$L = [\"CLAUDE.md\"]"$'\nmodel = "m"\n\n[projects."/x"]\ntrust_level = "trusted"\n'
case_ "key only inside a table" \
  "[profiles.p]"$'\n'"$L = [\"X.md\"]"$'\n' \
  "$L = [\"CLAUDE.md\"]"$'\n'"[profiles.p]"$'\n'"$L = [\"X.md\"]"$'\n'
case_ "list without CLAUDE.md, tables after" \
  "$L = [\"AGENTS.md\", \"README.md\"]"$'\n[projects."/a"]\ntrust_level = "trusted"\n' \
  "$L = [\"AGENTS.md\", \"README.md\", \"CLAUDE.md\"]"$'\n[projects."/a"]\ntrust_level = "trusted"\n'
case_ "empty list with a comment, no table" \
  "$L = [] # mine"$'\nmodel = "m"\n' \
  "$L = [\"CLAUDE.md\"] # mine"$'\nmodel = "m"\n'
case_ "trailing comma, no table" \
  "$L = [\"A.md\",]"$'\n' \
  "$L = [\"A.md\", \"CLAUDE.md\"]"$'\n'
case_ "same key also inside a table" \
  "$L = [\"A.md\"]"$'\n'"[profiles.p]"$'\n'"$L = [\"A.md\"]"$'\n' \
  "$L = [\"A.md\", \"CLAUDE.md\"]"$'\n'"[profiles.p]"$'\n'"$L = [\"A.md\"]"$'\n'
case_ "already lists CLAUDE.md" "$L = [\"CLAUDE.md\", \"A.md\"]"$'\n'
[[ "$(stat -c %a "$C")" == 644 ]] && pass "already lists CLAUDE.md" "mode left at 0644" || bad "already lists CLAUDE.md" "mode left at 0644" "$(stat -c %a "$C")"
case_ "multi-line list" "$L = ["$'\n  "A.md",\n]\n' "" 'Add "CLAUDE.md" to it by hand'

# --check must report the change without making it, and the "must change" guard
# must not mistake a dry run for a step that changed nothing.
start="$L = [\"A.md\"]"$'\n'
printf '%s' "$start" > "$C"
out="$(play --check)"
[[ "$(recap "$out")" == *failed=0 ]] && pass "--check" "dry run succeeds" || bad "--check" "dry run succeeds" "$(recap "$out")"
same_file "$start" && pass "--check" "config.toml untouched" || bad "--check" "config.toml untouched" "$(cat "$C")"

exit $fail
