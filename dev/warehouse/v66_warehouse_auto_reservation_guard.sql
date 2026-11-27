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
  if old.status='BOUGHT' and new.status='REQUESTED' and (exists(select 1 from owner_data.shop_wh_receipt r where r.request_id=old.id) or exists(select 1 from owner_data.shop_wh_alloc r where r.request_id=old.id)) then raise exception 'Use Warehouse reconciliation to undo receipt or reservation'; end if;
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
  if not v_internal and (exists(select 1 from owner_data.shop_wh_alloc where request_id=old.id) or exists(select 1 from owner_data.shop_wh_receipt where request_id=old.id)) then raise exception 'Use Warehouse delivery confirmation';end if;
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
  if v_flag and v_req is not null and exists(select 1 from owner_data.shop_wh_batch b where b.option_id=v_item and b.on_hand>coalesce((select sum(a.qty) from owner_data.shop_wh_alloc a where a.batch_id=b.id and a.status='READY'),0)) then raise exception 'Available stock exists — refresh and reserve before ordering';end if;
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
  if exists(select 1 from owner_data.shop_wh_pay w join owner_data.shop_payment m on m.id=w.payment_id where w.order_id=o.id and m.voided_at is null) then raise exception 'Paid order needs refund/reconciliation first';end if;
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
  if r.id is null or r.status<>'BOUGHT' or not (exists(select 1 from owner_data.shop_wh_alloc where request_id=r.id and status='READY') or exists(select 1 from owner_data.shop_wh_receipt where request_id=r.id)) then raise exception 'Not a warehouse-ready line';end if;
  if r.kind='PERSONAL' and not(coalesce((p->>'worker_paid')::boolean,false) or coalesce((p->>'deduction_authorised')::boolean,false)) then raise exception 'Confirm authorised deduction or worker cash payment';end if;
  v_result:=public.shop_owner_hand(jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('id',r.id,'share_ids',coalesce(p->'share_ids','[]'::jsonb),'sell',coalesce(nullif(p->>'sell','')::numeric,r.wh_fixed_sell,r.sell_price),'worker_paid',coalesce((p->>'worker_paid')::boolean,false))),'date',v_date));
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
 'orders',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('remaining',o.qty-o.received_qty-o.cancelled_qty,'received_cost',coalesce((select sum(x.qty*x.unit_cost) from owner_data.shop_wh_receipt x where x.order_id=o.id),0),'paid',coalesce((select sum(m.amount) from owner_data.shop_wh_pay x join owner_data.shop_payment m on m.id=x.payment_id where x.order_id=o.id and m.voided_at is null),0)) order by o.ordered_on desc,o.created_at desc) from owner_data.shop_wh_order o),'[]'::jsonb),
 'links',coalesce((select jsonb_agg(jsonb_build_object('request_id',r.id,'root_id',coalesce(t.root_id,r.id),'original_qty',coalesce(rt.original_qty,r.qty),'ordered',exists(select 1 from owner_data.shop_wh_order o where o.request_id=r.id and o.received_qty+o.cancelled_qty<o.qty),'allocation',a.status,'receipt',exists(select 1 from owner_data.shop_wh_receipt x where x.request_id=r.id),'fixed_sell',r.wh_fixed_sell,'review',owner_data.shop_wh_review(r))) from owner_data.shop_request r left join owner_data.shop_wh_part t on t.request_id=r.id left join owner_data.shop_wh_root rt on rt.request_id=t.root_id left join owner_data.shop_wh_alloc a on a.request_id=r.id where r.status in ('REQUESTED','BOUGHT')),'[]'::jsonb),
 'adjustments',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (select * from owner_data.shop_wh_adjust order by created_at desc limit 100) x),'[]'::jsonb)
 );
end $function$;
notify pgrst, 'reload schema';