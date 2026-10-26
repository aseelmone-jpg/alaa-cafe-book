// HTTP contract checks against an isolated in-memory mock, NOT PostgreSQL/RLS proof.
const test=require('node:test');
const assert=require('node:assert/strict');
const {createDemoServer,DEMO_PASSWORD}=require('../scripts/local-demo-server.cjs');
const cafe='10000000-0000-4000-8000-000000000001';
async function fixture(t){
 const server=createDemoServer();await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 t.after(()=>new Promise(resolve=>{server.closeAllConnections();server.close(resolve)}));
 const base='http://127.0.0.1:'+server.address().port;
 const api=async(body,token)=>{const response=await fetch(base+'/__demo/api',{method:'POST',headers:{'Content-Type':'application/json','X-Demo-Session':token||''},body:JSON.stringify(body)});return response.json()};
 const login=async email=>{const r=await api({operation:'signin',values:{email,password:DEMO_PASSWORD}});assert.equal(r.error,null);return r.data.session.access_token};
 const rpc=(token,name,args)=>api({operation:'rpc',name,args},token);
 return {base,api,login,rpc};
}
test('isolated mock: pending denied financial access; owner approval assigns no financial permissions',async t=>{
 const {api,login,rpc}=await fixture(t),owner=await login('owner@alaa.test'),pending=await login('pending@alaa.test');
 assert.equal((await rpc(pending,'my_account_access')).data.status,'pending');
 assert.ok((await api({operation:'query',table:'cafes',action:'select'},pending)).error);
 assert.ok((await rpc(pending,'admin_pending_accounts',{p_cafe_id:cafe})).error);
 const request=(await rpc(owner,'admin_pending_accounts',{p_cafe_id:cafe})).data[0];
 const args={p_cafe_id:cafe,p_user_id:request.user_id,p_decision:'approved',p_reason:'',p_expected_updated_at:request.updated_at};
 assert.equal((await rpc(owner,'review_account',args)).error,null);
 assert.equal((await rpc(pending,'my_account_access')).data.status,'approved');
 assert.deepEqual((await rpc(pending,'cafe_accounting_snapshot',{p_cafe_id:cafe})).data.day_entries,[]);
 assert.ok((await rpc(owner,'review_account',args)).error);
 const notices=await api({operation:'query',table:'user_notifications',action:'select'},pending);
 assert.equal(notices.data.length,1);assert.equal(notices.data[0].kind,'registration_approved');
 assert.equal((await rpc(pending,'mark_notification_read',{p_id:notices.data[0].id})).data,true);
});
test('isolated mock: rejection requires reason; registration stays pending and duplicate response is neutral',async t=>{
 const {api,login,rpc}=await fixture(t),owner=await login('owner@alaa.test');
 const request=(await rpc(owner,'admin_pending_accounts',{p_cafe_id:cafe})).data[0];
 const args={p_cafe_id:cafe,p_user_id:request.user_id,p_decision:'rejected',p_reason:'',p_expected_updated_at:request.updated_at};
 assert.ok((await rpc(owner,'review_account',args)).error);
 assert.equal((await rpc(owner,'review_account',{...args,p_reason:'Owner does not recognize account'})).error,null);
 const pending=await login('pending@alaa.test');assert.equal((await rpc(pending,'my_account_access')).data.status,'rejected');
 const signup={operation:'signup',values:{email:'new@alaa.test',password:DEMO_PASSWORD}};
 assert.deepEqual((await api(signup)).data,(await api(signup)).data);
 const fresh=await login('new@alaa.test');assert.equal((await rpc(fresh,'my_account_access')).data.status,'pending');
});
test('isolated mock: journal retries are idempotent, stale edits rejected, void preserves history',async t=>{
 const {api,login,rpc}=await fixture(t),owner=await login('owner@alaa.test');
 const lines=[{side:'credit',particulars:'UPI Account',amount:100,transferRole:'source'},{side:'debit',particulars:'Cash',amount:100,transferRole:'destination'}];
 const args={p_cafe_id:cafe,p_id:'20000000-0000-4000-8000-000000000001',p_voucher_date:'2026-10-02',p_remark:'Sample transfer',p_lines:lines,p_expected_updated_at:null};
 const saved=await rpc(owner,'save_journal_voucher_checked',args);assert.equal(saved.error,null);
 assert.equal((await rpc(owner,'save_journal_voucher_checked',args)).data.updated_at,saved.data.updated_at);
 let snap=(await rpc(owner,'cafe_accounting_snapshot',{p_cafe_id:cafe})).data;assert.equal(snap.journal_vouchers.length,1);
 const changed=await rpc(owner,'save_journal_voucher_checked',{...args,p_expected_updated_at:saved.data.updated_at,p_lines:lines.map(l=>({...l,amount:200}))});assert.equal(changed.error,null);
 assert.ok((await rpc(owner,'save_journal_voucher_checked',{...args,p_expected_updated_at:saved.data.updated_at})).error);
 const result=await api({operation:'query',table:'journal_vouchers',action:'update',filters:[{field:'id',type:'eq',value:args.p_id}],values:{voided_at:new Date().toISOString(),voided_by:'00000000-0000-4000-8000-000000000001'}},owner);assert.equal(result.error,null);
 snap=(await rpc(owner,'cafe_accounting_snapshot',{p_cafe_id:cafe})).data;assert.ok(snap.journal_vouchers[0].voided_at);
 const history=await api({operation:'query',table:'accounting_change_events',action:'select'},owner);assert.equal(history.data.length,3);
});
test('isolated preview blocks external connections and never serves workspace files',async t=>{
 const {base}=await fixture(t);const response=await fetch(base+'/');const html=await response.text();
 assert.match(response.headers.get('content-security-policy'),/connect-src 'self';/);
 assert.match(html,/ISOLATED LOCAL DEMO/);assert.match(html,/src="\/__local-demo.js"/);
 assert.equal((await fetch(base+'/work/local-demo-server.cjs')).status,404);
});
