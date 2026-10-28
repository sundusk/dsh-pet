#!/bin/bash
# =============================================================================
# 生成 README 用的 DSH Pet 状态球 SVG（docs/assets/dsh-pet-<mood>.svg）
#
# 为什么用脚本生成而不是截图：
#   - GitHub 在 README 里原生渲染 SVG，不失真、体积小（每张 ~1KB）
#   - 改颜色/眼睛样式时改本脚本的 BALLS 表重跑即可，无需重新截图
#
# 颜色与 Sources/DSHPet/SettingsStore.swift 的 moodColorConfigs 保持一致：
#   idle #60a5fa / waiting #34d399 / jumping #a855f7 / authorizing #facc15
#   questioning #ec4899 / done #22d3ee / failed #f87171 / stopped #000000
#   断连灰 #9ca3af（SettingsStore.disconnectedHex）
#
# 球的画法（与 app 渲染一致）：径向渐变圆（左上高光 → 主色 → 加深色）
# + 白色竖椭圆眼睛 + 顶部高光 + 底部接触阴影。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."   # 仓库根

OUT="docs/assets"
mkdir -p "$OUT"

# mood: 中文标签(仅注释用): 主色hex
BALLS=(
  "idle:空闲:60a5fa"
  "waiting:正在思考中:34d399"
  "jumping:工具调用:a855f7"
  "authorizing:等待你的授权:facc15"
  "questioning:做出你的抉择:ec4899"
  "done:搞定啦:22d3ee"
  "failed:出错了:f87171"
  "stopped:已停止:000000"
  "disconnected:未连接灰:9ca3af"
)

# 颜色加深 55%（用于球体底部暗部）
darken() {
  local hex=$1
  printf '%02x%02x%02x' \
    $(( 16#${hex:0:2} * 55 / 100 )) \
    $(( 16#${hex:2:2} * 55 / 100 )) \
    $(( 16#${hex:4:2} * 55 / 100 ))
}

render() {
  local name=$1 color=$2 dark=$3
  # 眼睛默认黑色；stopped 是黑球，黑眼不可见 → 用白眼
  local eye="#000000"
  [ "$name" = "stopped" ] && eye="#ffffff"
  cat > "$OUT/dsh-pet-$name.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="72" height="72" viewBox="0 0 96 96" role="img" aria-label="DSH Pet $name">
  <defs>
    <radialGradient id="ball" cx="35%" cy="28%" r="85%">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.80"/>
      <stop offset="26%" stop-color="#${color}"/>
      <stop offset="100%" stop-color="#${dark}"/>
    </radialGradient>
    <radialGradient id="shine" cx="34%" cy="24%" r="45%">
      <stop offset="0%" stop-color="#ffffff" stop-opacity="0.5"/>
      <stop offset="100%" stop-color="#ffffff" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="glow" cx="50%" cy="50%" r="50%">
      <stop offset="0%" stop-color="#${color}" stop-opacity="0.45"/>
      <stop offset="55%" stop-color="#${color}" stop-opacity="0.12"/>
      <stop offset="100%" stop-color="#${color}" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <ellipse cx="48" cy="80" rx="26" ry="5" fill="#000000" opacity="0.10"/>
  <circle cx="48" cy="46" r="40" fill="url(#glow)"/>
  <circle cx="48" cy="46" r="31" fill="url(#ball)"/>
  <circle cx="48" cy="46" r="31" fill="url(#shine)"/>
  <ellipse cx="37" cy="46" rx="4.6" ry="8.4" fill="${eye}"/>
  <ellipse cx="59" cy="46" rx="4.6" ry="8.4" fill="${eye}"/>
</svg>
SVG
  echo "生成 $OUT/dsh-pet-$name.svg"
}

for entry in "${BALLS[@]}"; do
  IFS=: read -r name _label color <<< "$entry"
  render "$name" "$color" "$(darken "$color")"
done

echo "✅ 完成，共 ${#BALLS[@]} 张"
