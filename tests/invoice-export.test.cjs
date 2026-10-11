const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(
  path.join(__dirname, '..', 'PayMind_MVP_v2_1_58.html'),
  'utf8'
);
const helperStart = html.indexOf('function csvSafeCell(value){');
const helperEnd = html.indexOf('\nconst jsargContent = v =>', helperStart);
const exportStart = html.indexOf('function exportInvoicesCSV(){');
const exportEnd = html.indexOf('\nfunction downloadTemplate(type)', exportStart);

assert.notEqual(helperStart, -1, 'CSV safety helper must exist');
assert.notEqual(helperEnd, -1, 'CSV helper block must have an end marker');
assert.notEqual(exportStart, -1, 'invoice export function must exist');
assert.notEqual(exportEnd, -1, 'invoice export function must have an end marker');

const helperSource = html.slice(helperStart, helperEnd);
const exportSource = html.slice(exportStart, exportEnd);

function runExport(invoices, active = { hospital_id: 'hospital-a', role: 'finance_manager' }) {
  const downloads = [];
  const alerts = [];
  let savedBlob = null;
  const anchor = {
    href: '',
    download: '',
    style: {},
    click() {
      downloads.push({ href: this.href, download: this.download });
    },
    remove() {}
  };
  class TestBlob {
    constructor(parts, options) {
      this.parts = parts;
      this.type = options.type;
      savedBlob = this;
    }
  }
  const sandbox = {
    state: { active, invoices },
    canManageExceptions: () => ['admin', 'finance_manager', 'finance_officer'].includes(active?.role),
    alert: message => alerts.push(message),
    Blob: TestBlob,
    URL: {
      createObjectURL: () => 'blob:test-invoices',
      revokeObjectURL: () => {}
    },
    document: {
      body: { appendChild() {} },
      createElement: () => anchor
    },
    window: { setTimeout: callback => { callback(); return 1; } },
    Date
  };
  vm.runInNewContext(
    helperSource + '\n' + exportSource +
    '\nthis.exportInvoicesCSV = exportInvoicesCSV;',
    sandbox
  );
  sandbox.exportInvoicesCSV();
  return { downloads, alerts, blob: savedBlob };
}

test('exports the selected workspace invoices with template-compatible columns', () => {
  const result = runExport([{
    hospital_id: 'hospital-a',
    invoice_ref: 'INV-101',
    invoice_date: '2026-10-10',
    amount: 15000,
    payer: 'Example Insurance',
    department: 'Outpatient',
    status: 'open'
  }]);

  assert.equal(result.alerts.length, 0);
  assert.equal(result.downloads.length, 1);
  assert.match(result.downloads[0].download, /^paymind-invoices-\d{4}-\d{2}-\d{2}\.csv$/);
  assert.equal(result.blob.type, 'text/csv;charset=utf-8;');
  const csv = result.blob.parts.join('');
  assert.ok(csv.startsWith('\uFEFF'));
  assert.ok(csv.includes('invoice_ref,invoice_date,amount,payer,department,status'));
  assert.ok(csv.includes('INV-101,2026-10-10,15000,Example Insurance,Outpatient,open'));
});

test('neutralises formula-like invoice references in the actual export', () => {
  const result = runExport([{
    hospital_id: 'hospital-a',
    invoice_ref: '=HYPERLINK("https://bad.example","click")',
    invoice_date: '2026-10-10',
    amount: 250,
    payer: '+SUM(A1:A2)',
    department: '@cmd',
    status: 'open'
  }]);
  const csv = result.blob.parts.join('');
  assert.ok(csv.includes('\'=HYPERLINK('));
  assert.ok(csv.includes("'+SUM(A1:A2)"));
  assert.ok(csv.includes("'@cmd"));
});

test('does not download when no workspace is selected or no invoices are loaded', () => {
  const noWorkspace = runExport([], null);
  assert.equal(noWorkspace.downloads.length, 0);
  assert.equal(noWorkspace.alerts.length, 1);

  const noInvoices = runExport([]);
  assert.equal(noInvoices.downloads.length, 0);
  assert.equal(noInvoices.alerts.length, 1);
});


test('exports only invoices from the selected hospital', () => {
  const result = runExport([
    {
      hospital_id: 'hospital-a',
      invoice_ref: 'INV-OWN',
      invoice_date: '2026-10-10',
      amount: 10,
      payer: 'Own Hospital',
      department: 'Outpatient',
      status: 'open'
    },
    {
      hospital_id: 'hospital-b',
      invoice_ref: 'INV-OTHER',
      invoice_date: '2026-10-10',
      amount: 99,
      payer: 'Other Hospital',
      department: 'Outpatient',
      status: 'open'
    }
  ]);
  const csv = result.blob.parts.join('');
  assert.ok(csv.includes('INV-OWN'));
  assert.ok(!csv.includes('INV-OTHER'));
});

test('prevents non-finance roles from exporting invoices', () => {
  const result = runExport([{
    hospital_id: 'hospital-a',
    invoice_ref: 'INV-101',
    invoice_date: '2026-10-10',
    amount: 15000,
    payer: 'Example Insurance',
    department: 'Outpatient',
    status: 'open'
  }], { hospital_id: 'hospital-a', role: 'viewer' });

  assert.equal(result.downloads.length, 0);
  assert.equal(result.alerts.length, 1);
});
