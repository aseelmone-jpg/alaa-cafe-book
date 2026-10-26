const test=require('node:test');
const assert=require('node:assert/strict');
const accounting=require('../public/accounting.js');
const entry=extra=>({date:'2026-10-19',sale:0,upi:0,purchase:0,otherExpense:0,saleBank:0,purchaseUpi:0,purchaseBank:0,otherExpenseUpi:0,otherExpenseBank:0,...extra});
const signedLedger=(entries,account,vouchers=[])=>{
 const row=accounting.ledgers(entries,vouchers).find(row=>row.account===account);
 return row?(row.side==='Dr'?row.balance:-row.balance):0;
};
test('a purchase of 1000 paid 600 Cash and 400 UPI reduces the correct accounts',()=>{
 const row=entry({purchase:1000,purchaseUpi:400});assert.equal(accounting.validateEntry(row),'');
 assert.equal(accounting.entryPayments(row).purchases.Cash,600);assert.equal(signedLedger([row],'Cash'),-600);assert.equal(signedLedger([row],'UPI Account'),-400);assert.equal(accounting.dailyBalances([row])[0].closing,-600);assert.equal(accounting.totals([row]).upi,-400);
});
test('sales split over Cash, UPI and Bank increases each receiving account',()=>{
 const row=entry({sale:1000,upi:300,saleBank:200});assert.equal(accounting.validateEntry(row),'');
 assert.equal(signedLedger([row],'Cash'),500);assert.equal(signedLedger([row],'UPI Account'),300);assert.equal(signedLedger([row],'Bank'),200);
});
test('purchases and expenses can both be split over all three existing accounts',()=>{
 const row=entry({purchase:1000,purchaseUpi:400,purchaseBank:250,otherExpense:300,otherExpenseUpi:50,otherExpenseBank:100});
 assert.equal(accounting.validateEntry(row),'');assert.equal(signedLedger([row],'Cash'),-500);assert.equal(signedLedger([row],'UPI Account'),-450);assert.equal(signedLedger([row],'Bank'),-350);
 const lines=accounting.journalLines([row]);assert.equal(lines.filter(line=>line.debit==='Purchases').reduce((sum,line)=>sum+line.amount,0),1000);assert.equal(lines.filter(line=>line.debit==='Other Expenses').reduce((sum,line)=>sum+line.amount,0),300);
});
test('payment choice changes balances but does not change sales, total costs or P&L',()=>{
 const cash=entry({sale:1000,purchase:500,otherExpense:100}),split=entry({sale:1000,upi:400,saleBank:200,purchase:500,purchaseUpi:150,purchaseBank:150,otherExpense:100,otherExpenseUpi:30,otherExpenseBank:50});
 for(const key of ['sales','purchases','expenses'])assert.equal(accounting.totals([cash])[key],accounting.totals([split])[key]);
 assert.equal(accounting.totals([split]).sales-accounting.totals([split]).purchases-accounting.totals([split]).expenses,400);
});
test('payment split validation rejects negative, non-finite, excessive and over-precision values',()=>{
 for(const key of ['saleBank','purchaseUpi','purchaseBank','otherExpenseUpi','otherExpenseBank']){
  for(const value of [-1,NaN,Infinity,0.001,10000000000])assert.notEqual(accounting.validateEntry(entry({[key]:value})), '',key+'='+value);
 }
});
test('payment split validation prevents non-cash amounts exceeding each category total',()=>{
 assert.match(accounting.validateEntry(entry({sale:100,upi:60,saleBank:41})),/Sales UPI plus Bank/);
 assert.match(accounting.validateEntry(entry({purchase:100,purchaseUpi:60,purchaseBank:41})),/Purchase UPI plus Bank/);
 assert.match(accounting.validateEntry(entry({otherExpense:100,otherExpenseUpi:60,otherExpenseBank:41})),/Expense UPI plus Bank/);
 assert.equal(accounting.validateEntry(entry({sale:0.3,upi:0.1,saleBank:0.2,purchase:0.3,purchaseUpi:0.1,purchaseBank:0.2})), '');
});
test('a partial split is rejected while entirely absent legacy fields remain supported',()=>{
 const legacy={date:'2026-01-01',sale:100,upi:40,purchase:20,otherExpense:5};
 assert.equal(accounting.validateEntry(legacy),'');assert.equal(accounting.entryPayments(legacy).legacy,true);assert.match(accounting.validateEntry({...legacy,saleBank:0}),/all payment split amounts/);
 const allNull={...legacy,saleBank:null,purchaseUpi:null,purchaseBank:null,otherExpenseUpi:null,otherExpenseBank:null};assert.equal(accounting.validateEntry(allNull),'');assert.equal(accounting.entryPayments(allNull).legacy,true);
 const before=JSON.stringify(legacy);accounting.dailyBalances([legacy]);accounting.ledgers([legacy]);assert.equal(JSON.stringify(legacy),before);assert.equal(accounting.dailyBalances([legacy])[0].closing,35);
});
test('UPI statement includes outgoing-only days and carries the net balance',()=>{
 const rows=accounting.upiStatement([entry({date:'2026-01-01',sale:100,upi:80}),entry({date:'2026-01-02',purchase:50,purchaseUpi:30,otherExpense:10,otherExpenseUpi:5})]);
 assert.deepEqual(rows.map(row=>[row.opening,row.received,row.purchasePaid,row.expensePaid,row.closing]),[[0,80,0,0,80],[80,0,30,5,45]]);
});
test('Cash, UPI and Bank journal transfers combine with payment splits without double counting',()=>{
 const row=entry({sale:1000,upi:300,saleBank:200,purchase:100,purchaseUpi:50});
 const transfer={date:row.date,lines:[{side:'credit',particulars:'UPI Account',amount:25,transferRole:'source'},{side:'debit',particulars:'Bank',amount:25,transferRole:'destination'}]};
 assert.equal(signedLedger([row],'Cash',[transfer]),450);assert.equal(signedLedger([row],'UPI Account',[transfer]),225);assert.equal(signedLedger([row],'Bank',[transfer]),225);assert.equal(accounting.totals([row],[transfer]).upi,225);
 assert.equal(signedLedger([row],'UPI Account',[{...transfer,voidedAt:'now'}]),250);
});
test('editing the payment mix replaces its effect while preserving the purchase total',()=>{
 const before=entry({purchase:1000,purchaseUpi:400}),after=entry({purchase:1000,purchaseBank:700});
 assert.equal(signedLedger([before],'Cash'),-600);assert.equal(signedLedger([after],'Cash'),-300);assert.equal(signedLedger([after],'UPI Account'),0);assert.equal(signedLedger([after],'Bank'),-700);assert.equal(accounting.totals([after]).purchases,1000);
});
