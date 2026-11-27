
create table owner_data.shop_delivery_ack (
 request_id uuid primary key references owner_data.shop_request(id),
 farm_code text not null check(farm_code in ('AD 1','AD 2','AD 3')),
 kind text not null check(kind in ('FARM','PERSONAL','SHARED','FOOD')),
 item text not null,
 worker_name text,
 detail text,
 round date,
 sent_qty integer not null check(sent_qty>0),
 received_qty integer not null default 0 check(received_qty>=0 and received_qty<=sent_qty),
 handed_at timestamptz not null,
 last_received_at timestamptz,
 last_note text,
 created_at timestamptz not null default now()
);
create table owner_data.shop_delivery_event (
 id uuid primary key default gen_random_uuid(),
 request_id uuid not null references owner_data.shop_delivery_ack(request_id),
 op_id uuid not null,
 qty integer not null check(qty>=0),
 note text,
 device_id uuid references owner_data.shop_device(id),
 actor uuid,
 received_at timestamptz not null default now(),
 check((device_id is not null)<>(actor is not null)),
 unique(op_id,request_id)
);
create table owner_data.shop_leader_qty_change (
 id uuid primary key default gen_random_uuid(),
 request_id uuid not null references owner_data.shop_request(id),
 op_id uuid not null unique,
 old_qty integer not null check(old_qty>0),
 new_qty integer not null check(new_qty>0),
 device_id uuid references owner_data.shop_device(id),
 actor uuid,
 changed_at timestamptz not null default now(),
 check((device_id is not null)<>(actor is not null))
);
create index shop_delivery_ack_farm_idx on owner_data.shop_delivery_ack(farm_code,handed_at desc);
create index shop_delivery_event_request_idx on owner_data.shop_delivery_event(request_id,received_at desc);
create index shop_leader_qty_request_idx on owner_data.shop_leader_qty_change(request_id,changed_at desc);
alter table owner_data.shop_delivery_ack enable row level security;
alter table owner_data.shop_delivery_event enable row level security;
alter table owner_data.shop_leader_qty_change enable row level security;
revoke all on owner_data.shop_delivery_ack,owner_data.shop_delivery_event,owner_data.shop_leader_qty_change from public,anon,authenticated;
-- New physical handovers only. No backfill and no financial writes.
create function owner_data.shop_delivery_capture() returns trigger language plpgsql set search_path='' as $f$
declare code_v text; label_v text;
begin
 if old.status<>'BOUGHT' or new.status<>'CONFIRMED' then return new;end if;
 select code,label into code_v,label_v from public.hub_option where id=new.option_id;
 if upper(coalesce(code_v,new.custom_name,'')) in ('TOP UP','UBAT','DOCTOR','PINJAM') or coalesce(new.legacy,false) or exists(select 1 from owner_data.shop_wh_review_resolution z where z.request_id=new.id and z.mode in ('MEDICAL_NEW','MEDICAL_EXISTING','HISTORICAL','COMPANY')) then return new;end if;
 insert into owner_data.shop_delivery_ack(request_id,farm_code,kind,item,worker_name,detail,round,sent_qty,handed_at)
 values(new.id,new.farm_code,new.kind,coalesce(label_v,new.custom_name,'Item'),(select name from public.hub_worker where id=new.worker_id),new.detail,new.round,new.qty,coalesce(new.handed_at,now()))
 on conflict(request_id) do nothing;
 return new;
end $f$;
create trigger shop_delivery_capture after update of status on owner_data.shop_request for each row when(old.status is distinct from new.status) execute function owner_data.shop_delivery_capture();
revoke all on function owner_data.shop_delivery_capture() from public,anon,authenticated;
create function owner_data.shop_delivery_valid(p_id uuid) returns boolean language sql stable set search_path='' as $f$
select exists(select 1 from owner_data.shop_request r where r.id=p_id and r.status='CONFIRMED'
 and not exists(select 1 from owner_data.shop_entry e where e.id=r.entry_id and e.voided_at is not null)
 and not exists(select 1 from owner_data.shop_share s where s.id=r.share_id and s.voided_at is not null)
 and not exists(select 1 from owner_data.farm_cost c where c.id=r.cost_id and c.voided_at is not null)
 and not exists(select 1 from owner_data.shop_wh_reversal z where z.request_id=r.id and z.action='RETURN'))
$f$;
revoke all on function owner_data.shop_delivery_valid(uuid) from public,anon,authenticated;
create function owner_data.shop_delivery_json(p_farm text) returns jsonb language sql stable set search_path='' as $f$
select coalesce(jsonb_agg(jsonb_build_object('id',a.request_id,'farm',a.farm_code,'kind',a.kind,'item',a.item,'item_id',r.option_id,'worker',a.worker_name,'detail',a.detail,'round',a.round,'sent_qty',a.sent_qty,'received_qty',a.received_qty,'handed_at',a.handed_at,'last_received_at',a.last_received_at,'last_note',a.last_note,'valid',owner_data.shop_delivery_valid(a.request_id),'photo_count',owner_data.shop_photo_count(a.request_id),'events',coalesce((select jsonb_agg(jsonb_build_object('qty',e.qty,'note',e.note,'at',e.received_at,'by',case when e.device_id is not null then (select w.name from owner_data.shop_device d join public.hub_worker w on w.id=d.worker_id where d.id=e.device_id) else 'Management' end) order by e.received_at desc) from owner_data.shop_delivery_event e where e.request_id=a.request_id),'[]'::jsonb)) order by a.handed_at desc),'[]'::jsonb)
from owner_data.shop_delivery_ack a join owner_data.shop_request r on r.id=a.request_id
where (p_farm is null or a.farm_code=p_farm) and (a.handed_at>now()-interval '90 days' or (a.received_qty<a.sent_qty and owner_data.shop_delivery_valid(a.request_id)))
$f$;
revoke all on function owner_data.shop_delivery_json(text) from public,anon,authenticated;
create function owner_data.shop_leader_qty_editable(r owner_data.shop_request) returns boolean language sql stable set search_path='' as $f$
select r.status='REQUESTED' and r.kind in ('FARM','SHARED','PERSONAL') and r.bottle_id is null
 and coalesce((select upper(code) from public.hub_option where id=r.option_id),upper(r.custom_name),'') not in ('TOP UP','WHISKEY','PHONE','HANDPHONE','UBAT','DOCTOR','PINJAM','SIM CARD')
 and coalesce(owner_data.shop_wh_review(r),'') not in ('WORKER','MEDICAL','INSTALMENT')
 and not exists(select 1 from owner_data.shop_wh_part t where t.request_id=r.id)
 and not exists(select 1 from owner_data.shop_wh_root t where t.request_id=r.id)
 and not exists(select 1 from owner_data.shop_wh_order o where o.request_id=r.id)
 and not exists(select 1 from owner_data.shop_wh_alloc a where a.request_id=r.id)
 and not exists(select 1 from owner_data.shop_wh_phone p where p.request_id=r.id)
$f$;
revoke all on function owner_data.shop_leader_qty_editable(owner_data.shop_request) from public,anon,authenticated;

create function public.shop_leader_delivery_action(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $f$
declare who jsonb; actor_id uuid; dev uuid; farm_v text; op uuid:=(p->>'op_id')::uuid; old owner_data.shop_leader_submit; digest_v jsonb; res jsonb; action_v text:=p->>'action'; x jsonb; r owner_data.shop_request; ack owner_data.shop_delivery_ack; q int; expected int; note_v text; n int:=0;
begin
 who:=owner_data.shop_photo_actor(p);actor_id:=(who->>'actor')::uuid;dev:=(who->>'device')::uuid;farm_v:=who->>'farm';
 if op is null then raise exception 'Operation ID required';end if;
 digest_v:=jsonb_build_object('hash',md5((p-'device_key')::text));
 perform pg_advisory_xact_lock(27112026,64);
 select * into old from owner_data.shop_leader_submit where id=op;
 if found then
  if old.actor is distinct from actor_id or old.device_id is distinct from dev or old.farm<>farm_v or old.payload<>digest_v then raise exception 'Operation already used';end if;
  return old.result;
 end if;
 if action_v='EDIT_QTY' then
  select * into r from owner_data.shop_request where id=(p->>'request_id')::uuid and farm_code=farm_v for update;
  q:=(p->>'qty')::int;expected:=(p->>'expected_qty')::int;
  if r.id is null or not owner_data.shop_leader_qty_editable(r) or expected is distinct from r.qty then raise exception 'Request changed or already being purchased — refresh';end if;
  if q is null or q not between 1 and (case when r.kind='PERSONAL' then 20 else 999 end) then raise exception 'Invalid quantity';end if;
  if q<>r.qty then
   insert into owner_data.shop_leader_qty_change(request_id,op_id,old_qty,new_qty,device_id,actor) values(r.id,op,r.qty,q,dev,actor_id);
   update owner_data.shop_request set qty=q where id=r.id;
  end if;
  n:=1;
 elsif action_v='RECEIVE' then
  if jsonb_typeof(p->'lines') is distinct from 'array' or jsonb_array_length(p->'lines') not between 1 and 100 then raise exception 'Select delivery lines';end if;
  for x in select value from jsonb_array_elements(p->'lines') order by value->>'id' loop
   select * into r from owner_data.shop_request where id=(x->>'id')::uuid and farm_code=farm_v for update;
   select * into ack from owner_data.shop_delivery_ack where request_id=r.id and farm_code=farm_v for update;
   q:=(x->>'qty')::int;expected:=(x->>'expected_received')::int;note_v:=nullif(btrim(coalesce(x->>'note','')),'');
   if ack.request_id is null or not owner_data.shop_delivery_valid(r.id) or expected is distinct from ack.received_qty or ack.received_qty>=ack.sent_qty then raise exception 'Delivery changed or already received — refresh';end if;
   if q is null or q<0 or q>ack.sent_qty-ack.received_qty or length(note_v)>200 or (q<ack.sent_qty-ack.received_qty and note_v is null) then raise exception 'Check quantity and report missing goods';end if;
   insert into owner_data.shop_delivery_event(request_id,op_id,qty,note,device_id,actor) values(ack.request_id,op,q,note_v,dev,actor_id);
   update owner_data.shop_delivery_ack set received_qty=received_qty+q,last_received_at=case when q>0 then now() else last_received_at end,last_note=note_v where request_id=ack.request_id;
   n:=n+1;
  end loop;
 else raise exception 'Unknown leader action';end if;
 res:=jsonb_build_object('ok',true,'count',n,'op_id',op);
 insert into owner_data.shop_leader_submit(id,device_id,actor,farm,payload,result) values(op,dev,actor_id,farm_v,digest_v,res);
 return res;
end $f$;
revoke all on function public.shop_leader_delivery_action(jsonb) from public,anon,authenticated;
grant execute on function public.shop_leader_delivery_action(jsonb) to anon,authenticated;

CREATE OR REPLACE FUNCTION owner_data.shop_line_json(r owner_data.shop_request)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select jsonb_build_object('id', r.id, 'kind', r.kind, 'farm', r.farm_code, 'worker_id', r.worker_id,
    'worker', (select w.name from public.hub_worker w where w.id = r.worker_id),
    'item_id', r.option_id, 'item', coalesce((select o.label from public.hub_option o where o.id = r.option_id), r.custom_name),
    'code', (select o.code from public.hub_option o where o.id = r.option_id), 'custom', r.option_id is null,
    'qty', r.qty, 'trip', r.trip, 'round', r.round, 'status', r.status, 'note', r.note, 'at', r.created_at,
    'buy', r.buy, 'bought_at', r.bought_at, 'handed_at', r.handed_at, 'from_phone', r.device_id is not null, 'detail', r.detail,
    'buy_price', r.buy_price, 'sell_price', r.sell_price, 'pay_id', r.pay_id, 'worker_paid', r.worker_paid,
    'bottle_id', r.bottle_id, 'bottle_n', r.bottle_n, 'asked', owner_data.shop_ask(r), 'legacy', r.legacy, 'photo_count',owner_data.shop_photo_count(r.id), 'qty_editable',owner_data.shop_leader_qty_editable(r), 'ordered',exists(select 1 from owner_data.shop_wh_order o where o.request_id=r.id and o.received_qty+o.cancelled_qty<o.qty), 'reserved',exists(select 1 from owner_data.shop_wh_alloc a where a.request_id=r.id and a.status='READY'))
$function$;
CREATE OR REPLACE FUNCTION public.shop_hello(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare k uuid; d owner_data.shop_device; v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date; v_farms text[]; v_farm text;
begin
  begin k := (p->>'device_key')::uuid; exception when others then raise exception 'Bad request'; end;
  if k is null then raise exception 'Bad request'; end if;
  select * into d from owner_data.shop_device where device_key = k;
  if d.id is null then
    if (select count(*) from owner_data.shop_device where status = 'PENDING') >= 10 then raise exception 'Too many phones waiting'; end if;
    insert into owner_data.shop_device (device_key, user_agent) values (k, left(p->>'ua', 200)) returning * into d;
  end if;
  v_farms := owner_data.shop_phone_farms(d);
  if d.status <> 'ACTIVE' or coalesce(array_length(v_farms,1),0) = 0 then
    return jsonb_build_object('status', case when d.status = 'ACTIVE' then 'PENDING' else d.status end, 'code', upper(left(replace(k::text,'-',''), 6)));
  end if;
  if d.unlocked_on is distinct from v_today then
    return jsonb_build_object('status', 'PIN', 'name', (select w.name from public.hub_worker w where w.id = d.worker_id));
  end if;
  v_farm := case when nullif(p->>'farm','') = any(v_farms) then p->>'farm' else v_farms[1] end;
  update owner_data.shop_device set last_seen = now() where id = d.id;
  return jsonb_build_object(
    'status', 'ACTIVE', 'farm', v_farm, 'farms', to_jsonb(v_farms), 'today', v_today,
    'me', (select jsonb_build_object('name', w.name, 'role', l.role) from public.hub_worker w join owner_data.shop_leader l on l.worker_id = w.id where w.id = d.worker_id),
    'food_round', owner_data.shop_food_round(v_today), 'deliveries',owner_data.shop_delivery_json(v_farm),
    'workers', owner_data.shop_farm_workers(v_farm),
    'items', owner_data.shop_items_json(false),
    'lines', coalesce((select jsonb_agg(owner_data.shop_line_json(r) - array['buy','buy_price','sell_price','pay_id','worker_paid'] order by r.created_at)
                       from owner_data.shop_request r
                       where r.farm_code = v_farm
                         and (r.status in ('REQUESTED','BOUGHT')
                              or (r.status = 'REJECTED' and r.decided_at > now() - interval '14 days'))), '[]'::jsonb),
    'att', coalesce((select jsonb_object_agg(a.worker_id, jsonb_build_object('code', a.code, 'why', n.reason))
                     from public.salary_attendance a left join owner_data.att_note n on n.worker_id = a.worker_id and n.work_date = a.work_date
                     where a.work_date = v_today and a.code <> ''
                       and owner_data.shop_worker_farm(a.worker_id) = v_farm), '{}'::jsonb));
end $function$;
CREATE OR REPLACE FUNCTION public.shop_owner_lhello(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date; v_farms text[] := array['AD 1','AD 2','AD 3']; v_farm text;
begin
  perform owner_data.require_shop('shop_lhello', jsonb_build_object('farm', p->>'farm'));
  v_farm := case when nullif(p->>'farm','') = any(v_farms) then p->>'farm' else 'AD 1' end;
  return jsonb_build_object(
    'status', 'ACTIVE', 'farm', v_farm, 'farms', to_jsonb(v_farms), 'today', v_today, 'manager', true,
    'me', (select jsonb_build_object('id', u.id, 'role', u.role) from public.hub_app_user u where u.id = auth.uid()),
    'food_round', owner_data.shop_food_round(v_today), 'deliveries',owner_data.shop_delivery_json(v_farm),
    'workers', owner_data.shop_farm_workers(v_farm),
    'items', owner_data.shop_items_json(false),
    -- same as the Leader phone: no price, no who paid
    'lines', coalesce((select jsonb_agg(owner_data.shop_line_json(r) - array['buy','buy_price','sell_price','pay_id','worker_paid'] order by r.created_at)
                       from owner_data.shop_request r
                       where r.farm_code = v_farm
                         and (r.status in ('REQUESTED','BOUGHT')
                              or (r.status = 'REJECTED' and r.decided_at > now() - interval '14 days'))), '[]'::jsonb),
    'att', coalesce((select jsonb_object_agg(a.worker_id, jsonb_build_object('code', a.code, 'why', n.reason))
                     from public.salary_attendance a left join owner_data.att_note n on n.worker_id = a.worker_id and n.work_date = a.work_date
                     where a.work_date = v_today and a.code <> ''
                       and owner_data.shop_worker_farm(a.worker_id) = v_farm), '{}'::jsonb));
end $function$;
CREATE OR REPLACE FUNCTION public.shop_owner_board(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  perform owner_data.require_shop('shop_board', '{}'::jsonb);
  return jsonb_build_object(
    'today', v_today, 'food_round', owner_data.shop_food_round(v_today), 'deliveries',owner_data.shop_delivery_json(null),
    'trip_day', (select (value)::int from owner_data.shop_setting where key = 'trip_day'),
    'me', (select jsonb_build_object('id', u.id, 'role', u.role) from public.hub_app_user u where u.id = auth.uid()),
    'items', owner_data.shop_items_json(true),
    'leaders', coalesce((select jsonb_agg(jsonb_build_object('worker_id', l.worker_id, 'name', w.name, 'role', l.role, 'farm', l.farm_code, 'pin_set', l.pin_hash is not null) order by l.role desc, l.farm_code, w.name)
                         from owner_data.shop_leader l join public.hub_worker w on w.id = l.worker_id), '[]'::jsonb),
    'phones', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'code', upper(left(replace(d.device_key::text,'-',''), 6)), 'status', d.status,
                          'worker_id', d.worker_id, 'person', (select w.name from public.hub_worker w where w.id = d.worker_id), 'label', d.label,
                          'farms', to_jsonb(owner_data.shop_phone_farms(d)), 'requested_at', d.requested_at, 'last_seen', d.last_seen) order by d.status, d.requested_at desc)
                        from owner_data.shop_device d), '[]'::jsonb),
    'all_workers', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name, 'farm', owner_data.shop_worker_farm(w.id)) order by w.name)
                             from public.hub_worker w where w.voided_at is null and (w.stop_date is null or w.stop_date > v_today)
                               and owner_data.shop_worker_farm(w.id) in ('AD 1','AD 2','AD 3')), '[]'::jsonb),
    'workers', jsonb_build_object('AD 1', owner_data.shop_farm_workers('AD 1'), 'AD 2', owner_data.shop_farm_workers('AD 2'), 'AD 3', owner_data.shop_farm_workers('AD 3')),
    'lines', coalesce((select jsonb_agg(owner_data.shop_line_json(r) order by r.created_at) from owner_data.shop_request r
                       where r.status in ('REQUESTED','BOUGHT') or (r.status = 'REJECTED' and r.decided_at > now() - interval '14 days')), '[]'::jsonb),
    'written', jsonb_build_object(
       'personal', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'farm', e.farm_code, 'worker', w.name, 'item', e.item, 'qty', e.qty, 'amount', e.amount, 'date', e.buy_date, 'void', e.voided_at is not null,
         'asked', (select owner_data.shop_ask(r) from owner_data.shop_request r where r.entry_id = e.id limit 1),
         'req_id', (select r.id from owner_data.shop_request r where r.entry_id = e.id and r.legacy limit 1)) order by e.created_at desc)
                             from owner_data.shop_entry e join public.hub_worker w on w.id = e.worker_id where (e.created_at > now() - interval '35 days' or e.buy_date >= date '2026-10-31')), '[]'::jsonb),
       'shared', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'farm', s.farm_code, 'item', s.item, 'amount', s.amount, 'date', s.buy_date, 'n', cardinality(s.worker_ids), 'void', s.voided_at is not null,
         'asked', (select min(owner_data.shop_ask(r)) from owner_data.shop_request r where r.share_id = s.id)) order by s.created_at desc)
                           from owner_data.shop_share s where (s.created_at > now() - interval '35 days' or s.buy_date >= date '2026-10-31')), '[]'::jsonb),
       'farm', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'farm', c.farm_code, 'item', c.item, 'qty', c.qty, 'amount', c.amount, 'date', c.buy_date, 'void', c.voided_at is not null,
         'asked', (select min(owner_data.shop_ask(r)) from owner_data.shop_request r where r.cost_id = c.id)) order by c.created_at desc)
                         from owner_data.farm_cost c where (c.created_at > now() - interval '35 days' or c.buy_date >= date '2026-10-31')), '[]'::jsonb)),
    'att', coalesce((select jsonb_object_agg(f, jsonb_build_object(
              'work', (select count(*) from public.salary_attendance a where a.work_date = v_today and a.code = 'ad' and owner_data.shop_worker_farm(a.worker_id) = f),
              'half', (select count(*) from public.salary_attendance a where a.work_date = v_today and a.code = 'ad_half' and owner_data.shop_worker_farm(a.worker_id) = f),
              'off',  (select count(*) from public.salary_attendance a where a.work_date = v_today and a.code = 'off' and owner_data.shop_worker_farm(a.worker_id) = f)))
            from unnest(array['AD 1','AD 2','AD 3']) f), '{}'::jsonb));
end $function$;
notify pgrst,'reload schema';