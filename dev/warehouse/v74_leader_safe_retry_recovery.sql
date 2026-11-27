
create function public.shop_leader_abandon(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $f$
declare who jsonb; actor_id uuid; dev uuid; f text; op uuid:=(p->>'op_id')::uuid; old owner_data.shop_leader_submit; res jsonb;
begin
 who:=owner_data.shop_photo_actor(p);actor_id:=(who->>'actor')::uuid;dev:=(who->>'device')::uuid;f:=who->>'farm';
 if op is null then raise exception 'Missing operation ID';end if;
 perform pg_advisory_xact_lock(27112026,64);
 select * into old from owner_data.shop_leader_submit where id=op;
 if found then
  if old.actor is distinct from actor_id or old.device_id is distinct from dev or old.farm<>f then raise exception 'Operation not available';end if;
  return old.result;
 end if;
 res:=jsonb_build_object('ok',false,'cancelled',true,'op_id',op);
 insert into owner_data.shop_leader_submit(id,device_id,actor,farm,payload,result) values(op,dev,actor_id,f,jsonb_build_object('abandoned',true),res);
 return res;
end $f$;
revoke all on function public.shop_leader_abandon(jsonb) from public,anon,authenticated;
grant execute on function public.shop_leader_abandon(jsonb) to anon,authenticated;
notify pgrst,'reload schema';