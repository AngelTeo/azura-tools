CREATE OR REPLACE FUNCTION public.salary_lock_month(p_month text, p_payslips jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare n integer;
begin
  if not public.hub_can('SALARY', 'approve') then raise exception 'You need Salary approve access to lock a month'; end if;
  if p_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then raise exception 'Invalid month: %', p_month; end if;
  if public.salary_month_locked(p_month) then raise exception '% is already locked', p_month; end if;
  if jsonb_typeof(p_payslips) <> 'array' or jsonb_array_length(p_payslips) = 0 then raise exception 'No payslips to lock'; end if;
  if p_month >= '2026-11' then
    if exists(select 1 from public.salary_food f where f.month=p_month and f.voided_at is null and cardinality(owner_data.shop_month_food_ids(p_month,f.data))=0 and coalesce((f.data->>'total')::numeric,0)>0) then
      raise exception 'Food expense has no eligible attendance; check attendance before locking';
    end if;
    if exists(
      with charges as (select u.wid, sum((f.data->>'total')::numeric/cardinality(q.ids)) total
        from public.salary_food f cross join lateral (select owner_data.shop_month_food_ids(p_month,f.data) ids) q
        cross join lateral unnest(q.ids) u(wid) where f.month=p_month and f.voided_at is null group by u.wid),
      slips as (select (x->>'worker_id')::uuid wid,(x->'data'->>'food')::numeric food from jsonb_array_elements(p_payslips) x)
      select 1 from charges c full join slips s on s.wid=c.wid
        where s.wid is null or s.food is null or abs(s.food - coalesce(ceil((round(c.total*100000)/1000)/10-0.000001)/10,0))>0.005
    ) then raise exception 'Food allocation mismatch; refresh Salary and review attendance before locking'; end if;
    update public.salary_food f set data=f.data || jsonb_build_object('workerIds',to_jsonb(owner_data.shop_month_food_ids(p_month,f.data)),'allocation_rule','HALF_MONTH_ATTENDANCE_V1','original_workerIds',coalesce(f.data->'original_workerIds',f.data->'workerIds','[]'::jsonb)),updated_at=now()
      where f.month=p_month and f.voided_at is null and nullif(f.data->>'date','') is not null;
  end if;
  insert into public.salary_payslip (month, worker_id, data)
    select p_month, (x->>'worker_id')::uuid, x->'data' from jsonb_array_elements(p_payslips) x;
  get diagnostics n = row_count;
  insert into public.salary_run (month, status, locked_at, locked_by) values (p_month, 'LOCKED', now(), auth.uid())
    on conflict (month) do update set status = 'LOCKED', locked_at = now(), locked_by = auth.uid(), updated_at = now();
  insert into public.salary_run_log (month, action, payslips) values (p_month, 'LOCK', n);
  return n;
end $function$;

CREATE OR REPLACE FUNCTION owner_data.shop_month_food_ids(m text, d jsonb)
 RETURNS uuid[]
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
with dates as (select (m||'-01')::date lo,((m||'-01')::date+interval '1 month' - interval '1 day')::date hi,nullif(d->>'date','')::date dt),
roster as (select w.id,w.join_date,w.stop_date,w.shares_food from public.hub_worker w,dates
where w.voided_at is null and (case when public.salary_month_locked(m) then exists(select 1 from public.salary_payslip s where s.worker_id=w.id and s.month=m and s.voided_at is null) else (w.join_date is null or w.join_date<=dates.hi) and (w.stop_date is null or w.stop_date>=dates.lo) end)),
eligible as (
select r.id from roster r,dates where dates.dt is not null and r.shares_food is not false and (r.join_date is null or r.join_date<=case when extract(day from dates.dt)<=15 then dates.lo+14 else dates.hi end) and (r.stop_date is null or r.stop_date>=case when extract(day from dates.dt)<=15 then dates.lo else dates.lo+15 end)
union select r.id from roster r where d->'addIds' ? r.id::text)
select case when m >= '2026-11' and (select dt from dates) is not null then
case when public.salary_month_locked(m) then coalesce((select array_agg(value::uuid) from jsonb_array_elements_text(coalesce(d->'workerIds','[]'::jsonb))), '{}'::uuid[])
else coalesce((select array_agg(r.id order by r.id) from roster r,dates
where r.shares_food is not false and exists(select 1 from public.salary_attendance a where a.worker_id=r.id and a.code in ('ad','ad_half','hx','hx_half','both','split') and a.work_date between
case when extract(day from dates.dt)<=15 then dates.lo else dates.lo+15 end and
case when extract(day from dates.dt)<=15 then dates.lo+14 else dates.hi end)), '{}'::uuid[]) end
when nullif(d->>'date','') is null then coalesce((select array_agg(value::uuid) from jsonb_array_elements_text(coalesce(d->'workerIds','[]'::jsonb))), '{}'::uuid[])
else coalesce((select array_agg(e.id order by e.id) from eligible e where not coalesce(d->'removeIds' ? e.id::text,false)), '{}'::uuid[]) end
$function$;

CREATE OR REPLACE FUNCTION owner_data.shop_month_workers(m text)
 RETURNS TABLE(worker_id uuid, worker_name text, farm text, stopped boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
select w.id,w.name,coalesce(f.code,case when w.title='AD FLOATING' and f.code is null and exists(select 1 from public.hub_worker_company a join public.hub_company hc on hc.id=a.company_id where a.worker_id=w.id and a.voided_at is null and a.effective_from<=m and hc.code='AD') then 'AD FLOATING' end,(select e.farm_code from owner_data.shop_entry e where e.worker_id=w.id and to_char(e.buy_date,'YYYY-MM')=m and e.voided_at is null order by e.buy_date desc,e.created_at desc limit 1),'AD'),coalesce(w.stop_date<=(now() at time zone 'Asia/Kuala_Lumpur')::date,false)
from public.hub_worker w
left join lateral(select h.code from public.hub_worker_farm a join public.hub_farm h on h.id=a.farm_id where a.worker_id=w.id and a.voided_at is null and a.effective_from<=m order by a.effective_from desc,a.created_at desc limit 1) f on true
where w.voided_at is null and (
((f.code in ('AD 1','AD 2','AD 3') or (w.title='AD FLOATING' and f.code is null and exists(select 1 from public.hub_worker_company a join public.hub_company hc on hc.id=a.company_id where a.worker_id=w.id and a.voided_at is null and a.effective_from<=m and hc.code='AD'))) and (w.join_date is null or to_char(w.join_date,'YYYY-MM')<=m) and (w.stop_date is null or to_char(w.stop_date,'YYYY-MM')>=m))
or exists(select 1 from owner_data.shop_entry e where e.worker_id=w.id and e.farm_code in ('AD 1','AD 2','AD 3') and e.voided_at is null and (to_char(e.buy_date,'YYYY-MM')=m or exists(select 1 from public.salary_personal s where s.id=e.personal_id and s.month=m and s.voided_at is null)))
or exists(select 1 from owner_data.shop_request r where r.worker_id=w.id and r.farm_code in ('AD 1','AD 2','AD 3') and r.status in ('REQUESTED','BOUGHT','CONFIRMED') and to_char(owner_data.shop_ask(r),'YYYY-MM')=m))
$function$;

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
      if cardinality(v_ids)=0 then raise exception 'No eligible attendance; check attendance before recording shared costs'; end if;
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

CREATE OR REPLACE FUNCTION public.shop_owner_wh_special(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare a text:=p->>'action'; v_actor uuid:=auth.uid(); v_op uuid:=(p->>'op_id')::uuid; v_today date:=(now() at time zone 'Asia/Kuala_Lumpur')::date; v_date date:=coalesce(nullif(p->>'date','')::date,v_today); v_month text;
 r owner_data.shop_request; ph owner_data.shop_wh_phone; prev owner_data.shop_wh_op; sp public.salary_personal; en owner_data.shop_entry; plan public.salary_loan_plan; sameplan public.salary_loan_plan;
 v_review text; v_reason text:=btrim(coalesce(p->>'reason','')); v_mode text; v_amt numeric; v_sell numeric; v_dep numeric; v_monthly numeric; v_combined numeric; v_start text; v_principal numeric; v_pay uuid; v_entry uuid; v_cost uuid; v_loan uuid; v_plan uuid; v_opt uuid; v_label text; v_pid text; v_result jsonb:='{}'; v_legacy boolean:=false; v_replace boolean:=false; v_ref text;
begin
 if v_actor is null or not public.shop_is_manager() then raise exception 'Not allowed';end if;
 if v_op is null then raise exception 'Operation ID required';end if;
 perform pg_advisory_xact_lock(27112026,64);
 select * into prev from owner_data.shop_wh_op where id=v_op;
 if found then if prev.actor<>v_actor or prev.payload<>p then raise exception 'Operation ID already used with different parameters';end if;return prev.result;end if;
 if v_date>v_today then raise exception 'Date cannot be in the future';end if;
 select * into r from owner_data.shop_request where id=(p->>'request_id')::uuid for update;
 if r.id is null or r.kind<>'PERSONAL' or r.bottle_id is not null then raise exception 'Unknown special request';end if;
 if r.status not in ('REQUESTED','BOUGHT') then raise exception 'Already handled — refresh';end if;
 v_review:=owner_data.shop_wh_review(r);
 select * into ph from owner_data.shop_wh_phone where request_id=r.id for update;
 v_month:=to_char(v_date,'YYYY-MM');
 v_label:=coalesce((select label from public.hub_option where id=r.option_id),r.custom_name);
 perform owner_data.require_shop('shop_wh_special_'||coalesce(a,'unknown'),jsonb_build_object('op_id',v_op,'request_id',r.id));
 perform set_config('owner_data.wh_internal','1',true);

 if a='LINK_SALARY' then
  if r.status<>'REQUESTED' or coalesce(v_review,'') not in ('MEDICAL','WORKER') or length(v_reason) not between 1 and 300 then raise exception 'Verify the original expense and evidence first';end if;
  select * into sp from public.salary_personal where id=p->>'salary_id' and worker_id=r.worker_id and voided_at is null for update;
  if sp.id is null or coalesce(sp.data->>'date','')!~'^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception 'Choose a verified existing Salary deduction';end if;
  v_date:=(sp.data->>'date')::date;v_amt:=nullif(sp.data->>'amount','')::numeric;
  if v_amt is null or v_amt<=0 or v_amt<>round(v_amt,2) or v_date>v_today then raise exception 'Invalid historical salary amount/date';end if;
  if exists(select 1 from owner_data.shop_wh_review_resolution where salary_id=sp.id) then raise exception 'Salary record already reconciled to another request';end if;
  select * into en from owner_data.shop_entry where personal_id=sp.id and voided_at is null order by created_at limit 1 for update;
  if en.id is not null then
   if en.worker_id<>r.worker_id or en.amount<>v_amt then raise exception 'Existing entry does not match salary record';end if;
   v_entry:=en.id;
  else
   if r.option_id is null or r.qty>20 or v_amt/r.qty<>round(v_amt/r.qty,2) then raise exception 'Exact catalogue match and divisible original quantity required';end if;
   insert into owner_data.shop_entry(client_id,device_id,farm_code,worker_id,option_id,item,buy_date,qty,unit_price,amount,personal_id)
   values(r.client_id,r.device_id,r.farm_code,r.worker_id,r.option_id,left(coalesce(sp.data->>'description',v_label),200),v_date,r.qty,v_amt/r.qty,v_amt,sp.id) returning id into v_entry;
   v_legacy:=coalesce((p->>'payment_pending')::boolean,false);
  end if;
  insert into owner_data.shop_wh_review_resolution(request_id,mode,reason,salary_id,created_by)
   values(r.id,case when v_review='MEDICAL' then 'MEDICAL_EXISTING' else 'HISTORICAL' end,v_reason,sp.id,v_actor);
  update owner_data.shop_request set status='CONFIRMED',decided_at=now(),handed_at=(v_date::timestamp at time zone 'Asia/Kuala_Lumpur'),handed_by=v_actor,entry_id=v_entry,sell_price=v_amt/r.qty,legacy=v_legacy where id=r.id;
  v_result:=jsonb_build_object('entry_id',v_entry,'existing_salary_id',sp.id,'new_salary',false,'new_payment',false);
 elsif a='MEDICAL_ACTUAL' then
  if r.status<>'REQUESTED' or v_review is distinct from 'MEDICAL' or r.option_id is null or r.qty<>1 or length(v_reason) not between 1 and 300 then raise exception 'Not an eligible reported medical expense';end if;
  v_mode:=p->>'mode';v_amt:=nullif(p->>'amount','')::numeric;v_ref:=btrim(coalesce(p->>'ref',''));
  if coalesce(v_mode,'') not in ('DEDUCT','COMPANY','WORKER_CASH') or v_amt is null or v_amt<=0 or v_amt>5000 or v_amt<>round(v_amt,2) or v_date<v_today-120 or length(v_ref) not between 1 and 80 then raise exception 'Enter actual medical amount, receipt reference and fee handling';end if;
  if exists(select 1 from public.salary_personal s where s.worker_id=r.worker_id and s.voided_at is null and s.data->>'date'=v_date::text and s.data->>'amount' ~ '^[0-9]+([.][0-9]+)?$' and (s.data->>'amount')::numeric=v_amt) then raise exception 'Matching salary amount/date exists — reconcile original deduction first';end if;
  if v_mode='DEDUCT' and not coalesce((p->>'deduction_authorised')::boolean,false) then raise exception 'Confirm lawful deduction authorisation';end if;
  if v_mode in ('DEDUCT','COMPANY') then
   if exists(select 1 from owner_data.shop_payment x where x.voided_at is null and x.purpose='MEDICAL' and x.ref=v_ref and x.amount=v_amt and x.paid_on=v_date) then raise exception 'Medical payment reference already recorded — reconcile first';end if;
   v_pay:=owner_data.shop_pay_new(p->>'payer',v_amt,'MEDICAL',v_label,v_date,v_ref,v_op);
  end if;
  insert into owner_data.shop_wh_review_resolution(request_id,mode,reason,created_by) values(r.id,case when v_mode='COMPANY' then 'COMPANY' else 'MEDICAL_NEW' end,v_reason,v_actor);
  if v_mode='COMPANY' then
   insert into owner_data.farm_cost(farm_code,option_id,item,qty,unit_price,amount,buy_date,request_id,created_by) values(r.farm_code,r.option_id,v_label,1,v_amt,v_amt,v_date,r.id,v_actor) returning id into v_cost;
   update owner_data.shop_request set status='CONFIRMED',decided_at=now(),handed_at=now(),handed_by=v_actor,bought_at=now(),bought_by=v_actor,buy_price=v_amt,pay_id=v_pay,cost_id=v_cost,buy=jsonb_build_object('price',v_amt,'paid_by',owner_data.shop_payer(p->>'payer'),'date',v_date) where id=r.id;
   v_result:=jsonb_build_object('cost_id',v_cost,'pay_id',v_pay,'new_salary',false);
  else
   update owner_data.shop_request set status='BOUGHT',bought_at=now(),bought_by=v_actor,buy_price=v_amt,sell_price=v_amt,pay_id=v_pay,buy=jsonb_build_object('price',v_amt,'paid_by',case when v_mode='WORKER_CASH' then 'WORKER' else owner_data.shop_payer(p->>'payer') end,'date',v_date) where id=r.id;
   v_result:=public.shop_owner_hand(jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('id',r.id,'sell',v_amt,'worker_paid',v_mode='WORKER_CASH')),'date',v_date));
   select e.personal_id into v_pid from owner_data.shop_request x join owner_data.shop_entry e on e.id=x.entry_id where x.id=r.id;
   if v_pid is not null then update owner_data.shop_wh_review_resolution set salary_id=v_pid where request_id=r.id;end if;
  end if;
 elsif a='CANCEL_REVIEW' then
  if r.status<>'REQUESTED' or coalesce(v_review,'') not in ('WORKER','MEDICAL','INSTALMENT','CATALOG') or length(v_reason) not between 1 and 300 or exists(select 1 from owner_data.shop_wh_order x where x.request_id=r.id) then raise exception 'Only verified unfulfilled special requests can be cancelled';end if;
  if ph.stage in ('BOUGHT','DELIVERED') then raise exception 'Reconcile actual phone purchase before cancelling';end if;
  update owner_data.shop_wh_phone set stage='CANCELLED',updated_by=v_actor,updated_at=now() where request_id=r.id;
  update owner_data.shop_request set status='REJECTED',decided_at=now(),note=left(v_reason,200) where id=r.id;
 elsif a='PHONE_QUOTE' then
  if v_review is distinct from 'INSTALMENT' or r.status<>'REQUESTED' or r.qty<>1 or ph.stage in ('BOUGHT','DELIVERED') then raise exception 'Phone not eligible for a quote';end if;
  v_amt:=nullif(p->>'quote_price','')::numeric;v_ref:=btrim(coalesce(p->>'ref',''));
  if v_amt is null or v_amt<=0 or v_amt>50000 or v_amt<>round(v_amt,2) or length(btrim(coalesce(p->>'model',''))) not between 1 and 100 or length(btrim(coalesce(p->>'supplier',''))) not between 1 and 100 or length(v_ref) not between 1 and 100 then raise exception 'Enter verified supplier quote, model and reference';end if;
  insert into owner_data.shop_wh_phone(request_id,stage,model,supplier,quoted_on,quote_price,quote_ref,created_by,updated_by) values(r.id,'QUOTED',btrim(p->>'model'),btrim(p->>'supplier'),v_date,v_amt,v_ref,v_actor,v_actor)
  on conflict(request_id) do update set stage='QUOTED',model=excluded.model,supplier=excluded.supplier,quoted_on=excluded.quoted_on,quote_price=excluded.quote_price,quote_ref=excluded.quote_ref,agreed_sell=null,deposit=null,monthly=null,combined_monthly=null,start_month=null,prior_plan_id=null,prior_monthly=null,replace_plan=false,agreement=null,approved_by=null,approved_at=null,updated_by=v_actor,updated_at=now();
 elsif a='PHONE_APPROVE' then
  if v_review is distinct from 'INSTALMENT' or r.status<>'REQUESTED' or coalesce(ph.stage,'') not in ('QUOTED','APPROVED') then raise exception 'Record an actual quote first';end if;
  v_sell:=nullif(p->>'sell','')::numeric;v_dep:=nullif(p->>'deposit','')::numeric;v_monthly:=nullif(p->>'monthly','')::numeric;v_combined:=nullif(p->>'combined_monthly','')::numeric;v_start:=p->>'start_month';v_replace:=coalesce((p->>'replace_plan')::boolean,false);
  if v_sell is null or v_sell<=0 or v_sell>50000 or v_sell<>round(v_sell,2) or v_dep is null or v_dep<0 or v_dep>=v_sell or v_dep<>round(v_dep,2) or v_monthly is null or v_monthly<=0 or v_monthly>v_sell-v_dep or v_monthly<>round(v_monthly,2) or v_combined is null or v_combined<v_monthly or v_combined>50000 or v_combined<>round(v_combined,2) or v_start is null or v_start!~'^[0-9]{4}-(0[1-9]|1[0-2])$' or v_start<to_char(v_today,'YYYY-MM') or public.salary_month_locked(v_start) or length(v_reason) not between 1 and 300 or not coalesce((p->>'deduction_authorised')::boolean,false) then raise exception 'Confirm actual instalment agreement and open Salary start month';end if;
  select * into plan from public.salary_loan_plan where worker_id=r.worker_id and voided_at is null and effective_from<=v_start order by effective_from desc limit 1;
  if plan.id is not null and plan.monthly_pay<>v_combined and not v_replace then raise exception 'Explicit approval needed to change existing combined monthly loan payment';end if;
  if exists(select 1 from public.salary_loan_plan x where x.worker_id=r.worker_id and x.voided_at is null and x.effective_from>v_start and x.monthly_pay<>v_combined) then raise exception 'A future Salary plan conflicts — reconcile it in Salary first';end if;
  update owner_data.shop_wh_phone set stage='APPROVED',agreed_sell=v_sell,deposit=v_dep,monthly=v_monthly,combined_monthly=v_combined,start_month=v_start,prior_plan_id=plan.id,prior_monthly=plan.monthly_pay,replace_plan=v_replace,agreement=v_reason,approved_by=v_actor,approved_at=now(),updated_by=v_actor,updated_at=now() where request_id=r.id;
 elsif a='PHONE_BUY' then
  if v_review is distinct from 'INSTALMENT' or r.status<>'REQUESTED' or ph.stage is distinct from 'APPROVED' then raise exception 'Approve instalment terms before buying';end if;
  v_amt:=nullif(p->>'amount','')::numeric;v_ref:=btrim(coalesce(p->>'ref',''));
  if v_amt is null or v_amt<=0 or v_amt>50000 or v_amt<>round(v_amt,2) or v_date<ph.quoted_on or length(v_ref) not between 1 and 80 then raise exception 'Enter actual purchase cost, date and payment reference';end if;
  if exists(select 1 from owner_data.shop_payment x where x.voided_at is null and x.ref=v_ref and x.amount=v_amt and x.paid_on=v_date) then raise exception 'Matching actual payment already recorded — reconcile first';end if;
  v_pay:=owner_data.shop_pay_new(p->>'payer',v_amt,'PURCHASE',ph.model,v_date,v_ref,v_op);
  update owner_data.shop_wh_phone set stage='BOUGHT',actual_buy=v_amt,bought_on=v_date,payment_id=v_pay,updated_by=v_actor,updated_at=now() where request_id=r.id;
  update owner_data.shop_request set status='BOUGHT',bought_at=now(),bought_by=v_actor,buy_price=v_amt,sell_price=ph.agreed_sell,pay_id=v_pay,buy=jsonb_build_object('price',v_amt,'paid_by',owner_data.shop_payer(p->>'payer'),'date',v_date,'instalment',true) where id=r.id;
 elsif a='PHONE_DELIVER' then
  if v_review is distinct from 'INSTALMENT' or r.status<>'BOUGHT' or ph.stage is distinct from 'BOUGHT' or ph.loan_id is not null or v_date<ph.bought_on or ph.start_month<to_char(v_date,'YYYY-MM') or public.salary_month_locked(ph.start_month) or not coalesce((p->>'deduction_authorised')::boolean,false) or (ph.deposit>0 and not coalesce((p->>'deposit_received')::boolean,false)) then raise exception 'Verify actual delivery, deposit, agreed Salary start month and lawful authorisation';end if;
  select * into plan from public.salary_loan_plan where worker_id=r.worker_id and voided_at is null and effective_from<=ph.start_month order by effective_from desc limit 1 for update;
  if plan.id is distinct from ph.prior_plan_id or plan.monthly_pay is distinct from ph.prior_monthly then raise exception 'Existing Salary plan changed — reconcile agreement before delivery';end if;
  if exists(select 1 from public.salary_loan_plan x where x.worker_id=r.worker_id and x.voided_at is null and x.effective_from>ph.start_month and x.monthly_pay<>ph.combined_monthly) then raise exception 'Future Salary plan conflicts';end if;
  v_principal:=ph.agreed_sell-ph.deposit;
  if plan.id is not null and plan.monthly_pay=ph.combined_monthly then v_plan:=plan.id;
  else
   if plan.id is not null and not ph.replace_plan then raise exception 'Combined repayment change not approved';end if;
   select * into sameplan from public.salary_loan_plan where worker_id=r.worker_id and effective_from=ph.start_month and voided_at is null for update;
   if sameplan.id is not null then update public.salary_loan_plan set voided_at=now(),void_reason='Approved phone instalment combined repayment; previous plan preserved' where id=sameplan.id;end if;
   insert into public.salary_loan_plan(worker_id,effective_from,monthly_pay,created_by) values(r.worker_id,ph.start_month,ph.combined_monthly,v_actor) returning id into v_plan;
  end if;
  -- The loan becomes eligible in the explicitly agreed Salary month; actual handover date is retained in txn_date.
  insert into public.salary_loan_txn(worker_id,month,txn_date,kind,amount,note,created_by) values(r.worker_id,ph.start_month,v_date,'LOAN',v_principal,'Phone instalment · '||ph.model||' · request '||r.id::text,v_actor) returning id into v_loan;
  v_opt:=r.option_id;
  if v_opt is null then v_opt:=public.shop_owner_item_add(jsonb_build_object('label','HANDPHONE','kind','PERSONAL'));end if;
  insert into owner_data.shop_entry(client_id,device_id,farm_code,worker_id,option_id,item,buy_date,qty,unit_price,default_price,amount,personal_id)
   values(r.client_id,r.device_id,r.farm_code,r.worker_id,v_opt,'HANDPHONE (instalment) · '||ph.model,v_date,1,ph.agreed_sell,ph.actual_buy,ph.agreed_sell,null) returning id into v_entry;
  insert into owner_data.shop_wh_review_resolution(request_id,mode,reason,loan_id,created_by) values(r.id,'INSTALMENT',ph.agreement,v_loan,v_actor);
  update owner_data.shop_request set status='CONFIRMED',option_id=v_opt,decided_at=now(),handed_at=now(),handed_by=v_actor,entry_id=v_entry where id=r.id;
  update owner_data.shop_wh_phone set stage='DELIVERED',delivered_on=v_date,loan_id=v_loan,plan_id=v_plan,updated_by=v_actor,updated_at=now() where request_id=r.id;
  v_result:=jsonb_build_object('loan_id',v_loan,'principal',v_principal,'plan_id',v_plan,'entry_id',v_entry);
 else raise exception 'Unknown special action';end if;
 perform set_config('owner_data.wh_internal','0',true);
 v_result:=jsonb_build_object('ok',true,'op_id',v_op)||v_result;
 insert into owner_data.shop_wh_op(id,actor,payload,result) values(v_op,v_actor,p,v_result);
 return v_result;
end $function$;

CREATE OR REPLACE FUNCTION owner_data.shop_wh_allocate(p_option uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare rr record; bb record; v_left int; v_take int; v_n int:=0; v_available int; gg record; member record; v_rep uuid; v_cents bigint; v_idx int; v_batch uuid; v_full numeric;
begin
 for rr in select r.id,r.option_id,r.qty,r.detail from owner_data.shop_request r join owner_data.shop_wh_policy pol on pol.option_id=r.option_id and pol.stock_managed and pol.opening_confirmed
 where r.status='REQUESTED' and r.kind<>'FOOD' and r.bottle_id is null and not exists(select 1 from public.hub_option o where o.id=r.option_id and o.code='WHISKEY') and owner_data.shop_wh_review(r) is null and (p_option is null or r.option_id=p_option) and owner_data.shop_photo_count(r.id)=0 and (not owner_data.shop_wh_spec_required(r.option_id) or owner_data.shop_wh_spec(r.detail)<>'')
 and not exists(select 1 from owner_data.shop_wh_order o where o.request_id=r.id and o.received_qty+o.cancelled_qty<o.qty)
 order by owner_data.shop_ask(r),r.created_at,r.id for update of r loop
 v_left:=rr.qty;
 for bb in select b.id from owner_data.shop_wh_batch b where b.option_id=rr.option_id and owner_data.shop_wh_spec(b.stock_spec)=owner_data.shop_wh_spec(rr.detail) and b.on_hand>0 order by b.received_on,b.created_at,b.id for update loop
  select b.on_hand-coalesce((select sum(a.qty) from owner_data.shop_wh_alloc a where a.batch_id=b.id and a.status='READY'),0) into v_available from owner_data.shop_wh_batch b where b.id=bb.id;
  v_take:=least(v_left,v_available);
  if v_take>0 then perform owner_data.shop_wh_reserve(rr.id,bb.id,v_take);v_left:=v_left-v_take;v_n:=v_n+v_take;end if;
  exit when v_left=0;
 end loop;
 end loop;
 -- A shared bottle is a single physical unit. Only the representative owns the allocation.
 for gg in select r.bottle_id,min(r.option_id::text)::uuid option_id,min(r.farm_code) farm, min(owner_data.shop_wh_spec(r.detail)) spec,min(owner_data.shop_ask(r)) asked,min(r.created_at) created
 from owner_data.shop_request r join public.hub_option o on o.id=r.option_id and o.code='WHISKEY'
 join owner_data.shop_wh_policy pol on pol.option_id=r.option_id and pol.stock_managed and pol.opening_confirmed
 where r.status='REQUESTED' and r.bottle_id is not null and (p_option is null or r.option_id=p_option)
 group by r.bottle_id order by asked,created,r.bottle_id loop
  perform 1 from owner_data.shop_request x where x.bottle_id=gg.bottle_id order by x.id for update;
  if exists(select 1 from owner_data.shop_request x where x.bottle_id=gg.bottle_id and (x.status<>'REQUESTED' or x.kind<>'PERSONAL' or x.qty<>1 or x.option_id is distinct from gg.option_id or x.farm_code is distinct from gg.farm or owner_data.shop_wh_spec(x.detail)<>gg.spec or owner_data.shop_wh_review(x) is not null or owner_data.shop_photo_count(x.id)>0 or x.bottle_n<>(select count(*) from owner_data.shop_request y where y.bottle_id=gg.bottle_id))) then continue;end if;
  if (select count(distinct worker_id) from owner_data.shop_request x where x.bottle_id=gg.bottle_id) not between 1 and 3 or (select count(distinct worker_id) from owner_data.shop_request x where x.bottle_id=gg.bottle_id)<>(select count(*) from owner_data.shop_request x where x.bottle_id=gg.bottle_id) then continue;end if;
  select b.id,b.unit_cost into v_batch,v_full from owner_data.shop_wh_batch b where b.option_id=gg.option_id and owner_data.shop_wh_spec(b.stock_spec)=gg.spec and b.on_hand>coalesce((select sum(z.qty) from owner_data.shop_wh_alloc z where z.batch_id=b.id and z.status='READY'),0) order by b.received_on,b.created_at,b.id limit 1 for update;
  if v_batch is null then continue;end if;
  select x.id into v_rep from owner_data.shop_request x where x.bottle_id=gg.bottle_id order by x.id limit 1;
  v_idx:=0;v_cents:=round(v_full*100)::bigint;
  insert into owner_data.shop_wh_alloc(request_id,batch_id,qty,fixed_sell) select v_rep,v_batch,1,owner_data.shop_whiskey_rate(x.bottle_n) from owner_data.shop_request x where x.id=v_rep;
  for member in select x.id,x.bottle_n from owner_data.shop_request x where x.bottle_id=gg.bottle_id order by x.id loop
   v_idx:=v_idx+1;
   update owner_data.shop_request set status='BOUGHT',bought_at=now(),bought_by=auth.uid(),pay_id=null,
    buy_price=((v_cents/member.bottle_n)+case when v_idx<=v_cents%member.bottle_n then 1 else 0 end)::numeric/100,
    sell_price=owner_data.shop_whiskey_rate(member.bottle_n),wh_fixed_sell=owner_data.shop_whiskey_rate(member.bottle_n),
    buy=jsonb_build_object('price',((v_cents/member.bottle_n)+case when v_idx<=v_cents%member.bottle_n then 1 else 0 end)::numeric/100,'date',(select received_on from owner_data.shop_wh_batch where id=v_batch),'warehouse',true,'warehouse_bottle',true,'batch_id',v_batch,'allocation_id',v_rep,'bottle_price',v_full)
   where id=member.id;
  end loop;
  v_n:=v_n+1;
 end loop;
 return v_n;
end $function$;

CREATE OR REPLACE FUNCTION owner_data.shop_wh_reserve(p_request uuid, p_batch uuid, p_qty integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare r owner_data.shop_request; b owner_data.shop_wh_batch; pol owner_data.shop_wh_policy; v_id uuid; v_reserved int; v_sell numeric;
begin
 select * into r from owner_data.shop_request where id=p_request for update;
 if r.id is null or r.status<>'REQUESTED' or owner_data.shop_wh_review(r) is not null then raise exception 'Request not eligible for reservation'; end if;
 select * into b from owner_data.shop_wh_batch where id=p_batch for update;
 select * into pol from owner_data.shop_wh_policy where option_id=r.option_id;
 if b.id is null or b.option_id is distinct from r.option_id or not coalesce(pol.stock_managed,false) or not pol.opening_confirmed then raise exception 'Wrong stock batch or opening stock not confirmed'; end if;
 if owner_data.shop_photo_count(r.id)>0 or owner_data.shop_wh_spec(b.stock_spec)<>owner_data.shop_wh_spec(r.detail) or (owner_data.shop_wh_spec_required(r.option_id) and owner_data.shop_wh_spec(r.detail)='') then raise exception 'Stock specification or photo requires exact verification';end if;
 select coalesce(sum(qty),0) into v_reserved from owner_data.shop_wh_alloc where batch_id=b.id and status='READY';
 if p_qty<1 or p_qty>b.on_hand-v_reserved then raise exception 'Insufficient available stock'; end if;
 v_id:=owner_data.shop_wh_split(r.id,p_qty);
 v_sell:=case when r.kind='PERSONAL' and pol.price_mode='FIXED' then pol.fixed_sell end;
 insert into owner_data.shop_wh_alloc(request_id,batch_id,qty,fixed_sell) values(v_id,b.id,p_qty,v_sell);
 update owner_data.shop_request set status='BOUGHT',buy_price=b.unit_cost,sell_price=v_sell,bought_at=now(),bought_by=auth.uid(),buy=jsonb_build_object('price',b.unit_cost,'date',b.received_on,'warehouse',true,'batch_id',b.id),pay_id=null where id=v_id;
 return v_id;
end $function$;

CREATE OR REPLACE FUNCTION owner_data.shop_wh_spec(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$ select lower(btrim(regexp_replace(coalesce(p,''),'\s+',' ','g'))) $function$;

CREATE OR REPLACE FUNCTION owner_data.shop_wh_spec_required(p_item uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
select coalesce((select upper(code) ~ '^(BAJU|SHIRT|PANTS|BOOTS|KASUT|SHOES|SHOE)( |$|[-_])' from public.hub_option where id=p_item),false)
$function$;