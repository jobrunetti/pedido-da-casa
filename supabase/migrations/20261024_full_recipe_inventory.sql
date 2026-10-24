-- Pedido da Casa - expansão de ficha técnica e estoque
-- MIGRAÇÃO ADITIVA: preserva produtos, pedidos e dados existentes.
begin;
create table if not exists public.ingredients(
 id uuid primary key default gen_random_uuid(),
 name text not null unique,
 unit text not null default 'g' check(unit in('g','kg','ml','l','un','porção')),
 stock_quantity numeric(14,3) not null default 0 check(stock_quantity>=0),
 min_stock numeric(14,3) not null default 0 check(min_stock>=0),
 unit_cost numeric(14,4) not null default 0 check(unit_cost>=0),
 active boolean not null default true,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.product_recipe_items(
 id uuid primary key default gen_random_uuid(),
 product_id uuid not null references public.products(id) on delete cascade,
 ingredient_id uuid not null references public.ingredients(id) on delete restrict,
 quantity numeric(14,3) not null check(quantity>0),
 unit text not null default 'g',
 created_at timestamptz not null default now(),
 unique(product_id,ingredient_id)
);
create table if not exists public.addon_recipe_items(
 id uuid primary key default gen_random_uuid(),
 addon_id uuid not null references public.addons(id) on delete cascade,
 ingredient_id uuid not null references public.ingredients(id) on delete restrict,
 quantity numeric(14,3) not null check(quantity>0),
 unit text not null default 'g',
 created_at timestamptz not null default now(),
 unique(addon_id,ingredient_id)
);
alter table public.addons add column if not exists suggested_extra_percent numeric(6,2) not null default 50 check(suggested_extra_percent>0 and suggested_extra_percent<=300);
create table if not exists public.inventory_movements(
 id uuid primary key default gen_random_uuid(),
 ingredient_id uuid not null references public.ingredients(id) on delete restrict,
 movement_type text not null check(movement_type in('opening','purchase','sale','waste','adjustment','return')),
 quantity numeric(14,3) not null check(quantity<>0),
 unit_cost numeric(14,4),
 order_id uuid references public.orders(id) on delete set null,
 order_item_id uuid references public.order_items(id) on delete set null,
 notes text not null default '',
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default now()
);
create unique index if not exists inventory_sale_once_per_item_ingredient
 on public.inventory_movements(order_item_id,ingredient_id,movement_type)
 where movement_type='sale' and order_item_id is not null;
create index if not exists product_recipe_product_idx on public.product_recipe_items(product_id);
create index if not exists addon_recipe_addon_idx on public.addon_recipe_items(addon_id);
create index if not exists inventory_moves_ingredient_date_idx on public.inventory_movements(ingredient_id,created_at desc);
create index if not exists inventory_moves_order_idx on public.inventory_movements(order_id);
-- Existing opening stock becomes a single opening movement; future balance is the ledger sum.
insert into public.inventory_movements(ingredient_id,movement_type,quantity,unit_cost,notes)
select i.id,'opening',i.stock_quantity,i.unit_cost,'Saldo inicial cadastrado'
from public.ingredients i where i.stock_quantity>0
and not exists(select 1 from public.inventory_movements m where m.ingredient_id=i.id);
alter table public.ingredients enable row level security;
alter table public.product_recipe_items enable row level security;
alter table public.addon_recipe_items enable row level security;
alter table public.inventory_movements enable row level security;
grant select,insert,update,delete on public.ingredients,public.product_recipe_items,public.addon_recipe_items to authenticated;
grant select,insert,update,delete on public.inventory_movements to authenticated;
drop policy if exists ingredients_admin_all on public.ingredients;
create policy ingredients_admin_all on public.ingredients for all to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists product_recipe_admin_all on public.product_recipe_items;
create policy product_recipe_admin_all on public.product_recipe_items for all to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists addon_recipe_admin_all on public.addon_recipe_items;
create policy addon_recipe_admin_all on public.addon_recipe_items for all to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists inventory_admin_all on public.inventory_movements;
create policy inventory_admin_all on public.inventory_movements for all to authenticated using(public.is_admin()) with check(public.is_admin());
create or replace view public.inventory_stock_summary as
select i.id as ingredient_id,i.name as ingredient_name,i.unit,i.min_stock,i.unit_cost,
       coalesce(sum(m.quantity),i.stock_quantity,0)::numeric(14,3) as stock_quantity,
       (coalesce(sum(m.quantity),i.stock_quantity,0)<=i.min_stock) as low_stock
from public.ingredients i left join public.inventory_movements m on m.ingredient_id=i.id
group by i.id,i.name,i.unit,i.min_stock,i.unit_cost,i.stock_quantity;
grant select on public.inventory_stock_summary to authenticated;
-- Entrada/ajuste de estoque apenas por usuário administrador. Quantidade negativa representa perda.
create or replace function public.adjust_inventory(p_ingredient_id uuid,p_quantity numeric,p_unit_cost numeric default null,p_notes text default '')
returns uuid language plpgsql security definer set search_path='' as $$
declare iid uuid; current_balance numeric; new_balance numeric; mid uuid; kind text;
begin
 if not public.is_admin() then raise exception 'Acesso restrito ao administrador.'; end if;
 if p_quantity is null or p_quantity=0 then raise exception 'Informe uma quantidade diferente de zero.'; end if;
 select id into iid from public.ingredients where id=p_ingredient_id and active=true for update;
 if iid is null then raise exception 'Insumo não encontrado ou inativo.'; end if;
 select coalesce(sum(quantity),0) into current_balance from public.inventory_movements where ingredient_id=iid;
 new_balance:=current_balance+p_quantity;
 if new_balance<0 then raise exception 'Ajuste recusado: o estoque não pode ficar negativo.'; end if;
 kind:=case when p_quantity>0 then 'purchase' else 'waste' end;
 insert into public.inventory_movements(ingredient_id,movement_type,quantity,unit_cost,notes,created_by)
 values(iid,kind,p_quantity,p_unit_cost,left(coalesce(p_notes,''),300),auth.uid()) returning id into mid;
 if p_unit_cost is not null then update public.ingredients set unit_cost=p_unit_cost,updated_at=now() where id=iid; end if;
 return mid;
end; $$;
revoke all on function public.adjust_inventory(uuid,numeric,numeric,text) from public;
grant execute on function public.adjust_inventory(uuid,numeric,numeric,text) to authenticated;
-- Extend order creation safely. Prices, products and extras are resolved server-side.
-- Stock is deducted only when status changes into accepted/preparing/ready/completed, exactly once per order item/ingredient.
create or replace function public.apply_order_stock(p_order_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare oi record; rr record; needed numeric; balance numeric; already boolean;
begin
 for oi in select it.* from public.order_items it where it.order_id=p_order_id loop
  for rr in
   select ingredient_id,quantity,unit from public.product_recipe_items where product_id=oi.product_id
   union all
   select ar.ingredient_id,ar.quantity,ar.unit from public.addon_recipe_items ar
   join public.addons a on a.id=ar.addon_id
   where a.name=any(oi.addon_names_snapshot)
  loop
   needed:=rr.quantity*oi.quantity;
   if exists(select 1 from public.inventory_movements where order_item_id=oi.id and ingredient_id=rr.ingredient_id and movement_type='sale') then continue; end if;
   select coalesce(sum(quantity),0) into balance from public.inventory_movements where ingredient_id=rr.ingredient_id;
   -- For pre-ledger data, fall back to current stock column.
   if not exists(select 1 from public.inventory_movements where ingredient_id=rr.ingredient_id) then
    select stock_quantity into balance from public.ingredients where id=rr.ingredient_id;
   end if;
   if balance<needed then raise exception 'Estoque insuficiente para insumo %: disponível %, necessário %.',rr.ingredient_id,balance,needed; end if;
   insert into public.inventory_movements(ingredient_id,movement_type,quantity,order_id,order_item_id,notes,created_by)
   values(rr.ingredient_id,'sale',-needed,p_order_id,oi.id,'Consumo automático do pedido',null);
  end loop;
 end loop;
end; $$;
revoke all on function public.apply_order_stock(uuid) from public;
-- trigger deducts stock once when order becomes accepted or later; cancellation/rejection restores it once.
create or replace function public.order_status_stock_trigger() returns trigger language plpgsql security definer set search_path='' as $$
declare old_active boolean; new_active boolean; mv record;
begin
 old_active:=tg_op='UPDATE' and old.status in('accepted','preparing','ready','completed');
 new_active:=new.status in('accepted','preparing','ready','completed');
 if new_active and not coalesce(old_active,false) then
  perform public.apply_order_stock(new.id);
 elsif coalesce(old_active,false) and not new_active then
  for mv in select * from public.inventory_movements where order_id=new.id and movement_type='sale' loop
   if not exists(select 1 from public.inventory_movements r where r.order_item_id=mv.order_item_id and r.ingredient_id=mv.ingredient_id and r.movement_type='return') then
    insert into public.inventory_movements(ingredient_id,movement_type,quantity,order_id,order_item_id,notes)
    values(mv.ingredient_id,'return',abs(mv.quantity),new.id,mv.order_item_id,'Estorno automático por cancelamento/recusa');
   end if;
  end loop;
 end if;
 return new;
end; $$;
drop trigger if exists orders_stock_status_trigger on public.orders;
create trigger orders_stock_status_trigger after update of status on public.orders for each row execute function public.order_status_stock_trigger();
-- Cash validation and add-on validation are done inside the order transaction.
create or replace function public.create_public_order(order_data jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare oid uuid; sub numeric(10,2):=0; fee numeric(10,2):=0; totalv numeric(10,2):=0; item jsonb; prod public.products%rowtype; qty int; aid uuid[]; atotal numeric(10,2); anames text[]; unitv numeric(10,2); linev numeric(10,2); cname text; phone text; fulfill text; addr text; pay text; changev numeric(10,2); notesv text; openv boolean; removed text[];
begin
 cname:=left(trim(coalesce(order_data->>'customer_name','')),120);
 phone:=left(regexp_replace(coalesce(order_data->>'customer_phone',''),'[^0-9+]','','g'),25);
 fulfill:=coalesce(order_data->>'fulfillment','pickup'); addr:=left(trim(coalesce(order_data->>'address','')),400);
 pay:=coalesce(order_data->>'payment_method','pix'); changev:=nullif(order_data->>'cash_change_for','')::numeric;
 notesv:=left(trim(coalesce(order_data->>'notes','')),1000);
 if length(cname)<2 then raise exception 'Informe o nome.'; end if;
 if length(regexp_replace(phone,'[^0-9]','','g'))<8 then raise exception 'Informe um telefone válido.'; end if;
 if fulfill not in('pickup','delivery') then raise exception 'Recebimento inválido.'; end if;
 if fulfill='delivery' and length(addr)<5 then raise exception 'Informe o endereço.'; end if;
 if pay not in('pix','cash','card') then raise exception 'Pagamento inválido.'; end if;
 if jsonb_typeof(order_data->'items')<>'array' or jsonb_array_length(order_data->'items')<1 or jsonb_array_length(order_data->'items')>40 then raise exception 'Carrinho inválido.'; end if;
 select is_open,delivery_fee into openv,fee from public.store_settings where id=1;
 if coalesce(openv,false)=false then raise exception 'A lanchonete está fechada.'; end if;
 if fulfill='pickup' then fee:=0; end if;
 insert into public.orders(customer_name,customer_phone,fulfillment,address,payment_method,cash_change_for,notes,delivery_fee)
 values(cname,phone,fulfill,addr,pay,case when pay='cash' then changev else null end,notesv,fee) returning id into oid;
 for item in select value from jsonb_array_elements(order_data->'items') loop
  select * into prod from public.products where id=(item->>'product_id')::uuid and active=true;
  if not found then raise exception 'Produto indisponível.'; end if;
  qty:=coalesce((item->>'quantity')::int,1); if qty<1 or qty>50 then raise exception 'Quantidade inválida.'; end if;
  aid:=array(select distinct jsonb_array_elements_text(coalesce(item->'addon_ids','[]'::jsonb))::uuid);
  if coalesce(array_length(aid,1),0)<>jsonb_array_length(coalesce(item->'addon_ids','[]'::jsonb)) then raise exception 'Adicionais inválidos.'; end if;
  if exists(select 1 from unnest(aid) x where not exists(select 1 from public.addons a where a.id=x and a.active=true)) then raise exception 'Adicional indisponível.'; end if;
  select coalesce(sum(a.price),0),coalesce(array_agg(a.name order by a.name),array[]::text[]) into atotal,anames from public.addons a where a.id=any(aid);
  unitv:=prod.price+atotal; linev:=unitv*qty;
  removed:=array(select jsonb_array_elements_text(coalesce(item->'removed_ingredients','[]'::jsonb)));
  -- Do not allow arbitrary removed names: only names included in the product's public ingredient list.
  if exists(select 1 from unnest(removed) x where not (x=any(coalesce(prod.ingredients,array[]::text[])))) then raise exception 'Ingrediente removido inválido.'; end if;
  insert into public.order_items(order_id,product_id,product_name_snapshot,unit_price,quantity,addon_names_snapshot,removed_ingredients,notes,line_total)
  values(oid,prod.id,prod.name,unitv,qty,anames,removed,left(coalesce(item->>'notes',''),500),linev);
  sub:=sub+linev;
 end loop;
 totalv:=sub+fee;
 if pay='cash' and changev is not null and changev<totalv then raise exception 'O valor informado para troco precisa ser igual ou maior que o total.'; end if;
 update public.orders set subtotal=sub,total=totalv where id=oid;
 return jsonb_build_object('order_id',oid,'subtotal',sub,'delivery_fee',fee,'total',totalv);
end; $$;
revoke all on function public.create_public_order(jsonb) from public;
grant execute on function public.create_public_order(jsonb) to anon,authenticated;
commit;
