#!/usr/bin/env bash
# 网链统一 skill 安装器。按服务端 registry（/api/skills）把某个 skill 的全部文件
# 安装到「规范目录名」下，并清理已知旧别名目录。
#
# 关键保证：目录名永远等于 skill 规范名（如 shihui-publish），绝不会把新内容
# 写进旧名目录（如 openurl-publish）。这就是「改名迁移」的硬修复——Agent 不再
# 需要自己 mkdir/mv/rm。
#
# 用法：
#   skill-install.sh <skill-name> <target-dir> [--base URL]
#   curl -fsSL https://openurl.shihui.ai/skill-install.sh | bash -s <skill-name> <你的客户端 Skill 根目录>/<skill-name>
#
# 退出码：0 成功；非 0 失败。
set -eu

BASE="https://openurl.shihui.ai"
NAME=""
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    -h|--help)
      echo "usage: skill-install.sh <skill-name> <target-dir> [--base URL]" >&2
      echo "  installs into a folder named exactly <skill-name>;" >&2
      echo "  auto-migrates known legacy folders (e.g. openurl-publish -> shihui-publish)." >&2
      exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *)
      if [ -z "$NAME" ]; then NAME="$1"
      elif [ -z "$TARGET" ]; then TARGET="$1"
      else echo "unexpected argument: $1" >&2; exit 1
      fi
      shift ;;
  esac
done

[ -n "$NAME" ] || {
  echo "usage: skill-install.sh <skill-name> <target-dir> [--base URL]" >&2
  exit 1
}
BASE="${BASE%/}"

# 旧名 → 规范名。Agent 若仍用旧名调用，自动纠正。
case "$NAME" in
  openurl-publish) NAME="shihui-publish" ;;
  openurl-tutor)   NAME="shihui-tutor" ;;
esac

# 每个规范名对应的旧目录名（安装成功后删除，避免「文件夹旧、内容新」）。
legacy_for() {
  case "$1" in
    shihui-publish) echo "openurl-publish" ;;
    shihui-tutor)   echo "openurl-tutor" ;;
    *) echo "" ;;
  esac
}

command -v node >/dev/null 2>&1 || {
  echo "error: node is required to read the skill registry" >&2
  exit 1
}

# ---------- 解析目标目录：目录名必须等于规范名 ----------
# Skill 根目录属于各 Agent 客户端，安装器绝不猜测、更不默认某个客户端目录。
# 传了但 basename ≠ name → 改写为「同级 sibling/<name>」（绝不写进错名目录）。
[ -n "$TARGET" ] || {
  echo "error: target-dir is required; pass your Agent client's Skill directory, for example:" >&2
  echo "  <skills-root>/$NAME" >&2
  exit 1
}
TARGET="${TARGET%/}"
base_name=$(basename "$TARGET")
if [ "$base_name" != "$NAME" ]; then
  parent=$(dirname "$TARGET")
  corrected="$parent/$NAME"
  echo "note: target folder name '$base_name' != skill name '$NAME';" >&2
  echo "      installing into '$corrected' instead (canonical name is mandatory)." >&2
  TARGET="$corrected"
fi

info=$(curl -fsSL "$BASE/api/skills") || {
  echo "error: cannot reach $BASE/api/skills" >&2
  exit 1
}

# 用 node 解析 registry：第一行 downloadBase（去尾斜杠），其余每行一个相对路径。
parsed=$(printf '%s' "$info" | node -e '
let s = "";
process.stdin.on("data", (d) => (s += d)).on("end", () => {
  const name = process.argv[1];
  let j;
  try { j = JSON.parse(s); } catch { console.error("error: invalid registry response"); process.exit(2); }
  const sk = j.skills && j.skills[name];
  if (!sk) { console.error("error: unknown skill: " + name); process.exit(3); }
  if (!sk.downloadBase) { console.error("error: skill not downloadable yet: " + name); process.exit(4); }
  console.log(String(sk.downloadBase).replace(/\/$/, ""));
  for (const f of sk.files) console.log(f);
});' "$NAME") || exit 1

DL=$(printf '%s\n' "$parsed" | head -1)
[ -n "$DL" ] || { echo "error: no download base for $NAME" >&2; exit 1; }

mkdir -p "$TARGET"
# 从第二行起是文件清单
printf '%s\n' "$parsed" | tail -n +2 | while IFS= read -r f; do
  [ -n "$f" ] || continue
  dest="$TARGET/$f"
  mkdir -p "$(dirname "$dest")"
  curl -fsSL "$DL/$f" -o "$dest" || { echo "error: failed to download $f" >&2; exit 1; }
  # 脚本类给可执行权限
  case "$f" in
    *.sh) chmod +x "$dest" 2>/dev/null || true ;;
  esac
  echo "  + $f" >&2
done

# 清理同级旧别名目录（若存在且不是刚装好的目标）
legacy=$(legacy_for "$NAME")
if [ -n "$legacy" ]; then
  parent=$(dirname "$TARGET")
  old="$parent/$legacy"
  if [ -e "$old" ] && [ "$old" != "$TARGET" ]; then
    rm -rf "$old"
    echo "removed legacy folder: $old" >&2
  fi
fi

echo "installed $NAME into $TARGET" >&2
echo "IMPORTANT: read $TARGET/SKILL.md and continue from there (folder name must be $NAME)." >&2
echo "ok"
echo "$TARGET"
