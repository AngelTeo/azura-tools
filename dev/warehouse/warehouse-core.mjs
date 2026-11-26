// Deterministic reference logic for warehouse planning. No I/O, no production mutations.
// Monetary amounts are integer sen. Actual reservations, payment and salary writes MUST be atomic server-side.
export function planStock({batches,requests,reservations=[]}){
 const require=(ok,msg)=>{if(!ok)throw Error(msg);};
 const qok=n=>Number.isSafeInteger(n)&&n>=0;
 const sorted=batches.slice().sort((a,b)=>String(a.receivedAt).localeCompare(String(b.receivedAt))||String(a.id).localeCompare(String(b.id)));
 const bm=new Map(),rm=new Map(),remaining=new Map(),reserved=new Map();
 for(const b of sorted){require(b.id&&b.itemId&&b.receivedAt&&qok(b.qty)&&qok(b.unitCostCents)&&!bm.has(b.id),"Invalid batch");bm.set(b.id,b);remaining.set(b.id,b.qty);}
 for(const r of requests){require(r.id&&r.itemId&&r.askedAt&&qok(r.openQty)&&qok(r.orderedQty??0)&&!rm.has(r.id),"Invalid request");rm.set(r.id,r);}
 for(const a of reservations){const b=bm.get(a.batchId),r=rm.get(a.requestId);require(b&&r&&b.itemId===r.itemId&&qok(a.qty)&&a.qty>0,"Invalid reservation");remaining.set(b.id,remaining.get(b.id)-a.qty);require(remaining.get(b.id)>=0,"Over-reserved batch");reserved.set(r.id,(reserved.get(r.id)||0)+a.qty);}
 const proposed=[],routes=[];
 const ordered=requests.slice().sort((a,b)=>String(a.askedAt).localeCompare(String(b.askedAt))||String(a.id).localeCompare(String(b.id)));
 for(const r of ordered){
  let ready=reserved.get(r.id)||0, onOrder=r.orderedQty??0;
  require(ready+onOrder<=r.openQty,"Request over-allocated");
  let shortage=r.openQty-ready-onOrder;
  if(r.approved!==false){for(const b of sorted){if(!shortage)break;if(b.itemId!==r.itemId)continue;const n=Math.min(shortage,remaining.get(b.id));if(n){remaining.set(b.id,remaining.get(b.id)-n);proposed.push({requestId:r.id,batchId:b.id,qty:n});ready+=n;shortage-=n;}}}
  routes.push({requestId:r.id,itemId:r.itemId,ready,ordered:onOrder,toBuy:r.approved===false?0:shortage,blocked:r.approved===false?shortage:0,approvalBlocked:r.approved===false});
 }
 const balances=[...new Set(sorted.map(b=>b.itemId).concat(requests.map(r=>r.itemId)))].map(itemId=>{const bs=sorted.filter(b=>b.itemId===itemId),physical=bs.reduce((s,b)=>s+b.qty,0),available=bs.reduce((s,b)=>s+remaining.get(b.id),0);return {itemId,physical,reserved:physical-available,available,inventoryCostCents:bs.reduce((s,b)=>s+b.qty*b.unitCostCents,0)};});
 return {proposed,routes,balances};
}

export function issueCost({batches,allocations,requestId,qty}){
 if(!Number.isSafeInteger(qty)||qty<=0)throw Error("Invalid issue quantity");
 const byId=new Map(batches.map(b=>[b.id,b]));
 const grouped=new Map();for(const a of allocations.filter(a=>a.requestId===requestId)){if(!Number.isSafeInteger(a.qty)||a.qty<=0||!byId.has(a.batchId))throw Error("Invalid allocation");grouped.set(a.batchId,(grouped.get(a.batchId)||0)+a.qty);}
 const rows=[...grouped].map(([id,n])=>({b:byId.get(id),n})).sort((a,b)=>String(a.b.receivedAt).localeCompare(String(b.b.receivedAt))||String(a.b.id).localeCompare(String(b.b.id)));
 let left=qty,costCents=0;const consumed=[];
 for(const {b,n} of rows){if(!Number.isSafeInteger(b.qty)||n>b.qty||!Number.isSafeInteger(b.unitCostCents)||b.unitCostCents<0)throw Error("Invalid reserved batch");const take=Math.min(left,n);if(take){consumed.push({batchId:b.id,qty:take,unitCostCents:b.unitCostCents});costCents+=take*b.unitCostCents;left-=take;}}
 if(left)throw Error("Insufficient reserved stock");
 return {qty,costCents,consumed};
}

export function routeDirect({openQty,receivedQty,orderedQty=0,approved=true}){
 if(![openQty,receivedQty,orderedQty].every(n=>Number.isSafeInteger(n)&&n>=0)||receivedQty+orderedQty>openQty)throw Error("Invalid direct request");
 const rest=openQty-receivedQty-orderedQty;
 return {ready:receivedQty,ordered:orderedQty,toBuy:approved?rest:0,blocked:approved?0:rest,approvalBlocked:!approved};
}

export function restockQty({shortage=0,available=0,inboundUnallocated=0,minAvailable=0,packSize=1,minOrder=0}){
 if(![shortage,available,inboundUnallocated,minAvailable,packSize,minOrder].every(n=>Number.isSafeInteger(n)&&n>=0)||packSize<1)throw Error("Invalid restock values");
 const need=Math.max(0,shortage+minAvailable-available-inboundUnallocated);
 return need?Math.ceil(Math.max(need,minOrder)/packSize)*packSize:0;
}

export function saleSnapshot({qty,costCents,pricingMode,fixedSellCents,actualSellCents,workerPaid=false}){
 const sell=pricingMode==="FIXED"?fixedSellCents:pricingMode==="VARIABLE"?actualSellCents:undefined;
 if(!Number.isSafeInteger(qty)||qty<=0||!Number.isSafeInteger(costCents)||costCents<0||!Number.isSafeInteger(sell)||sell<0)throw Error("Unconfirmed price or quantity");
 if(pricingMode==="FIXED"&&actualSellCents!=null&&actualSellCents!==sell)throw Error("Fixed sell price cannot be overridden");
 const chargeCents=qty*sell;
 return {qty,costCents,sellUnitCents:sell,chargeCents,differenceCents:chargeCents-costCents,deductionCents:workerPaid?0:chargeCents};
}
