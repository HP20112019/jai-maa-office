-- Jai Maa Enterprises: customer catalogue, stock and confirmation-time inventory
-- Run once in Supabase SQL Editor after the existing order system setup.

alter table public.products add column if not exists stock numeric(14,3) not null default 0;
do $$
begin
  if not exists (select 1 from pg_constraint where conname='products_stock_nonnegative') then
    alter table public.products add constraint products_stock_nonnegative check (stock >= 0);
  end if;
end $$;

create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text not null default '',
  phone text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists customers_name_idx on public.customers (lower(name));
alter table public.customers enable row level security;

drop policy if exists "customers_read_active_profiles" on public.customers;
create policy "customers_read_active_profiles" on public.customers
for select to authenticated
using (exists (select 1 from public.profiles p where p.id=auth.uid() and p.active=true and p.role in ('office','salesman')));

drop policy if exists "customers_office_manage" on public.customers;
create policy "customers_office_manage" on public.customers
for all to authenticated
using (exists (select 1 from public.profiles p where p.id=auth.uid() and p.active=true and p.role='office'))
with check (exists (select 1 from public.profiles p where p.id=auth.uid() and p.active=true and p.role='office'));

create or replace function public.apply_order_stock_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  item jsonb;
  qty numeric;
  old_deducted boolean := false;
  new_deducted boolean := false;
  matched integer;
begin
  if TG_OP='DELETE' then
    if OLD.status in ('confirmed','dispatched') then
      for item in select value from jsonb_array_elements(coalesce(OLD.items,'[]'::jsonb)) loop
        qty := coalesce((item->>'qty')::numeric,0);
        update public.products set stock=stock+qty where lower(name)=lower(trim(item->>'name'));
      end loop;
    end if;
    return OLD;
  end if;

  if TG_OP='UPDATE' then
    old_deducted := OLD.status in ('confirmed','dispatched');
  end if;
  new_deducted := NEW.status in ('confirmed','dispatched');

  if old_deducted=new_deducted then
    return NEW;
  end if;

  if new_deducted then
    for item in select value from jsonb_array_elements(coalesce(NEW.items,'[]'::jsonb)) loop
      qty := coalesce((item->>'qty')::numeric,0);
      if qty<=0 then raise exception 'bad_item'; end if;
      update public.products
        set stock=stock-qty
        where lower(name)=lower(trim(item->>'name')) and stock>=qty;
      get diagnostics matched = row_count;
      if matched=0 then
        if exists (select 1 from public.products where lower(name)=lower(trim(item->>'name'))) then
          raise exception 'insufficient_stock: %', trim(item->>'name');
        else
          raise exception 'product_not_found: %', trim(item->>'name');
        end if;
      end if;
    end loop;
  else
    for item in select value from jsonb_array_elements(coalesce(NEW.items,'[]'::jsonb)) loop
      qty := coalesce((item->>'qty')::numeric,0);
      update public.products set stock=stock+qty where lower(name)=lower(trim(item->>'name'));
    end loop;
  end if;
  return NEW;
end;
$$;

drop trigger if exists orders_inventory_adjustment on public.orders;
create trigger orders_inventory_adjustment
after insert or update or delete on public.orders
for each row execute function public.apply_order_stock_change();
