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

test('formats paise when present and whole rupees without trailing decimals', () => {
  assert.equal(accounting.formatMoney(1234.5), '₹1,234.50');
  assert.equal(accounting.formatMoney(1234), '₹1,234');
});
