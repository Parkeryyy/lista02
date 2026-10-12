-- Questao 01
create or replace view v_staff_performance as
select 
    s.staff_id,
    s.first_name || ' ' || s.last_name as staff_name,
    a.address || ', ' || ci.city || ' - ' || co.country as store_address,
    coalesce(r_stats.total_rentals, 0) as total_rentals,
    coalesce(p_stats.total_revenue, 0.00) as total_revenue
from staff s
join store st on s.store_id = st.store_id
join address a on st.address_id = a.address_id
join city ci on a.city_id = ci.city_id
join country co on ci.country_id = co.country_id
left join (
    select staff_id, count(*) as total_rentals 
    from rental 
    group by staff_id
) r_stats on s.staff_id = r_stats.staff_id
left join (
    select staff_id, sum(amount) as total_revenue 
    from payment 
    group by staff_id
) p_stats on s.staff_id = p_stats.staff_id;

-- Questao 02
-- 1. Criacao da Materialized View
create materialized view mv_category_total_sales as
select 
    c.name as category_name,
    sum(p.amount) as total_sales
from category c
join film_category fc on c.category_id = fc.category_id
join film f on fc.film_id = f.film_id
join inventory i on f.film_id = i.film_id
join rental r on i.inventory_id = r.inventory_id
join payment p on r.rental_id = p.rental_id
group by c.name;

-- 2. Criacao do indice unico obrigatorio para refresh concorrente
create unique index idx_mv_category_total_sales_name 
on mv_category_total_sales (category_name);

-- 3. Comando para atualizar a MV sem bloquear consultas (Concurrent Refresh)
refresh materialized view concurrently mv_category_total_sales;

-- Questao 03
-- Criacao do indice parcial para locacoes em aberto
create index idx_rental_not_returned 
on rental (rental_id) 
where return_date is null;

-- Validacao com explain analyze
explain analyze
select rental_id, customer_id, rental_date 
from rental 
where return_date is null;

-- Questao 04
-- Criando o indice gin baseado em busca de texto completo na coluna description
create index idx_film_description_fts 
on film using gin(to_tsvector('english', description));

-- Consulta utilizando o operador de busca (@@) e explain analyze
explain analyze
select film_id, title, description
from film
where to_tsvector('english', description) @@ to_tsquery('english', 'documentary & drama');

-- Questao 05
create index idx_payment_customer_data_desc
on payment (customer_id, payment_date desc);

-- Questao 06
-- Criando o indice funcional
create index idx_customer_lower_email 
on customer (lower(email));

-- Consulta de teste validando o uso do indice com explain analyze
explain analyze
select customer_id, first_name, email 
from customer 
where lower(email) = 'mary.smith@sakilacustomer.org';

-- Questao 07
-- 1. Funcao da Trigger
create or replace function fn_validate_rental_dates()
returns trigger as $$
begin
    if NEW.return_date is not null and NEW.return_date < NEW.rental_date then
        raise exception 'Data de devolucao invalida (%) anterior a data de locacao (%)!', 
            NEW.return_date, NEW.rental_date;
    end if;
    return NEW;
end;
$$ language plpgsql;

-- 2. Criacao da trigger before insert or update
create trigger trg_validate_rental_dates
before insert or update on rental
for each row
execute function fn_validate_rental_dates();

-- 3. Consultas de Teste:
-- Teste de Falha (Deve lancar excecao):
insert into rental (rental_date, inventory_id, customer_id, return_date, staff_id)
values ('2026-06-10 10:00:00', 1, 1, '2026-06-09 10:00:00', 1);

-- Teste de Sucesso (return_date posterior a rental_date):
insert into rental (rental_date, inventory_id, customer_id, return_date, staff_id)
values ('2026-06-10 10:00:00', 1, 1, '2026-06-12 10:00:00', 1);

-- Questao 08
-- 1. Criacao da tabela de auditoria
CREATE TABLE film_cost_audit (
    audit_id SERIAL PRIMARY KEY,
    film_id INT,
    old_cost NUMERIC(5,2),
    new_cost NUMERIC(5,2),
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 2. Funcao da Trigger
CREATE OR REPLACE FUNCTION fn_audit_film_cost()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO film_cost_audit (film_id, old_cost, new_cost)
    VALUES (NEW.film_id, OLD.replacement_cost, NEW.replacement_cost);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3. Criacao da Trigger AFTER UPDATE com a clausula WHEN
CREATE TRIGGER trg_film_cost_audit
AFTER UPDATE ON film
FOR EACH ROW
WHEN (OLD.replacement_cost IS DISTINCT FROM NEW.replacement_cost)
EXECUTE FUNCTION fn_audit_film_cost();

-- Questao 09
-- 1. Funcao da Trigger
CREATE OR REPLACE FUNCTION fn_protect_language_deletion()
RETURNS TRIGGER AS $$
DECLARE
    v_count INT;
BEGIN
    SELECT COUNT(*)
    INTO v_count
    FROM film
    WHERE language_id = OLD.language_id 
       OR original_language_id = OLD.language_id;

    IF v_count > 0 THEN
        RAISE EXCEPTION 'Operacao negada: Nao eh possivel excluir o idioma "%" (ID: %) pois existem % filme(s) vinculado(s) a ele.',
            OLD.name, OLD.language_id, v_count;
    END IF;

    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

-- 2. Criacao da Trigger BEFORE DELETE
CREATE TRIGGER trg_protect_language_delete
BEFORE DELETE ON language
FOR EACH ROW
EXECUTE FUNCTION fn_protect_language_deletion();

-- Questao 10
-- 1. Criacao da tabela de estatisticas de locacao por cliente
CREATE TABLE customer_rental_stats (
    customer_id INT PRIMARY KEY,
    total_rentals INT DEFAULT 0
);

-- 2. Populacao inicial com os dados atuais da base
INSERT INTO customer_rental_stats (customer_id, total_rentals)
SELECT customer_id, COUNT(*)
FROM rental
GROUP BY customer_id;

-- 3. Funcao da Trigger com logica de UPSERT (INSERT ... ON CONFLICT)
CREATE OR REPLACE FUNCTION fn_sync_customer_rental_stats()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO customer_rental_stats (customer_id, total_rentals)
    VALUES (NEW.customer_id, 1)
    ON CONFLICT (customer_id)
    DO UPDATE SET total_rentals = customer_rental_stats.total_rentals + 1;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 4. Criacao da Trigger AFTER INSERT
CREATE TRIGGER trg_sync_rental_stats
AFTER INSERT ON rental
FOR EACH ROW
EXECUTE FUNCTION fn_sync_customer_rental_stats();
