# archivo-fotografico-familia

Web responsive para el archivo y árbol genealógico familiar Piscoya Rivera.

Publicada con GitHub Pages: https://piscoya-web.github.io/archivo-fotografico-familia/

## Cómo está hecha

- `index.html`: toda la web (álbumes, historias, buscador y visor de fotos).
- `albums.json`: los álbumes y, por cada foto, su año, lugar, personas e historia (sale del inventario).
- `fotos/`: las fotos en tamaño grande (WebP). `mini/`: las miniaturas que se ven en las cuadrículas.
- Supabase se usa **solo** para el registro de familiares (función `acceso_familia`). Si Supabase se pausa,
  la galería se sigue viendo; solo deja de guardarse quién se registra.
- `.github/workflows/keep-alive.yml`: escribe un latido en Supabase los lunes y jueves para que no se pause.

## Añadir o corregir una historia

Edita la foto en `albums.json` (campos `anio`, `lugar`, `personas`, `historia`) y guarda. GitHub Pages
publica el cambio en un minuto.

## Añadir páginas o fotos nuevas

`herramientas/procesar_album.py` trabaja sobre la carpeta de cada álbum escaneado y solo procesa lo nuevo:

1. `recortar`: detecta las fotos de cada página nueva de `01_Paginas…`, las recorta y endereza en `02_Recortes…`.
2. Revisar `revision_recortes.jpg` y anotar en `giros.json` las fotos que están de lado.
3. `exportar`: mejora color y contraste (`herramientas/mejorar.py`) y crea `03_JPG_Finales…` y `04_webpage…`.
   Los JPG que se pongan a mano en `03_…` también reciben su versión web.
4. `publicar`: copia lo nuevo a `fotos/` y `mini/` y lo añade a `albums.json` sin tocar las historias ya escritas.

Los recortes de `02_…` se guardan sin retocar: la mejora de color se puede rehacer cuando se quiera.

## Copias de seguridad

Los originales (TIF/PSD/JPG) están en el disco local `SCAN PISCOYA RIVERA` y en Google Drive.
Este repositorio guarda una copia completa de la versión web.
