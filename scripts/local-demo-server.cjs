// ISOLATED SAMPLE BACKEND, not PostgreSQL/Supabase and never a deployment target.
// Uses only Node built-ins. No external network calls, production keys or packages.
const http=require('node:http'),fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const accounting=require('../public/accounting.js');
const DEMO_PASSWORD='LocalDemo12345!';
function createDemoServer(){
 const root=path.resolve(__dirname,'../public'),owner='00000000-0000-4000-8000-000000000001',pending='00000000-0000-4000-8000-000000000002',member='00000000-0000-4000-8000-000000000003',cafe='10000000-0000-4000-8000-000000000001';
 const db={users:[],sessions:new Map(),cafes:[{id:cafe,owner_id:owner,name:'ALAA CAFE · SAMPLE',location:'LOCAL DEMO',archived_at:null,created_at:new Date().toISOString()},{id:'10000000-0000-4000-8000-000000000002',owner_id:owner,name:'SECOND CAFE · SAMPLE',location:'LOCAL DEMO',archived_at:null,created_at:new Date().toISOString()}],members:[{cafe_id:cafe,user_id:member}],features:[],days:[],vouchers:[],options:[],events:[],notices:[]};
 let clock=Date.now();const stamp=()=>new Date(++clock).toISOString();
 const defaults={dayBook:true,sales:true,purchases:true,expenses:true,upiAccount:true,reportsPnl:true,journalEntry:true,cash:true,ledgers:true,rpos:false,addCafe:false,deleteCafe:false,manageAccounts:false};
 const hash=password=>{const salt=crypto.randomBytes(16).toString('hex');return {salt,digest:crypto.scryptSync(password,salt,64).toString('hex')}};
 const addUser=(id,email,status,role='user')=>{const user={id,email,status,role,owner_id:owner,reason:'',updated_at:stamp(),created_at:stamp(),password:hash(DEMO_PASSWORD)};db.users.push(user);return user};
 addUser(owner,'owner@alaa.test','approved','admin');addUser(pending,'pending@alaa.test','pending');addUser(member,'member@alaa.test','approved');
 db.features.push({cafe_id:cafe,user_id:member,features:{...defaults}});
 const notice=(recipient_id,subject_user_id,kind,message)=>{if(!db.notices.some(n=>n.recipient_id===recipient_id&&n.subject_user_id===subject_user_id&&n.kind===kind))db.notices.push({id:crypto.randomUUID(),recipient_id,subject_user_id,kind,message,created_at:stamp(),read_at:null})};
 notice(owner,pending,'registration_pending','Sample account approval requested: pending@alaa.test');
 for(const c of db.cafes)for(const account_name of ['Bank','Cash','Other Expenses','Purchases','Sales','UPI Account'])db.options.push({cafe_id:c.id,account_name,enabled:true});
 db.days.push({id:crypto.randomUUID(),owner_id:owner,cafe_id:cafe,entry_date:'2026-10-01',sale:1000,upi:300,purchase:200,other_expense:50,remarks:'SAMPLE DATA ONLY',voided_at:null,updated_at:stamp(),created_at:stamp()});
 const fail=(message,code='42501')=>{throw Object.assign(Error(message),{code})};
 const safeUser=user=>({id:user.id,email:user.email,app_metadata:{role:user.role}});
 const approved=user=>{if(!user||user.status!=='approved')fail('Account approval is required')};
 const owns=(user,id)=>!!user&&user.status==='approved'&&user.role==='admin'&&db.cafes.some(c=>c.id===id&&c.owner_id===user.id&&!c.archived_at);
 const accessible=(user,id)=>{approved(user);if(!db.cafes.some(c=>c.id===id&&!c.archived_at&&(c.owner_id===user.id||db.members.some(m=>m.cafe_id===id&&m.user_id===user.id))))fail('Cafe access is unavailable')};
 const allowed=(user,id,key)=>{accessible(user,id);return owns(user,id)||(db.features.find(f=>f.cafe_id===id&&f.user_id===user.id)?.features[key]??defaults[key])===true};
 const raw=(user,id)=>['dayBook','cash','ledgers','journalEntry','reportsPnl'].some(key=>allowed(user,id,key));
 const audit=(user,kind,row,old)=>db.events.push({id:crypto.randomUUID(),cafe_id:row.cafe_id||row.id,entity_type:kind,entity_id:row.id,event_type:row.voided_at?'void':row.archived_at?'archive':old?'update':'create',actor_id:user.id,old_record:old||null,new_record:structuredClone(row),occurred_at:stamp()});
 const event=(table,row)=>({table,cafe_id:row.cafe_id,user_id:row.user_id,recipient_id:row.recipient_id});
 const date=value=>typeof value==='string'&&/^\d{4}-\d{2}-\d{2}$/.test(value)&&!Number.isNaN(Date.parse(value+'T00:00:00Z'))&&new Date(value+'T00:00:00Z').toISOString().slice(0,10)===value;
 const notificationEvents=userId=>[{table:'user_account_access',user_id:userId},{table:'user_notifications',recipient_id:userId}];
 function rpc(user,name,a={}){
  if(!user)fail('Sign in first');
  if(name==='my_account_access')return {data:{status:user.status,reason:user.reason,can_review:user.status==='approved'&&user.id===owner&&user.role==='admin'}};
  if(name==='mark_notification_read'){const row=db.notices.find(n=>n.id===a.p_id&&n.recipient_id===user.id);if(row)row.read_at??=stamp();return {data:!!row,events:row?[event('user_notifications',row)]:[]}}
  approved(user);
  const cafeId=a.p_cafe_id;
  if(name==='admin_pending_accounts'){if(!owns(user,cafeId))fail('Only the owning admin can review accounts');return {data:db.users.filter(u=>u.owner_id===user.id&&u.status==='pending').slice(0,50).map(u=>({user_id:u.id,email:u.email,created_at:u.created_at,updated_at:u.updated_at}))}}
  if(name==='review_account'){
   if(!owns(user,cafeId))fail('Only the owning admin can review accounts');const target=db.users.find(u=>u.id===a.p_user_id&&u.owner_id===user.id);
   if(!target||target.status!=='pending'||target.updated_at!==a.p_expected_updated_at)fail('This request changed or was already reviewed','40001');
   if(!['approved','rejected'].includes(a.p_decision)||typeof a.p_reason!=='string'||a.p_reason.length>500||(a.p_decision==='rejected'&&!a.p_reason.trim()))fail('Enter a valid decision and rejection reason','22023');
   if(target.id===user.id)fail('You cannot approve your own account');
   target.status=a.p_decision;target.reason=a.p_reason.trim();target.updated_at=stamp();
   if(target.status==='approved'){if(!db.members.some(m=>m.cafe_id===cafeId&&m.user_id===target.id))db.members.push({cafe_id:cafeId,user_id:target.id});if(!db.features.some(f=>f.cafe_id===cafeId&&f.user_id===target.id))db.features.push({cafe_id:cafeId,user_id:target.id,features:Object.fromEntries(Object.keys(defaults).map(k=>[k,false]))})}
   notice(target.id,target.id,'registration_'+target.status,target.status==='approved'?'Your account was approved. Your owner controls feature access.':'Your account was rejected. Reason: '+target.reason);
   return {data:{status:target.status,user_id:target.id},events:notificationEvents(target.id)};
  }
  if(name==='admin_list_cafe_users'){if(!owns(user,cafeId))fail('Only the owning admin can manage users');return {data:db.members.filter(m=>m.cafe_id===cafeId).map(m=>({user_id:m.user_id,email:db.users.find(u=>u.id===m.user_id)?.email,features:db.features.find(f=>f.cafe_id===cafeId&&f.user_id===m.user_id)?.features||{...defaults}}))}}
  if(name==='cafe_accounting_snapshot'){
   accessible(user,cafeId);const all=raw(user,cafeId),sales=all||allowed(user,cafeId,'sales'),purchases=all||allowed(user,cafeId,'purchases'),expenses=all||allowed(user,cafeId,'expenses'),upi=all||allowed(user,cafeId,'upiAccount');
   const days=db.days.filter(d=>d.cafe_id===cafeId&&!d.voided_at&&(all||sales||purchases||expenses||upi)).map(d=>({...d,sale:sales?d.sale:0,upi:upi?d.upi:0,purchase:purchases?d.purchase:0,other_expense:expenses?d.other_expense:0,remarks:all?d.remarks:''}));
   const vouchers=db.vouchers.filter(v=>v.cafe_id===cafeId).flatMap(v=>{const lines=all?v.lines:accounting.voucherLinesForEdit(v.lines).filter(l=>(sales&&['Sales','Cash Sale'].includes(l.particulars))||(purchases&&l.particulars==='Purchases')||(expenses&&['Expenses','Other Expenses'].includes(l.particulars))||(upi&&l.particulars==='UPI Account'));return lines.length?[{...v,lines,remark:all?v.remark:''}]:[]});
   return {data:{day_entries:days,journal_vouchers:vouchers,journal_account_options:allowed(user,cafeId,'journalEntry')||allowed(user,cafeId,'manageAccounts')?db.options.filter(o=>o.cafe_id===cafeId):[]}};
  }
  if(name==='save_day_entry_checked'){
   if(!allowed(user,cafeId,'dayBook'))fail('Day Book is not enabled');const entry={sale:a.p_sale,upi:a.p_upi,purchase:a.p_purchase,otherExpense:a.p_other_expense},error=accounting.validateEntry(entry);if(error||!date(a.p_entry_date))fail(error||'Invalid date','22023');
   let row=db.days.find(d=>d.cafe_id===cafeId&&d.entry_date===a.p_entry_date);const values={sale:a.p_sale,upi:a.p_upi,purchase:a.p_purchase,other_expense:a.p_other_expense,remarks:a.p_remarks};
   if(row&&!row.voided_at&&a.p_expected_updated_at===null&&Object.keys(values).every(k=>row[k]===values[k]))return {data:row};
   if(row&&(row.voided_at||row.updated_at!==a.p_expected_updated_at)||!row&&a.p_expected_updated_at!==null)fail('This day entry changed elsewhere','40001');
   const old=row?structuredClone(row):null;if(!row){row={id:crypto.randomUUID(),owner_id:db.cafes.find(c=>c.id===cafeId).owner_id,cafe_id:cafeId,entry_date:a.p_entry_date,created_at:stamp(),voided_at:null};db.days.push(row)}
   Object.assign(row,values,{updated_at:stamp()});audit(user,'day_entry',row,old);return {data:row,events:[event('day_entries',row)]};
  }
  if(name==='save_journal_voucher_checked'){
   if(!allowed(user,cafeId,'journalEntry'))fail('Journal Entry is not enabled');const error=accounting.validateVoucherLines(a.p_lines);if(error||!date(a.p_voucher_date))fail(error||'Invalid date','22023');
   let row=db.vouchers.find(v=>v.id===a.p_id&&v.cafe_id===cafeId);const values={voucher_date:a.p_voucher_date,remark:a.p_remark,lines:a.p_lines};
   if(row&&!row.voided_at&&a.p_expected_updated_at===null&&Object.keys(values).every(k=>JSON.stringify(row[k])===JSON.stringify(values[k])))return {data:row};
   if(row&&(row.voided_at||row.updated_at!==a.p_expected_updated_at)||!row&&a.p_expected_updated_at!==null)fail('This voucher changed elsewhere','40001');
   const old=row?structuredClone(row):null;if(!row){row={id:a.p_id||crypto.randomUUID(),cafe_id:cafeId,owner_id:db.cafes.find(c=>c.id===cafeId).owner_id,voucher_no:Math.max(0,...db.vouchers.filter(v=>v.cafe_id===cafeId).map(v=>v.voucher_no))+1,voided_at:null,created_at:stamp()};db.vouchers.push(row)}
   Object.assign(row,values,{updated_at:stamp()});audit(user,'journal_voucher',row,old);return {data:row,events:[event('journal_vouchers',row)]};
  }
  if(name==='create_cafe_with_access'){
   if(!allowed(user,a.p_source_cafe_id,'addCafe'))fail('Add cafe is not enabled');const source=db.cafes.find(c=>c.id===a.p_source_cafe_id),name=String(a.p_name||'').trim(),location=String(a.p_location||'').trim();
   if(!name||name.length>80||!location||location.length>100)fail('Invalid cafe name or location','22023');
   if(db.cafes.some(c=>!c.archived_at&&c.owner_id===source.owner_id&&c.name.toLowerCase()===name.toLowerCase()&&c.location.toLowerCase()===location.toLowerCase()))fail('Cafe already exists','23505');
   const row={id:crypto.randomUUID(),owner_id:source.owner_id,name,location,archived_at:null,created_at:stamp()};db.cafes.push(row);
   if(user.id!==source.owner_id)db.members.push({cafe_id:row.id,user_id:user.id});audit(user,'cafe',row);return {data:row,events:[{table:'cafes'}]};
  }
  if(name==='delete_cafe_with_access'){
   if(!allowed(user,cafeId,'deleteCafe'))fail('Delete cafe is not enabled');const row=db.cafes.find(c=>c.id===cafeId);
   if(db.cafes.filter(c=>c.owner_id===row.owner_id&&!c.archived_at).length<2)fail('Keep at least one active cafe');const old=structuredClone(row);row.archived_at=stamp();row.archived_by=user.id;audit(user,'cafe',row,old);return {data:{id:cafeId},events:[{table:'cafes'}]};
  }
  fail('Unsupported isolated demo RPC: '+name,'PGRST202');
 }
 function query(user,q){
  if(!user)fail('Sign in first');const sources={cafes:db.cafes,day_entries:db.days,journal_vouchers:db.vouchers,journal_account_options:db.options,cafe_user_features:db.features,accounting_change_events:db.events,user_notifications:db.notices};
  const source=sources[q.table];if(!source)fail('Unsupported demo table');
  if(q.table!=='user_notifications')approved(user);
  let rows=source.filter(row=>{if(q.table==='user_notifications')return row.recipient_id===user.id;
   if(q.table==='cafes')return row.owner_id===user.id||db.members.some(m=>m.cafe_id===row.id&&m.user_id===user.id);
   if(q.table==='cafe_user_features')return row.user_id===user.id||owns(user,row.cafe_id);
   if(q.table==='accounting_change_events')return owns(user,row.cafe_id);
   try{return q.table==='journal_account_options'?(allowed(user,row.cafe_id,'journalEntry')||allowed(user,row.cafe_id,'manageAccounts')):raw(user,row.cafe_id)}catch{return false}
  });
  rows=rows.filter(row=>(q.filters||[]).every(f=>f.type==='gte'?row[f.field]>=f.value:f.type==='lt'?row[f.field]<f.value:f.type==='is'?(row[f.field]??null)===f.value:row[f.field]===f.value));
  if(q.action==='upsert'){
   if(!['cafe_user_features','journal_account_options'].includes(q.table))fail('Financial writes require checked RPCs');
   const values=Array.isArray(q.values)?q.values:[q.values],out=[];
   for(const value of values){const permission=q.table==='cafe_user_features'?owns(user,value.cafe_id):allowed(user,value.cafe_id,'manageAccounts');if(!permission)fail('Management permission is not enabled');
    if(q.table==='cafe_user_features'&&!db.members.some(m=>m.cafe_id===value.cafe_id&&m.user_id===value.user_id))fail('User is not a cafe member');
    const keys=q.table==='cafe_user_features'?['cafe_id','user_id']:['cafe_id','account_name'];let row=source.find(r=>keys.every(k=>r[k]===value[k]));
    if(!row){row={};source.push(row)}Object.assign(row,value,{updated_at:stamp()});out.push(row);
   }return {data:out,events:out.map(row=>event(q.table,row))};
  }
  if(q.action==='update'){
   if(!['day_entries','journal_vouchers'].includes(q.table)||Object.keys(q.values).some(k=>!['voided_at','voided_by'].includes(k)))fail('Only checked accounting writes are allowed');
   for(const row of rows){if(!owns(user,row.cafe_id)||q.values.voided_by!==user.id)fail('Only the owner can void records');const old=structuredClone(row);Object.assign(row,q.values,{updated_at:stamp()});audit(user,q.table==='day_entries'?'day_entry':'journal_voucher',row,old)}
  }else if(q.action!=='select')fail('Unsupported demo mutation');
  const count=rows.length;
  for(const sort of [...q.sort||[]].reverse())rows.sort((a,b)=>String(a[sort.field]??'').localeCompare(String(b[sort.field]??''))*(sort.ascending?1:-1));
  if(q.range)rows=rows.slice(q.range[0],q.range[1]+1);
  if(q.mode==='single'&&rows.length!==1)fail('Row changed or is not available','40001');
  return {data:q.options?.head?null:q.mode==='single'||q.mode==='maybe'?rows[0]||null:rows,count,events:q.action==='update'?rows.map(row=>event(q.table,row)):[]};
 }
 const server=http.createServer(async(req,res)=>{
  const headers=Object.fromEntries(JSON.parse(fs.readFileSync(path.join(root,'../vercel.json'),'utf8')).headers[0].headers.map(h=>[h.key,h.value]));
  headers['Content-Security-Policy']=headers['Content-Security-Policy'].replace(/connect-src [^;]+/,'connect-src \'self\'');
  for(const [key,value] of Object.entries(headers))res.setHeader(key,value);res.setHeader('Cache-Control','no-store');
  const url=new URL(req.url,'http://127.0.0.1');
  if(url.pathname==='/__demo/api'){
   res.setHeader('Content-Type','application/json');
   try{
    if(req.method!=='POST')fail('POST required');if(req.headers.origin&&req.headers.origin!=='http://'+req.headers.host)fail('Cross-origin requests are not allowed');
    let body='';for await(const part of req){body+=part;if(body.length>1000000)fail('Request too large')}
    const q=JSON.parse(body),user=db.users.find(u=>u.id===db.sessions.get(req.headers['x-demo-session']));let result;
    if(q.operation==='signin'){const found=db.users.find(u=>u.email.toLowerCase()===String(q.values.email).trim().toLowerCase());
     if(!found||!crypto.timingSafeEqual(Buffer.from(found.password.digest,'hex'),crypto.scryptSync(String(q.values.password),found.password.salt,64)))fail('Invalid demo login','invalid_credentials');
     const token=crypto.randomUUID();db.sessions.set(token,found.id);result={data:{user:safeUser(found),session:{access_token:token,user:safeUser(found)}}};
    }else if(q.operation==='signup'){
     const email=String(q.values.email||'').trim().toLowerCase(),password=String(q.values.password||'');if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)||password.length<12||password.length>128)fail('Use a valid email and a 12–128 character password','22023');
     if(!db.users.some(u=>u.email===email)){const added=addUser(crypto.randomUUID(),email,'pending');added.password=hash(password);notice(owner,added.id,'registration_pending','Sample account approval requested: '+email)}
     result={data:{user:null,session:null},events:[{table:'user_notifications',recipient_id:owner}]};
    }else if(q.operation==='session'){result={data:{session:user?{user:safeUser(user)}:null}}}
    else if(q.operation==='signout'){db.sessions.delete(req.headers['x-demo-session']);result={data:null}}
    else if(q.operation==='password'){if(!user)fail('Sign in first');const password=String(q.values.password||'');if(password.length<12||password.length>128)fail('Invalid password','22023');user.password=hash(password);result={data:{user:safeUser(user)}}}
    else if(q.operation==='rpc')result=rpc(user,q.name,q.args);
    else if(q.operation==='query')result=query(user,q);else fail('Unknown operation');
    res.end(JSON.stringify({error:null,...result}));
   }catch(error){res.end(JSON.stringify({data:null,error:{message:error.message,code:error.code||'demo_error'}}))}return;
  }
  if(url.pathname==='/__local-demo.js'){res.setHeader('Content-Type','text/javascript; charset=utf-8');res.end(fs.readFileSync(path.join(__dirname,'local-demo-client.js')));return}
  let relative;try{relative=decodeURIComponent(url.pathname)}catch{res.writeHead(400).end();return}
  const file=path.resolve(root,'.'+(relative==='/'?'/index.html':relative));if(!file.startsWith(root+path.sep)){res.writeHead(403).end();return}
  if(!fs.existsSync(file)||!fs.statSync(file).isFile()){res.writeHead(404).end('Not found');return}
  const type={'.html':'text/html; charset=utf-8','.js':'text/javascript; charset=utf-8','.webmanifest':'application/manifest+json','.png':'image/png','.jpg':'image/jpeg','.json':'application/json'}[path.extname(file)]||'application/octet-stream';res.setHeader('Content-Type',type);
  let content=fs.readFileSync(file);
  if(file===path.join(root,'index.html')){
   const banner='<aside style="background:#fff4d6;color:#553119;padding:12px;text-align:center;border-bottom:2px solid #b9872f"><strong>ISOLATED LOCAL DEMO — SAMPLE DATA ONLY</strong><div>No Supabase connection. Email delivery is simulated. Data resets when this server restarts.</div><div>Sample password: LocalDemo12345! · Fill login: <button type="button" data-demo-email="owner@alaa.test">Owner</button> <button type="button" data-demo-email="pending@alaa.test">Pending user</button> <button type="button" data-demo-email="member@alaa.test">Approved member</button></div></aside>';
   content=content.toString('utf8').replace(/<script>(?=\s*const \$=)/,'<script src="/__local-demo.js"></script><script>').replace('<body class="auth-initializing">','<body class="auth-initializing">'+banner);
  }
  res.end(content);
 });
 return server;
}
if(require.main===module)createDemoServer().listen(Number(process.env.ALAA_DEMO_PORT||4175),'127.0.0.1',()=>console.log('Isolated sample preview: http://127.0.0.1:4175/ — no Supabase connection'));
module.exports={createDemoServer,DEMO_PASSWORD};
