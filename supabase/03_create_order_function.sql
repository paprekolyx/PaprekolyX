-- ============================================================================
--  PaprekolyX — СКРИПТ 3: приём заказов через функцию create_order
-- ============================================================================
--  ЗАДАЧА
--    Создать серверную функцию, которая одним атомарным действием:
--      • создаёт заказ в таблице orders;
--      • сохраняет позиции заказа в order_items со снапшотом цен;
--      • записывает доставку в deliveries;
--      • делает первую запись в журнале статусов order_status_history;
--      • возвращает номер заказа и суммы.
--
--  ПОЧЕМУ ФУНКЦИЯ, А НЕ ПРЯМОЙ INSERT С САЙТА
--    1. ЦЕНЫ СЧИТАЕТ СЕРВЕР. Если сайт сам присылает цену, её можно подменить
--       в консоли браузера и «купить» изделие за 1 рубль. Функция берёт цену
--       из таблицы products и игнорирует всё, что прислал клиент.
--    2. АТОМАРНОСТЬ. Заказ и его позиции создаются в одной транзакции:
--       не может появиться заказ без позиций или позиция без заказа.
--    3. НЕ НУЖНО ОТКРЫВАТЬ ЧТЕНИЕ orders. Функция возвращает только номер
--       созданного заказа. Таблица заказов остаётся закрытой для посетителей.
--
--  БЕЗОПАСНОСТЬ
--    • проверяются имя, наличие хотя бы одного способа связи, состав корзины;
--    • не более 3 заказов за 10 минут с одного телефона / ВК / e-mail;
--    • заказать можно только активные товары (is_active = true);
--    • после установки функции прямой INSERT из браузера закрывается —
--      единственной точкой записи остаётся функция.
--
--  Скрипт идемпотентен: его можно запускать повторно.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Функция создания заказа
-- ----------------------------------------------------------------------------
create or replace function public.create_order(p jsonb)
returns jsonb
language plpgsql
security definer            -- выполняется от имени владельца таблиц,
set search_path = public    -- поэтому видит данные поверх RLS
as $$
declare
    v_name          text;
    v_phone         text;
    v_vk            text;
    v_email         text;
    v_comment       text;
    v_deliv_comment text;
    v_items         jsonb;
    v_item          jsonb;
    v_payment       integer;
    v_delivery      integer;
    v_deliv_cost    numeric(10,2) := 0;
    v_status_new    integer;
    v_order_id      integer;
    v_total         numeric(10,2) := 0;
    v_pid           integer;
    v_qty           integer;
    v_price         numeric(10,2);
    v_pids          integer[]      := '{}';
    v_qtys          integer[]      := '{}';
    v_prices        numeric(10,2)[]:= '{}';
begin
    -- ------------------------------------------------------------------
    -- 1.1. Разбор входных данных
    -- ------------------------------------------------------------------
    v_name          := nullif(trim(coalesce(p->>'customer_name', '')), '');
    v_phone         := nullif(trim(coalesce(p->>'customer_phone', '')), '');
    v_vk            := nullif(trim(coalesce(p->>'customer_vk', '')), '');
    v_email         := nullif(trim(coalesce(p->>'customer_email', '')), '');
    v_comment       := nullif(trim(coalesce(p->>'comment', '')), '');
    v_deliv_comment := nullif(trim(coalesce(p->>'delivery_comment', '')), '');
    v_items         := coalesce(p->'items', '[]'::jsonb);

    if v_name is null then
        raise exception 'Укажите, пожалуйста, ваше имя' using errcode = '22023';
    end if;

    if v_phone is null and v_vk is null and v_email is null then
        raise exception 'Укажите хотя бы один способ связи: телефон, ВКонтакте или e-mail'
            using errcode = '22023';
    end if;

    if length(v_name) > 200 or length(coalesce(v_phone,'')) > 50
       or length(coalesce(v_vk,'')) > 300 or length(coalesce(v_email,'')) > 200
       or length(coalesce(v_comment,'')) > 2000
       or length(coalesce(v_deliv_comment,'')) > 500 then
        raise exception 'Слишком длинный текст в одном из полей' using errcode = '22023';
    end if;

    if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
        raise exception 'Корзина пуста' using errcode = '22023';
    end if;

    if jsonb_array_length(v_items) > 50 then
        raise exception 'Слишком много позиций в одном заказе — напишите нам в ВКонтакте'
            using errcode = '22023';
    end if;

    -- ------------------------------------------------------------------
    -- 1.2. Ограничение частоты (защита от спама и случайных двойных кликов)
    -- ------------------------------------------------------------------
    if (select count(*) from public.orders o
         where o.created_at > now() - interval '10 minutes'
           and (   (v_phone is not null and o.customer_phone = v_phone)
                or (v_vk    is not null and o.customer_vk    = v_vk)
                or (v_email is not null and o.customer_email = v_email))) >= 3 then
        raise exception 'Вы отправили слишком много заказов подряд. Напишите нам в ВКонтакте — мы всё оформим'
            using errcode = '22023';
    end if;

    -- ------------------------------------------------------------------
    -- 1.3. Способ оплаты
    -- ------------------------------------------------------------------
    begin
        v_payment := nullif(trim(coalesce(p->>'payment_method_id', '')), '')::integer;
    exception when others then
        raise exception 'Некорректно указан способ оплаты' using errcode = '22023';
    end;

    if v_payment is not null and not exists
        (select 1 from public.payment_methods where id = v_payment and is_active) then
        raise exception 'Выбранный способ оплаты недоступен' using errcode = '22023';
    end if;

    -- ------------------------------------------------------------------
    -- 1.4. Способ доставки и её стоимость
    -- ------------------------------------------------------------------
    begin
        v_delivery := nullif(trim(coalesce(p->>'delivery_method_id', '')), '')::integer;
    exception when others then
        raise exception 'Некорректно указан способ доставки' using errcode = '22023';
    end;

    if v_delivery is not null then
        select base_price into v_deliv_cost
        from public.delivery_methods where id = v_delivery and is_active;
        if v_deliv_cost is null then
            raise exception 'Выбранный способ доставки недоступен' using errcode = '22023';
        end if;
    else
        v_deliv_cost := 0;
    end if;

    -- ------------------------------------------------------------------
    -- 1.5. Проверка состава корзины.
    --      Цены берутся ИЗ БАЗЫ, а не из того, что прислал сайт.
    -- ------------------------------------------------------------------
    for v_item in select value from jsonb_array_elements(v_items)
    loop
        begin
            v_pid := nullif(trim(coalesce(v_item->>'product_id', '')), '')::integer;
            v_qty := nullif(trim(coalesce(v_item->>'quantity', '')), '')::integer;
        exception when others then
            raise exception 'Некорректный состав корзины' using errcode = '22023';
        end;

        if v_pid is null then
            raise exception 'В корзине есть позиция без товара' using errcode = '22023';
        end if;
        if v_qty is null then
            v_qty := 1;
        end if;
        if v_qty < 1 or v_qty > 99 then
            raise exception 'Некорректное количество: должно быть от 1 до 99' using errcode = '22023';
        end if;

        select pr.price into v_price
        from public.products pr
        where pr.id = v_pid and pr.is_active = true;

        if v_price is null then
            raise exception 'Одно из изделий недоступно для заказа. Обновите страницу и попробуйте снова'
                using errcode = '22023';
        end if;

        v_pids   := array_append(v_pids,   v_pid);
        v_qtys   := array_append(v_qtys,   v_qty);
        v_prices := array_append(v_prices, v_price);
        v_total  := v_total + (v_price * v_qty);
    end loop;

    -- ------------------------------------------------------------------
    -- 1.6. Статус «Новый»
    -- ------------------------------------------------------------------
    select id into v_status_new from public.order_statuses where code = 'new' limit 1;
    if v_status_new is null then
        raise exception 'В базе не настроен справочник статусов заказа' using errcode = '22023';
    end if;

    -- ------------------------------------------------------------------
    -- 1.7. Создаём заказ
    -- ------------------------------------------------------------------
    insert into public.orders
        (customer_name, customer_phone, customer_vk, customer_email,
         status_id, payment_method_id, delivery_method_id,
         total, delivery_cost, comment)
    values
        (v_name, v_phone, v_vk, v_email,
         v_status_new, v_payment, v_delivery,
         v_total, v_deliv_cost, v_comment)
    returning id into v_order_id;

    -- ------------------------------------------------------------------
    -- 1.8. Позиции заказа (снапшот цен на момент оформления)
    -- ------------------------------------------------------------------
    insert into public.order_items (order_id, product_id, quantity, price)
    select v_order_id, t.pid, t.qty, t.pr
    from unnest(v_pids, v_qtys, v_prices) as t(pid, qty, pr);

    -- ------------------------------------------------------------------
    -- 1.9. Доставка
    -- ------------------------------------------------------------------
    if v_delivery is not null then
        insert into public.deliveries
            (order_id, delivery_method_id, pickup_point, cost, comment)
        values
            (v_order_id, v_delivery, v_deliv_comment, v_deliv_cost, null);
    end if;

    -- ------------------------------------------------------------------
    -- 1.10. Первая запись в журнале статусов
    -- ------------------------------------------------------------------
    insert into public.order_status_history (order_id, status_id, changed_by, comment)
    values (v_order_id, v_status_new, 'customer', 'Заказ оформлен на сайте');

    -- ------------------------------------------------------------------
    -- 1.11. Ответ сайту — только то, что нужно показать клиенту
    -- ------------------------------------------------------------------
    return jsonb_build_object(
        'order_id',      v_order_id,
        'items_count',   array_length(v_pids, 1),
        'total',         v_total,
        'delivery_cost', v_deliv_cost,
        'grand_total',   v_total + v_deliv_cost
    );
end;
$$;


-- ----------------------------------------------------------------------------
-- 2. Права на вызов функции
-- ----------------------------------------------------------------------------
revoke all on function public.create_order(jsonb) from public;
grant execute on function public.create_order(jsonb) to anon, authenticated;


-- ----------------------------------------------------------------------------
-- 3. Закрываем прямой INSERT из браузера:
--    теперь единственный способ создать заказ — вызвать функцию.
--    Отзывы остаются открытыми для добавления (там своя политика с модерацией).
-- ----------------------------------------------------------------------------
drop policy if exists "anon_insert_orders"      on public.orders;
drop policy if exists "anon_insert_order_items" on public.order_items;

revoke insert on public.orders      from anon, authenticated;
revoke insert on public.order_items from anon, authenticated;


-- ----------------------------------------------------------------------------
-- 4. Итоговая проверка
-- ----------------------------------------------------------------------------
select
    (select count(*) from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'create_order')   as sozdana_funkciy,
    (select count(*) from pg_policies
     where schemaname = 'public' and tablename = 'orders')         as politik_u_orders,
    (select count(*) from pg_policies
     where schemaname = 'public' and tablename = 'order_items')    as politik_u_order_items;
