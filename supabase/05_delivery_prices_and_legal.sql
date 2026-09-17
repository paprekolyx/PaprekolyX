-- ============================================================================
--  PaprekolyX — СКРИПТ 5: стоимость доставки и юридические ссылки
-- ============================================================================
--  ЧАСТЬ 1. Доставка: диапазон вместо одной цифры
--    «Москва (метро)» стоит 300 ₽ до обычной станции и 500 ₽ с пересадкой
--    на МЦК или МЦД. Одно поле base_price не может это выразить, поэтому
--    добавлено поле price_max.
--
--    Соглашение о данных (сайт читает его так):
--      base_price = 0 и price_max = 0     →  «бесплатно»
--      price_max > base_price             →  «300–500 ₽» (диапазон)
--      price_max пусто и base_price = 0   →  «рассчитывается отдельно»
--      price_max пусто и base_price > 0   →  «300 ₽» (точная цена)
--
--    В заказ пишется base_price (минимум). Точную сумму мастер подтверждает
--    в переписке — об этом сказано в форме.
--
--  ЧАСТЬ 2. Новые ключи site_content
--    legal.privacy_url   — ссылка на политику обработки персональных данных.
--                          Пока пустая: сайт показывает обычный текст без ссылки.
--    legal.privacy_label — название документа.
--    brand.logo_description — описание логотипа для брендбука (сам логотип
--                          может измениться, поэтому описание тоже в базе).
--
--  Скрипт идемпотентен и НЕ затирает ваши правки: цены обновляются только
--  там, где до сих пор стоит значение по умолчанию (0).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- 1. Диапазон стоимости доставки
-- ----------------------------------------------------------------------------
alter table public.delivery_methods add column if not exists price_max numeric(10,2);

comment on column public.delivery_methods.base_price is 'Минимальная стоимость доставки; 0 — бесплатно или рассчитывается отдельно';
comment on column public.delivery_methods.price_max  is 'Максимальная стоимость доставки. Больше base_price — сайт показывает диапазон; пусто вместе с base_price=0 — «рассчитывается отдельно»';

-- Названия и описания — только если они ещё стандартные
update public.delivery_methods
   set name = 'Самовывоз',
       description = 'м. Ховрино, бесплатно'
 where code = 'pickup' and name = 'Самовывоз';

update public.delivery_methods
   set name = 'Москва (метро)',
       description = 'до любой станции, встреча в центре зала'
 where code = 'metro_msk';

update public.delivery_methods
   set name = 'Boxberry',
       description = 'до пункта выдачи по России'
 where code = 'boxberry' and name = 'Boxberry';

update public.delivery_methods
   set name = 'СДЭК',
       description = 'до пункта выдачи по России'
 where code = 'cdek' and name = 'СДЭК';

-- Цены — только если до сих пор не заполнены
update public.delivery_methods
   set base_price = 0, price_max = 0
 where code = 'pickup' and coalesce(base_price, 0) = 0;

update public.delivery_methods
   set base_price = 300, price_max = 500
 where code = 'metro_msk' and coalesce(base_price, 0) = 0;

-- Boxberry и СДЭК: точная цена зависит от региона, поэтому максимум оставляем пустым
update public.delivery_methods
   set base_price = 0, price_max = null
 where code in ('boxberry', 'cdek') and coalesce(base_price, 0) = 0;


-- ----------------------------------------------------------------------------
-- 2. Новые ключи site_content
-- ----------------------------------------------------------------------------
insert into public.site_content (key, value, description)
select v.key, v.value, v.description
from (values
    ('legal.privacy_url', '',
     'Ссылка на политику обработки персональных данных. Пусто — сайт показывает текст без ссылки'),
    ('legal.privacy_label', 'Политика обработки персональных данных',
     'Название документа о персональных данных'),
    ('brand.logo_description',
     'Круглая эмблема с градиентом от розового к фиолетовому. Буква «P» в центре — символ бренда.',
     'Описание логотипа в брендбуке. Меняйте вместе с самим логотипом')
) as v(key, value, description)
where not exists (select 1 from public.site_content c where c.key = v.key);


-- ----------------------------------------------------------------------------
-- 3. Перечитать схему API
-- ----------------------------------------------------------------------------
notify pgrst, 'reload schema';


-- ----------------------------------------------------------------------------
-- 4. Проверка
-- ----------------------------------------------------------------------------
select code, name, base_price, price_max, description
from public.delivery_methods
order by id;

select
    (select count(*) from public.site_content) as vsego_klyuchej,
    (select count(*) from public.site_content where key like 'legal.%') as yuridicheskie;
