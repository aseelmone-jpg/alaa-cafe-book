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
    CafeAccounting: accounting, crypto:{randomUUID:()=> 'voucher-1'},journalRequest:null,
    $: getNode,
    money: accounting.formatMoney,
    escapeText: value => String(value).replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character])),
    shopData, activeShopId: shopData.shops[0].id, entries: shopData.shops[0].entries,
    currentShop: () => shopData.shops.find(shop => shop.id === context.activeShopId),
    isAdmin: () => context.signedInUser?.app_metadata?.role === 'admin',
    signedInUser: { id: admin ? 'admin-1' : 'user-1', app_metadata: { role: admin ? 'admin' : 'user' } },
    activeCategoryView: 'Day Book',
    userFeatureAccess: { dayBook:true,sales:true,purchases:true,expenses:true,upiAccount:true,journalEntry:true,cash:true,ledgers:true,reportsPnl: true, addCafe: false, manageAccounts: false },
    featureAccessCafeId: 'cafe-1',
    defaultJournalAccounts: vm.runInNewContext(accountDefaults[1]),
    journalStorageReady: true, realtimeGeneration: 0, realtimeReadSequence: 0, dayDraftDirty: false, dayDraftVersion: null, journalEditVersion: null,
    localStorage: { setItem() {} }, STORE_KEY: 'test-cafes',
    window: { alert: message => alerts.push(message), confirm: () => true },
    document: { querySelector: getNode, querySelectorAll: selector => selector === '.tabs .tab' ? tabs : [] },
    updateShopUI() {}, syncEntryForm() {}, loadUserFeatureAccess() {}, startRealtimeSync() {},
    supabaseClient: {
      async rpc(name, args) {
        const shop=shopData.shops.find(item=>item.id===context.activeShopId);
        if(name==='cafe_accounting_snapshot')return {error:null,data:{day_entries:shop.entries.map(e=>({id:e.id,updated_at:e.updatedAt,entry_date:e.date,sale:e.sale,upi:e.upi,purchase:e.purchase,other_expense:e.otherExpense,remarks:e.remarks})),journal_vouchers:(shop.journalVouchers||[]).map(v=>({id:v.id,updated_at:v.updatedAt,voucher_no:v.voucherNo,voucher_date:v.date,remark:v.remark,lines:copy(v.lines),voided_at:v.voidedAt,voided_by:v.voidedBy})),journal_account_options:shop.journalAccountOptions||[]}};
        assert.equal(name,'save_journal_voucher_checked');
        const savedPrior=shop.journalVouchers.find(v=>v.id===args.p_id);const payload={cafe_id:args.p_cafe_id,voucher_no:savedPrior?savedPrior.voucherNo:Math.max(0,...shop.journalVouchers.map(v=>v.voucherNo))+1,voucher_date:args.p_voucher_date,remark:args.p_remark,lines:copy(args.p_lines)};
        requests.push({table:'journal_vouchers',action:savedPrior?'update':'insert',payload,args});
        if(context.rpcSaveError)return {error:{message:context.rpcSaveError},data:null};
        return {error:null,data:{...payload,id:args.p_id||'voucher-1',updated_at:'2026-10-06T00:00:00Z'}};
      },
      from(table) {
        const request = { table };
        requests.push(request);
        const readResult = () => {
          const shop = shopData.shops.find(item => item.id === context.activeShopId);
          const data = table === 'day_entries'
            ? shop.entries.map(entry => ({ entry_date: entry.date, sale: entry.sale, upi: entry.upi, purchase: entry.purchase, other_expense: entry.otherExpense, remarks: entry.remarks }))
            : table === 'journal_vouchers'
              ? (shop.journalVouchers || []).map(voucher => ({ id: voucher.id, voucher_no: voucher.voucherNo, voucher_date: voucher.date, remark: voucher.remark, lines: copy(voucher.lines), voided_at: voucher.voidedAt || null, voided_by: voucher.voidedBy || null }))
              : shop.journalAccountOptions || [];
          return { data, error: null };
        };
        const query = {
          update(payload) { request.action = 'update'; request.payload = payload; return this; },
          insert(payload) { request.action = 'insert'; request.payload = payload; return this; },
          delete() { request.action = 'delete'; return this; },
          eq() { return this; }, is() { return this; }, select() { return this; },
          async order() { return readResult(); },
          then(resolve, reject) { return Promise.resolve(readResult()).then(resolve, reject); },
          async single() {
            const prior = shopData.shops.find(item => item.id === context.activeShopId).journalVouchers.find(item => item.id === 'voucher-1') || {};
            const payload = request.payload || {};
            return { data: {
              id: 'voucher-1', voucher_no: payload.voucher_no ?? prior.voucherNo,
              voucher_date: payload.voucher_date ?? prior.date, remark: payload.remark ?? prior.remark,
              lines: payload.lines ? copy(payload.lines) : copy(prior.lines || []),
              voided_at: Object.hasOwn(payload, 'voided_at') ? payload.voided_at : prior.voidedAt || null,
              voided_by: Object.hasOwn(payload, 'voided_by') ? payload.voided_by : prior.voidedBy || null,
            }, error: null };
          },
        };
        return query;
      },
    },
  });
  vm.runInContext(listener('function canUseManagementFeature('), context);
  for(const prefix of ['function canUseFeature(', 'function dayRow(', 'function voucherRow('])vm.runInContext(listener(prefix),context);
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

test('only admins see voucher voiding, and the user action handler still rejects it', async () => {
  const voucher = { id: 'voucher-1', voucherNo: 1, date: '2026-10-01', lines: [{ side: 'debit', particulars: 'Cash', amount: 10 }, { side: 'credit', particulars: 'Sales', amount: 10 }] };
  for (const admin of [true, false]) {
    const ui = createUi({ admin, shops: [{ id: 'cafe-1', entries: [], journalVouchers: [voucher] }] });
    ui.selectTab('Journal Entry');
    assert.equal(ui.getNode('#journalVoucherList').innerHTML.includes('data-delete-voucher'), admin);
    assert.equal(ui.getNode('#journalVoucherList').innerHTML.includes('data-edit-voucher'), true);
    if (!admin) {
      await ui.getNode('#journalVoucherList').handlers.click({ target: { closest: selector => selector === '[data-delete-voucher]' ? { dataset: { deleteVoucher: 'voucher-1' } } : null } });
      assert.deepEqual(ui.alerts, ['Only an admin can void journal vouchers.']);
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

test('cancel, edit, reverse, and void replace or remove the old dashboard effect without deleting history', async () => {
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
  assert.equal(ui.requests.at(-1).action, 'update');
  assert.ok(ui.requests.at(-1).payload.voided_at);
  assert.equal(ui.shopData.shops[0].journalVouchers.length, 1);
  assert.ok(ui.shopData.shops[0].journalVouchers[0].voidedAt);
  assert.equal(ui.getNode('#journalVoucherList').innerHTML, '<div class="journal-balance">No active vouchers for this cafe yet.</div>');
  assert.equal(ui.shopData.shops[0].journalVouchers.length, 1, 'voided voucher remains in the stored history');
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


test('realtime preserves dirty Day Book fields and the original edit version',async()=>{
 const ui=createUi();ui.context.dayDraftDirty=true;ui.context.dayDraftVersion='original-version';
 ui.getNode('#sale').value='777';ui.getNode('#remarks').value='Unfinished';
 let syncCalls=0;ui.context.syncEntryForm=()=>{syncCalls++;ui.getNode('#sale').value='0'};
 await ui.run("refreshCafeFromRealtime('cafe-1')");
 assert.equal(syncCalls,0);assert.equal(ui.getNode('#sale').value,'777');assert.equal(ui.getNode('#remarks').value,'Unfinished');assert.equal(ui.context.dayDraftVersion,'original-version');
});

test('editing sends the version captured on open and a conflict preserves the draft',async()=>{
 const ui=createUi({shops:[{id:'cafe-1',owner_id:'admin-1',entries:[],journalAccountOptions:[],journalVouchers:[{id:'voucher-1',voucherNo:1,date:'2026-10-01',updatedAt:'original',lines:[{side:'debit',particulars:'Cash',amount:100,transferRole:'destination'},{side:'credit',particulars:'UPI Account',amount:100,transferRole:'source'}]}]}]});
 ui.run('loadJournalVoucher(currentShop().journalVouchers[0])');
 ui.shopData.shops[0].journalVouchers[0].updatedAt='newer';
 ui.context.rpcSaveError='This voucher changed elsewhere';
 ui.getNode('#journalRemark').value='keep this draft';
 await ui.getNode('#journalSave').handlers.click();
 assert.equal(ui.requests[0].args.p_expected_updated_at,'original');
 assert.equal(ui.getNode('#journalRemark').value,'keep this draft');
 assert.equal(ui.run('editingVoucherId'),'voucher-1');assert.match(ui.alerts[0],/changed elsewhere/);
});

test('the cache persists only the selected cafe ID, never financial records',()=>{
 const ui=createUi();let stored;ui.context.localStorage.setItem=(key,value)=>{stored=JSON.parse(value)};
 ui.run('render()');assert.deepEqual(stored,{activeId:'cafe-1'});
 assert.doesNotMatch(html,/localStorage\.getItem\(LEGACY_KEY/);
 assert.match(html,/alaa-cafes-v2:/);
});

test('a user without a feature-settings row receives the existing defaults after access loads',async()=>{
 const defaults=vm.runInNewContext('('+html.match(/const featureDefaults=([^;]+);/)[1]+')');
 const context={currentShop:()=>({id:'cafe-1'}),signedInUser:{id:'user-1'},featureDefaults:defaults,isAdmin:()=>false,setRoleAccess(){},supabaseClient:{from:()=>({select(){return this},eq(){return this},async maybeSingle(){return {data:null,error:null}}})}};
 vm.runInNewContext(listener('async function loadUserFeatureAccess('),context);
 await context.loadUserFeatureAccess();assert.equal(context.userFeatureAccess.dayBook,true);assert.equal(context.userFeatureAccess.journalEntry,true);assert.equal(context.userFeatureAccess.addCafe,false);assert.equal(context.featureAccessCafeId,'cafe-1');
});

test('an old realtime response is discarded after account changes',async()=>{
 const ui=createUi();let resolve;ui.context.supabaseClient.rpc=()=>new Promise(done=>{resolve=done});
 const refresh=ui.run("refreshCafeFromRealtime('cafe-1')");
 ui.context.signedInUser={id:'different-user',app_metadata:{role:'user'}};
 resolve({error:null,data:{day_entries:[{entry_date:'2026-10-06',sale:999}],journal_vouchers:[],journal_account_options:[]}});await refresh;
 assert.deepEqual(ui.shopData.shops[0].entries,[]);
});

test('a disabled Journal Entry feature rejects writes before an API call',async()=>{
 const ui=createUi({admin:false});ui.context.userFeatureAccess.journalEntry=false;
 await ui.getNode('#journalSave').handlers.click();assert.equal(ui.requests.length,0);assert.match(ui.alerts[0],/not enabled/);
});

test('rerender cannot reopen a report after that feature is disabled',()=>{
 const ui=createUi({admin:false});ui.selectTab('Reports & P&L');
 ui.context.userFeatureAccess.reportsPnl=false;ui.run('render()');
 assert.equal(ui.getNode('#pnlReport').classList.contains('hide'),true);
 assert.match(ui.getNode('#otherText').textContent,/not enabled/);
});

test('delegated management actions require an explicit true flag for the current cafe', () => {
  const ui = createUi({ admin: false });
  assert.equal(ui.run("canUseManagementFeature('addCafe')"), false);
  assert.equal(ui.run("canUseManagementFeature('manageAccounts')"), false);
  ui.context.userFeatureAccess.addCafe = true;
  ui.context.userFeatureAccess.manageAccounts = true;
  assert.equal(ui.run("canUseManagementFeature('addCafe')"), true);
  assert.equal(ui.run("canUseManagementFeature('manageAccounts')"), true);
  ui.context.featureAccessCafeId = 'another-cafe';
  assert.equal(ui.run("canUseManagementFeature('addCafe')"), false);
  assert.equal(ui.run("canUseManagementFeature('manageAccounts')"), false);
  ui.context.featureAccessCafeId = 'cafe-1';
  ui.context.userFeatureAccess.addCafe = 'true';
  assert.equal(ui.run("canUseManagementFeature('addCafe')"), false);
  ui.context.signedInUser = null;
  assert.equal(ui.run("canUseManagementFeature('manageAccounts')"), false);
});
test('admin management access stays enabled', () => {
  const ui = createUi();
  assert.equal(ui.run("canUseManagementFeature('addCafe')"), true);
  assert.equal(ui.run("canUseManagementFeature('manageAccounts')"), true);
});

test('advanced new vouchers keep Debit + Debit + Credit sides across rerenders and save',async()=>{
 const ui=createUi();ui.selectTab('Journal Entry');
 ui.getNode('#journalManualSides').checked=true;
 ui.run("journalDraftLines=[{side:'debit',particulars:'Purchases',amount:'60'},{side:'debit',particulars:'Other Expenses',amount:'40'},{side:'credit',particulars:'Cash',amount:'100'}];renderJournalApp();renderJournalApp()");
 assert.deepEqual(Array.from(ui.run('journalDraftLines'),l=>l.side),['debit','debit','credit']);
 await ui.getNode('#journalSave').handlers.click();
 assert.deepEqual(Array.from(ui.requests[0].payload.lines,l=>l.side),['debit','debit','credit']);
 assert.equal(ui.getNode('#cashTotal').textContent,'₹-100');
});

test('a duplicate voucher warning can cancel saving without changing balances',async()=>{
 const lines=[{side:'debit',particulars:'Cash',amount:100,transferRole:'destination'},{side:'credit',particulars:'UPI Account',amount:100,transferRole:'source'}];
 const ui=createUi({shops:[{id:'cafe-1',owner_id:'admin-1',entries:[],journalAccountOptions:[],journalVouchers:[{id:'old',voucherNo:1,date:'2026-10-01',lines}]}]});
 ui.selectTab('Journal Entry');ui.run('journalDraftLines='+JSON.stringify(lines));
 let warning;ui.context.window.confirm=message=>{warning=message;return false};
 await ui.getNode('#journalSave').handlers.click();
 assert.match(warning,/same date, accounts and amounts/);assert.equal(ui.requests.length,0);
 assert.equal(ui.shopData.shops[0].journalVouchers.length,1);
});

test('changing historical adjustment lines requires confirmation of corrected posting convention',async()=>{
 const voucher={id:'voucher-1',voucherNo:1,date:'2026-10-01',updatedAt:'original',lines:[{side:'debit',particulars:'Other Expenses',amount:100},{side:'credit',particulars:'Cash',amount:100}]};
 const ui=createUi({shops:[{id:'cafe-1',owner_id:'admin-1',entries:[],journalAccountOptions:[],journalVouchers:[voucher]}]});
 ui.run('loadJournalVoucher(currentShop().journalVouchers[0]);journalDraftLines.forEach(l=>l.amount="150")');
 let message;ui.context.window.confirm=text=>{message=text;return false};
 await ui.getNode('#journalSave').handlers.click();assert.match(message,/old posting convention/);assert.equal(ui.requests.length,0);
 assert.deepEqual(ui.shopData.shops[0].journalVouchers[0].lines,voucher.lines);
});

test('retrying an unsuccessful journal create retains the same request ID',async()=>{
 const ui=createUi();ui.selectTab('Journal Entry');
 ui.run("journalDraftLines=[{side:'debit',particulars:'Cash',amount:'100'},{side:'credit',particulars:'UPI Account',amount:'100'}]");
 let requestCounter=0;ui.context.crypto.randomUUID=()=> 'request-'+(++requestCounter);
 ui.context.rpcSaveError='Network response lost';await ui.getNode('#journalSave').handlers.click();
 ui.context.rpcSaveError=null;await ui.getNode('#journalSave').handlers.click();
 assert.equal(ui.requests[0].args.p_id,'request-1');assert.equal(ui.requests[1].args.p_id,'request-1');
 assert.equal(ui.shopData.shops[0].journalVouchers.length,1);assert.equal(ui.run('journalRequest'),null);
});

test('TOTAL includes Cash movements on journal-only dates before the next Day Book date',()=>{
 const ui=createUi({shops:[{id:'cafe-1',owner_id:'admin-1',journalAccountOptions:[],entries:[{date:'2026-01-01',sale:100,upi:0,purchase:0,otherExpense:0},{date:'2026-01-03',sale:200,upi:0,purchase:0,otherExpense:0}],journalVouchers:[{id:'transfer',date:'2026-01-02',lines:[{side:'debit',particulars:'Cash',amount:50,transferRole:'destination'},{side:'credit',particulars:'UPI Account',amount:50,transferRole:'source'}]}]}]});
 ui.run('render()');assert.match(ui.getNode('#rows').innerHTML,/₹150<\/td><td class="num">₹350<\/td>/);
});

test('reviewing a saved expense/UPI voucher corrects dashboard, statement and P&L in one versioned update',async()=>{
 const voucher={id:'voucher-5',voucherNo:5,date:'2026-10-21',updatedAt:'original',lines:[{side:'debit',particulars:'Other Expenses',amount:24050},{side:'credit',particulars:'UPI Account',amount:24050}]};
 const ui=createUi({shops:[{id:'cafe-1',owner_id:'admin-1',journalAccountOptions:[],entries:[{date:'2026-10-01',sale:100000,upi:100000,purchase:0,otherExpense:0}],journalVouchers:[voucher]}]});
 ui.run('loadJournalVoucher(currentShop().journalVouchers[0]);render()');
 assert.equal(ui.getNode('#journalCorrectPosting').checked,false);assert.equal(ui.getNode('#journalCorrectionNotice').classList.contains('hide'),false);
 assert.equal(ui.getNode('#upiTotal').textContent,'₹1,24,050');
 ui.getNode('#journalCorrectPosting').checked=true;let warning;ui.context.window.confirm=text=>{warning=text;return true};
 await ui.getNode('#journalSave').handlers.click();
 assert.match(warning,/old posting convention/);assert.equal(ui.requests.length,1);assert.equal(ui.requests[0].action,'update');
 assert.equal(ui.requests[0].args.p_id,'voucher-5');assert.equal(ui.requests[0].args.p_expected_updated_at,'original');
 assert.equal(ui.shopData.shops[0].journalVouchers.length,1);assert.equal(ui.getNode('#upiTotal').textContent,'₹75,950');
 assert.equal(ui.getNode('#expenseTotal').textContent,'₹24,050');assert.equal(ui.getNode('#cashTotal').textContent,'₹0');
 const saved=ui.shopData.shops[0].journalVouchers[0];
 assert.deepEqual(saved.lines.map(l=>[l.side,l.particulars,l.amount]),voucher.lines.map(l=>[l.side,l.particulars,l.amount]));
 assert.equal(accounting.upiStatement(ui.shopData.shops[0].entries,[saved]).at(-1).closing,75950);
 assert.equal(accounting.totals(ui.shopData.shops[0].entries,[saved]).expenses,24050);
 assert.equal(ui.getNode('#journalCorrectPosting').checked,false);
});

test('cancelling the legacy calculation correction makes no request and keeps the original voucher',async()=>{
 const voucher={id:'old',voucherNo:5,date:'2026-10-21',lines:[{side:'debit',particulars:'Other Expenses',amount:24050},{side:'credit',particulars:'UPI Account',amount:24050}]};
 const ui=createUi({shops:[{id:'cafe-1',owner_id:'admin-1',entries:[],journalAccountOptions:[],journalVouchers:[voucher]}]});
 ui.run('loadJournalVoucher(currentShop().journalVouchers[0])');ui.getNode('#journalCorrectPosting').checked=true;ui.context.window.confirm=()=>false;
 await ui.getNode('#journalSave').handlers.click();assert.equal(ui.requests.length,0);assert.deepEqual(ui.shopData.shops[0].journalVouchers[0],voucher);
});
