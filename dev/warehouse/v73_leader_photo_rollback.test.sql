
do $test$
declare actor uuid; w uuid; devkey uuid:=gen_random_uuid(); farm_sku uuid; food_sku uuid; personal_sku uuid; farmid uuid; photoid uuid; foodid uuid; pid uuid; round_v date; d date:=(now() at time zone 'Asia/Kuala_Lumpur')::date; tok text:=left(replace(gen_random_uuid()::text,'-',''),10); img text:=encode(decode('ffd8ffe000ffd9','hex'),'base64'); cmd jsonb; res jsonb; x jsonb; n int:=0; caught boolean; basecount bigint; paycount bigint; salcount bigint; cid uuid:=gen_random_uuid();
begin
 begin
 select id into actor from public.hub_app_user where role='OWNER' and status='ACTIVE' order by id limit 1;
 perform set_config('request.jwt.claim.sub',actor::text,true);perform set_config('request.jwt.claims',jsonb_build_object('sub',actor,'role','authenticated')::text,true);
 insert into public.hub_worker(name,worker_type,join_date,cost_co) values('PHOTO_ROLLBACK_'||tok,'FOREIGN',d,'AD') returning id into w;
 insert into public.hub_worker_farm(worker_id,farm_id,effective_from) values(w,(select id from public.hub_farm where code='AD 1'),to_char(d,'YYYY-MM'));
 insert into owner_data.shop_leader(worker_id,role,farm_code) values(w,'LEADER','AD 1');
 insert into owner_data.shop_device(device_key,worker_id,status,unlocked_on,farm_code) values(devkey,w,'ACTIVE',d,'AD 1');
 insert into public.hub_option(list_code,code,label) values('FARM_ITEM','PHOTO_TEST_'||tok,'PHOTO TEST') returning id into farm_sku;
 insert into public.hub_option(list_code,code,label) values('FOOD_ITEM','PHOTO_FOOD_'||tok,'PHOTO FOOD') returning id into food_sku;
 insert into public.hub_option(list_code,code,label) values('PERSONAL_ITEM','PHOTO_PERSONAL_'||tok,'PHOTO PERSONAL') returning id into personal_sku;
 select count(*) into paycount from owner_data.shop_payment;select count(*) into salcount from public.salary_personal;
 round_v:=owner_data.shop_food_round(d);
 -- Phone-authenticated all four categories in one atomic transaction.
 cmd:=jsonb_build_object('device_key',devkey,'farm','AD 1','manager',false,'op_id',gen_random_uuid(),'requests',jsonb_build_array(
 jsonb_build_object('client_id',cid,'kind','FARM','qty',2,'photos',jsonb_build_array(img,img)),
 jsonb_build_object('client_id',gen_random_uuid(),'kind','PERSONAL','item_id',personal_sku,'qty',1,'workers',jsonb_build_array(w),'photos',jsonb_build_array(img)),
 jsonb_build_object('client_id',gen_random_uuid(),'kind','SHARED','qty',1,'photos',jsonb_build_array(img)),
 jsonb_build_object('client_id',gen_random_uuid(),'kind','FOOD','qty',3,'round',round_v,'photos',jsonb_build_array(img))));
 res:=public.shop_leader_submit(cmd);if (res->>'count')::int<>4 or public.shop_leader_submit(cmd)<>res then raise exception 'atomic retry failed';end if;n:=n+1;
 select id into photoid from owner_data.shop_request where client_id=cid;
 if owner_data.shop_photo_count(photoid)<>2 or (select custom_name from owner_data.shop_request where id=photoid)<>'PHOTO REQUEST' or (select owner_data.shop_wh_review(r) from owner_data.shop_request r where id=photoid)<>'PHOTO' then raise exception 'photo only failed';end if;n:=n+1;
 if jsonb_array_length(public.shop_request_photo_get(jsonb_build_object('device_key',devkey,'farm','AD 1','request_id',photoid)))<>2 then raise exception 'photo read failed';end if;n:=n+1;
 caught:=false;begin perform public.shop_request_photo_get(jsonb_build_object('device_key',devkey,'farm','AD 2','request_id',photoid));exception when others then caught:=true;end;
 if not caught then raise exception 'wrong farm access allowed';end if;n:=n+1;
 caught:=false;begin perform public.shop_request_photo_get(jsonb_build_object('device_key',gen_random_uuid(),'farm','AD 1','request_id',photoid));exception when others then caught:=true;end;
 if not caught then raise exception 'unapproved phone access allowed';end if;n:=n+1;
 x:=public.shop_hello(jsonb_build_object('device_key',devkey,'farm','AD 1'));if exists(select 1 from jsonb_array_elements(x->'lines') a where a ? 'buy_price' or a ? 'sell_price' or a ? 'pay_id') then raise exception 'price leaked';end if;n:=n+1;
 caught:=false;begin perform public.shop_owner_buy(jsonb_build_object('ids',jsonb_build_array(photoid),'price',10,'paid_by','TBF','client_id',gen_random_uuid()));exception when others then if sqlerrm not like 'Resolve the request review%' then raise;end if;caught:=true;end;
 if not caught then raise exception 'unidentified item buy allowed';end if;n:=n+1;
 res:=public.shop_owner_photo_identify(jsonb_build_object('request_id',photoid,'item_id',farm_sku));
 if (select option_id from owner_data.shop_request where id=photoid)<>farm_sku or owner_data.shop_photo_count(photoid)<>2 or exists(select 1 from owner_data.shop_item_photo where option_id=farm_sku) then raise exception 'identify overwrote photo';end if;n:=n+1;
 select id into foodid from owner_data.shop_request where kind='FOOD' and client_id=(cmd->'requests'->3->>'client_id')::uuid;
 perform public.shop_owner_photo_identify(jsonb_build_object('request_id',foodid,'label','PHOTO NEW FOOD '||tok,'unit','PACK','supplier','Grocery'));
 if (select option_id from owner_data.shop_request where id=foodid) is null then raise exception 'food identification failed';end if;n:=n+1;
 -- Isolate grocery save from existing production round: synthetic test uses AD3 manager for baseline only when no open order.
 select count(*) into basecount from owner_data.shop_request;
 caught:=false;begin perform public.shop_leader_submit(jsonb_build_object('manager',true,'farm','AD 1','op_id',gen_random_uuid(),'requests',jsonb_build_array(jsonb_build_object('client_id',gen_random_uuid(),'kind','FARM','qty',1,'item_id',farm_sku),jsonb_build_object('client_id',gen_random_uuid(),'kind','FARM','qty',1,'photos',jsonb_build_array('bad')))));exception when others then caught:=true;end;
 if not caught or (select count(*) from owner_data.shop_request)<>basecount then raise exception 'partial invalid batch saved';end if;n:=n+1;
 caught:=false;begin perform public.shop_leader_food_save(jsonb_build_object('manager',true,'farm','AD 1','op_id',gen_random_uuid(),'round',round_v-1,'baseline','[]'::jsonb,'items','{}'::jsonb));exception when others then if sqlerrm not like 'Food round changed%' then raise;end if;caught:=true;end;
 if not caught then raise exception 'wrong round accepted';end if;n:=n+1;
 cmd:=jsonb_build_object('manager',true,'farm','AD 1','op_id',gen_random_uuid(),'round',round_v,'baseline',coalesce((select jsonb_agg(jsonb_build_array(r.id,r.qty) order by r.id) from owner_data.shop_request r where r.farm_code='AD 1' and r.kind='FOOD' and r.round=round_v and r.status='REQUESTED' and owner_data.shop_photo_count(r.id)=0 and r.option_id is not null),'[]'::jsonb),'items',jsonb_build_object(food_sku::text,2));
 res:=public.shop_leader_food_save(cmd);if public.shop_leader_food_save(cmd)<>res or (select status from owner_data.shop_request where id=foodid)<>'REQUESTED' then raise exception 'food retry deleted photo request';end if;n:=n+1;
 caught:=false;begin perform public.shop_leader_food_save(cmd||jsonb_build_object('op_id',gen_random_uuid()));exception when others then if sqlerrm not like 'Food list changed%' then raise;end if;caught:=true;end;
 if not caught then raise exception 'stale food overwrite allowed';end if;n:=n+1;
 if (select count(*) from owner_data.shop_payment)<>paycount or (select count(*) from public.salary_personal)<>salcount then raise exception 'photo submit posted money';end if;n:=n+1;
 if has_table_privilege('anon','owner_data.shop_request_photo','SELECT') or has_table_privilege('authenticated','owner_data.shop_request_photo','SELECT') then raise exception 'public photo table access';end if;n:=n+1;
 raise exception using errcode='ZX001',message='PASS '||n;
 exception when sqlstate 'ZX001' then if sqlerrm<>'PASS 15' then raise;end if;end;
end $test$;
select '15 leader photo and grocery transaction checks passed; all fixtures rolled back' result;