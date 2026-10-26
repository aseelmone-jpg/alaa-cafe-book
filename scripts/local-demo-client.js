// Test-only Supabase-shaped adapter. This file is never placed in public/.
// The local demo server blocks every non-local connection through CSP.
(() => {
 const key='alaa-isolated-demo-session';
 const listeners=new Set(),subscriptions=new Set();
 const bus=typeof BroadcastChannel==='function'?new BroadcastChannel('alaa-isolated-demo'):null;
 const dispatch=event=>{for(const sub of subscriptions){const match=sub.filter.filter?.split('=eq.');
  if(sub.filter.table===event.table&&(!match||event[match[0]]===match[1]))sub.callback({eventType:'UPDATE'});
 }};
 if(bus)bus.onmessage=event=>dispatch(event.data);
 async function api(operation,args={}){
  try{const response=await fetch('/__demo/api',{method:'POST',headers:{'Content-Type':'application/json','X-Demo-Session':sessionStorage.getItem(key)||''},body:JSON.stringify({operation,...args})});
   const result=await response.json();for(const event of result.events||[]){dispatch(event);bus?.postMessage(event)}return result;
  }catch(error){return {data:null,error:{message:'Local demo connection failed: '+error.message}}}
 }
 const emit=(event,session)=>{for(const listener of listeners)listener(event,session)};
 const client={
  auth:{
   async getSession(){const result=await api('session');return {data:{session:result.data?.session||null},error:result.error}},
   onAuthStateChange(listener){listeners.add(listener);return {data:{subscription:{unsubscribe:()=>listeners.delete(listener)}}}},
   async signInWithPassword(values){const result=await api('signin',{values});if(!result.error){sessionStorage.setItem(key,result.data.session.access_token);emit('SIGNED_IN',result.data.session)}return result},
   signUp:values=>api('signup',{values}),
   async signOut(){await api('signout');sessionStorage.removeItem(key);emit('SIGNED_OUT',null);return {error:null}},
   async resetPasswordForEmail(){return {error:{message:'Email delivery is not connected in the isolated demo. Recovery behavior is covered by mocked tests; no real email was sent.'}}},
   async resend(){return {error:{message:'Email confirmation is skipped for sample accounts only. No real email was sent.'}}},
   async updateUser(values){return api('password',{values})},
  },
  rpc:(name,args)=>api('rpc',{name,args}),
  from(table){
   let operation='select',values,columns='*',options={},mode='many',range,sort=[];const filters=[];
   const query={select(c='*',o={}){columns=c;options=o;return query},eq:(field,value)=>{filters.push({type:'eq',field,value});return query},
    is:(field,value)=>{filters.push({type:'is',field,value});return query},gte:(field,value)=>{filters.push({type:'gte',field,value});return query},lt:(field,value)=>{filters.push({type:'lt',field,value});return query},
    order(field,o={}){sort.push({field,ascending:o.ascending!==false});return query},range(a,b){range=[a,b];return query},
    update(data){operation='update';values=data;return query},upsert(data){operation='upsert';values=data;return query},
    insert(data){operation='insert';values=data;return query},single(){mode='single';return query},maybeSingle(){mode='maybe';return query},
    then(resolve,reject){return api('query',{table,action:operation,values,columns,options,filters,mode,range,sort}).then(resolve,reject)}};return query;
  },
  channel(){const owned=[];const channel={on(type,filter,callback){const sub={filter,callback};owned.push(sub);subscriptions.add(sub);return channel},subscribe(callback){queueMicrotask(()=>callback?.('SUBSCRIBED'));return channel},owned};return channel},
  async removeChannel(channel){for(const sub of channel.owned||[])subscriptions.delete(sub)},
 };
 window.supabase={createClient:()=>client};
 document.addEventListener('DOMContentLoaded',()=>{
  for(const button of document.querySelectorAll('[data-demo-email]'))button.addEventListener('click',()=>{
   document.getElementById('authEmail').value=button.dataset.demoEmail;document.getElementById('authPassword').value='LocalDemo12345!';
  });
 });
})();
