-- «Unir personas»: cuando la misma persona quedó dos veces en el árbol.
-- Pasa a la ficha que se conserva todo lo que apuntaba a la otra (etiquetas en fotos, padre/madre de sus hijos,
-- parejas, su propio padre y madre, la cuenta de miembro) y después borra la duplicada.
-- Los datos que la ficha conservada no tenga (sexo, años, padres, notas) se completan con los de la duplicada.
-- Se puede ejecutar varias veces en el SQL Editor de Supabase.

create or replace function public.admin_unir_personas(p_conservar uuid, p_borrar uuid)
returns json language plpgsql security definer set search_path = public as $$
declare k personas; d personas; n_etq int; n_hijos int; n_par int; n_miem int;
begin
  if not es_admin() then return json_build_object('ok', false, 'error', 'no_admin'); end if;
  if p_conservar is null or p_borrar is null or p_conservar = p_borrar then
    return json_build_object('ok', false, 'error', 'elige_dos_personas');
  end if;
  select * into k from personas where id = p_conservar;
  if not found then return json_build_object('ok', false, 'error', 'no_existe_conservar'); end if;
  select * into d from personas where id = p_borrar;
  if not found then return json_build_object('ok', false, 'error', 'no_existe_borrar'); end if;

  -- etiquetas y aportes de las fotos
  update etiquetas set persona_id = p_conservar where persona_id = p_borrar;
  get diagnostics n_etq = row_count;

  -- hijos: quien tenía a la duplicada como padre o madre
  update personas set padre_id = p_conservar where padre_id = p_borrar and id <> p_conservar;
  get diagnostics n_hijos = row_count;
  update personas set madre_id = p_conservar where madre_id = p_borrar and id <> p_conservar;
  get diagnostics n_par = row_count;
  n_hijos := n_hijos + n_par;

  -- parejas: se pasan a la conservada (sin repetir y sin emparejarla consigo misma)
  insert into parejas (persona_a, persona_b, anio_union)
  select p_conservar, case when x.persona_a = p_borrar then x.persona_b else x.persona_a end, x.anio_union
    from parejas x
   where (x.persona_a = p_borrar or x.persona_b = p_borrar)
     and (case when x.persona_a = p_borrar then x.persona_b else x.persona_a end) <> p_conservar
     and not exists (select 1 from parejas y
                      where (y.persona_a = p_conservar and y.persona_b = case when x.persona_a = p_borrar then x.persona_b else x.persona_a end)
                         or (y.persona_b = p_conservar and y.persona_a = case when x.persona_a = p_borrar then x.persona_b else x.persona_a end));
  get diagnostics n_par = row_count;
  delete from parejas where persona_a = p_borrar or persona_b = p_borrar;

  -- la cuenta de miembro enlazada
  update miembros set persona_id = p_conservar where persona_id = p_borrar;
  get diagnostics n_miem = row_count;

  -- completar lo que falte en la ficha conservada
  update personas set
    sexo = coalesce(k.sexo, d.sexo),
    anio_nacimiento = coalesce(k.anio_nacimiento, d.anio_nacimiento),
    anio_fallecimiento = coalesce(k.anio_fallecimiento, d.anio_fallecimiento),
    fallecido = k.fallecido or d.fallecido,
    padre_id = coalesce(k.padre_id, nullif(d.padre_id, p_conservar)),
    madre_id = coalesce(k.madre_id, nullif(d.madre_id, p_conservar)),
    notas = nullif(concat_ws(E'\n', nullif(trim(k.notas), ''), nullif(trim(d.notas), '')), '')
  where id = p_conservar;

  delete from personas where id = p_borrar;

  return json_build_object('ok', true, 'conservada', k.nombre, 'borrada', d.nombre,
                           'etiquetas', n_etq, 'hijos', n_hijos, 'parejas', n_par, 'miembros', n_miem);
end $$;

revoke all on function public.admin_unir_personas(uuid, uuid) from public, anon;
grant execute on function public.admin_unir_personas(uuid, uuid) to authenticated;

select 'ok' as resultado;
