-- ============================================================================
--  PaprekolyX — СКРИПТ 1 из 2: «Каталог начинает работать»
-- ============================================================================
--  ЗАДАЧА
--    Разрешить сайту ЧИТАТЬ товары, категории и справочники.
--
--  ПОЧЕМУ ЭТО НУЖНО
--    В Supabase включена защита RLS, но политик на чтение нет.
--    Поэтому сайт получает пустой ответ [ ] и каталог не отображается,
--    хотя 99 товаров в базе уже есть.
--
--  БЕЗОПАСНОСТЬ
--    • данные не удаляются и не изменяются;
--    • доступ на ЗАПИСЬ не открывается — менять товары может только админ;
--    • промокоды намеренно НЕ открываются всем (иначе их увидит любой желающий);
--    • скрипт можно запускать повторно — ошибки не будет.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Гарантируем, что защита (RLS) включена на всех публичных таблицах
-- ----------------------------------------------------------------------------
alter table public.categories       enable row level security;
alter table public.products         enable row level security;
alter table public.order_statuses   enable row level security;
alter table public.payment_methods  enable row level security;
alter table public.delivery_methods enable row level security;
alter table public.reviews          enable row level security;


-- ----------------------------------------------------------------------------
-- 2. Даём роли anon (посетитель сайта) право читать эти таблицы
-- ----------------------------------------------------------------------------
grant select on public.categories       to anon, authenticated;
grant select on public.products         to anon, authenticated;
grant select on public.order_statuses   to anon, authenticated;
grant select on public.payment_methods  to anon, authenticated;
grant select on public.delivery_methods to anon, authenticated;
grant select on public.reviews          to anon, authenticated;


-- ----------------------------------------------------------------------------
-- 3. Политики чтения.
--    Сначала удаляем одноимённые старые политики — так скрипт можно
--    запускать сколько угодно раз без ошибок и дублей.
-- ----------------------------------------------------------------------------

-- Категории: видны все
drop policy if exists "public_read_categories" on public.categories;
create policy "public_read_categories" on public.categories
    for select to anon, authenticated
    using (true);

-- Товары: видны все (сайт сам отбирает только is_active = true)
drop policy if exists "public_read_products" on public.products;
create policy "public_read_products" on public.products
    for select to anon, authenticated
    using (true);

-- Статусы заказов: видны все (нужны для формы и для админки)
drop policy if exists "public_read_order_statuses" on public.order_statuses;
create policy "public_read_order_statuses" on public.order_statuses
    for select to anon, authenticated
    using (true);

-- Способы оплаты: только активные
drop policy if exists "public_read_payment_methods" on public.payment_methods;
create policy "public_read_payment_methods" on public.payment_methods
    for select to anon, authenticated
    using (is_active = true);

-- Способы доставки: только активные
drop policy if exists "public_read_delivery_methods" on public.delivery_methods;
create policy "public_read_delivery_methods" on public.delivery_methods
    for select to anon, authenticated
    using (is_active = true);

-- Отзывы: только опубликованные (модерация)
drop policy if exists "public_read_reviews" on public.reviews;
create policy "public_read_reviews" on public.reviews
    for select to anon, authenticated
    using (is_published = true);


-- ----------------------------------------------------------------------------
-- 4. Итоговая проверка.
--    После выполнения скрипта в окне результатов вы увидите эту таблицу.
--    В колонке «строк» должно быть непустое число для categories и products.
-- ----------------------------------------------------------------------------
select 'categories'       as tablica, count(*) as strok from public.categories
union all select 'products',          count(*)          from public.products
union all select 'order_statuses',    count(*)          from public.order_statuses
union all select 'payment_methods',   count(*)          from public.payment_methods
union all select 'delivery_methods',  count(*)          from public.delivery_methods
union all select 'reviews',           count(*)          from public.reviews
order by 1;
