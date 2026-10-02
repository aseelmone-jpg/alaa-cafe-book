const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const accounting = require('../public/accounting.js');

const html = fs.readFileSync(path.join(__dirname, '../public/index.html'), 'utf8');
const accountDefaults = html.match(/const defaultJournalAccounts=(\[[^;]+\]);/);
assert.ok(accountDefaults, 'Missing journal account choices');
const uiFunctions = html.slice(
  html.indexOf('function render(){'),
  html.indexOf("$('#shopSelect').addEventListener('change',()=>{editingVoucherId"),
);
const listener = prefix => {
  const line = html.split(/\r?\n/).find(item => item.startsWith(prefix));
  assert.ok(line, 'Missing application listener: ' + prefix);
  return line;
};
const copy = value => JSON.parse(JSON.stringify(value));

function createUi({ admin = true, shops } = {}) {
  const nodes = new Map();
  const getNode = selector => {
    if (!nodes.has(selector)) {
      const classes = new Set(['#journalApp', '#categoryTable', '#otherText'].includes(selector) ? ['hide'] : []);
      const node = {
        value: '', textContent: '', innerHTML: '', disabled: false, handlers: {},
        classList: {
          add: name => classes.add(name),
          remove: name => classes.delete(name),
          contains: name => classes.has(name),
          toggle(name, force) {
            const enabled = force === undefined ? !classes.has(name) : force;
            if (enabled) classes.add(name); else classes.delete(name);
            return enabled;
          },
        },
        addEventListener(event, handler) { this.handlers[event] = handler; },
      };
      nodes.set(selector, node);
    }
    return nodes.get(selector);
  };
  getNode('#date').value = '2026-10-01';
  getNode('#voucherDate').value = '2026-10-01';
  const tabs = ['Day Book', 'Sales', 'Purchases', 'Expenses', 'UPI Account', 'Journal Entry', 'Cash', 'Ledgers', 'Reports & P&L'].map(name => {
    const tab = getNode('tab:' + name);
    tab.dataset = { tab: name };
    return tab;
  });
  const alerts = [], requests = [];
  const shopData = { shops: copy(shops || [{ id: 'cafe-1', owner_id: 'admin-1', entries: [], journalVouchers: [], journalAccountOptions: [] }]) };
  let context;
  context = vm.createContext({
    CafeAccounting: accounting,
    $: getNode,
    money: accounting.formatMoney,
    escapeText: value => String(value).replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character])),
    shopData, activeShopId: shopData.shops[0].id, entries: shopData.shops[0].entries,
    currentShop: () => shopData.shops.find(shop => shop.id === context.activeShopId),
    isAdmin: () => context.signedInUser?.app_metadata?.role === 'admin',
    signedInUser: { id: admin ? 'admin-1' : 'user-1', app_metadata: { role: admin ? 'admin' : 'user' } },
    activeCategoryView: 'Day Book',
    userFeatureAccess: { reportsPnl: true },
    defaultJournalAccounts: vm.runInNewContext(accountDefaults[1]),
    journalStorageReady: true,
    localStorage: { setItem() {} }, STORE_KEY: 'test-cafes',
    window: { alert: message => alerts.push(message), confirm: () => true },
    document: { querySelector: getNode, querySelectorAll: selector => selector === '.tabs .tab' ? tabs : [] },
    updateShopUI() {}, syncEntryForm() {}, loadUserFeatureAccess() {}, startRealtimeSync() {},
    supabaseClient: {
      from(table) {
        const request = { table };
        requests.push(request);
        const readResult = () => {
          const shop = shopData.shops.find(item => item.id === context.activeShopId);
          const data = table === 'day_entries'
            ? shop.entries.map(entry => ({ entry_date: entry.date, sale: entry.sale, upi: entry.upi, purchase: entry.purchase, other_expense: entry.otherExpense, remarks: entry.remarks }))
            : table === 'journal_vouchers'
              ? (shop.journalVouchers || []).map(voucher => ({ id: voucher.id, voucher_no: voucher.voucherNo, voucher_date: voucher.date, remark: voucher.remark, lines: copy(voucher.lines) }))
              : shop.journalAccountOptions || [];
          return { data, error: null };
        };
        const query = {
          update(payload) { request.action = 'update'; request.payload = payload; return this; },
          insert(payload) { request.action = 'insert'; request.payload = payload; return this; },
          delete() { request.action = 'delete'; return this; },
          eq() { return this; }, select() { return this; },
          async order() { return readResult(); },
          then(resolve, reject) { return Promise.resolve(readResult()).then(resolve, reject); },
          async single() { return { data: { id: 'voucher-1', ...copy(request.payload) }, error: null }; },
        };
        return query;
      },
    },
  });
  vm.runInContext(uiFunctions, context, { filename: 'actual journal UI functions' });
  for (const prefix of [
    "document.querySelector('.tabs').addEventListener('click'",
    "$('#shopSelect').addEventListener('change',e=>",
    "$('#journalLineRows').addEventListener('input',e=>",
    "$('#journalLineRows').addEventListener('change',e=>",
    "$('#journalSave').addEventListener('click'",
    "$('#journalVoucherList').addEventListener('click'",
    "$('#journalReset').addEventListener('click'",
    'async function refreshCafeFromRealtime(',
  ]) vm.runInContext(listener(prefix), context, { filename: 'actual application listener' });
  return {
    context, getNode, shopData, alerts, requests,
    run: source => vm.runInContext(source, context),
    selectTab(name) {
      const tab = tabs.find(item => item.dataset.tab === name);
      assert.ok(tab);
      getNode('.tabs').handlers.click({ target: { closest: () => tab } });
    },
  };
}

test('Bank to Cash selection records source and destination and updates the dashboard', async () => {
  const ui = createUi();
  ui.selectTab('Journal Entry');
  assert.match(ui.getNode('#journalLineRows').innerHTML, /<option value="Bank"\s*>Bank<\/option>/);
  const rows = ui.getNode('#journalLineRows');
  rows.handlers.change({ target: { dataset: { journalField: 'side', journalIndex: '0' }, value: 'credit' } });
  assert.deepEqual(Array.from(ui.run('journalDraftLines.map(line=>line.side)')), ['credit', 'debit']);
  for (const [index, account, side] of [[0, 'Bank', 'credit'], [1, 'Cash', 'debit']]) {
    rows.handlers.change({ target: { dataset: { journalField: 'particulars', journalIndex: String(index) }, value: account } });
    rows.handlers.input({ target: { dataset: { journalField: 'amount', journalIndex: String(index), journalSide: side }, value: '125.50' } });
  }
  await ui.getNode('#journalSave').handlers.click();
  assert.deepEqual(ui.alerts, []);
  assert.deepEqual(copy(ui.requests[0].payload.lines), [
    { side: 'credit', particulars: 'Bank', amount: 125.50, transferRole: 'source' },
    { side: 'debit', particulars: 'Cash', amount: 125.50, transferRole: 'destination' },
  ]);
  assert.equal(ui.getNode('#cashTotal').textContent, '₹125.50');
  assert.deepEqual(accounting.voucherPostings(ui.shopData.shops[0].journalVouchers).map(p => [p.account, p.balanceChange]), [['Bank', -125.50], ['Cash', 125.50]]);
});

test('UPI to Cash and Cash to UPI both update the dashboard immediately', async () => {
  for (const [source, destination] of [['UPI Account', 'Cash'], ['Cash', 'UPI Account']]) {
    const ui = createUi();
    ui.selectTab('Journal Entry');
    const rows = ui.getNode('#journalLineRows');
    rows.handlers.change({ target: { dataset: { journalField: 'side', journalIndex: '0' }, value: 'credit' } });
    for (const [index, account, side] of [[0, source, 'credit'], [1, destination, 'debit']]) {
      rows.handlers.change({ target: { dataset: { journalField: 'particulars', journalIndex: String(index) }, value: account } });
      rows.handlers.input({ target: { dataset: { journalField: 'amount', journalIndex: String(index), journalSide: side }, value: '100' } });
    }
    await ui.getNode('#journalSave').handlers.click();
    assert.deepEqual(ui.alerts, []);
    const postings = accounting.voucherPostings(ui.shopData.shops[0].journalVouchers);
    assert.deepEqual(postings.map(p => [p.account, p.balanceChange]), [[source, -100], [destination, 100]]);
    assert.equal(ui.getNode('#cashTotal').textContent, source === 'Cash' ? '₹-100' : '₹100');
    assert.equal(ui.getNode('#upiTotal').textContent, source === 'UPI Account' ? '₹-100' : '₹100');
    assert.deepEqual(accounting.totals([], ui.shopData.shops[0].journalVouchers), { sales: 0, upi: source === 'UPI Account' ? -100 : 100, purchases: 0, expenses: 0 });
  }
});

test('leaving Journal Entry hides its form on every other section', () => {
  const ui = createUi();
  for (const section of ['Sales', 'Purchases', 'Expenses', 'UPI Account', 'Cash', 'Ledgers', 'Reports & P&L']) {
    ui.selectTab('Journal Entry');
    assert.equal(ui.getNode('#journalApp').classList.contains('hide'), false);
    ui.selectTab(section);
    assert.equal(ui.getNode('#journalApp').classList.contains('hide'), true, section + ' must not retain the Journal form');
  }
});

test('P&L stays visible and recomputes journal adjustments on rerender', () => {
  const ui = createUi({ shops: [{ id: 'cafe-1', entries: [{ date: '2026-10-01', sale: 100, upi: 40, purchase: 20, otherExpense: 5 }], journalVouchers: [{ id: 'voucher-1', voucherNo: 1, date: '2026-10-01', lines: [{ side: 'debit', particulars: 'Cash', amount: 10 }, { side: 'credit', particulars: 'Sales', amount: 10 }] }] }] });
  ui.selectTab('Reports & P&L');
  assert.equal(ui.getNode('#otherText').textContent, 'Sales ₹110 · Expenses ₹25 · Profit ₹85');
  ui.shopData.shops[0].entries[0].sale = 130;
  ui.run('render()');
  assert.equal(ui.getNode('#otherText').classList.contains('hide'), false);
  assert.equal(ui.getNode('#otherText').textContent, 'Sales ₹140 · Expenses ₹25 · Profit ₹115');
});

test('switching cafes refreshes the active P&L from that cafe data', () => {
  const ui = createUi({ shops: [
    { id: 'cafe-1', entries: [{ date: '2026-10-01', sale: 100, purchase: 20 }], journalVouchers: [] },
    { id: 'cafe-2', entries: [{ date: '2026-10-01', sale: 250, purchase: 50, otherExpense: 10 }], journalVouchers: [] },
  ] });
  ui.selectTab('Reports & P&L');
  ui.getNode('#shopSelect').handlers.change({ target: { value: 'cafe-2' } });
  assert.equal(ui.getNode('#otherText').classList.contains('hide'), false);
  assert.equal(ui.getNode('#otherText').textContent, 'Sales ₹250 · Expenses ₹60 · Profit ₹190');
});

test('only admins see voucher deletion, and the user action handler still rejects it', async () => {
  const voucher = { id: 'voucher-1', voucherNo: 1, date: '2026-10-01', lines: [{ side: 'debit', particulars: 'Cash', amount: 10 }, { side: 'credit', particulars: 'Sales', amount: 10 }] };
  for (const admin of [true, false]) {
    const ui = createUi({ admin, shops: [{ id: 'cafe-1', entries: [], journalVouchers: [voucher] }] });
    ui.selectTab('Journal Entry');
    assert.equal(ui.getNode('#journalVoucherList').innerHTML.includes('data-delete-voucher'), admin);
    assert.equal(ui.getNode('#journalVoucherList').innerHTML.includes('data-edit-voucher'), true);
    if (!admin) {
      await ui.getNode('#journalVoucherList').handlers.click({ target: { closest: selector => selector === '[data-delete-voucher]' ? { dataset: { deleteVoucher: 'voucher-1' } } : null } });
      assert.deepEqual(ui.alerts, ['Only an admin can delete journal vouchers.']);
      assert.equal(ui.requests.length, 0);
    }
  }
});

test('actual voucher edit/save preserves stored sides and clears the successful saved draft', async () => {
  const examples = [
    [{ side: 'debit', particulars: 'Cash', amount: 50 }, { side: 'credit', particulars: 'Sales', amount: 50 }],
    [{ side: 'debit', particulars: 'Cash', amount: 40 }, { side: 'debit', particulars: 'Purchases', amount: 10 }, { side: 'credit', particulars: 'Sales', amount: 50 }],
    [{ side: 'credit', particulars: 'Sales', amount: 50 }, { side: 'debit', particulars: 'Cash', amount: 20 }, { side: 'debit', particulars: 'Purchases', amount: 30 }],
    [{ side: 'debit', particulars: 'Cash', amount: 20 }, { side: 'credit', particulars: 'Sales', amount: 10 }, { side: 'debit', particulars: 'Purchases', amount: 5 }, { side: 'credit', particulars: 'Sales', amount: 15 }],
  ];
  for (const lines of examples) {
    const voucher = { id: 'voucher-1', voucherNo: 1, date: '2026-10-01', remark: 'Existing voucher', lines };
    const ui = createUi({ shops: [{ id: 'cafe-1', entries: [], journalVouchers: [voucher] }] });
    ui.selectTab('Journal Entry');
    ui.run('loadJournalVoucher(currentShop().journalVouchers[0])');
    await ui.getNode('#journalSave').handlers.click();
    assert.deepEqual(ui.alerts, []);
    assert.deepEqual(copy(ui.requests[0].payload.lines), lines);
    assert.equal(ui.requests[0].action, 'update');
    assert.equal(ui.run('editingVoucherId'), null);
    assert.equal(ui.run("journalDraftLines.every(line=>line.amount===''&&line.particulars==='')"), true);
    assert.equal(ui.getNode('#journalRemark').value, '');
  }
});

test('legacy UPI to Cash voucher keeps its old effect on unchanged save and adopts corrected roles when edited', async () => {
  const lines = [{ side: 'credit', particulars: 'Cash', amount: 100 }, { side: 'debit', particulars: 'UPI Account', amount: 100 }];
  const ui = createUi({ shops: [{ id: 'cafe-1', entries: [], journalVouchers: [{ id: 'voucher-1', voucherNo: 1, date: '2026-10-02', lines }] }] });
  ui.selectTab('Journal Entry');
  ui.run('loadJournalVoucher(currentShop().journalVouchers[0])');
  assert.deepEqual(Array.from(ui.run('journalDraftLines.map(line=>line.side)')), ['debit', 'credit']);
  await ui.getNode('#journalSave').handlers.click();
  assert.deepEqual(copy(ui.requests[0].payload.lines), lines);
  assert.equal(ui.getNode('#cashTotal').textContent, '₹100');
  assert.equal(ui.getNode('#upiTotal').textContent, '₹-100');
  ui.run('loadJournalVoucher(currentShop().journalVouchers[0])');
  const rows = ui.getNode('#journalLineRows');
  rows.handlers.input({ target: { dataset: { journalField: 'amount', journalIndex: '0', journalSide: 'debit' }, value: '150' } });
  rows.handlers.input({ target: { dataset: { journalField: 'amount', journalIndex: '1', journalSide: 'credit' }, value: '150' } });
  await ui.getNode('#journalSave').handlers.click();
  assert.deepEqual(copy(ui.requests[1].payload.lines), [
    { side: 'debit', particulars: 'Cash', amount: 150, transferRole: 'destination' },
    { side: 'credit', particulars: 'UPI Account', amount: 150, transferRole: 'source' },
  ]);
  assert.equal(ui.getNode('#cashTotal').textContent, '₹150');
  assert.equal(ui.getNode('#upiTotal').textContent, '₹-150');
  const effective = accounting.voucherPostings([{ date: '2026-10-02', lines }]);
  assert.deepEqual(effective.map(p => [p.account, p.debit, p.credit]), [['Cash', 100, 0], ['UPI Account', 0, 100]]);
});

test('cancel, edit, reverse, and delete replace or remove the old dashboard effect', async () => {
  const ui = createUi();
  ui.selectTab('Journal Entry');
  const rows = ui.getNode('#journalLineRows');
  rows.handlers.change({ target: { dataset: { journalField: 'side', journalIndex: '0' }, value: 'credit' } });
  const fill = (source, destination, amount) => {
    for (const [index, account, side] of [[0, source, 'credit'], [1, destination, 'debit']]) {
      rows.handlers.change({ target: { dataset: { journalField: 'particulars', journalIndex: String(index) }, value: account } });
      rows.handlers.input({ target: { dataset: { journalField: 'amount', journalIndex: String(index), journalSide: side }, value: String(amount) } });
    }
  };
  fill('UPI Account', 'Cash', 100);
  await ui.getNode('#journalSave').handlers.click();
  assert.equal(ui.getNode('#cashTotal').textContent, '₹100');
  assert.equal(ui.getNode('#upiTotal').textContent, '₹-100');
  ui.run('loadJournalVoucher(currentShop().journalVouchers[0])');
  fill('Cash', 'UPI Account', 75);
  ui.getNode('#journalReset').handlers.click();
  assert.deepEqual(Array.from(ui.run('journalDraftLines.map(line=>line.particulars)')), ['UPI Account', 'Cash']);
  assert.equal(ui.getNode('#cashTotal').textContent, '₹100');
  fill('Cash', 'UPI Account', 75);
  await ui.getNode('#journalSave').handlers.click();
  assert.equal(ui.requests.at(-1).action, 'update');
  assert.equal(ui.shopData.shops[0].journalVouchers.length, 1);
  assert.equal(ui.getNode('#cashTotal').textContent, '₹-75');
  assert.equal(ui.getNode('#upiTotal').textContent, '₹75');
  await ui.getNode('#journalVoucherList').handlers.click({ target: { closest: selector => selector === '[data-delete-voucher]' ? { dataset: { deleteVoucher: 'voucher-1' } } : null } });
  assert.equal(ui.requests.at(-1).action, 'delete');
  assert.equal(ui.shopData.shops[0].journalVouchers.length, 0);
  assert.equal(ui.getNode('#cashTotal').textContent, '₹0');
  assert.equal(ui.getNode('#upiTotal').textContent, '₹0');
});

test('rerender and realtime preserve unsaved voucher date and remark edits', async () => {
  const voucher = { id: 'voucher-1', voucherNo: 1, date: '2026-10-01', remark: 'Stored remark', lines: [{ side: 'debit', particulars: 'Cash', amount: 10 }, { side: 'credit', particulars: 'Sales', amount: 10 }] };
  const ui = createUi({ shops: [{ id: 'cafe-1', entries: [], journalVouchers: [voucher] }] });
  ui.selectTab('Journal Entry');
  ui.run('loadJournalVoucher(currentShop().journalVouchers[0])');
  assert.equal(ui.getNode('#voucherDate').value, '2026-10-01');
  assert.equal(ui.getNode('#journalRemark').value, 'Stored remark');
  for (const [date, remark] of [['2026-10-02', 'Unsaved edit'], ['', '']]) {
    ui.getNode('#voucherDate').value = date;
    ui.getNode('#journalRemark').value = remark;
    ui.run('render()');
    assert.equal(ui.getNode('#voucherDate').value, date);
    assert.equal(ui.getNode('#journalRemark').value, remark);
    await ui.run("refreshCafeFromRealtime('cafe-1')");
    assert.equal(ui.getNode('#voucherDate').value, date);
    assert.equal(ui.getNode('#journalRemark').value, remark);
  }
});
