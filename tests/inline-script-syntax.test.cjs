const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(
  path.join(__dirname, '..', 'PayMind_MVP_v2_1_58.html'),
  'utf8'
);
const scriptTag = /<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi;
const scripts = [];
let match;
let index = 0;

while ((match = scriptTag.exec(html)) !== null) {
  const attributes = match[1] || '';
  const body = match[2] || '';
  if (/\bsrc\s*=/i.test(attributes)) continue;
  const type = attributes.match(/\btype\s*=\s*["']?([^"' \t>]+)/i)?.[1]?.toLowerCase();
  if (type && !['text/javascript', 'application/javascript'].includes(type)) continue;
  if (!body.trim()) continue;
  scripts.push({ filename: 'PayMind_MVP_v2_1_58.inline-' + (++index) + '.js', body });
}

test('the application has inline scripts to validate', () => {
  assert.ok(scripts.length > 0);
});

for (const script of scripts) {
  test('parses ' + script.filename, () => {
    assert.doesNotThrow(() => new vm.Script(script.body, { filename: script.filename }));
  });
}
