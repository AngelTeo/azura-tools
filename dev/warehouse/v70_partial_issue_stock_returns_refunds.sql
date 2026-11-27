
alter table owner_data.shop_request add column wh_receipt_parent uuid references owner_data.shop_wh_receipt(id);
create table owner_data.shop_wh_reversal (
 id uuid primary key default gen_random_uuid(), request_id uuid not null unique references owner_data.shop_request(id),
 action text not null check(action in ('RELEASE','RETURN')), qty integer not null check(qty>0),
 batch_id uuid not null references owner_data.shop_wh_batch(id), actual_on date not null,
 reason text not null check(length(btrim(reason)) between 1 and 300), actor uuid not null, created_at timestamptz not null default now()
);
create table owner_data.shop_wh_refund (
 id uuid primary key default gen_random_uuid(), payment_id uuid not null references owner_data.shop_wh_pay(payment_id),
 amount numeric(12,2) not null check(amount>0), refunded_on date not null, ref text not null check(length(btrim(ref)) between 1 and 80),
 reason text not null check(length(btrim(reason)) between 1 and 300), actor uuid not null, created_at timestamptz not null default now(),
 unique(payment_id,ref)
);
alter table owner_data.shop_wh_reversal enable row level security;
alter table owner_data.shop_wh_refund enable row level security;
revoke all on owner_data.shop_wh_reversal,owner_data.shop_wh_refund from public,anon,authenticated;
create function owner_data.shop_wh_payment_net(p_id uuid) returns numeric language sql stable set search_path='' as $f$
select greatest(0,p.amount-coalesce((select sum(f.amount) from owner_data.shop_wh_refund f where f.payment_id=p.id),0)) from owner_data.shop_payment p where p.id=p_id
$f$;
revoke all on function owner_data.shop_wh_payment_net(uuid) from public,anon,authenticated;

create function owner_data.shop_wh_split_ready(p_id uuid,p_qty int) returns uuid language plpgsql set search_path='' as $f$
declare r owner_data.shop_request; a owner_data.shop_wh_alloc; root_id_v uuid; new_id uuid; receipt_id_v uuid;
begin
 select * into r from owner_data.shop_request where id=p_id for update;
 if r.id is null or r.status<>'BOUGHT' or r.kind='FOOD' or r.bottle_id is not null or p_qty is null or p_qty<1 or p_qty>r.qty then raise exception 'Invalid delivery quantity';end if;
 if p_qty=r.qty then return r.id;end if;
 select * into a from owner_data.shop_wh_alloc where request_id=r.id and status='READY' for update;
 select coalesce(r.wh_receipt_parent,(select x.id from owner_data.shop_wh_receipt x where x.request_id=r.id order by x.created_at limit 1)) into receipt_id_v;
 if a.request_id is null and receipt_id_v is null then raise exception 'Not warehouse ready';end if;
 if r.pay_id is not null then raise exception 'Cannot split an already allocated payment';end if;
 select root_id into root_id_v from owner_data.shop_wh_part where request_id=r.id;
 root_id_v:=coalesce(root_id_v,r.id);
 insert into owner_data.shop_wh_root(request_id,original_qty) values(root_id_v,r.qty) on conflict do nothing;
 insert into owner_data.shop_wh_part(request_id,root_id) values(r.id,root_id_v) on conflict do nothing;
 update owner_data.shop_request set qty=qty-p_qty where id=r.id;
 insert into owner_data.shop_request(client_id,device_id,farm_code,worker_id,option_id,custom_name,qty,est_price,status,created_at,note,kind,made_by,trip,detail,ask_date,buy,bought_at,bought_by,buy_price,sell_price,wh_fixed_sell,wh_receipt_parent)
 values(gen_random_uuid(),r.device_id,r.farm_code,r.worker_id,r.option_id,r.custom_name,p_qty,r.est_price,'BOUGHT',r.created_at,r.note,r.kind,r.made_by,r.trip,r.detail,owner_data.shop_ask(r),r.buy,r.bought_at,r.bought_by,r.buy_price,r.sell_price,r.wh_fixed_sell,receipt_id_v) returning id into new_id;
 insert into owner_data.shop_wh_part(request_id,root_id) values(new_id,root_id_v);
 if a.request_id is not null then
  if a.qty<>r.qty then raise exception 'Allocation quantity mismatch';end if;
  update owner_data.shop_wh_alloc set qty=qty-p_qty where request_id=r.id;
  insert into owner_data.shop_wh_alloc(request_id,batch_id,qty,fixed_sell) values(new_id,a.batch_id,p_qty,a.fixed_sell);
 end if;
 return new_id;
end $f$;
revoke all on function owner_data.shop_wh_split_ready(uuid,int) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION owner_data.shop_wh_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_internal boolean:=coalesce(current_setting('owner_data.wh_internal',true),'')='1'; a owner_data.shop_wh_alloc; v_fixed numeric; v_review text;
begin
 if tg_op='DELETE' then
  if exists(select 1 from owner_data.shop_wh_root where request_id=old.id) or exists(select 1 from owner_data.shop_wh_part where request_id=old.id) or exists(select 1 from owner_data.shop_wh_order where request_id=old.id) or exists(select 1 from owner_data.shop_wh_alloc where request_id=old.id) or exists(select 1 from owner_data.shop_wh_review_resolution where request_id=old.id) then raise exception 'Warehouse history cannot be deleted'; end if;
  return old;
 end if;
 if not v_internal then
  if exists(select 1 from owner_data.shop_wh_order o where o.request_id=old.id and o.received_qty+o.cancelled_qty<o.qty) and (new.status is distinct from old.status or new.qty is distinct from old.qty or new.option_id is distinct from old.option_id or new.kind is distinct from old.kind or new.worker_id is distinct from old.worker_id or new.farm_code is distinct from old.farm_code or new.detail is distinct from old.detail or new.trip is distinct from old.trip) then raise exception 'Use Warehouse order actions for this ordered line'; end if;
  if old.status='REQUESTED' and new.status in ('BOUGHT','CONFIRMED') then
   if owner_data.shop_wh_review(old) is not null then raise exception 'Resolve the request review first'; end if;
   if exists(select 1 from owner_data.shop_wh_policy w where w.option_id=old.option_id and w.stock_managed) then raise exception 'Use Warehouse for stock-managed goods'; end if;
  end if;
  if old.status='BOUGHT' and new.status='REQUESTED' and ((old.wh_receipt_parent is not null or exists(select 1 from owner_data.shop_wh_receipt r where r.request_id=old.id)) or exists(select 1 from owner_data.shop_wh_alloc r where r.request_id=old.id)) then raise exception 'Use Warehouse reconciliation to undo receipt or reservation'; end if;
 end if;
 if old.status='REQUESTED' and new.status='BOUGHT' and old.kind='PERSONAL' and old.bottle_id is null then
  select fixed_sell into v_fixed from owner_data.shop_wh_policy where option_id=old.option_id and price_mode='FIXED';
  if v_fixed is not null then
   if new.sell_price is not null and new.sell_price<>v_fixed then raise exception 'Fixed selling price cannot change';end if;
   new.sell_price:=v_fixed;new.wh_fixed_sell:=v_fixed;
  end if;
 end if;
 if old.status='BOUGHT' and new.status='REQUESTED' then new.wh_fixed_sell:=null;end if;
 if old.status='BOUGHT' and new.status='CONFIRMED' then
  if not v_internal and (exists(select 1 from owner_data.shop_wh_alloc where request_id=old.id) or (old.wh_receipt_parent is not null or exists(select 1 from owner_data.shop_wh_receipt where request_id=old.id))) then raise exception 'Use Warehouse delivery confirmation';end if;
  v_review:=owner_data.shop_wh_review(old);
  if v_review is not null and not (v_internal and exists(select 1 from owner_data.shop_wh_review_resolution x where x.request_id=old.id)) then raise exception 'Resolve the request review first'; end if;
  if old.wh_fixed_sell is not null and new.sell_price is distinct from old.wh_fixed_sell then raise exception 'Fixed selling price cannot change';end if;
  select * into a from owner_data.shop_wh_alloc where request_id=old.id for update;
  if a.request_id is not null then
   if a.status<>'READY' or a.qty<>old.qty then raise exception 'Invalid stock allocation'; end if;
   if a.fixed_sell is not null and new.sell_price is distinct from a.fixed_sell then raise exception 'Fixed selling price cannot change'; end if;
   update owner_data.shop_wh_batch set on_hand=on_hand-a.qty where id=a.batch_id and on_hand>=a.qty;
   if not found then raise exception 'Insufficient stock — refresh'; end if;
   update owner_data.shop_wh_alloc set status='ISSUED',issued_at=now() where request_id=old.id;
  end if;
 end if;
 return new;
end $function$;
CREATE OR REPLACE FUNCTION owner_data.shop_wh_void_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
 if new.voided_at is not null and old.voided_at is null and exists(
 select 1 from owner_data.shop_request r where
 (case tg_table_name when 'shop_entry' then r.entry_id when 'shop_share' then r.share_id else r.cost_id end)=old.id
 and (exists(select 1 from owner_data.shop_wh_alloc a where a.request_id=r.id) or r.wh_receipt_parent is not null or exists(select 1 from owner_data.shop_wh_receipt x where x.request_id=r.id) or exists(select 1 from owner_data.shop_wh_review_resolution z where z.request_id=r.id and z.mode<>'LINKED')) and coalesce(current_setting('owner_data.wh_reverse_request',true),'')<>r.id::text) then
 raise exception 'Warehouse-linked delivery requires audited reconciliation';
 end if;
 return new;
end $function$;
CREATE OR REPLACE FUNCTION public.shop_owner_wh(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_action text:=p->>'action'; v_op uuid:=(p->>'op_id')::uuid; v_actor uuid:=auth.uid(); v_today date:=(now() at time zone 'Asia/Kuala_Lumpur')::date;
 v_date date:=coalesce(nullif(p->>'date','')::date,v_today); v_qty int; v_cost numeric; v_sell numeric; v_result jsonb:='{}'; v_id uuid; v_item uuid; v_req uuid; v_payment uuid; v_part uuid; v_batch uuid; v_take int; v_reserved int; v_reason text; v_label text; v_old owner_data.shop_wh_op; r owner_data.shop_request; o owner_data.shop_wh_order; b owner_data.shop_wh_batch; pol owner_data.shop_wh_policy; opt public.hub_option; v_flag boolean; v_mode text; v_min int; v_pack int; v_n int; v_open boolean;
begin
 if v_actor is null or not public.shop_is_manager() then raise exception 'Not allowed';end if;
 if v_op is null then raise exception 'Operation ID required';end if;
 perform pg_advisory_xact_lock(27112026,64);
 select * into v_old from owner_data.shop_wh_op where id=v_op;
 if found then
  if v_old.actor<>v_actor or v_old.payload<>p then raise exception 'Operation ID already used with different parameters';end if;
  return v_old.result;
 end if;
 if v_date>v_today then raise exception 'Date cannot be in the future';end if;
 perform owner_data.require_shop('shop_wh_'||coalesce(v_action,'unknown'),jsonb_build_object('op_id',v_op));
 perform set_config('owner_data.wh_internal','1',true);
 if v_action='POLICY' then
  v_item:=(p->>'item_id')::uuid;v_flag:=coalesce((p->>'stock')::boolean,false);v_mode:=p->>'price_mode';v_sell:=nullif(p->>'fixed_sell','')::numeric;v_min:=nullif(p->>'minimum','')::int;v_pack:=nullif(p->>'pack','')::int;
  select * into opt from public.hub_option where id=v_item and list_code in ('PERSONAL_ITEM','FARM_ITEM','SHARED_ITEM') and shown;
  if opt.id is null or upper(opt.code) in ('TOP UP','WHISKEY','PINJAM','UBAT','DOCTOR','SIM CARD') then raise exception 'Special or unknown item — cannot use stock policy';end if;
  if v_mode not in ('FIXED','VARIABLE') or v_mode is null then raise exception 'Choose price mode';end if;
  if opt.list_code<>'PERSONAL_ITEM' then v_mode:='VARIABLE';v_sell:=null;end if;
  if v_mode='FIXED' and (v_sell is null or v_sell<=0 or v_sell>5000 or v_sell<>round(v_sell,2)) then raise exception 'Enter fixed selling price';end if;
  if v_mode='VARIABLE' then v_sell:=null;end if;
  select * into pol from owner_data.shop_wh_policy where option_id=v_item for update;
  if pol.option_id is not null and pol.stock_managed<>v_flag and (exists(select 1 from owner_data.shop_wh_batch where option_id=v_item and on_hand>0) or exists(select 1 from owner_data.shop_wh_order where option_id=v_item and received_qty+cancelled_qty<qty) or exists(select 1 from owner_data.shop_wh_alloc a join owner_data.shop_wh_batch z on z.id=a.batch_id where z.option_id=v_item and a.status='READY')) then raise exception 'Resolve stock and open orders before changing fulfilment mode';end if;
  insert into owner_data.shop_wh_policy(option_id,stock_managed,price_mode,fixed_sell,minimum_qty,pack_qty,opening_confirmed,updated_by)
  values(v_item,v_flag,v_mode,v_sell,v_min,v_pack,case when v_flag and coalesce(pol.stock_managed,false) then pol.opening_confirmed else false end,v_actor)
  on conflict(option_id) do update set stock_managed=excluded.stock_managed,price_mode=excluded.price_mode,fixed_sell=excluded.fixed_sell,minimum_qty=excluded.minimum_qty,pack_qty=excluded.pack_qty,opening_confirmed=excluded.opening_confirmed,updated_by=v_actor,updated_at=now();
 elsif v_action='OPENING' then
  v_item:=(p->>'item_id')::uuid;v_qty:=(p->>'qty')::int;v_cost:=nullif(p->>'unit_cost','')::numeric;v_reason:=btrim(coalesce(p->>'reason',''));
  select * into pol from owner_data.shop_wh_policy where option_id=v_item for update;
  if not coalesce(pol.stock_managed,false) or pol.opening_confirmed then raise exception 'Opening stock already confirmed or item not stock-managed';end if;
  if v_qty is null or v_qty<0 or v_qty>99999 or length(v_reason)<1 then raise exception 'Enter verified opening quantity and evidence';end if;
  if v_qty>0 then
   if v_cost is null or v_cost<=0 or v_cost>5000 or v_cost<>round(v_cost,2) then raise exception 'Verified actual opening unit cost required';end if;
   insert into owner_data.shop_wh_batch(option_id,received_on,original_qty,on_hand,unit_cost,source,ref,created_by) values(v_item,v_date,v_qty,v_qty,v_cost,'OPENING',left(v_reason,300),v_actor) returning id into v_batch;
  end if;
  update owner_data.shop_wh_policy set opening_confirmed=true,updated_at=now(),updated_by=v_actor where option_id=v_item;
  perform owner_data.shop_wh_allocate(v_item);
  v_result:=jsonb_build_object('batch_id',v_batch);
 elsif v_action='SYNC' then
  v_n:=owner_data.shop_wh_allocate(null);v_result:=jsonb_build_object('reserved_qty',v_n);
 elsif v_action='ORDER' then
  v_req:=nullif(p->>'request_id','')::uuid;v_item:=nullif(p->>'item_id','')::uuid;v_qty:=(p->>'qty')::int;
  if v_qty is null or v_qty<1 or v_qty>99999 or length(btrim(coalesce(p->>'supplier',''))) not between 1 and 100 then raise exception 'Enter order quantity and supplier';end if;
  if v_req is not null then
   select * into r from owner_data.shop_request where id=v_req for update;
   if r.id is null or r.status<>'REQUESTED' or r.kind='FOOD' or r.bottle_id is not null or owner_data.shop_wh_review(r) is not null then raise exception 'Request not eligible for supplier order';end if;
   v_item:=r.option_id;
   if exists(select 1 from public.hub_option where id=v_item and code in ('TOP UP','WHISKEY')) then raise exception 'Use existing special-item flow';end if;
   if exists(select 1 from owner_data.shop_wh_order where request_id=r.id and received_qty+cancelled_qty<qty) then raise exception 'Already ordered';end if;
   if v_qty>r.qty then raise exception 'Order the shortage only; extra stock is separate replenishment';end if;
   v_req:=owner_data.shop_wh_split(r.id,v_qty);
   v_label:=coalesce((select label from public.hub_option where id=v_item),r.custom_name);
  else
   select label into v_label from public.hub_option where id=v_item and shown;
   if v_label is null then raise exception 'Unknown item';end if;
  end if;
  select * into pol from owner_data.shop_wh_policy where option_id=v_item;
  v_flag:=coalesce(pol.stock_managed,false);
  if v_req is null and not v_flag then raise exception 'Only stock-managed goods can be replenished without a request';end if;
  if v_flag and not pol.opening_confirmed then raise exception 'Confirm actual opening stock first';end if;
  if v_flag and v_req is not null and exists(select 1 from owner_data.shop_wh_batch wb where wb.option_id=v_item and wb.on_hand>coalesce((select sum(wa.qty) from owner_data.shop_wh_alloc wa where wa.batch_id=wb.id and wa.status='READY'),0)) then raise exception 'Available stock exists — refresh and reserve before ordering';end if;
  insert into owner_data.shop_wh_order(option_id,request_id,item,supplier,ordered_on,qty,ref,created_by,stock_order)
  values(v_item,v_req,v_label,btrim(p->>'supplier'),v_date,v_qty,nullif(left(btrim(coalesce(p->>'ref','')),100),''),v_actor,v_flag) returning id into v_id;
  v_result:=jsonb_build_object('order_id',v_id,'request_id',v_req);
 elsif v_action='RECEIVE' then
  select * into o from owner_data.shop_wh_order where id=(p->>'order_id')::uuid for update;
  v_qty:=(p->>'qty')::int;v_cost:=nullif(p->>'unit_cost','')::numeric;v_sell:=nullif(p->>'sell','')::numeric;
  if o.id is null or v_qty is null or v_qty<1 or v_qty>o.qty-o.received_qty-o.cancelled_qty then raise exception 'Receipt exceeds outstanding order';end if;
  if v_date<o.ordered_on or v_cost is null or v_cost<=0 or v_cost>5000 or v_cost<>round(v_cost,2) then raise exception 'Check receipt date and actual unit cost';end if;
  if o.request_id is not null then
   select * into r from owner_data.shop_request where id=o.request_id for update;
   if r.status<>'REQUESTED' or r.qty<v_qty or owner_data.shop_wh_review(r) is not null then raise exception 'Request changed or needs review';end if;
  end if;
  select * into pol from owner_data.shop_wh_policy where option_id=o.option_id;
  if o.stock_order then
   if not coalesce(pol.stock_managed,false) or not pol.opening_confirmed then raise exception 'Stock policy changed';end if;
   insert into owner_data.shop_wh_batch(option_id,order_id,received_on,original_qty,on_hand,unit_cost,source,ref,created_by) values(o.option_id,o.id,v_date,v_qty,v_qty,v_cost,'RECEIPT',o.ref,v_actor) returning id into v_batch;
   if o.request_id is not null then v_part:=owner_data.shop_wh_reserve(o.request_id,v_batch,v_qty);end if;
  else
   if o.request_id is null or coalesce(pol.stock_managed,false) then raise exception 'Request or stock policy changed';end if;
   if r.kind='PERSONAL' then
    if pol.price_mode='FIXED' then
     if v_sell is not null and v_sell<>pol.fixed_sell then raise exception 'Fixed selling price cannot change';end if;
     v_sell:=pol.fixed_sell;
    end if;
    if v_sell is null or v_sell<=0 or v_sell>5000 or v_sell<>round(v_sell,2) then raise exception 'Enter agreed selling price';end if;
   else v_sell:=null;end if;
   v_part:=owner_data.shop_wh_split(r.id,v_qty);
   update owner_data.shop_request set status='BOUGHT',bought_at=now(),bought_by=v_actor,buy_price=v_cost,sell_price=v_sell,pay_id=null,buy=jsonb_build_object('price',v_cost,'date',v_date,'warehouse_order',o.id) where id=v_part;
  end if;
  update owner_data.shop_wh_order set received_qty=received_qty+v_qty where id=o.id;
  insert into owner_data.shop_wh_receipt(order_id,request_id,batch_id,received_on,qty,unit_cost,sell_price,created_by) values(o.id,v_part,v_batch,v_date,v_qty,v_cost,v_sell,v_actor) returning id into v_id;
  if o.stock_order then perform owner_data.shop_wh_allocate(o.option_id);end if;
  v_result:=jsonb_build_object('receipt_id',v_id,'batch_id',v_batch,'request_id',v_part);
 elsif v_action='PAY' then
  select * into o from owner_data.shop_wh_order where id=(p->>'order_id')::uuid for update;
  v_cost:=nullif(p->>'amount','')::numeric;v_reason:=btrim(coalesce(p->>'ref',''));
  if o.id is null or v_cost is null or v_cost<=0 or v_cost>99999999 or v_cost<>round(v_cost,2) or length(v_reason) not between 1 and 80 or v_date<o.ordered_on then raise exception 'Enter verified actual payment, date and reference';end if;
  if exists(select 1 from owner_data.shop_wh_pay where order_id=o.id and ref=v_reason) then raise exception 'Payment reference already recorded';end if;
  v_payment:=owner_data.shop_pay_new(p->>'payer',v_cost,'PURCHASE',o.item||' · '||o.supplier,v_date,v_reason,v_op);
  insert into owner_data.shop_wh_pay(payment_id,order_id,ref) values(v_payment,o.id,v_reason);
  v_result:=jsonb_build_object('pay_id',v_payment,'amount',v_cost);
 elsif v_action='CANCEL_ORDER' then
  select * into o from owner_data.shop_wh_order where id=(p->>'order_id')::uuid for update;
  v_qty:=(p->>'qty')::int;v_reason:=btrim(coalesce(p->>'reason',''));
  if o.id is null or v_qty is null or v_qty<1 or v_qty>o.qty-o.received_qty-o.cancelled_qty or length(v_reason)<1 then raise exception 'Invalid cancellation';end if;
  if coalesce((select sum(owner_data.shop_wh_payment_net(m.id)) from owner_data.shop_wh_pay w join owner_data.shop_payment m on m.id=w.payment_id where w.order_id=o.id and m.voided_at is null),0)>coalesce((select sum(x.qty*x.unit_cost) from owner_data.shop_wh_receipt x where x.order_id=o.id),0) then raise exception 'Unreconciled supplier advance — actual refund required before cancellation';end if;
  if o.request_id is not null and v_qty<o.qty-o.received_qty-o.cancelled_qty then
   -- Split the cancelled portion so only the remaining ordered quantity retains the order.
   perform owner_data.shop_wh_split(o.request_id,v_qty);
  end if;
  update owner_data.shop_wh_order set cancelled_qty=cancelled_qty+v_qty where id=o.id;
  if o.stock_order then perform owner_data.shop_wh_allocate(o.option_id);end if;
 elsif v_action='ADJUST' then
  v_qty:=(p->>'qty')::int;v_reason:=btrim(coalesce(p->>'reason',''));v_item:=nullif(p->>'item_id','')::uuid;
  if v_qty is null or v_qty=0 or abs(v_qty)>99999 or length(v_reason) not between 1 and 300 then raise exception 'Enter adjustment quantity and reason';end if;
  if v_qty<0 then
   select * into b from owner_data.shop_wh_batch where id=(p->>'batch_id')::uuid for update;
   if b.id is null then raise exception 'Unknown batch';end if;
   select coalesce(sum(qty),0) into v_reserved from owner_data.shop_wh_alloc where batch_id=b.id and status='READY';
   if -v_qty>b.on_hand-v_reserved then raise exception 'Adjustment conflicts with reserved stock';end if;
   update owner_data.shop_wh_batch set on_hand=on_hand+v_qty where id=b.id;v_batch:=b.id;
  else
   select * into pol from owner_data.shop_wh_policy where option_id=v_item for update;
   v_cost:=nullif(p->>'unit_cost','')::numeric;
   if not coalesce(pol.stock_managed,false) or not pol.opening_confirmed or v_cost is null or v_cost<=0 or v_cost>5000 or v_cost<>round(v_cost,2) then raise exception 'Confirmed stock policy and verified cost required';end if;
   insert into owner_data.shop_wh_batch(option_id,received_on,original_qty,on_hand,unit_cost,source,ref,created_by) values(v_item,v_date,v_qty,v_qty,v_cost,'ADJUST_UP',left(v_reason,300),v_actor) returning id into v_batch;
   perform owner_data.shop_wh_allocate(v_item);
  end if;
  insert into owner_data.shop_wh_adjust(batch_id,delta,reason,actual_on,created_by) values(v_batch,v_qty,v_reason,v_date,v_actor);
 elsif v_action='ISSUE' then
  select * into r from owner_data.shop_request where id=(p->>'request_id')::uuid for update;
  if r.id is null or r.status<>'BOUGHT' or not (exists(select 1 from owner_data.shop_wh_alloc where request_id=r.id and status='READY') or r.wh_receipt_parent is not null or exists(select 1 from owner_data.shop_wh_receipt where request_id=r.id)) then raise exception 'Not a warehouse-ready line';end if;
  if r.kind='PERSONAL' and not(coalesce((p->>'worker_paid')::boolean,false) or coalesce((p->>'deduction_authorised')::boolean,false)) then raise exception 'Confirm authorised deduction or worker cash payment';end if;
  v_qty:=coalesce(nullif(p->>'qty','')::int,r.qty);
  v_part:=owner_data.shop_wh_split_ready(r.id,v_qty);
  v_result:=public.shop_owner_hand(jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('id',v_part,'share_ids',coalesce(p->'share_ids','[]'::jsonb),'sell',coalesce(nullif(p->>'sell','')::numeric,r.wh_fixed_sell,r.sell_price),'worker_paid',coalesce((p->>'worker_paid')::boolean,false))),'date',v_date));
 elsif v_action='LINK_ITEM' then
  v_req:=(p->>'request_id')::uuid;v_item:=(p->>'item_id')::uuid;
  select * into r from owner_data.shop_request where id=v_req for update;
  if r.id is null or r.status<>'REQUESTED' or r.option_id is not null or r.kind<>'PERSONAL' then raise exception 'Only unlinked personal request can be linked';end if;
  select * into opt from public.hub_option where id=v_item and list_code='PERSONAL_ITEM' and shown and code not in ('TOP UP','WHISKEY','PINJAM','DOCTOR','UBAT');
  if opt.id is null then raise exception 'Choose the actual matching catalogue item';end if;
  if owner_data.shop_wh_review(r) in ('INSTALMENT','MEDICAL','WORKER') then raise exception 'Resolve special case first';end if;
  v_reason:=btrim(coalesce(p->>'reason',''));if length(v_reason)<1 then raise exception 'Confirm the actual item match';end if;
  update owner_data.shop_request set option_id=v_item where id=v_req;
  insert into owner_data.shop_wh_review_resolution(request_id,mode,reason,created_by) values(v_req,'LINKED',left(v_reason,300),v_actor);
  perform owner_data.shop_wh_allocate(v_item);
 else raise exception 'Unknown Warehouse action';
 end if;
 perform set_config('owner_data.wh_internal','0',true);
 v_result:=jsonb_build_object('ok',true,'op_id',v_op)||v_result;
 insert into owner_data.shop_wh_op(id,actor,payload,result) values(v_op,v_actor,p,v_result);
 return v_result;
end $function$;
CREATE OR REPLACE FUNCTION public.shop_owner_wh_board(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 perform owner_data.require_shop('shop_wh_board','{}'::jsonb);
 -- Auto-reserve only if there is eligible demand and free physical stock. No salary/payment writes.
 if exists(select 1 from owner_data.shop_request r join owner_data.shop_wh_policy w on w.option_id=r.option_id and w.stock_managed and w.opening_confirmed where r.status='REQUESTED' and r.kind<>'FOOD' and r.bottle_id is null and owner_data.shop_wh_review(r) is null and not exists(select 1 from owner_data.shop_wh_order o where o.request_id=r.id and o.received_qty+o.cancelled_qty<o.qty) and exists(select 1 from owner_data.shop_wh_batch b where b.option_id=r.option_id and b.on_hand>coalesce((select sum(a.qty) from owner_data.shop_wh_alloc a where a.batch_id=b.id and a.status='READY'),0))) then
  perform pg_advisory_xact_lock(27112026,64);
  perform set_config('owner_data.wh_internal','1',true);
  perform owner_data.shop_wh_allocate(null);
  perform set_config('owner_data.wh_internal','0',true);
 end if;
 return jsonb_build_object(
 'policy',coalesce((select jsonb_agg(to_jsonb(w) order by w.option_id) from owner_data.shop_wh_policy w),'[]'::jsonb),
 'stock',coalesce((select jsonb_agg(z order by z->>'item') from (
  select jsonb_build_object('item_id',w.option_id,'item',o.label,'kind',owner_data.shop_kind(o.list_code),'unit',u.unit,'opening_confirmed',w.opening_confirmed,
  'physical',coalesce((select sum(b.on_hand) from owner_data.shop_wh_batch b where b.option_id=w.option_id),0),
  'reserved',coalesce((select sum(a.qty) from owner_data.shop_wh_alloc a join owner_data.shop_wh_batch b on b.id=a.batch_id where b.option_id=w.option_id and a.status='READY'),0),
  'cost',coalesce((select sum(b.on_hand*b.unit_cost) from owner_data.shop_wh_batch b where b.option_id=w.option_id),0),
  'minimum',w.minimum_qty,'pack',w.pack_qty,'price_mode',w.price_mode,'fixed_sell',w.fixed_sell,
  'inbound',coalesce((select sum(qty-received_qty-cancelled_qty) from owner_data.shop_wh_order x where x.option_id=w.option_id and x.stock_order),0)) z
  from owner_data.shop_wh_policy w join public.hub_option o on o.id=w.option_id left join owner_data.shop_item_unit u on u.option_id=w.option_id where w.stock_managed) s),'[]'::jsonb),
 'batches',coalesce((select jsonb_agg(to_jsonb(b)||jsonb_build_object('reserved',coalesce((select sum(a.qty) from owner_data.shop_wh_alloc a where a.batch_id=b.id and a.status='READY'),0)) order by b.received_on,b.created_at) from owner_data.shop_wh_batch b where b.on_hand>0),'[]'::jsonb),
 'orders',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('remaining',o.qty-o.received_qty-o.cancelled_qty,'received_cost',coalesce((select sum(x.qty*x.unit_cost) from owner_data.shop_wh_receipt x where x.order_id=o.id),0),'paid',coalesce((select sum(owner_data.shop_wh_payment_net(m.id)) from owner_data.shop_wh_pay x join owner_data.shop_payment m on m.id=x.payment_id where x.order_id=o.id and m.voided_at is null),0)) order by o.ordered_on desc,o.created_at desc) from owner_data.shop_wh_order o),'[]'::jsonb),
 'links',coalesce((select jsonb_agg(jsonb_build_object('request_id',r.id,'root_id',coalesce(t.root_id,r.id),'original_qty',coalesce(rt.original_qty,r.qty),'ordered',exists(select 1 from owner_data.shop_wh_order o where o.request_id=r.id and o.received_qty+o.cancelled_qty<o.qty),'allocation',a.status,'receipt',(r.wh_receipt_parent is not null or exists(select 1 from owner_data.shop_wh_receipt x where x.request_id=r.id)),'fixed_sell',r.wh_fixed_sell,'review',owner_data.shop_wh_review(r))) from owner_data.shop_request r left join owner_data.shop_wh_part t on t.request_id=r.id left join owner_data.shop_wh_root rt on rt.request_id=t.root_id left join owner_data.shop_wh_alloc a on a.request_id=r.id where r.status in ('REQUESTED','BOUGHT')),'[]'::jsonb),
 'order_payments',coalesce((select jsonb_agg(jsonb_build_object('payment_id',m.id,'order_id',wp.order_id,'date',m.paid_on,'ref',wp.ref,'payer',m.payer,'source',m.source,'gross',m.amount,'net',owner_data.shop_wh_payment_net(m.id),'reimbursed',m.reimb_id is not null)) from owner_data.shop_wh_pay wp join owner_data.shop_payment m on m.id=wp.payment_id where m.voided_at is null),'[]'::jsonb),
 'refunds',coalesce((select jsonb_agg(to_jsonb(f) order by f.created_at desc) from owner_data.shop_wh_refund f),'[]'::jsonb),
 'returns',coalesce((select jsonb_agg(to_jsonb(z) order by z.created_at desc) from owner_data.shop_wh_reversal z),'[]'::jsonb),
 'issued',coalesce((select jsonb_agg(jsonb_build_object('request_id',r.id,'item',coalesce((select label from public.hub_option where id=r.option_id),r.custom_name),'farm',r.farm_code,'kind',r.kind,'worker',(select name from public.hub_worker where id=r.worker_id),'qty',r.qty,'date',(r.handed_at at time zone 'Asia/Kuala_Lumpur')::date,'worker_paid',r.worker_paid,'cost',r.buy_price,'returned',exists(select 1 from owner_data.shop_wh_reversal z where z.request_id=r.id))) from owner_data.shop_request r join owner_data.shop_wh_alloc a on a.request_id=r.id where r.status='CONFIRMED'),'[]'::jsonb),
 'adjustments',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (select * from owner_data.shop_wh_adjust order by created_at desc limit 100) x),'[]'::jsonb)
 );
end $function$;
CREATE OR REPLACE FUNCTION public.shop_owner_money(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_from date := coalesce(nullif(p->>'from','')::date, (now() at time zone 'Asia/Kuala_Lumpur')::date - 120);
begin
  perform owner_data.require_shop('shop_money', '{}'::jsonb);
  return jsonb_build_object(
    'suppliers', coalesce((select value from owner_data.shop_setting where key = 'topup_suppliers'), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'date', x.paid_on, 'amount', owner_data.shop_wh_payment_net(x.id), 'gross_amount', x.amount, 'refund_amount', x.amount-owner_data.shop_wh_payment_net(x.id), 'source', x.source, 'payer', x.payer,
                            'purpose', x.purpose, 'label', x.label, 'ref', x.ref, 'reimb_id', x.reimb_id, 'at', x.created_at,
                            'by', (select u.display_name from public.hub_app_user u where u.id = x.created_by),
                            'legacy', exists (select 1 from owner_data.shop_request r where r.pay_id = x.id and r.legacy)) order by x.paid_on desc, x.created_at desc)
                          from owner_data.shop_payment x where x.voided_at is null and x.amount > 0 and (x.paid_on >= v_from or (x.source = 'MGMT' and x.reimb_id is null))), '[]'::jsonb),
    'reimbs', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'payer', b.payer, 'amount', b.amount, 'date', b.paid_on, 'ref', b.ref,
                          'n', (select count(*) from owner_data.shop_payment x where x.reimb_id = b.id),
                          'by', (select u.display_name from public.hub_app_user u where u.id = b.created_by)) order by b.paid_on desc, b.created_at desc)
                        from owner_data.shop_reimb b where b.voided_at is null and b.paid_on >= v_from), '[]'::jsonb),
    'topups', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'request_id', t.request_id, 'phone', t.phone, 'telco', t.telco, 'amount', t.amount,
                          'method', t.method, 'supplier', t.supplier, 'date', t.done_on, 'pay_id', t.pay_id, 'settle_id', t.settle_id,
                          'worker', (select w.name from public.hub_worker w join owner_data.shop_request r on r.worker_id = w.id where r.id = t.request_id),
                          'farm', (select r.farm_code from owner_data.shop_request r where r.id = t.request_id),
                          'paid_on', coalesce((select s.paid_on from owner_data.shop_settle s where s.id = t.settle_id), (select x.paid_on from owner_data.shop_payment x where x.id = t.pay_id)),
                          'ref', (select s.ref from owner_data.shop_settle s where s.id = t.settle_id),
                          'legacy', (select r.legacy from owner_data.shop_request r where r.id = t.request_id),
                          'asked', (select owner_data.shop_ask(r) from owner_data.shop_request r where r.id = t.request_id)) order by t.done_on desc, t.done_at desc)
                        from owner_data.shop_topup t where t.voided_at is null and (t.done_on >= v_from or (t.method = 'SUPPLIER' and t.settle_id is null) or t.method is null)), '[]'::jsonb),
    'unpaid_buys', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'worker', (select w.name from public.hub_worker w where w.id = r.worker_id),
                          'farm', r.farm_code, 'item', coalesce((select o.label from public.hub_option o where o.id = r.option_id), r.custom_name),
                          'qty', r.qty, 'date', (r.handed_at at time zone 'Asia/Kuala_Lumpur')::date, 'sell', r.sell_price, 'detail', r.detail,
                          'bottle_id', r.bottle_id, 'bottle_n', r.bottle_n, 'asked', owner_data.shop_ask(r),
                          'ref_buy', (select c.buy_price from owner_data.shop_item_cost c where c.option_id = r.option_id)) order by r.handed_at, r.bottle_id, r.id)
                        from owner_data.shop_request r
                        where r.legacy and r.status = 'CONFIRMED' and r.pay_id is null
                          and not exists (select 1 from owner_data.shop_topup t where t.request_id = r.id)
                          and exists (select 1 from owner_data.shop_entry e where e.id = r.entry_id and e.voided_at is null)), '[]'::jsonb),
    'settles', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'supplier', s.supplier, 'amount', s.amount, 'date', s.paid_on, 'ref', s.ref,
                          'n', (select count(*) from owner_data.shop_topup t where t.settle_id = s.id and t.voided_at is null),
                          'source', (select x.source from owner_data.shop_payment x where x.id = s.pay_id),
                          'payer', (select x.payer from owner_data.shop_payment x where x.id = s.pay_id)) order by s.paid_on desc)
                         from owner_data.shop_settle s where s.voided_at is null and s.paid_on >= v_from), '[]'::jsonb));
end $function$;
CREATE OR REPLACE FUNCTION public.shop_owner_reimburse(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_payer text := owner_data.shop_payer(p->>'payer'); v_ids uuid[]; v_n int; v_amt numeric(12,2); v_b uuid; v_date date;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date; v_client uuid;
begin
  perform owner_data.require_shop('shop_reimburse', p);
  begin v_date := coalesce(nullif(p->>'date','')::date, v_today); v_client := nullif(p->>'client_id','')::uuid;
  exception when others then raise exception 'Bad request'; end;
  if v_client is not null and exists (select 1 from owner_data.shop_reimb where client_id = v_client) then return jsonb_build_object('ok', true, 'repeat', true); end if;
  if v_payer not in ('TBF','LEX','LZF') then raise exception 'Pick TBF, LEX or LZF'; end if;
  if v_date > v_today then raise exception 'Date cannot be in the future'; end if;
  select array_agg(distinct (x)::uuid) into v_ids from jsonb_array_elements_text(coalesce(p->'ids','[]'::jsonb)) x;
  if coalesce(array_length(v_ids,1),0) = 0 then raise exception 'Tick at least one'; end if;
  perform 1 from owner_data.shop_payment where id = any(v_ids) for update;
  select count(*), sum(owner_data.shop_wh_payment_net(id)) into v_n, v_amt from owner_data.shop_payment
   where id = any(v_ids) and voided_at is null and reimb_id is null and source = 'MGMT' and payer = v_payer and owner_data.shop_wh_payment_net(id) > 0;
  if v_n <> array_length(v_ids,1) then raise exception 'Some payments are already reimbursed, undone or not %', v_payer; end if;
  insert into owner_data.shop_reimb (client_id, payer, amount, paid_on, ref, created_by)
  values (v_client, v_payer, v_amt, v_date, nullif(left(btrim(coalesce(p->>'ref','')), 80), ''), auth.uid()) returning id into v_b;
  update owner_data.shop_payment set reimb_id = v_b where id = any(v_ids);
  return jsonb_build_object('ok', true, 'id', v_b, 'amount', v_amt, 'count', v_n);
end $function$;
CREATE OR REPLACE FUNCTION owner_data.shop_pay_recalc(p_pay uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v numeric(12,2); pay owner_data.shop_payment;
begin
  select * into pay from owner_data.shop_payment where id = p_pay for update;
  if pay.id is null or pay.voided_at is not null or pay.purpose not in ('PURCHASE','MEDICAL') then return; end if;
 if exists(select 1 from owner_data.shop_wh_pay where payment_id=p_pay) then raise exception 'Warehouse payment must be reconciled through the original supplier order';end if;
  select coalesce(sum(case when r.bottle_id is not null then 0 else r.qty * r.buy_price end), 0)
       + coalesce((select sum(b.cost) from (select distinct on (r2.bottle_id) r2.bottle_id, (r2.buy->>'bottle_price')::numeric cost
                                            from owner_data.shop_request r2 where r2.pay_id = p_pay and r2.bottle_id is not null
                                              and r2.status in ('BOUGHT','CONFIRMED')) b), 0)
    into v from owner_data.shop_request r where r.pay_id = p_pay and r.status in ('BOUGHT','CONFIRMED');
  if v = 0 then update owner_data.shop_payment set voided_at = now(), voided_by = auth.uid(), void_note = 'All lines taken back' where id = p_pay;
  else update owner_data.shop_payment set amount = v where id = p_pay; end if;
end $function$;
create function public.shop_owner_wh_reconcile(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $f$
declare v_actor uuid:=auth.uid(); v_op uuid:=(p->>'op_id')::uuid; v_action text:=p->>'action'; v_reason text:=btrim(coalesce(p->>'reason','')); v_today date:=(now() at time zone 'Asia/Kuala_Lumpur')::date; v_date date:=nullif(p->>'date','')::date;
 prev owner_data.shop_wh_op; r owner_data.shop_request; al owner_data.shop_wh_alloc; b owner_data.shop_wh_batch; e owner_data.shop_entry; sh owner_data.shop_share; fc owner_data.farm_cost; sp public.salary_personal; pay owner_data.shop_payment; v_amount numeric; v_ref text; v_id uuid; v_month text; v_result jsonb:='{}';
begin
 if v_actor is null or not public.shop_is_manager() then raise exception 'Not allowed';end if;
 if v_action in ('RETURN','REFUND') and not exists(select 1 from public.hub_app_user where id=v_actor and status='ACTIVE' and role='OWNER') then raise exception 'Owner authorisation required for returns and refunds';end if;
 if v_op is null or v_date is null or v_date>v_today or length(v_reason) not between 1 and 300 or not coalesce((p->>'verified')::boolean,false) then raise exception 'Confirm actual date, reason and verification';end if;
 perform pg_advisory_xact_lock(27112026,64);
 select * into prev from owner_data.shop_wh_op where id=v_op;
 if found then if prev.actor<>v_actor or prev.payload<>p then raise exception 'Operation ID already used';end if;return prev.result;end if;
 perform owner_data.require_shop('shop_wh_reconcile_'||coalesce(v_action,''),jsonb_build_object('op_id',v_op));
 perform set_config('owner_data.wh_internal','1',true);
 if v_action='REFUND' then
  select * into pay from owner_data.shop_payment where id=(p->>'payment_id')::uuid and voided_at is null for update;
  v_amount:=nullif(p->>'amount','')::numeric;v_ref:=btrim(coalesce(p->>'ref',''));
  if pay.id is null or not exists(select 1 from owner_data.shop_wh_pay where payment_id=pay.id) or pay.reimb_id is not null or v_date<pay.paid_on or v_amount is null or v_amount<=0 or v_amount<>round(v_amount,2) or v_amount>owner_data.shop_wh_payment_net(pay.id) or length(v_ref) not between 1 and 80 then raise exception 'Invalid refund, exceeds net payment, or payment already reimbursed';end if;
  if not coalesce((p->>'original_payer_received')::boolean,false) then raise exception 'Confirm original payer received actual refund';end if;
  insert into owner_data.shop_wh_refund(payment_id,amount,refunded_on,ref,reason,actor) values(pay.id,v_amount,v_date,v_ref,v_reason,v_actor) returning id into v_id;
  v_result:=jsonb_build_object('refund_id',v_id,'net',owner_data.shop_wh_payment_net(pay.id));
 elsif v_action in ('RELEASE','RETURN') then
  select * into r from owner_data.shop_request where id=(p->>'request_id')::uuid for update;
  select * into al from owner_data.shop_wh_alloc where request_id=r.id for update;
  select * into b from owner_data.shop_wh_batch where id=al.batch_id for update;
  if r.id is null or al.request_id is null or b.id is null or exists(select 1 from owner_data.shop_wh_reversal where request_id=r.id) then raise exception 'Not an eligible warehouse allocation';end if;
  if v_action='RELEASE' then
   if r.status<>'BOUGHT' or al.status<>'READY' or v_date<b.received_on then raise exception 'Only an undelivered reservation can be released';end if;
   update owner_data.shop_wh_alloc set status='RELEASED' where request_id=r.id;
   update owner_data.shop_request set status='CANCELLED',decided_at=now(),note=left(v_reason,200) where id=r.id;
  else
   if r.status<>'CONFIRMED' or al.status<>'ISSUED' or v_date<(r.handed_at at time zone 'Asia/Kuala_Lumpur')::date or r.worker_paid then raise exception 'Only issued warehouse stock without worker cash payment can be returned here';end if;
   if b.on_hand+al.qty>b.original_qty then raise exception 'Return exceeds original batch quantity';end if;
   perform set_config('owner_data.wh_reverse_request',r.id::text,true);
   if r.kind='PERSONAL' then
    select * into e from owner_data.shop_entry where id=r.entry_id and voided_at is null for update;
    if e.id is null or e.personal_id is null then raise exception 'Original salary expense unavailable';end if;
    select * into sp from public.salary_personal where id=e.personal_id and voided_at is null for update;
    if sp.id is null or public.salary_month_locked(sp.month) or exists(select 1 from public.salary_payslip where worker_id=sp.worker_id and month=sp.month and voided_at is null) then raise exception 'Salary already locked, payslip exists or original deduction unavailable';end if;
    update public.salary_personal set voided_at=now(),updated_at=now(),updated_by=v_actor where id=sp.id;
    update owner_data.shop_entry set voided_at=now(),void_by='WAREHOUSE_RETURN' where id=e.id;
   elsif r.kind='SHARED' then
    select * into sh from owner_data.shop_share where id=r.share_id and voided_at is null for update;
    if sh.id is null then raise exception 'Original shared expense unavailable';end if;
    select month into v_month from public.salary_food where id=sh.food_id and voided_at is null for update;
    if v_month is null or public.salary_month_locked(v_month) or exists(select 1 from public.salary_payslip where worker_id=any(sh.worker_ids) and month=v_month and voided_at is null) then raise exception 'Shared salary period locked or payslip exists';end if;
    update public.salary_food set voided_at=now(),updated_at=now(),updated_by=v_actor where id=sh.food_id;
    update owner_data.shop_share set voided_at=now() where id=sh.id;
   elsif r.kind='FARM' then
    select * into fc from owner_data.farm_cost where id=r.cost_id and voided_at is null for update;
    if fc.id is null then raise exception 'Original farm expense unavailable';end if;
    update owner_data.farm_cost set voided_at=now(),void_note=left(v_reason,300) where id=fc.id;
   else raise exception 'Unsupported return';end if;
   update owner_data.shop_wh_batch set on_hand=on_hand+al.qty where id=b.id;
   update owner_data.shop_wh_alloc set status='RELEASED' where request_id=r.id;
   perform set_config('owner_data.wh_reverse_request','',true);
  end if;
  insert into owner_data.shop_wh_reversal(request_id,action,qty,batch_id,actual_on,reason,actor) values(r.id,v_action,al.qty,b.id,v_date,v_reason,v_actor) returning id into v_id;
  perform owner_data.shop_wh_allocate(b.option_id);
  v_result:=jsonb_build_object('reversal_id',v_id,'qty',al.qty);
 else raise exception 'Unknown reconciliation action';end if;
 perform set_config('owner_data.wh_internal','0',true);
 v_result:=jsonb_build_object('ok',true,'op_id',v_op)||v_result;
 insert into owner_data.shop_wh_op(id,actor,payload,result) values(v_op,v_actor,p,v_result);
 return v_result;
end $f$;
revoke all on function public.shop_owner_wh_reconcile(jsonb) from public,anon,authenticated;
grant execute on function public.shop_owner_wh_reconcile(jsonb) to authenticated,service_role;
notify pgrst,'reload schema';
