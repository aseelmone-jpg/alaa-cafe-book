const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const crypto=require('node:crypto');
const vm=require('node:vm');
const root=path.resolve(__dirname,'..');
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
const html=read('public/index.html').replace(/\r\n/g,'\n');

test('permission fallback inspects navigation tabs, never active auth buttons',()=>{
 const code=html.slice(html.indexOf('function setRoleAccess(){'),html.indexOf('async function loadUserFeatureAccess(){'));
 const selectors=[],nodes=new Map();let selected=false;
 const node=()=>({classList:{toggle(){},add(){},remove(){}},parentElement:null});
 const context={isAdmin:()=>false,userFeatureAccess:{dayBook:false,sales:true},canUseFeature:()=>false,canUseManagementFeature:()=>false,canDeleteCafe:()=>false,
  $:key=>{if(!nodes.has(key))nodes.set(key,node());return nodes.get(key)},
  document:{querySelectorAll:()=>[],querySelector:selector=>{selectors.push(selector);if(selector==='.tabs .tab.active,#rposTab.active')return {classList:{contains:()=>true}};if(selector==='.tabs .tab:not(.hide)')return {click:()=>selected=true};return null}}};
 vm.runInNewContext(code+'\nsetRoleAccess();',context);
 assert.equal(selected,true);assert.ok(!selectors.includes('.tab.active'));
});

test('Supabase SDK is pinned, local and matches its integrity attribute',()=>{
 const script=html.match(/<script src="(\/vendor\/supabase-[\d.]+\.js)" integrity="sha384-([^"]+)"/);
 assert.ok(script);const bytes=fs.readFileSync(path.join(root,'public',script[1]));
 assert.equal(crypto.createHash('sha384').update(bytes).digest('base64'),script[2]);
 assert.doesNotMatch(html,/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@2/);
 new vm.Script(bytes.toString('utf8'));
});

test('CSP matches every current inline script and protects framing and content types',()=>{
 const config=JSON.parse(read('vercel.json'));
 const headers=Object.fromEntries(config.headers[0].headers.map(header=>[header.key,header.value]));
 const csp=headers['Content-Security-Policy'];assert.ok(csp);
 for(const match of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)){
  if(/\bsrc\s*=/.test(match[1]))continue;
  assert.ok(csp.includes("'sha256-"+crypto.createHash('sha256').update(match[2]).digest('base64')+"'"),'Run node scripts/security-headers.cjs after changing inline JavaScript');
 }
 assert.match(csp,/frame-ancestors 'none'/);assert.match(csp,/object-src 'none'/);
 assert.doesNotMatch(csp.split(';').find(rule=>rule.includes('script-src')),/unsafe-inline|unsafe-eval/);
 assert.equal(headers['X-Content-Type-Options'],'nosniff');assert.equal(headers['X-Frame-Options'],'DENY');
 for(const [key,value] of Object.entries(headers))assert.ok(read('public/_headers').includes(key+': '+value));
});

test('legacy shared financial caches are removed without clearing Supabase session persistence',()=>{
 const line=html.split('\n').find(line=>line.startsWith('function purgeLegacyFinancialCaches()'));
 const removed=[];vm.runInNewContext(line+';purgeLegacyFinancialCaches()',{localStorage:{removeItem:key=>removed.push(key)}});
 assert.deepEqual(removed,['alaa-cafes-v1','alaa-ledger-v1']);
 assert.doesNotMatch(line,/localStorage\.clear|sb-/);
});

test('combined schema is one transaction with valid function delimiters',()=>{
 const schema=read('supabase/schema.sql');
 assert.equal((schema.match(/^begin;$/gm)||[]).length,1);
 assert.equal((schema.match(/^commit;$/gm)||[]).length,1);
 assert.doesNotMatch(schema,/^\s*as\s+\$\s*$|^\$;\s*$/m);
 assert.equal(schema,read('schema.sql'));
});

test('checked journal SQL specifies idempotent creates and rejects stale edits',()=>{
 const sql=read('supabase/2026-10-06-audit-fixes.sql');
 assert.match(sql,/saved\.voucher_date=p_voucher_date and saved\.remark=p_remark and saved\.lines=p_lines then return saved/);
 assert.match(sql,/values\(coalesce\(p_id,gen_random_uuid\(\)\)/);
 assert.match(sql,/saved\.updated_at is distinct from p_expected_updated_at/);
 assert.match(sql,/pg_advisory_xact_lock/);
 // This is a source regression check; executing PostgreSQL is a separate integration requirement.
});

test('Day Book save lock fails fast and keeps the same-date row lock key',()=>{
 const sql=read('supabase/2026-10-26-daybook-save-lock-guard.sql');
 assert.match(sql,/pg_try_advisory_xact_lock\(pg_catalog\.hashtextextended\(p_cafe_id::text\|\|':day:'\|\|p_entry_date::text,0\)\)/);
 assert.match(sql,/using errcode='55P03'/);
 assert.match(sql,/for update/);
});

test('installation manifest icons exist with their declared dimensions',()=>{
 const manifest=JSON.parse(read('public/manifest.webmanifest'));assert.equal(manifest.short_name,'ALAA CAFE');
 for(const icon of manifest.icons){const png=fs.readFileSync(path.join(root,'public',icon.src));
  assert.equal(png.subarray(1,4).toString(),'PNG');
  assert.equal(png.readUInt32BE(16)+'x'+png.readUInt32BE(20),icon.sizes);
 }
});
