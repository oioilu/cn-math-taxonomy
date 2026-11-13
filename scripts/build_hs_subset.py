#!/usr/bin/env python3
"""把知识图谱裁成「高中 · 数学/物理/化学」子集。

规则：
- 只保留 id 前缀 cnm(数学) / cnp(物理) / cnk(化学) 且 grade >= 10 的知识点
- 先修边两端都保留才留下
- 题目按 topicId 过滤
- 课标表整体保留（体积小，被主题引用）

原始数据备份到 data/_orig/（.vercelignore 已排除，不上传）。
"""
import json
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "data")
ORIG = os.path.join(DATA, "_orig")
KEEP_PREFIX = {"cnm", "cnp", "cnk"}
MIN_GRADE = 10
# UPSTREAM_BASE=548320e   # 上游基线：由 scripts/sync_upstream.sh 写入，勿手改


def load(name):
    with open(os.path.join(DATA, name), encoding="utf-8") as f:
        return json.load(f)


def dump(name, obj):
    with open(os.path.join(DATA, name), "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))


def main():
    os.makedirs(ORIG, exist_ok=True)
    for name in ("topics.json", "dependencies.json", "questions.json"):
        src, dst = os.path.join(DATA, name), os.path.join(ORIG, name)
        if not os.path.exists(dst):
            shutil.copy2(src, dst)

    topics = load("topics.json")
    deps = load("dependencies.json")
    questions = load("questions.json")

    kept = [t for t in topics if t["id"].split("_")[0] in KEEP_PREFIX and t.get("grade", 0) >= MIN_GRADE]
    kept_ids = {t["id"] for t in kept}

    kept_deps = [d for d in deps if d["topicId"] in kept_ids and d["prerequisiteId"] in kept_ids]
    kept_q = [q for q in questions if q.get("topicId") in kept_ids]

    dump("topics.json", kept)
    dump("dependencies.json", kept_deps)
    dump("questions.json", kept_q)

    by = {}
    for t in kept:
        by[t["id"].split("_")[0]] = by.get(t["id"].split("_")[0], 0) + 1
    print(f"知识点 {len(topics)} → {len(kept)}  {by}")
    print(f"先修边 {len(deps)} → {len(kept_deps)}")
    print(f"题目   {len(questions)} → {len(kept_q)}")
    grades = sorted({t["grade"] for t in kept})
    print("保留年级:", grades)


if __name__ == "__main__":
    main()
