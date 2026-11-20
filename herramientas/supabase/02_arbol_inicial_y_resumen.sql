-- Núcleo del árbol (sacado del inventario de fotos; marcado "por confirmar" para que la familia lo revise)
do $$
declare teo uuid; agu uuid; leo uuid; ale uuid; rlu uuid;
begin
  if exists (select 1 from public.personas) then return; end if;
  insert into personas (nombre, sexo, fallecido, por_confirmar) values ('José Teódulo Piscoya Guevara', 'M', false, true) returning id into teo;
  insert into personas (nombre, sexo, por_confirmar) values ('Agustina Arbañil Chapoñán de Piscoya', 'F', true) returning id into agu;
  insert into parejas values (teo, agu, null);
  insert into personas (nombre, sexo, padre_id, madre_id, por_confirmar) values ('José Leonardo Piscoya Arbañil', 'M', teo, agu, true) returning id into leo;
  insert into personas (nombre, sexo, padre_id, madre_id, por_confirmar) values
    ('César Piscoya Arbañil', 'M', teo, agu, true), ('Marco Piscoya Arbañil', 'M', teo, agu, true),
    ('Julio Piscoya Arbañil', 'M', teo, agu, true), ('Rosario Piscoya Arbañil', 'F', teo, agu, true);
  insert into personas (nombre, sexo, por_confirmar) values ('Alejandro Rivera Márquez', 'M', true) returning id into ale;
  insert into personas (nombre, sexo, padre_id, por_confirmar) values ('Rosa Luz Rivera de Piscoya', 'F', ale, true) returning id into rlu;
  insert into parejas values (leo, rlu, 1971);
  insert into personas (nombre, sexo, padre_id, madre_id, por_confirmar) values
    ('Rosita Luz Piscoya Rivera', 'F', leo, rlu, true), ('Leonardo Piscoya Rivera', 'M', leo, rlu, true),
    ('José Alejandro Piscoya Rivera', 'M', leo, rlu, true), ('Rosa María Piscoya Rivera', 'F', leo, rlu, true);
end $$;

-- Resumen semanal: registros nuevos + solicitudes pendientes con enlaces para aprobar o rechazar
update public.aviso_config set url = 'https://script.google.com/macros/s/AKfycby5LEuWP6L1fK5EQDtmCt11sqDbZTEeXB5tkjqrB1ezsjPklPRrW1nwyJFHMTNN8wIhOg/exec' where id = 1;

create or replace function public.enviar_resumen_registros() returns text
language plpgsql security definer set search_path = public as $fn$
declare cfg record; sitio text; nuevos json; n int; pend int; total int; antiguos json;
begin
  select * into cfg from aviso_config where id = 1;
  if cfg.url is null then return 'sin_url'; end if;
  select valor into sitio from ajustes where clave = 'sitio';
  select count(*) into total from miembros where estado = 'aprobado';
  select count(*) into pend from miembros where estado = 'pendiente';
  select json_agg(json_build_object(
           'fecha', to_char(creado at time zone 'America/Lima', 'DD/MM/YYYY'),
           'nombre', nombre, 'parentesco', parentesco, 'hijo_de', hijo_de_texto, 'telefono', telefono,
           'correo', correo, 'anio', anio_nacimiento, 'estado', estado,
           'aprobar', case when estado = 'pendiente' then sitio || '#/revisar/' || token || '/si' end,
           'rechazar', case when estado = 'pendiente' then sitio || '#/revisar/' || token || '/no' end) order by creado),
         count(*)
    into nuevos, n
    from miembros
   where estado = 'pendiente' or cfg.ultimo_envio is null or creado > cfg.ultimo_envio;
  if cfg.ultimo_envio is null then
    select json_agg(json_build_object('fecha', to_char(created_at at time zone 'America/Lima', 'DD/MM/YYYY'), 'nombre', nombre_completo,
             'parentesco', parentesco, 'telefono', telefono, 'correo', correo, 'anio', anio_nacimiento) order by created_at)
      into antiguos from formulario_familia;
  end if;
  if n = 0 and antiguos is null then return 'sin_novedades'; end if;
  perform net.http_post(
    url := cfg.url,
    body := jsonb_build_object('tipo', 'resumen_v2', 'registros', coalesce(nuevos, '[]'::json), 'antiguos', antiguos,
                               'pendientes', pend, 'total', total, 'sitio', sitio),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 20000);
  update aviso_config set ultimo_envio = now() where id = 1;
  return 'enviado ' || n || ' + ' || coalesce(json_array_length(antiguos), 0) || ' antiguos';
end $fn$;
revoke all on function public.enviar_resumen_registros() from public, anon, authenticated;

select count(*) as personas from public.personas;
