CREATE OR REPLACE FUNCTION owner_data.shop_wh_guard()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_internal boolean:=coalesce(current_setting('owner_data.wh_internal',true),'')='1'; a owner_data.shop_wh_alloc; v_fixed numeric; v_review text;
begin
 if tg_op='DELETE' then
  if coalesce(old.buy->>'warehouse_bottle','')='true' then raise exception 'Whole bottle warehouse history cannot be deleted';end if;
  if exists(select 1 from owner_data.shop_wh_root where request_id=old.id) or exists(select 1 from owner_data.shop_wh_part where request_id=old.id) or exists(select 1 from owner_data.shop_wh_order where request_id=old.id) or exists(select 1 from owner_data.shop_wh_alloc where request_id=old.id) or exists(select 1 from owner_data.shop_wh_review_resolution where request_id=old.id) then raise exception 'Warehouse history cannot be deleted'; end if;
  return old;
 end if;
 if coalesce(old.buy->>'warehouse_bottle','')='true' and (new.status is distinct from old.status or new.qty is distinct from old.qty or new.option_id is distinct from old.option_id or new.kind is distinct from old.kind or new.worker_id is distinct from old.worker_id or new.farm_code is distinct from old.farm_code or new.detail is distinct from old.detail or new.bottle_id is distinct from old.bottle_id or new.buy is distinct from old.buy) and (not v_internal or coalesce(current_setting('owner_data.wh_bottle_issue',true),'')<>old.bottle_id::text) then raise exception 'Use whole-bottle warehouse confirmation or reconciliation';end if;
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

CREATE OR REPLACE FUNCTION owner_data.shop_wh_review(r owner_data.shop_request)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
select case when r.option_id is null and owner_data.shop_photo_count(r.id)>0 then 'PHOTO' when r.kind<>'PERSONAL' then null
 when not exists(select 1 from public.hub_worker w where w.id=r.worker_id and w.voided_at is null and (w.stop_date is null or w.stop_date>(now() at time zone 'Asia/Kuala_Lumpur')::date) and owner_data.shop_worker_farm(w.id)=r.farm_code) then 'WORKER'
 when upper(coalesce((select o.code from public.hub_option o where o.id=r.option_id),r.custom_name,'')) in ('HANDPHONE','PHONE','MOBILE PHONE','SMARTPHONE') and coalesce(r.detail,'')~*'分期|installment|instalment' then 'INSTALMENT'
 when upper(coalesce((select o.code from public.hub_option o where o.id=r.option_id),r.custom_name,'')) in ('UBAT','DOCTOR') and coalesce(r.detail,'')~*'带去看|买了送去|已送药|已看诊|already (delivered|paid|treated)' then 'MEDICAL'
 when r.option_id is null then 'CATALOG' else null end
$function$;

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
      raise exception 'Food expense has no eligible AD employees; check employment before locking';
    end if;
    if exists(
      with charges as (select u.wid, sum((f.data->>'total')::numeric/cardinality(q.ids)) total
        from public.salary_food f cross join lateral (select owner_data.shop_month_food_ids(p_month,f.data) ids) q
        cross join lateral unnest(q.ids) u(wid) where f.month=p_month and f.voided_at is null group by u.wid),
      slips as (select (x->>'worker_id')::uuid wid,(x->'data'->>'food')::numeric food from jsonb_array_elements(p_payslips) x)
      select 1 from charges c full join slips s on s.wid=c.wid
        where s.wid is null or s.food is null or abs(s.food - coalesce(ceil((round(c.total*100000)/1000)/10-0.000001)/10,0))>0.005
    ) then raise exception 'Food allocation mismatch; refresh Salary and review employment before locking'; end if;
    update public.salary_food f set data=f.data || jsonb_build_object('workerIds',to_jsonb(owner_data.shop_month_food_ids(p_month,f.data)),'allocation_rule','HALF_MONTH_EMPLOYMENT_V1','original_workerIds',coalesce(f.data->'original_workerIds',f.data->'workerIds','[]'::jsonb)),updated_at=now()
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

CREATE OR REPLACE FUNCTION public.shop_owner_wh_special_context(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r owner_data.shop_request; v_review text; v_start text:=coalesce(nullif(p->>'start_month',''),to_char((now() at time zone 'Asia/Kuala_Lumpur')::date,'YYYY-MM'));
begin
 if auth.uid() is null or not public.shop_is_manager() then raise exception 'Not allowed';end if;
 select * into r from owner_data.shop_request where id=(p->>'request_id')::uuid;
 if r.id is null or r.kind<>'PERSONAL' then raise exception 'Unknown personal request';end if;
 v_review:=owner_data.shop_wh_review(r);
 if coalesce(v_review,'') not in ('MEDICAL','WORKER','INSTALMENT') and not exists(select 1 from owner_data.shop_wh_phone where request_id=r.id) then raise exception 'Not a special request';end if;
 return jsonb_build_object('review',v_review,
 'salary_candidates',case when v_review in ('MEDICAL','WORKER') then coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'month',s.month,'date',s.data->>'date','description',s.data->>'description','amount',s.data->>'amount','linked',exists(select 1 from owner_data.shop_entry e where e.personal_id=s.id and e.voided_at is null),'resolved',exists(select 1 from owner_data.shop_wh_review_resolution z where z.salary_id=s.id)) order by s.month desc,s.created_at desc) from public.salary_personal s where s.worker_id=r.worker_id and s.voided_at is null and s.month>=to_char((now() at time zone 'Asia/Kuala_Lumpur')::date-120,'YYYY-MM')),'[]'::jsonb) else '[]'::jsonb end,
 'phone', (select to_jsonb(x) from owner_data.shop_wh_phone x where x.request_id=r.id),
 'current_plan',(select jsonb_build_object('id',x.id,'monthly',x.monthly_pay,'from',x.effective_from) from public.salary_loan_plan x where x.worker_id=r.worker_id and x.voided_at is null and x.effective_from<=v_start order by x.effective_from desc limit 1),
 'future_plan_count',(select count(*) from public.salary_loan_plan x where x.worker_id=r.worker_id and x.voided_at is null and x.effective_from>v_start),
 'loan_count',(select count(*) from public.salary_loan_txn x where x.worker_id=r.worker_id and x.voided_at is null and x.kind='LOAN'),
 'start_month',v_start);
end $function$;