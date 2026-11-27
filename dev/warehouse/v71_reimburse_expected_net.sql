CREATE OR REPLACE FUNCTION public.shop_owner_reimburse(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_payer text := owner_data.shop_payer(p->>'payer'); v_ids uuid[]; v_n int; v_amt numeric(12,2); v_b uuid; v_date date;
  v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date; v_client uuid;
begin
  perform owner_data.require_shop('shop_reimburse', p);
  begin v_date := coalesce(nullif(p->>'date','')::date, v_today); v_client := nullif(p->>'client_id','')::uuid;
  exception when others then raise exception 'Bad request'; end;
  if v_client is not null and exists (select 1 from owner_data.shop_reimb where client_id = v_client) then return jsonb_build_object('ok', true, 'repeat', true); end if;
  if v_payer not in ('TBF','LEX','LZF') then raise exception 'Pick TBF, LEX or LZF'; end if;
  if v_date > v_today then raise exception 'Date cannot be in the future'; end if;
  select array_agg(distinct (x)::uuid) into v_ids from jsonb_array_elements_text(coalesce(p->'ids','[]'::jsonb)) x;
  if coalesce(array_length(v_ids,1),0) = 0 then raise exception 'Tick at least one'; end if;
  perform 1 from owner_data.shop_payment where id = any(v_ids) for update;
  select count(*), sum(owner_data.shop_wh_payment_net(id)) into v_n, v_amt from owner_data.shop_payment
   where id = any(v_ids) and voided_at is null and reimb_id is null and source = 'MGMT' and payer = v_payer and owner_data.shop_wh_payment_net(id) > 0;
  if v_n <> array_length(v_ids,1) then raise exception 'Some payments are already reimbursed, undone or not %', v_payer; end if;
  if p ? 'expected_amount' and nullif(p->>'expected_amount','')::numeric is distinct from v_amt then raise exception 'Net reimbursement changed — refresh and verify actual payment'; end if;
  insert into owner_data.shop_reimb (client_id, payer, amount, paid_on, ref, created_by)
  values (v_client, v_payer, v_amt, v_date, nullif(left(btrim(coalesce(p->>'ref','')), 80), ''), auth.uid()) returning id into v_b;
  update owner_data.shop_payment set reimb_id = v_b where id = any(v_ids);
  return jsonb_build_object('ok', true, 'id', v_b, 'amount', v_amt, 'count', v_n);
end $function$;
notify pgrst,'reload schema';