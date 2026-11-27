CREATE OR REPLACE FUNCTION public.shop_owner_wh_board(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 perform owner_data.require_shop('shop_wh_board','{}'::jsonb);
 -- Auto-reserve only if there is eligible demand and free physical stock. No salary/payment writes.
 if exists(select 1 from owner_data.shop_request r join owner_data.shop_wh_policy w on w.option_id=r.option_id and w.stock_managed and w.opening_confirmed where r.status='REQUESTED' and r.kind<>'FOOD' and r.bottle_id is null and owner_data.shop_wh_review(r) is null and not exists(select 1 from owner_data.shop_wh_order o where o.request_id=r.id and o.received_qty+o.cancelled_qty<o.qty) and exists(select 1 from owner_data.shop_wh_batch b where b.option_id=r.option_id and b.on_hand>coalesce((select sum(a.qty) from owner_data.shop_wh_alloc a where a.batch_id=b.id and a.status='READY'),0))) then
  perform pg_advisory_xact_lock(27112026,64);
  perform set_config('owner_data.wh_internal','1',true);
  perform owner_data.shop_wh_allocate(null);
  perform set_config('owner_data.wh_internal','0',true);
 end if;
 return jsonb_build_object(
 'policy',coalesce((select jsonb_agg(to_jsonb(w) order by w.option_id) from owner_data.shop_wh_policy w),'[]'::jsonb),
 'stock',coalesce((select jsonb_agg(z order by z->>'item') from (
  select jsonb_build_object('item_id',w.option_id,'item',o.label,'kind',owner_data.shop_kind(o.list_code),'unit',u.unit,'opening_confirmed',w.opening_confirmed,
  'physical',coalesce((select sum(b.on_hand) from owner_data.shop_wh_batch b where b.option_id=w.option_id),0),
  'reserved',coalesce((select sum(a.qty) from owner_data.shop_wh_alloc a join owner_data.shop_wh_batch b on b.id=a.batch_id where b.option_id=w.option_id and a.status='READY'),0),
  'cost',coalesce((select sum(b.on_hand*b.unit_cost) from owner_data.shop_wh_batch b where b.option_id=w.option_id),0),
  'minimum',w.minimum_qty,'pack',w.pack_qty,'price_mode',w.price_mode,'fixed_sell',w.fixed_sell,
  'inbound',coalesce((select sum(qty-received_qty-cancelled_qty) from owner_data.shop_wh_order x where x.option_id=w.option_id and x.stock_order),0)) z
  from owner_data.shop_wh_policy w join public.hub_option o on o.id=w.option_id left join owner_data.shop_item_unit u on u.option_id=w.option_id where w.stock_managed) s),'[]'::jsonb),
 'batches',coalesce((select jsonb_agg(to_jsonb(b)||jsonb_build_object('reserved',coalesce((select sum(a.qty) from owner_data.shop_wh_alloc a where a.batch_id=b.id and a.status='READY'),0)) order by b.received_on,b.created_at) from owner_data.shop_wh_batch b where b.on_hand>0),'[]'::jsonb),
 'orders',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('remaining',o.qty-o.received_qty-o.cancelled_qty,'received_cost',coalesce((select sum(x.qty*x.unit_cost) from owner_data.shop_wh_receipt x where x.order_id=o.id),0),'paid',coalesce((select sum(owner_data.shop_wh_payment_net(m.id)) from owner_data.shop_wh_pay x join owner_data.shop_payment m on m.id=x.payment_id where x.order_id=o.id and m.voided_at is null),0)) order by o.ordered_on desc,o.created_at desc) from owner_data.shop_wh_order o),'[]'::jsonb),
 'links',coalesce((select jsonb_agg(jsonb_build_object('request_id',r.id,'root_id',coalesce(t.root_id,r.id),'original_qty',coalesce(rt.original_qty,r.qty),'ordered',exists(select 1 from owner_data.shop_wh_order o where o.request_id=r.id and o.received_qty+o.cancelled_qty<o.qty),'allocation',a.status,'receipt',(r.wh_receipt_parent is not null or exists(select 1 from owner_data.shop_wh_receipt x where x.request_id=r.id)),'fixed_sell',r.wh_fixed_sell,'review',owner_data.shop_wh_review(r))) from owner_data.shop_request r left join owner_data.shop_wh_part t on t.request_id=r.id left join owner_data.shop_wh_root rt on rt.request_id=t.root_id left join owner_data.shop_wh_alloc a on a.request_id=r.id where r.status in ('REQUESTED','BOUGHT')),'[]'::jsonb),
 'order_payments',coalesce((select jsonb_agg(jsonb_build_object('payment_id',m.id,'order_id',wp.order_id,'date',m.paid_on,'ref',wp.ref,'payer',m.payer,'source',m.source,'gross',m.amount,'net',owner_data.shop_wh_payment_net(m.id),'reimbursed',m.reimb_id is not null)) from owner_data.shop_wh_pay wp join owner_data.shop_payment m on m.id=wp.payment_id where m.voided_at is null),'[]'::jsonb),
 'refunds',coalesce((select jsonb_agg(to_jsonb(f) order by f.created_at desc) from owner_data.shop_wh_refund f),'[]'::jsonb),
 'returns',coalesce((select jsonb_agg(to_jsonb(z) order by z.created_at desc) from owner_data.shop_wh_reversal z),'[]'::jsonb),
 'issued',coalesce((select jsonb_agg(jsonb_build_object('request_id',r.id,'item',coalesce((select label from public.hub_option where id=r.option_id),r.custom_name),'farm',r.farm_code,'kind',r.kind,'worker',(select name from public.hub_worker where id=r.worker_id),'qty',r.qty,'date',(r.handed_at at time zone 'Asia/Kuala_Lumpur')::date,'worker_paid',r.worker_paid,'cost',r.buy_price,'returned',exists(select 1 from owner_data.shop_wh_reversal z where z.request_id=r.id))) from owner_data.shop_request r join owner_data.shop_wh_alloc a on a.request_id=r.id where r.status='CONFIRMED'),'[]'::jsonb),
 'adjustments',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (select * from owner_data.shop_wh_adjust order by created_at desc limit 100) x),'[]'::jsonb)
 );
end $function$;
