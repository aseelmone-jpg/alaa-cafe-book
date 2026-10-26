const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const html=fs.readFileSync(path.join(__dirname,'../public/index.html'),'utf8');
const helpers=html.slice(html.indexOf('function accountingWritesBlocked(){'),html.indexOf('function reportRange(){'));
const missing={code:'PGRST202',message:'Could not find the function public.cafe_accounting_snapshot(p_cafe_id) in the schema cache'};
function harness({error=missing,role='admin',owner='admin',failure,throwRpc=false}={}){
 const calls=[],nodes=new Map();
 const queryFor=table=>{
  calls.push(['from',table]);const query={};
  for(const method of ['select','eq','is','order'])query[method]=(...args)=>{calls.push([method,table,...args]);return query};
  query.then=(resolve,reject)=>Promise.resolve(failure?{data:null,error:failure}:{data:[{id:table}],error:null}).then(resolve,reject);return query;
 };
 const context={signedInUser:{id:'admin',app_metadata:{role}},shop:{id:'cafe',owner_id:owner},currentShop:()=>context.shop,$:id=>{if(!nodes.has(id))nodes.set(id,{disabled:false,classList:{toggle(){}}});return nodes.get(id)},supabaseClient:{rpc:async(name,args)=>{calls.push(['rpc',name,args]);if(throwRpc)throw Error('network');return error?{data:null,error}:{data:{day_entries:[],journal_vouchers:[],journal_account_options:[]},error:null}},from:queryFor}};
 context.document={querySelectorAll:()=>[]};vm.runInNewContext(helpers,context);return {context,calls,nodes};
}
test('installed snapshot RPC is used directly without table fallback',async()=>{
 const h=harness({error:null});const result=await h.context.readCafeAccounting(h.context.shop);assert.equal(result.error,null);assert.equal(result.compatibilityReadOnly,false);assert.equal(h.calls.filter(call=>call[0]==='from').length,0);
});
test('only a missing snapshot RPC permits owner-admin read-only table fallback',async()=>{
 const h=harness();const result=await h.context.readCafeAccounting(h.context.shop);assert.equal(result.error,null);assert.equal(result.compatibilityReadOnly,true);assert.equal(result.data.day_entries[0].id,'day_entries');
 assert.deepEqual(h.calls.filter(call=>call[0]==='from').map(call=>call[1]),['day_entries','journal_vouchers','journal_account_options']);
 assert.equal(h.calls.filter(call=>call[0]==='eq'&&call[2]==='cafe_id'&&call[3]==='cafe').length,3);
 assert.ok(!h.calls.some(call=>['insert','update','upsert','delete'].includes(call[0])));
});
test('member and non-owner admin cannot enter the unfiltered fallback',async()=>{
 for(const options of [{role:'user'},{owner:'another-admin'}]){const h=harness(options),result=await h.context.readCafeAccounting(h.context.shop);assert.ok(result.error);assert.equal(h.calls.filter(call=>call[0]==='from').length,0)}
});
test('permission errors and other missing functions never trigger fallback',async()=>{
 for(const error of [{code:'42501',message:'permission denied'},{code:'PGRST202',message:'Could not find some_other_function'}]){const h=harness({error}),result=await h.context.readCafeAccounting(h.context.shop);assert.equal(result.error,error);assert.equal(h.calls.filter(call=>call[0]==='from').length,0)}
});
test('network failures are returned without bypassing the RPC',async()=>{
 const h=harness({throwRpc:true});const result=await h.context.readCafeAccounting(h.context.shop);assert.match(result.error.message,/network/);assert.equal(h.calls.filter(call=>call[0]==='from').length,0);
});
test('a table error fails the complete snapshot rather than rendering partial balances',async()=>{
 const error={message:'day entries unavailable'},h=harness({failure:error}),result=await h.context.readCafeAccounting(h.context.shop);assert.equal(result.error,error);assert.equal(result.data,null);
});
test('account changes during fallback discard the response',async()=>{
 const h=harness(),from=h.context.supabaseClient.from;h.context.supabaseClient.from=table=>{const query=from(table);if(table==='journal_account_options')h.context.signedInUser={id:'different',app_metadata:{role:'admin'}};return query};
 const result=await h.context.readCafeAccounting(h.context.shop);assert.equal(result.data,null);assert.match(result.error.message,/account changed/);
});
test('compatibility mode disables save buttons and restores only compatibility-disabled controls',()=>{
 const h=harness();h.context.shop.compatibilityReadOnly=true;h.context.updateAccountingCompatibility();assert.equal(h.nodes.get('#entrySubmit').disabled,true);assert.equal(h.nodes.get('#journalSave').disabled,true);
 h.context.shop.compatibilityReadOnly=false;h.context.updateAccountingCompatibility();assert.equal(h.nodes.get('#entrySubmit').disabled,false);
 h.nodes.get('#entrySubmit').disabled=true;h.context.updateAccountingCompatibility();assert.equal(h.nodes.get('#entrySubmit').disabled,true);
});
test('initial loading and realtime both use the compatibility reader; mutation handlers are guarded',()=>{
 assert.match(html,/const snapshot=await readCafeAccounting\(cafe\),\{data,error\}=snapshot/);assert.match(html,/const snapshot=await readCafeAccounting\(shop\)/);
 for(const id of ['entryForm','journalSave','newShopForm','deleteShop','saveJournalAccounts','journalVoucherList','rows']){
  const event=['entryForm','newShopForm'].includes(id)?'submit':'click';
  const listener=html.split(/\r?\n/).find(line=>line.startsWith("$('#"+id+"').addEventListener('"+event+"'"));assert.ok(listener?.includes('accountingWritesBlocked()'),id);
 }
 assert.match(html,/\$\('#saveFeatureSettings'\)\.addEventListener\('click',saveFeatureSettings\)/);
 const settingsSave=html.slice(html.indexOf('async function saveFeatureSettings(){'),html.indexOf('function scheduleRealtimeRefresh('));
 assert.ok(settingsSave.indexOf('accountingWritesBlocked()')<settingsSave.indexOf("from('cafe_user_features')"));
});
