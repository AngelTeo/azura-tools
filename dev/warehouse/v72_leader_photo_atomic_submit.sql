
create table owner_data.shop_request_photo (
 request_id uuid not null references owner_data.shop_request(id),
 seq smallint not null check(seq between 1 and 3),
 jpeg bytea not null check(octet_length(jpeg) between 4 and 120000 and substring(jpeg from 1 for 3)=decode('ffd8ff','hex') and substring(jpeg from octet_length(jpeg)-1 for 2)=decode('ffd9','hex')),
 created_at timestamptz not null default now(),
 primary key(request_id,seq)
);
alter table owner_data.shop_request_photo enable row level security;
revoke all on owner_data.shop_request_photo from public,anon,authenticated;
create table owner_data.shop_leader_submit (
 id uuid primary key, device_id uuid references owner_data.shop_device(id), actor uuid,
 farm text not null, payload jsonb not null, result jsonb not null,
 created_at timestamptz not null default now(),
 check((device_id is not null)<>(actor is not null))
);
alter table owner_data.shop_leader_submit enable row level security;
revoke all on owner_data.shop_leader_submit from public,anon,authenticated;
-- Store no image data in the retry audit payload: retain only a digest.
create function owner_data.shop_photo_source(p_id uuid) returns uuid language sql stable set search_path='' as $f$
select coalesce((select request_id from owner_data.shop_request_photo where request_id=p_id limit 1),
 (select p.root_id from owner_data.shop_wh_part p where p.request_id=p_id and exists(select 1 from owner_data.shop_request_photo f where f.request_id=p.root_id)),
 p_id)
$f$;
revoke all on function owner_data.shop_photo_source(uuid) from public,anon,authenticated;
create function owner_data.shop_photo_count(p_id uuid) returns int language sql stable set search_path='' as $f$
select count(*)::int from owner_data.shop_request_photo where request_id=owner_data.shop_photo_source(p_id)
$f$;
revoke all on function owner_data.shop_photo_count(uuid) from public,anon,authenticated;
create function owner_data.shop_photo_actor(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $f$
declare d owner_data.shop_device; f text;
begin
 if coalesce((p->>'manager')::boolean,false) then
  if auth.uid() is null or not public.shop_is_manager() then raise exception 'Not allowed';end if;
  f:=p->>'farm'; if coalesce(f,'') not in ('AD 1','AD 2','AD 3') then raise exception 'Pick a farm';end if;
  return jsonb_build_object('actor',auth.uid(),'farm',f);
 end if;
 d:=owner_data.shop_device_ok(p->>'device_key');
 f:=owner_data.shop_pick_farm(d,p->>'farm');
 if f is distinct from p->>'farm' then raise exception 'Farm changed — refresh';end if;
 return jsonb_build_object('device',d.id,'farm',f);
end $f$;
revoke all on function owner_data.shop_photo_actor(jsonb) from public,anon,authenticated;

create function public.shop_request_photo_get(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $f$
declare r owner_data.shop_request; who jsonb;
begin
 select * into r from owner_data.shop_request where id=(p->>'request_id')::uuid;
 if r.id is null then raise exception 'Not available';end if;
 if coalesce((p->>'manager')::boolean,false) then
  if auth.uid() is null or not public.shop_is_manager() then raise exception 'Not allowed';end if;
 else
  who:=owner_data.shop_photo_actor(p);
  if r.farm_code is distinct from who->>'farm' then raise exception 'Not available';end if;
 end if;
 return coalesce((select jsonb_agg(replace(encode(f.jpeg,'base64'),E'\n','') order by f.seq) from owner_data.shop_request_photo f where f.request_id=owner_data.shop_photo_source(r.id)),'[]'::jsonb);
end $f$;
revoke all on function public.shop_request_photo_get(jsonb) from public,anon,authenticated;
grant execute on function public.shop_request_photo_get(jsonb) to anon,authenticated;

create function public.shop_leader_submit(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $f$
declare who jsonb; actor_id uuid; device_id_v uuid; farm_v text; op uuid:=(p->>'op_id')::uuid; old owner_data.shop_leader_submit; r jsonb; q jsonb; img text; n int:=0; seq_v int; cid uuid; rid uuid; kind_v text; opt uuid; qty_v int; name_v text; detail_v text; round_v date; today date:=(now() at time zone 'Asia/Kuala_Lumpur')::date; digest_v jsonb; res jsonb; total_bytes int:=0; worker_id_v uuid; ws uuid[];
begin
 who:=owner_data.shop_photo_actor(p);actor_id:=(who->>'actor')::uuid;device_id_v:=(who->>'device')::uuid;farm_v:=who->>'farm';
 if op is null or jsonb_typeof(p->'requests') is distinct from 'array' or jsonb_array_length(p->'requests') not between 1 and 40 then raise exception 'Invalid request batch';end if;
 digest_v:=jsonb_build_object('hash',md5((p-'device_key')::text));
 perform pg_advisory_xact_lock(27112026,64);
 select * into old from owner_data.shop_leader_submit where id=op;
 if found then
  if old.actor is distinct from actor_id or old.device_id is distinct from device_id_v or old.farm<>farm_v or old.payload<>digest_v then raise exception 'Operation already used';end if;
  return old.result;
 end if;
 if device_id_v is not null and (select count(*) from owner_data.shop_request where device_id=device_id_v and created_at>now()-interval '1 day')+jsonb_array_length(p->'requests')>300 then raise exception 'Too many requests today';end if;
 for r in select value from jsonb_array_elements(p->'requests') loop
  kind_v:=r->>'kind';cid:=(r->>'client_id')::uuid;opt:=nullif(r->>'item_id','')::uuid;qty_v:=(r->>'qty')::int;
  name_v:=nullif(btrim(coalesce(r->>'custom_name','')),'');detail_v:=nullif(btrim(coalesce(r->>'detail','')),'');
  if cid is null or kind_v is null or kind_v not in ('FARM','PERSONAL','SHARED','FOOD') or qty_v is null or qty_v not between 1 and (case when kind_v='PERSONAL' then 20 else 999 end) or length(detail_v)>80 or exists(select 1 from owner_data.shop_request where client_id=cid) then raise exception 'Invalid or repeated request';end if;
  if jsonb_typeof(coalesce(r->'photos','[]'::jsonb))<>'array' or jsonb_array_length(coalesce(r->'photos','[]'::jsonb))>3 then raise exception 'Maximum 3 reference photos';end if;
  if opt is null and name_v is null then
   if jsonb_array_length(coalesce(r->'photos','[]'::jsonb))=0 then raise exception 'Enter a name or attach a photo';end if;
   name_v:='PHOTO REQUEST';
  end if;
  if name_v='PHOTO REQUEST' and jsonb_array_length(coalesce(r->'photos','[]'::jsonb))=0 then raise exception 'Photo required';end if;
  if kind_v='PERSONAL' then
   if jsonb_typeof(r->'workers') is distinct from 'array' or jsonb_array_length(r->'workers') not between 1 and 3 then raise exception 'Choose worker';end if;
   select array_agg(distinct value::uuid) into ws from jsonb_array_elements_text(r->'workers');
   if cardinality(ws)<>jsonb_array_length(r->'workers') or exists(select 1 from unnest(ws) w(id) where not exists(select 1 from public.hub_worker h where h.id=w.id and h.voided_at is null and (h.stop_date is null or h.stop_date>today) and owner_data.shop_worker_farm(h.id)=farm_v)) then raise exception 'Worker list changed';end if;
   if cardinality(ws)>1 and not exists(select 1 from public.hub_option where id=opt and code='WHISKEY') then raise exception 'Choose one worker per reference request';end if;
  end if;
  if kind_v='FOOD' then
   round_v:=(r->>'round')::date;
   if round_v is distinct from owner_data.shop_food_round(today) then raise exception 'Food round changed — refresh';end if;
   if exists(select 1 from owner_data.shop_request where farm_code=farm_v and kind='FOOD' and round=round_v and status not in ('REQUESTED','CANCELLED')) then raise exception 'This round is already being bought';end if;
   if opt is not null and not exists(select 1 from public.hub_option where id=opt and list_code='FOOD_ITEM' and shown) then raise exception 'Unknown food item';end if;
   if jsonb_array_length(coalesce(r->'photos','[]'::jsonb))=0 then raise exception 'Use regular food order for items without reference photos';end if;
   insert into owner_data.shop_request(client_id,device_id,made_by,farm_code,option_id,custom_name,qty,kind,round,detail) values(cid,device_id_v,actor_id,farm_v,opt,name_v,qty_v,'FOOD',round_v,detail_v);
  else
   q:=(r-'photos')||jsonb_build_object('farm',farm_v,'client_id',cid,'kind',kind_v,'custom_name',name_v,'detail',detail_v);
   if device_id_v is not null then perform public.shop_request(q||jsonb_build_object('device_key',p->>'device_key'));else perform public.shop_owner_lrequest(q);end if;
  end if;
  for rid in select id from owner_data.shop_request where client_id=cid and farm_code=farm_v loop
   seq_v:=0;
   for img in select value from jsonb_array_elements_text(coalesce(r->'photos','[]'::jsonb)) loop
    seq_v:=seq_v+1;
    if length(img)>160000 or img!~'^[A-Za-z0-9+/]+={0,2}$' then raise exception 'Invalid compressed photo';end if;
    total_bytes:=total_bytes+length(img);if total_bytes>1500000 then raise exception 'Photo batch too large — submit fewer items';end if;
    insert into owner_data.shop_request_photo(request_id,seq,jpeg) values(rid,seq_v,decode(img,'base64'));
   end loop;
   n:=n+1;
  end loop;
 end loop;
 res:=jsonb_build_object('ok',true,'count',n,'op_id',op);
 insert into owner_data.shop_leader_submit(id,device_id,actor,farm,payload,result) values(op,device_id_v,actor_id,farm_v,digest_v,res);
 return res;
end $f$;
revoke all on function public.shop_leader_submit(jsonb) from public,anon,authenticated;
grant execute on function public.shop_leader_submit(jsonb) to anon,authenticated;

create function public.shop_owner_photo_identify(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $f$
declare r owner_data.shop_request; opt public.hub_option; v_item uuid; label_v text; list_v text; v_unit text; v_supplier text;
begin
 perform owner_data.require_shop('shop_photo_identify',jsonb_build_object('request_id',p->>'request_id'));
 perform pg_advisory_xact_lock(27112026,64);
 select * into r from owner_data.shop_request where id=(p->>'request_id')::uuid for update;
 if r.id is null or r.status<>'REQUESTED' or r.option_id is not null or owner_data.shop_photo_count(r.id)=0 then raise exception 'Not an unidentified photo request';end if;
 list_v:=owner_data.shop_list(r.kind);
 if r.kind='FOOD' then list_v:='FOOD_ITEM';end if;
 v_item:=nullif(p->>'item_id','')::uuid;
 if v_item is null then
  label_v:=upper(btrim(coalesce(p->>'label','')));
  if length(label_v) not between 1 and 30 or label_v='PHOTO REQUEST' or label_v in ('TOP UP','WHISKEY','PINJAM','DOCTOR','UBAT','HANDPHONE','PHONE') then raise exception 'Enter actual product name';end if;
  if r.kind='FOOD' then
   v_unit:=btrim(coalesce(p->>'unit',''));v_supplier:=p->>'supplier';
   if length(v_unit) not between 1 and 30 or coalesce(v_supplier,'') not in ('Huat Tiong','Grocery','Wet Market') then raise exception 'Confirm food unit and supplier';end if;
  end if;
  insert into public.hub_option(list_code,code,label,sort,shown) values(list_v,label_v,label_v,(select coalesce(max(sort),0)+1 from public.hub_option where list_code=list_v),true) on conflict(list_code,code) do nothing;
  select id into v_item from public.hub_option where list_code=list_v and code=label_v and shown;
  if r.kind='FOOD' then insert into owner_data.shop_item_unit(option_id,unit,supplier) values(v_item,v_unit,v_supplier) on conflict(option_id) do nothing;end if;
 end if;
 select * into opt from public.hub_option where id=v_item and list_code=list_v and shown and code not in ('TOP UP','WHISKEY','PINJAM','DOCTOR','UBAT','HANDPHONE','PHONE');
 if opt.id is null then raise exception 'Select matching ordinary catalogue item';end if;
 update owner_data.shop_request set option_id=v_item where id=r.id;
 return jsonb_build_object('ok',true,'item_id',v_item);
end $f$;
revoke all on function public.shop_owner_photo_identify(jsonb) from public,anon,authenticated;
grant execute on function public.shop_owner_photo_identify(jsonb) to authenticated,service_role;

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
    'bottle_id', r.bottle_id, 'bottle_n', r.bottle_n, 'asked', owner_data.shop_ask(r), 'legacy', r.legacy, 'photo_count',owner_data.shop_photo_count(r.id), 'ordered',exists(select 1 from owner_data.shop_wh_order o where o.request_id=r.id and o.received_qty+o.cancelled_qty<o.qty), 'reserved',exists(select 1 from owner_data.shop_wh_alloc a where a.request_id=r.id and a.status='READY'))
$function$;
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
    'food_round', owner_data.shop_food_round(v_today),
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
    'food_round', owner_data.shop_food_round(v_today),
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
CREATE OR REPLACE FUNCTION public.shop_food_set(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare d owner_data.shop_device; v_farm text; v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date; v_round date; k text; v_qty int; v_n int := 0;
begin
  d := owner_data.shop_device_ok(p->>'device_key');
  v_farm := owner_data.shop_pick_farm(d, nullif(p->>'farm',''));
  v_round := owner_data.shop_food_round(v_today);
  perform pg_advisory_xact_lock(27112026,64);
  if p ? 'round' and (p->>'round')::date is distinct from v_round then raise exception 'Food round changed — refresh';end if;
  if jsonb_typeof(p->'items') <> 'object' then raise exception 'Bad request'; end if;
  if exists (select 1 from owner_data.shop_request where farm_code = v_farm and kind = 'FOOD' and round = v_round and status <> 'REQUESTED' and status <> 'CANCELLED') then
    raise exception 'This round is already being bought';
  end if;
  update owner_data.shop_request set status = 'CANCELLED', decided_at = now(), note = 'Replaced'
   where farm_code = v_farm and kind = 'FOOD' and round = v_round and status = 'REQUESTED' and owner_data.shop_photo_count(id)=0;
  for k, v_qty in select key, (value)::int from jsonb_each_text(p->'items') loop
    if v_qty is null or v_qty = 0 then continue; end if;
    if v_qty < 1 or v_qty > 999 then raise exception 'Check the quantity'; end if;
    if not exists (select 1 from public.hub_option o where o.id = k::uuid and o.list_code = 'FOOD_ITEM' and o.shown) then raise exception 'Unknown item'; end if;
    insert into owner_data.shop_request (client_id, device_id, farm_code, option_id, qty, kind, round)
    values (gen_random_uuid(), d.id, v_farm, k::uuid, v_qty, 'FOOD', v_round);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'count', v_n, 'round', v_round);
end $function$;
CREATE OR REPLACE FUNCTION public.shop_owner_lfood_set(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_farm text := p->>'farm'; v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date; v_round date; k text; v_qty int; v_n int := 0;
begin
  perform owner_data.require_shop('shop_lfood_set', p);
  if coalesce(v_farm,'') not in ('AD 1','AD 2','AD 3') then raise exception 'Pick a farm'; end if;
  v_round := owner_data.shop_food_round(v_today);
  perform pg_advisory_xact_lock(27112026,64);
  if p ? 'round' and (p->>'round')::date is distinct from v_round then raise exception 'Food round changed — refresh';end if;
  if jsonb_typeof(p->'items') <> 'object' then raise exception 'Bad request'; end if;
  if exists (select 1 from owner_data.shop_request where farm_code = v_farm and kind = 'FOOD' and round = v_round and status <> 'REQUESTED' and status <> 'CANCELLED') then
    raise exception 'This round is already being bought';
  end if;
  update owner_data.shop_request set status = 'CANCELLED', decided_at = now(), note = 'Replaced'
   where farm_code = v_farm and kind = 'FOOD' and round = v_round and status = 'REQUESTED' and owner_data.shop_photo_count(id)=0;
  for k, v_qty in select key, (value)::int from jsonb_each_text(p->'items') loop
    if v_qty is null or v_qty = 0 then continue; end if;
    if v_qty < 1 or v_qty > 999 then raise exception 'Check the quantity'; end if;
    if not exists (select 1 from public.hub_option o where o.id = k::uuid and o.list_code = 'FOOD_ITEM' and o.shown) then raise exception 'Unknown item'; end if;
    insert into owner_data.shop_request (client_id, device_id, made_by, farm_code, option_id, qty, kind, round)
    values (gen_random_uuid(), null, auth.uid(), v_farm, k::uuid, v_qty, 'FOOD', v_round);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'count', v_n, 'round', v_round);
end $function$;
notify pgrst,'reload schema';