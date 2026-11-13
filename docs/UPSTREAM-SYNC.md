# 上游同步（UPSTREAM-SYNC）

> **一句话：永远不要点 GitHub 的「Sync fork」。**
> 本仓库是 `xiaoyang111222/cn-math-taxonomy` 的**裁剪版**（只留高中 数学/物理/化学）。
> Sync fork 会把 `data/*.json` 全量覆盖成上游 3557 条、**而且不会重跑裁剪脚本** —— 站点 60 秒内变回「中小学十科」，没有任何报错。
> 正确同步只有一条命令：`scripts/sync_upstream.sh`。

<!-- BASELINE:START -->

| 同步日期 | 上游提交 | 三科数字 |
| --- | --- | --- |
| 2026-11-13 | `548320e` | 271 / 177 / 102 |

<!-- BASELINE:END -->

- 「三科数字」= 高中数学 / 物理 / 化学 的知识点数（`cnm` / `cnp` / `cnk`）。
- 这张表是**当前基线的唯一事实来源**：`--check` 报的基线、`--apply` 的比对基准都从这里读。
  `scripts/build_hs_subset.py` 顶部另有一行 `# UPSTREAM_BASE=<sha>` 与它同步。
  **只由 `scripts/sync_upstream.sh --apply` 写入，不要手改。**

---

## 1. 为什么不能点「Sync fork」

| 做法 | 结果 |
| --- | --- |
| GitHub 「Sync fork」按钮 / `git merge upstream/main` / `git pull upstream` | `data/*.json` 覆盖成上游全量（3557 知识点 / 14375 题）；**裁剪脚本不会自动重跑**；前端 `index.html`、`explore/`、`diagnose/` 全部产生冲突，一旦手滑选了上游版本，本站的署名、诊断年级收敛、课标口径等改动一起丢失。Vercel 会自动部署 → 60 秒内线上变回「中小学十科」，且构建成功、无报错。 |
| `scripts/sync_upstream.sh` | 只取上游的**内容**（`data/*.json`），立刻用 `build_hs_subset.py` 重新裁剪，自检通过才提交，前端冲突只**列清单**交给人。 |

核心事实：**上游数据是「原料」，本仓库数据是「成品」**。同步 = 换原料 + 重新加工，不是搬成品。

---

## 2. 三档用法与副作用

```bash
scripts/sync_upstream.sh --check     # 只读
scripts/sync_upstream.sh --dry-run   # 演练
scripts/sync_upstream.sh --apply     # 真同步（仍然不推送）
```

| 命令 | 做什么 | 副作用 | 退出码 |
| --- | --- | --- | --- |
| `--check` | 必要时添加 `upstream` remote（`https://github.com/xiaoyang111222/cn-math-taxonomy.git`）→ `git fetch upstream` → 报告：本仓库基线、上游 head 短 sha + 日期、`ahead/behind`、上游新提交按文件分组（`data/*.json` / `index.html` / `explore/` / `diagnose/` / `assets/` **标红**） | 只动 `.git`（remote 与 fetch 缓存），**工作区零改动**，`git status --porcelain` 仍为空 | 0；fetch 失败 3 |
| `--dry-run` | 走完整流程：工作区检查 → 取上游 head → 还原上游原始 `data/*.json` → 重跑裁剪 → `validate.py` + `test_engine.js` + 三科数字比对 → 冲突清单 → 基线**只预览不落盘** | **不 commit、不打 tag、不推送**；`data/*.json` 会被改写成「上游原件重建后」的结果（通常与现状一致），还原：`git checkout -- data/` | 0；自检失败 11；工作区脏 10 |
| `--apply` | 同 `--dry-run`，另加：打 `pre-sync-YYYYMMDD-HHMM` 回滚 tag、写基线（docs 表格 + `# UPSTREAM_BASE=`）、`git commit -m "chore: 同步上游 <sha> 并重新裁剪"` | 新增 1 个 commit + 1 个 tag，**依然不 push** | 同上 |

`--apply` 结束会打印：

```
请人工看 N 个文件（上面的清单）后执行： git push -u origin <当前分支>
回滚： git reset --hard pre-sync-YYYYMMDD-HHMM
```

**N > 0 时不要直接 push**，先做第 3 节的人工审。

### 硬性禁止（脚本永远不做，人也别做）

- ✗ `git merge upstream/main` / `git pull upstream` —— 带进全量数据与冲突地狱
- ✗ `git push` / `git push --force` —— 脚本只提交，推送是人的动作
- ✗ 手改 `data/*.json` —— 数据只能「上游原件 + 重建」，手改下次同步就被冲掉
- ✗ 改 `vercel.json` 的 `headers` / `trailingSlash` —— 线上缓存与 404 行为依赖它
- ✗ 改 `scripts/build_hs_subset.py` 的筛选规则（`KEEP_PREFIX={cnm,cnp,cnk}`、`MIN_GRADE=10`）—— 那是产品定义，必须单独提 PR

---

## 3. 同步之后必做（人工闭环，5 步）

1. **看「需人工看」清单**：脚本会把 `index.html explore/ diagnose/ assets/ vercel.json .vercelignore sw.js` 逐个对比「上游动过 / 我们动过 / 双方都动过」。标红的是双方都改过 —— 真冲突。
2. **`git diff` 审一遍**：重点看 `data/topics.json` 的增删点（三科数字变了就必须逐个确认）、`scripts/build_hs_subset.py` 只有基线注释那一行变化、`docs/UPSTREAM-SYNC.md` 只多一行基线。
3. **push**：`git push -u origin <分支>`（主分支走 PR，见 `CONTRIBUTING`/团队约定）。
4. **等 Vercel 自动部署**：push 后自动构建；看构建日志里 `build_hs_subset.py` 没有被跑（Vercel 只做静态托管，数据已经是仓库里的成品）。
5. **线上验三科**（用浏览器真看，不看构建状态）：
   - 首页副标题/统计只出现「高中数学、高中物理、高中化学」，没有「语文/英语/生物/历史…」；
   - `data/topics.json` 线上可取，`len == 550`（或本次基线数字）；
   - 打开一个物理知识点页 + 一个化学知识点页，题目能出、图能显示；
   - 诊断页年级行只有高中册次。

---

## 4. 冲突处置表

| 文件 | 冲突处理 | 理由 |
| --- | --- | --- |
| `data/topics.json`<br>`data/dependencies.json`<br>`data/questions.json` | **丢弃上游版本 → 脚本重建**（`git checkout --theirs` 也不要用，直接让 `sync_upstream.sh` 覆盖再裁） | 上游是原料，本站是裁剪成品；手合并 35 万行 diff 既不可能也无意义 |
| `data/cn-curriculum-standards.json` | **取上游版本**（原样保留，不裁剪） | 课标表体积小、被知识点引用；裁剪会导致大量悬空引用 |
| `index.html`、`explore/*`、`diagnose/*`、`assets/*` | **人工 3-way 合并**：先看上游改了什么（`git diff <基线> upstream/main -- <file>`），再决定是否搬过来，**保留本站三处定制**：CC BY-NC 署名、诊断年级只留高中册次、首页课标口径 | 这些文件本站改过，无脑取上游会丢定制；无脑取本站会丢上游新功能 |
| `vercel.json`、`.vercelignore` | **保持本仓库版本** | 缓存头 / 404 / 不上传 `data/_orig`、`data/_second_pass` 等策略是本站部署专属 |
| `scripts/build_hs_subset.py` | **只允许改 `# UPSTREAM_BASE=` 这一行注释**；规则变更必须单独 PR | 规则即产品定义 |
| 其余（`docs/`、`scripts/` 的上游内部脚本、`children/`、`screenshots/`） | 默认**不搬**；确需搬再单独 PR | 本站是裁剪版，上游工作文件不应进入站点（`.vercelignore` 已排除部分） |

脚本**不会**自动合并以上任何 txt 冲突 —— 它只列清单。

---

## 5. 回滚

| 场景 | 做法 |
| --- | --- |
| 已 `--apply` 但还没 push | `git reset --hard pre-sync-YYYYMMDD-HHMM`（脚本已打好 tag） |
| 已 push 到分支 | `git revert <同步 commit>` 再 push |
| 已经部署到线上出问题 | Vercel 后台 → Deployments → 上一个正常版本 → **Promote to Production**（秒级回滚，不等重新构建）；随后再在仓库里 `git revert` 把代码修回去，避免下次部署又变坏 |

三科数字异常（例如 271 → 289）时**不要 push**：先 `git reset --hard <tag>`，再去上游看新增了哪些 `cnm_h*` / `cnp_h*` / `cnk_h*` 知识点，确认是正常内容扩充后再重跑 `--apply`（此时基线数字变化属预期，更新 docs 表格即可）。

---

## 6. 命令速查

```bash
# 1. 上游有没有新东西
scripts/sync_upstream.sh --check

# 2. 演练（不提交、不打 tag、不推送）
scripts/sync_upstream.sh --dry-run
git checkout -- data/            # 演练完还原

# 3. 真同步（提交但不推送）
scripts/sync_upstream.sh --apply
git log -1 --stat                # 人工审
git push -u origin <分支>         # 人工推送
```

脚本兼容 bash 3.2（macOS 自带），不依赖 GNU 专有参数；语法自检：`bash -n scripts/sync_upstream.sh`。