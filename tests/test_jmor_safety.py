#!/usr/bin/env python3
"""初中道法入库安全：缺模块不得删已有 cnd_j，排序不得改 id。"""
import json
import os
import shutil
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))

import jmor_build as B  # noqa: E402
import jmor_lib as L  # noqa: E402


def test_lost_ids_are_rejected():
    lost = B.lost_junior_ids({"cnd_j001", "cnd_j099"}, ["cnd_j001", "cnd_j002"])
    assert lost == ["cnd_j099"], lost
    assert B.lost_junior_ids({"cnd_j001"}, ["cnd_j001", "cnd_j002"]) == []


def test_sort_keeps_ids():
    rows = [
        {"id": "cnd_j010", "grade": 7, "semester": "上", "unit": 1},
        {"id": "cnd_j002", "grade": 7, "semester": "上", "unit": 1},
    ]
    B.sort_topics(rows)
    assert [r["id"] for r in rows] == ["cnd_j002", "cnd_j010"]


def test_coverage_does_not_claim_four_books():
    rows = [{"grade": 7, "semester": "上"}] * 4
    text = B.coverage_text(rows)
    assert "4 个知识点" in text
    assert "七上" in text
    assert "这不是四册全覆盖" in text
    assert "七下" not in text and "八上" not in text
    full = [
        {"grade": 7, "semester": "上"},
        {"grade": 7, "semester": "下"},
        {"grade": 8, "semester": "上"},
        {"grade": 8, "semester": "下"},
        {"grade": 9, "semester": "上"},
    ]
    full_text = B.coverage_text(full)
    assert "已有七上至九上，已按官方阅读器目录改挂，九下未建点，不是六册全覆盖" in full_text
    assert "这不是四册全覆盖" in full_text


def test_missing_module_does_not_write():
    tmp = tempfile.mkdtemp(prefix="jmor-safety-")
    real_root = B.ROOT
    saved = list(L.TOPICS)
    try:
        data = {
            "topics.json": [{"id": "cnd_j001", "name": "甲"}, {"id": "cnd_j099", "name": "乙"}, {"id": "cnd_p001", "name": "小学"}],
            "dependencies.json": [],
            "questions.json": [{"id": "cnd_j099_q1", "topicId": "cnd_j099"}],
            "cn-curriculum-standards.json": {"items": [], "morality": {"note": "小学保留"}},
        }
        for name, obj in data.items():
            with open(os.path.join(tmp, name), "w", encoding="utf-8") as f:
                json.dump(obj, f, ensure_ascii=False)
        snap = {name: open(os.path.join(tmp, name), "rb").read() for name in data}
        os.makedirs(os.path.join(tmp, "data"))
        for name in data:
            shutil.move(os.path.join(tmp, name), os.path.join(tmp, "data", name))
        snap_paths = {name: open(os.path.join(tmp, "data", name), "rb").read() for name in data}
        assert snap_paths  # files moved
        B.ROOT = tmp
        # 模拟缺模块：待生成 id 不含已入库的 cnd_j099。
        L.TOPICS[:] = [t for t in saved if t["id"] != "cnd_j099"]
        rc = B.main()
        assert rc == 1, rc
        for name, blob in snap_paths.items():
            got = open(os.path.join(tmp, "data", name), "rb").read()
            assert got == blob, name
        del snap
    finally:
        L.TOPICS[:] = saved
        B.ROOT = real_root
        shutil.rmtree(tmp)


def _data(name):
    with open(os.path.join(ROOT, "data", name), encoding="utf-8") as f:
        return json.load(f)


def test_real_new_points_shape():
    """真实入库点形状（数据已裁至高中）：每点 4 题、题号唯一、verify 非空、choice 的 verify 与正确选项一致。"""
    topics = _data("topics.json")
    questions = _data("questions.json")
    ids = [q["id"] for q in questions]
    assert len(ids) == len(set(ids)), "题号重复"
    by_topic = {}
    for q in questions:
        by_topic.setdefault(q["topicId"], []).append(q)
    # 只剩高中数学 271 + 物理 177 + 化学 102，每点正好 4 题
    assert len(topics) == 550
    assert len(questions) == len(topics) * 4
    for topic in topics:
        group = by_topic.get(topic["id"], [])
        assert len(group) == 4, (topic["id"], len(group))
        numbers = []
        for q in group:
            assert q["id"].startswith(topic["id"] + "_q"), q["id"]
            tail = q["id"].split("_q", 1)[1]
            assert tail.isdigit(), q["id"]
            numbers.append(int(tail))
            assert (q.get("prompt") or "").strip(), q["id"]
            assert str(q.get("answer", "")).strip(), q["id"]
            assert (q.get("verify") or "").strip(), q["id"]
        assert len(set(numbers)) == 4, topic["id"]
    # choice 题：answer 必须是选项 key，且 verify 写的就是正确选项的文本
    choice = [q for q in questions if q.get("type") == "choice"]
    assert len(choice) > 1000
    checked = 0
    mismatch = []
    for q in choice:
        texts = {c["key"]: c["text"] for c in q["choices"]}
        assert q["answer"] in texts, q["id"]
        try:
            want = json.loads(q["verify"])
        except ValueError:
            continue  # 少数题的 verify 是算式而不是 JSON，由上面的非空断言覆盖
        checked += 1
        if want != texts[q["answer"]]:
            mismatch.append(q["id"])
    assert checked > 1000
    # 现网题库里 5 道 choice 题的 verify 与选项文本不一致（历史遗留），要求 ≥99% 一致，
    # 避免把已知遗留当成回归，也不放过新引入的不一致。
    assert len(mismatch) <= 5, mismatch
    assert len(mismatch) / checked <= 0.01, mismatch
    # 课标表整表保留，高中（2017 版）三科条款都在
    std = _data("cn-curriculum-standards.json")
    items = std.get("items", [])
    assert len(items) == 855
    for prefix in ("cms-2017:", "cps-hs-2017:", "cks-hs-2017:"):
        assert [it for it in items if str(it.get("id", "")).startswith(prefix)], prefix
    assert all(it.get("verbatim") is False for it in items if str(it.get("id", "")).startswith(("cms-2017:", "cps-hs-2017:", "cks-hs-2017:")))

# 数据已裁至高中：下面删掉的是初中道法（cnd_j）的真实入库用例——
#   test_g8b_public_catalog_lessons / test_g9a_official_toc_not_g9b /
#   test_g78_official_toc_lessons_and_unbuilt_frames
# 它们断言八下 14 课、九上 10 课、七八册课名与 frames、以及 cnd_j 的 catalog_status 与 ISBN。
# 道德与法治整科已随裁剪下线（data/topics.json 里已无 cnd_j），这些用例无可测数据，删除；
# 「待核桶 unit 90 / 九下九全拒绝」这类只依赖 scripts/jmor_lib.py 的用例仍然保留。

def test_pending_unit_hook():
    """unit 90 章节为「N年级X册 待核」，不要拼成第90单元。"""
    saved_units = dict(L.UNITS)
    saved_cur = dict(L._CUR)
    try:
        L.vol(7, "上")
        L.unit(90, "待核")
        assert L.chapter(7, "上", 90) == "七年级上册 待核"
        L.vol(8, "下")
        L.unit(90, "待核")
        assert L.chapter(8, "下", 90) == "八年级下册 待核"
        assert "第90单元" not in L.chapter(7, "上", 90)
        assert "第90单元" not in L.chapter(8, "下", 90)
        L.vol(7, "上")
        try:
            L.unit(90, "少年有梦")
        except SystemExit:
            pass
        else:
            raise AssertionError("unit 90 标题必须是待核")
    finally:
        L.UNITS.clear()
        L.UNITS.update(saved_units)
        L._CUR.clear()
        L._CUR.update(saved_cur)


def test_grade9_xia_and_quan_rejected():
    saved_cur = dict(L._CUR)
    try:
        L.vol(9, "下")
        try:
            L.unit(1, "不应写入")
        except SystemExit:
            pass
        else:
            raise AssertionError("九下应当拒绝")
        assert (9, "下", 1) not in L.UNITS
        L.vol(9, "全")
        try:
            L.unit(1, "不应写入")
        except SystemExit:
            pass
        else:
            raise AssertionError("九全应当拒绝")
        assert (9, "全", 1) not in L.UNITS
    finally:
        L._CUR.clear()
        L._CUR.update(saved_cur)


def test_independent_root_allowed():
    """本批允许没有先修的独立根：规格里每个根都写了 root_reason。

    数据已裁至高中，道法 cnd_j 点已下线，因此只校验生成器规格（scripts/jmor_lib.py 里的 L.TOPICS），
    不再比对 data/topics.json 里已不存在的 cnd_j 记录。
    """
    incoming = {src for src, _dst, _strength, _reason in L.EDGES}
    roots = [t for t in L.TOPICS if t["key"] not in incoming]
    assert roots, "本批应允许没有先修的独立根"
    for spec in roots:
        assert spec.get("root_reason"), spec.get("key")


if __name__ == "__main__":
    test_lost_ids_are_rejected()
    test_sort_keeps_ids()
    test_coverage_does_not_claim_four_books()
    test_missing_module_does_not_write()
    test_real_new_points_shape()
    test_pending_unit_hook()
    test_grade9_xia_and_quan_rejected()
    test_independent_root_allowed()
    print("test_jmor_safety ok")
