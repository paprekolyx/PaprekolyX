-- ============================================================================
--  PaprekolyX — СКРИПТ 6: кабинет просмотра заказов
-- ============================================================================
--  ЧТО ПОЯВЛЯЕТСЯ
--    1. Таблица admin_credentials — хранит SHA-256 хеш пароля входа.
--       Сам пароль в базе не хранится и по сети не передаётся.
--    2. Таблица status_transitions — статусная модель в стиле Jira workflow:
--       какие переходы между статусами заказа разрешены.
--    3. Функция admin_set_password(hash) — задаёт пароль. Вызывается ВРУЧНУЮ
--       из SQL Editor один раз. Из браузера вызвать нельзя.
--    4. Функция admin_check_password(hash) — проверка пароля при входе.
--    5. Функция admin_orders(hash) — отдаёт заказы одним JSON-ом, только если
--       хеш совпал. Включает позиции, оба комментария, доставку, историю
--       статусов, справочник статусов и статусную модель.
--
--  БЕЗОПАСНОСТЬ (и её честные границы)
--    • Таблица заказов остаётся закрытой для чтения: обойти функцию и сделать
--      select orders напрямую по-прежнему нельзя.
--    • Хеш пароля не читается через API: у admin_credentials нет политик RLS.
--    • Это НЕ настоящая аутентификация: нет серверной сессии, нет ограничения
--      частоты попыток, нет журнала входов. Перечень ограничений продублирован
--      в раскрывающемся блоке на странице orders.html и в техпаспорте.
--
--  ПОРЯДОК ПРИМЕНЕНИЯ
--    1. Выполнить этот скрипт.
--    2. Выполнить отдельным запросом:  select admin_set_password('ВАШ_ПАРOЛЬ');
--       Функция сама посчитает хеш? НЕТ: она принимает уже готовый hex-хеш.
--       Ниже в разделе 6 есть готовый запрос-помощник.
--
--  Скрипт идемпотентен: повторный запуск не затирает пароль и не дублирует
--  статусную модель.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Учётные данные кабинета
-- ----------------------------------------------------------------------------
create table if not exists public.admin_credentials (
    key           text primary key,
    password_hash text not null,          -- SHA-256, 64 hex-символа
    created_at    timestamptz default now(),
    updated_at    timestamptz default now()
);

comment on table  public.admin_credentials is 'Хеш пароля входа в кабинет заказов; сам пароль не хранится';
comment on column public.admin_credentials.password_hash is 'SHA-256 от пароля в нижнем регистре hex';

alter table public.admin_credentials enable row level security;
-- Политик НЕТ: читать и писать можно только через функции и из SQL Editor.


-- ----------------------------------------------------------------------------
-- 2. Статусная модель (Jira-like workflow)
-- ----------------------------------------------------------------------------
create table if not exists public.status_transitions (
    from_status_id integer not null references public.order_statuses(id),
    to_status_id   integer not null references public.order_statuses(id),
    primary key (from_status_id, to_status_id)
);

comment on table public.status_transitions is 'Разрешённые переходы между статусами заказа';

alter table public.status_transitions enable row level security;
-- Политик НЕТ: модель отдаётся функцией admin_orders.

insert into public.status_transitions (from_status_id, to_status_id)
select a.id, b.id
from (values
    ('new',         'confirmed'),   -- заказ увидели и взяли в работу
    ('new',         'cancelled'),
    ('confirmed',   'paid'),        -- договорились и получили оплату
    ('confirmed',   'cancelled'),
    ('paid',        'in_progress'), -- начали изготавливать
    ('paid',        'cancelled'),
    ('in_progress', 'ready'),       -- изделие готово
    ('in_progress', 'cancelled'),
    ('ready',       'shipped'),     -- отправили
    ('shipped',     'delivered'),   -- клиент получил
    ('delivered',   'returned')     -- возврат после получения
) as v(from_code, to_code)
join public.order_statuses a on a.code = v.from_code
join public.order_statuses b on b.code = v.to_code
on conflict do nothing;


-- ----------------------------------------------------------------------------
-- 3. Задание пароля (вызывается вручную из SQL Editor)
--    Принимает УЖЕ посчитанный SHA-256 в hex. Помощник для получения хеша
--    от обычного пароля — в разделе 6.
-- ----------------------------------------------------------------------------
create or replace function public.admin_set_password(p_hash_hex text)
returns text
language plpgsql security definer set search_path = public
as $$
begin
    if p_hash_hex is null or p_hash_hex !~ '^[0-9a-f]{64}$' then
        raise exception 'Ожидается SHA-256 в виде 64 hex-символов' using errcode = '22023';
    end if;

    insert into public.admin_credentials (key, password_hash)
    values ('admin', lower(p_hash_hex))
    on conflict (key) do update
        set password_hash = lower(excluded.password_hash),
            updated_at    = now();

    return 'Пароль кабинета заказов установлен';
end;
$$;

-- Из браузера эту функцию вызвать нельзя
revoke execute on function public.admin_set_password(text) from public, anon, authenticated;


-- ----------------------------------------------------------------------------
-- 4. Проверка пароля
-- ----------------------------------------------------------------------------
create or replace function public.admin_check_password(p_hash_hex text)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
    return exists (
        select 1 from public.admin_credentials
         where key = 'admin' and password_hash = lower(coalesce(p_hash_hex, ''))
    );
end;
$$;

grant execute on function public.admin_check_password(text) to anon, authenticated;


-- ----------------------------------------------------------------------------
-- 5. Выборка заказов для кабинета
-- ----------------------------------------------------------------------------
create or replace function public.admin_orders(p_hash_hex text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
    v_orders jsonb;
begin
    if not public.admin_check_password(p_hash_hex) then
        raise exception 'Неверный пароль' using errcode = '28000';
    end if;

    select coalesce(jsonb_agg(o order by o.created_at desc), '[]'::jsonb)
      into v_orders
    from (
        select ord.id,
               ord.created_at,
               ord.customer_name,
               ord.customer_phone,
               ord.customer_vk,
               ord.customer_email,
               ord.comment          as customer_comment,   -- комментарий к заказу
               ord.total,
               ord.delivery_cost,
               st.code              as status_code,
               st.name              as status_name,
               pm.name              as payment_name,
               dm.name              as delivery_name,
               (select d2.pickup_point    from public.deliveries d2 where d2.order_id = ord.id limit 1) as delivery_point,
               (select d2.tracking_number from public.deliveries d2 where d2.order_id = ord.id limit 1) as tracking_number,
               (select d2.comment         from public.deliveries d2 where d2.order_id = ord.id limit 1) as delivery_comment, -- комментарий к доставке
               (select coalesce(jsonb_agg(jsonb_build_object(
                            'article',   pr.article,
                            'name',       pr.name,
                            'quantity',   oi.quantity,
                            'price',      oi.price,
                            'image_url',  pr.image_url) order by oi.id), '[]'::jsonb)
                  from public.order_items oi
                  left join public.products pr on pr.id = oi.product_id
                 where oi.order_id = ord.id) as items,
               (select coalesce(jsonb_agg(jsonb_build_object(
                            'status_name', s2.name,
                            'changed_at',  h.changed_at,
                            'changed_by',  h.changed_by) order by h.changed_at), '[]'::jsonb)
                  from public.order_status_history h
                  join public.order_statuses s2 on s2.id = h.status_id
                 where h.order_id = ord.id) as history
        from public.orders ord
        left join public.order_statuses  st on st.id = ord.status_id
        left join public.payment_methods pm on pm.id = ord.payment_method_id
        left join public.delivery_methods dm on dm.id = ord.delivery_method_id
        order by ord.created_at desc
        limit 200
    ) o;

    return jsonb_build_object(
        'orders', v_orders,
        'stats', jsonb_build_object(
            'total',     (select count(*) from public.orders),
            'by_status', (select coalesce(jsonb_agg(jsonb_build_object(
                                'code', st.code, 'name', st.name, 'count', c.n)
                                order by st.sort_order), '[]'::jsonb)
                          from public.order_statuses st
                          join (select status_id, count(*) n from public.orders group by status_id) c
                            on c.status_id = st.id)
        ),
        'statuses', (select coalesce(jsonb_agg(jsonb_build_object(
                            'code', code, 'name', name,
                            'sort_order', sort_order, 'is_final', is_final)
                            order by sort_order), '[]'::jsonb)
                     from public.order_statuses),
        'transitions', (select coalesce(jsonb_agg(jsonb_build_object(
                            'from_code', a.code, 'from_name', a.name,
                            'to_code',   b.code, 'to_name',   b.name)
                            order by a.sort_order, b.sort_order), '[]'::jsonb)
                        from public.status_transitions t
                        join public.order_statuses a on a.id = t.from_status_id
                        join public.order_statuses b on b.id = t.to_status_id)
    );
end;
$$;

grant execute on function public.admin_orders(text) to anon, authenticated;


-- ----------------------------------------------------------------------------
-- 6. Помощник: посчитать SHA-256 от обычного пароля прямо в базе.
--    Выполните ОТДЕЛЬНЫМ запросом, подставив свой пароль, затем скопируйте
--    результат и передайте его в admin_set_password:
--
--        select admin_set_password(
--            encode(sha256(convert_to('МОЙ_ПАРОЛЬ', 'utf8')), 'hex'));
--
--    Ниже — готовая связка одним запросом (пароль задаётся в одном месте):
-- ----------------------------------------------------------------------------
-- select admin_set_password(
--     encode(sha256(convert_to('ЗАМЕНИТЕ_НА_СВОЙ_ПАРОЛЬ', 'utf8')), 'hex'));


-- ----------------------------------------------------------------------------
-- 7. Перечитать схему API и проверить
-- ----------------------------------------------------------------------------
notify pgrst, 'reload schema';

select
    (select count(*) from public.status_transitions)               as perehodov,
    (select count(*) from public.admin_credentials)                as parol_zadan,
    (select to_regclass('public.status_transitions') is not null)  as tablica_soedana;
