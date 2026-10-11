const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(
  path.join(__dirname, '..', 'PayMind_MVP_v2_1_58.html'),
  'utf8'
);
const start = html.indexOf('const jsargContent = v =>');
const end = html.indexOf('\nconst roleName', start);

assert.notEqual(start, -1, 'the app must define jsargContent');
assert.notEqual(end, -1, 'the helper must end before roleName');

const helperSource = html.slice(start, end).trim().replace(/;$/, '');
const sandbox = {};
vm.runInNewContext(helperSource + '\nthis.jsargContent = jsargContent;', sandbox);
const encode = sandbox.jsargContent;

test('escapes single quotes and backslashes inside JS string arguments', () => {
  assert.equal(encode("O'Brien"), "O\\'Brien");
  assert.equal(encode('name\\segment'), 'name\\\\segment');
  assert.equal(encode("');alert(1);//"), "\\');alert(1);//");
});

test('encodes HTML-sensitive characters for quoted attributes', () => {
  assert.equal(encode('A&B "West"'), 'A&amp;B &quot;West&quot;');
  assert.equal(encode('<img src=x onerror=alert(1)>'), '&lt;img src=x onerror=alert(1)&gt;');
});

test('escapes line breaks and Unicode line separators', () => {
  assert.equal(encode('line1\nline2'), 'line1\\nline2');
  assert.equal(encode('line1\rline2'), 'line1\\rline2');
  assert.equal(encode('a\u2028b'), 'a\\u2028b');
  assert.equal(encode('a\u2029b'), 'a\\u2029b');
});
