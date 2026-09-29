(function (root, factory) {
  const accounting = factory();
  if (typeof module === 'object' && module.exports) module.exports = accounting;
  if (root) root.CafeAccounting = accounting;
})(globalThis, function () {
  const amount = value => {
    const number = Number(value || 0);
    return Number.isFinite(number) ? Math.round((number + Number.EPSILON) * 100) / 100 : 0;
  };

  function validateEntry(entry) {
    for (const [label, value] of [['Sale', entry.sale], ['Google Pay (UPI)', entry.upi], ['Purchase', entry.purchase], ['Other expenses', entry.otherExpense]]) {
      const number = value === undefined || value === null || value === '' ? 0 : Number(value);
      if (!Number.isFinite(number) || number < 0) return label + ' must be a valid non-negative amount.';
      if (Math.abs(Math.round(number * 100) - number * 100) > 1e-7) return label + ' can have at most two decimal places.';
      if (number > 9999999999.99) return label + ' exceeds the maximum supported amount.';
    }
    if (amount(entry.upi) > amount(entry.sale)) return 'Google Pay (UPI) cannot be greater than total sales.';
    return '';
  }

  function dailyBalances(entries) {
    let balance = 0;
    return [...entries].sort((a, b) => a.date.localeCompare(b.date)).map(entry => {
      const opening = amount(balance);
      const cashSales = amount(amount(entry.sale) - amount(entry.upi));
      const purchase = amount(entry.purchase);
      const expense = amount(entry.otherExpense);
      balance = amount(opening + cashSales - purchase - expense);
      return { entry, opening, cashSales, purchase, expense, closing: balance };
    });
  }

  function totals(entries) {
    return entries.reduce((sum, entry) => {
      sum.sales = amount(sum.sales + amount(entry.sale));
      sum.upi = amount(sum.upi + amount(entry.upi));
      sum.purchases = amount(sum.purchases + amount(entry.purchase));
      sum.expenses = amount(sum.expenses + amount(entry.otherExpense));
      return sum;
    }, { sales: 0, upi: 0, purchases: 0, expenses: 0 });
  }

  function journalLines(entries) {
    const lines = [];
    for (const entry of [...entries].sort((a, b) => a.date.localeCompare(b.date))) {
      const sale = amount(entry.sale), upi = amount(entry.upi), cashSale = amount(sale - upi);
      const purchase = amount(entry.purchase), expense = amount(entry.otherExpense);
      if (cashSale > 0) lines.push({ date: entry.date, particulars: 'Cash received from sales', debit: 'Cash', credit: 'Sales', amount: cashSale });
      if (upi > 0) lines.push({ date: entry.date, particulars: 'UPI received from sales', debit: 'UPI Account', credit: 'Sales', amount: upi });
      if (purchase > 0) lines.push({ date: entry.date, particulars: entry.remarks || 'Purchase', debit: 'Purchases', credit: 'Cash', amount: purchase });
      if (expense > 0) lines.push({ date: entry.date, particulars: entry.remarks || 'Other expense', debit: 'Other Expenses', credit: 'Cash', amount: expense });
    }
    return lines;
  }

  function formatMoney(value) {
    const number = amount(value);
    return '₹' + number.toLocaleString('en-IN', { minimumFractionDigits: Number.isInteger(number) ? 0 : 2, maximumFractionDigits: 2 });
  }

  return { amount, validateEntry, dailyBalances, totals, journalLines, formatMoney };
});
