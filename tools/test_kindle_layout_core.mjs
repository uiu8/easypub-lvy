import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const root = path.resolve(import.meta.dirname, '..');
const matrixPath = path.join(root, 'docs/evidence/kindle-case-matrix-20261121.json');
const source = fs.readFileSync(path.join(root, 'plugins/kindle-preview/kindle-layout-core.js'), 'utf8');
const context = { window: {}, console };
vm.runInNewContext(source, context, { filename: 'kindle-layout-core.js' });
const core = context.window.EasyPubKindleLayout;
assert.ok(core, 'layout core was not installed');

const engines = ['modern', 'kpw5', 'legacy-voyage', 'legacy-kpw3', 'legacy-kpw4'];
const c02 = '清晨山路渐渐明亮，远处的村庄升起炊烟。旅人沿着石阶走到桥边，看见河面映着微光。他停下脚步，把一路所见记在纸上，然后继续向前。';
const c03 = '甲乙丙丁戊己庚辛壬癸“山路明亮”他说：“今天继续赶路。”甲乙丙丁戊己庚辛壬癸';
const p10 = '甲乙丙丁戊己庚辛王癸甲乙丙丁甲乙丙丁戊己庚辛王癸天地玄黄宇宙洪荒日月盈昃辰宿';
const b13 = '甲乙丙丁戊己庚辛王癸天地玄山川日月甲乙丙丁戊己庚辛王癸天地玄黄宇宙洪荒日月盈昃辰宿列张甲乙丙丁戊己庚辛王癸';
const f12 = '占位甲山川日月\n占位乙山川日月\n占位丙山川日月\n占位丁山川日月\n目标段落从此开始。' + c02;

const advance = (char) => /[A-Za-z0-9]/u.test(char) ? 0.58 : /[，。！？；：、“”‘’（）《》【】……——]/u.test(char) ? 0.5 : 1;
const lineText = (text, line) => Array.from(text).slice(line.start, line.end).join('');
const checks = [];

for (const engine of engines) {
  const profile = core.profileFor(engine);
  assert.equal(profile.id, engine);
  const lines = core.layoutText(c02, { width: 12, em: 1, engine, advance, justify: true });
  assert.ok(lines.length > 1, `${engine}: C02 did not wrap`);
  assert.equal(lines.map((line) => lineText(c02, line)).join(''), c02, `${engine}: C02 lost text`);
  for (const line of lines) {
    assert.ok(line.text.length > 0, `${engine}: empty line`);
    assert.ok(!/^[。，、；：？！」』）》】〉”’]/u.test(line.text), `${engine}: illegal line start ${line.text}`);
  }
  const quoteLines = core.layoutText(c03, { width: 12, em: 1, engine, advance, justify: true });
  assert.equal(quoteLines.map((line) => line.text).join(''), c03, `${engine}: quote text lost`);
  const punctuationLines = core.layoutText(p10, { width: 12, em: 1, engine, advance, justify: true });
  assert.equal(punctuationLines.map((line) => line.text).join(''), p10, `${engine}: punctuation text lost`);
  checks.push({ engine, profile, c02Lines: lines.length, quoteLines: quoteLines.length, punctuationLines: punctuationLines.length });
}

const paginated = core.paginateLinesDetailed([5, 4, 7, 2], {
  height: 4,
  lineHeight: 1,
  paragraphSpacing: [0, 0.25, 0, 0],
  orphans: [1, 2, 1, 1],
  widows: [1, 2, 1, 1],
  keepWithNext: [false, true, false, false],
  breakBefore: [false, false, false, true],
  breakAfter: [false, false, false, false],
});
assert.ok(paginated.pages.length >= 5, 'pagination state machine did not create regions');
assert.ok(paginated.events.some((event) => event.state === 'candidate'));
assert.ok(paginated.events.some((event) => event.state === 'commit'));
assert.ok(paginated.events.some((event) => event.state === 'next-region'));
assert.deepEqual(
  JSON.parse(JSON.stringify(paginated.pages.flat().map(({ paragraph, line }) => `${paragraph}:${line}`))),
  ['0:0', '0:1', '0:2', '0:3', '0:4', '1:0', '1:1', '1:2', '1:3', '2:0', '2:1', '2:2', '2:3', '2:4', '2:5', '2:6', '3:0', '3:1'],
);

const matrix = JSON.parse(fs.readFileSync(matrixPath, 'utf8'));
assert.equal(matrix.sample_count, 73, 'screenshot matrix sample count changed');
assert.equal(matrix.observation_only, true);
assert.ok(matrix.coverage.missing_families.includes('P15'));
assert.ok(matrix.coverage.observed_families.includes('C02'));
assert.ok(matrix.coverage.observed_families.includes('B15'));
// B13 and F12 are representative candidate/paragraph samples. They are run
// through the same engine API without treating their screenshot rows as rules.
for (const engine of engines) {
  const lines = core.layoutText(b13, { width: 12, em: 1, engine, advance, justify: true });
  assert.equal(lines.map((line) => line.text).join(''), b13);
  const fLines = core.layoutText(f12.replaceAll('\n', ''), { width: 12, em: 1, engine, advance, justify: false });
  assert.ok(fLines.length > 0);
}

const report = {
  schema: 'kindle-layout-core-regression/v1',
  generated_at: new Date().toISOString(),
  engines,
  matrix: { sample_count: matrix.sample_count, coverage: matrix.coverage },
  checks,
  pagination: { pages: paginated.pages.length, events: paginated.events.length, state: paginated.state },
  representative_cases: ['C02', 'C03', 'P10', 'B13', 'F12'],
};
const output = path.join(root, 'docs/evidence/kindle-layout-regression-20261121.json');
fs.writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`);
console.log(JSON.stringify({ passed: true, output, pages: paginated.pages.length, events: paginated.events.length }));
