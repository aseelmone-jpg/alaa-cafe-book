const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const variants = [['app', path.join(root, 'public/index.html'), true]];

function harness(file, checkedSave, priorEntries = []) {
  const html = fs.readFileSync(file, 'utf8');
  const lines = html.split(/\r?\n/);
  const source = prefixes => prefixes.map(prefix => {
    const line = lines.find(item => item.startsWith(prefix));
    assert.ok(line, `Missing ${prefix} in ${file}`);
    return line;
  }).join('\n');
  const nodes = new Map();
  const node = selector => {
    if (!nodes.has(selector)) nodes.set(selector, {
      value: '', textContent: '', disabled: false, validationMessage: '', handlers: {},
      setCustomValidity(message) { this.validationMessage = message; },
      addEventListener(event, callback) { this.handlers[event] = callback; },
    });
    return nodes.get(selector);
  };
  const shop = { id: 'cafe-1', owner_id: 'owner-1', entries: priorEntries };
  const requests = [], alerts = [];
  const context = vm.createContext({
    $, Date, entries: shop.entries, dayDraftDirty: false, dayDraftVersion: null,
    signedInUser: { id: 'owner-1' }, currentShop: () => shop,
    accountingWritesBlocked: () => false, canUseFeature: () => true,
    realtimeReadSequence: 0, dayRow: row => ({ date: row.entry_date, sale: row.sale, upi: row.upi, purchase: row.purchase, otherExpense: row.other_expense, remarks: row.remarks, updatedAt: row.updated_at }),
    CafeAccounting: { validateEntry: entry => !entry.date ? 'Choose a date.' : '' },
    render() {}, window: { alert: message => alerts.push(message) },
    supabaseClient: {
      async rpc(name, payload) {
        requests.push({ name, payload });
        if (context.saveError) return { error: { message: 'Network error' } };
        return { data: { entry_date: payload.p_entry_date, sale: payload.p_sale, upi: payload.p_upi, purchase: payload.p_purchase, other_expense: payload.p_other_expense, remarks: payload.p_remarks, updated_at: 'new-version' }, error: null };
      },
      from(table) {
        assert.equal(table, 'day_entries');
        return { async upsert(payload) { requests.push({ table, payload }); return context.saveError ? { error: { message: 'Network error' } } : { error: null }; } };
      },
    },
  });
  function $(selector) { return node(selector); }
  vm.runInContext(source([
    'function dayDateDisplay(', 'function dayDateIso(', 'function resetDayEntryForm(', 'function syncEntryForm(',
    "$('#dayDateText').addEventListener('input'", "$('#date').addEventListener('change'", "$('#entryForm').addEventListener('submit'",
  ]), context);
  const fill = (date = '2026-10-21') => {
    node('#date').value = date;
    node('#dayDateText').value = context.dayDateDisplay(date);
    node('#sale').value = '100';
    node('#upi').value = '30';
    node('#purchase').value = '20';
    node('#otherExpense').value = '10';
    node('#remarks').value = 'staff tea';
  };
  const submit = async () => node('#entryForm').handlers.submit({ preventDefault() {}, submitter: node('#entrySubmit') });
  return { html, node, context, shop, requests, alerts, fill, submit, checkedSave };
}

for (const [name, file, checkedSave] of variants) {
  test(`${name}: DD/MM/YYYY input and calendar load the selected entry`, () => {
    const entry = { date: '2026-10-21', sale: 42, upi: 0, purchase: 0, otherExpense: 0, remarks: 'saved', updatedAt: 'old-version' };
    const h = harness(file, checkedSave, [entry]);
    assert.equal(h.context.dayDateIso('21/10/2026'), '2026-10-21');
    assert.equal(h.context.dayDateIso('29/02/2024'), '2024-02-29');
    assert.equal(h.context.dayDateIso('31/02/2026'), '');
    h.node('#dayDateText').value = '21102026';
    h.node('#dayDateText').handlers.input();
    assert.equal(h.node('#dayDateText').value, '21/10/2026');
    assert.equal(h.node('#date').value, '2026-10-21');
    assert.equal(h.node('#sale').value, 42);
    assert.equal(h.node('#entrySubmit').textContent, 'Update Day Entry');
    h.node('#date').value = '2026-11-02';
    h.node('#date').handlers.change();
    assert.equal(h.node('#dayDateText').value, '02/11/2026');
    assert.equal(h.node('#sale').value, 0);
    h.node('#dayDateText').value = '31022026';
    h.node('#dayDateText').handlers.input();
    assert.equal(h.node('#date').value, '');
    assert.match(h.node('#dayDateText').validationMessage, /valid date/);
    assert.match(h.html, /\$\('#dayDateText'\)\.value=dayDateDisplay\(\$\('#date'\)\.value\)/);
  });

  test(`${name}: successful create and update clear the form only after saving`, async () => {
    const h = harness(file, checkedSave);
    h.fill();
    await h.submit();
    assert.equal(h.requests.length, 1);
    assert.equal(h.requests[0].payload[checkedSave ? 'p_entry_date' : 'entry_date'], '2026-10-21');
    assert.equal(h.shop.entries.length, 1);
    assert.equal(h.node('#date').value, '');
    assert.equal(h.node('#dayDateText').value, '');
    for (const id of ['#sale', '#upi', '#purchase', '#otherExpense']) assert.equal(h.node(id).value, 0);
    assert.equal(h.node('#remarks').value, '');
    assert.equal(h.node('#entrySubmit').textContent, 'Add Day Entry +');

    h.node('#date').value = '2026-10-21';
    h.node('#date').handlers.change();
    h.node('#sale').value = '150';
    await h.submit();
    assert.equal(h.requests.length, 2);
    assert.equal(h.shop.entries.length, 1);
    assert.equal(h.shop.entries[0].sale, 150);
    assert.equal(h.node('#date').value, '');
    assert.equal(h.node('#sale').value, 0);
    if (checkedSave) assert.equal(h.context.dayDraftVersion, null);
  });

  test(`${name}: failed save leaves date and amounts for retry`, async () => {
    const h = harness(file, checkedSave);
    h.fill();
    h.context.saveError = true;
    await h.submit();
    assert.equal(h.requests.length, 1);
    assert.equal(h.node('#date').value, '2026-10-21');
    assert.equal(h.node('#dayDateText').value, '21/10/2026');
    assert.equal(h.node('#sale').value, '100');
    assert.equal(h.node('#remarks').value, 'staff tea');
    assert.match(h.alerts[0], /Network error/);
  });
}

test('local root and public HTML match exactly', () => {
  assert.ok(fs.readFileSync(path.join(root, 'index.html')).equals(fs.readFileSync(path.join(root, 'public/index.html'))));
});

