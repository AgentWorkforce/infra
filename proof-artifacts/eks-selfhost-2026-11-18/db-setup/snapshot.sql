\c ar_dummy
select count(*) from inventory;
select md5(string_agg(id||item||qty, ',' order by id)) from inventory;
select datname, datacl from pg_database where datname='ar_dummy';
select * from pg_default_acl;
select tableowner from pg_tables where tablename='inventory';
select relacl from pg_class where relname='inventory';
