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
    'bottle_id', r.bottle_id, 'bottle_n', r.bottle_n, 'asked', owner_data.shop_ask(r), 'legacy', r.legacy, 'photo_count',owner_data.shop_photo_count(r.id), 'qty_editable',owner_data.shop_leader_qty_editable(r), 'qty_change',(select jsonb_build_object('old_qty',z.old_qty,'new_qty',z.new_qty,'at',z.changed_at) from owner_data.shop_leader_qty_change z where z.request_id=r.id order by z.changed_at desc limit 1), 'ordered',exists(select 1 from owner_data.shop_wh_order o where o.request_id=r.id and o.received_qty+o.cancelled_qty<o.qty), 'reserved',exists(select 1 from owner_data.shop_wh_alloc a where a.request_id=r.id and a.status='READY'))
$function$;
CREATE OR REPLACE FUNCTION owner_data.shop_leader_qty_editable(r owner_data.shop_request)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
select r.status='REQUESTED' and r.kind in ('FARM','SHARED','PERSONAL') and r.bottle_id is null
 and (r.kind<>'PERSONAL' or exists(select 1 from public.hub_worker w where w.id=r.worker_id and w.voided_at is null and (w.stop_date is null or w.stop_date>(now() at time zone 'Asia/Kuala_Lumpur')::date) and owner_data.shop_worker_farm(w.id)=r.farm_code))
 and coalesce((select upper(code) from public.hub_option where id=r.option_id),upper(r.custom_name),'') not in ('TOP UP','WHISKEY','PHONE','HANDPHONE','UBAT','DOCTOR','PINJAM','SIM CARD')
 and coalesce(owner_data.shop_wh_review(r),'') not in ('WORKER','MEDICAL','INSTALMENT')
 and not exists(select 1 from owner_data.shop_wh_part t where t.request_id=r.id)
 and not exists(select 1 from owner_data.shop_wh_root t where t.request_id=r.id)
 and not exists(select 1 from owner_data.shop_wh_order o where o.request_id=r.id)
 and not exists(select 1 from owner_data.shop_wh_alloc a where a.request_id=r.id)
 and not exists(select 1 from owner_data.shop_wh_phone p where p.request_id=r.id)
$function$;
notify pgrst,'reload schema';