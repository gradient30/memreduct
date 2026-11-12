#!/usr/bin/env bash
# 裸仓库 -> upstream（GitHub/CNB）推送公共逻辑
# 供 apply-bundle.sh、git_init_tcloud.sh 与云主机 bundle watcher 复用

is_non_retriable_push_error() {
  echo "$1" | grep -qiE \
    'without workflow scope|remote rejected|authentication failed|403|denied|insufficient|forbidden|requires|not authorized|repository not found|bad credentials|invalid username|permission denied|could not read username'
}

is_transient_push_error() {
  echo "$1" | grep -qiE \
    'empty reply from server|connection timed out|connection reset|could not resolve host|failed to connect|ssl|recv failure|operation timed out|http 408|502 bad gateway|503 service unavailable|504 gateway timeout|the requested url returned error|unable to access|curl 52|curl 56|network is unreachable|name or service not known'
}

probe_push_platform() {
  local probe_url="${1:-https://github.com}"
  curl -fsSIL --connect-timeout 10 --max-time 20 "$probe_url" >/dev/null 2>&1
}

wait_for_push_platform() {
  local probe_url="${1:-https://github.com}"
  local max_attempts="${2:-3}"
  local attempt=1

  while (( attempt <= max_attempts )); do
    if probe_push_platform "$probe_url"; then
      return 0
    fi
    sleep $(( attempt * 3 ))
    ((attempt++))
  done

  return 1
}

# 依赖远端上下文：target_remote branch push_retries push_sleep_base PUSH_PROBE_URL log()
push_with_retry() {
  local attempt=1
  local rc=0
  local out=""
  local push_log=""
  local remote_url=""
  local safe_remote_url=""
  local probe_url="${PUSH_PROBE_URL:-https://github.com}"

  remote_url="$(git remote get-url "$target_remote" 2>/dev/null || true)"
  safe_remote_url="$(sanitize_log_line "$remote_url")"

  while (( attempt <= push_retries )); do
    if ! wait_for_push_platform "$probe_url" 3; then
      log "push platform probe failed before attempt ${attempt}/${push_retries} url=${probe_url}"
    else
      log "push platform probe ok url=${probe_url}"
    fi

    push_log="$(mktemp)"
    log "push start (attempt ${attempt}/${push_retries}) remote=${target_remote} url=${safe_remote_url}"

    set +e
    GIT_TERMINAL_PROMPT=0 git \
      -c http.version=HTTP/1.1 \
      -c http.postBuffer=524288000 \
      -c http.lowSpeedLimit=1000 \
      -c http.lowSpeedTime=600 \
      push --force "$target_remote" "refs/heads/$branch:refs/heads/$branch" 2>&1 \
      | tee "$push_log" \
      | while IFS= read -r line; do
          log "$line"
        done
    rc=${PIPESTATUS[0]}
    set -e

    out="$(cat "$push_log")"
    rm -f "$push_log"

    if (( rc == 0 )); then
      log "push success remote=${target_remote} branch=${branch}"
      return 0
    fi

    if is_non_retriable_push_error "$out"; then
      log "push non-retriable (rc=${rc}) remote=${target_remote} url=${safe_remote_url}"
      return "$rc"
    fi

    if is_transient_push_error "$out"; then
      log "push transient network error (rc=${rc}) remote=${target_remote} — will retry"
    else
      log "push failed (attempt ${attempt}/${push_retries}, rc=${rc}) remote=${target_remote} url=${safe_remote_url}"
    fi

    sleep $(( attempt * push_sleep_base ))
    ((attempt++))
  done

  return "$rc"
}

log_upstream_recovery_hint() {
  local repo_path="$1"
  local remote_name="$2"
  local branch_name="$3"
  log "PARTIAL SUCCESS: bare repo already updated, but upstream push not confirmed"
  log "RECOVERY: git --git-dir=${repo_path} push --force ${remote_name} refs/heads/${branch_name}:refs/heads/${branch_name}"
  log "RECOVERY: or wait 1-2 minutes and retry the same push command (often Empty reply from server is transient)"
}
