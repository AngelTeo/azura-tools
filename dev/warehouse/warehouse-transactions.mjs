// Isolated transaction reference model. Copy-on-write atomicity in one process only.
// No database, authentication, network, production pay or salary operations.
import {planStock, issueCost, saleSnapshot} from './warehouse-core.mjs';
export function createWarehouse(seed={}){
 const clone=x=>JSON.parse(JSON.stringify(x));
 let state=clone({items:[],requests:[],orders:[],batches:[],reservations:[],payments:[],issues:[],adjustments:[],operations:{},...seed});
 const assert=(ok,msg)=>{if(!ok)throw Error(msg);};
 const integer=(n,min=0)=>Number.isSafeInteger(n)&&n>=min;
 const qty=n=>{assert(integer(n,1),"Invalid quantity");return n;};
 const money=n=>{assert(integer(n),"Invalid cost or price");return n;};
 const find=(rows,id)=>{const r=rows.find(x=>x.id===id);assert(r,"Unknown record: "+id);return r;};
 const add=(rows,row)=>{assert(row.id&&!rows.some(x=>x.id===row.id),"Duplicate record");rows.push(row);return row;};
 const fingerprint=x=>JSON.stringify(x,Object.keys(x).sort()); // only used below for flat commands
 const canonical=x=>x===null||typeof x!=="object"?JSON.stringify(x):Array.isArray(x)?"["+x.map(canonical).join(",")+"]":"{"+Object.keys(x).sort().map(k=>JSON.stringify(k)+":"+canonical(x[k])).join(",")+"}";
 const openQty=r=>r.qty-r.delivered-r.cancelled;
 const outstanding=o=>o.qty-o.received-o.cancelled;
 const pendingOrders=(s,r)=>s.orders.filter(o=>o.requestId===r.id).reduce((n,o)=>n+outstanding(o),0);
 const allocated=(s,r)=>s.reservations.filter(a=>a.requestId===r.id).reduce((n,a)=>n+a.qty,0);
 function routes(s){
  return s.requests.map(r=>{
   const it=find(s.items,r.itemId),ordered=pendingOrders(s,r);
   const ready=it.stock?allocated(s,r):r.received-r.delivered;
   const rest=openQty(r)-ready-ordered;
   assert(integer(rest),"Request overallocated");
   return {id:r.id,itemId:r.itemId,ready,ordered,toBuy:r.approved?rest:0,blocked:r.approved?0:rest};
  });
 }
 function allocate(s,itemId){
  const it=find(s.items,itemId);if(!it.stock)return;
  const r=s.requests.filter(r=>r.itemId===itemId&&openQty(r)>0).map(r=>({id:r.id,itemId,askedAt:r.askedAt,openQty:openQty(r),orderedQty:pendingOrders(s,r),approved:r.approved}));
  const rs=s.reservations.filter(a=>r.some(x=>x.id===a.requestId));
  const bs=s.batches.filter(b=>b.itemId===itemId);
  const plan=planStock({batches:bs,requests:r,reservations:rs});
  s.reservations.push(...plan.proposed);
 }
 function validate(s){
  const ids=new Set();
  for(const b of s.batches){assert(integer(b.qty)&&integer(b.unitCostCents)&&!ids.has(b.id),"Invalid batch");ids.add(b.id);
   assert(s.reservations.filter(a=>a.batchId===b.id).reduce((n,a)=>n+a.qty,0)<=b.qty,"Overreserved");}
  for(const a of s.reservations){const b=find(s.batches,a.batchId),r=find(s.requests,a.requestId);assert(b.itemId===r.itemId&&integer(a.qty,1),"Invalid allocation");}
  for(const r of s.requests){assert(integer(openQty(r))&&integer(r.delivered)&&integer(r.cancelled),"Invalid request balance");}
  for(const o of s.orders){assert(integer(outstanding(o)),"Order exceeded");}
  routes(s);
  return true;
 }
 function run(op){
  assert(typeof op.id==="string"&&op.id.length>0,"Missing operation ID");
  const key=canonical(op);
  if(Object.prototype.hasOwnProperty.call(state.operations,op.id)){
   const prior=state.operations[op.id];assert(prior.key===key,"Operation ID reused with different payload");return clone(prior.result);
  }
  const s=clone(state);let result={id:op.id,type:op.type};
  if(op.type==="REQUEST"){
   const it=find(s.items,op.itemId);qty(op.qty);assert(op.askedAt,"Missing request date");
   assert(it.pricing==="FIXED"||it.pricing==="VARIABLE","Unsupported special pricing");
   const fixed=it.pricing==="FIXED"?money(it.fixedSellCents):null;
   add(s.requests,{id:op.id,itemId:it.id,qty:op.qty,askedAt:op.askedAt,approved:op.approved!==false,pricing:it.pricing,fixedSellCents:fixed,received:0,delivered:0,cancelled:0,receivedLots:[]});
   allocate(s,it.id);
  }else if(op.type==="ORDER"){
   const it=find(s.items,op.itemId);qty(op.qty);assert(op.supplier&&op.date,"Missing supplier/date");
   if(op.requestId){const r=find(s.requests,op.requestId),route=routes(s).find(x=>x.id===r.id);assert(r.itemId===it.id&&r.approved&&op.qty<=route.toBuy,"Quantity exceeds shortage");}
   else assert(it.stock,"Direct purchase needs a request");
   add(s.orders,{id:op.id,itemId:it.id,requestId:op.requestId||null,qty:op.qty,received:0,cancelled:0,supplier:op.supplier,date:op.date});
  }else if(op.type==="PAY"){
   const o=find(s.orders,op.orderId);money(op.amountCents);assert(op.amountCents>0&&op.date&&["TBF","LEX","LZF","Petty Cash"].includes(op.payer),"Invalid actual payment");
   assert(op.ref,"Missing payment reference");
   assert(!s.payments.some(p=>p.orderId===o.id&&p.ref===op.ref),"Duplicate payment reference");
   add(s.payments,{id:op.id,orderId:o.id,amountCents:op.amountCents,payer:op.payer,date:op.date,ref:op.ref});
  }else if(op.type==="RECEIVE"){
   const o=find(s.orders,op.orderId),it=find(s.items,o.itemId);qty(op.qty);money(op.unitCostCents);assert(op.receivedAt&&op.qty<=outstanding(o),"Receipt exceeds outstanding order");
   o.received+=op.qty;
   if(it.stock){
    add(s.batches,{id:op.id,itemId:it.id,orderId:o.id,qty:op.qty,originalQty:op.qty,unitCostCents:op.unitCostCents,receivedAt:op.receivedAt});
    allocate(s,it.id);
   }else{
    const r=find(s.requests,o.requestId),sell=r.pricing==="FIXED"?r.fixedSellCents:money(op.actualSellCents);
    if(r.pricing==="FIXED"&&op.actualSellCents!=null)assert(op.actualSellCents===sell,"Fixed price cannot be overridden");
    r.received+=op.qty;r.receivedLots.push({id:op.id,qty:op.qty,unitCostCents:op.unitCostCents,sellUnitCents:sell});
   }
  }else if(op.type==="ISSUE"){
   const r=find(s.requests,op.requestId),it=find(s.items,r.itemId),route=routes(s).find(x=>x.id===r.id);qty(op.qty);
   assert(r.approved&&op.date&&op.qty<=route.ready,"Not ready for delivery");
   assert(op.workerPaid===true||op.deductionAuthorised===true,"Payment/deduction not confirmed");
   let costCents=0,chargeCents=0,consumed=[];
   if(it.stock){
    const issue=issueCost({batches:s.batches,allocations:s.reservations,requestId:r.id,qty:op.qty});costCents=issue.costCents;consumed=issue.consumed;
    const sale=saleSnapshot({qty:op.qty,costCents,pricingMode:r.pricing,fixedSellCents:r.fixedSellCents,actualSellCents:op.actualSellCents,workerPaid:op.workerPaid===true});chargeCents=sale.chargeCents;
    for(const c of consumed){find(s.batches,c.batchId).qty-=c.qty;let left=c.qty;for(const a of s.reservations.filter(a=>a.requestId===r.id&&a.batchId===c.batchId)){const n=Math.min(a.qty,left);a.qty-=n;left-=n;}assert(left===0,"Reservation mismatch");}
    s.reservations=s.reservations.filter(a=>a.qty>0);
   }else{
    let left=op.qty;for(const lot of r.receivedLots){const n=Math.min(left,lot.qty);if(n){costCents+=n*lot.unitCostCents;chargeCents+=n*lot.sellUnitCents;consumed.push({receiptId:lot.id,qty:n,unitCostCents:lot.unitCostCents,sellUnitCents:lot.sellUnitCents});lot.qty-=n;left-=n;}}
    assert(!left,"Receipt balance mismatch");
   }
   r.delivered+=op.qty;const deductionCents=op.workerPaid?0:chargeCents;
   const entry=add(s.issues,{id:op.id,requestId:r.id,qty:op.qty,costCents,chargeCents,deductionCents,differenceCents:chargeCents-costCents,date:op.date,consumed});
   result={...result,...entry};
  }else if(op.type==="CANCEL_REQUEST"){
   const r=find(s.requests,op.requestId),it=find(s.items,r.itemId);qty(op.qty);assert(op.reason,"Cancellation reason required");
   assert(op.qty<=openQty(r)-pendingOrders(s,r)-(it.stock?0:r.received-r.delivered),"Cancel outstanding order/return received goods first");
   if(it.stock){const route=routes(s).find(x=>x.id===r.id);let release=Math.max(0,op.qty-route.toBuy-route.blocked);
    for(const a of s.reservations.filter(a=>a.requestId===r.id).reverse()){const n=Math.min(release,a.qty);a.qty-=n;release-=n;}assert(release===0,"Invalid cancellation");s.reservations=s.reservations.filter(a=>a.qty>0);}
   r.cancelled+=op.qty;allocate(s,it.id);
  }else if(op.type==="CANCEL_ORDER"){
   const o=find(s.orders,op.orderId);qty(op.qty);assert(op.reason&&op.qty<=outstanding(o),"Invalid order cancellation");
   assert(!s.payments.some(p=>p.orderId===o.id),"Paid order needs reconciled refund first");
   o.cancelled+=op.qty;allocate(s,o.itemId);
  }else if(op.type==="ADJUST_DOWN"){
   const b=find(s.batches,op.batchId);qty(op.qty);assert(op.reason&&op.date,"Adjustment reason/date required");
   const reserved=s.reservations.filter(a=>a.batchId===b.id).reduce((n,a)=>n+a.qty,0);
   assert(op.qty<=b.qty-reserved,"Adjustment conflicts with reserved stock");
   b.qty-=op.qty;add(s.adjustments,{id:op.id,batchId:b.id,qty:-op.qty,reason:op.reason,date:op.date,costCents:op.qty*b.unitCostCents});
  }else throw Error("Unsupported command");
  validate(s);s.operations[op.id]={key,result};state=s;return clone(result);
 }
 function board(){const ss=clone(state);return {...ss,routes:routes(ss),stock:ss.items.filter(i=>i.stock).map(i=>{const bs=ss.batches.filter(b=>b.itemId===i.id),physical=bs.reduce((n,b)=>n+b.qty,0),reserved=ss.reservations.filter(a=>bs.some(b=>b.id===a.batchId)).reduce((n,a)=>n+a.qty,0);return {itemId:i.id,physical,reserved,available:physical-reserved,costCents:bs.reduce((n,b)=>n+b.qty*b.unitCostCents,0)};})};}
 validate(state);return {run,board};
}
