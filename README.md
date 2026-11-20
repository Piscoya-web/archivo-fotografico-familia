# archivo-fotografico-familia

Web del archivo fotográfico y árbol familiar Piscoya Rivera: https://piscoya-web.github.io/archivo-fotografico-familia/

Este repositorio tiene **solo el código**. Las fotos, las historias y los datos de la familia son privados: viven en el
almacenamiento privado de Supabase y solo los ve quien se registra.

## Cómo funciona

- `index.html`: toda la web (registro, álbumes, historias, buscador, árbol familiar y sección Administrar).
- Registro: cada familiar deja sus datos y entra con su **correo + año de nacimiento**. Entra al momento.
- Supabase: cuentas, árbol (`personas`, `parejas`), miembros y fotos privadas (bucket `archivo`).
  Los scripts SQL están en `herramientas/supabase/`.
- Resumen semanal por correo a la dueña del archivo (Supabase `pg_cron` + Google Apps Script,
  `herramientas/avisos_apps_script.js`), con un botón para quitar el acceso.
- `.github/workflows/keep-alive.yml`: escribe un «latido» en Supabase dos veces por semana para que no se pause.

## Añadir fotos

En la computadora del administrador, con `herramientas/procesar_album.py` (recortar → girar → exportar → publicar) y
luego, en la web, **Administrar › Subir fotos** eligiendo la carpeta local del sitio. Las fotos nunca se suben a GitHub
(`.gitignore`).
