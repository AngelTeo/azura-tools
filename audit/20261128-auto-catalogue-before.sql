CREATE OR REPLACE FUNCTION public.shop_leader_submit(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;

CREATE OR REPLACE FUNCTION public.shop_owner_item_add(p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_name text := upper(regexp_replace(trim(coalesce(p->>'label','')), '\s+', ' ', 'g')); v_id uuid;
  v_kind text := coalesce(nullif(p->>'kind',''), 'PERSONAL'); v_list text;
begin
  perform owner_data.require_owner_shop('shop_item_add', p);
  if v_kind not in ('PERSONAL','SHARED','FARM') then raise exception 'Bad request'; end if;
  v_list := owner_data.shop_list(v_kind);
  if v_name = '' or length(v_name) > 30 then raise exception 'Name 1 to 30 letters'; end if;
  select id into v_id from public.hub_option where list_code = v_list and code = v_name;
  if v_id is null then
    insert into public.hub_option (list_code, code, label, sort, shown)
    values (v_list, v_name, v_name, (select coalesce(max(sort),0)+1 from public.hub_option where list_code = v_list), true)
    returning id into v_id;
  else
    update public.hub_option set shown = true where id = v_id;
  end if;
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.shop_owner_photo_identify(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
end $function$;