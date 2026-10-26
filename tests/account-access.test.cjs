const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const html=fs.readFileSync(path.join(__dirname,'../public/index.html'),'utf8');
const code=html.slice(html.indexOf('function hideAccessPanels(){'),html.indexOf('function showAuthLoading('));
function harness({status='pending',admin=false,rpc,notifications=[],notificationPromise}={}){
 const nodes=new Map(),calls=[],watchers=[];
 const get=selector=>{
  if(!nodes.has(selector)){
   const classes=new Set();const node={value:'',textContent:'',innerHTML:'',disabled:false,open:false,handlers:{},
    classList:{add:k=>classes.add(k),remove:k=>classes.delete(k),contains:k=>classes.has(k)},
    addEventListener:(event,handler)=>node.handlers[event]=handler,checkValidity:()=>true,
    showModal:()=>node.open=true,close:()=>node.open=false};nodes.set(selector,node);
  }return nodes.get(selector);
 };
 const channel={on(event,filter,handler){watchers.push({filter,handler});return this},subscribe(){return this}};
 const context={signedInUser:{id:'user-1',email:'user@example.com',app_metadata:{role:admin?'admin':'user'}},accountAccess:null,accountAccessCompatibility:false,
  accountAccessVersion:0,accountAccessChannel:null,notificationRows:[],notificationOffset:0,notificationSequence:0,accountRequests:[],reviewSequence:0,recoverySession:false,
  syncing:false,cloudReady:false,entries:[{sale:100}],shopData:{shops:[{id:'cafe-1',owner_id:'owner',entries:[{sale:100}],journalVouchers:[{id:'saved'}]}]},
  $:get,document:{querySelectorAll:()=>[]},isAdmin:()=>admin,accountingWritesBlocked:()=>context.compatBlocked===true,
  currentShop:()=>context.shopData.shops[0],window:{alert:message=>calls.push(['alert',message]),confirm:()=>true,prompt:()=> 'Not authorized'},
  location:{origin:'http://127.0.0.1:4174',pathname:'/'},history:{replaceState:()=>calls.push(['replaceState'])},
  stopRealtimeSync:()=>calls.push(['stopFinancialSync']),closeAccountingHistory(){},
  showAuthLoadError:message=>{context.authError=message},
  loadCloud:async()=>calls.push(['loadCloud']),loadSettingsUsers:async()=>calls.push(['loadSettingsUsers']),
  escapeText:value=>String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])),
  supabaseClient:{
   rpc:async(name,args)=>{calls.push(['rpc',name,args]);if(rpc)return rpc(name,args);return {data:{status,reason:'Reason provided by owner',can_review:admin},error:null}},
   channel:()=>channel,removeChannel:async()=>{},
   from(table){calls.push(['from',table]);const query={};
    for(const method of ['select','eq','is','order'])query[method]=(...args)=>{calls.push([method,...args]);return query};
    query.range=(...args)=>{calls.push(['range',...args]);return notificationPromise||Promise.resolve({data:notifications,error:null})};
    query.then=(resolve,reject)=>Promise.resolve({count:notifications.length,error:null}).then(resolve,reject);return query;
   },
   auth:{resetPasswordForEmail:async(...args)=>{calls.push(['resetPasswordForEmail',...args]);return {error:null}},
    resend:async args=>{calls.push(['resend',args]);return {error:null}},
    updateUser:async args=>{calls.push(['updateUser',args]);return {error:null}}},
  },
 };
 vm.runInNewContext(code,context);return {context,get,calls,watchers};
}

test('pending accounts see status only and no financial queries are sent',async()=>{
 const h=harness();assert.equal(await h.context.ensureAccountAccess(),false);
 assert.equal(h.get('#authTitle').textContent,'Waiting for approval');assert.equal(h.context.entries.length,0);
 assert.equal(h.context.shopData.shops[0].journalVouchers.length,0);
 assert.ok(!h.calls.some(call=>call[0]==='from'&&call[1]!=='user_notifications'));
});
test('rejected users can read their status reason without financial access',async()=>{
 const h=harness({status:'rejected'});assert.equal(await h.context.ensureAccountAccess(),false);
 assert.match(h.get('#accountStatusMessage').textContent,/Reason provided by owner/);
 assert.equal(h.get('#authTitle').textContent,'Account not approved');
});
test('approved status permits the next financial load without changing the authentication system',async()=>{
 const h=harness({status:'approved'});assert.equal(await h.context.ensureAccountAccess(),true);
 assert.equal(h.context.accountAccessCompatibility,false);assert.ok(h.watchers.some(w=>w.filter.table==='user_account_access'));
 const load=html.slice(html.indexOf('async function loadCloud(){'),html.indexOf('async function authAction('));
 assert.ok(load.indexOf('ensureAccountAccess()')<load.indexOf("from('cafes')"));
 assert.doesNotMatch(load,/\.insert\(/,'Loading an account must not create cafes or import cached financial data');
});
test('missing approval backend denies ordinary users; owner compatibility is explicitly read-only',async()=>{
 const error={code:'PGRST202',message:'Could not find my_account_access'};
 const member=harness({rpc:async()=>({error})});await assert.rejects(()=>member.context.ensureAccountAccess(),/Could not check account approval/);
 const admin=harness({admin:true,rpc:async()=>({error})});assert.equal(await admin.context.ensureAccountAccess(),true);
 assert.equal(admin.context.accountAccessCompatibility,true);
 assert.match(html,/approvalReadOnly:accountAccessCompatibility/);
 assert.match(html,/accountAccessCompatibility&&!cafes\.some\(cafe=>cafe\.owner_id===loadingUser\.id\)/);
});
test('unknown status and stale responses never grant account access',async()=>{
 const invalid=harness({status:'unexpected'});await assert.rejects(()=>invalid.context.ensureAccountAccess(),/invalid account approval/);
 let resolve;const pending=new Promise(done=>resolve=done);const h=harness({rpc:()=>pending});
 const loading=h.context.ensureAccountAccess();h.context.signedInUser={id:'another'};
 resolve({data:{status:'approved'}});assert.equal(await loading,false);assert.equal(h.context.accountAccess,null);
});
test('notifications are scoped to recipient and escaped before rendering',async()=>{
 const h=harness({notifications:[{id:'notice',message:'<script>private</script>',created_at:'2026-10-20T00:00:00Z',read_at:null}]});
 await h.context.loadNotifications();assert.ok(h.calls.some(call=>call[0]==='eq'&&call[1]==='recipient_id'&&call[2]==='user-1'));
 assert.match(h.get('#notificationRows').innerHTML,/&lt;script&gt;/);assert.doesNotMatch(h.get('#notificationRows').innerHTML,/<script>/);
});
test('notification results arriving after account change are discarded',async()=>{
 let resolve;const promise=new Promise(done=>resolve=done);const h=harness({notificationPromise:promise});
 const loading=h.context.loadNotifications();h.context.signedInUser={id:'another'};
 resolve({data:[{message:'OLD ACCOUNT DATA'}]});await loading;assert.equal(h.get('#notificationRows').innerHTML,'');
});
test('non-owners and read-only compatibility users cannot approve accounts',async()=>{
 for(const admin of [false,true]){const h=harness({admin});h.context.accountAccess={can_review:admin};h.context.compatBlocked=true;
  h.context.accountRequests=[{user_id:'target'}];await h.context.reviewAccountRequest('target','approved');assert.equal(h.calls.filter(c=>c[0]==='rpc').length,0);
 }
});
test('approval submits the selected cafe and original request version',async()=>{
 const h=harness({admin:true,rpc:async name=>({data:name==='admin_pending_accounts'?[]:{status:'approved'},error:null})});
 h.context.accountAccess={can_review:true};h.context.accountRequests=[{user_id:'target',email:'target@example.com',updated_at:'original'}];
 await h.context.reviewAccountRequest('target','approved');
 const call=h.calls.find(c=>c[0]==='rpc'&&c[1]==='review_account');assert.ok(call);
 assert.deepEqual({...call[2]},{p_user_id:'target',p_cafe_id:'cafe-1',p_decision:'approved',p_reason:'',p_expected_updated_at:'original'});
});
test('rejection requires a reason and does not submit empty input',async()=>{
 const h=harness({admin:true});h.context.accountAccess={can_review:true};h.context.accountRequests=[{user_id:'target'}];h.context.window.prompt=()=> ' ';
 await h.context.reviewAccountRequest('target','rejected');assert.equal(h.calls.filter(c=>c[0]==='rpc').length,0);
 assert.match(h.get('#accountReviewMessage').textContent,/rejection reason/);
});
test('recovery emails and confirmation resend use Supabase Auth and neutral messages',async()=>{
 const h=harness();h.get('#authEmail').value='person@example.com';
 await h.context.sendAccountEmail('recovery');assert.ok(h.calls.some(c=>c[0]==='resetPasswordForEmail'&&c[2].redirectTo==='http://127.0.0.1:4174/?auth=recovery'));
 await h.context.sendAccountEmail('confirmation');assert.ok(h.calls.some(c=>c[0]==='resend'&&c[1].type==='signup'));
 assert.match(h.get('#authMessage').textContent,/If this email is eligible/);
 assert.ok(h.context.validateNewPassword('short'));assert.equal(h.context.validateNewPassword('a-long-new-password'),'');
});
test('password changes require recovery state and matching valid passwords',async()=>{
 const h=harness();h.get('#recoveryPassword').value='a-long-new-password';h.get('#recoveryConfirm').value='different-password';
 const submit=h.get('#passwordRecoveryForm').handlers.submit;await submit({preventDefault(){}});
 assert.equal(h.calls.some(c=>c[0]==='updateUser'),false);
 h.context.recoverySession=true;await submit({preventDefault(){}});assert.match(h.get('#recoveryMessage').textContent,/do not match/);
 h.get('#recoveryConfirm').value='a-long-new-password';await submit({preventDefault(){}});
 assert.ok(h.calls.some(c=>c[0]==='updateUser'));assert.equal(h.get('#recoveryPassword').value,'');assert.equal(h.context.recoverySession,false);
});
test('approval migration has server-only writes, an atomic decision and restrictive financial gates',()=>{
 const sql=fs.readFileSync(path.join(__dirname,'../supabase/2026-10-20-account-approval.sql'),'utf8');
 assert.match(sql,/revoke all on public\.user_account_access,public\.user_notifications from public,anon,authenticated/);
 assert.match(sql,/create policy "Approved accounts only" on public\.%I as restrictive/);
 assert.match(sql,/a\.status<>'pending' or a\.updated_at is distinct from p_expected_updated_at/);
 assert.match(sql,/Only the owning admin can review accounts/);assert.match(sql,/where user_id=p_user_id and owner_id=actor for update/);
 assert.match(sql,/if p_user_id=actor then raise exception/);
 assert.match(sql,/recipient_id=auth\.uid\(\)/);assert.match(sql,/exactly one existing cafe owner-admin/);
 assert.doesNotMatch(sql,/update\s+public\.(day_entries|journal_vouchers)\s+set/i);
 // SQL source assertions do not replace PostgreSQL/RLS execution tests.
});
