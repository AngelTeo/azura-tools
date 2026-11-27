CREATE OR REPLACE FUNCTION public.shop_owner_wh(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_action text:=p->>'action'; v_op uuid:=(p->>'op_id')::uuid; v_actor uuid:=auth.uid(); v_today date:=(now() at time zone 'Asia/Kuala_Lumpur')::date;
 v_date date:=coalesce(nullif(p->>'date','')::date,v_today); v_qty int; v_cost numeric; v_sell numeric; v_result jsonb:='{}'; v_id uuid; v_item uuid; v_req uuid; v_payment uuid; v_part uuid; v_batch uuid; v_take int; v_reserved int; v_reason text; v_label text; v_old owner_data.shop_wh_op; r owner_data.shop_request; o owner_data.shop_wh_order; b owner_data.shop_wh_batch; pol owner_data.shop_wh_policy; opt public.hub_option; v_flag boolean; v_mode text; v_min int; v_pack int; v_n int; v_open boolean; v_spec text; v_quick jsonb; v_received jsonb; v_paid jsonb;
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
  if opt.id is null or upper(opt.code) in ('TOP UP','PINJAM','UBAT','DOCTOR','SIM CARD') then raise exception 'Special or unknown item — cannot use stock policy';end if;
  if v_mode not in ('FIXED','VARIABLE') or v_mode is null then raise exception 'Choose price mode';end if;
  if opt.list_code<>'PERSONAL_ITEM' or opt.code='WHISKEY' then v_mode:='VARIABLE';v_sell:=null;end if;
  if v_mode='FIXED' and (v_sell is null or v_sell<=0 or v_sell>5000 or v_sell<>round(v_sell,2)) then raise exception 'Enter fixed selling price';end if;
  if v_mode='VARIABLE' then v_sell:=null;end if;
  select * into pol from owner_data.shop_wh_policy where option_id=v_item for update;
  if pol.option_id is not null and pol.stock_managed<>v_flag and (exists(select 1 from owner_data.shop_wh_batch where option_id=v_item and on_hand>0) or exists(select 1 from owner_data.shop_wh_order where option_id=v_item and received_qty+cancelled_qty<qty) or exists(select 1 from owner_data.shop_wh_alloc a join owner_data.shop_wh_batch z on z.id=a.batch_id where z.option_id=v_item and a.status='READY')) then raise exception 'Resolve stock and open orders before changing fulfilment mode';end if;
  insert into owner_data.shop_wh_policy(option_id,stock_managed,price_mode,fixed_sell,minimum_qty,pack_qty,opening_confirmed,updated_by)
  values(v_item,v_flag,v_mode,v_sell,v_min,v_pack,case when v_flag and coalesce(pol.stock_managed,false) then pol.opening_confirmed else false end,v_actor)
  on conflict(option_id) do update set stock_managed=excluded.stock_managed,price_mode=excluded.price_mode,fixed_sell=excluded.fixed_sell,minimum_qty=excluded.minimum_qty,pack_qty=excluded.pack_qty,opening_confirmed=excluded.opening_confirmed,updated_by=v_actor,updated_at=now();
 elsif v_action='QUICK_STOCK' then
  v_item:=(p->>'item_id')::uuid; v_qty:=(p->>'qty')::int; v_cost:=nullif(p->>'unit_cost','')::numeric;
  v_spec:=btrim(coalesce(p->>'stock_spec',''));
  select * into opt from public.hub_option where id=v_item and shown and list_code in ('FARM_ITEM','PERSONAL_ITEM','SHARED_ITEM') and upper(code) not in ('TOP UP','PINJAM','UBAT','DOCTOR','SIM CARD');
  if opt.id is null or v_qty is null or v_qty<1 or v_qty>99999 or v_cost is null or v_cost<=0 or v_cost>5000 or v_cost<>round(v_cost,2) or length(v_spec)>80 or (owner_data.shop_wh_spec_required(v_item) and v_spec='') then raise exception 'Verify item, exact specification, actual quantity and unit cost';end if;
  if length(btrim(coalesce(p->>'supplier',''))) not between 1 and 100 then raise exception 'Enter actual supplier';end if;
  if not coalesce((p->>'received_verified')::boolean,false) then raise exception 'Confirm actual physical receipt';end if;
  select * into pol from owner_data.shop_wh_policy where option_id=v_item;
  if not coalesce(pol.stock_managed,false) or not pol.opening_confirmed then
   if not coalesce((p->>'opening_zero')::boolean,false) then raise exception 'Confirm opening stock first (zero only after actual count)';end if;
   if exists(select 1 from owner_data.shop_wh_batch where option_id=v_item and on_hand>0) or exists(select 1 from owner_data.shop_wh_order where option_id=v_item and received_qty+cancelled_qty<qty) then raise exception 'Resolve existing stock and orders first';end if;
   if not coalesce(pol.stock_managed,false) then
    v_sell:=owner_data.shop_fixed_sell_for(v_item);
    perform public.shop_owner_wh(jsonb_build_object('action','POLICY','op_id',gen_random_uuid(),'item_id',v_item,'stock',true,'price_mode',case when v_sell is null then 'VARIABLE' else 'FIXED' end,'fixed_sell',v_sell,'minimum',pol.minimum_qty,'pack',pol.pack_qty));
   end if;
   perform public.shop_owner_wh(jsonb_build_object('action','OPENING','op_id',gen_random_uuid(),'item_id',v_item,'qty',0,'date',v_date,'reason','Manager verified zero opening stock before actual purchase'));
  end if;
  v_quick:=public.shop_owner_wh(jsonb_build_object('action','ORDER','op_id',gen_random_uuid(),'item_id',v_item,'qty',v_qty,'supplier',p->>'supplier','date',v_date,'ref',p->>'ref','stock_spec',v_spec));
  v_received:=public.shop_owner_wh(jsonb_build_object('action','RECEIVE','op_id',gen_random_uuid(),'order_id',v_quick->>'order_id','qty',v_qty,'unit_cost',v_cost,'date',v_date));
  if nullif(p->>'payer','') is not null then
   if length(btrim(coalesce(p->>'ref',''))) not between 1 and 80 then raise exception 'Actual payment reference required';end if;
   v_paid:=public.shop_owner_wh(jsonb_build_object('action','PAY','op_id',gen_random_uuid(),'order_id',v_quick->>'order_id','amount',v_qty*v_cost,'payer',p->>'payer','date',v_date,'ref',p->>'ref'));
  end if;
  v_result:=jsonb_build_object('order_id',v_quick->>'order_id','batch_id',v_received->>'batch_id','receipt_id',v_received->>'receipt_id','pay_id',v_paid->>'pay_id','received_qty',v_qty,'amount',v_qty*v_cost);
 elsif v_action='OPENING' then
  v_item:=(p->>'item_id')::uuid;v_qty:=(p->>'qty')::int;v_cost:=nullif(p->>'unit_cost','')::numeric;v_reason:=btrim(coalesce(p->>'reason',''));v_spec:=btrim(coalesce(p->>'stock_spec',''));
  select * into pol from owner_data.shop_wh_policy where option_id=v_item for update;
  if not coalesce(pol.stock_managed,false) or pol.opening_confirmed then raise exception 'Opening stock already confirmed or item not stock-managed';end if;
  if v_qty is null or v_qty<0 or v_qty>99999 or length(v_reason)<1 then raise exception 'Enter verified opening quantity and evidence';end if;
  if v_qty>0 then
   if length(v_spec)>80 or (owner_data.shop_wh_spec_required(v_item) and v_spec='') then raise exception 'Enter exact opening stock specification';end if;
   if v_cost is null or v_cost<=0 or v_cost>5000 or v_cost<>round(v_cost,2) then raise exception 'Verified actual opening unit cost required';end if;
   insert into owner_data.shop_wh_batch(option_id,received_on,original_qty,on_hand,unit_cost,source,ref,created_by,stock_spec) values(v_item,v_date,v_qty,v_qty,v_cost,'OPENING',left(v_reason,300),v_actor,v_spec) returning id into v_batch;
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
  v_spec:=btrim(coalesce(case when v_req is not null then r.detail else p->>'stock_spec' end,''));
  if v_req is not null and owner_data.shop_photo_count(r.id)>0 then v_flag:=false;end if;
  if v_flag and (length(v_spec)>80 or (owner_data.shop_wh_spec_required(v_item) and v_spec='')) then raise exception 'Enter exact stock specification';end if;
  if v_req is null and not v_flag then raise exception 'Only stock-managed goods can be replenished without a request';end if;
  if v_flag and not pol.opening_confirmed then raise exception 'Confirm actual opening stock first';end if;
  if v_flag and v_req is not null and exists(select 1 from owner_data.shop_wh_batch wb where wb.option_id=v_item and owner_data.shop_wh_spec(wb.stock_spec)=owner_data.shop_wh_spec(v_spec) and wb.on_hand>coalesce((select sum(wa.qty) from owner_data.shop_wh_alloc wa where wa.batch_id=wb.id and wa.status='READY'),0)) then raise exception 'Available stock exists — refresh and reserve before ordering';end if;
  insert into owner_data.shop_wh_order(option_id,request_id,item,supplier,ordered_on,qty,ref,created_by,stock_order,stock_spec)
  values(v_item,v_req,v_label,btrim(p->>'supplier'),v_date,v_qty,nullif(left(btrim(coalesce(p->>'ref','')),100),''),v_actor,v_flag,v_spec) returning id into v_id;
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
   insert into owner_data.shop_wh_batch(option_id,order_id,received_on,original_qty,on_hand,unit_cost,source,ref,created_by,stock_spec) values(o.option_id,o.id,v_date,v_qty,v_qty,v_cost,'RECEIPT',o.ref,v_actor,o.stock_spec) returning id into v_batch;
   if o.request_id is not null then v_part:=owner_data.shop_wh_reserve(o.request_id,v_batch,v_qty);end if;
  else
   if o.request_id is null or (coalesce(pol.stock_managed,false) and owner_data.shop_photo_count(r.id)=0) then raise exception 'Request or stock policy changed';end if;
   if r.kind='PERSONAL' then
    if owner_data.shop_fixed_sell_for(o.option_id) is not null then
     if v_sell is not null and v_sell<>owner_data.shop_fixed_sell_for(o.option_id) then raise exception 'Fixed selling price cannot change';end if;
     v_sell:=owner_data.shop_fixed_sell_for(o.option_id);
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
  if exists(select 1 from owner_data.shop_wh_pay x join owner_data.shop_wh_order y on y.id=x.order_id join owner_data.shop_payment m on m.id=x.payment_id where m.voided_at is null and lower(btrim(y.supplier))=lower(btrim(o.supplier)) and lower(btrim(x.ref))=lower(v_reason)) then raise exception 'Payment reference already recorded for this supplier; use the original payment or receipt reconciliation';end if;
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
   v_spec:=btrim(coalesce(p->>'stock_spec',''));
   if length(v_spec)>80 or (owner_data.shop_wh_spec_required(v_item) and v_spec='') then raise exception 'Enter exact stock specification';end if;
   insert into owner_data.shop_wh_batch(option_id,received_on,original_qty,on_hand,unit_cost,source,ref,created_by,stock_spec) values(v_item,v_date,v_qty,v_qty,v_cost,'ADJUST_UP',left(v_reason,300),v_actor,v_spec) returning id into v_batch;
   perform owner_data.shop_wh_allocate(v_item);
  end if;
  insert into owner_data.shop_wh_adjust(batch_id,delta,reason,actual_on,created_by) values(v_batch,v_qty,v_reason,v_date,v_actor);
 elsif v_action='ISSUE_BOTTLE' then
  if not coalesce((p->>'physical_verified')::boolean,false) then raise exception 'Confirm actual whole unit delivery';end if;
  select * into r from owner_data.shop_request where id=(p->>'request_id')::uuid for update;
  if r.id is null or r.bottle_id is null or r.status<>'BOUGHT' or coalesce(r.buy->>'warehouse_bottle','')<>'true' then raise exception 'Not a reserved whole-bottle group';end if;
  select * into b from owner_data.shop_wh_batch where id=(r.buy->>'batch_id')::uuid for update;
  if b.id is null or v_date<b.received_on then raise exception 'Check physical delivery date';end if;
  if not exists(select 1 from owner_data.shop_wh_alloc z where z.request_id=(r.buy->>'allocation_id')::uuid and z.batch_id=b.id and z.status='READY' and z.qty=1) then raise exception 'Reservation unavailable';end if;
  perform 1 from owner_data.shop_request x where x.bottle_id=r.bottle_id order by x.id for update;
  if (select count(*) from owner_data.shop_request x where x.bottle_id=r.bottle_id)<>r.bottle_n or exists(select 1 from owner_data.shop_request x where x.bottle_id=r.bottle_id and (x.status<>'BOUGHT' or x.buy->>'allocation_id' is distinct from r.buy->>'allocation_id' or owner_data.shop_wh_review(x) is not null)) then raise exception 'Whole group changed or needs review';end if;
  if jsonb_typeof(p->'cash_ids') is distinct from 'array' or exists(select 1 from jsonb_array_elements_text(p->'cash_ids') y where not exists(select 1 from owner_data.shop_request x where x.bottle_id=r.bottle_id and x.id=y::uuid)) then raise exception 'Invalid cash confirmation';end if;
  if not coalesce((p->>'deduction_authorised')::boolean,false) and (select count(distinct y) from jsonb_array_elements_text(p->'cash_ids') y)<>r.bottle_n then raise exception 'Confirm authorised deductions or actual cash receipts for every member';end if;
  perform set_config('owner_data.wh_bottle_issue',r.bottle_id::text,true);
  select jsonb_agg(jsonb_build_object('id',x.id,'worker_paid',p->'cash_ids' ? x.id::text) order by x.id) into v_quick from owner_data.shop_request x where x.bottle_id=r.bottle_id;
  v_result:=public.shop_owner_hand(jsonb_build_object('lines',v_quick,'date',v_date));
  perform set_config('owner_data.wh_bottle_issue','',true);
 elsif v_action='ISSUE' then
  select * into r from owner_data.shop_request where id=(p->>'request_id')::uuid for update;
  if r.bottle_id is not null then raise exception 'Confirm whole-bottle group together';end if;
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
 if exists(select 1 from owner_data.shop_request r join owner_data.shop_wh_policy w on w.option_id=r.option_id and w.stock_managed and w.opening_confirmed where r.status='REQUESTED' and r.kind<>'FOOD' and owner_data.shop_wh_review(r) is null and owner_data.shop_photo_count(r.id)=0 and owner_data.shop_wh_spec_complete(r.option_id,r.detail) and not exists(select 1 from owner_data.shop_wh_order o where o.request_id=r.id and o.received_qty+o.cancelled_qty<o.qty) and exists(select 1 from owner_data.shop_wh_batch b where b.option_id=r.option_id and owner_data.shop_wh_spec(b.stock_spec)=owner_data.shop_wh_spec(r.detail) and b.on_hand>coalesce((select sum(a.qty) from owner_data.shop_wh_alloc a where a.batch_id=b.id and a.status='READY'),0))) then
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
 'links',coalesce((select jsonb_agg(jsonb_build_object('request_id',r.id,'root_id',coalesce(t.root_id,r.id),'original_qty',coalesce(rt.original_qty,r.qty),'ordered',exists(select 1 from owner_data.shop_wh_order o where o.request_id=r.id and o.received_qty+o.cancelled_qty<o.qty),'allocation',a.status,'receipt',(r.wh_receipt_parent is not null or exists(select 1 from owner_data.shop_wh_receipt x where x.request_id=r.id)),'fixed_sell',r.wh_fixed_sell,'review',owner_data.shop_wh_review(r))) from owner_data.shop_request r left join owner_data.shop_wh_part t on t.request_id=r.id left join owner_data.shop_wh_root rt on rt.request_id=t.root_id left join owner_data.shop_wh_alloc a on a.request_id=coalesce(nullif(r.buy->>'allocation_id','')::uuid,r.id) where r.status in ('REQUESTED','BOUGHT')),'[]'::jsonb),
 'order_payments',coalesce((select jsonb_agg(jsonb_build_object('payment_id',m.id,'order_id',wp.order_id,'date',m.paid_on,'ref',wp.ref,'payer',m.payer,'source',m.source,'gross',m.amount,'net',owner_data.shop_wh_payment_net(m.id),'reimbursed',m.reimb_id is not null)) from owner_data.shop_wh_pay wp join owner_data.shop_payment m on m.id=wp.payment_id where m.voided_at is null),'[]'::jsonb),
 'refunds',coalesce((select jsonb_agg(to_jsonb(f) order by f.created_at desc) from owner_data.shop_wh_refund f),'[]'::jsonb),
 'returns',coalesce((select jsonb_agg(to_jsonb(z) order by z.created_at desc) from owner_data.shop_wh_reversal z),'[]'::jsonb),
 'issued',coalesce((select jsonb_agg(jsonb_build_object('request_id',r.id,'item',coalesce((select label from public.hub_option where id=r.option_id),r.custom_name),'farm',r.farm_code,'kind',r.kind,'worker',(select name from public.hub_worker where id=r.worker_id),'qty',r.qty,'date',(r.handed_at at time zone 'Asia/Kuala_Lumpur')::date,'worker_paid',case when coalesce(r.buy->>'warehouse_bottle','')='true' then exists(select 1 from owner_data.shop_request y where y.bottle_id=r.bottle_id and y.worker_paid) else r.worker_paid end,'cost',coalesce(nullif(r.buy->>'bottle_price','')::numeric,r.buy_price),'batch_id',a.batch_id,'stock_spec',r.detail,'bottle_group',coalesce(r.buy->>'warehouse_bottle','')='true','members',case when coalesce(r.buy->>'warehouse_bottle','')='true' then (select string_agg(w.name,', ' order by w.name) from owner_data.shop_request y join public.hub_worker w on w.id=y.worker_id where y.bottle_id=r.bottle_id) end,'returned',exists(select 1 from owner_data.shop_wh_reversal z where z.request_id=r.id))) from owner_data.shop_request r join owner_data.shop_wh_alloc a on a.request_id=r.id where r.status='CONFIRMED'),'[]'::jsonb),
 'adjustments',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (select * from owner_data.shop_wh_adjust order by created_at desc limit 100) x),'[]'::jsonb)
 );
end $function$;

CREATE OR REPLACE FUNCTION public.shop_owner_wh_reconcile(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_actor uuid:=auth.uid(); v_op uuid:=(p->>'op_id')::uuid; v_action text:=p->>'action'; v_reason text:=btrim(coalesce(p->>'reason','')); v_today date:=(now() at time zone 'Asia/Kuala_Lumpur')::date; v_date date:=nullif(p->>'date','')::date;
 prev owner_data.shop_wh_op; r owner_data.shop_request; al owner_data.shop_wh_alloc; b owner_data.shop_wh_batch; e owner_data.shop_entry; sh owner_data.shop_share; fc owner_data.farm_cost; sp public.salary_personal; pay owner_data.shop_payment; v_amount numeric; v_ref text; v_id uuid; v_month text; v_result jsonb:='{}'; v_group uuid; member owner_data.shop_request;
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
  if coalesce(r.buy->>'warehouse_bottle','')='true' then
   v_group:=r.bottle_id;
   select * into r from owner_data.shop_request where id=(r.buy->>'allocation_id')::uuid for update;
   perform 1 from owner_data.shop_request x where x.bottle_id=v_group order by x.id for update;
   if (select count(*) from owner_data.shop_request x where x.bottle_id=v_group)<>r.bottle_n then raise exception 'Whole group changed';end if;
   perform set_config('owner_data.wh_bottle_issue',v_group::text,true);
  end if;
  select * into al from owner_data.shop_wh_alloc where request_id=r.id for update;
  select * into b from owner_data.shop_wh_batch where id=al.batch_id for update;
  if r.id is null or al.request_id is null or b.id is null or exists(select 1 from owner_data.shop_wh_reversal where request_id=r.id) then raise exception 'Not an eligible warehouse allocation';end if;
  if v_action='RELEASE' then
   if r.status<>'BOUGHT' or al.status<>'READY' or v_date<b.received_on then raise exception 'Only an undelivered reservation can be released';end if;
   update owner_data.shop_wh_alloc set status='RELEASED' where request_id=r.id;
   if v_group is not null and exists(select 1 from owner_data.shop_request x where x.bottle_id=v_group and x.status<>'BOUGHT') then raise exception 'Whole group is not undelivered';end if;
   update owner_data.shop_request set status='CANCELLED',decided_at=now(),note=left(v_reason,200) where id=r.id or (v_group is not null and bottle_id=v_group);
  else
   if r.status<>'CONFIRMED' or al.status<>'ISSUED' or v_date<(r.handed_at at time zone 'Asia/Kuala_Lumpur')::date or r.worker_paid then raise exception 'Only issued warehouse stock without worker cash payment can be returned here';end if;
   if b.on_hand+al.qty>b.original_qty then raise exception 'Return exceeds original batch quantity';end if;
   perform set_config('owner_data.wh_reverse_request',r.id::text,true);
   if v_group is not null then
    for member in select * from owner_data.shop_request x where x.bottle_id=v_group order by x.id loop
     if member.status<>'CONFIRMED' or member.worker_paid or v_date<(member.handed_at at time zone 'Asia/Kuala_Lumpur')::date then raise exception 'Whole-group return requires all original deductions and no cash receipts';end if;
     select * into e from owner_data.shop_entry where id=member.entry_id and voided_at is null for update;
     select * into sp from public.salary_personal where id=e.personal_id and voided_at is null for update;
     if e.id is null or sp.id is null or public.salary_month_locked(sp.month) or exists(select 1 from public.salary_payslip where worker_id=sp.worker_id and month=sp.month and voided_at is null) then raise exception 'Salary already locked, payslip exists or original deduction unavailable';end if;
     perform set_config('owner_data.wh_reverse_request',member.id::text,true);
     update public.salary_personal set voided_at=now(),updated_at=now(),updated_by=v_actor where id=sp.id;
     update owner_data.shop_entry set voided_at=now(),void_by='WAREHOUSE_RETURN' where id=e.id;
    end loop;
   elsif r.kind='PERSONAL' then
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
  perform set_config('owner_data.wh_bottle_issue','',true);
  perform owner_data.shop_wh_allocate(b.option_id);
  v_result:=jsonb_build_object('reversal_id',v_id,'qty',al.qty);
 else raise exception 'Unknown reconciliation action';end if;
 perform set_config('owner_data.wh_internal','0',true);
 v_result:=jsonb_build_object('ok',true,'op_id',v_op)||v_result;
 insert into owner_data.shop_wh_op(id,actor,payload,result) values(v_op,v_actor,p,v_result);
 return v_result;
end $function$;

CREATE OR REPLACE FUNCTION owner_data.shop_pay_new(p_by text, p_amount numeric, p_purpose text, p_label text, p_date date, p_ref text, p_client uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_by text := owner_data.shop_payer(p_by); v_id uuid;
begin
  if v_by is null then raise exception 'Pick who paid: TBF, LEX, LZF or Petty Cash'; end if;
  if p_amount is null or p_amount < 0 then raise exception 'Bad amount'; end if;
  insert into owner_data.shop_payment (client_id, paid_on, amount, source, payer, purpose, label, ref, created_by)
  values (p_client, coalesce(p_date, (now() at time zone 'Asia/Kuala_Lumpur')::date), round(p_amount, 2),
          case when v_by = 'PETTY' then 'PETTY' else 'MGMT' end, nullif(v_by, 'PETTY'), p_purpose, left(p_label, 200),
          nullif(left(btrim(coalesce(p_ref,'')), 80), ''), auth.uid())
  returning id into v_id;
  return v_id;
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