#!/usr/bin/env bash
#
# 从上游仓库 (lbjlaq/Antigravity-Manager) 同步最新代码到本 fork，
# 并触发 GitHub Actions 构建推送 Docker 镜像到 Docker Hub。
#
# 依赖: git, gh (GitHub CLI, 需已执行 gh auth login)
# 用法: ./scripts/sync-upstream.sh [--force]
#   --force: 本地与上游历史分叉时，强制以上游为准（丢弃本地独有提交）

set -euo pipefail

UPSTREAM_URL="https://github.com/lbjlaq/Antigravity-Manager.git"
BRANCH="main"
WORKFLOW="docker-build.yml"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

log() { echo "[sync-upstream] $*"; }

command -v gh >/dev/null 2>&1 || { log "错误: 未安装 GitHub CLI (https://cli.github.com)"; exit 1; }
gh auth status >/dev/null 2>&1 || { log "错误: 请先运行 gh auth login"; exit 1; }

if ! git remote get-url upstream >/dev/null 2>&1; then
    log "添加 upstream 远程: $UPSTREAM_URL"
    git remote add upstream "$UPSTREAM_URL"
fi

log "拉取上游 $BRANCH 分支..."
git fetch upstream "$BRANCH"

LOCAL_SHA=$(git rev-parse "$BRANCH")
UPSTREAM_SHA=$(git rev-parse "upstream/$BRANCH")
BASE_SHA=$(git merge-base "$BRANCH" "upstream/$BRANCH")

if [ "$UPSTREAM_SHA" = "$BASE_SHA" ]; then
    log "本地已是最新 ($LOCAL_SHA)，无需同步，也不触发构建。"
    exit 0
fi

AHEAD=$(git rev-list --count "upstream/$BRANCH..$BRANCH")
BEHIND=$(git rev-list --count "$BRANCH..upstream/$BRANCH")

log "上游有新提交: ${LOCAL_SHA:0:7} -> ${UPSTREAM_SHA:0:7} (落后 $BEHIND 个提交, 本地独有 $AHEAD 个提交)"

if [ "$(git status --porcelain)" != "" ]; then
    log "错误: 工作区有未提交的改动，请先处理后再同步。"
    exit 1
fi

git checkout "$BRANCH"

NEED_FORCE_PUSH=0
if [ "$FORCE" = "1" ]; then
    log "--force 模式: 强制以 upstream/$BRANCH 覆盖本地..."
    git reset --hard "upstream/$BRANCH"
elif [ "$AHEAD" = "0" ]; then
    log "无本地独有提交，直接快进合并 upstream/$BRANCH ..."
    git merge --ff-only "upstream/$BRANCH"
else
    log "存在本地独有提交 (如 CI 配置)，rebase 到 upstream/$BRANCH 之上..."
    git rebase "upstream/$BRANCH"
    NEED_FORCE_PUSH=1
fi

log "推送到 origin/$BRANCH ..."
if [ "$NEED_FORCE_PUSH" = "1" ]; then
    git push --force-with-lease origin "$BRANCH"
else
    git push origin "$BRANCH"
fi

log "触发 GitHub Actions 构建 Docker 镜像..."
gh workflow run "$WORKFLOW" --ref "$BRANCH"

RUN_URL=$(gh run list --workflow="$WORKFLOW" --limit 1 --json url --jq '.[0].url')
log "完成! 构建进度: $RUN_URL"
