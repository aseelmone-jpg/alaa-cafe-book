// Prepare ONLY the approved Journal calculation update from the verified live baseline.
// No network, package installation, database write, Git operation or deployment.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const root=path.resolve(__dirname,'..'),baseline=path.join(root,'work/install-release');
const release=path.join(root,'work/journal-direction-release');
fs.mkdirSync(path.join(release,'public'),{recursive:true});
fs.cpSync(path.join(baseline,'public'),path.join(release,'public'),{recursive:true});
fs.copyFileSync(path.join(baseline,'vercel.json'),path.join(release,'vercel.json'));
fs.mkdirSync(path.join(release,'.vercel'),{recursive:true});
fs.copyFileSync(path.join(baseline,'.vercel/project.json'),path.join(release,'.vercel/project.json'));
const normalize=s=>s.replace(/\r\n/g,'\n');
const latest=normalize(fs.readFileSync(path.join(root,'public/accounting.js'),'utf8'));
let accounting=normalize(fs.readFileSync(path.join(baseline,'public/accounting.js'),'utf8'));
let html=normalize(fs.readFileSync(path.join(baseline,'public/index.html'),'utf8'));
function replaceOnce(text,before,after){if(!text.includes(before)||text.indexOf(before)!==text.lastIndexOf(before))throw Error('Expected one occurrence: '+before.slice(0,100));return text.replace(before,()=>after)}
const oldBalance='const balanceChange = line.transferRole === \'source\' ? -value : line.transferRole === \'destination\' ? value : legacyTransfer ? debit - credit : credit - debit;';
const postingStart=latest.indexOf('        const normalDebit =');
const postingEnd=latest.indexOf('\n        return [{',postingStart);
accounting=replaceOnce(accounting,oldBalance,latest.slice(postingStart,postingEnd).trimStart());
const saveStart=accounting.indexOf('  function voucherLinesForSave('),saveEnd=accounting.indexOf('  function formatMoney(',saveStart);
const latestStart=latest.indexOf('  function voucherNeedsPostingReview('),latestEnd=latest.indexOf('  function formatMoney(',latestStart);
accounting=accounting.slice(0,saveStart)+latest.slice(latestStart,latestEnd)+accounting.slice(saveEnd);
accounting=replaceOnce(accounting,'voucherLinesForEdit, voucherLinesForSave, formatMoney','voucherLinesForEdit, voucherNeedsPostingReview, voucherLinesForSave, formatMoney');
html=replaceOnce(html,'<script src="./accounting.js"></script>','<script src="./accounting.js?v=journal-20261021"></script>');
html=replaceOnce(html,'<p class="journal-note">','<div id="journalCorrectionNotice" class="journal-note hide"><label><input id="journalCorrectPosting" type="checkbox"> Apply corrected Debit/Credit calculation to this voucher</label><p>This saved adjustment uses the old opposite calculation. Opening it does not change balances. Select this option only after reviewing the accounts and amounts, then Save to record the correction.</p></div><p class="journal-note">');
html=replaceOnce(html,'}],editingVoucherId=null;','}],editingVoucherId=null,journalEditVersion=null;');
html=replaceOnce(html,'const current=shop.journalVouchers.find(v=>v.id===editingVoucherId);if(journalDraftLines.length>1)',"const current=shop.journalVouchers.find(v=>v.id===editingVoucherId);const needsReview=!!current&&CafeAccounting.voucherNeedsPostingReview(current.lines);$('#journalCorrectionNotice').classList.toggle('hide',!needsReview);if(!needsReview)$('#journalCorrectPosting').checked=false;if(journalDraftLines.length>1)");
html=replaceOnce(html,'editingVoucherId=voucher.id;journalDraftLines=',"editingVoucherId=voucher.id;journalEditVersion=voucher.updatedAt||null;$('#journalCorrectPosting').checked=false;journalDraftLines=");
html=replaceOnce(html,'CafeAccounting.voucherLinesForSave(journalDraftLines,existing?.lines||[])',"CafeAccounting.voucherLinesForSave(journalDraftLines,existing?.lines||[],$('#journalCorrectPosting').checked===true)");
html=replaceOnce(html,'const voucherNo=existing?.voucherNo||nextVoucherNo(),payload=',"if(existing&&!journalEditVersion){window.alert('Reload this voucher before saving; its edit version is unavailable.');return}if(existing&&CafeAccounting.voucherNeedsPostingReview(existing.lines)&&lines.some(line=>line.postingRule)&&!window.confirm('This applies the corrected Debit/Credit calculation to this voucher. Review the amounts and direction. Continue?'))return;const voucherNo=existing?.voucherNo||nextVoucherNo(),payload=");
html=replaceOnce(html,".eq('id',existing.id).eq('cafe_id',currentShop().id);else query=query.insert(payload)",".eq('id',existing.id).eq('cafe_id',currentShop().id).is('voided_at',null).eq('updated_at',journalEditVersion);else query=query.insert(payload)");
html=replaceOnce(html,'const saved={id:data.id,voucherNo:', 'const saved={id:data.id,updatedAt:data.updated_at,voucherNo:');
html=replaceOnce(html,"else list[index]=saved;editingVoucherId=null;journalDraftLines=","else list[index]=saved;editingVoucherId=null;journalEditVersion=null;$('#journalCorrectPosting').checked=false;journalDraftLines=");
html=replaceOnce(html,'map(v=>({id:v.id,voucherNo:', 'map(v=>({id:v.id,updatedAt:v.updated_at,voucherNo:');
html=replaceOnce(html,'map(voucher=>({id:voucher.id,voucherNo:', 'map(voucher=>({id:voucher.id,updatedAt:voucher.updated_at,voucherNo:');
// Avoid claiming every account is debit-normal in the existing transfer selector.
html=html.replaceAll('Debit / To · destination (+)','Debit / To').replaceAll('Credit / From · source (−)','Credit / From');
new vm.Script(accounting);
for(const m of html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi))if(!/\bsrc\s*=/.test(m[1]))new vm.Script(m[2]);
if(/my_account_access|cafe_accounting_snapshot|save_journal_voucher_checked|passwordRecoveryForm|payment_splits_version/.test(html))throw Error('Unrelated pending backend/UI changes entered targeted release');
fs.writeFileSync(path.join(release,'public/accounting.js'),accounting);
fs.writeFileSync(path.join(release,'public/index.html'),html);
console.log('Prepared journal-only release: '+release);
