#!/usr/bin/env bash
# scripts/sync_upstream.sh — 把「上游同步」固化成一条命令
#
# 本仓库 oioilu/cn-math-taxonomy 是上游 xiaoyang111222/cn-math-taxonomy 的
# 「高中 · 数学/物理/化学」裁剪版。上游很活跃，一旦直接同步（GitHub 的
# Sync fork、git merge、git pull），data/*.json 会被上游全量数据覆盖成 3557 条，
# 而裁剪脚本不会重跑 → 站点 60 秒内变回「中小学十科」，且没有任何报错。
#
# 正确姿势只有一条：还原上游原始数据 → 重跑裁剪 → 自检 → 人工看前端冲突 → 人工 push。
# 本脚本只做到「自检通过 + 提交（不 push）」，剩下的判断留给人。
#
# ── 硬性禁止（本脚本永不做，也请人不要手做）────────────────────────────────
#   ✗ git merge upstream/main / git pull upstream
#       会带进上游 3557 条全量数据 + 前端冲突地狱，而且没人会重跑裁剪
#   ✗ git push / git push --force
#       推送是人工判断后的动作；脚本只提交，不推送
#   ✗ 手改 data/*.json
#       数据只能来自「上游原件 + build_hs_subset.py 重建」，手改会在下次同步被冲掉
#   ✗ 改 vercel.json 的 headers / trailingSlash
#       线上缓存与 404 行为依赖它，跟数据同步无关
#   ✗ 改 scripts/build_hs_subset.py 的筛选规则（KEEP_PREFIX {cnm,cnp,cnk} / MIN_GRADE 10）
#       改规则等于换了产品定义，必须单独提 PR 评审
#
# ── 用法 ──────────────────────────────────────────────────────────────────
#   scripts/sync_upstream.sh --check     只读：上游有多少新提交、改了哪些文件
#   scripts/sync_upstream.sh --dry-run   全流程走一遍，不提交、不推送、不打 tag
#   scripts/sync_upstream.sh --apply     真同步：打 tag + 重建数据 + 自检 + 提交（不推送）
#
# 退出码：0 成功｜2 用法错误｜3 网络/fetch 失败｜10 工作区不干净
#         11 自检失败（已停在提交之前，未产生 commit）｜12 上游 ref 取不到
#
# 兼容性：bash 3.2（macOS 自带）+ BSD 工具，不用 GNU 专有参数。
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

UPSTREAM_REMOTE="upstream"
UPSTREAM_URL="https://github.com/xiaoyang111222/cn-math-taxonomy.git"
# 默认同步到上游 main。SYNC_UPSTREAM_REF 只用于演练/回归测试（例如指到一个更早的上游提交，
# 验证「数据真有差异」时的路径）；日常同步不要设置它。
UPSTREAM_REF="${SYNC_UPSTREAM_REF:-upstream/main}"
DOC="docs/UPSTREAM-SYNC.md"
BUILD="scripts/build_hs_subset.py"
VALIDATE="scripts/validate.py"
ENGINE="tests/test_engine.js"

# 基线兜底值（正常情况下从 BUILD 顶部 # UPSTREAM_BASE= 注释读取）
BASE_SHA_FALLBACK="548320e"
EXPECT_FALLBACK="271 / 177 / 102"

# 与本仓库改动重叠、上游一动就必须人工过目的前端文件
WATCH_FILES="index.html explore diagnose assets vercel.json .vercelignore sw.js"

if [ -t 1 ]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'
  BLD=$'\033[1m'; RST=$'\033[0m'
else
  RED=""; GRN=""; YEL=""; BLD=""; RST=""
fi

info()  { printf '%s\n' "$*"; }
step()  { printf '\n%s== %s ==%s\n' "$BLD" "$*" "$RST"; }
warn()  { printf '%s[warn] %s%s\n' "$YEL" "$*" "$RST"; }
ok()    { printf '%s[ok] %s%s\n' "$GRN" "$*" "$RST"; }
fail()  { printf '%s[FAIL] %s%s\n' "$RED" "$*" "$RST" >&2; }

usage() {
  cat <<'EOF'
用法：
  scripts/sync_upstream.sh --check     只读：上游有多少新提交、改了哪些文件（不改任何文件）
  scripts/sync_upstream.sh --dry-run   全流程走一遍，但不提交、不推送、不打 tag
  scripts/sync_upstream.sh --apply     真同步：打 tag + 重建数据 + 自检 + 提交（不推送）

永远不要：git merge upstream/main、git pull upstream、点 GitHub 的「Sync fork」。
详见 docs/UPSTREAM-SYNC.md
EOF
}

# ── 小工具 ────────────────────────────────────────────────────────────────

read_baseline() { # 读 build_hs_subset.py 顶部的 # UPSTREAM_BASE=<sha>
  local s=""
  if [ -f "$BUILD" ]; then
    s=$(grep -m1 -E '^#[[:space:]]*UPSTREAM_BASE=[0-9a-fA-F]+' "$BUILD" \
        | sed -E 's/.*UPSTREAM_BASE=([0-9a-fA-F]+).*/\1/' || true)
  fi
  if [ -z "$s" ]; then
    warn "scripts/build_hs_subset.py 里没有 # UPSTREAM_BASE=，回退到 $BASE_SHA_FALLBACK"
    s="$BASE_SHA_FALLBACK"
  fi
  printf '%s' "$s"
}

read_expected_counts() { # 读 docs/UPSTREAM-SYNC.md 基线表格最新一行（第一行）的三科数字
  local c=""
  if [ -f "$DOC" ]; then
    c=$(grep -E '^\|[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]*\|' "$DOC" \
        | head -n 1 | awk -F'|' '{print $4}' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' || true)
  fi
  case "$c" in
    [0-9]*"/"[0-9]*"/"[0-9]*) : ;;
    *) c="$EXPECT_FALLBACK" ;;
  esac
  printf '%s' "$c"
}

norm_counts() { printf '%s' "$1" | sed -E 's/[[:space:]]+//g'; }

ensure_upstream() {
  if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    info "没有 $UPSTREAM_REMOTE remote，添加 $UPSTREAM_URL"
    git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
  fi
}

fetch_upstream() {
  info "git fetch $UPSTREAM_REMOTE --quiet"
  if ! git fetch "$UPSTREAM_REMOTE" --quiet; then
    fail "git fetch $UPSTREAM_REMOTE 失败：检查网络/仓库地址（${UPSTREAM_URL}）"
    exit 3
  fi
}

resolve_upstream_head() {
  local u
  if ! u=$(git rev-parse --verify "$UPSTREAM_REF^{commit}" 2>/dev/null); then
    fail "取不到 ${UPSTREAM_REF}，先跑 scripts/sync_upstream.sh --check（或检查 SYNC_UPSTREAM_REF 是否有效）"
    exit 12
  fi
  printf '%s' "$u"
}

require_clean_worktree() {
  local st
  st=$(git status --porcelain)
  if [ -n "$st" ]; then
    fail "工作区不干净，先提交或还原再同步："
    printf '%s\n' "$st" >&2
    exit 10
  fi
  ok "工作区干净"
}

# 上游某个 commit 范围内改过的文件（去空行、去重、排序）
files_in_range() {
  git log --name-only --pretty=format: "$1" | sed '/^[[:space:]]*$/d' | sort -u
}

classify_note() { # $1=path → 打一行备注（空表示普通文件）
  case "$1" in
    data/*.json)                            printf '数据（同步时丢弃上游版本、脚本重建）' ;;
    index.html)                             printf '首页，与本仓库改动重叠' ;;
    explore/*|diagnose/*)                   printf '前端页，与本仓库改动重叠' ;;
    assets/*)                               printf '静态资源，与本仓库改动重叠' ;;
    vercel.json|.vercelignore)              printf '部署配置，保持本仓库版本' ;;
    scripts/build_hs_subset.py)             printf '裁剪脚本本体，禁止改规则' ;;
    *)                                      : ;;
  esac
}

is_overlap() { # $1=path → 0 表示与我们改动重叠（要标红）
  case "$1" in
    data/*.json|index.html|explore/*|diagnose/*|assets/*) return 0 ;;
    *) return 1 ;;
  esac
}

print_file_groups() { # $1=range 说明文字  $2=range
  local label="$1" range="$2" f overlap_cnt=0 other_cnt=0
  local -a overlaps others
  overlaps=(); others=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_overlap "$f"; then overlaps+=("$f"); else others+=("$f"); fi
  done <<EOF
$(files_in_range "$range")
EOF

  overlap_cnt=${#overlaps[@]}
  other_cnt=${#others[@]}

  if [ $((overlap_cnt + other_cnt)) -eq 0 ]; then
    info "  （$label 没有文件变化）"
    return 0
  fi
  info "  $label 共改 $((overlap_cnt + other_cnt)) 个文件："
  if [ "$overlap_cnt" -gt 0 ]; then
    info "${RED}  🔴 与我们改动重叠（必须人工看）$overlap_cnt 个：${RST}"
    for f in "${overlaps[@]}"; do
      printf '%s     %s%s  ← %s\n' "$RED" "$f" "$RST" "$(classify_note "$f")"
    done
  fi
  if [ "$other_cnt" -gt 0 ]; then
    info "  ⚪ 其余 $other_cnt 个："
    for f in "${others[@]}"; do
      local note
      note=$(classify_note "$f")
      if [ -n "$note" ]; then printf '     %s  ← %s\n' "$f" "$note"; else printf '     %s\n' "$f"; fi
    done
  fi
}

# ── --check（只读）─────────────────────────────────────────────────────────

do_check() {
  step "--check（只读，不改任何文件）"
  ensure_upstream
  fetch_upstream

  local base u short_u date_u new_n
  base=$(read_baseline)
  u=$(resolve_upstream_head)
  if [ -n "${SYNC_UPSTREAM_REF:-}" ]; then
    warn "SYNC_UPSTREAM_REF=$SYNC_UPSTREAM_REF —— 正在同步测试 ref，而不是 upstream/main"
  fi
  short_u=$(git rev-parse --short "$u")
  date_u=$(git log -1 --format='%ad' --date=short "$u")

  info "本仓库记录的基线 : $base"
  info "上游当前 head    : $short_u  ($date_u)  $(git log -1 --format='%s' "$u")"

  # left = 只在上游的提交（我们落后），right = 只在本仓库的提交（我们领先）
  local counts behind ahead
  counts=$(git rev-list --left-right --count "$UPSTREAM_REMOTE/main...HEAD")
  behind=$(printf '%s' "$counts" | awk '{print $1}')
  ahead=$(printf '%s' "$counts" | awk '{print $2}')
  info "相对 upstream/main：ahead ${ahead}（本仓库独有提交，裁剪版正常）/ behind ${behind}（上游新提交）"

  if git merge-base --is-ancestor "$base" "$u"; then
    new_n=$(git rev-list --count "$base..$u")
    step "基线 $base 之后上游新增 $new_n 个提交"
    if [ "$new_n" -gt 0 ]; then
      info "最近 20 条："
      git log --pretty=format:'  %h %ad %s' --date=short "$base..$u" | sed -n '1,20p'
      printf '\n'
    fi
    print_file_groups "基线→上游" "$base..$u"
  else
    warn "基线 $base 不是上游 head 的祖先（历史被改写过？），改为对比最近一次上游提交"
    print_file_groups "上游最近一次提交" "$UPSTREAM_REMOTE/main~1..$u"
  fi

  if [ "$behind" -eq 0 ]; then
    printf '\n'
    ok "上游没有新提交，当前就是最新。"
    info "（供参考：上游最近 5 个提交改过的文件如下）"
    print_file_groups "上游最近 5 个提交" "$UPSTREAM_REMOTE/main~5..$UPSTREAM_REMOTE/main"
  fi

  step "结论"
  if [ "$behind" -eq 0 ]; then
    info "无需同步。想演练流程可跑 --dry-run。"
  else
    info "有 $behind 个新上游提交。建议顺序：--dry-run（演练） → --apply（提交） → 人工审 diff → git push。"
  fi
  return 0
}

# ── 还原上游原件 + 重建 ────────────────────────────────────────────────────

TMPD=""
cleanup_tmp() { if [ -n "${TMPD:-}" ]; then rm -rf "$TMPD"; fi; return 0; }
trap cleanup_tmp EXIT

restore_upstream_data() { # $1=上游 commit sha
  local u="$1" name
  TMPD=$(mktemp -d "${TMPDIR:-/tmp}/cn-sync.XXXXXX")
  for name in topics dependencies questions; do
    # 先写临时文件再改名：git show 失败时不会把 data/ 里的文件截成空
    # （任务书里写的 `cp /tmp/_up_*.json data/` 会留下 data/_up_topics.json 这种错名，这里用 mv 保持原名）
    git show "$u:data/$name.json" > "$TMPD/$name.json"
    mv "$TMPD/$name.json" "data/$name.json"
    info "  还原 data/$name.json ← 上游 $(git rev-parse --short "$u")"
  done
  if git cat-file -e "$u:data/cn-curriculum-standards.json" 2>/dev/null; then
    git show "$u:data/cn-curriculum-standards.json" > "$TMPD/cn-curriculum-standards.json"
    mv "$TMPD/cn-curriculum-standards.json" "data/cn-curriculum-standards.json"
    info "  还原 data/cn-curriculum-standards.json ← 上游"
  else
    warn "上游 $u 没有 data/cn-curriculum-standards.json，保留本仓库版本"
  fi
}

run_build() {
  local out rc
  if out=$(python3 "$BUILD" 2>&1); then rc=0; else rc=$?; fi
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    fail "裁剪脚本 $BUILD 失败（rc=${rc}），已停在提交之前"
    exit 11
  fi
  ok "裁剪完成"
}

# ── 自检 ──────────────────────────────────────────────────────────────────

check_validate() {
  local out rc
  if out=$(python3 "$VALIDATE" 2>&1); then rc=0; else rc=$?; fi
  printf '%s\n' "$out" | tail -n 25
  if [ "$rc" -ne 0 ] \
     || ! printf '%s' "$out" | grep -q 'VALIDATION PASSED' \
     || ! printf '%s' "$out" | grep -q '共 0 个错误'; then
    fail "自检未过：python3 $VALIDATE 必须输出「共 0 个错误 / VALIDATION PASSED」且退出码 0（实际 rc=${rc}）"
    return 1
  fi
  ok "validate.py：0 个错误"
}

check_engine() {
  local out rc summary failed_n
  if out=$(node "$ENGINE" 2>&1); then rc=0; else rc=$?; fi
  printf '%s\n' "$out" | tail -n 8
  summary=$(printf '%s\n' "$out" | grep -E '[0-9]+ passed, [0-9]+ failed' | tail -n 1 || true)
  failed_n=$(printf '%s' "$summary" | sed -E 's/.* ([0-9]+) failed.*/\1/')
  if [ "$rc" -ne 0 ] || [ -z "$summary" ] || [ "$failed_n" != "0" ]; then
    fail "自检未过：node $ENGINE 必须 0 failed 且退出码 0（实际 rc=$rc / ${summary:-无汇总行}）"
    return 1
  fi
  ok "test_engine.js：$summary"
}

check_topic_counts() {
  local got expect
  TOPIC_COUNTS=""
  got=$(python3 - "data/topics.json" <<'PY'
import json, sys
counts = {"cnm": 0, "cnp": 0, "cnk": 0}
for t in json.load(open(sys.argv[1], encoding="utf-8")):
    p = t["id"].split("_")[0]
    if p in counts:
        counts[p] += 1
print("%d / %d / %d" % (counts["cnm"], counts["cnp"], counts["cnk"]))
PY
)
  expect=$(read_expected_counts)
  info "三科知识点（数学 / 物理 / 化学）：$got"
  info "基线记录的三科数字            ：$expect"
  if [ "$(norm_counts "$got")" != "$(norm_counts "$expect")" ]; then
    printf '%s\n' "${RED}${BLD}"
    info "################################################################"
    info "#  数字已变，需人工确认！                                      #"
    info "#  基线：$expect"
    info "#  本次：$got"
    info "#  知识点数量变化可能来自上游增删内容，也可能来自裁剪规则被改。"
    info "#  确认无误后再改 docs/UPSTREAM-SYNC.md 的基线行。              #"
    info "################################################################"
    printf '%s\n' "$RST"
  else
    ok "三科数字与基线一致：$got"
  fi
  TOPIC_COUNTS="$got"
}

# ── 冲突清单（只报不改）──────────────────────────────────────────────────

stop_selfcheck() {
  fail "已停在自检，未提交任何 commit。"
  info "  还原 data/： git checkout -- data/"
  info "  排查后重跑： scripts/sync_upstream.sh --dry-run"
  exit 11
}

print_manual_list() { # $1=基线 sha  $2=上游 sha → 打印「需人工看」并回传数量到全局 MANUAL_N
  local base="$1" u="$2" f up_changed our_changed note
  local -a manual
  manual=()
  step "需人工看清单（脚本不自动合并这些文件，也不动它们的 txt 冲突）"
  for f in $WATCH_FILES; do
    up_changed=0
    # 任务书口径：upstream/main~1..${U}（上游最近一次提交是否动过）
    if ! git diff --quiet "$UPSTREAM_REMOTE/main~1..$u" -- "$f" 2>/dev/null; then up_changed=1; fi
    # 再叠加「基线..上游」整段，避免上游新提交不止一条时漏报
    if [ "$up_changed" -eq 0 ] && git merge-base --is-ancestor "$base" "$u" 2>/dev/null; then
      if ! git diff --quiet "$base..$u" -- "$f" 2>/dev/null; then up_changed=1; fi
    fi
    our_changed=0
    if ! git diff --quiet "$base"..HEAD -- "$f" 2>/dev/null; then our_changed=1; fi
    if [ "$up_changed" -eq 1 ] || [ "$our_changed" -eq 1 ]; then
      note="$(classify_note "$f")"
      if [ "$up_changed" -eq 1 ] && [ "$our_changed" -eq 1 ]; then
        printf '%s  %-14s 双方都改过 → 人工 3-way 合并%s  %s\n' "$RED" "$f" "$RST" "$note"
      elif [ "$up_changed" -eq 1 ]; then
        printf '%s  %-14s 只有上游改过 → 建议人工 3-way 或按本仓库口径改写%s  %s\n' "$YEL" "$f" "$RST" "$note"
      else
        printf '  %-14s 只有我们改过 → 保持本仓库版本  %s\n' "$f" "$note"
      fi
      manual+=("$f")
    fi
  done
  MANUAL_N=${#manual[@]}
  if [ "$MANUAL_N" -eq 0 ]; then
    info "  （无）上游没动这些文件"
  fi
}

# ── 写基线 ────────────────────────────────────────────────────────────────

write_baseline() { # $1=上游 sha  $2=三科数字  $3=1 时只打印不落盘
  local u="$1" counts="$2" dry="$3"
  python3 - "$DOC" "$BUILD" "$u" "$counts" "$dry" <<'PY'
import re, sys, datetime, pathlib

doc_path, build_path, sha, counts, dry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1"
today = datetime.date.today().isoformat()
row = "| %s | `%s` | %s |" % (today, sha[:7], counts)

# 1) docs/UPSTREAM-SYNC.md 的基线表格（BASELINE 标记之间，最新一版在最上面）
p = pathlib.Path(doc_path)
text = p.read_text(encoding="utf-8")
start, end = "<!-- BASELINE:START -->", "<!-- BASELINE:END -->"
if start not in text or end not in text:
    sys.exit("docs 基线块标记丢失，请先修好 %s 里的 %s / %s" % (doc_path, start, end))
head, rest = text.split(start, 1)
block, tail = rest.split(end, 1)
lines = [ln for ln in block.splitlines() if ln.strip()]
header = [ln for ln in lines if ln.strip().startswith("|") and "同步日期" in ln]
sep = [ln for ln in lines if re.fullmatch(r"\|\s*-{3,}.*\|", ln.strip())]
rows = [ln for ln in lines if ln.strip().startswith("|") and ln not in header and ln not in sep]
# 同一个上游 sha 只保留一条（重跑幂等）
rows = [ln for ln in rows if sha[:7] not in ln]
new_block = "\n\n" + (header[0] if header else "| 同步日期 | 上游提交 | 三科数字 |") + "\n" \
    + (sep[0] if sep else "| --- | --- | --- |") + "\n"
new_block += row + "\n" + "".join(ln + "\n" for ln in rows)
new_doc = head + start + new_block + end + tail

# 2) scripts/build_hs_subset.py 顶部常量区的 # UPSTREAM_BASE=<sha>
b = pathlib.Path(build_path)
src = b.read_text(encoding="utf-8")
new_line = "# UPSTREAM_BASE=%s   # 上游基线：由 scripts/sync_upstream.sh 写入，勿手改" % sha[:7]
if re.search(r"^#\s*UPSTREAM_BASE=", src, re.M):
    new_src = re.sub(r"^#\s*UPSTREAM_BASE=.*$", new_line, src, count=1, flags=re.M)
else:
    new_src = re.sub(r"^(MIN_GRADE\s*=\s*\d+\s*$)", r"\1\n" + new_line, src, count=1, flags=re.M)

if dry:
    # dry-run 只预览：落盘会把 docs/build 脚本也弄脏，就违反了「dry-run 后 git status 只有 data/ 差异」
    print("  [预览] 基线行：%s" % row)
    print("  [预览] %s" % new_line)
    sys.exit(0)

p.write_text(new_doc, encoding="utf-8")
b.write_text(new_src, encoding="utf-8")
print("  基线行：%s" % row)
print("  %s" % new_line)
PY
}

# ── --dry-run / --apply 公共流程 ───────────────────────────────────────────

do_sync() { # $1 = dry-run | apply
  local mode="$1" base u short_u dt tag counts expected
  step "$mode"
  info "1) 前置检查：工作区必须干净"
  require_clean_worktree

  ensure_upstream
  fetch_upstream

  printf "\n"; info "2) 取上游 head"
  u=$(resolve_upstream_head)
  if [ -n "${SYNC_UPSTREAM_REF:-}" ]; then
    warn "SYNC_UPSTREAM_REF=$SYNC_UPSTREAM_REF —— 正在同步测试 ref，而不是 upstream/main"
  fi
  short_u=$(git rev-parse --short "$u")
  info "   上游 head = $short_u  ($(git log -1 --format='%ad' --date=short "$u"))  $(git log -1 --format='%s' "$u")"
  base=$(read_baseline)
  info "   本仓库基线 = $base"

  dt=$(date +%Y%m%d-%H%M)
  tag="pre-sync-$dt"
  printf "\n"; info "3) 打回滚 tag：$tag"
  if [ "$mode" = "apply" ]; then
    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
      tag="$tag-$$"
      info "   同名 tag 已存在，改名为 $tag"
    fi
    git tag "$tag"
    ok "   已打 tag ${tag}（指向同步前的本仓库提交，回滚就靠它）"
  else
    info "   [dry-run] 跳过打 tag（--apply 时创建 ${tag}）"
  fi

  printf "\n"; info "4) 还原上游原始数据（不许省略，这是整个流程的关键）"
  restore_upstream_data "$u"
  info "   现 data/*.json = 上游原件（$(python3 -c 'import json;print(len(json.load(open("data/topics.json"))))') 条知识点），下一步裁回高中三科"

  printf "\n"; info "5) 重跑裁剪：python3 $BUILD"
  run_build

  printf "\n"; info "6) 自检（任一失败即停，不提交）"
  check_validate || stop_selfcheck
  check_engine || stop_selfcheck
  check_topic_counts
  counts="$TOPIC_COUNTS"

  printf "\n"; info "7) 冲突清单（只报不改）"
  MANUAL_N=0
  print_manual_list "$base" "$u"

  printf "\n"; info "8) 写基线"
  if [ "$mode" = "apply" ]; then
    write_baseline "$u" "$counts" 0
    ok "   已写入 $DOC 基线行 + $BUILD 的 # UPSTREAM_BASE=$short_u"
  else
    info "   [dry-run] 将写入（不落盘）："
    write_baseline "$u" "$counts" 1
    info "   [dry-run] 跳过落盘，保持 git status 只有 data/ 的差异"
  fi

  printf "\n"; info "9) 收尾"
  info "   变更统计："
  git diff --stat | sed 's/^/     /'
  if [ "$mode" = "apply" ]; then
    git add -A
    if git diff --cached --quiet; then
      warn "   没有可提交的变更（上游内容与当前完全一致）"
    else
      git commit -m "chore: 同步上游 $short_u 并重新裁剪" --quiet
      ok "   已提交：$(git log -1 --format='%h %s')"
    fi
    printf '\n'
    info "${BLD}${GRN}同步完成（未推送）。${RST}"
    info "请人工看 $MANUAL_N 个文件（上面的清单）后执行： git push -u origin $(git rev-parse --abbrev-ref HEAD)"
    info "回滚： git reset --hard $tag   （或 git revert $(git rev-parse --short HEAD)）"
  else
    printf '\n'
    info "${BLD}${GRN}dry-run 成功：流程可跑通，未产生 commit、未打 tag、未推送。${RST}"
    info "data/ 现在是「上游原件重建后」的结果；不改就还原： git checkout -- data/"
    printf '还原后 git status --porcelain 应为空。\n'
  fi
  return 0
}

# ── main ──────────────────────────────────────────────────────────────────

main() {
  case "${1:-}" in
    --check)   do_check ;;
    --dry-run) do_sync dry-run ;;
    --apply)   do_sync apply ;;
    -h|--help) usage ;;
    *)         usage; exit 2 ;;
  esac
}

main "$@"