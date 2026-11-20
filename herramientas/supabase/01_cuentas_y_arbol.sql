-- Archivo fotográfico familiar: cuentas con aprobación, fotos privadas y árbol genealógico.
-- Se puede ejecutar varias veces (idempotente) en el SQL Editor de Supabase.

-- ===== Ajustes de la familia =====
create table if not exists public.ajustes (clave text primary key, valor text);
alter table public.ajustes enable row level security;
revoke all on public.ajustes from anon, authenticated;
insert into public.ajustes values
  ('correo_admin', 'rlpiscoya@gmail.com'),
  ('sitio', 'https://piscoya-web.github.io/archivo-fotografico-familia/')
on conflict (clave) do nothing;

create or replace function public.normalizar(t text) returns text language sql immutable as $$
  select regexp_replace(translate(lower(trim(coalesce(t, ''))), 'áéíóúüñàèìòù', 'aeiouunaeiou'), '\s+', ' ', 'g')
$$;

-- ===== Árbol genealógico =====
create table if not exists public.personas (
  id uuid primary key default gen_random_uuid(),
  nombre text not null,
  sexo char(1) check (sexo in ('M', 'F')),
  anio_nacimiento int,
  anio_fallecimiento int,
  fallecido boolean not null default false,
  padre_id uuid references public.personas(id) on delete set null,
  madre_id uuid references public.personas(id) on delete set null,
  notas text,
  por_confirmar boolean not null default false,
  creado timestamptz not null default now()
);
create table if not exists public.parejas (
  persona_a uuid not null references public.personas(id) on delete cascade,
  persona_b uuid not null references public.personas(id) on delete cascade,
  anio_union int,
  primary key (persona_a, persona_b)
);

-- ===== Miembros (cuentas) =====
create table if not exists public.miembros (
  user_id uuid primary key references auth.users(id) on delete cascade,
  nombre text not null,
  correo text not null,
  telefono text,
  anio_nacimiento int,
  parentesco text,
  hijo_de_texto text,
  acepta_arbol boolean not null default false,
  estado text not null default 'pendiente' check (estado in ('pendiente', 'aprobado', 'rechazado')),
  es_admin boolean not null default false,
  persona_id uuid references public.personas(id) on delete set null,
  token text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  creado timestamptz not null default now(),
  revisado timestamptz
);

create or replace function public.es_aprobado() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from miembros where user_id = auth.uid() and estado = 'aprobado')
$$;
create or replace function public.es_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from miembros where user_id = auth.uid() and estado = 'aprobado' and es_admin)
$$;

alter table public.personas enable row level security;
alter table public.parejas enable row level security;
alter table public.miembros enable row level security;
revoke all on public.personas, public.parejas, public.miembros from anon, authenticated;
grant select, insert, update, delete on public.personas, public.parejas to authenticated;
grant select on public.miembros to authenticated;

drop policy if exists "ver arbol" on public.personas;
drop policy if exists "editar arbol" on public.personas;
drop policy if exists "ver parejas" on public.parejas;
drop policy if exists "editar parejas" on public.parejas;
drop policy if exists "ver miembros" on public.miembros;
create policy "ver arbol" on public.personas for select to authenticated using (public.es_aprobado());
create policy "editar arbol" on public.personas for all to authenticated using (public.es_admin()) with check (public.es_admin());
create policy "ver parejas" on public.parejas for select to authenticated using (public.es_aprobado());
create policy "editar parejas" on public.parejas for all to authenticated using (public.es_admin()) with check (public.es_admin());
create policy "ver miembros" on public.miembros for select to authenticated using (user_id = auth.uid() or public.es_admin());

-- ===== Solicitud de acceso (después de crear la cuenta) =====
create or replace function public.solicitar_acceso(p_nombre text, p_telefono text, p_anio int, p_parentesco text,
                                                   p_hijo_de text, p_acepta_arbol boolean)
returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); mail text; adm text; previo boolean; est text; admin boolean := false;
begin
  if uid is null then return json_build_object('ok', false, 'error', 'sin_sesion'); end if;
  select lower(email) into mail from auth.users where id = uid;
  if exists (select 1 from miembros where user_id = uid) then
    return (select json_build_object('ok', true, 'estado', estado, 'nombre', nombre, 'es_admin', es_admin) from miembros where user_id = uid);
  end if;
  if coalesce(trim(p_nombre), '') = '' then return json_build_object('ok', false, 'error', 'datos_incompletos'); end if;
  select valor into adm from ajustes where clave = 'correo_admin';
  -- quien ya se había registrado con el formulario anterior (mismo correo y año) entra directo
  select exists (select 1 from formulario_familia where lower(trim(correo)) = mail and anio_nacimiento = p_anio) into previo;
  if mail = lower(adm) then admin := true; est := 'aprobado';
  elsif previo then est := 'aprobado';
  else est := 'pendiente'; end if;
  insert into miembros (user_id, nombre, correo, telefono, anio_nacimiento, parentesco, hijo_de_texto, acepta_arbol, estado, es_admin, revisado)
  values (uid, left(trim(p_nombre), 120), mail, left(trim(p_telefono), 30), p_anio, left(trim(p_parentesco), 80),
          left(trim(p_hijo_de), 120), coalesce(p_acepta_arbol, false), est, admin, case when est = 'aprobado' then now() end);
  if est = 'aprobado' then perform public._enlazar_arbol(uid); end if;
  return json_build_object('ok', true, 'estado', est, 'nombre', trim(p_nombre), 'es_admin', admin);
end $$;

create or replace function public.mi_estado() returns json language sql stable security definer set search_path = public as $$
  select coalesce((select json_build_object('estado', estado, 'nombre', nombre, 'es_admin', es_admin) from miembros where user_id = auth.uid()),
                  json_build_object('estado', 'sin_solicitud'))
$$;

-- Al aprobar: la persona entra al árbol (si lo aceptó), enlazada con su padre o madre si su nombre coincide.
create or replace function public._enlazar_arbol(uid uuid) returns void language plpgsql security definer set search_path = public as $$
declare m miembros; pid uuid; prog personas; n int;
begin
  select * into m from miembros where user_id = uid;
  if not found or not m.acepta_arbol or m.persona_id is not null then return; end if;
  -- ¿ya está en el árbol con su nombre?
  select count(*) into n from personas where normalizar(nombre) = normalizar(m.nombre);
  if n = 1 then
    select id into pid from personas where normalizar(nombre) = normalizar(m.nombre);
  else
    select count(*) into n from personas where normalizar(nombre) = normalizar(m.hijo_de_texto);
    if n = 1 then select * into prog from personas where normalizar(nombre) = normalizar(m.hijo_de_texto); end if;
    insert into personas (nombre, anio_nacimiento, padre_id, madre_id, por_confirmar)
    values (m.nombre, m.anio_nacimiento,
            case when prog.sexo = 'M' then prog.id end, case when prog.sexo = 'F' then prog.id end,
            prog.id is null)
    returning id into pid;
  end if;
  update miembros set persona_id = pid where user_id = uid;
end $$;

create or replace function public._revisar(uid uuid, p_aprobar boolean) returns json language plpgsql security definer set search_path = public as $$
declare m miembros;
begin
  select * into m from miembros where user_id = uid;
  if not found then return json_build_object('ok', false, 'error', 'no_existe'); end if;
  update miembros set estado = case when p_aprobar then 'aprobado' else 'rechazado' end, revisado = now() where user_id = uid;
  if p_aprobar then perform _enlazar_arbol(uid); end if;
  return json_build_object('ok', true, 'nombre', m.nombre, 'estado', case when p_aprobar then 'aprobado' else 'rechazado' end, 'antes', m.estado);
end $$;

-- Desde el enlace del correo semanal (no hace falta iniciar sesión: el enlace es la llave)
create or replace function public.revisar_por_token(p_token text, p_aprobar boolean) returns json
language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if length(coalesce(p_token, '')) < 40 then return json_build_object('ok', false, 'error', 'token'); end if;
  select user_id into uid from miembros where token = p_token;
  if uid is null then return json_build_object('ok', false, 'error', 'token'); end if;
  return _revisar(uid, p_aprobar);
end $$;

create or replace function public.admin_revisar(p_user uuid, p_aprobar boolean) returns json
language plpgsql security definer set search_path = public as $$
begin
  if not es_admin() then return json_build_object('ok', false, 'error', 'no_admin'); end if;
  return _revisar(p_user, p_aprobar);
end $$;

revoke all on function public._enlazar_arbol(uuid), public._revisar(uuid, boolean) from public, anon, authenticated;
revoke all on function public.solicitar_acceso(text, text, int, text, text, boolean), public.mi_estado(), public.admin_revisar(uuid, boolean),
              public.revisar_por_token(text, boolean) from public;
grant execute on function public.solicitar_acceso(text, text, int, text, text, boolean), public.mi_estado(), public.admin_revisar(uuid, boolean) to authenticated;
grant execute on function public.revisar_por_token(text, boolean) to anon, authenticated;
grant execute on function public.es_aprobado(), public.es_admin() to authenticated;

-- ===== Fotos privadas =====
insert into storage.buckets (id, name, public) values ('archivo', 'archivo', false) on conflict (id) do update set public = false;
drop policy if exists "aprobados leen archivo" on storage.objects;
drop policy if exists "admin sube archivo" on storage.objects;
drop policy if exists "admin cambia archivo" on storage.objects;
create policy "aprobados leen archivo" on storage.objects for select to authenticated using (bucket_id = 'archivo' and public.es_aprobado());
create policy "admin sube archivo" on storage.objects for insert to authenticated with check (bucket_id = 'archivo' and public.es_admin());
create policy "admin cambia archivo" on storage.objects for update to authenticated using (bucket_id = 'archivo' and public.es_admin());

-- El almacenamiento antiguo ('photos') era público: se cierra. Y las tablas antiguas de fotos dejan de leerse sin cuenta.
update storage.buckets set public = false where id = 'photos';
drop policy if exists "Lectura publica de albums" on public.albums;
revoke all on public.albums, public.photos from anon;
-- el acceso antiguo (correo + año) ya no se usa
revoke all on function public.acceso_familia(text, int, boolean, text, text, text) from anon, authenticated;

select 'ok' as resultado;
