-- ============================================================================
--  PaprekolyX — СКРИПТ 9: «оплачен» становится признаком, смена статусов из кабинета
-- ============================================================================
--  ЧТО МЕНЯЕТСЯ
--    1. «Оплачен» уходит из справочника статусов: оплата — это свойство заказа,
--       а не этап работы. Добавляются поля orders.is_paid и orders.paid_at.
--    2. Существующие заказы со статусом paid переносятся: is_paid = true,
--       статус становится confirmed, а если в истории есть «в работе» — in_progress.
--    3. В журнал истории добавляется changed_role: пока всегда 'admin',
--       в будущем поле примет роль пользователя.
--    4. Новые функции смены статуса и оплаты с проверкой разрешённых переходов.
--
--  ПРАВИЛО ОТМЕНЫ: заказ с is_paid = true отменить нельзя, пока флаг оплаты
--  не снят осознанно (сначала admin_set_paid(false), затем отмена).
--
--  Идемпотентен: миграция данных выполняется один раз, функции перезаписываются.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Поля оплаты в заказе
-- ----------------------------------------------------------------------------
alter table public.orders add column if not exists is_paid boolean not null default false;
alter table public.orders add column if not exists paid_at timestamptz;

comment on column public.orders.is_paid is 'Заказ оплачен полностью; не является статусом';
comment on column public.orders.paid_at is 'Когда заказ отмечен оплаченным';


-- ----------------------------------------------------------------------------
-- 2. Роль в журнале истории статусов
-- ----------------------------------------------------------------------------
alter table public.order_status_history
    add column if not exists changed_role text not null default 'admin';

comment on column public.order_status_history.changed_role is 'Роль пользователя: пока только admin, в будущем другие роли';
comment on column public.order_status_history.changed_by is 'Кто именно изменил: admin / customer / system';


-- ----------------------------------------------------------------------------
-- 3. Миграция данных: статус paid -> признак is_paid
--    Выполняется один раз: после удаления кода paid условие не найдёт строк.
-- ----------------------------------------------------------------------------
update public.orders o
   set is_paid = true,
       paid_at = coalesce(o.paid_at, o.created_at),
       status_id = case
           when exists (select 1 from public.order_status_history h
                         join public.order_statuses s on s.id = h.status_id
                        where h.order_id = o.id and s.code = 'in_progress')
           then (select id from public.order_statuses where code = 'in_progress')
           else (select id from public.order_statuses where code = 'confirmed')
       end
 where o.status_id = (select id from public.order_statuses where code = 'paid');


-- ----------------------------------------------------------------------------
-- 4. Убираем paid из справочника и из статусной модели
-- ----------------------------------------------------------------------------
delete from public.status_transitions
 where from_status_id = (select id from public.order_statuses where code = 'paid')
    or to_status_id   = (select id from public.order_statuses where code = 'paid');

-- После удаления paid цепочку восстанавливаем: confirmed -> in_progress
insert into public.status_transitions (from_status_id, to_status_id)
select a.id, b.id
from public.order_statuses a, public.order_statuses b
where a.code = 'confirmed' and b.code = 'in_progress'
on conflict do nothing;

delete from public.order_statuses where code = 'paid'
  and not exists (select 1 from public.orders o where o.status_id = public.order_statuses.id);


-- ----------------------------------------------------------------------------
-- 5. Смена статуса с проверкой переходов
-- ----------------------------------------------------------------------------
create or replace function public.admin_set_status(
    p_hash_hex text,
    p_order_id integer,
    p_status_code text,
    p_comment text default null,
    p_role text default 'admin')
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
    v_order public.orders;
    v_from  public.order_statuses;
    v_to    public.order_statuses;
begin
    if not exists (select 1 from public.admin_credentials
                    where key = 'admin' and password_hash = lower(coalesce(p_hash_hex, ''))) then
        raise exception 'Неверный пароль' using errcode = '28000';
    end if;

    select * into v_order from public.orders where id = p_order_id;
    if v_order.id is null then
        raise exception 'Заказ не найден' using errcode = '22023';
    end if;

    select * into v_to from public.order_statuses where code = p_status_code;
    if v_to.id is null then
        raise exception 'Неизвестный статус: %', p_status_code using errcode = '22023';
    end if;

    select * into v_from from public.order_statuses where id = v_order.status_id;
    if v_from.id = v_to.id then
        raise exception 'Заказ уже в этом статусе' using errcode = '22023';
    end if;

    if not exists (select 1 from public.status_transitions t
                    where t.from_status_id = v_from.id and t.to_status_id = v_to.id) then
        raise exception 'Переход % → % не разрешён статусной моделью', v_from.name, v_to.name
            using errcode = '22023';
    end if;

    if v_to.code = 'cancelled' and v_order.is_paid then
        raise exception 'Заказ оплачен: сначала снимите флаг оплаты, затем отменяйте'
            using errcode = '22023';
    end if;

    update public.orders set status_id = v_to.id where id = v_order.id;

    insert into public.order_status_history (order_id, status_id, changed_by, changed_role, comment)
    values (v_order.id, v_to.id, 'admin', coalesce(p_role, 'admin'), p_comment);

    return jsonb_build_object('ok', true, 'status_code', v_to.code, 'status_name', v_to.name);
end;
$$;

grant execute on function public.admin_set_status(text, integer, text, text, text) to anon, authenticated;


-- ----------------------------------------------------------------------------
-- 6. Флаг оплаты
-- ----------------------------------------------------------------------------
create or replace function public.admin_set_paid(
    p_hash_hex text,
    p_order_id integer,
    p_is_paid boolean,
    p_role text default 'admin')
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
    v_order public.orders;
begin
    if not exists (select 1 from public.admin_credentials
                    where key = 'admin' and password_hash = lower(coalesce(p_hash_hex, ''))) then
        raise exception 'Неверный пароль' using errcode = '28000';
    end if;

    select * into v_order from public.orders where id = p_order_id;
    if v_order.id is null then
        raise exception 'Заказ не найден' using errcode = '22023';
    end if;

    if p_is_paid then
        update public.orders set is_paid = true, paid_at = now() where id = v_order.id;
        insert into public.payments (order_id, payment_method_id, amount, payment_type, transaction_id, status)
        values (v_order.id, v_order.payment_method_id,
                v_order.total + coalesce(v_order.delivery_cost, 0), 'full',
                'admin:' || v_order.id || ':' || extract(epoch from now())::bigint, 'success');
    else
        update public.orders set is_paid = false, paid_at = null where id = v_order.id;
        delete from public.payments
         where order_id = v_order.id and transaction_id like 'admin:' || v_order.id || ':%';
    end if;

    insert into public.order_status_history (order_id, status_id, changed_by, changed_role, comment)
    values (v_order.id, v_order.status_id, 'admin', coalesce(p_role, 'admin'),
            case when p_is_paid then 'Отмечен оплаченным' else 'Флаг оплаты снят' end);

    return jsonb_build_object('ok', true, 'is_paid', p_is_paid);
end;
$$;

grant execute on function public.admin_set_paid(text, integer, boolean, text) to anon, authenticated;


-- ----------------------------------------------------------------------------
-- 7. Что разрешено для заказа (для кнопок в кабинете)
-- ----------------------------------------------------------------------------
create or replace function public.admin_order_actions(p_hash_hex text, p_order_id integer)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
    v_order public.orders;
begin
    if not exists (select 1 from public.admin_credentials
                    where key = 'admin' and password_hash = lower(coalesce(p_hash_hex, ''))) then
        raise exception 'Неверный пароль' using errcode = '28000';
    end if;

    select * into v_order from public.orders where id = p_order_id;
    if v_order.id is null then
        raise exception 'Заказ не найден' using errcode = '22023';
    end if;

    return jsonb_build_object(
        'status_code', (select code from public.order_statuses where id = v_order.status_id),
        'status_name', (select name from public.order_statuses where id = v_order.status_id),
        'is_paid',     v_order.is_paid,
        'paid_at',     v_order.paid_at,
        'allowed',     coalesce((
            select jsonb_agg(jsonb_build_object('code', s.code, 'name', s.name) order by s.sort_order)
            from public.status_transitions t
            join public.order_statuses s on s.id = t.to_status_id
            where t.from_status_id = v_order.status_id), '[]'::jsonb));
end;
$$;

grant execute on function public.admin_order_actions(text, integer) to anon, authenticated;


-- ----------------------------------------------------------------------------
-- 8. Роль в истории проставляется триггером, чтобы create_order не переписывать
-- ----------------------------------------------------------------------------
create or replace function public.status_history_role()
returns trigger
language plpgsql
as $$
begin
    new.changed_role := case new.changed_by
        when 'customer' then 'customer'
        when 'system'   then 'system'
        else coalesce(new.changed_role, 'admin') end;
    return new;
end;
$$;

drop trigger if exists status_history_role on public.order_status_history;
create trigger status_history_role
    before insert on public.order_status_history
    for each row execute function public.status_history_role();


-- ----------------------------------------------------------------------------
-- 9. Перечитать схему и проверить
-- ----------------------------------------------------------------------------
notify pgrst, 'reload schema';

select
    (select count(*) from public.order_statuses where code = 'paid') as paid_v_statusah,
    (select count(*) from public.orders where is_paid)               as oplacheno,
    (select to_regclass('public.order_status_history') is not null)  as zhurnal_est;
