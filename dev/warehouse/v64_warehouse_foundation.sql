
create table owner_data.shop_wh_policy (
 option_id uuid primary key references public.hub_option(id),
 stock_managed boolean not null default false,
 price_mode text not null check(price_mode in ('FIXED','VARIABLE')),
 fixed_sell numeric(10,2) check(fixed_sell>0 and fixed_sell<=5000),
 minimum_qty integer check(minimum_qty>=0),
 pack_qty integer check(pack_qty>0),
 updated_at timestamptz not null default now(),
 updated_by uuid not null,
 check((price_mode='FIXED')=(fixed_sell is not null))
);
create table owner_data.shop_wh_root (
 request_id uuid primary key references owner_data.shop_request(id),
 original_qty integer not null check(original_qty>0),
 created_at timestamptz not null default now()
);
create table owner_data.shop_wh_part (
 request_id uuid primary key references owner_data.shop_request(id),
 root_id uuid not null references owner_data.shop_wh_root(request_id),
 created_at timestamptz not null default now()
);
create table owner_data.shop_wh_order (
 id uuid primary key default gen_random_uuid(),
 option_id uuid references public.hub_option(id),
 request_id uuid references owner_data.shop_request(id),
 item text not null,
 supplier text not null check(length(trim(supplier)) between 1 and 100),
 ordered_on date not null,
 qty integer not null check(qty between 1 and 99999),
 received_qty integer not null default 0 check(received_qty>=0),
 cancelled_qty integer not null default 0 check(cancelled_qty>=0),
 ref text,
 created_by uuid not null,
 created_at timestamptz not null default now(),
 check(received_qty+cancelled_qty<=qty),
 check(request_id is not null or option_id is not null)
);
create unique index shop_wh_order_open_request on owner_data.shop_wh_order(request_id) where request_id is not null and received_qty+cancelled_qty<qty;
create table owner_data.shop_wh_batch (
 id uuid primary key default gen_random_uuid(),
 option_id uuid not null references public.hub_option(id),
 order_id uuid references owner_data.shop_wh_order(id),
 received_on date not null,
 original_qty integer not null check(original_qty>0),
 on_hand integer not null check(on_hand>=0 and on_hand<=original_qty),
 unit_cost numeric(10,2) not null check(unit_cost>0 and unit_cost<=5000),
 source text not null check(source in ('OPENING','RECEIPT','ADJUST_UP')),
 ref text,
 created_by uuid not null,
 created_at timestamptz not null default now()
);
create index shop_wh_batch_fifo on owner_data.shop_wh_batch(option_id,received_on,created_at,id);
create table owner_data.shop_wh_alloc (
 request_id uuid primary key references owner_data.shop_request(id),
 batch_id uuid not null references owner_data.shop_wh_batch(id),
 qty integer not null check(qty>0),
 status text not null default 'READY' check(status in ('READY','ISSUED','RELEASED')),
 fixed_sell numeric(10,2),
 created_at timestamptz not null default now(),
 issued_at timestamptz
);
create index shop_wh_alloc_batch on owner_data.shop_wh_alloc(batch_id,status);
create table owner_data.shop_wh_receipt (
 id uuid primary key default gen_random_uuid(),
 order_id uuid not null references owner_data.shop_wh_order(id),
 request_id uuid references owner_data.shop_request(id),
 batch_id uuid references owner_data.shop_wh_batch(id),
 received_on date not null,
 qty integer not null check(qty>0),
 unit_cost numeric(10,2) not null check(unit_cost>0 and unit_cost<=5000),
 sell_price numeric(10,2),
 created_by uuid not null,
 created_at timestamptz not null default now(),
 check(request_id is not null or batch_id is not null)
);
create table owner_data.shop_wh_pay (
 payment_id uuid primary key references owner_data.shop_payment(id),
 order_id uuid not null references owner_data.shop_wh_order(id),
 ref text not null check(length(trim(ref)) between 1 and 80),
 unique(order_id,ref)
);
create table owner_data.shop_wh_adjust (
 id uuid primary key default gen_random_uuid(),
 batch_id uuid not null references owner_data.shop_wh_batch(id),
 delta integer not null check(delta<>0),
 reason text not null check(length(trim(reason)) between 1 and 300),
 actual_on date not null,
 created_by uuid not null,
 created_at timestamptz not null default now()
);
create table owner_data.shop_wh_op (
 id uuid primary key,
 actor uuid not null,
 payload jsonb not null,
 result jsonb not null,
 created_at timestamptz not null default now()
);
do $ddl$ declare t text; begin
 foreach t in array array['shop_wh_policy','shop_wh_root','shop_wh_part','shop_wh_order','shop_wh_batch','shop_wh_alloc','shop_wh_receipt','shop_wh_pay','shop_wh_adjust','shop_wh_op'] loop
 execute format('alter table owner_data.%I enable row level security',t);
 execute format('revoke all on owner_data.%I from public, anon, authenticated',t);
 end loop;
end $ddl$;

create function owner_data.shop_wh_review(r owner_data.shop_request)
returns text language sql stable set search_path='' as $f$
select case when r.kind<>'PERSONAL' then null
 when not exists(select 1 from public.hub_worker w where w.id=r.worker_id and w.voided_at is null and (w.stop_date is null or w.stop_date>(now() at time zone 'Asia/Kuala_Lumpur')::date) and owner_data.shop_worker_farm(w.id)=r.farm_code) then 'WORKER'
 when upper(coalesce((select o.code from public.hub_option o where o.id=r.option_id),r.custom_name,'')) in ('HANDPHONE','PHONE','MOBILE PHONE','SMARTPHONE') and coalesce(r.detail,'')~*'分期|installment|instalment' then 'INSTALMENT'
 when upper(coalesce((select o.code from public.hub_option o where o.id=r.option_id),r.custom_name,'')) in ('UBAT','DOCTOR') and coalesce(r.detail,'')~*'带去看|买了送去|已送药|已看诊|already (delivered|paid|treated)' then 'MEDICAL'
 when r.option_id is null then 'CATALOG' else null end
$f$;
create function owner_data.shop_wh_guard() returns trigger language plpgsql set search_path='' as $f$
declare v_internal boolean:=coalesce(current_setting('owner_data.wh_internal',true),'')='1'; a owner_data.shop_wh_alloc; v_fixed numeric;
begin
 if tg_op='DELETE' then
  if exists(select 1 from owner_data.shop_wh_root where request_id=old.id) or exists(select 1 from owner_data.shop_wh_part where request_id=old.id) or exists(select 1 from owner_data.shop_wh_order where request_id=old.id) or exists(select 1 from owner_data.shop_wh_alloc where request_id=old.id) then raise exception 'Warehouse history cannot be deleted'; end if;
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
 if old.status='BOUGHT' and new.status='CONFIRMED' then
  if owner_data.shop_wh_review(old) is not null then raise exception 'Resolve the request review first'; end if;
  select * into a from owner_data.shop_wh_alloc where request_id=old.id for update;
  if a.request_id is not null then
   if a.status<>'READY' or a.qty<>old.qty then raise exception 'Invalid stock allocation'; end if;
   if a.fixed_sell is not null and new.sell_price is distinct from a.fixed_sell then raise exception 'Fixed selling price cannot change'; end if;
   update owner_data.shop_wh_batch set on_hand=on_hand-a.qty where id=a.batch_id and on_hand>=a.qty;
   if not found then raise exception 'Insufficient stock — refresh'; end if;
   update owner_data.shop_wh_alloc set status='ISSUED',issued_at=now() where request_id=old.id;
  end if;
  if old.kind='PERSONAL' and exists(select 1 from owner_data.shop_wh_receipt rr where rr.request_id=old.id) and exists(select 1 from owner_data.shop_wh_policy w where w.option_id=old.option_id and w.price_mode='FIXED') and new.sell_price is distinct from old.sell_price then raise exception 'Fixed selling price cannot change'; end if;
 end if;
 return new;
end $f$;
create trigger shop_wh_request_guard before update or delete on owner_data.shop_request for each row execute function owner_data.shop_wh_guard();

create function owner_data.shop_wh_split(p_request uuid,p_qty int) returns uuid language plpgsql set search_path='' as $f$
declare r owner_data.shop_request; v_root uuid; v_id uuid;
begin
 select * into r from owner_data.shop_request where id=p_request for update;
 if r.id is null or r.status<>'REQUESTED' or p_qty<1 or p_qty>r.qty or r.bottle_id is not null or r.kind='FOOD' then raise exception 'Invalid request quantity'; end if;
 if p_qty=r.qty then return r.id; end if;
 select root_id into v_root from owner_data.shop_wh_part where request_id=r.id;
 v_root:=coalesce(v_root,r.id);
 insert into owner_data.shop_wh_root(request_id,original_qty) values(v_root,r.qty) on conflict do nothing;
 insert into owner_data.shop_wh_part(request_id,root_id) values(r.id,v_root) on conflict do nothing;
 update owner_data.shop_request set qty=qty-p_qty where id=r.id;
 insert into owner_data.shop_request(client_id,device_id,farm_code,worker_id,option_id,custom_name,qty,est_price,status,created_at,note,kind,made_by,trip,detail,ask_date)
 values(gen_random_uuid(),r.device_id,r.farm_code,r.worker_id,r.option_id,r.custom_name,p_qty,r.est_price,'REQUESTED',r.created_at,r.note,r.kind,r.made_by,r.trip,r.detail,owner_data.shop_ask(r)) returning id into v_id;
 insert into owner_data.shop_wh_part(request_id,root_id) values(v_id,v_root);
 return v_id;
end $f$;
create function owner_data.shop_wh_reserve(p_request uuid,p_batch uuid,p_qty int) returns uuid language plpgsql set search_path='' as $f$
declare r owner_data.shop_request; b owner_data.shop_wh_batch; pol owner_data.shop_wh_policy; v_id uuid; v_reserved int; v_sell numeric;
begin
 select * into r from owner_data.shop_request where id=p_request for update;
 if r.id is null or r.status<>'REQUESTED' or owner_data.shop_wh_review(r) is not null then raise exception 'Request not eligible for reservation'; end if;
 select * into b from owner_data.shop_wh_batch where id=p_batch for update;
 select * into pol from owner_data.shop_wh_policy where option_id=r.option_id;
 if b.id is null or b.option_id is distinct from r.option_id or not coalesce(pol.stock_managed,false) then raise exception 'Wrong stock batch'; end if;
 select coalesce(sum(qty),0) into v_reserved from owner_data.shop_wh_alloc where batch_id=b.id and status='READY';
 if p_qty<1 or p_qty>b.on_hand-v_reserved then raise exception 'Insufficient available stock'; end if;
 v_id:=owner_data.shop_wh_split(r.id,p_qty);
 v_sell:=case when r.kind='PERSONAL' and pol.price_mode='FIXED' then pol.fixed_sell end;
 insert into owner_data.shop_wh_alloc(request_id,batch_id,qty,fixed_sell) values(v_id,b.id,p_qty,v_sell);
 update owner_data.shop_request set status='BOUGHT',buy_price=b.unit_cost,sell_price=v_sell,bought_at=now(),bought_by=auth.uid(),buy=jsonb_build_object('price',b.unit_cost,'date',b.received_on,'warehouse',true,'batch_id',b.id),pay_id=null where id=v_id;
 return v_id;
end $f$;
create function owner_data.shop_wh_allocate(p_option uuid default null) returns int language plpgsql set search_path='' as $f$
declare rr record; bb record; v_left int; v_take int; v_n int:=0; v_available int;
begin
 for rr in select r.id,r.option_id,r.qty from owner_data.shop_request r join owner_data.shop_wh_policy pol on pol.option_id=r.option_id and pol.stock_managed
 where r.status='REQUESTED' and r.kind<>'FOOD' and r.bottle_id is null and owner_data.shop_wh_review(r) is null and (p_option is null or r.option_id=p_option)
 and not exists(select 1 from owner_data.shop_wh_order o where o.request_id=r.id and o.received_qty+o.cancelled_qty<o.qty)
 order by owner_data.shop_ask(r),r.created_at,r.id for update of r loop
 v_left:=rr.qty;
 for bb in select b.id from owner_data.shop_wh_batch b where b.option_id=rr.option_id and b.on_hand>0 order by b.received_on,b.created_at,b.id for update loop
  select b.on_hand-coalesce((select sum(a.qty) from owner_data.shop_wh_alloc a where a.batch_id=b.id and a.status='READY'),0) into v_available from owner_data.shop_wh_batch b where b.id=bb.id;
  v_take:=least(v_left,v_available);
  if v_take>0 then perform owner_data.shop_wh_reserve(rr.id,bb.id,v_take);v_left:=v_left-v_take;v_n:=v_n+v_take;end if;
  exit when v_left=0;
 end loop;
 end loop;
 return v_n;
end $f$;

create function owner_data.shop_wh_void_guard() returns trigger language plpgsql set search_path='' as $f$
begin
 if new.voided_at is not null and old.voided_at is null and exists(
 select 1 from owner_data.shop_request r where
 (case tg_table_name when 'shop_entry' then r.entry_id when 'shop_share' then r.share_id else r.cost_id end)=old.id
 and (exists(select 1 from owner_data.shop_wh_alloc a where a.request_id=r.id) or exists(select 1 from owner_data.shop_wh_receipt x where x.request_id=r.id))) then
 raise exception 'Warehouse-linked delivery requires audited reconciliation';
 end if;
 return new;
end $f$;
create trigger shop_wh_entry_void_guard before update of voided_at on owner_data.shop_entry for each row execute function owner_data.shop_wh_void_guard();
create trigger shop_wh_share_void_guard before update of voided_at on owner_data.shop_share for each row execute function owner_data.shop_wh_void_guard();
create trigger shop_wh_cost_void_guard before update of voided_at on owner_data.farm_cost for each row execute function owner_data.shop_wh_void_guard();

revoke all on function owner_data.shop_wh_review(owner_data.shop_request),owner_data.shop_wh_guard(),owner_data.shop_wh_split(uuid,int),owner_data.shop_wh_reserve(uuid,uuid,int),owner_data.shop_wh_allocate(uuid),owner_data.shop_wh_void_guard() from public,anon,authenticated;
