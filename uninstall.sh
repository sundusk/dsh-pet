#!/bin/bash
# =============================================================================
# DSH Pet 卸载脚本
#
# 功能：
#   1. 退出正在运行的 DSH Pet / 旧版 MoodBall
#   2. 删除 Applications 中的新旧应用包
#   3. 询问是否同时移除 DSH Pet 桥接插件（dsh plugin remove）
#
# 用法：
#   bash uninstall.sh
# =============================================================================
set -euo pipefail

APP_CANDIDATES=(
    "$HOME/Applications/DSH Pet.app"
    "/Applications/DSH Pet.app"
    "$HOME/Applications/MoodBall.app"
    "/Applications/MoodBall.app"
)

info() { printf "\033[1;34m[info]\033[0m %s\n" "$1"; }
ok()   { printf "\033[1;32m[ok]\033[0m   %s\n" "$1"; }

# ---------------------------------------------------------------- 1. 退出 app
info "退出 DSH Pet……"
osascript -e 'tell application "DSH Pet" to quit' 2>/dev/null || true
osascript -e 'tell application "MoodBall" to quit' 2>/dev/null || true
sleep 1
if pgrep -x DSHPet >/dev/null 2>&1; then
    pkill -x DSHPet 2>/dev/null || true
fi
if pgrep -x MoodBall >/dev/null 2>&1; then
    pkill -x MoodBall 2>/dev/null || true
fi

# ---------------------------------------------------------------- 2. 删除 app
removed=0
for p in "${APP_CANDIDATES[@]}"; do
    if [ -d "$p" ]; then
        /usr/bin/trash "$p"
        ok "已删除 $p"
        removed=1
    fi
done
if [ "$removed" = "0" ]; then
    info "未找到 DSH Pet.app 或 MoodBall.app（可能装在别的位置，请手动移入废纸篓）。"
fi

# ---------------------------------------------------------------- 3. 移除插件（询问）
echo ""
read -r -p "是否同时移除 DSH Pet 桥接插件？(y/N) " ans
case "$ans" in
    y|Y|yes|YES)
        DSH_BIN=$(command -v dsh || ls -d "$HOME"/.npm/_npx/*/node_modules/.bin/dsh 2>/dev/null | head -1)
        if [ -n "$DSH_BIN" ]; then
            if "$DSH_BIN" plugin --profile web remove @sundusk/dsh-pet 2>&1; then
                ok "插件已移除（重启 dsh web 后生效）。"
            else
                info "插件移除失败；如果安装的是旧版，请手动执行：dsh plugin --profile web remove @sundusk/dsh-moodball-status"
            fi
        else
            info "未找到 dsh 命令，请手动执行：dsh plugin --profile web remove @sundusk/dsh-pet"
        fi
        ;;
    *)
        info "已跳过插件移除（保留 DSH Pet 桥接插件，不影响其他功能）。"
        ;;
esac

echo ""
echo "✅ 卸载完成"
