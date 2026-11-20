-- «Reconozco a alguien en esta foto»: etiquetas y recuerdos de la familia.
-- Las etiquetas y los recuerdos se ven al momento. Los enlaces del árbol («es mi papá») esperan la revisión del administrador.

create table if not exists public.etiquetas (
  id uuid primary key default gen_random_uuid(),
  foto text not null,                         -- 'album_id/archivo.webp'
  persona_id uuid references public.personas(id) on delete set null,
  nombre_texto text,                          -- lo que escribió el familiar
  relacion text not null default 'otro' check (relacion in ('yo', 'padre', 'madre', 'hijo', 'pareja', 'otro')),
  nota text,                                  -- dónde está en la foto, recuerdo…
  autor uuid references auth.users(id) on delete set null,
  autor_nombre text,
  arbol text not null default 'no_aplica' check (arbol in ('no_aplica', 'pendiente', 'aplicada', 'rechazada')),
  oculta boolean not null default false,
  creado timestamptz not null default now(),
  revisado timestamptz
);
create index if not exists etiquetas_foto on public.etiquetas (foto);
create index if not exists etiquetas_persona on public.etiquetas (persona_id);

alter table public.etiquetas enable row level security;
revoke all on public.etiquetas from anon, authenticated;
grant select on public.etiquetas to authenticated;
drop policy if exists "ver etiquetas" on public.etiquetas;
create policy "ver etiquetas" on public.etiquetas for select to authenticated using (public.es_aprobado() and (not oculta or public.es_admin()));

-- Un familiar aporta una etiqueta (y, si es pariente suyo, una propuesta para el árbol)
create or replace function public.aportar(p_foto text, p_persona uuid, p_nombre text, p_relacion text, p_nota text)
returns json language plpgsql security definer set search_path = public as $$
declare m miembros; nuevo uuid; rel text := coalesce(nullif(p_relacion, ''), 'otro');
begin
  if not es_aprobado() then return json_build_object('ok', false, 'error', 'sin_acceso'); end if;
  if coalesce(trim(p_foto), '') = '' or (p_persona is null and coalesce(trim(p_nombre), '') = '') then
    return json_build_object('ok', false, 'error', 'datos_incompletos');
  end if;
  if rel not in ('yo', 'padre', 'madre', 'hijo', 'pareja', 'otro') then rel := 'otro'; end if;
  select * into m from miembros where user_id = auth.uid();
  insert into etiquetas (foto, persona_id, nombre_texto, relacion, nota, autor, autor_nombre, arbol)
  values (left(trim(p_foto), 200), p_persona, left(trim(p_nombre), 120), rel, left(trim(p_nota), 1000), auth.uid(), m.nombre,
          case when rel <> 'otro' or p_persona is null then 'pendiente' else 'no_aplica' end)
  returning id into nuevo;
  return json_build_object('ok', true, 'id', nuevo);
end $$;

-- El autor puede borrar lo suyo; el administrador, cualquier etiqueta
create or replace function public.borrar_etiqueta(p_id uuid) returns json
language plpgsql security definer set search_path = public as $$
begin
  delete from etiquetas where id = p_id and (autor = auth.uid() or es_admin());
  return json_build_object('ok', found);
end $$;

-- El administrador revisa: enlaza la etiqueta con una persona del árbol y aplica el parentesco
create or replace function public.admin_revisar_etiqueta(p_id uuid, p_persona uuid, p_aplicar boolean)
returns json language plpgsql security definer set search_path = public as $$
declare e etiquetas; m miembros; destino uuid := p_persona; yo_p uuid; yo_sexo char(1);
begin
  if not es_admin() then return json_build_object('ok', false, 'error', 'no_admin'); end if;
  select * into e from etiquetas where id = p_id;
  if not found then return json_build_object('ok', false, 'error', 'no_existe'); end if;
  if not p_aplicar then
    update etiquetas set arbol = 'rechazada', revisado = now() where id = p_id;
    return json_build_object('ok', true, 'arbol', 'rechazada');
  end if;
  -- persona de la foto: la elegida, la que ya tenía, o una nueva con el nombre escrito
  destino := coalesce(destino, e.persona_id);
  if destino is null then
    insert into personas (nombre, por_confirmar) values (coalesce(nullif(trim(e.nombre_texto), ''), 'Sin nombre'), true) returning id into destino;
  end if;
  update etiquetas set persona_id = destino where id = p_id;
  -- persona del autor en el árbol (se crea si aún no estaba)
  if e.relacion <> 'otro' and e.autor is not null then
    select * into m from miembros where user_id = e.autor;
    if found then
      if e.relacion = 'yo' then
        update miembros set persona_id = destino where user_id = e.autor;
      else
        yo_p := m.persona_id;
        if yo_p is null then
          insert into personas (nombre, anio_nacimiento, por_confirmar) values (m.nombre, m.anio_nacimiento, true) returning id into yo_p;
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
          if yo_sexo = 'F' then update personas set madre_id = yo_p where id = destino;
          else update personas set padre_id = yo_p where id = destino; end if;
        elsif e.relacion = 'pareja' then
          insert into parejas (persona_a, persona_b) values (yo_p, destino) on conflict do nothing;
        end if;
      end if;
    end if;
  end if;
  update etiquetas set arbol = 'aplicada', revisado = now() where id = p_id;
  return json_build_object('ok', true, 'arbol', 'aplicada', 'persona', destino);
end $$;

revoke all on function public.aportar(text, uuid, text, text, text), public.borrar_etiqueta(uuid),
              public.admin_revisar_etiqueta(uuid, uuid, boolean) from public, anon;
grant execute on function public.aportar(text, uuid, text, text, text), public.borrar_etiqueta(uuid),
              public.admin_revisar_etiqueta(uuid, uuid, boolean) to authenticated;

-- Para «Mi rama»: el estado del miembro incluye su persona en el árbol
create or replace function public.mi_estado() returns json language sql stable security definer set search_path = public as $$
  select coalesce((select json_build_object('estado', estado, 'nombre', nombre, 'es_admin', es_admin, 'persona_id', persona_id)
                     from miembros where user_id = auth.uid()),
                  json_build_object('estado', 'sin_solicitud'))
$$;

-- El resumen semanal también cuenta los aportes nuevos y los pendientes de revisar
create or replace function public.enviar_resumen_registros() returns text
language plpgsql security definer set search_path = public as $fn$
declare cfg record; sitio text; nuevos json; n int; total int; antiguos json; aportes json; na int; pend int;
begin
  select * into cfg from aviso_config where id = 1;
  if cfg.url is null then return 'sin_url'; end if;
  select valor into sitio from ajustes where clave = 'sitio';
  select count(*) into total from miembros where estado = 'aprobado';
  select json_agg(json_build_object(
           'fecha', to_char(creado at time zone 'America/Lima', 'DD/MM/YYYY'),
           'nombre', nombre, 'parentesco', parentesco, 'hijo_de', hijo_de_texto, 'telefono', telefono,
           'correo', correo, 'anio', anio_nacimiento, 'estado', estado,
           'quitar', case when estado = 'aprobado' and not es_admin then sitio || '#/revisar/' || token || '/no' end) order by creado),
         count(*)
    into nuevos, n
    from miembros where cfg.ultimo_envio is null or creado > cfg.ultimo_envio;
  if cfg.ultimo_envio is null then
    select json_agg(json_build_object('fecha', to_char(created_at at time zone 'America/Lima', 'DD/MM/YYYY'), 'nombre', nombre_completo,
             'parentesco', parentesco, 'telefono', telefono, 'correo', correo, 'anio', anio_nacimiento) order by created_at)
      into antiguos from formulario_familia;
  end if;
  select json_agg(json_build_object('fecha', to_char(creado at time zone 'America/Lima', 'DD/MM/YYYY'), 'autor', autor_nombre,
           'nombre', coalesce(nombre_texto, (select nombre from personas p where p.id = persona_id)), 'relacion', relacion, 'nota', nota,
           'arbol', arbol) order by creado), count(*)
    into aportes, na
    from etiquetas where cfg.ultimo_envio is null or creado > cfg.ultimo_envio;
  select count(*) into pend from etiquetas where arbol = 'pendiente';
  if n = 0 and antiguos is null and na = 0 and pend = 0 then return 'sin_novedades'; end if;
  perform net.http_post(
    url := cfg.url,
    body := jsonb_build_object('tipo', 'resumen_v4', 'registros', coalesce(nuevos, '[]'::json), 'antiguos', antiguos, 'total', total,
                               'aportes', coalesce(aportes, '[]'::json), 'pendientes_arbol', pend, 'sitio', sitio),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 20000);
  update aviso_config set ultimo_envio = now() where id = 1;
  return 'enviado ' || n || ' registros, ' || na || ' aportes, ' || pend || ' por revisar';
end $fn$;
revoke all on function public.enviar_resumen_registros() from public, anon, authenticated;

select 'ok' as resultado;
