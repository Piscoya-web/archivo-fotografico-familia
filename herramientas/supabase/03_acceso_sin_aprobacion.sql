-- Acceso inmediato: quien se registra entra al momento (la clave es su correo + año de nacimiento).
-- La administradora recibe el resumen semanal con un botón para quitar el acceso a quien no corresponda.

create or replace function public.solicitar_acceso(p_nombre text, p_telefono text, p_anio int, p_parentesco text,
                                                   p_hijo_de text, p_acepta_arbol boolean)
returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); mail text; adm text; admin boolean := false; ant record;
begin
  if uid is null then return json_build_object('ok', false, 'error', 'sin_sesion'); end if;
  select lower(email) into mail from auth.users where id = uid;
  if exists (select 1 from miembros where user_id = uid) then
    return (select json_build_object('ok', true, 'estado', estado, 'nombre', nombre, 'es_admin', es_admin) from miembros where user_id = uid);
  end if;
  -- datos del formulario anterior, si se había registrado antes
  select * into ant from formulario_familia where lower(trim(correo)) = mail order by created_at limit 1;
  p_nombre := coalesce(nullif(trim(p_nombre), ''), ant.nombre_completo);
  if coalesce(p_nombre, '') = '' then return json_build_object('ok', false, 'error', 'datos_incompletos'); end if;
  select valor into adm from ajustes where clave = 'correo_admin';
  admin := mail = any (string_to_array(replace(lower(adm), ' ', ''), ','));
  insert into miembros (user_id, nombre, correo, telefono, anio_nacimiento, parentesco, hijo_de_texto, acepta_arbol, estado, es_admin, revisado)
  values (uid, left(p_nombre, 120), mail, left(coalesce(nullif(trim(p_telefono), ''), ant.telefono), 30), coalesce(p_anio, ant.anio_nacimiento),
          left(coalesce(nullif(trim(p_parentesco), ''), ant.parentesco), 80), left(trim(p_hijo_de), 120), coalesce(p_acepta_arbol, true),
          'aprobado', admin, now());
  perform public._enlazar_arbol(uid);
  return json_build_object('ok', true, 'estado', 'aprobado', 'nombre', p_nombre, 'es_admin', admin);
end $$;

-- ¿Se registró con el formulario anterior (correo + año) y aún no tiene cuenta? Así entra con "Ya estoy registrado".
create or replace function public.registro_anterior(p_correo text, p_anio int) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('ok', exists (
    select 1 from formulario_familia f
     where lower(trim(f.correo)) = lower(trim(p_correo)) and f.anio_nacimiento = p_anio
       and not exists (select 1 from auth.users u where lower(u.email) = lower(trim(p_correo)))))
$$;
revoke all on function public.registro_anterior(text, int) from public;
grant execute on function public.registro_anterior(text, int) to anon, authenticated;

-- Quien quedó "pendiente" con el sistema anterior, entra.
update public.miembros set estado = 'aprobado', revisado = now() where estado = 'pendiente';

-- Resumen semanal: familiares nuevos con botón "Quitar acceso"
create or replace function public.enviar_resumen_registros() returns text
language plpgsql security definer set search_path = public as $fn$
declare cfg record; sitio text; nuevos json; n int; total int; antiguos json;
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
    from miembros
   where cfg.ultimo_envio is null or creado > cfg.ultimo_envio;
  if cfg.ultimo_envio is null then
    select json_agg(json_build_object('fecha', to_char(created_at at time zone 'America/Lima', 'DD/MM/YYYY'), 'nombre', nombre_completo,
             'parentesco', parentesco, 'telefono', telefono, 'correo', correo, 'anio', anio_nacimiento) order by created_at)
      into antiguos from formulario_familia;
  end if;
  if n = 0 and antiguos is null then return 'sin_novedades'; end if;
  perform net.http_post(
    url := cfg.url,
    body := jsonb_build_object('tipo', 'resumen_v3', 'registros', coalesce(nuevos, '[]'::json), 'antiguos', antiguos, 'total', total, 'sitio', sitio),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 20000);
  update aviso_config set ultimo_envio = now() where id = 1;
  return 'enviado ' || n || ' + ' || coalesce(json_array_length(antiguos), 0) || ' antiguos';
end $fn$;
revoke all on function public.enviar_resumen_registros() from public, anon, authenticated;

select nombre, correo, estado, es_admin, creado from public.miembros order by creado;
