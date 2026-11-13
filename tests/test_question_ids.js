#!/usr/bin/env node
/* 题目 ID 与纠错模板：node tests/test_question_ids.js
 * 题库 id 是「知识点 id + _q + 题号」。模板若仍写 q_cnm_ 这种格式，报错对不上题。
 */
'use strict';
const assert = require('assert');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
let passed = 0;

function test(name, fn) {
  fn();
  passed++;
  console.log('  ok   ' + name);
}

function read(rel) {
  return fs.readFileSync(path.join(ROOT, rel), 'utf8');
}

const questions = JSON.parse(read('data/questions.json'));
const template = read('.github/ISSUE_TEMPLATE/question-fix.yml');

test('每道题的 id 都是知识点 id 加 _q 和题号', () => {
  assert.ok(Array.isArray(questions) && questions.length > 1000);
  const bad = [];
  for (const q of questions) {
    if (!q || typeof q.id !== 'string' || typeof q.topicId !== 'string') {
      bad.push(String(q && q.id));
      if (bad.length > 8) break;
      continue;
    }
    const escaped = q.topicId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    if (!new RegExp('^' + escaped + '_q\\d+$').test(q.id)) {
      bad.push(q.id + ' topic=' + q.topicId);
      if (bad.length > 8) break;
    }
  }
  assert.deepStrictEqual(bad, []);
});

test('纠错模板说明真实 ID 格式，不再使用 q_cnm_', () => {
  assert.match(template, /^name:\s*题目纠错\s*$/m);
  assert.match(template, /id:\s*question_id\s*$/m);
  assert.match(template, /cnm_221_q3/);
  assert.match(template, /cnm_p001_q1/);
  assert.match(template, /placeholder:\s*cnm_xxx_qN\s*$/m);
  assert.doesNotMatch(template, /q_cnm_/);
});

test('模板里举例的题目：ID 格式与题库一致；仍在图里的示例必须能查到', () => {
  const ids = new Set(questions.filter((q) => q && typeof q.id === 'string').map((q) => q.id));
  const topics = JSON.parse(read('data/topics.json'));
  const topicIds = new Set(topics.map((t) => t.id));
  // 数据已裁至高中：模板仍举例 cnm_221_q3、cnm_p001_q1（初中数学、小学数学的题），
  // 这两个知识点已随裁剪下线，所以只校验示例 ID 的格式；示例若还在图里就必须在题库中。
  const examples = ['cnm_221_q3', 'cnm_p001_q1'];
  examples.forEach((id) => {
    assert.match(id, /^cnm_[a-z]?\d+_q\d+$/);
    const topicId = id.replace(/_q\d+$/, '');
    if (topicIds.has(topicId)) assert.ok(ids.has(id), id + ' 在题库里应该有');
  });
  // 现网题库仍按模板写的「知识点 id + _q + 题号」命名，且高中点都能对上
  const live = questions.filter((q) => topicIds.has(q.topicId));
  assert.ok(live.length > 1000);
  assert.ok(ids.has('cnm_h001_q1'));
  assert.ok(live.every((q) => q.id === q.topicId + '_q' + q.id.slice(q.topicId.length + 2)));
});

test('纠错模板的题目 ID 栏不收集作答或档案', () => {
  assert.doesNotMatch(template, /id:\s*(answer|child|profile|session|user_answer)\b/);
  const idBlock = template.split(/id:\s*question_id/)[1].split(/type:\s*textarea/)[0];
  assert.ok(idBlock && idBlock.length > 0);
  assert.doesNotMatch(idBlock, /答案|档案|孩子|localStorage/);
});

console.log('\n' + passed + ' passed');
