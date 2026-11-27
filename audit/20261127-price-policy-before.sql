-- Rollback definitions: 2026-11-27 before price policy fix
-- Prior price policies: []
CREATE OR REPLACE FUNCTION public.shop_owner_buy(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_ids uuid[]; v_price numeric(10,2); v_n int; v_by text := owner_data.shop_payer(p->>'paid_by'); v_pay uuid; v_total numeric(12,2) := 0;
  r owner_data.shop_request; v_p numeric(10,2); v_label text; v_client uuid; v_date date; v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  v_bottles uuid[] := '{}'; v_bp numeric(10,2); v_purpose text := coalesce(nullif(p->>'purpose',''), 'PURCHASE'); v_s numeric(10,2);
begin
  perform owner_data.require_shop('shop_buy', p);
  begin v_client := nullif(p->>'client_id','')::uuid; v_date := coalesce(nullif(p->>'date','')::date, v_today);
  exception when others then raise exception 'Bad request'; end;
  if v_client is not null and exists (select 1 from owner_data.shop_payment where client_id = v_client) then
    return jsonb_build_object('ok', true, 'repeat', true);
  end if;
  if v_date > v_today or v_date < v_today - 60 then raise exception 'Date must be within the last 60 days'; end if;
  if v_by is null then raise exception 'Pick who paid: TBF, LEX, LZF or Petty Cash'; end if;
  if v_purpose not in ('PURCHASE','MEDICAL') then raise exception 'Bad request'; end if;
  select array_agg(distinct (x)::uuid) into v_ids from jsonb_array_elements_text(coalesce(p->'ids','[]'::jsonb)) x;
  if coalesce(array_length(v_ids,1),0) = 0 then raise exception 'Tick at least one'; end if;
  -- a bottle is bought whole
  select array_agg(distinct r2.id) into v_ids from owner_data.shop_request r2
   where r2.id = any(v_ids) or (r2.bottle_id is not null and r2.status = 'REQUESTED'
         and r2.bottle_id in (select r3.bottle_id from owner_data.shop_request r3 where r3.id = any(v_ids)));
  v_price := round(nullif(p->>'price','')::numeric, 2);
  v_pay := owner_data.shop_pay_new(v_by, 0, v_purpose, null, v_date, p->>'ref', v_client);
  for r in select * from owner_data.shop_request where id = any(v_ids) order by created_at for update loop
    v_s := null;
    if r.status <> 'REQUESTED' then raise exception 'Some lines were already handled — reload'; end if;
    if exists (select 1 from public.hub_option o where o.id = r.option_id and o.code = 'TOP UP') then
      raise exception 'TOP UP is confirmed on the TOP UP page';
    end if;
    if r.bottle_id is not null then
      v_bp := round(coalesce(nullif(p->'bottle_prices'->>(r.bottle_id::text),'')::numeric, v_price), 2);
      if v_bp is null or v_bp <= 0 or v_bp > 5000 then raise exception 'Enter the actual price of each bottle'; end if;
      v_p := round(v_bp / r.bottle_n, 2);
      if not (r.bottle_id = any(v_bottles)) then v_bottles := v_bottles || r.bottle_id; v_total := v_total + v_bp; end if;
    else
      v_p := round(coalesce(nullif(p->'prices'->>(r.id::text),'')::numeric, v_price), 2);
      if v_p is null or v_p <= 0 or v_p > 5000 then raise exception 'Enter the actual price'; end if;
      v_total := v_total + r.qty * v_p; v_bp := null;
      if r.kind = 'PERSONAL' then
        v_s := round(nullif(p->'sells'->>(r.id::text),'')::numeric, 2);
        if v_s is not null and (v_s <= 0 or v_s > 5000) then raise exception 'Enter the sell price (what the worker pays)'; end if;
      end if;
    end if;
    v_label := coalesce((select o.label from public.hub_option o where o.id = r.option_id), r.custom_name);
    update owner_data.shop_request
       set status = 'BOUGHT', bought_at = now(), bought_by = auth.uid(), buy_price = v_p, pay_id = v_pay, sell_price = v_s,
           buy = jsonb_build_object('price', v_p, 'paid_by', v_by, 'date', v_date,
                                    'default', (select sp.price from owner_data.shop_price sp where sp.option_id = r.option_id and sp.voided_at is null and sp.is_default limit 1))
                 || case when v_bp is not null then jsonb_build_object('bottle_price', v_bp) else '{}'::jsonb end
     where id = r.id;
  end loop;
  update owner_data.shop_payment set amount = v_total,
         label = (select string_agg(distinct coalesce(o.label, q.custom_name), ', ') from owner_data.shop_request q left join public.hub_option o on o.id = q.option_id where q.pay_id = v_pay)
   where id = v_pay;
  return jsonb_build_object('ok', true, 'count', array_length(v_ids,1), 'pay_id', v_pay, 'amount', v_total);
end $function$
;
CREATE OR REPLACE FUNCTION public.shop_owner_hand(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date; v_date date; v_month text;
  x jsonb; r owner_data.shop_request; v_label text; v_price numeric(10,2); v_total numeric(12,2); v_sell numeric(10,2); v_charge numeric(12,2);
  v_ids uuid[]; v_all uuid[]; v_pid text; v_fid text; v_entry uuid; v_cost uuid; v_share uuid; v_n int := 0; v_wpaid boolean;
  g record;
begin
  perform owner_data.require_shop('shop_hand', p);
  begin v_date := coalesce((p->>'date')::date, v_today); exception when others then raise exception 'Invalid date'; end;
  if v_date > v_today then raise exception 'Date cannot be in the future'; end if;
  v_month := to_char(v_date, 'YYYY-MM');
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then raise exception 'Tick at least one'; end if;

  create temp table if not exists _food (id uuid, farm text, round date, total numeric, ids uuid[]) on commit drop;
  delete from _food;

  for x in select * from jsonb_array_elements(p->'lines') loop
    select * into r from owner_data.shop_request where id = (x->>'id')::uuid and status = 'BOUGHT' for update;
    if r.id is null then raise exception 'A line was already handed over — reload'; end if;
    v_label := coalesce((select o.label from public.hub_option o where o.id = r.option_id), r.custom_name);
    v_price := coalesce(r.buy_price, (r.buy->>'price')::numeric); v_total := r.qty * v_price;
    if r.kind <> 'FARM' and public.salary_month_locked(v_month) then raise exception '% is closed', v_month; end if;

    if r.kind in ('SHARED','FOOD') and v_month >= '2026-11' then
      v_ids := owner_data.shop_month_food_ids(v_month,jsonb_build_object('date',v_date));
      if cardinality(v_ids)=0 then raise exception 'No eligible attendance; check attendance before recording shared costs'; end if;
    elsif r.kind in ('SHARED','FOOD') then
      select array_agg(distinct (y)::uuid) into v_ids from jsonb_array_elements_text(coalesce(x->'share_ids','[]'::jsonb)) y;
      if coalesce(array_length(v_ids,1),0) = 0 then raise exception 'Tick at least one worker for %', v_label; end if;
      if exists (select 1 from unnest(v_ids) i where owner_data.shop_worker_farm(i) is distinct from r.farm_code) then
        raise exception 'Worker is not on %', r.farm_code;
      end if;
    end if;

    if r.kind = 'PERSONAL' then
      v_wpaid := coalesce((x->>'worker_paid')::boolean, false);
      if r.bottle_id is not null then
        v_sell := owner_data.shop_whiskey_rate(r.bottle_n);                    -- fixed share, not editable
      else
        v_sell := round(coalesce(nullif(x->>'sell','')::numeric, r.sell_price,
                    (select sp.price from owner_data.shop_price sp where sp.option_id = r.option_id and sp.voided_at is null and sp.is_default limit 1)), 2);
      end if;
      if v_sell is null or v_sell <= 0 or v_sell > 5000 then raise exception 'Set the sell price for %', v_label; end if;
      v_charge := r.qty * v_sell;
      if v_wpaid then
        v_pid := null;
      else
        v_pid := 'p_' || (extract(epoch from clock_timestamp()) * 1000)::bigint || '_' || substr(md5(random()::text), 1, 3);
        insert into public.salary_personal (id, worker_id, month, data)
        values (v_pid, r.worker_id, v_month, jsonb_build_object('id', v_pid, 'date', v_date,
                'description', v_label || case when r.bottle_n > 1 then ' (share 1/' || r.bottle_n || ')' when r.qty > 1 then ' × ' || r.qty else '' end,
                'amount', v_charge));
      end if;
      insert into owner_data.shop_entry (client_id, device_id, farm_code, worker_id, option_id, item, buy_date, qty, unit_price, default_price, amount, personal_id)
      values (r.client_id, r.device_id, r.farm_code, r.worker_id, r.option_id,
              v_label || case when v_wpaid then ' (worker paid)' else '' end, v_date, r.qty, v_sell, v_price, v_charge, v_pid)
      returning id into v_entry;
      update owner_data.shop_request set status = 'CONFIRMED', decided_at = now(), handed_at = now(), handed_by = auth.uid(), entry_id = v_entry,
             sell_price = v_sell, worker_paid = v_wpaid where id = r.id;
    elsif r.kind = 'SHARED' then
      select coalesce(array_agg(w.id), '{}') into v_all from public.hub_worker w where w.voided_at is null and not (w.id = any(v_ids));
      v_fid := 'f_' || (extract(epoch from clock_timestamp()) * 1000)::bigint || '_' || substr(md5(random()::text), 1, 3);
      insert into public.salary_food (id, month, data)
      values (v_fid, v_month, jsonb_build_object('id', v_fid, 'date', v_date, 'vendor', '',
              'description', r.farm_code || ' · ' || v_label || case when r.qty > 1 then ' × ' || r.qty else '' end,
              'qty', 1, 'unitPrice', v_total, 'total', v_total, 'workerIds', to_jsonb(v_ids), 'autoSel', false,
              'addIds', to_jsonb(v_ids), 'removeIds', to_jsonb(v_all)));
      insert into owner_data.shop_share (farm_code, item, amount, buy_date, worker_ids, food_id, created_by)
      values (r.farm_code, v_label || case when r.qty > 1 then ' × ' || r.qty else '' end, v_total, v_date, v_ids, v_fid, auth.uid())
      returning id into v_share;
      update owner_data.shop_request set status = 'CONFIRMED', decided_at = now(), handed_at = now(), handed_by = auth.uid(), share_id = v_share where id = r.id;
    elsif r.kind = 'FOOD' then
      insert into _food values (r.id, r.farm_code, r.round, v_total, v_ids);
    else
      insert into owner_data.farm_cost (farm_code, option_id, item, qty, unit_price, amount, buy_date, request_id, created_by)
      values (r.farm_code, r.option_id, v_label, r.qty, v_price, v_total, v_date, r.id, auth.uid())
      returning id into v_cost;
      update owner_data.shop_request set status = 'CONFIRMED', decided_at = now(), handed_at = now(), handed_by = auth.uid(), cost_id = v_cost where id = r.id;
    end if;
    v_n := v_n + 1;
  end loop;

  for g in select farm, round, sum(total) total, array_agg(id) line_ids from _food group by farm, round loop
    select f.ids into v_ids from _food f where f.farm = g.farm and f.round = g.round order by f.id limit 1;
    select coalesce(array_agg(w.id), '{}') into v_all from public.hub_worker w where w.voided_at is null and not (w.id = any(v_ids));
    v_fid := 'f_' || (extract(epoch from clock_timestamp()) * 1000)::bigint || '_' || substr(md5(random()::text), 1, 3);
    insert into public.salary_food (id, month, data)
    values (v_fid, v_month, jsonb_build_object('id', v_fid, 'date', v_date, 'vendor', 'Groceries',
            'description', g.farm || ' · Groceries ' || to_char(g.round, 'DD/MM'),
            'qty', 1, 'unitPrice', g.total, 'total', g.total, 'workerIds', to_jsonb(v_ids), 'autoSel', false,
            'addIds', to_jsonb(v_ids), 'removeIds', to_jsonb(v_all)));
    insert into owner_data.shop_share (farm_code, item, amount, buy_date, worker_ids, food_id, created_by)
    values (g.farm, 'Groceries ' || to_char(g.round, 'DD/MM'), g.total, v_date, v_ids, v_fid, auth.uid())
    returning id into v_share;
    update owner_data.shop_request set status = 'CONFIRMED', decided_at = now(), handed_at = now(), handed_by = auth.uid(), share_id = v_share
     where id = any(g.line_ids);
  end loop;
  delete from _food;
  return jsonb_build_object('ok', true, 'count', v_n, 'month', v_month);
end $function$
;
CREATE OR REPLACE FUNCTION public.shop_owner_spot(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_farm text := p->>'farm'; v_kind text := p->>'kind'; v_opt uuid; v_custom text; v_qty int := coalesce((p->>'qty')::int, 1);
  v_wid uuid; v_id uuid; v_price numeric(10,2); v_detail text := nullif(btrim(regexp_replace(coalesce(p->>'detail',''), '\s+', ' ', 'g')), '');
  v_client uuid := gen_random_uuid(); v_code text; b jsonb; v_bi int := 0; v_lines jsonb := '[]'::jsonb; v_ids jsonb := '[]'::jsonb; v_bottles jsonb := '{}'::jsonb; v_c uuid;
begin
  perform owner_data.require_shop('shop_spot', p);
  if v_farm not in ('AD 1','AD 2','AD 3') or v_kind not in ('PERSONAL','SHARED','FARM') then raise exception 'Bad request'; end if;
  if nullif(p->>'item_id','') is not null then
    select id, code into v_opt, v_code from public.hub_option where id = (p->>'item_id')::uuid and list_code = owner_data.shop_list(v_kind) and code <> 'PINJAM';
    if v_opt is null then raise exception 'Unknown item'; end if;
  else
    v_custom := upper(regexp_replace(trim(coalesce(p->>'custom_name','')), '\s+', ' ', 'g'));
    if v_custom = '' or length(v_custom) > 40 then raise exception 'Type the item name'; end if;
  end if;
  if v_code = 'TOP UP' then raise exception 'TOP UP is confirmed on the TOP UP page'; end if;
  if v_qty < 1 or v_qty > 999 then raise exception 'Check the quantity'; end if;
  if length(v_detail) > 80 then raise exception 'Detail is too long'; end if;

  if v_code = 'WHISKEY' and v_kind = 'PERSONAL' then
    -- p.bottles: [[worker ids], ...] each 1–3 people; TAKEN needs p.bottle_prices: [price per bottle in the same order]
    if jsonb_typeof(p->'bottles') <> 'array' or jsonb_array_length(p->'bottles') = 0 then raise exception 'Pick who shares each bottle'; end if;
    for b in select * from jsonb_array_elements(p->'bottles') loop
      if jsonb_typeof(b) <> 'array' or jsonb_array_length(b) not between 1 and 3 then raise exception 'One bottle is for 1 to 3 people'; end if;
      v_c := gen_random_uuid();
      for v_wid in select distinct (y)::uuid from jsonb_array_elements_text(b) y loop
        if owner_data.shop_worker_farm(v_wid) is distinct from v_farm then raise exception 'Worker is not on %', v_farm; end if;
        insert into owner_data.shop_request (client_id, device_id, made_by, farm_code, worker_id, option_id, qty, kind, detail)
        values (v_c, null, auth.uid(), v_farm, v_wid, v_opt, 1, 'PERSONAL', v_detail) returning id into v_id;
        v_ids := v_ids || to_jsonb(v_id);
        v_lines := v_lines || jsonb_build_object('id', v_id, 'worker_paid', coalesce((p->>'worker_paid')::boolean, false));
      end loop;
      perform owner_data.shop_bottle_tag(v_c);
      if coalesce(p->>'mode','WANT') = 'TAKEN' then
        v_price := round(nullif(p->'bottle_prices'->>v_bi, '')::numeric, 2);
        v_bottles := v_bottles || jsonb_build_object((select bottle_id::text from owner_data.shop_request where id = v_id), v_price);
        v_bi := v_bi + 1;
      end if;
    end loop;
    if coalesce(p->>'mode','WANT') = 'TAKEN' then
      perform public.shop_owner_buy(jsonb_build_object('ids', v_ids, 'bottle_prices', v_bottles, 'paid_by', p->>'paid_by'));
      return public.shop_owner_hand(jsonb_build_object('lines', v_lines));
    end if;
    return jsonb_build_object('ok', true, 'count', jsonb_array_length(v_ids));
  end if;

  if v_kind = 'PERSONAL' then
    v_wid := (p->>'worker_id')::uuid;
    if owner_data.shop_worker_farm(v_wid) is distinct from v_farm then raise exception 'Worker is not on %', v_farm; end if;
  end if;
  insert into owner_data.shop_request (client_id, device_id, made_by, farm_code, worker_id, option_id, custom_name, qty, kind, detail)
  values (v_client, null, auth.uid(), v_farm, v_wid, v_opt, v_custom, v_qty, v_kind, v_detail) returning id into v_id;
  if coalesce(p->>'mode','WANT') = 'TAKEN' then
    v_price := round((p->>'price')::numeric, 2);
    perform public.shop_owner_buy(jsonb_build_object('ids', jsonb_build_array(v_id), 'price', v_price, 'paid_by', p->>'paid_by'));
    return public.shop_owner_hand(jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('id', v_id,
             'share_ids', coalesce(p->'share_ids','[]'::jsonb), 'sell', p->>'sell', 'worker_paid', coalesce((p->>'worker_paid')::boolean, false)))));
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $function$
;
CREATE OR REPLACE FUNCTION public.shop_owner_wh(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_action text:=p->>'action'; v_op uuid:=(p->>'op_id')::uuid; v_actor uuid:=auth.uid(); v_today date:=(now() at time zone 'Asia/Kuala_Lumpur')::date;
 v_date date:=coalesce(nullif(p->>'date','')::date,v_today); v_qty int; v_cost numeric; v_sell numeric; v_result jsonb:='{}'; v_id uuid; v_item uuid; v_req uuid; v_payment uuid; v_part uuid; v_batch uuid; v_take int; v_reserved int; v_reason text; v_label text; v_old owner_data.shop_wh_op; r owner_data.shop_request; o owner_data.shop_wh_order; b owner_data.shop_wh_batch; pol owner_data.shop_wh_policy; opt public.hub_option; v_flag boolean; v_mode text; v_min int; v_pack int; v_n int; v_open boolean;
begin
 if v_actor is null or not public.shop_is_manager() then raise exception 'Not allowed';end if;
 if v_op is null then raise exception 'Operation ID required';end if;
 perform pg_advisory_xact_lock(27112026,64);
 select * into v_old from owner_data.shop_wh_op where id=v_op;
 if found then
  if v_old.actor<>v_actor or v_old.payload<>p then raise exception 'Operation ID already used with different parameters';end if;
  return v_old.result;
 end if;
 if v_date>v_today then raise exception 'Date cannot be in the future';end if;
 perform owner_data.require_shop('shop_wh_'||coalesce(v_action,'unknown'),jsonb_build_object('op_id',v_op));
 perform set_config('owner_data.wh_internal','1',true);
 if v_action='POLICY' then
  v_item:=(p->>'item_id')::uuid;v_flag:=coalesce((p->>'stock')::boolean,false);v_mode:=p->>'price_mode';v_sell:=nullif(p->>'fixed_sell','')::numeric;v_min:=nullif(p->>'minimum','')::int;v_pack:=nullif(p->>'pack','')::int;
  select * into opt from public.hub_option where id=v_item and list_code in ('PERSONAL_ITEM','FARM_ITEM','SHARED_ITEM') and shown;
  if opt.id is null or upper(opt.code) in ('TOP UP','WHISKEY','PINJAM','UBAT','DOCTOR','SIM CARD') then raise exception 'Special or unknown item — cannot use stock policy';end if;
  if v_mode not in ('FIXED','VARIABLE') or v_mode is null then raise exception 'Choose price mode';end if;
  if opt.list_code<>'PERSONAL_ITEM' then v_mode:='VARIABLE';v_sell:=null;end if;
  if v_mode='FIXED' and (v_sell is null or v_sell<=0 or v_sell>5000 or v_sell<>round(v_sell,2)) then raise exception 'Enter fixed selling price';end if;
  if v_mode='VARIABLE' then v_sell:=null;end if;
  select * into pol from owner_data.shop_wh_policy where option_id=v_item for update;
  if pol.option_id is not null and pol.stock_managed<>v_flag and (exists(select 1 from owner_data.shop_wh_batch where option_id=v_item and on_hand>0) or exists(select 1 from owner_data.shop_wh_order where option_id=v_item and received_qty+cancelled_qty<qty) or exists(select 1 from owner_data.shop_wh_alloc a join owner_data.shop_wh_batch z on z.id=a.batch_id where z.option_id=v_item and a.status='READY')) then raise exception 'Resolve stock and open orders before changing fulfilment mode';end if;
  insert into owner_data.shop_wh_policy(option_id,stock_managed,price_mode,fixed_sell,minimum_qty,pack_qty,opening_confirmed,updated_by)
  values(v_item,v_flag,v_mode,v_sell,v_min,v_pack,case when v_flag and coalesce(pol.stock_managed,false) then pol.opening_confirmed else false end,v_actor)
  on conflict(option_id) do update set stock_managed=excluded.stock_managed,price_mode=excluded.price_mode,fixed_sell=excluded.fixed_sell,minimum_qty=excluded.minimum_qty,pack_qty=excluded.pack_qty,opening_confirmed=excluded.opening_confirmed,updated_by=v_actor,updated_at=now();
 elsif v_action='OPENING' then
  v_item:=(p->>'item_id')::uuid;v_qty:=(p->>'qty')::int;v_cost:=nullif(p->>'unit_cost','')::numeric;v_reason:=btrim(coalesce(p->>'reason',''));
  select * into pol from owner_data.shop_wh_policy where option_id=v_item for update;
  if not coalesce(pol.stock_managed,false) or pol.opening_confirmed then raise exception 'Opening stock already confirmed or item not stock-managed';end if;
  if v_qty is null or v_qty<0 or v_qty>99999 or length(v_reason)<1 then raise exception 'Enter verified opening quantity and evidence';end if;
  if v_qty>0 then
   if v_cost is null or v_cost<=0 or v_cost>5000 or v_cost<>round(v_cost,2) then raise exception 'Verified actual opening unit cost required';end if;
   insert into owner_data.shop_wh_batch(option_id,received_on,original_qty,on_hand,unit_cost,source,ref,created_by) values(v_item,v_date,v_qty,v_qty,v_cost,'OPENING',left(v_reason,300),v_actor) returning id into v_batch;
  end if;
  update owner_data.shop_wh_policy set opening_confirmed=true,updated_at=now(),updated_by=v_actor where option_id=v_item;
  perform owner_data.shop_wh_allocate(v_item);
  v_result:=jsonb_build_object('batch_id',v_batch);
 elsif v_action='SYNC' then
  v_n:=owner_data.shop_wh_allocate(null);v_result:=jsonb_build_object('reserved_qty',v_n);
 elsif v_action='ORDER' then
  v_req:=nullif(p->>'request_id','')::uuid;v_item:=nullif(p->>'item_id','')::uuid;v_qty:=(p->>'qty')::int;
  if v_qty is null or v_qty<1 or v_qty>99999 or length(btrim(coalesce(p->>'supplier',''))) not between 1 and 100 then raise exception 'Enter order quantity and supplier';end if;
  if v_req is not null then
   select * into r from owner_data.shop_request where id=v_req for update;
   if r.id is null or r.status<>'REQUESTED' or r.kind='FOOD' or r.bottle_id is not null or owner_data.shop_wh_review(r) is not null then raise exception 'Request not eligible for supplier order';end if;
   v_item:=r.option_id;
   if exists(select 1 from public.hub_option where id=v_item and code in ('TOP UP','WHISKEY')) then raise exception 'Use existing special-item flow';end if;
   if exists(select 1 from owner_data.shop_wh_order where request_id=r.id and received_qty+cancelled_qty<qty) then raise exception 'Already ordered';end if;
   if v_qty>r.qty then raise exception 'Order the shortage only; extra stock is separate replenishment';end if;
   v_req:=owner_data.shop_wh_split(r.id,v_qty);
   v_label:=coalesce((select label from public.hub_option where id=v_item),r.custom_name);
  else
   select label into v_label from public.hub_option where id=v_item and shown;
   if v_label is null then raise exception 'Unknown item';end if;
  end if;
  select * into pol from owner_data.shop_wh_policy where option_id=v_item;
  v_flag:=coalesce(pol.stock_managed,false);
  if v_req is null and not v_flag then raise exception 'Only stock-managed goods can be replenished without a request';end if;
  if v_flag and not pol.opening_confirmed then raise exception 'Confirm actual opening stock first';end if;
  if v_flag and v_req is not null and exists(select 1 from owner_data.shop_wh_batch wb where wb.option_id=v_item and wb.on_hand>coalesce((select sum(wa.qty) from owner_data.shop_wh_alloc wa where wa.batch_id=wb.id and wa.status='READY'),0)) then raise exception 'Available stock exists — refresh and reserve before ordering';end if;
  insert into owner_data.shop_wh_order(option_id,request_id,item,supplier,ordered_on,qty,ref,created_by,stock_order)
  values(v_item,v_req,v_label,btrim(p->>'supplier'),v_date,v_qty,nullif(left(btrim(coalesce(p->>'ref','')),100),''),v_actor,v_flag) returning id into v_id;
  v_result:=jsonb_build_object('order_id',v_id,'request_id',v_req);
 elsif v_action='RECEIVE' then
  select * into o from owner_data.shop_wh_order where id=(p->>'order_id')::uuid for update;
  v_qty:=(p->>'qty')::int;v_cost:=nullif(p->>'unit_cost','')::numeric;v_sell:=nullif(p->>'sell','')::numeric;
  if o.id is null or v_qty is null or v_qty<1 or v_qty>o.qty-o.received_qty-o.cancelled_qty then raise exception 'Receipt exceeds outstanding order';end if;
  if v_date<o.ordered_on or v_cost is null or v_cost<=0 or v_cost>5000 or v_cost<>round(v_cost,2) then raise exception 'Check receipt date and actual unit cost';end if;
  if o.request_id is not null then
   select * into r from owner_data.shop_request where id=o.request_id for update;
   if r.status<>'REQUESTED' or r.qty<v_qty or owner_data.shop_wh_review(r) is not null then raise exception 'Request changed or needs review';end if;
  end if;
  select * into pol from owner_data.shop_wh_policy where option_id=o.option_id;
  if o.stock_order then
   if not coalesce(pol.stock_managed,false) or not pol.opening_confirmed then raise exception 'Stock policy changed';end if;
   insert into owner_data.shop_wh_batch(option_id,order_id,received_on,original_qty,on_hand,unit_cost,source,ref,created_by) values(o.option_id,o.id,v_date,v_qty,v_qty,v_cost,'RECEIPT',o.ref,v_actor) returning id into v_batch;
   if o.request_id is not null then v_part:=owner_data.shop_wh_reserve(o.request_id,v_batch,v_qty);end if;
  else
   if o.request_id is null or coalesce(pol.stock_managed,false) then raise exception 'Request or stock policy changed';end if;
   if r.kind='PERSONAL' then
    if pol.price_mode='FIXED' then
     if v_sell is not null and v_sell<>pol.fixed_sell then raise exception 'Fixed selling price cannot change';end if;
     v_sell:=pol.fixed_sell;
    end if;
    if v_sell is null or v_sell<=0 or v_sell>5000 or v_sell<>round(v_sell,2) then raise exception 'Enter agreed selling price';end if;
   else v_sell:=null;end if;
   v_part:=owner_data.shop_wh_split(r.id,v_qty);
   update owner_data.shop_request set status='BOUGHT',bought_at=now(),bought_by=v_actor,buy_price=v_cost,sell_price=v_sell,pay_id=null,buy=jsonb_build_object('price',v_cost,'date',v_date,'warehouse_order',o.id) where id=v_part;
  end if;
  update owner_data.shop_wh_order set received_qty=received_qty+v_qty where id=o.id;
  insert into owner_data.shop_wh_receipt(order_id,request_id,batch_id,received_on,qty,unit_cost,sell_price,created_by) values(o.id,v_part,v_batch,v_date,v_qty,v_cost,v_sell,v_actor) returning id into v_id;
  if o.stock_order then perform owner_data.shop_wh_allocate(o.option_id);end if;
  v_result:=jsonb_build_object('receipt_id',v_id,'batch_id',v_batch,'request_id',v_part);
 elsif v_action='PAY' then
  select * into o from owner_data.shop_wh_order where id=(p->>'order_id')::uuid for update;
  v_cost:=nullif(p->>'amount','')::numeric;v_reason:=btrim(coalesce(p->>'ref',''));
  if o.id is null or v_cost is null or v_cost<=0 or v_cost>99999999 or v_cost<>round(v_cost,2) or length(v_reason) not between 1 and 80 or v_date<o.ordered_on then raise exception 'Enter verified actual payment, date and reference';end if;
  if exists(select 1 from owner_data.shop_wh_pay where order_id=o.id and ref=v_reason) then raise exception 'Payment reference already recorded';end if;
  v_payment:=owner_data.shop_pay_new(p->>'payer',v_cost,'PURCHASE',o.item||' · '||o.supplier,v_date,v_reason,v_op);
  insert into owner_data.shop_wh_pay(payment_id,order_id,ref) values(v_payment,o.id,v_reason);
  v_result:=jsonb_build_object('pay_id',v_payment,'amount',v_cost);
 elsif v_action='CANCEL_ORDER' then
  select * into o from owner_data.shop_wh_order where id=(p->>'order_id')::uuid for update;
  v_qty:=(p->>'qty')::int;v_reason:=btrim(coalesce(p->>'reason',''));
  if o.id is null or v_qty is null or v_qty<1 or v_qty>o.qty-o.received_qty-o.cancelled_qty or length(v_reason)<1 then raise exception 'Invalid cancellation';end if;
  if coalesce((select sum(owner_data.shop_wh_payment_net(m.id)) from owner_data.shop_wh_pay w join owner_data.shop_payment m on m.id=w.payment_id where w.order_id=o.id and m.voided_at is null),0)>coalesce((select sum(x.qty*x.unit_cost) from owner_data.shop_wh_receipt x where x.order_id=o.id),0) then raise exception 'Unreconciled supplier advance — actual refund required before cancellation';end if;
  if o.request_id is not null and v_qty<o.qty-o.received_qty-o.cancelled_qty then
   -- Split the cancelled portion so only the remaining ordered quantity retains the order.
   perform owner_data.shop_wh_split(o.request_id,v_qty);
  end if;
  update owner_data.shop_wh_order set cancelled_qty=cancelled_qty+v_qty where id=o.id;
  if o.stock_order then perform owner_data.shop_wh_allocate(o.option_id);end if;
 elsif v_action='ADJUST' then
  v_qty:=(p->>'qty')::int;v_reason:=btrim(coalesce(p->>'reason',''));v_item:=nullif(p->>'item_id','')::uuid;
  if v_qty is null or v_qty=0 or abs(v_qty)>99999 or length(v_reason) not between 1 and 300 then raise exception 'Enter adjustment quantity and reason';end if;
  if v_qty<0 then
   select * into b from owner_data.shop_wh_batch where id=(p->>'batch_id')::uuid for update;
   if b.id is null then raise exception 'Unknown batch';end if;
   select coalesce(sum(qty),0) into v_reserved from owner_data.shop_wh_alloc where batch_id=b.id and status='READY';
   if -v_qty>b.on_hand-v_reserved then raise exception 'Adjustment conflicts with reserved stock';end if;
   update owner_data.shop_wh_batch set on_hand=on_hand+v_qty where id=b.id;v_batch:=b.id;
  else
   select * into pol from owner_data.shop_wh_policy where option_id=v_item for update;
   v_cost:=nullif(p->>'unit_cost','')::numeric;
   if not coalesce(pol.stock_managed,false) or not pol.opening_confirmed or v_cost is null or v_cost<=0 or v_cost>5000 or v_cost<>round(v_cost,2) then raise exception 'Confirmed stock policy and verified cost required';end if;
   insert into owner_data.shop_wh_batch(option_id,received_on,original_qty,on_hand,unit_cost,source,ref,created_by) values(v_item,v_date,v_qty,v_qty,v_cost,'ADJUST_UP',left(v_reason,300),v_actor) returning id into v_batch;
   perform owner_data.shop_wh_allocate(v_item);
  end if;
  insert into owner_data.shop_wh_adjust(batch_id,delta,reason,actual_on,created_by) values(v_batch,v_qty,v_reason,v_date,v_actor);
 elsif v_action='ISSUE' then
  select * into r from owner_data.shop_request where id=(p->>'request_id')::uuid for update;
  if r.id is null or r.status<>'BOUGHT' or not (exists(select 1 from owner_data.shop_wh_alloc where request_id=r.id and status='READY') or r.wh_receipt_parent is not null or exists(select 1 from owner_data.shop_wh_receipt where request_id=r.id)) then raise exception 'Not a warehouse-ready line';end if;
  if r.kind='PERSONAL' and not(coalesce((p->>'worker_paid')::boolean,false) or coalesce((p->>'deduction_authorised')::boolean,false)) then raise exception 'Confirm authorised deduction or worker cash payment';end if;
  v_qty:=coalesce(nullif(p->>'qty','')::int,r.qty);
  v_part:=owner_data.shop_wh_split_ready(r.id,v_qty);
  v_result:=public.shop_owner_hand(jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('id',v_part,'share_ids',coalesce(p->'share_ids','[]'::jsonb),'sell',coalesce(nullif(p->>'sell','')::numeric,r.wh_fixed_sell,r.sell_price),'worker_paid',coalesce((p->>'worker_paid')::boolean,false))),'date',v_date));
 elsif v_action='LINK_ITEM' then
  v_req:=(p->>'request_id')::uuid;v_item:=(p->>'item_id')::uuid;
  select * into r from owner_data.shop_request where id=v_req for update;
  if r.id is null or r.status<>'REQUESTED' or r.option_id is not null or r.kind<>'PERSONAL' then raise exception 'Only unlinked personal request can be linked';end if;
  select * into opt from public.hub_option where id=v_item and list_code='PERSONAL_ITEM' and shown and code not in ('TOP UP','WHISKEY','PINJAM','DOCTOR','UBAT');
  if opt.id is null then raise exception 'Choose the actual matching catalogue item';end if;
  if owner_data.shop_wh_review(r) in ('INSTALMENT','MEDICAL','WORKER') then raise exception 'Resolve special case first';end if;
  v_reason:=btrim(coalesce(p->>'reason',''));if length(v_reason)<1 then raise exception 'Confirm the actual item match';end if;
  update owner_data.shop_request set option_id=v_item where id=v_req;
  insert into owner_data.shop_wh_review_resolution(request_id,mode,reason,created_by) values(v_req,'LINKED',left(v_reason,300),v_actor);
  perform owner_data.shop_wh_allocate(v_item);
 else raise exception 'Unknown Warehouse action';
 end if;
 perform set_config('owner_data.wh_internal','0',true);
 v_result:=jsonb_build_object('ok',true,'op_id',v_op)||v_result;
 insert into owner_data.shop_wh_op(id,actor,payload,result) values(v_op,v_actor,p,v_result);
 return v_result;
end $function$

