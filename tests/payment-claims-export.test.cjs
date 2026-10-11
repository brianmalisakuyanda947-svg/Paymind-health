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
assert.notEqual(helperStart, -1, 'shared CSV helpers must exist');
assert.notEqual(helperEnd, -1, 'shared CSV helper boundary must exist');
const helperSource = html.slice(helperStart, helperEnd);

function extractFunction(name, nextName) {
  const start = html.indexOf('function ' + name + '(){');
  const end = html.indexOf('\nfunction ' + nextName, start);
  assert.notEqual(start, -1, name + ' must exist');
  assert.notEqual(end, -1, 'boundary after ' + name + ' must exist');
  return html.slice(start, end);
}

function runExport(fnName, nextName, collection, records, active = {
  hospital_id: 'hospital-a',
  role: 'finance_manager'
}) {
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
  const state = {
    active,
    invoices: [],
    payments: [],
    claims: []
  };
  state[collection] = records;
  const sandbox = {
    state,
    canManageExceptions: () => ['admin', 'finance_manager', 'finance_officer'].includes(active?.role),
    alert: message => alerts.push(message),
    Blob: TestBlob,
    URL: {
      createObjectURL: () => 'blob:test-export',
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
    helperSource + '\n' + extractFunction(fnName, nextName) +
      '\nthis.runExport = ' + fnName + ';',
    sandbox
  );
  sandbox.runExport();
  return { downloads, alerts, blob: savedBlob };
}

test('exports selected hospital payments with template-compatible columns', () => {
  const result = runExport('exportPaymentsCSV', 'exportClaimsCSV', 'payments', [
    {
      hospital_id: 'hospital-a',
      payment_ref: 'PAY-101',
      invoice_ref: 'INV-101',
      payment_date: '2026-10-10',
      amount: 5000,
      payer: 'Example Insurance',
      payment_method: 'Bank',
      bank_reference: 'BANK-1'
    },
    {
      hospital_id: 'hospital-b',
      payment_ref: 'PAY-OTHER',
      invoice_ref: 'INV-OTHER',
      payment_date: '2026-10-10',
      amount: 900,
      payer: 'Other Hospital',
      payment_method: 'Bank'
    }
  ]);
  const csv = result.blob.parts.join('');
  assert.equal(result.alerts.length, 0);
  assert.equal(result.downloads.length, 1);
  assert.match(result.downloads[0].download, /^paymind-payments-\d{4}-\d{2}-\d{2}\.csv$/);
  assert.ok(csv.includes('payment_ref,invoice_ref,payment_date,amount,payer,payment_method'));
  assert.ok(csv.includes('PAY-101,INV-101,2026-10-10,5000,Example Insurance,Bank'));
  assert.ok(!csv.includes('PAY-OTHER'));
});

test('neutralises spreadsheet formulas in payment export text', () => {
  const result = runExport('exportPaymentsCSV', 'exportClaimsCSV', 'payments', [{
    hospital_id: 'hospital-a',
    payment_ref: '=HYPERLINK("https://bad.example","click")',
    invoice_ref: 'INV-101',
    payment_date: '2026-10-10',
    amount: 500,
    payer: '+SUM(A1:A2)',
    payment_method: '@cmd'
  }]);
  const csv = result.blob.parts.join('');
  assert.ok(csv.includes('\'=HYPERLINK('));
  assert.ok(csv.includes("'+SUM(A1:A2)"));
  assert.ok(csv.includes("'@cmd"));
});

test('exports selected hospital claims with template-compatible columns', () => {
  const result = runExport('exportClaimsCSV', 'downloadTemplate', 'claims', [
    {
      hospital_id: 'hospital-a',
      claim_ref: 'CLM-101',
      invoice_ref: 'INV-101',
      payer: 'Example Insurance',
      submitted_date: '2026-10-09',
      amount: 15000,
      status: 'submitted',
      notes: 'not part of the import-template export'
    },
    {
      hospital_id: 'hospital-b',
      claim_ref: 'CLM-OTHER',
      invoice_ref: 'INV-OTHER',
      payer: 'Other Hospital',
      submitted_date: '2026-10-09',
      amount: 900,
      status: 'submitted'
    }
  ]);
  const csv = result.blob.parts.join('');
  assert.equal(result.alerts.length, 0);
  assert.equal(result.downloads.length, 1);
  assert.match(result.downloads[0].download, /^paymind-claims-\d{4}-\d{2}-\d{2}\.csv$/);
  assert.ok(csv.includes('claim_ref,invoice_ref,payer,submitted_date,amount,status'));
  assert.ok(csv.includes('CLM-101,INV-101,Example Insurance,2026-10-09,15000,submitted'));
  assert.ok(!csv.includes('CLM-OTHER'));
  assert.ok(!csv.includes('not part of the import-template export'));
});

test('prevents non-finance roles and empty collections from exporting', () => {
  const samplePayment = [{
    hospital_id: 'hospital-a',
    payment_ref: 'PAY-101',
    invoice_ref: 'INV-101',
    payment_date: '2026-10-10',
    amount: 5000,
    payer: 'Example Insurance',
    payment_method: 'Bank'
  }];
  const denied = runExport('exportPaymentsCSV', 'exportClaimsCSV', 'payments', samplePayment, {
    hospital_id: 'hospital-a',
    role: 'viewer'
  });
  assert.equal(denied.downloads.length, 0);
  assert.equal(denied.alerts.length, 1);

  const empty = runExport('exportClaimsCSV', 'downloadTemplate', 'claims', []);
  assert.equal(empty.downloads.length, 0);
  assert.equal(empty.alerts.length, 1);
});
