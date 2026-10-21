#!/bin/bash
# Restores the GoldenPassport app that install.sh replaced.
#
#   bash rollback.sh [--restore-data] [backup-dir]
#
# By default only the app is restored: 0.2.x never writes gp.secrets, so the old
# app finds its data unchanged. --restore-data also resets the whole data
# directory to its pre-install state, discarding changes made in 0.2.x.
#
# Messages are in Simplified Chinese or English, like the app (see ui_language).
# Environment overrides (for testing): GP_BACKUP_ROOT, GP_NO_LAUNCH=1, GP_LANG=zh-Hans|en.
set -euo pipefail

BUNDLE_ID="site.stanzhai.GoldenPassport"
BACKUP_ROOT="${GP_BACKUP_ROOT:-$HOME/GoldenPassport-backups}"

# The app's own language setting (menu: 语言 / Language), else the system's preferred
# languages, matched by macOS exactly as it does for the app.
ui_language() {
  osascript -l JavaScript -e '
    ObjC.import("Foundation");
    function run(argv) {
      var languages = $.NSUserDefaults.alloc.initWithSuiteName(argv[0]).objectForKey("AppleLanguages");
      return ObjC.unwrap($.NSBundle.preferredLocalizationsFromArrayForPreferences($(["en", "zh-Hans"]), languages).firstObject);
    }' "$BUNDLE_ID" 2>/dev/null || echo en
}
UI_LANG="${GP_LANG:-$(ui_language)}"
# say ZH EN prints the message in the UI language; a single argument is printed as is.
say() { if [ $# -eq 1 ] || [ "$UI_LANG" = zh-Hans ]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }

usage() {
  say "用法：bash rollback.sh [--restore-data] [备份目录]

恢复 install.sh 替换掉的 GoldenPassport。默认只恢复 App：0.2.x 从不写入 gp.secrets，
旧版看到的数据和安装前一样。加上 --restore-data 会把整个数据目录也恢复到安装前，
在 0.2.x 里做的改动会丢失。不指定备份目录时，使用 $BACKUP_ROOT 里最新的一份。
" "Usage: bash rollback.sh [--restore-data] [backup-folder]

Restores the GoldenPassport app that install.sh replaced. By default only the app
is restored: 0.2.x never writes gp.secrets, so the old app finds its data as it
was. --restore-data also resets the whole data folder to its state before the
install, discarding changes made in 0.2.x. Without a backup folder, the newest one
in $BACKUP_ROOT is used.
"
}

RESTORE_DATA=0
BACKUP=""
for arg in "$@"; do
  case "$arg" in
    --restore-data) RESTORE_DATA=1 ;;
    -h|--help) usage; exit 0 ;;
    *) BACKUP="$arg" ;;
  esac
done

step() { printf '\n==> %s\n' "$(say "$@")"; }
info() { printf '    %s\n' "$(say "$@")"; }
die() { printf '\n%s %s\n' "$(say '[失败]' '[FAILED]')" "$(say "$@")" >&2; exit 1; }
checksum() { [ -f "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || echo "none"; }

if [ -z "$BACKUP" ]; then
  BACKUP="$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | tail -n 1 || true)"
  [ -n "$BACKUP" ] || die "在 $BACKUP_ROOT 下没有找到备份" "No backups found in $BACKUP_ROOT"
fi
BACKUP="${BACKUP%/}"
MANIFEST="$BACKUP/manifest.txt"
[ -f "$MANIFEST" ] || die "$BACKUP 不是 install.sh 生成的备份（缺少 manifest.txt）" \
  "$BACKUP is not a backup made by install.sh (manifest.txt is missing)"
manifest() { sed -n "s/^$1=//p" "$MANIFEST" | head -n 1; }

APPS_DIR="$(manifest apps_dir)"
DATA_DIR="$(manifest data_dir)"
TARGET="$APPS_DIR/GoldenPassport.app"

step "回退计划" "Rollback plan"
info "备份：${BACKUP}（$(manifest date)）" "Backup: $BACKUP ($(manifest date))"
info "当前：$(manifest installed_version) → 回退到：$(manifest previous_version)" \
  "Now: $(manifest installed_version) → going back to: $(manifest previous_version)"
if [ $RESTORE_DATA = 1 ]; then
  info "数据：整个数据目录恢复到安装前（0.2.x 中的改动会丢失）" \
    "Data: the whole data folder goes back to its state before the install (changes made in 0.2.x are lost)"
else
  info "数据：保持不变" "Data: left as it is"
fi

step "退出 GoldenPassport" "Quitting GoldenPassport"
pids="$(pgrep -f "^$TARGET/Contents/MacOS/" || true)"
if [ -n "$pids" ]; then
  kill -TERM $pids 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "^$TARGET/Contents/MacOS/" >/dev/null || break
    sleep 0.5
  done
  kill -KILL $pids 2>/dev/null || true
fi

step "恢复 App" "Restoring the app"
rm -rf "$TARGET"
if [ "$(manifest had_app)" = "yes" ]; then
  ditto -x -k "$BACKUP/GoldenPassport.app.zip" "$APPS_DIR"
  info "已恢复 $TARGET" "Restored $TARGET"
else
  info "安装前没有 GoldenPassport，已删除新版" "GoldenPassport was not installed before, so the new version was removed"
fi

step "检查数据" "Checking data"
if [ $RESTORE_DATA = 1 ]; then
  rm -rf "$DATA_DIR"
  [ -d "$BACKUP/data" ] && ditto "$BACKUP/data" "$DATA_DIR"
  info "数据目录已恢复到安装前" "The data folder is back to its state before the install"
elif [ "$(checksum "$DATA_DIR/gp.secrets")" = "$(manifest gp_secrets_sha256)" ]; then
  info "gp.secrets 与备份一致，旧版能看到原来的全部记录" "gp.secrets matches the backup, so 0.1.x finds all its accounts"
else
  info "[警告] gp.secrets 与备份不一致，正在从备份恢复这个文件" \
    "[WARNING] gp.secrets differs from the backup; restoring it from the backup"
  cp -p "$BACKUP/data/gp.secrets" "$DATA_DIR/gp.secrets"
fi
if [ $RESTORE_DATA = 0 ] && [ -f "$DATA_DIR/accounts.json" ]; then
  info "新版的 accounts.json 仍保留在数据目录里，旧版不会读取它；再次安装新版时会继续使用。" \
    "The new version's accounts.json stays in the data folder. 0.1.x doesn't read it; the new version uses it again when you reinstall."
  info "在新版里新增或修改的记录，旧版看不到。需要的话，先在新版菜单里导出 .secrets，再导入旧版。" \
    "Accounts added or changed in the new version are not visible to 0.1.x. If you need them there, export a .secrets backup from the new version's menu and import it into 0.1.x."
fi

if [ "${GP_NO_LAUNCH:-0}" != "1" ] && [ -d "$TARGET" ]; then
  step "启动 GoldenPassport" "Starting GoldenPassport"
  open "$TARGET"
fi
printf '\n%s\n' "$(say "回退完成。备份仍保留在 $BACKUP" "Rollback complete. The backup stays in $BACKUP")"
printf '%s\n' "$(say "⚠️  备份中含有全部 MFA 密钥的未加密副本，请勿外传。不再需要时请删除：rm -rf \"$BACKUP_ROOT\"" \
  "⚠️  The backup holds an unencrypted copy of all your MFA secrets. Don't share it, and delete it when you no longer need it: rm -rf \"$BACKUP_ROOT\"")"
