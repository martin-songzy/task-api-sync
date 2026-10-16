#!/usr/bin/env bash
# git credential helper：从 ~/.config/github/token 读取 GitHub PAT
# 该 token 文件权限应为 600，永不入库。用法：
#   git config credential.helper "<repo>/git-credential-taskapi.sh"
if [ "${1:-}" = "get" ]; then
  # 按 git credential 协议消费 stdin（host=... 等），直到空行
  while IFS= read -r line; do
    [ -z "$line" ] && break
  done
  TOKEN_FILE="$HOME/.config/github/token"
  [ -f "$TOKEN_FILE" ] || exit 0
  TOKEN="$(tr -d ' \t\r\n' < "$TOKEN_FILE")"
  [ -n "$TOKEN" ] || exit 0
  printf 'username=%s\npassword=%s\n' "x-access-token" "$TOKEN"
fi
exit 0
