import {planStock,issueCost,routeDirect,restockQty,saleSnapshot} from './warehouse-core.mjs';
const checks=[];
function test(name,fn){fn();checks.push(name);}
function eq(actual,expected){if(JSON.stringify(actual)!==JSON.stringify(expected))throw Error(JSON.stringify({actual,expected}));}
function throws(fn){let yes=false;try{fn();}catch(e){yes=true;}if(!yes)throw Error('Expected rejection');}
const batches=[{id:'B1',itemId:'A',receivedAt:'2026-11-01',qty:12,unitCostCents:4800},{id:'B2',itemId:'A',receivedAt:'2026-11-20',qty:50,unitCostCents:5100}];
const req=(id,openQty,extra={})=>({id,itemId:'A',askedAt:'2026-11-27T00:00:00',openQty,...extra});
test('FIFO reservation across batches',()=>eq(planStock({batches,requests:[req('R1',14)]}).proposed,[{requestId:'R1',batchId:'B1',qty:12},{requestId:'R1',batchId:'B2',qty:2}]));
test('Available excludes reserved quantity',()=>eq(planStock({batches,requests:[req('R1',4)]}).balances[0],{itemId:'A',physical:62,reserved:4,available:58,inventoryCostCents:312600}));
test('Existing reservations are not allocated twice',()=>eq(planStock({batches,requests:[req('R1',4)],reservations:[{requestId:'R1',batchId:'B1',qty:4}]}).proposed,[]));
test('Two requests cannot reserve same unit',()=>eq(planStock({batches,requests:[req('R1',60),req('R2',5)]}).routes.map(r=>[r.ready,r.toBuy]),[[60,0],[2,3]]));
test('Shortage only, not whole request',()=>eq(planStock({batches:[{...batches[0],qty:5}],requests:[req('R1',8)]}).routes[0].toBuy,3));
test('Inbound order not counted as physical stock',()=>eq(planStock({batches:[],requests:[req('R1',8,{orderedQty:5})]}).routes[0],{requestId:'R1',itemId:'A',ready:0,ordered:5,toBuy:3,blocked:0,approvalBlocked:false}));
test('Approval gates new reservation',()=>eq(planStock({batches,requests:[req('R1',4,{approved:false})]}).routes[0].blocked,4));
test('Preserve FIFO priority by request date',()=>eq(planStock({batches:[{...batches[0],qty:2}],requests:[req('R1',2),req('R2',2,{askedAt:'2026-11-26'})]}).routes.map(r=>r.ready),[2,0]));
test('Reject over-reservation',()=>throws(()=>planStock({batches,requests:[req('R1',13)],reservations:[{requestId:'R1',batchId:'B1',qty:13}]})));
test('Reject reservations for wrong SKU',()=>throws(()=>planStock({batches,requests:[req('R1',1,{itemId:'B'})],reservations:[{requestId:'R1',batchId:'B1',qty:1}]})));
test('Release reservation on cancellation in next server snapshot',()=>eq(planStock({batches,requests:[],reservations:[]}).balances[0].available,62));
test('Partial FIFO issue across batches',()=>eq(issueCost({batches,allocations:[{requestId:'R1',batchId:'B1',qty:12},{requestId:'R1',batchId:'B2',qty:2}],requestId:'R1',qty:13}).costCents,62700));
test('Cannot issue more than allocated',()=>throws(()=>issueCost({batches,allocations:[{requestId:'R1',batchId:'B1',qty:2}],requestId:'R1',qty:3})));
test('Direct purchase partial receipt',()=>eq(routeDirect({openQty:5,receivedQty:2,orderedQty:1}),{ready:2,ordered:1,toBuy:2,blocked:0,approvalBlocked:false}));
test('Restock pack minimum and shortage',()=>eq(restockQty({shortage:3,packSize:10,minOrder:20}),20));
test('No surplus buying when adequate',()=>eq(restockQty({available:12,minAvailable:10,packSize:10}),0));
test('Unallocated confirmed inbound reduces restock',()=>eq(restockQty({shortage:3,inboundUnallocated:3}),0));
test('Variable price preserves independent cost and charge',()=>eq(saleSnapshot({qty:2,costCents:1600,pricingMode:'VARIABLE',actualSellCents:1000}),{qty:2,costCents:1600,sellUnitCents:1000,chargeCents:2000,differenceCents:400,deductionCents:2000}));
test('Fixed sale price unaffected by different batch cost',()=>{const a=saleSnapshot({qty:2,costCents:9600,pricingMode:'FIXED',fixedSellCents:5700});const b=saleSnapshot({qty:2,costCents:10200,pricingMode:'FIXED',fixedSellCents:5700});eq(a.chargeCents,b.chargeCents);eq(b.differenceCents,1200);});
test('Reject override of fixed agreed selling price',()=>throws(()=>saleSnapshot({qty:1,costCents:4800,pricingMode:'FIXED',fixedSellCents:5700,actualSellCents:5800})));
test('Worker-paid record does not deduct salary again',()=>eq(saleSnapshot({qty:1,costCents:800,pricingMode:'VARIABLE',actualSellCents:1000,workerPaid:true}).deductionCents,0));
console.log(checks.length+' tests PASS: '+checks.join(' | '));
