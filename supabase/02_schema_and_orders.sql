-- ============================================================================
--  PaprekolyX — СКРИПТ 2 из 2: «Схема по паспорту + приём заказов»
-- ============================================================================
--  ЗАДАЧА
--    1. Довести таблицы orders и order_items до вида из технического паспорта.
--    2. Создать недостающую таблицу product_images (галерея товара).
--    3. Заполнить справочники: статусы заказов, способы оплаты и доставки.
--    4. Разрешить сайту СОЗДАВАТЬ заказы и отзывы (запись).
--
--  БЕЗОПАСНОСТЬ
--    • существующие данные НЕ удаляются (поле orders.status остаётся на месте);
--    • все действия в стиле «если ещё нет — добавить», скрипт можно повторять;
--    • чтение чужих заказов остаётся закрытым: посетитель может только создать.
--
--  ПОРЯДОК ЗАПУСКА
--    Сначала скрипт 01, затем этот. Оба — в Supabase → SQL Editor → Run.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Таблица orders: добавляем недостающие поля
-- ----------------------------------------------------------------------------
alter table public.orders add column if not exists customer_email    text;
alter table public.orders add column if not exists status_id         integer;
alter table public.orders add column if not exists payment_method_id integer;
alter table public.orders add column if not exists delivery_method_id integer;
alter table public.orders add column if not exists delivery_cost     numeric(10,2) default 0;
alter table public.orders add column if not exists promo_code_id     integer;

-- Внешние ключи добавляем только если их ещё нет (иначе будет ошибка)
do $$ begin
    if not exists (select 1 from pg_constraint where conname = 'orders_status_id_fkey') then
        alter table public.orders add constraint orders_status_id_fkey
            foreign key (status_id) references public.order_statuses(id);
    end if;
    if not exists (select 1 from pg_constraint where conname = 'orders_payment_method_id_fkey') then
        alter table public.orders add constraint orders_payment_method_id_fkey
            foreign key (payment_method_id) references public.payment_methods(id);
    end if;
    if not exists (select 1 from pg_constraint where conname = 'orders_delivery_method_id_fkey') then
        alter table public.orders add constraint orders_delivery_method_id_fkey
            foreign key (delivery_method_id) references public.delivery_methods(id);
    end if;
    if not exists (select 1 from pg_constraint where conname = 'orders_promo_code_id_fkey') then
        alter table public.orders add constraint orders_promo_code_id_fkey
            foreign key (promo_code_id) references public.promo_codes(id);
    end if;
end $$;

-- Индекс для быстрой выборки заказов по статусу
create index if not exists orders_status_id_idx on public.orders(status_id);


-- ----------------------------------------------------------------------------
-- 2. Таблица order_items: снапшот цены на момент заказа
--    Без него изменение цены товара «переписало» бы историю старых заказов.
-- ----------------------------------------------------------------------------
alter table public.order_items add column if not exists price numeric(10,2);


-- ----------------------------------------------------------------------------
-- 3. Таблица product_images (галерея товара) — её в базе ещё не было
-- ----------------------------------------------------------------------------
create table if not exists public.product_images (
    id          serial primary key,
    product_id  integer not null references public.products(id) on delete cascade,
    image_url   text    not null,
    sort_order  integer default 0,
    is_main     boolean default false,
    alt_text    text
);

create index if not exists product_images_product_id_idx on public.product_images(product_id);

alter table public.product_images enable row level security;
grant select on public.product_images to anon, authenticated;

drop policy if exists "public_read_product_images" on public.product_images;
create policy "public_read_product_images" on public.product_images
    for select to anon, authenticated
    using (true);


-- ----------------------------------------------------------------------------
-- 4. Уникальность кодов в справочниках (как требует паспорт)
--    Если дубли уже есть — скрипт не упадёт, а напишет предупреждение.
-- ----------------------------------------------------------------------------
do $$ begin
    if not exists (
        select 1 from pg_constraint c
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
        where c.conrelid = 'public.order_statuses'::regclass and c.contype = 'u' and a.attname = 'code'
    ) then
        alter table public.order_statuses add constraint order_statuses_code_key unique (code);
    end if;
exception when unique_violation then
    raise notice 'order_statuses: есть дубли кодов — уникальность не добавлена';
end $$;

do $$ begin
    if not exists (
        select 1 from pg_constraint c
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
        where c.conrelid = 'public.payment_methods'::regclass and c.contype = 'u' and a.attname = 'code'
    ) then
        alter table public.payment_methods add constraint payment_methods_code_key unique (code);
    end if;
exception when unique_violation then
    raise notice 'payment_methods: есть дубли кодов — уникальность не добавлена';
end $$;

do $$ begin
    if not exists (
        select 1 from pg_constraint c
        join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
        where c.conrelid = 'public.delivery_methods'::regclass and c.contype = 'u' and a.attname = 'code'
    ) then
        alter table public.delivery_methods add constraint delivery_methods_code_key unique (code);
    end if;
exception when unique_violation then
    raise notice 'delivery_methods: есть дубли кодов — уникальность не добавлена';
end $$;


-- ----------------------------------------------------------------------------
-- 5. Заполнение справочника СТАТУСОВ ЗАКАЗА
--    Добавятся только те коды, которых ещё нет — существующие не трогаем.
-- ----------------------------------------------------------------------------
insert into public.order_statuses (code, name, description, is_final, sort_order)
select v.code, v.name, v.description, v.is_final, v.sort_order
from (values
    ('new',         'Новый',        'Заказ создан, ждёт подтверждения',        false, 1),
    ('confirmed',   'Подтверждён',  'Детали согласованы с клиентом',           false, 2),
    ('paid',        'Оплачен',      'Получена оплата или предоплата 40%',      false, 3),
    ('in_progress', 'В работе',     'Мастер изготавливает изделие',            false, 4),
    ('ready',       'Готов',        'Изделие готово к отправке',               false, 5),
    ('shipped',     'Отправлен',    'Передан в доставку',                      false, 6),
    ('delivered',   'Доставлен',    'Клиент получил заказ',                    true,  7),
    ('cancelled',   'Отменён',      'Заказ отменён',                           true,  8),
    ('returned',    'Возврат',      'Оформлен возврат',                        true,  9)
) as v(code, name, description, is_final, sort_order)
where not exists (select 1 from public.order_statuses o where o.code = v.code);


-- ----------------------------------------------------------------------------
-- 6. Заполнение справочника СПОСОБОВ ОПЛАТЫ
-- ----------------------------------------------------------------------------
insert into public.payment_methods (code, name, description, is_active)
select v.code, v.name, v.description, v.is_active
from (values
    ('vk_pay', 'VK Pay',              'Оплата через VK Pay',                          true),
    ('sber',   'Перевод на Сбербанк', 'Перевод на карту Сбербанк (МИР)',              true),
    ('yandex', 'Перевод на Яндекс',   'Перевод на карту Яндекс Банк (МИР)',           true),
    ('sbp',    'СБП',                 'Оплата по QR-коду через Систему быстрых платежей', true)
) as v(code, name, description, is_active)
where not exists (select 1 from public.payment_methods p where p.code = v.code);


-- ----------------------------------------------------------------------------
-- 7. Заполнение справочника СПОСОБОВ ДОСТАВКИ
--    base_price = 0: стоимость уточняется при подтверждении заказа.
-- ----------------------------------------------------------------------------
insert into public.delivery_methods (code, name, description, base_price, is_active)
select v.code, v.name, v.description, v.base_price, v.is_active
from (values
    ('pickup',    'Самовывоз',        'м. Ховрино, по договорённости',        0::numeric(10,2), true),
    ('metro_msk', 'По Москве (метро)','Передача на станции метро',            0::numeric(10,2), true),
    ('boxberry',  'Boxberry',         'Доставка в пункт выдачи по РФ',        0::numeric(10,2), true),
    ('cdek',      'СДЭК',             'Доставка в пункт выдачи по РФ',        0::numeric(10,2), true)
) as v(code, name, description, base_price, is_active)
where not exists (select 1 from public.delivery_methods d where d.code = v.code);


-- ----------------------------------------------------------------------------
-- 8. Разрешаем сайту СОЗДАВАТЬ заказы, позиции заказов и отзывы
--    ВАЖНО: читать чужие заказы посетитель по-прежнему не может.
-- ----------------------------------------------------------------------------
grant insert on public.orders      to anon, authenticated;
grant insert on public.order_items to anon, authenticated;
grant insert on public.reviews     to anon, authenticated;

-- Без этого не сработают автоинкрементные id (serial)
grant usage, select on all sequences in schema public to anon, authenticated;

drop policy if exists "anon_insert_orders" on public.orders;
create policy "anon_insert_orders" on public.orders
    for insert to anon, authenticated
    with check (true);

drop policy if exists "anon_insert_order_items" on public.order_items;
create policy "anon_insert_order_items" on public.order_items
    for insert to anon, authenticated
    with check (true);

-- Отзыв от посетителя всегда создаётся НЕопубликованным (модерация)
drop policy if exists "anon_insert_reviews" on public.reviews;
create policy "anon_insert_reviews" on public.reviews
    for insert to anon, authenticated
    with check (rating between 1 and 5 and is_published = false);


-- ----------------------------------------------------------------------------
-- 9. Итоговая проверка: структура таблицы orders после обновления
-- ----------------------------------------------------------------------------
select column_name as pole, data_type as tip
from information_schema.columns
where table_schema = 'public' and table_name = 'orders'
order by ordinal_position;
