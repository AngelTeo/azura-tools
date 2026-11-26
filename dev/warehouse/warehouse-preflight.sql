-- Kedai Runcit Warehouse integration preflight (read only).
-- Run in authorised Azura Delta project dittqalvrjiamzdzrskd.
-- Contains no business data reads and no mutations.
-- Treat the result as private: review function bodies for embedded secrets;
-- do not commit the raw output to the public repository.
begin transaction read only;
set local statement_timeout = '30s';

with rels as (
  select c.oid, n.nspname as schema_name, c.relname as relation_name,
         c.relkind, c.relrowsecurity, c.relforcerowsecurity
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r','p','v','m')
    and (c.relname ~ '^shop_' or c.relname ~ '^salary_'
         or c.relname in ('hub_worker','hub_option'))
), funcs as (
  select p.oid, n.nspname as schema_name, p.proname,
         pg_catalog.pg_get_function_identity_arguments(p.oid) as signature,
         pg_catalog.pg_get_function_result(p.oid) as result_type,
         p.prosecdef, p.proconfig, p.proacl,
         pg_catalog.pg_get_functiondef(p.oid) as definition
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prokind in ('f','p')
    and (p.proname ~ '^shop_' or p.proname ~ '^salary_')
)
select jsonb_build_object(
 'server_version', current_setting('server_version'),
 'relations', coalesce((select jsonb_agg(to_jsonb(r) - 'oid' order by r.relation_name) from rels r),'[]'::jsonb),
 'columns', coalesce((
   select jsonb_agg(jsonb_build_object(
     'table',r.relation_name,'column',a.attname,
     'type',pg_catalog.format_type(a.atttypid,a.atttypmod),
     'not_null',a.attnotnull,
     'default',pg_catalog.pg_get_expr(d.adbin,d.adrelid)
   ) order by r.relation_name,a.attnum)
   from rels r join pg_catalog.pg_attribute a on a.attrelid=r.oid
   left join pg_catalog.pg_attrdef d on d.adrelid=r.oid and d.adnum=a.attnum
   where a.attnum>0 and not a.attisdropped
 ),'[]'::jsonb),
 'constraints', coalesce((
   select jsonb_agg(jsonb_build_object('table',r.relation_name,'name',c.conname,
      'definition',pg_catalog.pg_get_constraintdef(c.oid)) order by r.relation_name,c.conname)
   from rels r join pg_catalog.pg_constraint c on c.conrelid=r.oid
 ),'[]'::jsonb),
 'indexes', coalesce((
   select jsonb_agg(jsonb_build_object('table',r.relation_name,
      'definition',pg_catalog.pg_get_indexdef(i.indexrelid)) order by r.relation_name,i.indexrelid)
   from rels r join pg_catalog.pg_index i on i.indrelid=r.oid
 ),'[]'::jsonb),
 'triggers', coalesce((
   select jsonb_agg(jsonb_build_object('table',r.relation_name,'name',t.tgname,
      'definition',pg_catalog.pg_get_triggerdef(t.oid)) order by r.relation_name,t.tgname)
   from rels r join pg_catalog.pg_trigger t on t.tgrelid=r.oid
   where not t.tgisinternal
 ),'[]'::jsonb),
 'policies', coalesce((
   select jsonb_agg(to_jsonb(p) order by p.tablename,p.policyname)
   from pg_catalog.pg_policies p join rels r on p.schemaname=r.schema_name and p.tablename=r.relation_name
 ),'[]'::jsonb),
 'table_grants',coalesce((
   select jsonb_agg(to_jsonb(g) order by g.table_name,g.grantee,g.privilege_type)
   from information_schema.role_table_grants g join rels r
     on g.table_schema=r.schema_name and g.table_name=r.relation_name
 ),'[]'::jsonb),
 'functions',coalesce((select jsonb_agg(to_jsonb(f) - 'oid' order by f.proname,f.signature) from funcs f),'[]'::jsonb)
) as warehouse_preflight;

rollback;
