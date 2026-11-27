CREATE OR REPLACE FUNCTION public.shop_owner_hand(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date; v_date date; v_month text;
  x jsonb; r owner_data.shop_request; v_label text; v_price numeric(10,2); v_total numeric(12,2); v_sell numeric(10,2); v_charge numeric(12,2);
  v_ids uuid[]; v_all uuid[]; v_pid text; v_fid text; v_entry uuid; v_cost uuid; v_share uuid; v_n int := 0; v_wpaid boolean;
  g record;
begin
  perform owner_data.require_shop('shop_hand', p);
  begin v_date := coalesce((p->>'date')::date, v_today); exception when others then raise exception 'Invalid date'; end;
  if v_date > v_today then raise exception 'Date cannot be in the future'; end if;
  v_month := to_char(v_date, 'YYYY-MM');
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then raise exception 'Tick at least one'; end if;

  create temp table if not exists _food (id uuid, farm text, round date, total numeric, ids uuid[]) on commit drop;
  delete from _food;

  for x in select * from jsonb_array_elements(p->'lines') loop
    select * into r from owner_data.shop_request where id = (x->>'id')::uuid and status = 'BOUGHT' for update;
    if r.id is null then raise exception 'A line was already handed over — reload'; end if;
    v_label := coalesce((select o.label from public.hub_option o where o.id = r.option_id), r.custom_name);
    v_price := coalesce(r.buy_price, (r.buy->>'price')::numeric); v_total := r.qty * v_price;
    if r.kind <> 'FARM' and public.salary_month_locked(v_month) then raise exception '% is closed', v_month; end if;

    if r.kind in ('SHARED','FOOD') and v_month >= '2026-11' then
      v_ids := owner_data.shop_month_food_ids(v_month,jsonb_build_object('date',v_date));
      if cardinality(v_ids)=0 then raise exception 'No eligible AD employees; check employment before recording shared costs'; end if;
    elsif r.kind in ('SHARED','FOOD') then
      select array_agg(distinct (y)::uuid) into v_ids from jsonb_array_elements_text(coalesce(x->'share_ids','[]'::jsonb)) y;
      if coalesce(array_length(v_ids,1),0) = 0 then raise exception 'Tick at least one worker for %', v_label; end if;
      if exists (select 1 from unnest(v_ids) i where owner_data.shop_worker_farm(i) is distinct from r.farm_code) then
        raise exception 'Worker is not on %', r.farm_code;
      end if;
    end if;

    if r.kind = 'PERSONAL' then
      v_wpaid := coalesce((x->>'worker_paid')::boolean, false);
      if r.bottle_id is not null then
        v_sell := owner_data.shop_whiskey_rate(r.bottle_n);                    -- fixed share, not editable
      else
        if coalesce(r.wh_fixed_sell,r.sell_price) is not null and nullif(x->>'sell','')::numeric is not null
           and round(nullif(x->>'sell','')::numeric,2) <> coalesce(r.wh_fixed_sell,r.sell_price) then
          raise exception 'Confirmed selling price cannot change at delivery';
        end if;
        v_sell := round(coalesce(r.wh_fixed_sell,r.sell_price,nullif(x->>'sell','')::numeric),2);
      end if;
      if v_sell is null or v_sell <= 0 or v_sell > 5000 then raise exception 'Set the sell price for %', v_label; end if;
      v_charge := r.qty * v_sell;
      if v_wpaid then
        v_pid := null;
      else
        v_pid := 'p_' || (extract(epoch from clock_timestamp()) * 1000)::bigint || '_' || substr(md5(random()::text), 1, 3);
        insert into public.salary_personal (id, worker_id, month, data)
        values (v_pid, r.worker_id, v_month, jsonb_build_object('id', v_pid, 'date', v_date,
                'description', v_label || case when r.bottle_n > 1 then ' (share 1/' || r.bottle_n || ')' when r.qty > 1 then ' × ' || r.qty else '' end,
                'amount', v_charge));
      end if;
      insert into owner_data.shop_entry (client_id, device_id, farm_code, worker_id, option_id, item, buy_date, qty, unit_price, default_price, amount, personal_id)
      values (r.client_id, r.device_id, r.farm_code, r.worker_id, r.option_id,
              v_label || case when v_wpaid then ' (worker paid)' else '' end, v_date, r.qty, v_sell, v_price, v_charge, v_pid)
      returning id into v_entry;
      update owner_data.shop_request set status = 'CONFIRMED', decided_at = now(), handed_at = now(), handed_by = auth.uid(), entry_id = v_entry,
             sell_price = v_sell, worker_paid = v_wpaid where id = r.id;
    elsif r.kind = 'SHARED' then
      select coalesce(array_agg(w.id), '{}') into v_all from public.hub_worker w where w.voided_at is null and not (w.id = any(v_ids));
      v_fid := 'f_' || (extract(epoch from clock_timestamp()) * 1000)::bigint || '_' || substr(md5(random()::text), 1, 3);
      insert into public.salary_food (id, month, data)
      values (v_fid, v_month, jsonb_build_object('id', v_fid, 'date', v_date, 'vendor', '',
              'description', r.farm_code || ' · ' || v_label || case when r.qty > 1 then ' × ' || r.qty else '' end,
              'qty', 1, 'unitPrice', v_total, 'total', v_total, 'workerIds', to_jsonb(v_ids), 'autoSel', false,
              'addIds', to_jsonb(v_ids), 'removeIds', to_jsonb(v_all)));
      insert into owner_data.shop_share (farm_code, item, amount, buy_date, worker_ids, food_id, created_by)
      values (r.farm_code, v_label || case when r.qty > 1 then ' × ' || r.qty else '' end, v_total, v_date, v_ids, v_fid, auth.uid())
      returning id into v_share;
      update owner_data.shop_request set status = 'CONFIRMED', decided_at = now(), handed_at = now(), handed_by = auth.uid(), share_id = v_share where id = r.id;
    elsif r.kind = 'FOOD' then
      insert into _food values (r.id, r.farm_code, r.round, v_total, v_ids);
    else
      insert into owner_data.farm_cost (farm_code, option_id, item, qty, unit_price, amount, buy_date, request_id, created_by)
      values (r.farm_code, r.option_id, v_label, r.qty, v_price, v_total, v_date, r.id, auth.uid())
      returning id into v_cost;
      update owner_data.shop_request set status = 'CONFIRMED', decided_at = now(), handed_at = now(), handed_by = auth.uid(), cost_id = v_cost where id = r.id;
    end if;
    v_n := v_n + 1;
  end loop;

  for g in select farm, round, sum(total) total, array_agg(id) line_ids from _food group by farm, round loop
    select f.ids into v_ids from _food f where f.farm = g.farm and f.round = g.round order by f.id limit 1;
    select coalesce(array_agg(w.id), '{}') into v_all from public.hub_worker w where w.voided_at is null and not (w.id = any(v_ids));
    v_fid := 'f_' || (extract(epoch from clock_timestamp()) * 1000)::bigint || '_' || substr(md5(random()::text), 1, 3);
    insert into public.salary_food (id, month, data)
    values (v_fid, v_month, jsonb_build_object('id', v_fid, 'date', v_date, 'vendor', 'Groceries',
            'description', g.farm || ' · Groceries ' || to_char(g.round, 'DD/MM'),
            'qty', 1, 'unitPrice', g.total, 'total', g.total, 'workerIds', to_jsonb(v_ids), 'autoSel', false,
            'addIds', to_jsonb(v_ids), 'removeIds', to_jsonb(v_all)));
    insert into owner_data.shop_share (farm_code, item, amount, buy_date, worker_ids, food_id, created_by)
    values (g.farm, 'Groceries ' || to_char(g.round, 'DD/MM'), g.total, v_date, v_ids, v_fid, auth.uid())
    returning id into v_share;
    update owner_data.shop_request set status = 'CONFIRMED', decided_at = now(), handed_at = now(), handed_by = auth.uid(), share_id = v_share
     where id = any(g.line_ids);
  end loop;
  delete from _food;
  return jsonb_build_object('ok', true, 'count', v_n, 'month', v_month);
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

CREATE OR REPLACE FUNCTION public.shop_owner_month_card(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare m text:=p->>'month'; wid uuid:=nullif(p->>'worker_id','')::uuid; w record; personal jsonb; cash jsonb; shared jsonb; loans jsonb; pending jsonb; pt numeric; ct numeric; ft numeric; fr numeric; shown numeric; locked boolean; snap jsonb; issues text[]:='{}'; shared_review jsonb:='[]'::jsonb; today date:=(now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
if auth.uid() is null or not public.shop_is_manager() then raise exception 'Not allowed';end if;
if m is null or m !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' or m<'2026-11' or m>to_char(today,'YYYY-MM') then raise exception 'Select a month from November 2026 to current month';end if;
locked:=public.salary_month_locked(m);
if wid is null then return jsonb_build_object('month',m,'locked',locked,'today',today,'workers',coalesce((select jsonb_agg(to_jsonb(z) order by z.farm,z.worker_name) from owner_data.shop_month_workers(m) z),'[]'::jsonb));end if;
select * into w from owner_data.shop_month_workers(m) where worker_id=wid;if not found then raise exception 'Worker not in the AD monthly roster';end if;
select coalesce(jsonb_agg(jsonb_build_object('date',s.data->>'date','item',coalesce(nullif(s.data->>'description',''),e.item,'Salary personal expense'),'qty',e.qty,'unit_price',e.unit_price,'item_id',coalesce(e.option_id,r.option_id),'request_id',r.id,'amount',(s.data->>'amount')::numeric,'source',case when e.id is null then 'SALARY' else 'KEDAI' end,'detail',r.detail,'receipt_pending',exists(select 1 from owner_data.shop_delivery_ack a where a.request_id=r.id and a.received_qty<a.sent_qty and owner_data.shop_delivery_valid(a.request_id))) order by s.data->>'date',s.id),'[]'::jsonb),coalesce(sum((s.data->>'amount')::numeric),0)
into personal,pt from public.salary_personal s
left join lateral(select e.* from owner_data.shop_entry e where e.personal_id=s.id and e.voided_at is null order by e.created_at,e.id limit 1) e on true
left join lateral(select r.* from owner_data.shop_request r where r.entry_id=e.id and r.worker_id=wid order by r.created_at,r.id limit 1) r on true
where s.worker_id=wid and s.month=m and s.voided_at is null;
select coalesce(jsonb_agg(jsonb_build_object('date',e.buy_date,'item',e.item,'qty',e.qty,'amount',e.amount,'detail',r.detail,'item_id',coalesce(e.option_id,r.option_id),'request_id',r.id) order by e.buy_date,e.id),'[]'::jsonb),coalesce(sum(e.amount),0) into cash,ct
from owner_data.shop_entry e join lateral(select r.* from owner_data.shop_request r where r.entry_id=e.id and r.worker_paid and r.status='CONFIRMED' order by r.created_at limit 1) r on true where e.worker_id=wid and e.voided_at is null and e.personal_id is null and to_char(e.buy_date,'YYYY-MM')=m;
with f as(select s.*,owner_data.shop_month_food_ids(m,s.data) ids from public.salary_food s where s.month=m and s.voided_at is null),
mine as(select f.*,(f.data->>'total')::numeric/cardinality(f.ids) share from f where wid=any(f.ids))
select coalesce(jsonb_agg(jsonb_build_object('date',f.data->>'date','item',concat_ws(' · ',nullif(f.data->>'vendor',''),nullif(f.data->>'description','')),'amount',round(f.share,2),'n',cardinality(f.ids),'items',coalesce((select jsonb_agg(jsonb_build_object('item',coalesce(o.label,r.custom_name),'qty',r.qty) order by r.id) from owner_data.shop_share sh join owner_data.shop_request r on r.share_id=sh.id left join public.hub_option o on o.id=r.option_id where sh.food_id=f.id and sh.voided_at is null and r.status='CONFIRMED'),'[]'::jsonb)) order by f.data->>'date',f.id),'[]'::jsonb),coalesce(sum(f.share),0),coalesce(sum(round(f.share,2)),0)
into shared,fr,shown from mine f;
ft:=ceil((round(fr*100000)/1000)/10-0.000001)/10;
-- A stored recipient list and live Salary membership may legitimately differ as rosters change.
-- Do not turn a discrepancy into a final worker charge. Preserve the source, show a separate management review.
if m < '2026-11' or locked then
with f as(select s.*,owner_data.shop_month_food_ids(m,s.data) live, array(select value::uuid from jsonb_array_elements_text(coalesce(s.data->'workerIds','[]'::jsonb)) order by value::uuid) stored from public.salary_food s where s.month=m and s.voided_at is null and jsonb_typeof(s.data->'workerIds')='array') select coalesce(jsonb_agg(jsonb_build_object('date',data->>'date','item',concat_ws(' · ',nullif(data->>'vendor',''),nullif(data->>'description','')),'stored_count',cardinality(stored),'live_count',cardinality(live)) order by data->>'date',id),'[]'::jsonb) into shared_review from f where (wid=any(live) or wid=any(stored)) and (not(live @> stored and stored @> live));
end if;
if jsonb_array_length(shared_review)>0 then shared:='[]'::jsonb;ft:=0;shown:=0;issues:=array_append(issues,'SHARED_MEMBERSHIP_REVIEW');end if;
if locked then
select data into snap from public.salary_payslip where worker_id=wid and month=m and voided_at is null order by created_at desc limit 1;
if snap is null or not(snap?'persD') or not(snap?'food') then issues:=array_append(issues,'LOCKED_PAYSLIP_MISSING');
elsif abs((snap->>'persD')::numeric-round(pt,2))>0.005 or (jsonb_array_length(shared_review)=0 and abs((snap->>'food')::numeric-ft)>0.005) then issues:=array_append(issues,'LOCKED_TOTAL_MISMATCH');end if;
end if;
if exists(select 1 from owner_data.shop_entry e join public.salary_personal s on s.id=e.personal_id where e.worker_id=wid and e.voided_at is null and s.month=m and (s.voided_at is not null or s.worker_id<>wid)) then issues:=array_append(issues,'LINKED_DEDUCTION_CHANGED');end if;
select coalesce(jsonb_agg(jsonb_build_object('date',ph.delivered_on,'item',ph.model,'item_id',r.option_id,'request_id',r.id,'amount',ph.agreed_sell,'deposit',ph.deposit,'principal',ph.agreed_sell-ph.deposit,'monthly',ph.monthly,'start_month',ph.start_month) order by ph.delivered_on),'[]'::jsonb) into loans
from owner_data.shop_wh_phone ph join owner_data.shop_request r on r.id=ph.request_id join public.salary_loan_txn t on t.id=ph.loan_id and t.voided_at is null where r.worker_id=wid and ph.stage='DELIVERED' and to_char(ph.delivered_on,'YYYY-MM')=m;
select coalesce(jsonb_agg(jsonb_build_object('date',owner_data.shop_ask(r),'item',coalesce(o.label,r.custom_name),'qty',r.qty,'status',r.status,'detail',r.detail,'ordered',exists(select 1 from owner_data.shop_wh_order a where a.request_id=r.id and a.received_qty+a.cancelled_qty<a.qty)) order by owner_data.shop_ask(r),r.created_at),'[]'::jsonb) into pending
from owner_data.shop_request r left join public.hub_option o on o.id=r.option_id where r.worker_id=wid and r.status in ('REQUESTED','BOUGHT') and owner_data.shop_ask(r)<((m||'-01')::date+interval '1 month')::date;
return jsonb_build_object('month',m,'today',today,'locked',locked,'worker',to_jsonb(w),'personal',personal,'cash',cash,'shared',shared,'instalments',loans,'pending',pending,'personal_total',round(pt,2),'cash_total',round(ct,2),'shared_total',case when jsonb_array_length(shared_review)>0 then null else ft end,'shared_review',shared_review,'shared_rounding',round(ft-shown,2),'salary_total',case when jsonb_array_length(shared_review)>0 then null else round(pt,2)+ft end,'locked_personal',snap->'persD','locked_shared',snap->'food','issues',to_jsonb(issues));
end $function$;

CREATE OR REPLACE FUNCTION public.shop_owner_wh(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_action text:=p->>'action'; v_op uuid:=(p->>'op_id')::uuid; v_actor uuid:=auth.uid(); v_today date:=(now() at time zone 'Asia/Kuala_Lumpur')::date;
 v_date date:=coalesce(nullif(p->>'date','')::date,v_today); v_qty int; v_cost numeric; v_sell numeric; v_result jsonb:='{}'; v_id uuid; v_item uuid; v_req uuid; v_payment uuid; v_part uuid; v_batch uuid; v_take int; v_reserved int; v_reason text; v_label text; v_old owner_data.shop_wh_op; r owner_data.shop_request; o owner_data.shop_wh_order; b owner_data.shop_wh_batch; pol owner_data.shop_wh_policy; opt public.hub_option; v_flag boolean; v_mode text; v_min int; v_pack int; v_n int; v_open boolean; v_spec text; v_quick jsonb; v_received jsonb; v_paid jsonb; v_row jsonb; v_rows jsonb:='[]'::jsonb; v_group uuid; v_total numeric(12,2); v_seen uuid[]:='{}';
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
 elsif v_action='RECEIPT_MULTI' then
  v_reason:=btrim(coalesce(p->>'ref',''));v_label:=btrim(coalesce(p->>'supplier',''));
  if jsonb_typeof(p->'rows') is distinct from 'array' or jsonb_array_length(p->'rows') not between 1 and 50 or length(v_reason) not between 1 and 80 or length(v_label) not between 1 and 100 or not coalesce((p->>'received_verified')::boolean,false) then raise exception 'Verify actual receipt, supplier and all items';end if;
  if exists(select 1 from owner_data.shop_wh_order x where lower(btrim(x.supplier))=lower(v_label) and lower(btrim(coalesce(x.ref,'')))=lower(v_reason)) then raise exception 'Supplier receipt reference already exists; reconcile original receipt';end if;
  if nullif(p->>'receipt_photo','') is not null then
   if length(p->>'receipt_photo')>600000 or (p->>'receipt_photo') !~ '^[A-Za-z0-9+/]+={0,2}$' then raise exception 'Receipt photo too large or invalid';end if;
   if substring(decode(p->>'receipt_photo','base64') from 1 for 3)<>decode('ffd8ff','hex') then raise exception 'Receipt photo must be JPEG';end if;
  end if;
  v_total:=0;
  for v_row in select value from jsonb_array_elements(p->'rows') loop
   v_item:=(v_row->>'item_id')::uuid;v_qty:=(v_row->>'qty')::int;v_cost:=nullif(v_row->>'unit_cost','')::numeric;v_req:=nullif(v_row->>'request_id','')::uuid;
   if v_qty is null or v_qty<1 or v_qty>99999 or v_cost is null or v_cost<=0 or v_cost>5000 or v_cost<>round(v_cost,2) then raise exception 'Verify actual quantity and unit buy price';end if;
   if v_req is not null then
    if v_req=any(v_seen) then raise exception 'Duplicate request in same receipt';end if;v_seen:=v_seen||v_req;
    select * into r from owner_data.shop_request where id=v_req for update;
    if r.id is null or r.option_id is distinct from v_item or r.status<>'REQUESTED' or r.bottle_id is not null or v_qty>r.qty or owner_data.shop_wh_review(r) is not null or not owner_data.shop_wh_spec_complete(v_item,r.detail) then raise exception 'Direct request changed or specification incomplete';end if;
    if exists(select 1 from owner_data.shop_wh_policy x where x.option_id=v_item and x.stock_managed) and owner_data.shop_photo_count(r.id)=0 then raise exception 'Use stock receipt for stock-managed items';end if;
    v_quick:=public.shop_owner_wh(jsonb_build_object('action','ORDER','op_id',gen_random_uuid(),'request_id',v_req,'qty',v_qty,'supplier',v_label,'date',v_date,'ref',v_reason));
    v_received:=public.shop_owner_wh(jsonb_build_object('action','RECEIVE','op_id',gen_random_uuid(),'order_id',v_quick->>'order_id','qty',v_qty,'unit_cost',v_cost,'sell',v_row->>'sell','date',v_date));
   else
    if not owner_data.shop_wh_spec_complete(v_item,v_row->>'stock_spec') then raise exception 'Exact stock size required';end if;
    v_quick:=public.shop_owner_wh(jsonb_build_object('action','QUICK_STOCK','op_id',gen_random_uuid(),'item_id',v_item,'qty',v_qty,'unit_cost',v_cost,'stock_spec',v_row->>'stock_spec','supplier',v_label,'date',v_date,'ref',v_reason,'received_verified',true,'opening_zero',coalesce((v_row->>'opening_zero')::boolean,false)));
    v_received:=v_quick;
   end if;
   update owner_data.shop_wh_order set receipt_group_id=v_op where id=(v_quick->>'order_id')::uuid;
   v_rows:=v_rows||jsonb_build_array(jsonb_build_object('order_id',v_quick->>'order_id','receipt_id',v_received->>'receipt_id','batch_id',v_received->>'batch_id','amount',v_qty*v_cost));
   v_total:=v_total+v_qty*v_cost;
  end loop;
  if nullif(p->>'payer','') is not null then
   if nullif(p->>'paid_total','')::numeric is distinct from v_total then raise exception 'Actual paid total must equal receipt line total';end if;
   v_paid:=public.shop_owner_wh(jsonb_build_object('action','PAY_RECEIPT','op_id',gen_random_uuid(),'receipt_group_id',v_op,'payer',p->>'payer','date',v_date,'ref',v_reason,'amount',v_total));
  end if;
  v_result:=jsonb_build_object('receipt_group_id',v_op,'rows',v_rows,'total',v_total,'pay_id',v_paid->>'pay_id');
 elsif v_action='PAY_RECEIPT' then
  v_group:=(p->>'receipt_group_id')::uuid;v_reason:=btrim(coalesce(p->>'ref',''));
  if v_group is null or length(v_reason) not between 1 and 80 then raise exception 'Verify original receipt and payment reference';end if;
  perform 1 from owner_data.shop_wh_order x where x.receipt_group_id=v_group order by x.id for update;
  if not found then raise exception 'Receipt group not found';end if;
  select min(supplier) into v_label from owner_data.shop_wh_order where receipt_group_id=v_group;
  if exists(select 1 from owner_data.shop_wh_order where receipt_group_id=v_group and ordered_on>v_date) then raise exception 'Payment date before receipt';end if;
  if exists(select 1 from owner_data.shop_wh_pay w join owner_data.shop_wh_order x on x.id=w.order_id join owner_data.shop_payment m on m.id=w.payment_id where x.receipt_group_id=v_group and m.voided_at is null) then raise exception 'Receipt already has payment; reconcile original payment';end if;
  if exists(select 1 from owner_data.shop_wh_pay w join owner_data.shop_wh_order x on x.id=w.order_id join owner_data.shop_payment m on m.id=w.payment_id where m.voided_at is null and lower(btrim(x.supplier))=lower(btrim(v_label)) and lower(btrim(w.ref))=lower(v_reason)) then raise exception 'Supplier payment reference already recorded';end if;
  select coalesce(sum(x.qty*x.unit_cost),0) into v_total from owner_data.shop_wh_receipt x join owner_data.shop_wh_order y on y.id=x.order_id where y.receipt_group_id=v_group;
  if v_total<=0 or nullif(p->>'amount','')::numeric is distinct from v_total then raise exception 'Confirm exact receipt payment total';end if;
  v_payment:=owner_data.shop_pay_new(p->>'payer',v_total,'PURCHASE','Receipt · '||v_label,v_date,v_reason,v_op);
  insert into owner_data.shop_wh_pay(payment_id,order_id,ref,allocated_amount)
  select v_payment,y.id,v_reason,sum(x.qty*x.unit_cost) from owner_data.shop_wh_order y join owner_data.shop_wh_receipt x on x.order_id=y.id where y.receipt_group_id=v_group group by y.id;
  v_result:=jsonb_build_object('pay_id',v_payment,'amount',v_total,'receipt_group_id',v_group);
 elsif v_action='QUICK_STOCK' then
  v_item:=(p->>'item_id')::uuid; v_qty:=(p->>'qty')::int; v_cost:=nullif(p->>'unit_cost','')::numeric;
  v_spec:=btrim(coalesce(p->>'stock_spec',''));
  select * into opt from public.hub_option where id=v_item and shown and list_code in ('FARM_ITEM','PERSONAL_ITEM','SHARED_ITEM') and upper(code) not in ('TOP UP','PINJAM','UBAT','DOCTOR','SIM CARD');
  if opt.id is null or v_qty is null or v_qty<1 or v_qty>99999 or v_cost is null or v_cost<=0 or v_cost>5000 or v_cost<>round(v_cost,2) or length(v_spec)>80 or not owner_data.shop_wh_spec_complete(v_item,v_spec) then raise exception 'Verify item, exact specification, actual quantity and unit cost';end if;
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
   if length(v_spec)>80 or not owner_data.shop_wh_spec_complete(v_item,v_spec) then raise exception 'Enter exact opening stock specification';end if;
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
  if v_flag and (length(v_spec)>80 or not owner_data.shop_wh_spec_complete(v_item,v_spec)) then raise exception 'Enter exact stock specification';end if;
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
  if o.receipt_group_id is not null then raise exception 'Use receipt group payment instead';end if;
  if exists(select 1 from owner_data.shop_wh_pay x join owner_data.shop_wh_order y on y.id=x.order_id join owner_data.shop_payment m on m.id=x.payment_id where m.voided_at is null and lower(btrim(y.supplier))=lower(btrim(o.supplier)) and lower(btrim(x.ref))=lower(v_reason)) then raise exception 'Payment reference already recorded for this supplier; use the original payment or receipt reconciliation';end if;
  v_payment:=owner_data.shop_pay_new(p->>'payer',v_cost,'PURCHASE',o.item||' · '||o.supplier,v_date,v_reason,v_op);
  insert into owner_data.shop_wh_pay(payment_id,order_id,ref) values(v_payment,o.id,v_reason);
  v_result:=jsonb_build_object('pay_id',v_payment,'amount',v_cost);
 elsif v_action='CANCEL_ORDER' then
  select * into o from owner_data.shop_wh_order where id=(p->>'order_id')::uuid for update;
  v_qty:=(p->>'qty')::int;v_reason:=btrim(coalesce(p->>'reason',''));
  if o.id is null or v_qty is null or v_qty<1 or v_qty>o.qty-o.received_qty-o.cancelled_qty or length(v_reason)<1 then raise exception 'Invalid cancellation';end if;
  if coalesce((select sum(owner_data.shop_wh_order_payment_net(m.id,w.order_id)) from owner_data.shop_wh_pay w join owner_data.shop_payment m on m.id=w.payment_id where w.order_id=o.id and m.voided_at is null),0)>coalesce((select sum(x.qty*x.unit_cost) from owner_data.shop_wh_receipt x where x.order_id=o.id),0) then raise exception 'Unreconciled supplier advance — actual refund required before cancellation';end if;
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
   if length(v_spec)>80 or not owner_data.shop_wh_spec_complete(v_item,v_spec) then raise exception 'Enter exact stock specification';end if;
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
 'orders',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('receipt_photo',exists(select 1 from owner_data.shop_wh_op z where z.id=o.receipt_group_id and nullif(z.payload->>'receipt_photo','') is not null),'remaining',o.qty-o.received_qty-o.cancelled_qty,'received_cost',coalesce((select sum(x.qty*x.unit_cost) from owner_data.shop_wh_receipt x where x.order_id=o.id),0),'paid',coalesce((select sum(owner_data.shop_wh_order_payment_net(m.id,x.order_id)) from owner_data.shop_wh_pay x join owner_data.shop_payment m on m.id=x.payment_id where x.order_id=o.id and m.voided_at is null),0)) order by o.ordered_on desc,o.created_at desc) from owner_data.shop_wh_order o),'[]'::jsonb),
 'links',coalesce((select jsonb_agg(jsonb_build_object('request_id',r.id,'root_id',coalesce(t.root_id,r.id),'original_qty',coalesce(rt.original_qty,r.qty),'ordered',exists(select 1 from owner_data.shop_wh_order o where o.request_id=r.id and o.received_qty+o.cancelled_qty<o.qty),'allocation',a.status,'receipt',(r.wh_receipt_parent is not null or exists(select 1 from owner_data.shop_wh_receipt x where x.request_id=r.id)),'fixed_sell',r.wh_fixed_sell,'review',owner_data.shop_wh_review(r))) from owner_data.shop_request r left join owner_data.shop_wh_part t on t.request_id=r.id left join owner_data.shop_wh_root rt on rt.request_id=t.root_id left join owner_data.shop_wh_alloc a on a.request_id=coalesce(nullif(r.buy->>'allocation_id','')::uuid,r.id) where r.status in ('REQUESTED','BOUGHT')),'[]'::jsonb),
 'order_payments',coalesce((select jsonb_agg(jsonb_build_object('payment_id',m.id,'order_id',wp.order_id,'date',m.paid_on,'ref',wp.ref,'payer',m.payer,'source',m.source,'gross',coalesce(wp.allocated_amount,m.amount),'net',owner_data.shop_wh_order_payment_net(m.id,wp.order_id),'grouped',wp.allocated_amount is not null,'reimbursed',m.reimb_id is not null)) from owner_data.shop_wh_pay wp join owner_data.shop_payment m on m.id=wp.payment_id where m.voided_at is null),'[]'::jsonb),
 'refunds',coalesce((select jsonb_agg(to_jsonb(f) order by f.created_at desc) from owner_data.shop_wh_refund f),'[]'::jsonb),
 'returns',coalesce((select jsonb_agg(to_jsonb(z) order by z.created_at desc) from owner_data.shop_wh_reversal z),'[]'::jsonb),
 'issued',coalesce((select jsonb_agg(jsonb_build_object('request_id',r.id,'item',coalesce((select label from public.hub_option where id=r.option_id),r.custom_name),'farm',r.farm_code,'kind',r.kind,'worker',(select name from public.hub_worker where id=r.worker_id),'qty',r.qty,'date',(r.handed_at at time zone 'Asia/Kuala_Lumpur')::date,'worker_paid',case when coalesce(r.buy->>'warehouse_bottle','')='true' then exists(select 1 from owner_data.shop_request y where y.bottle_id=r.bottle_id and y.worker_paid) else r.worker_paid end,'cost',coalesce(nullif(r.buy->>'bottle_price','')::numeric,r.buy_price),'batch_id',a.batch_id,'stock_spec',r.detail,'bottle_group',coalesce(r.buy->>'warehouse_bottle','')='true','members',case when coalesce(r.buy->>'warehouse_bottle','')='true' then (select string_agg(w.name,', ' order by w.name) from owner_data.shop_request y join public.hub_worker w on w.id=y.worker_id where y.bottle_id=r.bottle_id) end,'returned',exists(select 1 from owner_data.shop_wh_reversal z where z.request_id=r.id))) from owner_data.shop_request r join owner_data.shop_wh_alloc a on a.request_id=r.id where r.status='CONFIRMED'),'[]'::jsonb),
 'adjustments',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (select * from owner_data.shop_wh_adjust order by created_at desc limit 100) x),'[]'::jsonb)
 );
end $function$;