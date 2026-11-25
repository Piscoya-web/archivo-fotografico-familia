-- Aportes que ya están en el árbol: no se vuelven a ofrecer en Administrar.
-- 1) admin_marcar_en_arbol: cierra la etiqueta como «en el árbol» sin tocar el árbol.
-- 2) admin_revisar_etiqueta ya no crea una persona repetida: si alguien con el mismo nombre ya está, usa esa,
--    y no repite parejas escritas al revés.
-- Se puede ejecutar varias veces en el SQL Editor de Supabase.

create or replace function public.admin_marcar_en_arbol(p_id uuid, p_persona uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then return json_build_object('ok', false, 'error', 'no_admin'); end if;
  update etiquetas set persona_id = coalesce(p_persona, persona_id), arbol = 'aplicada', revisado = now()
   where id = p_id and arbol = 'pendiente';
  return json_build_object('ok', found);
end $$;
revoke all on function public.admin_marcar_en_arbol(uuid, uuid) from public, anon;
grant execute on function public.admin_marcar_en_arbol(uuid, uuid) to authenticated;

create or replace function public.admin_revisar_etiqueta(p_id uuid, p_persona uuid, p_aplicar boolean)
returns json language plpgsql security definer set search_path = public as $$
declare e etiquetas; m miembros; destino uuid := p_persona; yo_p uuid; yo_sexo char(1); n int;
begin
  if not es_admin() then return json_build_object('ok', false, 'error', 'no_admin'); end if;
  select * into e from etiquetas where id = p_id;
  if not found then return json_build_object('ok', false, 'error', 'no_existe'); end if;
  if not p_aplicar then
    update etiquetas set arbol = 'rechazada', revisado = now() where id = p_id;
    return json_build_object('ok', true, 'arbol', 'rechazada');
  end if;
  -- persona de la foto: la elegida, la que ya tenía, la que ya está con ese nombre, o una nueva
  destino := coalesce(destino, e.persona_id);
  if destino is null and coalesce(trim(e.nombre_texto), '') <> '' then
    select count(*) into n from personas where normalizar(nombre) = normalizar(e.nombre_texto);
    if n = 1 then select id into destino from personas where normalizar(nombre) = normalizar(e.nombre_texto); end if;
  end if;
  if destino is null then
    insert into personas (nombre, por_confirmar) values (coalesce(nullif(trim(e.nombre_texto), ''), 'Sin nombre'), true) returning id into destino;
  end if;
  update etiquetas set persona_id = destino where id = p_id;
  if e.relacion <> 'otro' and e.autor is not null then
    select * into m from miembros where user_id = e.autor;
    if found then
      if e.relacion = 'yo' then
        update miembros set persona_id = destino where user_id = e.autor;
      else
        yo_p := m.persona_id;
        if yo_p is null then
          select count(*) into n from personas where normalizar(nombre) = normalizar(m.nombre);
          if n = 1 then select id into yo_p from personas where normalizar(nombre) = normalizar(m.nombre);
          else insert into personas (nombre, anio_nacimiento, por_confirmar) values (m.nombre, m.anio_nacimiento, true) returning id into yo_p; end if;
          update miembros set persona_id = yo_p where user_id = e.autor;
        end if;
        select sexo into yo_sexo from personas where id = yo_p;
        if e.relacion = 'padre' then
          update personas set padre_id = destino where id = yo_p;
          update personas set sexo = coalesce(sexo, 'M') where id = destino;
        elsif e.relacion = 'madre' then
          update personas set madre_id = destino where id = yo_p;
          update personas set sexo = coalesce(sexo, 'F') where id = destino;
        elsif e.relacion = 'hijo' then
          if not exists (select 1 from personas where id = destino and yo_p in (padre_id, madre_id)) then
            if yo_sexo = 'F' then update personas set madre_id = yo_p where id = destino;
            else update personas set padre_id = yo_p where id = destino; end if;
          end if;
        elsif e.relacion = 'pareja' and yo_p <> destino then
          insert into parejas (persona_a, persona_b)
          select yo_p, destino where not exists (select 1 from parejas
            where (persona_a = yo_p and persona_b = destino) or (persona_a = destino and persona_b = yo_p));
        end if;
      end if;
    end if;
  end if;
  update etiquetas set arbol = 'aplicada', revisado = now() where id = p_id;
  return json_build_object('ok', true, 'arbol', 'aplicada', 'persona', destino);
end $$;
revoke all on function public.admin_revisar_etiqueta(uuid, uuid, boolean) from public, anon;
grant execute on function public.admin_revisar_etiqueta(uuid, uuid, boolean) to authenticated;

select 'ok' as resultado;
