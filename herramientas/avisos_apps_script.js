// Copia del script de Google Apps Script que envía el resumen semanal por correo.
// Vive en script.google.com (proyecto "Avisos Archivo Fotografico Piscoya", cuenta piscoyacampos@gmail.com),
// publicado como "App web" (Ejecutar como: yo · Acceso: cualquiera). Supabase lo llama cada lunes (pg_cron).
// Para otra familia: crear un proyecto nuevo, pegar esto, cambiar DESTINO y NOMBRE, publicar y poner la URL en aviso_config.
const DESTINO = 'rlpiscoya@gmail.com';
const NOMBRE = 'Archivo Fotográfico Piscoya Rivera';

function doPost(e) {
  let d;
  try { d = JSON.parse(e.postData.contents); } catch (err) { return salida('json'); }
  if (!d || d.tipo !== 'resumen_v3' || !Array.isArray(d.registros)) return salida('formato');
  const regs = d.registros.slice(0, 300);
  const antiguos = Array.isArray(d.antiguos) ? d.antiguos.slice(0, 300) : [];
  if (!regs.length && !antiguos.length) return salida('vacio');
  const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const td = 'style="padding:7px 10px;border-bottom:1px solid #e2e2de;font-size:14px;vertical-align:top"';
  const btn = (url, txt) => '<a href="' + esc(url) + '" style="display:inline-block;padding:5px 10px;border-radius:4px;color:#b3261e;border:1px solid #b3261e;text-decoration:none;font-size:12px">' + txt + '</a>';
  const tabla = (filas, conBoton) => {
    const cab = ['Fecha', 'Nombre', 'Parentesco', 'Hijo/a de', 'Teléfono', 'Correo', 'Año nac.'].concat(conBoton ? [''] : []);
    return '<table style="border-collapse:collapse;margin:8px 0 18px"><tr>' + cab.map(h => '<th ' + td + ' align="left">' + h + '</th>').join('') + '</tr>' +
      filas.map(r => '<tr>' + [r.fecha, r.nombre, r.parentesco, r.hijo_de, r.telefono, r.correo, r.anio].map(v => '<td ' + td + '>' + esc(v) + '</td>').join('') +
        (conBoton ? '<td ' + td + '>' + (r.quitar ? btn(r.quitar, 'Quitar acceso') : esc(r.estado === 'rechazado' ? 'sin acceso' : '')) + '</td>' : '') + '</tr>').join('') + '</table>';
  };
  let html = '<div style="font-family:Arial,sans-serif;color:#111;max-width:900px"><h2 style="font-weight:600">' + NOMBRE + '</h2>';
  if (regs.length) html += '<h3>Familiares que entraron por primera vez esta semana (' + regs.length + ')</h3>' +
    '<p>Ya pueden ver el archivo. Si alguien no es de la familia, pulsa «Quitar acceso».</p>' + tabla(regs, true);
  if (antiguos.length) html += '<h3>Registrados con el formulario anterior (' + antiguos.length + ')</h3>' +
    '<p>Entran con «Ya estoy registrado», usando el mismo correo y año de nacimiento.</p>' + tabla(antiguos, false);
  html += '<p style="font-size:13px;color:#666">Familiares con acceso: ' + esc(d.total) + '. Archivo: <a href="' + esc(d.sitio) + '">' + esc(d.sitio) + '</a>' +
          ' (con tu cuenta verás también la sección Administrar).</p></div>';
  const asunto = regs.length ? 'Archivo familiar: ' + regs.length + (regs.length === 1 ? ' familiar nuevo esta semana' : ' familiares nuevos esta semana')
                             : 'Archivo familiar: registros anteriores';
  MailApp.sendEmail({ to: DESTINO, subject: asunto, htmlBody: html, name: NOMBRE });
  return salida('ok');
}

function salida(t) { return ContentService.createTextOutput(t); }
function autorizar() { MailApp.getRemainingDailyQuota(); }
