# 高中知识图谱 · 数学 / 物理 / 化学

一个纯静态的**高中**知识图谱与自适应前置诊断工具：沿先修关系出题，答错就往前追，直到定位到真正没学会的那一步。

只收高中数学、高中物理、高中化学（必修 + 选择性必修）。

## 内容范围

| 学科 | 知识点 | 先修边 | 题目 | 册次 |
|---|---:|---:|---:|---|
| 数学 | 271 | 320 | 1,084 | 必修第一、二册 + 选择性必修第一至三册 |
| 物理 | 177 | 409 | 708 | 必修第一至三册 + 选择性必修第一至三册 |
| 化学 | 102 | 180 | 408 | 必修第一、二册 + 选择性必修第一至三册 |
| **合计** | **550** | **909** | **2,200** | 年级 10–15 |

- 每个知识点带课标条目编号（人教版 2017 版课标 / 2022 版日常修订）
- 先修关系分 hard / soft 两类，全图 0 环、0 孤立
- 题目分选择与数值两类

## 功能

- **知识图谱**：按册、章浏览，硬先修实线、软先修虚线，可点任意节点看掌握标准与课标条目
- **自适应诊断**：先问目标本身，答错出同级或更容易的题，仍错才沿先修回溯；结果给薄弱根因 + 按顺序排列的学习路径
- **本机记录**：答题进度存 localStorage，不上传
- **PWA**：可添加到主屏幕离线使用

## 目录结构

```
index.html            首页（按册进入）
explore/              知识图谱浏览
diagnose/             自适应诊断
assets/               样式、首页脚本、PWA 注册
data/
  topics.json         知识点（550 条）
  dependencies.json   先修边（909 条）
  questions.json      题目（2,200 道）
  cn-curriculum-standards.json   课标条目
scripts/
  build_hs_subset.py  裁剪脚本（从上游原件生成 data/*.json）
  validate.py         数据校验
tests/
  test_engine.js      诊断引擎测试
sw.js                 服务工作线程
vercel.json           部署响应头（缓存 + 安全头）
```

### 数据字段（摘要）

**topics.json**：`id` / `name` / `grade` / `volume` / `chapter` / `section` / `domain` / `type` / `description` / `mastery` / `standards[]` / `root_reason`（无先修的起点才写）

**dependencies.json**：`topicId` / `prerequisiteId` / `strength`（`hard` | `soft`）

**questions.json**：`id` / `topicId` / `type`（`choice` | `numeric`）/ `prompt` / `options` / `answer` / `explain` / `difficulty`

## 本地运行

必须用 HTTP 服务打开（`file://` 会被浏览器的 fetch 拦掉）：

```bash
python3 -m http.server 8000
# 首页      http://localhost:8000/
# 知识图谱  http://localhost:8000/explore/
# 诊断      http://localhost:8000/diagnose/
```

## 数据是怎么来的

`data/*.json` 不是手写的，由 `scripts/build_hs_subset.py` 生成：

- 保留 id 前缀 `cnm`（数学）/ `cnp`（物理）/ `cnk`（化学）且 `grade >= 10` 的知识点
- 先修边两端都被保留才留
- 题目按 `topicId` 过滤
- 课标表整表保留，前端只取用到的条目

改数据请改脚本后重跑，不要手改 JSON：

```bash
python3 scripts/build_hs_subset.py
```

## 自检

```bash
python3 scripts/validate.py        # 期望：0 个错误，VALIDATION PASSED
node tests/test_engine.js          # 期望：0 failed
```

## 数据来源与许可

内容改编自 [xiaoyang111222/cn-math-taxonomy](https://github.com/xiaoyang111222/cn-math-taxonomy)，原作者以 **CC BY-NC 4.0** 许可发布（署名 · 非商业性使用），条款见仓库内 `LICENSE`。

本仓库对其内容做了**裁剪修改**：仅保留高中数学、物理、化学三个学科及高中年级的知识点、先修边与题目，移除其余学科与学段。原作品与本改编版均**不得用于商业用途**。

---

*本项目为个人学习用途的静态站点，无后端、无账号、无数据上传。*