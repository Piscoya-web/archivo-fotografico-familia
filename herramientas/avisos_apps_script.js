// Copia del script de Google Apps Script que envía los resúmenes semanales por correo.
// Vive en script.google.com (proyecto "Avisos Archivo Fotografico Piscoya", cuenta piscoyacampos@gmail.com),
// publicado como "App web" (Ejecutar como: yo · Acceso: cualquiera). Supabase lo llama cada lunes (pg_cron).
// Para otra familia: crear un proyecto nuevo, pegar esto, cambiar DUENA, ADMIN y NOMBRE, publicar y poner la URL en aviso_config.
const DUENA = 'rlpiscoya@gmail.com';       // recibe quién entró al archivo, con «Quitar acceso»
const ADMIN = 'piscoyacampos@gmail.com';   // recibe los aportes de la familia y lo que falta revisar en el árbol
const NOMBRE = 'Archivo Fotográfico Piscoya Rivera';

const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const TD = 'style="padding:7px 10px;border-bottom:1px solid #e2e2de;font-size:14px;vertical-align:top"';
const tabla = (cab, filas) => '<table style="border-collapse:collapse;margin:8px 0 18px"><tr>' +
  cab.map(h => '<th ' + TD + ' align="left">' + h + '</th>').join('') + '</tr>' +
  filas.map(f => '<tr>' + f.map(v => '<td ' + TD + '>' + v + '</td>').join('') + '</tr>').join('') + '</table>';
const pie = d => '<p style="font-size:13px;color:#666">Archivo: <a href="' + esc(d.sitio) + '">' + esc(d.sitio) + '</a></p></div>';
const cabecera = () => '<div style="font-family:Arial,sans-serif;color:#111;max-width:900px"><h2 style="font-weight:600">' + NOMBRE + '</h2>';

function doPost(e) {
  let d;
  try { d = JSON.parse(e.postData.contents); } catch (err) { return salida('json'); }
  if (!d || d.tipo !== 'resumen_v4' || !Array.isArray(d.registros)) return salida('formato');
  const regs = d.registros.slice(0, 300);
  const antiguos = Array.isArray(d.antiguos) ? d.antiguos.slice(0, 300) : [];
  const aportes = Array.isArray(d.aportes) ? d.aportes.slice(0, 300) : [];
  const pend = Number(d.pendientes_arbol || 0);

  // 1) A la dueña: quién entró
  if (regs.length || antiguos.length) {
    const btn = url => '<a href="' + esc(url) + '" style="display:inline-block;padding:5px 10px;border-radius:4px;color:#b3261e;border:1px solid #b3261e;text-decoration:none;font-size:12px">Quitar acceso</a>';
    const cab = ['Fecha', 'Nombre', 'Parentesco', 'Hijo/a de', 'Teléfono', 'Correo', 'Año nac.'];
    let html = cabecera();
    if (regs.length) html += '<h3>Familiares que entraron por primera vez esta semana (' + regs.length + ')</h3>' +
      '<p>Ya pueden ver el archivo. Si alguien no es de la familia, pulsa «Quitar acceso».</p>' +
      tabla(cab.concat(['']), regs.map(r => [r.fecha, r.nombre, r.parentesco, r.hijo_de, r.telefono, r.correo, r.anio].map(esc)
        .concat([r.quitar ? btn(r.quitar) : (r.estado === 'rechazado' ? 'sin acceso' : '')])));
    if (antiguos.length) html += '<h3>Registrados con el formulario anterior (' + antiguos.length + ')</h3>' +
      '<p>Entran con «Ya estoy registrado», usando el mismo correo y año de nacimiento.</p>' +
      tabla(cab.slice(0, 3).concat(cab.slice(4)), antiguos.map(r => [r.fecha, r.nombre, r.parentesco, r.telefono, r.correo, r.anio].map(esc)));
    html += '<p>Familiares con acceso: ' + esc(d.total) + '.</p>' + pie(d);
    MailApp.sendEmail({ to: DUENA, subject: regs.length ? 'Archivo familiar: ' + regs.length + (regs.length === 1 ? ' familiar nuevo esta semana' : ' familiares nuevos esta semana') : 'Archivo familiar: registros anteriores', htmlBody: html, name: NOMBRE });
  }

  // 2) Al administrador: lo que la familia reconoció en las fotos
  if (aportes.length || pend) {
    const rel = { yo: 'es él/ella', padre: 'su papá', madre: 'su mamá', hijo: 'su hijo/a', pareja: 'su pareja', otro: '—' };
    const est = { pendiente: '<b>por revisar</b>', aplicada: 'en el árbol', rechazada: 'solo etiqueta', no_aplica: 'etiqueta' };
    let html = cabecera() + '<h3>La familia reconoció personas en las fotos</h3>';
    if (pend) html += '<p><b>' + pend + '</b> ' + (pend === 1 ? 'enlace espera' : 'enlaces esperan') + ' tu revisión para entrar al árbol: entra al archivo › <b>Administrar › Aportes por revisar</b>.</p>';
    if (aportes.length) html += tabla(['Fecha', 'Quién lo dijo', 'Persona en la foto', 'Parentesco', 'Nota', 'Árbol'],
      aportes.map(a => [esc(a.fecha), esc(a.autor), esc(a.nombre), esc(rel[a.relacion] || ''), esc(a.nota), est[a.arbol] || '']));
    html += pie(d);
    MailApp.sendEmail({ to: ADMIN, subject: 'Archivo familiar: ' + (pend ? pend + ' por revisar en el árbol' : aportes.length + ' aportes nuevos'), htmlBody: html, name: NOMBRE });
  }
  return salida('ok');
}

function salida(t) { return ContentService.createTextOutput(t); }
function autorizar() { MailApp.getRemainingDailyQuota(); }
