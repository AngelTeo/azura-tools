// Regression against the actual candidate HTML, not a separately rewritten model.
// All fixtures are anonymous and synthetic. Never invokes RPC or writes data.
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';
const html=readFileSync(new URL('../../OPR/KedaiRuncit.html',import.meta.url),'utf8');
const block=(a,b)=>{const i=html.indexOf(a),j=html.indexOf(b,i+1);assert(i>=0&&j>i);return html.slice(i,j);};
const source=block('function personalSpecs(','/* ================= Leader phone')+'\n'+block('function handValidation(','function detailHand(id)')+'\n'+html.match(/function detailPriceOk\(v\)\{[^\n]+/)[0]+'\nreturn {specFromDetail,mergeDetailSpec,handValidation,handAmounts};';
const m=new Function(source)();
const it={label:'PANTS - SHORT'},l={status:'BOUGHT',kind:'PERSONAL',qty:2,buy:{price:18}},d={date:'2026-11-27',shares:[],sell:20,wpaid:false};
const tests=[
 ['preserve clothing style',()=>assert.equal(m.mergeDetailSpec(it,'7 分','XL'),'7 分 · XL')],
 ['change size without erasing style',()=>assert.equal(m.mergeDetailSpec(it,'7 分 · XL','L'),'7 分 · L')],
 ['missing size blocked',()=>assert.equal(m.specFromDetail(it,'7 分'),null)],
 ['combined style and size valid',()=>assert.equal(m.specFromDetail(it,'7 分 · XL'),'XL')],
 ['legacy size suffix accepted',()=>assert.equal(m.specFromDetail({label:'SHIRT'},'L 号'),'L')],
 ['plain size accepted',()=>assert.equal(m.specFromDetail(it,'XL'),'XL')],
 ['unpaid charge',()=>assert.equal(m.handAmounts(l,d).deduction,40)],
 ['paid cash no deduction',()=>assert.equal(m.handAmounts(l,{...d,wpaid:true}).deduction,0)],
 ['future date blocked',()=>assert.equal(m.handValidation(l,{...d,date:'2026-11-28'},'2026-11-27'),false)],
 ['missing sell blocked',()=>assert.equal(m.handValidation(l,{...d,sell:''},'2026-11-27'),false)],
 ['valid handover',()=>assert.equal(m.handValidation(l,d,'2026-11-27'),true)],
 ['missing shared recipients blocked',()=>assert.equal(m.handValidation({...l,kind:'SHARED'},d,'2026-11-27'),false)]
];
for(const [name,run] of tests){run();console.log('PASS '+name);}
console.log(tests.length+' source regression checks PASS');
