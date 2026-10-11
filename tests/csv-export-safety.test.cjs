const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const htmlPath = path.join(__dirname, '..', 'PayMind_MVP_v2_1_58.html');
const html = fs.readFileSync(htmlPath, 'utf8');
const start = html.indexOf('function csvSafeCell(value){');
const end = html.indexOf('\nfunction csvRows(rows)', start);

assert.notEqual(start, -1, 'the live app must define csvSafeCell');
assert.notEqual(end, -1, 'the live app must define csvRows after csvSafeCell');

const helperSource = html.slice(start, end);
const sandbox = {};
vm.runInNewContext(helperSource + '\nthis.csvSafeCell = csvSafeCell;', sandbox);
const csvSafeCell = sandbox.csvSafeCell;

test('neutralises common spreadsheet formula prefixes', () => {
  for (const value of ['=1+1', '+SUM(A1:A2)', '-CMD(1)', '@SUM(A1:A2)']) {
    assert.equal(csvSafeCell(value), "'" + value);
  }
});

test('neutralises whitespace-prefixed formulas and leading control characters', () => {
  assert.equal(csvSafeCell('  =1+1'), "'  =1+1");
  assert.equal(csvSafeCell('\t=1+1'), "'\t=1+1");
  assert.equal(csvSafeCell('\rReport'), "\"'\rReport\"");
});

test('preserves genuine numeric values including negative amounts', () => {
  assert.equal(csvSafeCell(-1250.5), '-1250.5');
  assert.equal(csvSafeCell('2500.00'), '2500.00');
});

test('retains correct CSV quoting for commas, quotes and newlines', () => {
  assert.equal(csvSafeCell('HealthPlus, "North"'), '"HealthPlus, ""North"""');
  assert.equal(csvSafeCell('line one\nline two'), '"line one\nline two"');
});

test('does not alter ordinary payer and reference values', () => {
  assert.equal(csvSafeCell('HealthPlus Insurance'), 'HealthPlus Insurance');
  assert.equal(csvSafeCell('INV-1001'), 'INV-1001');
});
