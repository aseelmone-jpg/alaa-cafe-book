const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const html=fs.readFileSync(require('node:path').join(__dirname,'../public/index.html'),'utf8');
const code=html.slice(html.indexOf('async function loadSettingsUsers(){'),html.indexOf('function scheduleRealtimeRefresh('));
function deferred(){let resolve;const promise=new Promise(done=>resolve=done);return {promise,resolve}}
function harness(){
 const nodes=new Map(),calls=[];const get=key=>{if(!nodes.has(key)){const names=new Set();nodes.set(key,{value:'',innerHTML:'',textContent:'',disabled:false,classList:{contains:n=>names.has(n),add:n=>names.add(n),remove:n=>names.delete(n)}})}return nodes.get(key)};
 const c={signedInUser:{id:'owner'},cafe:{id:'cafe-1'},settingsUsers:[],settingsContext:null,settingsLoadSequence:0,reviewSequence:0,
  featureDefaults:{sales:false,dayBook:false},$:get,currentShop:()=>c.cafe,isAdmin:()=>!!c.signedInUser,
  readOnly:false,accountingWritesBlocked:()=>c.readOnly,escapeText:String,renderSettingsFeatures:features=>{c.rendered=features},window:{alert:message=>calls.push(['alert',message])},
  document:{querySelectorAll:()=>[{dataset:{settingFeature:'sales'},checked:true}]},
  supabaseClient:{rpc:async(name,args)=>{calls.push(['rpc',name,args]);return c.loadResult||{data:[{user_id:'member',email:'member@test',features:{sales:false}}]}},
   from:table=>({upsert:async value=>{calls.push(['upsert',table,value]);return c.saveResult||{error:null}}})}};
 vm.runInNewContext(code+'\n'+html.split('\n').find(l=>l.startsWith('function closeSettings(){')),c);return {c,get,calls};
}
test('settings load discards responses after user/cafe changes or dialog close',async()=>{
 for(const change of ['user','cafe','close']){const {c,get}=harness(),d=deferred();c.loadResult=d.promise;
  const pending=c.loadSettingsUsers();if(change==='user')c.signedInUser={id:'other'};if(change==='cafe')c.cafe={id:'cafe-2'};if(change==='close')c.closeSettings();
  d.resolve({data:[{user_id:'old',email:'OLD PRIVATE DATA'}]});await pending;
  assert.equal(c.settingsUsers.length,0);assert.equal(c.settingsContext,null);assert.doesNotMatch(get('#settingsUser').innerHTML,/OLD PRIVATE/);
 }
});
test('newer settings load wins when earlier load finishes last',async()=>{
 const {c}=harness(),d=deferred();c.loadResult=d.promise;const old=c.loadSettingsUsers();
 c.loadResult={data:[{user_id:'new',features:{sales:true}}]};await c.loadSettingsUsers();
 d.resolve({data:[{user_id:'old'}]});await old;assert.equal(c.settingsUsers[0].user_id,'new');
});
test('settings cannot save old cafe permissions into a different cafe',async()=>{
 const {c,get,calls}=harness();await c.loadSettingsUsers();get('#settingsUser').value='member';c.cafe={id:'cafe-2'};
 await c.saveFeatureSettings();assert.equal(calls.filter(call=>call[0]==='upsert').length,0);
});
test('settings save captures cafe and ignores its response after session/dialog change',async()=>{
 const {c,get,calls}=harness();await c.loadSettingsUsers();get('#settingsUser').value='member';const d=deferred();c.saveResult=d.promise;
 const pending=c.saveFeatureSettings();const request=calls.find(call=>call[0]==='upsert');assert.equal(request[2].cafe_id,'cafe-1');
 c.closeSettings();get('#settingsMessage').textContent='NEW CONTEXT';d.resolve({error:null});await pending;
 assert.equal(get('#settingsMessage').textContent,'NEW CONTEXT');assert.equal(get('#saveFeatureSettings').disabled,true);
});
test('settings network errors remain visible and prevent permission writes',async()=>{
 const {c,get,calls}=harness();c.supabaseClient.rpc=async()=>{throw Error('offline')};await c.loadSettingsUsers();
 assert.match(get('#settingsMessage').textContent,/offline/);assert.equal(c.settingsContext,null);
 assert.equal(get('#saveFeatureSettings').disabled,true);await c.saveFeatureSettings();assert.equal(calls.length,0);
});
test('successful permission save updates only the assigned user from the loaded context',async()=>{
 const {c,get,calls}=harness();await c.loadSettingsUsers();get('#settingsUser').value='unassigned';await c.saveFeatureSettings();
 assert.equal(calls.filter(call=>call[0]==='upsert').length,0);
 get('#settingsUser').value='member';await c.saveFeatureSettings();assert.equal(c.settingsUsers[0].features.sales,true);
 assert.match(get('#settingsMessage').textContent,/saved for member@test/);
});
test('read-only compatibility mode blocks settings writes even with a valid loaded context',async()=>{
 const {c,get,calls}=harness();await c.loadSettingsUsers();get('#settingsUser').value='member';c.readOnly=true;
 await c.saveFeatureSettings();assert.equal(calls.filter(call=>call[0]==='upsert').length,0);
 assert.match(calls.find(call=>call[0]==='alert')[1],/read-only/);
});
