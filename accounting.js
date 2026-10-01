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

  function voucherPostings(vouchers = []) {
    return (Array.isArray(vouchers) ? vouchers : []).flatMap(voucher =>
      (Array.isArray(voucher.lines) ? voucher.lines : []).flatMap(line => {
        const account = String(line.particulars || '').trim();
        const value = amount(line.amount);
        if (!account || value <= 0 || !['debit', 'credit'].includes(line.side)) return [];
        const debit = line.side === 'debit' ? value : 0;
        const credit = line.side === 'credit' ? value : 0;
        return [{ date: voucher.date || voucher.voucher_date || '', account, debit, credit, balanceChange: amount(credit - debit), remark: voucher.remark || '', voucherNo: voucher.voucherNo ?? voucher.voucher_no ?? '' }];
      })
    );
  }

  function dailyBalances(entries, vouchers = []) {
    const byDate = new Map();
    for (const entry of entries || []) byDate.set(entry.date, { entry, cashSales: amount(amount(entry.sale) - amount(entry.upi)), purchase: amount(entry.purchase), expense: amount(entry.otherExpense), journalDebit: 0, journalCredit: 0, journalBalanceChange: 0 });
    for (const posting of voucherPostings(vouchers)) {
      if (posting.account !== 'Cash' || !posting.date) continue;
      const row = byDate.get(posting.date) || { entry: { date: posting.date, remarks: posting.remark }, cashSales: 0, purchase: 0, expense: 0, journalDebit: 0, journalCredit: 0, journalBalanceChange: 0 };
      row.journalDebit = amount(row.journalDebit + posting.debit);
      row.journalCredit = amount(row.journalCredit + posting.credit);
      row.journalBalanceChange = amount(row.journalBalanceChange + posting.balanceChange);
      byDate.set(posting.date, row);
    }
    let balance = 0;
    return [...byDate.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([, row]) => {
      const opening = amount(balance);
      balance = amount(opening + row.cashSales - row.purchase - row.expense + row.journalBalanceChange);
      return { ...row, opening, closing: balance };
    });
  }

  function totals(entries, vouchers = []) {
    const result = (entries || []).reduce((sum, entry) => {
      sum.sales = amount(sum.sales + amount(entry.sale));
      sum.upi = amount(sum.upi + amount(entry.upi));
      sum.purchases = amount(sum.purchases + amount(entry.purchase));
      sum.expenses = amount(sum.expenses + amount(entry.otherExpense));
      return sum;
    }, { sales: 0, upi: 0, purchases: 0, expenses: 0 });
    for (const posting of voucherPostings(vouchers)) {
      if (posting.account === 'Sales' || posting.account === 'Cash Sale') result.sales = amount(result.sales + posting.balanceChange);
      if (posting.account === 'Purchases') result.purchases = amount(result.purchases + posting.balanceChange);
      if (posting.account === 'Other Expenses' || posting.account === 'Expenses') result.expenses = amount(result.expenses + posting.balanceChange);
      if (posting.account === 'UPI Account') result.upi = amount(result.upi + posting.balanceChange);
    }
    return result;
  }

  function journalLines(entries) {
    const lines = [];
    for (const entry of [...(entries || [])].sort((a, b) => a.date.localeCompare(b.date))) {
      const sale = amount(entry.sale), upi = amount(entry.upi), cashSale = amount(sale - upi);
      const purchase = amount(entry.purchase), expense = amount(entry.otherExpense);
      if (cashSale > 0) lines.push({ date: entry.date, particulars: 'Cash received from sales', debit: 'Cash', credit: 'Sales', amount: cashSale });
      if (upi > 0) lines.push({ date: entry.date, particulars: 'UPI received from sales', debit: 'UPI Account', credit: 'Sales', amount: upi });
      if (purchase > 0) lines.push({ date: entry.date, particulars: entry.remarks || 'Purchase', debit: 'Purchases', credit: 'Cash', amount: purchase });
      if (expense > 0) lines.push({ date: entry.date, particulars: entry.remarks || 'Other expense', debit: 'Other Expenses', credit: 'Cash', amount: expense });
    }
    return lines;
  }

  function upiStatement(entries, vouchers = []) {
    const byDate = new Map();
    for (const entry of entries || []) {
      const row = byDate.get(entry.date) || { entry: { date: entry.date, remarks: entry.remarks || '' }, received: 0, journalDebit: 0, journalCredit: 0, journalBalanceChange: 0 };
      row.received = amount(row.received + amount(entry.upi));
      if (!row.entry.remarks && entry.remarks) row.entry.remarks = entry.remarks;
      byDate.set(entry.date, row);
    }
    for (const posting of voucherPostings(vouchers)) {
      if (posting.account !== 'UPI Account' || !posting.date) continue;
      const row = byDate.get(posting.date) || { entry: { date: posting.date, remarks: posting.remark }, received: 0, journalDebit: 0, journalCredit: 0, journalBalanceChange: 0 };
      row.journalDebit = amount(row.journalDebit + posting.debit);
      row.journalCredit = amount(row.journalCredit + posting.credit);
      row.journalBalanceChange = amount(row.journalBalanceChange + posting.balanceChange);
      byDate.set(posting.date, row);
    }
    let balance = 0;
    return [...byDate.entries()].sort(([a], [b]) => a.localeCompare(b)).flatMap(([, row]) => {
      if (row.received <= 0 && row.journalDebit <= 0 && row.journalCredit <= 0) return [];
      const opening = balance;
      balance = amount(balance + row.received + row.journalBalanceChange);
      return [{ ...row, opening, closing: balance }];
    });
  }

  function ledgers(entries, vouchers = []) {
    const accounts = new Map();
    const add = (accountName, side, value, isVoucher = false) => {
      if (!accountName || value <= 0) return;
      const account = accounts.get(accountName) || { account: accountName, debit: 0, credit: 0, voucherDebit: 0, voucherCredit: 0, journalBalanceChange: 0 };
      account[side] = amount(account[side] + value);
      if (isVoucher && side === 'debit') account.voucherDebit = amount(account.voucherDebit + value);
      if (isVoucher && side === 'credit') account.voucherCredit = amount(account.voucherCredit + value);
      accounts.set(accountName, account);
    };
    for (const line of journalLines(entries || [])) {
      add(line.debit, 'debit', line.amount);
      add(line.credit, 'credit', line.amount);
    }
    for (const posting of voucherPostings(vouchers)) {
      add(posting.account, 'debit', posting.debit, true);
      add(posting.account, 'credit', posting.credit, true);
      const account = accounts.get(posting.account);
      account.journalBalanceChange = amount(account.journalBalanceChange + posting.balanceChange);
    }
    return [...accounts.values()].sort((a, b) => a.account.localeCompare(b.account)).map(account => {
      const normalSide = account.account === 'Sales' || account.account === 'Cash Sale' ? 'credit' : 'debit';
      const dayBookNet = amount(account.debit - account.credit - account.voucherDebit + account.voucherCredit);
      const openingBalance = normalSide === 'debit' ? dayBookNet : -dayBookNet;
      const net = amount(openingBalance + account.journalBalanceChange);
      return { account: account.account, debit: account.debit, credit: account.credit, balance: amount(Math.abs(net)), side: net >= 0 ? (normalSide === 'debit' ? 'Dr' : 'Cr') : (normalSide === 'debit' ? 'Cr' : 'Dr') };
    });
  }

  function validateVoucherLines(lines) {
    if (!Array.isArray(lines) || lines.length < 2) return 'Add at least one debit and one credit item.';
    let debit = 0, credit = 0;
    for (const line of lines) {
      const value = Number(line.amount);
      if (!['debit', 'credit'].includes(line.side)) return 'Every item must be marked Debit or Credit.';
      if (!String(line.particulars || '').trim()) return 'Select an account for every item.';
      if (!Number.isFinite(value) || value <= 0 || Math.abs(Math.round(value * 100) - value * 100) > 1e-7 || value > 9999999999.99) return 'Every item needs a valid positive amount with up to two decimal places.';
      if (line.side === 'debit') debit = amount(debit + value); else credit = amount(credit + value);
    }
    return debit > 0 && debit === credit ? '' : 'Debit and credit totals must be equal and greater than zero.';
  }

  function journalLineSides(lines, firstSide, preserveSavedSides = false) {
    if (!Array.isArray(lines)) return [];
    if (preserveSavedSides) return lines.map(line => ({ ...line, side: line.side }));
    if (!['debit', 'credit'].includes(firstSide)) return [];
    return lines.map((line, index) => ({
      ...line,
      side: index % 2 === 0 ? firstSide : firstSide === 'debit' ? 'credit' : 'debit',
    }));
  }

  function voucherLinesForSave(lines) {
    return (Array.isArray(lines) ? lines : []).map(line => ({
      side: line.side,
      particulars: String(line.particulars || '').trim(),
      amount: Number(line.amount),
    }));
  }

  function formatMoney(value) {
    const number = amount(value);
    return '₹' + number.toLocaleString('en-IN', { minimumFractionDigits: Number.isInteger(number) ? 0 : 2, maximumFractionDigits: 2 });
  }

  return { amount, validateEntry, dailyBalances, totals, journalLines, voucherPostings, upiStatement, ledgers, validateVoucherLines, journalLineSides, voucherLinesForSave, formatMoney };
});
