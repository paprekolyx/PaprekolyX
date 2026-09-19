-- ============================================================================
--  PaprekolyX — СКРИПТ 8: статистика заявок и журнал входов администратора
-- ============================================================================
--  ЧАСТЬ 1. Журнал входов в кабинет (без Supabase Auth)
--    Таблица admin_login_log пишется только из функции проверки пароля,
--    поэтому фиксируется каждая попытка входа: успешная и нет.
--    Хранится:
--      attempted_at          — когда;
--      success               — удалось ли войти;
--      user_agent            — браузер и ОС со слов клиента;
--      valid_hash_at_attempt — какой хеш пароля действовал в момент попытки
--                              (позволяет понять, к какой «эпохе» пароля
--                              относится запись, если пароль меняли).
--    Читать журнал может только функция admin_login_log(hash) с верным паролем.
--
--  ЧАСТЬ 2. Функция admin_stats(hash, days) — агрегаты для страницы статистики.
--    Все денежные метрики считаются по суммам ОФОРМЛЕННЫХ заявок:
--    сайт не видит оплаты, они происходят в ВКонтакте.
--
--  Идемпотентен: функции перезаписываются, таблица создаётся если её нет.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Журнал входов
-- ----------------------------------------------------------------------------
create table if not exists public.admin_login_log (
    id                    bigserial primary key,
    attempted_at          timestamptz not null default now(),
    success               boolean not null,
    user_agent            text,
    valid_hash_at_attempt text
);

comment on table public.admin_login_log is 'Попытки входа в кабинет заказов: успешные и нет';

alter table public.admin_login_log enable row level security;
-- Политик НЕТ: пишет только функция проверки пароля, читает только admin_login_log(hash).


-- ----------------------------------------------------------------------------
-- 2. Проверка пароля с журналированием
--    Старая версия без журнала заменяется.
-- ----------------------------------------------------------------------------
drop function if exists public.admin_check_password(text);

create or replace function public.admin_check_password(p_hash_hex text, p_user_agent text default null)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
    v_valid_hash text;
    v_ok         boolean;
begin
    select password_hash into v_valid_hash
    from public.admin_credentials
    where key = 'admin';

    v_ok := v_valid_hash is not null
        and v_valid_hash = lower(coalesce(p_hash_hex, ''));

    insert into public.admin_login_log (success, user_agent, valid_hash_at_attempt)
    values (v_ok, left(coalesce(p_user_agent, ''), 300), v_valid_hash);

    return v_ok;
end;
$$;

grant execute on function public.admin_check_password(text, text) to anon, authenticated;


-- ----------------------------------------------------------------------------
-- 3. Чтение журнала (только с верным паролем)
-- ----------------------------------------------------------------------------
create or replace function public.admin_login_log(p_hash_hex text, p_limit integer default 50)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
    if not exists (select 1 from public.admin_credentials
                    where key = 'admin'
                      and password_hash = lower(coalesce(p_hash_hex, ''))) then
        raise exception 'Неверный пароль' using errcode = '28000';
    end if;

    return coalesce((
        select jsonb_agg(jsonb_build_object(
                   'attempted_at', attempted_at,
                   'success',      success,
                   'user_agent',   user_agent)
                 order by attempted_at desc)
        from (select * from public.admin_login_log
               order by attempted_at desc
               limit least(coalesce(p_limit, 50), 200)) t
    ), '[]'::jsonb);
end;
$$;

grant execute on function public.admin_login_log(text, integer) to anon, authenticated;


-- ----------------------------------------------------------------------------
-- 4. Статистика заявок
-- ----------------------------------------------------------------------------
create or replace function public.admin_stats(p_hash_hex text, p_days integer default null)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
    v_from timestamptz;
begin
    if not exists (select 1 from public.admin_credentials
                    where key = 'admin'
                      and password_hash = lower(coalesce(p_hash_hex, ''))) then
        raise exception 'Неверный пароль' using errcode = '28000';
    end if;

    v_from := case when p_days is null or p_days <= 0
                   then '-infinity'::timestamptz
                   else now() - (p_days || ' days')::interval end;

    return jsonb_build_object(
        -- общие числа
        'total',        (select count(*) from public.orders where created_at >= v_from),
        'unique_clients', (select count(distinct coalesce(nullif(customer_phone,''), customer_email, customer_name))
                             from public.orders where created_at >= v_from),
        'avg_items',    (select round(coalesce(avg(c.n),0), 2)
                           from (select count(*) n from public.order_items oi
                                  join public.orders o on o.id = oi.order_id
                                 where o.created_at >= v_from group by oi.order_id) c),
        'avg_total',    (select round(coalesce(avg(total),0), 2) from public.orders where created_at >= v_from),
        'median_total', (select round(coalesce(percentile_cont(0.5) within group (order by total),0)::numeric, 2)
                           from public.orders where created_at >= v_from),
        'cancel_rate',  (select round(100.0 * count(*) filter (where st.code in ('cancelled','returned'))
                                  / nullif(count(*), 0), 1)
                           from public.orders o
                           left join public.order_statuses st on st.id = o.status_id
                          where o.created_at >= v_from),

        -- заявки по дням
        'per_day', coalesce((
            select jsonb_agg(jsonb_build_object('day', to_char(d, 'YYYY-MM-DD'), 'count', n)
                             order by d)
            from (select date_trunc('day', created_at)::date as d, count(*) as n
                    from public.orders where created_at >= v_from
                   group by 1) t), '[]'::jsonb),

        -- воронка статусов
        'by_status', coalesce((
            select jsonb_agg(jsonb_build_object('code', st.code, 'name', st.name, 'count', c.n)
                             order by st.sort_order)
            from public.order_statuses st
            join (select status_id, count(*) n from public.orders
                   where created_at >= v_from group by status_id) c on c.status_id = st.id),
            '[]'::jsonb),

        -- топ товаров
        'top_products', coalesce((
            select jsonb_agg(jsonb_build_object('article', pr.article, 'name', pr.name,
                                                'qty', q, 'sum', s) order by q desc, s desc)
            from (select oi.product_id, sum(oi.quantity) q, sum(oi.quantity * oi.price) s
                    from public.order_items oi
                    join public.orders o on o.id = oi.order_id
                   where o.created_at >= v_from
                   group by oi.product_id order by 2 desc limit 5) t
            join public.products pr on pr.id = t.product_id), '[]'::jsonb),

        -- доли категорий
        'category_share', coalesce((
            select jsonb_agg(jsonb_build_object('name', c.name, 'qty', q) order by q desc)
            from (select pr.category_id, sum(oi.quantity) q
                    from public.order_items oi
                    join public.orders o on o.id = oi.order_id
                    join public.products pr on pr.id = oi.product_id
                   where o.created_at >= v_from
                   group by pr.category_id) t
            join public.categories c on c.id = t.category_id), '[]'::jsonb),

        -- способы доставки
        'delivery_share', coalesce((
            select jsonb_agg(jsonb_build_object('name', dm.name, 'count', n) order by n desc)
            from (select delivery_method_id, count(*) n from public.orders
                   where created_at >= v_from and delivery_method_id is not null
                   group by delivery_method_id) t
            join public.delivery_methods dm on dm.id = t.delivery_method_id), '[]'::jsonb),

        -- повторные клиенты
        'repeat_clients', (select count(*) from (
                              select 1 from public.orders
                             where created_at >= v_from
                             group by coalesce(nullif(customer_phone,''), customer_email, customer_name)
                            having count(*) > 1) t),

        -- средний путь до доставки в днях
        'avg_days_to_deliver', (select round(coalesce(avg(extract(epoch from (dl - first_at)) / 86400)::numeric, 0), 1)
                                  from (select o.id,
                                               min(h.changed_at) as first_at,
                                               max(h.changed_at) filter (where st.code = 'delivered') as dl
                                          from public.orders o
                                          join public.order_status_history h on h.order_id = o.id
                                          join public.order_statuses st on st.id = h.status_id
                                         where o.created_at >= v_from
                                         group by o.id) t
                                 where dl is not null)
    );
end;
$$;

grant execute on function public.admin_stats(text, integer) to anon, authenticated;


-- ----------------------------------------------------------------------------
-- 5. Перечитать схему и проверить
-- ----------------------------------------------------------------------------
notify pgrst, 'reload schema';

select
    (select to_regclass('public.admin_login_log') is not null) as zhurnal_sozdan,
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'admin_stats') as funkciya_stats,
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'admin_check_password') as funkciya_check;
