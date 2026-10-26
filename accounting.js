(function (root, factory) {
  const accounting = factory();
  if (typeof module === 'object' && module.exports) module.exports = accounting;
  if (root) root.CafeAccounting = accounting;
})(globalThis, function () {
  const amount = value => {
    const number = Number(value || 0);
    return Number.isFinite(number) ? Math.round((number + Number.EPSILON) * 100) / 100 : 0;
  };
  const transferAccounts = new Set(['Cash', 'UPI Account', 'Bank']);
  const isTransfer = lines => Array.isArray(lines) && lines.length >= 2 &&
    lines.every(line => transferAccounts.has(String(line.particulars || '').trim())) &&
    new Set(lines.map(line => String(line.particulars || '').trim())).size >= 2;
  const isLegacyTransfer = lines => isTransfer(lines) && lines.every(line => !line.transferRole);

  const paymentSplitFields = ['saleBank', 'purchaseUpi', 'purchaseBank', 'otherExpenseUpi', 'otherExpenseBank'];
  function entryPayments(entry) {
    const legacy = paymentSplitFields.every(key => entry[key] === undefined || entry[key] === null);
    const saleBank = amount(entry.saleBank), purchaseUpi = amount(entry.purchaseUpi), purchaseBank = amount(entry.purchaseBank);
    const expenseUpi = amount(entry.otherExpenseUpi), expenseBank = amount(entry.otherExpenseBank);
    return {
      legacy,
      sales: { Cash: amount(amount(entry.sale) - amount(entry.upi) - saleBank), 'UPI Account': amount(entry.upi), Bank: saleBank },
      purchases: { Cash: amount(amount(entry.purchase) - purchaseUpi - purchaseBank), 'UPI Account': purchaseUpi, Bank: purchaseBank },
      expenses: { Cash: amount(amount(entry.otherExpense) - expenseUpi - expenseBank), 'UPI Account': expenseUpi, Bank: expenseBank },
    };
  }

  function validateEntry(entry) {
    const hasSplit = paymentSplitFields.some(key => entry[key] !== undefined && entry[key] !== null);
    if (hasSplit && paymentSplitFields.some(key => entry[key] === undefined || entry[key] === null)) return 'Provide all payment split amounts, using zero for unused accounts.';
    const splitValues = hasSplit ? [['Sales paid to Bank', entry.saleBank], ['Purchases paid by UPI', entry.purchaseUpi], ['Purchases paid by Bank', entry.purchaseBank], ['Expenses paid by UPI', entry.otherExpenseUpi], ['Expenses paid by Bank', entry.otherExpenseBank]] : [];
    for (const [label, value] of [['Sale', entry.sale], ['Google Pay (UPI)', entry.upi], ['Purchase', entry.purchase], ['Other expenses', entry.otherExpense], ...splitValues]) {
      const number = value === undefined || value === null || value === '' ? 0 : Number(value);
      if (!Number.isFinite(number) || number < 0) return label + ' must be a valid non-negative amount.';
      if (Math.abs(Math.round(number * 100) - number * 100) > 1e-7) return label + ' can have at most two decimal places.';
      if (number > 9999999999.99) return label + ' exceeds the maximum supported amount.';
    }
    if (amount(entry.upi) > amount(entry.sale)) return 'Google Pay (UPI) cannot be greater than total sales.';
    if (hasSplit && amount(amount(entry.upi) + amount(entry.saleBank)) > amount(entry.sale)) return 'Sales UPI plus Bank cannot exceed total sales.';
    if (hasSplit && amount(amount(entry.purchaseUpi) + amount(entry.purchaseBank)) > amount(entry.purchase)) return 'Purchase UPI plus Bank cannot exceed total purchases.';
    if (hasSplit && amount(amount(entry.otherExpenseUpi) + amount(entry.otherExpenseBank)) > amount(entry.otherExpense)) return 'Expense UPI plus Bank cannot exceed total expenses.';
    return '';
  }

  function voucherPostings(vouchers = []) {
    return (Array.isArray(vouchers) ? vouchers : []).filter(voucher => !voucher.voidedAt && !voucher.voided_at).flatMap(voucher => {
      const legacyTransfer = isLegacyTransfer(voucher.lines);
      return (Array.isArray(voucher.lines) ? voucher.lines : []).flatMap(line => {
        const account = String(line.particulars || '').trim();
        const value = amount(line.amount);
        if (!account || value <= 0 || !['debit', 'credit'].includes(line.side)) return [];
        // Older fund transfers used opposite stored sides; keep their effect while
        // showing the effective debit/credit in ledgers and account statements.
        const effectiveSide = legacyTransfer ? (line.side === 'debit' ? 'credit' : 'debit') : line.side;
        const debit = effectiveSide === 'debit' ? value : 0;
        const credit = effectiveSide === 'credit' ? value : 0;
        const normalDebit = ['Cash', 'UPI Account', 'Bank', 'Purchases', 'Other Expenses', 'Expenses'].includes(account);
        // Unknown historical accounts retain their existing convention; no account types are invented.
        const normalChange = normalDebit ? debit - credit : credit - debit;
        const balanceChange = line.transferRole === 'source' ? -value : line.transferRole === 'destination' ? value : legacyTransfer ? debit - credit : line.postingRule === 'account-normal-v1' ? normalChange : credit - debit;
        return [{ date: voucher.date || voucher.voucher_date || '', account, debit, credit, balanceChange: amount(balanceChange), remark: voucher.remark || '', voucherNo: voucher.voucherNo ?? voucher.voucher_no ?? '' }];
      });
    });
  }

  function dailyBalances(entries, vouchers = []) {
    const byDate = new Map();
    for (const entry of entries || []) {
      const payments = entryPayments(entry);
      byDate.set(entry.date, { entry, cashSales: payments.sales.Cash, purchase: payments.purchases.Cash, expense: payments.expenses.Cash, journalDebit: 0, journalCredit: 0, journalBalanceChange: 0 });
    }
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
      const payments = entryPayments(entry);
      sum.upi = amount(sum.upi + payments.sales['UPI Account'] - payments.purchases['UPI Account'] - payments.expenses['UPI Account']);
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
      const payments = entryPayments(entry);
      for (const account of ['Cash', 'UPI Account', 'Bank']) {
        const label = account === 'UPI Account' ? 'UPI' : account;
        if (payments.sales[account] > 0) lines.push({ date: entry.date, particulars: label + ' received from sales', debit: account, credit: 'Sales', amount: payments.sales[account] });
      }
      for (const [group, debit, fallback] of [['purchases', 'Purchases', 'Purchase'], ['expenses', 'Other Expenses', 'Other expense']]) {
        for (const account of ['Cash', 'UPI Account', 'Bank']) if (payments[group][account] > 0) lines.push({ date: entry.date, particulars: entry.remarks || fallback, debit, credit: account, amount: payments[group][account] });
      }
    }
    return lines;
  }

  function upiStatement(entries, vouchers = []) {
    const byDate = new Map();
    for (const entry of entries || []) {
      const payments = entryPayments(entry);
      const row = byDate.get(entry.date) || { entry: { date: entry.date, remarks: entry.remarks || '' }, received: 0, purchasePaid: 0, expensePaid: 0, journalDebit: 0, journalCredit: 0, journalBalanceChange: 0 };
      row.received = amount(row.received + amount(entry.upi));
      row.purchasePaid = amount(row.purchasePaid + payments.purchases['UPI Account']);
      row.expensePaid = amount(row.expensePaid + payments.expenses['UPI Account']);
      if (!row.entry.remarks && entry.remarks) row.entry.remarks = entry.remarks;
      byDate.set(entry.date, row);
    }
    for (const posting of voucherPostings(vouchers)) {
      if (posting.account !== 'UPI Account' || !posting.date) continue;
      const row = byDate.get(posting.date) || { entry: { date: posting.date, remarks: posting.remark }, received: 0, purchasePaid: 0, expensePaid: 0, journalDebit: 0, journalCredit: 0, journalBalanceChange: 0 };
      row.journalDebit = amount(row.journalDebit + posting.debit);
      row.journalCredit = amount(row.journalCredit + posting.credit);
      row.journalBalanceChange = amount(row.journalBalanceChange + posting.balanceChange);
      byDate.set(posting.date, row);
    }
    let balance = 0;
    return [...byDate.entries()].sort(([a], [b]) => a.localeCompare(b)).flatMap(([, row]) => {
      if (row.received <= 0 && row.purchasePaid <= 0 && row.expensePaid <= 0 && row.journalDebit <= 0 && row.journalCredit <= 0) return [];
      const opening = balance;
      balance = amount(balance + row.received - row.purchasePaid - row.expensePaid + row.journalBalanceChange);
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
      if (line.transferRole && !['source', 'destination'].includes(line.transferRole)) return 'Every transfer item needs a valid source or destination.';
      if (line.transferRole && line.transferRole !== (line.side === 'credit' ? 'source' : 'destination')) return 'Transfer source and destination must match Credit / From and Debit / To.';
      if (line.side === 'debit') debit = amount(debit + value); else credit = amount(credit + value);
    }
    if (lines.some(line => line.transferRole) && (!isTransfer(lines) || lines.some(line => !line.transferRole))) return 'A transfer must use Cash, UPI Account, or Bank for both source and destination.';
    if (lines.length === 2 && lines.every(line => transferAccounts.has(String(line.particulars || '').trim())) && !isTransfer(lines)) return 'Choose different source and destination accounts.';
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

  function voucherLinesForEdit(lines) {
    const legacyTransfer = isLegacyTransfer(lines);
    return (Array.isArray(lines) ? lines : []).map(line => ({
      ...line,
      side: legacyTransfer ? (line.side === 'debit' ? 'credit' : 'debit') : line.side,
    }));
  }

  function voucherNeedsPostingReview(lines) {
    return Array.isArray(lines) && lines.length >= 2 && !isTransfer(lines) &&
      lines.every(line => !line.transferRole && !line.postingRule);
  }

  function voucherLinesForSave(lines, previousLines = [], applyCorrectedRule = false) {
    const cleaned = (Array.isArray(lines) ? lines : []).map(line => ({
      side: line.side,
      particulars: String(line.particulars || '').trim(),
      amount: Number(line.amount),
    }));
    // An unchanged edit must not rewrite a historical voucher's stored sides.
    if (!(applyCorrectedRule && voucherNeedsPostingReview(previousLines)) && previousLines.length && JSON.stringify(cleaned) === JSON.stringify(voucherLinesForEdit(previousLines).map(line => ({ side: line.side, particulars: String(line.particulars || '').trim(), amount: Number(line.amount) })))) {
      return previousLines.map(line => ({ ...line }));
    }
    return isTransfer(cleaned) ? cleaned.map(line => ({ ...line, transferRole: line.side === 'credit' ? 'source' : 'destination' })) : cleaned.map(line => ({ ...line, postingRule: 'account-normal-v1' }));
  }

  function formatMoney(value) {
    const number = amount(value);
    return '₹' + number.toLocaleString('en-IN', { minimumFractionDigits: Number.isInteger(number) ? 0 : 2, maximumFractionDigits: 2 });
  }

  return { amount, entryPayments, validateEntry, dailyBalances, totals, journalLines, voucherPostings, upiStatement, ledgers, validateVoucherLines, journalLineSides, voucherLinesForEdit, voucherNeedsPostingReview, voucherLinesForSave, formatMoney };
});
