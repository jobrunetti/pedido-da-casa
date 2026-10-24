-- Pedido da Casa: ingredientes da ficha técnica no cardápio público.
-- Execute uma única vez no Supabase SQL Editor. Não repita a migração original.

-- Retorna apenas nomes de ingredientes ativos vinculados a produtos ativos.
-- Não expõe quantidade, custo nem estoque.
create or replace function public.get_product_ingredients()
returns table (product_id uuid, ingredient_name text)
language sql
stable
security definer
set search_path = ''
as $$
  select r.product_id, i.name as ingredient_name
  from public.product_recipe_items r
  join public.ingredients i on i.id = r.ingredient_id
  join public.products p on p.id = r.product_id
  where coalesce(p.active, true) = true
    and coalesce(i.active, true) = true
  order by r.product_id, i.name;
$$;

revoke all on function public.get_product_ingredients() from public;
grant execute on function public.get_product_ingredients() to anon, authenticated;

-- A função create_public_order já valida removed_ingredients usando products.ingredients.
-- Sincronizamos esse campo com os nomes da ficha técnica para que a validação existente
-- reconheça os ingredientes exibidos no modal. A ficha técnica passa a ser a fonte principal.
create or replace function public.sync_product_ingredients_from_recipe(p_product_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.products p
  set ingredients = coalesce((
    select array_agg(i.name order by i.name)
    from public.product_recipe_items r
    join public.ingredients i on i.id = r.ingredient_id
    where r.product_id = p_product_id
      and coalesce(i.active, true) = true
  ), array[]::text[])
  where p.id = p_product_id;
end;
$$;

create or replace function public.sync_product_ingredients_recipe_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if TG_OP = 'DELETE' then
    perform public.sync_product_ingredients_from_recipe(OLD.product_id);
    return OLD;
  end if;
  perform public.sync_product_ingredients_from_recipe(NEW.product_id);
  if TG_OP = 'UPDATE' and OLD.product_id is distinct from NEW.product_id then
    perform public.sync_product_ingredients_from_recipe(OLD.product_id);
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_sync_product_ingredients_recipe on public.product_recipe_items;
create trigger trg_sync_product_ingredients_recipe
after insert or update or delete on public.product_recipe_items
for each row execute function public.sync_product_ingredients_recipe_trigger();

-- Mantém a lista pública e a validação consistentes se um nome de ingrediente mudar,
-- ou se um ingrediente for ativado/desativado.
create or replace function public.sync_products_when_ingredient_changes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  rec record;
begin
  for rec in
    select distinct r.product_id
    from public.product_recipe_items r
    where r.ingredient_id = NEW.id
  loop
    perform public.sync_product_ingredients_from_recipe(rec.product_id);
  end loop;
  return NEW;
end;
$$;

drop trigger if exists trg_sync_products_when_ingredient_changes on public.ingredients;
create trigger trg_sync_products_when_ingredient_changes
after update of name, active on public.ingredients
for each row execute function public.sync_products_when_ingredient_changes();

-- Corrige também os produtos que já possuem ficha técnica antes desta atualização.
do $$
declare
  rec record;
begin
  for rec in select distinct product_id from public.product_recipe_items loop
    perform public.sync_product_ingredients_from_recipe(rec.product_id);
  end loop;
end;
$$;
