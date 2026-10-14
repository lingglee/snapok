#!/bin/bash
# 让 CI 在发版时自动更新 Homebrew cask（维护者运行一次即可）。
# 生成一个只能写 thinkany-ai/homebrew-tap 的部署密钥：公钥加到 tap 仓库，私钥存为本仓库的
# HOMEBREW_TAP_DEPLOY_KEY secret。私钥只在临时目录里存在片刻，不会打印出来。
#
#   ./scripts/setup-homebrew-tap-key.sh
#
# 前提：gh 已登录，且对两个仓库都有 admin 权限。重复运行会再加一把新钥匙，旧的可在 tap 的 Settings › Deploy keys 删除。
set -euo pipefail

REPO="${REPO:-thinkany-ai/snapok}"
TAP_REPO="${TAP_REPO:-thinkany-ai/homebrew-tap}"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

ssh-keygen -q -t ed25519 -N "" -C "$REPO CI → $TAP_REPO" -f "$DIR/key"
gh repo deploy-key add "$DIR/key.pub" --repo "$TAP_REPO" --allow-write --title "$REPO CI (cask updates)"
gh secret set HOMEBREW_TAP_DEPLOY_KEY --repo "$REPO" < "$DIR/key"
echo "Done: $TAP_REPO has a write deploy key, and $REPO has the HOMEBREW_TAP_DEPLOY_KEY secret."
