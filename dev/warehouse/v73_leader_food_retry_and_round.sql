
create function public.shop_leader_food_save(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $f$
declare who jsonb; actor_id uuid; dev uuid; f text; op uuid:=(p->>'op_id')::uuid; old owner_data.shop_leader_submit; d date; sig jsonb; expected jsonb; digest_v jsonb; res jsonb;
begin
 who:=owner_data.shop_photo_actor(p);actor_id:=(who->>'actor')::uuid;dev:=(who->>'device')::uuid;f:=who->>'farm';
 if op is null or jsonb_typeof(p->'items') is distinct from 'object' or jsonb_typeof(p->'baseline') is distinct from 'array' then raise exception 'Invalid food order';end if;
 digest_v:=jsonb_build_object('hash',md5((p-'device_key')::text));
 perform pg_advisory_xact_lock(27112026,64);
 select * into old from owner_data.shop_leader_submit where id=op;
 if found then
  if old.actor is distinct from actor_id or old.device_id is distinct from dev or old.farm<>f or old.payload<>digest_v then raise exception 'Operation already used';end if;
  return old.result;
 end if;
 d:=(p->>'round')::date;
 if d is distinct from owner_data.shop_food_round((now() at time zone 'Asia/Kuala_Lumpur')::date) then raise exception 'Food round changed — refresh';end if;
 perform 1 from owner_data.shop_request r where r.farm_code=f and r.kind='FOOD' and r.round=d for update;
 select coalesce(jsonb_agg(jsonb_build_array(r.id,r.qty) order by r.id),'[]'::jsonb) into sig from owner_data.shop_request r where r.farm_code=f and r.kind='FOOD' and r.round=d and r.status='REQUESTED' and owner_data.shop_photo_count(r.id)=0 and r.option_id is not null;
 select coalesce(jsonb_agg(x order by x->>0),'[]'::jsonb) into expected from jsonb_array_elements(p->'baseline') x;
 if sig<>expected then raise exception 'Food list changed — refresh before editing';end if;
 if dev is not null then res:=public.shop_food_set(p);else res:=public.shop_owner_lfood_set(p);end if;
 insert into owner_data.shop_leader_submit(id,device_id,actor,farm,payload,result) values(op,dev,actor_id,f,digest_v,res);
 return res;
end $f$;
revoke all on function public.shop_leader_food_save(jsonb) from public,anon,authenticated;
grant execute on function public.shop_leader_food_save(jsonb) to anon,authenticated;
notify pgrst,'reload schema';
