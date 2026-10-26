// Read-only local release checks. Never connects to a database or deploys.
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const {spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..');
let failures=0;
function check(name,fn){try{fn();console.log('PASS '+name)}catch(error){failures++;console.error('FAIL '+name+': '+error.message)}}
const read=file=>fs.readFileSync(path.join(root,file),'utf8');
for(const file of ['accounting.js','public/accounting.js','pwa-install.js','public/pwa-install.js','scripts/security-headers.cjs','scripts/local-demo-server.cjs','scripts/local-demo-client.js','scripts/verify.cjs'])check('JavaScript syntax: '+file,()=>new vm.Script(read(file),{filename:file}));
for(const file of ['index.html','public/index.html'])check('Inline JavaScript syntax: '+file,()=>{
 let count=0;
 for(const match of read(file).matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)){
  if(/\bsrc\s*=/i.test(match[1]))continue;
  new vm.Script(match[2],{filename:file+' inline script '+(++count)});
 }
 if(!count)throw Error('No inline application scripts found');
});
for(const [a,b] of [['index.html','public/index.html'],['accounting.js','public/accounting.js'],['pwa-install.js','public/pwa-install.js'],['manifest.webmanifest','public/manifest.webmanifest'],['schema.sql','supabase/schema.sql']])check('Matching copies: '+a+' / '+b,()=>{
 if(read(a).replace(/\r\n/g,'\n')!==read(b).replace(/\r\n/g,'\n'))throw Error('Copies differ');
});
check('SQL delimiter safety scan (not database validation)',()=>{
 const files=['schema.sql',...fs.readdirSync(path.join(root,'supabase')).filter(f=>f.endsWith('.sql')).map(f=>'supabase/'+f)];
 const invalid=[];
 for(const file of files)read(file).split(/\r?\n/).forEach((line,i)=>{
  if(/^\s*as\s+\$\s*$/i.test(line)||/^\s*\$;\s*$/.test(line))invalid.push(file+':'+(i+1));
 });
 if(invalid.length)throw Error('Malformed single-dollar function delimiters at '+invalid.join(', '));
});
const tests=fs.readdirSync(path.join(root,'tests')).filter(file=>file.endsWith('.test.cjs')).sort().map(file=>path.join(root,'tests',file));
if(!tests.length){failures++;console.error('FAIL No tests found')}else{
 const result=spawnSync(process.execPath,['--test',...tests],{cwd:root,stdio:'inherit'});
 if(result.error||result.status!==0){failures++;console.error('FAIL Existing tests'+(result.error?': '+result.error.message:''))}
 else console.log('PASS Existing tests');
}
console.log('\nBuild/lint/typecheck: not configured; not reported as passing.');
console.log('Production database, RLS, browser workflows and deployment: not exercised.');
console.log(failures?'RELEASE BLOCKED: '+failures+' check(s) failed.':'LOCAL CHECKS PASSED. Production preflight and explicit release approval are still required.');
process.exitCode=failures?1:0;
