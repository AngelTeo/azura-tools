
create function owner_data.shop_month_workers(m text) returns table(worker_id uuid,worker_name text,farm text,stopped boolean) language sql stable set search_path='' as $f$
select w.id,w.name,coalesce(f.code,(select e.farm_code from owner_data.shop_entry e where e.worker_id=w.id and to_char(e.buy_date,'YYYY-MM')=m and e.voided_at is null order by e.buy_date desc,e.created_at desc limit 1),'AD'),coalesce(w.stop_date<=(now() at time zone 'Asia/Kuala_Lumpur')::date,false)
from public.hub_worker w
left join lateral(select h.code from public.hub_worker_farm a join public.hub_farm h on h.id=a.farm_id where a.worker_id=w.id and a.voided_at is null and a.effective_from<=m order by a.effective_from desc,a.created_at desc limit 1) f on true
where w.voided_at is null and (
(f.code in ('AD 1','AD 2','AD 3') and (w.join_date is null or to_char(w.join_date,'YYYY-MM')<=m) and (w.stop_date is null or to_char(w.stop_date,'YYYY-MM')>=m))
or exists(select 1 from owner_data.shop_entry e where e.worker_id=w.id and e.farm_code in ('AD 1','AD 2','AD 3') and e.voided_at is null and (to_char(e.buy_date,'YYYY-MM')=m or exists(select 1 from public.salary_personal s where s.id=e.personal_id and s.month=m and s.voided_at is null)))
or exists(select 1 from owner_data.shop_request r where r.worker_id=w.id and r.farm_code in ('AD 1','AD 2','AD 3') and r.status in ('REQUESTED','BOUGHT','CONFIRMED') and to_char(owner_data.shop_ask(r),'YYYY-MM')=m))
$f$;
revoke all on function owner_data.shop_month_workers(text) from public,anon,authenticated;
create function owner_data.shop_month_food_ids(m text,d jsonb) returns uuid[] language sql stable set search_path='' as $f$
with dates as (select (m||'-01')::date lo,((m||'-01')::date+interval '1 month' - interval '1 day')::date hi,nullif(d->>'date','')::date dt),
roster as (select w.id,w.join_date,w.stop_date,w.shares_food from public.hub_worker w,dates
where w.voided_at is null and (case when public.salary_month_locked(m) then exists(select 1 from public.salary_payslip s where s.worker_id=w.id and s.month=m and s.voided_at is null) else (w.join_date is null or w.join_date<=dates.hi) and (w.stop_date is null or w.stop_date>=dates.lo) end)),
eligible as (
select r.id from roster r,dates where dates.dt is not null and r.shares_food is not false and (r.join_date is null or r.join_date<=case when extract(day from dates.dt)<=15 then dates.lo+14 else dates.hi end) and (r.stop_date is null or r.stop_date>=case when extract(day from dates.dt)<=15 then dates.lo else dates.lo+15 end)
union select r.id from roster r where d->'addIds' ? r.id::text)
select case when nullif(d->>'date','') is null then coalesce((select array_agg(value::uuid) from jsonb_array_elements_text(coalesce(d->'workerIds','[]'::jsonb))), '{}'::uuid[])
else coalesce((select array_agg(e.id order by e.id) from eligible e where not coalesce(d->'removeIds' ? e.id::text,false)), '{}'::uuid[]) end
$f$;
revoke all on function owner_data.shop_month_food_ids(text,jsonb) from public,anon,authenticated;
create function public.shop_owner_month_card(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $f$
declare m text:=p->>'month'; wid uuid:=nullif(p->>'worker_id','')::uuid; w record; personal jsonb; cash jsonb; shared jsonb; loans jsonb; pending jsonb; pt numeric; ct numeric; ft numeric; fr numeric; shown numeric; locked boolean; snap jsonb; issues text[]:='{}'; today date:=(now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
if auth.uid() is null or not public.shop_is_manager() then raise exception 'Not allowed';end if;
if m is null or m !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' or m<'2026-11' or m>to_char(today,'YYYY-MM') then raise exception 'Select a month from November 2026 to current month';end if;
locked:=public.salary_month_locked(m);
if wid is null then return jsonb_build_object('month',m,'locked',locked,'today',today,'workers',coalesce((select jsonb_agg(to_jsonb(z) order by z.farm,z.worker_name) from owner_data.shop_month_workers(m) z),'[]'::jsonb));end if;
select * into w from owner_data.shop_month_workers(m) where worker_id=wid;if not found then raise exception 'Worker not in the AD monthly roster';end if;
select coalesce(jsonb_agg(jsonb_build_object('date',s.data->>'date','item',coalesce(nullif(s.data->>'description',''),e.item,'Salary personal expense'),'qty',e.qty,'unit_price',e.unit_price,'amount',(s.data->>'amount')::numeric,'source',case when e.id is null then 'SALARY' else 'KEDAI' end,'detail',r.detail,'receipt_pending',exists(select 1 from owner_data.shop_delivery_ack a where a.request_id=r.id and a.received_qty<a.sent_qty and owner_data.shop_delivery_valid(a.request_id))) order by s.data->>'date',s.id),'[]'::jsonb),coalesce(sum((s.data->>'amount')::numeric),0)
into personal,pt from public.salary_personal s
left join lateral(select e.* from owner_data.shop_entry e where e.personal_id=s.id and e.voided_at is null order by e.created_at,e.id limit 1) e on true
left join lateral(select r.* from owner_data.shop_request r where r.entry_id=e.id and r.worker_id=wid order by r.created_at,r.id limit 1) r on true
where s.worker_id=wid and s.month=m and s.voided_at is null;
select coalesce(jsonb_agg(jsonb_build_object('date',e.buy_date,'item',e.item,'qty',e.qty,'amount',e.amount,'detail',r.detail) order by e.buy_date,e.id),'[]'::jsonb),coalesce(sum(e.amount),0) into cash,ct
from owner_data.shop_entry e join lateral(select r.* from owner_data.shop_request r where r.entry_id=e.id and r.worker_paid and r.status='CONFIRMED' order by r.created_at limit 1) r on true where e.worker_id=wid and e.voided_at is null and e.personal_id is null and to_char(e.buy_date,'YYYY-MM')=m;
with f as(select s.*,owner_data.shop_month_food_ids(m,s.data) ids from public.salary_food s where s.month=m and s.voided_at is null),
mine as(select f.*,(f.data->>'total')::numeric/cardinality(f.ids) share from f where wid=any(f.ids))
select coalesce(jsonb_agg(jsonb_build_object('date',f.data->>'date','item',concat_ws(' · ',nullif(f.data->>'vendor',''),nullif(f.data->>'description','')),'amount',round(f.share,2),'n',cardinality(f.ids),'items',coalesce((select jsonb_agg(jsonb_build_object('item',coalesce(o.label,r.custom_name),'qty',r.qty) order by r.id) from owner_data.shop_share sh join owner_data.shop_request r on r.share_id=sh.id left join public.hub_option o on o.id=r.option_id where sh.food_id=f.id and sh.voided_at is null and r.status='CONFIRMED'),'[]'::jsonb)) order by f.data->>'date',f.id),'[]'::jsonb),coalesce(sum(f.share),0),coalesce(sum(round(f.share,2)),0)
into shared,fr,shown from mine f;
ft:=ceil((round(fr*100000)/1000)/10-0.000001)/10;
if locked then
select data into snap from public.salary_payslip where worker_id=wid and month=m and voided_at is null order by created_at desc limit 1;
if snap is null or not(snap?'persD') or not(snap?'food') then issues:=array_append(issues,'LOCKED_PAYSLIP_MISSING');
elsif abs((snap->>'persD')::numeric-round(pt,2))>0.005 or abs((snap->>'food')::numeric-ft)>0.005 then issues:=array_append(issues,'LOCKED_TOTAL_MISMATCH');end if;
end if;
if exists(select 1 from owner_data.shop_entry e join public.salary_personal s on s.id=e.personal_id where e.worker_id=wid and e.voided_at is null and s.month=m and (s.voided_at is not null or s.worker_id<>wid)) then issues:=array_append(issues,'LINKED_DEDUCTION_CHANGED');end if;
select coalesce(jsonb_agg(jsonb_build_object('date',ph.delivered_on,'item',ph.model,'amount',ph.agreed_sell,'deposit',ph.deposit,'principal',ph.agreed_sell-ph.deposit,'monthly',ph.monthly,'start_month',ph.start_month) order by ph.delivered_on),'[]'::jsonb) into loans
from owner_data.shop_wh_phone ph join owner_data.shop_request r on r.id=ph.request_id join public.salary_loan_txn t on t.id=ph.loan_id and t.voided_at is null where r.worker_id=wid and ph.stage='DELIVERED' and to_char(ph.delivered_on,'YYYY-MM')=m;
select coalesce(jsonb_agg(jsonb_build_object('date',owner_data.shop_ask(r),'item',coalesce(o.label,r.custom_name),'qty',r.qty,'status',r.status,'detail',r.detail,'ordered',exists(select 1 from owner_data.shop_wh_order a where a.request_id=r.id and a.received_qty+a.cancelled_qty<a.qty)) order by owner_data.shop_ask(r),r.created_at),'[]'::jsonb) into pending
from owner_data.shop_request r left join public.hub_option o on o.id=r.option_id where r.worker_id=wid and r.status in ('REQUESTED','BOUGHT') and owner_data.shop_ask(r)<((m||'-01')::date+interval '1 month')::date;
return jsonb_build_object('month',m,'today',today,'locked',locked,'worker',to_jsonb(w),'personal',personal,'cash',cash,'shared',shared,'instalments',loans,'pending',pending,'personal_total',round(pt,2),'cash_total',round(ct,2),'shared_total',ft,'shared_rounding',round(ft-shown,2),'salary_total',round(pt,2)+ft,'locked_personal',snap->'persD','locked_shared',snap->'food','issues',to_jsonb(issues));
end $f$;
revoke all on function public.shop_owner_month_card(jsonb) from public,anon,authenticated;
grant execute on function public.shop_owner_month_card(jsonb) to authenticated,service_role;
notify pgrst,'reload schema';
