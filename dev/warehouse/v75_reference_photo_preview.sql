CREATE OR REPLACE FUNCTION public.shop_request_photo_get(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
 return coalesce((select jsonb_agg(replace(encode(f.jpeg,'base64'),E'\n','') order by f.seq) from owner_data.shop_request_photo f where f.request_id=owner_data.shop_photo_source(r.id) and (not coalesce((p->>'first')::boolean,false) or f.seq=1)),'[]'::jsonb);
end $function$;
notify pgrst,'reload schema';