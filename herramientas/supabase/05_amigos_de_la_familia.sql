-- Los amigos de la familia (parentesco «Amigo/a de la familia») no entran al árbol,
-- tampoco si entran con «Ya estoy registrado» desde el formulario anterior.
create or replace function public.solicitar_acceso(p_nombre text, p_telefono text, p_anio int, p_parentesco text,
                                                   p_hijo_de text, p_acepta_arbol boolean)
returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); mail text; adm text; admin boolean := false; ant record; par text;
begin
  if uid is null then return json_build_object('ok', false, 'error', 'sin_sesion'); end if;
  select lower(email) into mail from auth.users where id = uid;
  if exists (select 1 from miembros where user_id = uid) then
    return (select json_build_object('ok', true, 'estado', estado, 'nombre', nombre, 'es_admin', es_admin, 'persona_id', persona_id) from miembros where user_id = uid);
  end if;
  select * into ant from formulario_familia where lower(trim(correo)) = mail order by created_at limit 1;
  p_nombre := coalesce(nullif(trim(p_nombre), ''), ant.nombre_completo);
  if coalesce(p_nombre, '') = '' then return json_build_object('ok', false, 'error', 'datos_incompletos'); end if;
  par := left(coalesce(nullif(trim(p_parentesco), ''), ant.parentesco), 80);
  select valor into adm from ajustes where clave = 'correo_admin';
  admin := mail = any (string_to_array(replace(lower(adm), ' ', ''), ','));
  insert into miembros (user_id, nombre, correo, telefono, anio_nacimiento, parentesco, hijo_de_texto, acepta_arbol, estado, es_admin, revisado)
  values (uid, left(p_nombre, 120), mail, left(coalesce(nullif(trim(p_telefono), ''), ant.telefono), 30), coalesce(p_anio, ant.anio_nacimiento),
          par, left(trim(p_hijo_de), 120), coalesce(p_acepta_arbol, true) and coalesce(normalizar(par), '') not like 'amig%',
          'aprobado', admin, now());
  perform public._enlazar_arbol(uid);
  return json_build_object('ok', true, 'estado', 'aprobado', 'nombre', p_nombre, 'es_admin', admin);
end $$;
