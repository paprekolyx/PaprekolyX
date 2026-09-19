-- ============================================================================
--  PaprekolyX — СКРИПТ 7: промокоды, пункт выдачи и исправление комментария
-- ============================================================================
--  ЧТО ИСПРАВЛЯЕТ
--    1. БАГ скрипта 03: комментарий к доставке записывался в deliveries.pickup_point,
--       а deliveries.comment оставался пустым. Из-за этого в кабинете комментарий
--       показывался не там.
--       Разница полей:
--         pickup_point — АДРЕС: пункт выдачи Boxberry/СДЭК или станция метро;
--         comment      — СВОБОДНЫЙ комментарий: удобное время, пожелания курьеру.
--       Скрипт переносит ошибочно заполненные значения в comment.
--    2. Добавляет поле формы «Пункт выдачи / станция метро» → deliveries.pickup_point.
--    3. Добавляет промокоды: проверка на сервере (таблица promo_codes закрыта
--       для чтения), скидка считается на сервере, used_count увеличивается.
--
--  Идемпотентен: функции перезаписываются, миграция данных не дублирует правки.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Миграция ошибочно заполненных строк доставки
--    Условие безопасно: форма сайта никогда не отправляла pickup_point,
--    поэтому непустой pickup_point при пустом comment — это и есть комментарий.
-- ----------------------------------------------------------------------------
update public.deliveries
   set comment = pickup_point,
       pickup_point = null
 where comment is null
   and pickup_point is not null;


-- ----------------------------------------------------------------------------
-- 2. Проверка промокода (для живого отклика в форме)
-- ----------------------------------------------------------------------------
create or replace function public.check_promo(p_code text, p_amount numeric)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
    v_promo public.promo_codes;
    v_discount numeric(10,2) := 0;
begin
    if p_code is null or btrim(p_code) = '' then
        return jsonb_build_object('ok', false, 'message', 'Введите промокод');
    end if;

    select * into v_promo
    from public.promo_codes
    where code = upper(btrim(p_code))
    limit 1;

    if v_promo.id is null or not v_promo.is_active then
        return jsonb_build_object('ok', false, 'message', 'Такого промокода нет или он отключён');
    end if;
    if v_promo.valid_from is not null and current_date < v_promo.valid_from then
        return jsonb_build_object('ok', false, 'message', 'Промокод ещё не начал действовать');
    end if;
    if v_promo.valid_until is not null and current_date > v_promo.valid_until then
        return jsonb_build_object('ok', false, 'message', 'Срок действия промокода истёк');
    end if;
    if v_promo.usage_limit is not null and v_promo.used_count >= v_promo.usage_limit then
        return jsonb_build_object('ok', false, 'message', 'Промокод уже использован максимальное число раз');
    end if;
    if coalesce(p_amount, 0) < coalesce(v_promo.min_order_amount, 0) then
        return jsonb_build_object('ok', false,
            'message', 'Промокод действует от ' || v_promo.min_order_amount || ' ₽');
    end if;

    v_discount := case v_promo.discount_type
        when 'percent' then round(coalesce(p_amount,0) * v_promo.discount_value / 100, 2)
        else v_promo.discount_value end;
    if v_discount > coalesce(p_amount, 0) then v_discount := coalesce(p_amount, 0); end if;

    return jsonb_build_object(
        'ok', true,
        'message', 'Промокод применён',
        'discount', v_discount,
        'discount_text', case v_promo.discount_type
            when 'percent' then v_promo.discount_value || '%'
            else v_promo.discount_value || ' ₽' end);
end;
$$;

grant execute on function public.check_promo(text, numeric) to anon, authenticated;


-- ----------------------------------------------------------------------------
-- 3. Создание заказа: исправленная доставка + промокод + пункт выдачи
-- ----------------------------------------------------------------------------
create or replace function public.create_order(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_name          text;
    v_phone         text;
    v_vk            text;
    v_email         text;
    v_comment       text;
    v_deliv_comment text;
    v_pickup        text;
    v_promo_code    text;
    v_items         jsonb;
    v_item          jsonb;
    v_payment       integer;
    v_delivery      integer;
    v_deliv_cost    numeric(10,2) := 0;
    v_status_new    integer;
    v_order_id      integer;
    v_subtotal      numeric(10,2) := 0;
    v_discount      numeric(10,2) := 0;
    v_total         numeric(10,2) := 0;
    v_promo         public.promo_codes;
    v_pid           integer;
    v_qty           integer;
    v_price         numeric(10,2);
    v_pids          integer[]       := '{}';
    v_qtys          integer[]       := '{}';
    v_prices        numeric(10,2)[] := '{}';
begin
    v_name          := nullif(trim(coalesce(p->>'customer_name', '')), '');
    v_phone         := nullif(trim(coalesce(p->>'customer_phone', '')), '');
    v_vk            := nullif(trim(coalesce(p->>'customer_vk', '')), '');
    v_email         := nullif(trim(coalesce(p->>'customer_email', '')), '');
    v_comment       := nullif(trim(coalesce(p->>'comment', '')), '');
    v_deliv_comment := nullif(trim(coalesce(p->>'delivery_comment', '')), '');
    v_pickup        := nullif(trim(coalesce(p->>'pickup_point', '')), '');
    v_promo_code    := nullif(upper(trim(coalesce(p->>'promo_code', ''))), '');
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
       or length(coalesce(v_deliv_comment,'')) > 500
       or length(coalesce(v_pickup,'')) > 300 then
        raise exception 'Слишком длинный текст в одном из полей' using errcode = '22023';
    end if;
    if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 then
        raise exception 'Корзина пуста' using errcode = '22023';
    end if;
    if jsonb_array_length(v_items) > 50 then
        raise exception 'Слишком много позиций в одном заказе — напишите нам в ВКонтакте'
            using errcode = '22023';
    end if;

    if (select count(*) from public.orders o
         where o.created_at > now() - interval '10 minutes'
           and (   (v_phone is not null and o.customer_phone = v_phone)
                or (v_vk    is not null and o.customer_vk    = v_vk)
                or (v_email is not null and o.customer_email = v_email))) >= 3 then
        raise exception 'Вы отправили слишком много заказов подряд. Напишите нам в ВКонтакте — мы всё оформим'
            using errcode = '22023';
    end if;

    begin
        v_payment := nullif(trim(coalesce(p->>'payment_method_id', '')), '')::integer;
    exception when others then
        raise exception 'Некорректно указан способ оплаты' using errcode = '22023';
    end;
    if v_payment is not null and not exists
        (select 1 from public.payment_methods where id = v_payment and is_active) then
        raise exception 'Выбранный способ оплаты недоступен' using errcode = '22023';
    end if;

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

    -- цены берём ТОЛЬКО из базы
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
        if v_qty is null then v_qty := 1; end if;
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
        v_pids     := array_append(v_pids, v_pid);
        v_qtys     := array_append(v_qtys, v_qty);
        v_prices   := array_append(v_prices, v_price);
        v_subtotal := v_subtotal + (v_price * v_qty);
    end loop;

    -- промокод проверяем на сервере: таблица promo_codes для чтения закрыта
    if v_promo_code is not null then
        select * into v_promo
        from public.promo_codes
        where code = v_promo_code
        limit 1;

        if v_promo.id is null or not v_promo.is_active then
            raise exception 'Такого промокода нет или он отключён' using errcode = '22023';
        end if;
        if v_promo.valid_from is not null and current_date < v_promo.valid_from then
            raise exception 'Промокод ещё не начал действовать' using errcode = '22023';
        end if;
        if v_promo.valid_until is not null and current_date > v_promo.valid_until then
            raise exception 'Срок действия промокода истёк' using errcode = '22023';
        end if;
        if v_promo.usage_limit is not null and v_promo.used_count >= v_promo.usage_limit then
            raise exception 'Промокод уже использован максимальное число раз' using errcode = '22023';
        end if;
        if v_subtotal < coalesce(v_promo.min_order_amount, 0) then
            raise exception 'Промокод действует при заказе от % ₽', v_promo.min_order_amount
                using errcode = '22023';
        end if;

        v_discount := case v_promo.discount_type
            when 'percent' then round(v_subtotal * v_promo.discount_value / 100, 2)
            else v_promo.discount_value end;
        if v_discount > v_subtotal then v_discount := v_subtotal; end if;
    end if;

    v_total := v_subtotal - v_discount;

    select id into v_status_new from public.order_statuses where code = 'new' limit 1;
    if v_status_new is null then
        raise exception 'В базе не настроен справочник статусов заказа' using errcode = '22023';
    end if;

    insert into public.orders
        (customer_name, customer_phone, customer_vk, customer_email,
         status_id, payment_method_id, delivery_method_id,
         total, delivery_cost, comment, promo_code_id)
    values
        (v_name, v_phone, v_vk, v_email,
         v_status_new, v_payment, v_delivery,
         v_total, v_deliv_cost, v_comment, v_promo.id)
    returning id into v_order_id;

    insert into public.order_items (order_id, product_id, quantity, price)
    select v_order_id, t.pid, t.qty, t.pr
    from unnest(v_pids, v_qtys, v_prices) as t(pid, qty, pr);

    if v_delivery is not null then
        insert into public.deliveries
            (order_id, delivery_method_id, pickup_point, cost, comment)
        values
            (v_order_id, v_delivery, v_pickup, v_deliv_cost, v_deliv_comment);
    end if;

    insert into public.order_status_history (order_id, status_id, changed_by, comment)
    values (v_order_id, v_status_new, 'customer', 'Заказ оформлен на сайте');

    if v_promo.id is not null then
        update public.promo_codes
           set used_count = used_count + 1
         where id = v_promo.id;
    end if;

    return jsonb_build_object(
        'order_id',      v_order_id,
        'items_count',   array_length(v_pids, 1),
        'subtotal',      v_subtotal,
        'discount',      v_discount,
        'total',         v_total,
        'delivery_cost', v_deliv_cost,
        'grand_total',   v_total + v_deliv_cost,
        'promo_code',    v_promo_code
    );
end;
$$;


-- ----------------------------------------------------------------------------
-- 4. Перечитать схему и проверить
--    При желании создайте тестовый промокод (раскомментируйте):
--    insert into public.promo_codes (code, discount_type, discount_value, min_order_amount, is_active)
--    values ('TEST10', 'percent', 10, 0, true)
--    on conflict (code) do nothing;
-- ----------------------------------------------------------------------------
notify pgrst, 'reload schema';

select
    (select count(*) from public.deliveries
      where comment is not null and pickup_point is null) as kommentarii_na_meste,
    (select count(*) from public.deliveries
      where comment is null and pickup_point is not null)  as oshibochnyh_ostalos;
