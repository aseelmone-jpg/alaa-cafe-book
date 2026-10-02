const test = require('node:test');
const assert = require('node:assert/strict');
const accounting = require('../public/accounting.js');

test('validates UPI as a subset of total sales', () => {
  assert.equal(accounting.validateEntry({ sale: 100, upi: 60, purchase: 0, otherExpense: 0 }), '');
  assert.match(accounting.validateEntry({ sale: 50, upi: 60, purchase: 0, otherExpense: 0 }), /cannot be greater/);
});

test('rejects negative, non-finite, over-precision and out-of-range amounts', () => {
  assert.match(accounting.validateEntry({ sale: -1, upi: 0 }), /non-negative/);
  assert.match(accounting.validateEntry({ sale: NaN, upi: 0 }), /valid non-negative/);
  assert.match(accounting.validateEntry({ sale: Infinity, upi: 0 }), /valid non-negative/);
  assert.match(accounting.validateEntry({ sale: 1.001, upi: 0 }), /two decimal places/);
  assert.match(accounting.validateEntry({ sale: 10000000000, upi: 0 }), /maximum supported/);
});

test('carries cash balances in date order and excludes UPI from physical cash', () => {
  const days = accounting.dailyBalances([
    { date: '2026-09-02', sale: 20, upi: 0, purchase: 0, otherExpense: 0 },
    { date: '2026-09-01', sale: 100, upi: 60, purchase: 10, otherExpense: 5 },
  ]);
  assert.deepEqual(days.map(day => [day.opening, day.cashSales, day.closing]), [[0, 40, 25], [25, 20, 45]]);
});

test('aggregates totals without floating point paise drift', () => {
  assert.deepEqual(accounting.totals([
    { sale: 0.1, upi: 0.05, purchase: 0.02, otherExpense: 0.01 },
    { sale: 0.2, upi: 0.1, purchase: 0.03, otherExpense: 0.04 },
  ]), { sales: 0.3, upi: 0.15, purchases: 0.05, expenses: 0.05 });
});

test('creates balanced journal lines for cash, UPI, purchases and expenses', () => {
  const lines = accounting.journalLines([{ date: '2026-09-01', sale: 100, upi: 60, purchase: 10, otherExpense: 5 }]);
  const accountTotals = side => lines.reduce((totals, line) => {
    const account = line[side];
    totals[account] = (totals[account] || 0) + line.amount;
    return totals;
  }, {});
  const debits = accountTotals('debit');
  const credits = accountTotals('credit');
  const debitTotal = Object.values(debits).reduce((sum, value) => sum + value, 0);
  const creditTotal = Object.values(credits).reduce((sum, value) => sum + value, 0);
  assert.equal(debitTotal, 115);
  assert.equal(creditTotal, 115);
  assert.deepEqual(debits, { Cash: 40, 'UPI Account': 60, Purchases: 10, 'Other Expenses': 5 });
  assert.deepEqual(credits, { Sales: 100, Cash: 15 });
});

test('builds a running UPI statement from received payments only', () => {
  const statement = accounting.upiStatement([
    { date: '2026-09-02', sale: 40, upi: 15 },
    { date: '2026-09-01', sale: 30, upi: 10 },
    { date: '2026-09-03', sale: 5, upi: 0 },
  ]);
  assert.deepEqual(statement.map(row => [row.entry.date, row.opening, row.received, row.closing]), [
    ['2026-09-01', 0, 10, 10],
    ['2026-09-02', 10, 15, 25],
  ]);
});

test('saved vouchers preserve every side through open and unchanged save', () => {
  const examples = [
    [{ side: 'debit', particulars: 'Cash', amount: 50 }, { side: 'credit', particulars: 'Sales', amount: 50 }],
    [{ side: 'debit', particulars: 'Cash', amount: 40 }, { side: 'debit', particulars: 'Purchases', amount: 10 }, { side: 'credit', particulars: 'Sales', amount: 50 }],
    [{ side: 'credit', particulars: 'Capital', amount: 50 }, { side: 'debit', particulars: 'Cash', amount: 20 }, { side: 'debit', particulars: 'Purchases', amount: 30 }],
    [{ side: 'debit', particulars: 'Cash', amount: 20 }, { side: 'credit', particulars: 'Capital', amount: 10 }, { side: 'debit', particulars: 'Purchases', amount: 5 }, { side: 'credit', particulars: 'Sales', amount: 15 }],
  ];
  for (const saved of examples) {
    const opened = accounting.journalLineSides(saved, saved[0].side, true);
    assert.deepEqual(opened, saved, 'opening must retain the stored sides and values');
    assert.equal(accounting.validateVoucherLines(opened), '', 'example must be a valid balanced voucher');
    const savedAgain = accounting.voucherLinesForSave(opened);
    assert.deepEqual(savedAgain, saved, 'an unchanged save must retain the same voucher meaning');
    assert.deepEqual(savedAgain.map(line => line.side), saved.map(line => line.side));
  }
});

test('new voucher lines alternate from the first Debit/To or Credit/From selection', () => {
  const blankLines = [
    { particulars: 'Cash', amount: 40 },
    { particulars: 'Purchases', amount: 10 },
    { particulars: 'Sales', amount: 50 },
  ];
  assert.deepEqual(accounting.journalLineSides(blankLines, 'debit').map(line => line.side), ['debit', 'credit', 'debit']);
  assert.deepEqual(accounting.journalLineSides(blankLines, 'credit').map(line => line.side), ['credit', 'debit', 'credit']);
});

test('journal voucher validation requires balanced, valid debit and credit lines', () => {
  const balanced = [
    { side: 'debit', particulars: 'Cash', amount: '125.50' },
    { side: 'credit', particulars: 'Sales', amount: '125.50' },
  ];
  assert.equal(accounting.validateVoucherLines(balanced), '');
  assert.match(accounting.validateVoucherLines([...balanced.slice(0, 1), { ...balanced[1], amount: '125.49' }]), /equal/);
  assert.match(accounting.validateVoucherLines([{ ...balanced[0], amount: '0' }, balanced[1]]), /valid positive/);
  assert.match(accounting.validateVoucherLines([{ ...balanced[0], side: 'invalid' }, balanced[1]]), /Debit or Credit/);
  assert.match(accounting.validateVoucherLines([{ side: 'debit', particulars: 'Cash', amount: 1 }, { side: 'credit', particulars: 'Cash', amount: 1 }]), /different source/);
  assert.match(accounting.validateVoucherLines([{ side: 'debit', particulars: 'Cash', amount: 1, transferRole: 'source' }, { side: 'credit', particulars: 'UPI Account', amount: 1, transferRole: 'destination' }]), /source and destination must match/);
  assert.match(accounting.validateVoucherLines([{ side: 'debit', particulars: 'Cash', amount: 1, transferRole: 'destination' }, { side: 'credit', particulars: 'UPI Account', amount: 1 }]), /must use Cash, UPI Account, or Bank/);
});

test('journal postings update the expected account balances and P&L totals', () => {
  const vouchers = [{ date: '2026-09-30', lines: [
    { side: 'debit', particulars: 'Cash', amount: 100 },
    { side: 'debit', particulars: 'UPI Account', amount: 60 },
    { side: 'debit', particulars: 'Purchases', amount: 20 },
    { side: 'debit', particulars: 'Other Expenses', amount: 5 },
    { side: 'credit', particulars: 'Sales', amount: 185 },
  ] }];
  assert.deepEqual(accounting.totals([], vouchers), { sales: 185, upi: -60, purchases: -20, expenses: -5 });
  const balances = Object.fromEntries(accounting.ledgers([], vouchers).map(line => [line.account, [line.balance, line.side]]));
  assert.deepEqual(balances.Cash, [100, 'Cr']);
  assert.deepEqual(balances['UPI Account'], [60, 'Cr']);
  assert.deepEqual(balances.Purchases, [20, 'Cr']);
  assert.deepEqual(balances['Other Expenses'], [5, 'Cr']);
  assert.deepEqual(balances.Sales, [185, 'Cr']);
});

test('existing unmarked adjustment vouchers retain their original balance effects', () => {
  const entries = [{ date: '2026-09-30', sale: 100, upi: 40, purchase: 20, otherExpense: 5 }];
  const vouchers = [
    { date: '2026-09-30', lines: [{ side: 'debit', particulars: 'Cash', amount: 10 }, { side: 'credit', particulars: 'Sales', amount: 10 }] },
    { date: '2026-09-30', lines: [{ side: 'debit', particulars: 'Sales', amount: 4 }, { side: 'credit', particulars: 'Cash', amount: 4 }] },
    { date: '2026-09-30', lines: [{ side: 'debit', particulars: 'UPI Account', amount: 5 }, { side: 'credit', particulars: 'Other Expenses', amount: 5 }] },
    { date: '2026-09-30', lines: [{ side: 'debit', particulars: 'Other Expenses', amount: 2 }, { side: 'credit', particulars: 'UPI Account', amount: 2 }] },
    { date: '2026-09-30', lines: [{ side: 'debit', particulars: 'Purchases', amount: 3 }, { side: 'credit', particulars: 'Cash', amount: 3 }] },
    { date: '2026-09-30', lines: [{ side: 'debit', particulars: 'Cash', amount: 1 }, { side: 'credit', particulars: 'Purchases', amount: 1 }] },
  ];
  const balances = Object.fromEntries(accounting.ledgers(entries, vouchers).map(line => [line.account, [line.balance, line.side]]));
  assert.deepEqual(balances.Cash, [31, 'Dr']);
  assert.deepEqual(balances['UPI Account'], [37, 'Dr']);
  assert.deepEqual(balances.Sales, [106, 'Cr']);
  assert.deepEqual(balances.Purchases, [18, 'Dr']);
  assert.deepEqual(balances['Other Expenses'], [8, 'Dr']);
  assert.deepEqual(accounting.totals(entries, vouchers), { sales: 106, upi: 37, purchases: 18, expenses: 8 });
  const cashDay = accounting.dailyBalances(entries, vouchers)[0];
  assert.equal(cashDay.closing, 31);
  assert.equal(cashDay.journalDebit, 11);
  assert.equal(cashDay.journalCredit, 7);
  const upiDay = accounting.upiStatement(entries, vouchers)[0];
  assert.equal(upiDay.closing, 37);
  assert.equal(upiDay.journalDebit, 5);
  assert.equal(upiDay.journalCredit, 2);
});

test('Cash, UPI and Bank transfers work in both directions and reach dashboard balances', () => {
  const pairs = [
    ['UPI Account', 'Cash'], ['Cash', 'UPI Account'],
    ['Bank', 'Cash'], ['Cash', 'Bank'],
    ['UPI Account', 'Bank'], ['Bank', 'UPI Account'],
  ];
  for (const [first, second] of pairs) {
    for (const [arrow, firstSide] of [['→', 'credit'], ['←', 'debit']]) {
      const draft = accounting.journalLineSides([
        { particulars: first, amount: 125.50 },
        { particulars: second, amount: 125.50 },
      ], firstSide);
      assert.deepEqual(draft.map(line => line.side), firstSide === 'debit' ? ['debit', 'credit'] : ['credit', 'debit'], `${first} ${arrow} ${second}`);
      assert.equal(accounting.validateVoucherLines(draft), '', `${first} ${arrow} ${second}`);
      const voucher = { date: '2026-10-02', lines: accounting.voucherLinesForSave(draft) };
      assert.deepEqual(voucher.lines.map(line => line.transferRole), firstSide === 'credit' ? ['source', 'destination'] : ['destination', 'source']);
      const expectedFirst = firstSide === 'credit' ? -125.50 : 125.50;
      const postings = accounting.voucherPostings([voucher]);
      assert.deepEqual(postings.map(posting => [posting.account, posting.balanceChange]), [[first, expectedFirst], [second, -expectedFirst]], `${first} ${arrow} ${second}`);
      const balances = Object.fromEntries(accounting.ledgers([], [voucher]).map(line => [line.account, line.balance * (line.side === 'Dr' ? 1 : -1)]));
      assert.equal(balances[first], expectedFirst, `${first} ${arrow} ${second} first balance`);
      assert.equal(balances[second], -expectedFirst, `${first} ${arrow} ${second} second balance`);
      const cashPosting = postings.find(posting => posting.account === 'Cash');
      const cashRows = accounting.dailyBalances([], [voucher]);
      assert.equal(cashRows.at(-1)?.closing ?? 0, cashPosting?.balanceChange ?? 0, `${first} ${arrow} ${second} cash balance`);
      const upiPosting = postings.find(posting => posting.account === 'UPI Account');
      const upiRows = accounting.upiStatement([], [voucher]);
      assert.equal(upiRows.at(-1)?.closing ?? 0, upiPosting?.balanceChange ?? 0, `${first} ${arrow} ${second} UPI balance`);
      const totals = accounting.totals([], [voucher]);
      assert.deepEqual([totals.sales, totals.purchases, totals.expenses], [0, 0, 0], `${first} ${arrow} ${second} profit and loss`);
      assert.equal(totals.upi, upiPosting?.balanceChange ?? 0, `${first} ${arrow} ${second} dashboard UPI`);
    }
  }
});

test('an existing legacy transfer retains its effect and saved sides on unchanged edit', () => {
  const oldLines = [
    { side: 'credit', particulars: 'Cash', amount: 100 },
    { side: 'debit', particulars: 'UPI Account', amount: 100 },
  ];
  const original = { date: '2026-10-02', lines: oldLines };
  assert.deepEqual(accounting.voucherPostings([original]).map(p => [p.account, p.balanceChange]), [['Cash', 100], ['UPI Account', -100]]);
  const draft = accounting.voucherLinesForEdit(oldLines);
  assert.deepEqual(draft.map(line => line.side), ['debit', 'credit']);
  assert.deepEqual(accounting.voucherLinesForSave(draft, oldLines), oldLines);
  const edited = { date: '2026-10-02', lines: accounting.voucherLinesForSave(draft.map(line => ({ ...line, amount: 125 })), oldLines) };
  assert.deepEqual(edited.lines.map(line => line.transferRole), ['destination', 'source']);
  assert.deepEqual(accounting.voucherPostings([edited]).map(p => [p.account, p.balanceChange]), [['Cash', 125], ['UPI Account', -125]]);
  assert.deepEqual(accounting.voucherPostings([original]).map(p => p.balanceChange), [100, -100], 'editing never mutates the old voucher');
});

test('editing source, destination, or amount replaces rather than doubles the transfer', () => {
  const saved = { date: '2026-10-02', lines: accounting.voucherLinesForSave([
    { side: 'credit', particulars: 'UPI Account', amount: 100 },
    { side: 'debit', particulars: 'Cash', amount: 100 },
  ]) };
  const changed = { date: '2026-10-02', lines: accounting.voucherLinesForSave([
    { side: 'credit', particulars: 'Cash', amount: 75 },
    { side: 'debit', particulars: 'Bank', amount: 75 },
  ], saved.lines) };
  const net = vouchers => Object.fromEntries(accounting.ledgers([], vouchers).map(row => [row.account, row.balance * (row.side === 'Dr' ? 1 : -1)]));
  assert.deepEqual(net([saved]), { Cash: 100, 'UPI Account': -100 });
  assert.deepEqual(net([changed]), { Bank: 75, Cash: -75 });
  assert.deepEqual(net([]), {}, 'deleting the voucher removes both effects');
  assert.deepEqual(net([saved, changed]), { Bank: 75, Cash: 25, 'UPI Account': -100 }, 'double counting occurs only if both vouchers are retained');
});

test('summarizes debit and credit balances for each ledger account', () => {
  const ledgers = accounting.ledgers([
    { date: '2026-09-01', sale: 100, upi: 60, purchase: 10, otherExpense: 5 },
  ]);
  assert.deepEqual(ledgers, [
    { account: 'Cash', debit: 40, credit: 15, balance: 25, side: 'Dr' },
    { account: 'Other Expenses', debit: 5, credit: 0, balance: 5, side: 'Dr' },
    { account: 'Purchases', debit: 10, credit: 0, balance: 10, side: 'Dr' },
    { account: 'Sales', debit: 0, credit: 100, balance: 100, side: 'Cr' },
    { account: 'UPI Account', debit: 60, credit: 0, balance: 60, side: 'Dr' },
  ]);
});

test('formats paise when present and whole rupees without trailing decimals', () => {
  assert.equal(accounting.formatMoney(1234.5), '₹1,234.50');
  assert.equal(accounting.formatMoney(1234), '₹1,234');
});
