const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const accounting=require('../public/accounting.js');
const html=fs.readFileSync(path.join(__dirname,'../public/index.html'),'utf8');
const code=html.slice(html.indexOf('function reportRange(){'),html.indexOf('let journalDraftLines=['));
function harness({admin=true,owner='admin',response={data:[]}}={}){
 const nodes=new Map(),calls=[];
 const get=selector=>{if(!nodes.has(selector))nodes.set(selector,{value:'',innerHTML:'',textContent:'',disabled:false,classList:{add(){},remove(){}}});return nodes.get(selector)};
 const query={};
 for(const method of ['select','eq','order','gte','lt'])query[method]=(...args)=>{calls.push([method,...args]);return query};
 query.range=(...args)=>{calls.push(['range',...args]);return Promise.resolve(typeof response==='function'?response():response)};
 const context={CafeAccounting:accounting,$:get,currentShop:()=>context.shop,isAdmin:()=>admin,signedInUser:{id:'admin'},activeCategoryView:'Reports & P&L',shop:{id:'cafe-1',owner_id:owner},supabaseClient:{from:table=>{calls.push(['from',table]);return query}},escapeText:value=>String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))};
 vm.runInNewContext(code+'\nglobalThis.api={reportRange,reportData,reportCsvCell,profitLossCsv,historyChangeDetails,loadAccountingHistory,closeAccountingHistory};',context);
 return {api:context.api,context,get,calls};
}
test('report date range accepts all dates and valid leap days, rejects reversed or impossible dates',()=>{
 const {api,get}=harness();assert.deepEqual({...api.reportRange()},{from:'',to:''});
 get('#reportFrom').value='2024-02-29';get('#reportTo').value='2024-03-01';assert.equal(api.reportRange().from,'2024-02-29');
 get('#reportFrom').value='2025-02-29';assert.throws(()=>api.reportRange(),/valid report dates/);
 get('#reportFrom').value='2026-04-02';get('#reportTo').value='2026-04-01';assert.throws(()=>api.reportRange(),/on or before/);
});
test('report periods include both endpoints and exclude voided day entries and vouchers',()=>{
 const {api}=harness();const rows=api.reportData([{date:'2026-01-01'},{date:'2026-01-02'},{date:'2026-01-03'},{date:'2026-01-02',voided_at:'now'}],[{date:'2026-01-02'},{date:'2026-01-02',voidedAt:'now'}],{from:'2026-01-01',to:'2026-01-02'});
 assert.deepEqual(Array.from(rows.entries,row=>row.date),['2026-01-01','2026-01-02']);assert.equal(rows.vouchers.length,1);
});
test('period P&L includes adjustments dated inside that period without changing original arrays',()=>{
 const {api}=harness(),days=[{date:'2026-01-01',sale:100,upi:40,purchase:20,otherExpense:10},{date:'2026-02-01',sale:500}],vouchers=[{date:'2026-01-02',lines:[{side:'debit',particulars:'Other Expenses',amount:5,postingRule:'account-normal-v1'},{side:'credit',particulars:'Cash',amount:5,postingRule:'account-normal-v1'}]}];
 const before=JSON.stringify({days,vouchers}),data=api.reportData(days,vouchers,{from:'2026-01-01',to:'2026-01-31'}),totals=accounting.totals(data.entries,data.vouchers);
 assert.equal(totals.sales,100);assert.equal(totals.expenses,15);assert.equal(totals.sales-totals.purchases-totals.expenses,65);assert.equal(JSON.stringify({days,vouchers}),before);
});
test('CSV quotes text and neutralizes spreadsheet formula text while retaining numeric losses',()=>{
 const {api}=harness();assert.equal(api.reportCsvCell('a,"b"'),'"a,""b"""');
 for(const value of ['=1+1',' +SUM(A1)','-SUM(A1)','@test','\t=1'])assert.match(api.reportCsvCell(value),/^"'/);
 const csv=api.profitLossCsv({name:'=FORMULA()',location:'Cafe, town'},{from:'',to:''},{sales:100,purchases:120,expenses:5});
 assert.ok(csv.startsWith('\uFEFF'));assert.ok(csv.includes("'="));assert.ok(csv.endsWith(',100,120,5,-25'));
});
test('history is read-only, scoped to the current owner cafe, and paginated',async()=>{
 const response={data:Array.from({length:101},(_,i)=>({id:String(i),entity_type:'day_entry',entity_id:'record',event_type:'update',actor_id:'admin',occurred_at:'2026-01-01T01:00:00Z',old_record:{sale:1},new_record:{sale:2}}))};
 const {api,calls,get}=harness({response});await api.loadAccountingHistory(0);
 assert.ok(calls.some(call=>call[0]==='from'&&call[1]==='accounting_change_events'));assert.ok(calls.some(call=>call[0]==='eq'&&call[1]==='cafe_id'&&call[2]==='cafe-1'));
 assert.deepEqual(calls.find(call=>call[0]==='range'),['range',0,100]);assert.equal((get('#historyRows').innerHTML.match(/<details>/g)||[]).length,100);assert.equal(get('#historyNext').disabled,false);assert.equal(get('#historyPrev').disabled,true);
 assert.ok(!calls.some(call=>['insert','update','delete','upsert'].includes(call[0])));
});
test('history denies non-admins and admins who do not own the cafe before querying',async()=>{
 for(const options of [{admin:false},{owner:'another-admin'}]){const {api,calls}=harness(options);await api.loadAccountingHistory();assert.equal(calls.length,0)}
});
test('history date filters use India-midnight boundaries and an exclusive next day',async()=>{
 const {api,get,calls}=harness();get('#reportFrom').value='2026-01-01';get('#reportTo').value='2026-01-31';await api.loadAccountingHistory();
 assert.deepEqual(calls.find(call=>call[0]==='gte'),['gte','occurred_at','2026-01-01T00:00:00+05:30']);assert.deepEqual(calls.find(call=>call[0]==='lt'),['lt','occurred_at','2026-02-01T00:00:00+05:30']);
});
test('history results are discarded after a cafe change or explicit close',async()=>{
 let resolve;const pending=new Promise(done=>{resolve=done});const {api,context,get}=harness({response:()=>pending});const loading=api.loadAccountingHistory();context.shop={id:'another-cafe',owner_id:'admin'};resolve({data:[{id:'secret'}]});await loading;assert.equal(get('#historyRows').innerHTML,'');
 let resolve2;const next=new Promise(done=>{resolve2=done});const h=harness({response:()=>next});const loading2=h.api.loadAccountingHistory();h.api.closeAccountingHistory();resolve2({data:[{id:'secret'}]});await loading2;assert.equal(h.get('#historyRows').innerHTML,'');
});
test('history shows query errors and escapes untrusted historical values',async()=>{
 const {api,get}=harness({response:{error:{message:'Permission denied'}}});await api.loadAccountingHistory();assert.match(get('#historyMessage').textContent,/Permission denied/);
 const details=api.historyChangeDetails({old_record:{remarks:'old'},new_record:{remarks:'<script>alert(1)</script>'}});assert.ok(!details.includes('<script>'));assert.ok(details.includes('&lt;script&gt;'));
});
