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
notify pgrst,'reload schema';