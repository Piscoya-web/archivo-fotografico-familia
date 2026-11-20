"""Procesa un álbum escaneado siguiendo la estructura de carpetas del archivo y lo integra en la web.

Estructura de cada álbum (p. ej. D:/Documentos/SCAN PISCOYA RIVERA/ALBUM 10):
  01_Paginas_Master_TIFF_*   páginas escaneadas (TIF)
  02_Recortes_Photoshop_*    cada foto recortada y enderezada (TIF, sin retocar)
  03_JPG_Finales_*           fotos finales, con color y contraste mejorados (NNN.jpg)
  04_webpage_album*          versión web (NNN.webp)
  giros.json                 rotación de cada recorte: {"ALB10_PAG005_F01": 90}  (90 = horario)
  numeracion.json            qué número final tiene cada recorte (no se renumera nunca)

Pasos (cada uno solo trabaja lo NUEVO; lo ya hecho no se toca):
  python procesar_album.py recortar  "<álbum>"           páginas nuevas -> recortes + hoja de revisión
  python procesar_album.py exportar  "<álbum>"           recortes nuevos -> JPG final mejorado + webp
                                                         (y JPG sueltos que pongas en 03 -> webp)
  python procesar_album.py publicar  "<álbum>" <id> "<título>" <carpeta_web>
                                                         webp nuevos -> fotos/ y mini/ de la web + albums.json
"""
import sys, os, glob, json, re, shutil
import cv2
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mejorar import mejorar

S = 0.2


def sub(album, prefijo):
    m = [d for d in glob.glob(os.path.join(album, prefijo + '*')) if os.path.isdir(d)]
    if m:
        return m[0]
    n = re.search(r'(\d+)\s*$', os.path.basename(album.rstrip('/\\'))).group(1)
    nombres = {'01': f'01_Paginas_Master_TIFF_A{n}', '02': f'02_Recortes_Photoshop_A{n}',
               '03': f'03_JPG_Finales_A{n}', '04': f'04_webpage_album{n}'}
    d = os.path.join(album, nombres[prefijo]); os.makedirs(d, exist_ok=True); return d


def num_album(album):
    return int(re.search(r'(\d+)\s*$', os.path.basename(album.rstrip('/\\'))).group(1))


def leer(path, defecto):
    return json.load(open(path, encoding='utf-8-sig')) if os.path.exists(path) else defecto


def guardar(path, data):
    json.dump(data, open(path, 'w', encoding='utf-8'), indent=1, ensure_ascii=False)


def _orden(pts):
    s = pts.sum(1); d = np.diff(pts, axis=1).ravel()
    return np.array([pts[np.argmin(s)], pts[np.argmin(d)], pts[np.argmax(s)], pts[np.argmax(d)]], dtype=np.float32)


def detectar(full):
    """Devuelve las cajas (en píxeles reales) de las fotos pegadas sobre una página oscura, de izquierda a derecha."""
    small = cv2.resize(full, None, fx=S, fy=S, interpolation=cv2.INTER_AREA)
    gray = cv2.GaussianBlur(cv2.cvtColor(small, cv2.COLOR_BGR2GRAY), (5, 5), 0)
    H, W = gray.shape
    dark = cv2.morphologyEx((gray < 110).astype(np.uint8) * 255, cv2.MORPH_CLOSE, np.ones((15, 15), np.uint8))
    cs, _ = cv2.findContours(dark, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not cs:
        return [], small
    hull = cv2.convexHull(max(cs, key=cv2.contourArea))
    page_mask = np.zeros_like(gray); cv2.drawContours(page_mask, [hull], -1, 255, -1)
    page_area = cv2.contourArea(hull)
    hsv = cv2.cvtColor(cv2.GaussianBlur(small, (5, 5), 0), cv2.COLOR_BGR2HSV)
    bg = cv2.morphologyEx(((gray < 105) & (hsv[..., 1] < 70)).astype(np.uint8) * 255, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    fg = cv2.bitwise_and(cv2.bitwise_not(bg), page_mask)
    fg = cv2.morphologyEx(fg, cv2.MORPH_OPEN, np.ones((9, 9), np.uint8))
    fg = cv2.morphologyEx(fg, cv2.MORPH_CLOSE, np.ones((25, 25), np.uint8))
    cs, _ = cv2.findContours(fg, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    cajas = []
    for c in cs:
        a = cv2.contourArea(c)
        if a < 0.06 * page_area:
            continue
        rect = cv2.minAreaRect(c)
        (cx, cy), (rw, rh), _ = rect
        if a / max(rw * rh, 1) < 0.75 or min(rw, rh) < 0.12 * min(W, H):
            continue
        cajas.append((cx, _orden(cv2.boxPoints(rect))))
    cajas.sort(key=lambda t: t[0])
    return [b / S for _, b in cajas], small


def recortar_caja(full, B, margen=0.012):
    w = int(round(max(np.linalg.norm(B[1] - B[0]), np.linalg.norm(B[2] - B[3]))))
    h = int(round(max(np.linalg.norm(B[3] - B[0]), np.linalg.norm(B[2] - B[1]))))
    m = int(margen * min(w, h)) + 4  # se recorta un poco hacia dentro para no dejar borde del álbum
    dst = np.array([[-m, -m], [w - 1 + m, -m], [w - 1 + m, h - 1 + m], [-m, h - 1 + m]], dtype=np.float32)
    M = cv2.getPerspectiveTransform(B.astype(np.float32), dst)
    return limpiar_bordes(cv2.warpPerspective(full, M, (w, h), flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE))


def limpiar_bordes(img, maximo=0.07):
    """Quita las tiras de página del álbum (gris oscuro, sin color) que queden pegadas a un borde."""
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    sat = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)[..., 1]
    pagina = ((gray < 110) & (sat < 70)).astype(np.float32)
    h, w = pagina.shape
    filas, cols = pagina.mean(1), pagina.mean(0)
    def cuanto(perfil, n):
        k = 0
        while k < int(maximo * n) and perfil[k] > 0.25:
            k += 1
        return k + (int(0.004 * n) if k else 0)
    t, b = cuanto(filas, h), cuanto(filas[::-1], h)
    l, r = cuanto(cols, w), cuanto(cols[::-1], w)
    return img[t:h - b, l:w - r]


def cmd_recortar(album):
    d1, d2 = sub(album, '01'), sub(album, '02')
    n = num_album(album)
    hechos = {re.match(r'ALB\d+_PAG(\d+)_F', f).group(1) for f in os.listdir(d2) if re.match(r'ALB\d+_PAG\d+_F\d+\.tif$', f)}
    nuevos, vis_list = [], []
    for p in sorted(glob.glob(os.path.join(d1, '*.tif'))):
        pag = re.search(r'(\d+)\D*$', os.path.splitext(os.path.basename(p))[0]).group(1).zfill(3)
        if pag in hechos:
            continue
        full = cv2.imread(p, cv2.IMREAD_COLOR)
        cajas, small = detectar(full)
        for i, B in enumerate(cajas, 1):
            nombre = f'ALB{n:02d}_PAG{pag}_F{i:02d}'
            cv2.imwrite(os.path.join(d2, nombre + '.tif'), recortar_caja(full, B), [cv2.IMWRITE_TIFF_COMPRESSION, 5])
            nuevos.append(nombre)
            cv2.polylines(small, [(B * S).astype(int)], True, (0, 0, 255), 3)
        vis_list.append(cv2.resize(small, (400, int(400 * small.shape[0] / small.shape[1]))))
        print(f'página {pag}: {len(cajas)} fotos')
    if vis_list:
        h = max(v.shape[0] for v in vis_list)
        filas = [np.hstack([np.pad(v, ((0, h - v.shape[0]), (0, 6), (0, 0)), constant_values=255) for v in vis_list[i:i + 5]]) for i in range(0, len(vis_list), 5)]
        wmax = max(f.shape[1] for f in filas)
        hoja = np.vstack([np.pad(f, ((0, 6), (0, wmax - f.shape[1]), (0, 0)), constant_values=255) for f in filas])
        cv2.imwrite(os.path.join(album, 'revision_paginas.jpg'), hoja)
    # hoja con los recortes nuevos numerados, para decidir giros
    if nuevos:
        th = []
        for nombre in nuevos:
            im = cv2.imread(os.path.join(d2, nombre + '.tif'))
            k = 260 / max(im.shape[:2]); im = cv2.resize(im, (int(im.shape[1] * k), int(im.shape[0] * k)))
            c = np.full((280, 280, 3), 255, np.uint8); y, x = (280 - im.shape[0]) // 2, (280 - im.shape[1]) // 2
            c[y:y + im.shape[0], x:x + im.shape[1]] = im
            cv2.putText(c, nombre[-11:], (4, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (0, 0, 255), 1)
            th.append(c)
        while len(th) % 6:
            th.append(np.full((280, 280, 3), 255, np.uint8))
        cv2.imwrite(os.path.join(album, 'revision_recortes.jpg'), np.vstack([np.hstack(th[i:i + 6]) for i in range(0, len(th), 6)]))
    print(f'{len(nuevos)} recortes nuevos. Revisa revision_recortes.jpg y anota los giros en giros.json.')


def cmd_exportar(album):
    d2, d3, d4 = sub(album, '02'), sub(album, '03'), sub(album, '04')
    giros = leer(os.path.join(album, 'giros.json'), {})
    numer = leer(os.path.join(album, 'numeracion.json'), {})
    usados = {int(v) for v in numer.values()} | {int(f[:3]) for f in os.listdir(d3) if re.match(r'\d{3}\.jpg$', f)}
    sig = max(usados, default=0) + 1
    rot = {90: cv2.ROTATE_90_CLOCKWISE, 180: cv2.ROTATE_180, 270: cv2.ROTATE_90_COUNTERCLOCKWISE}
    for p in sorted(glob.glob(os.path.join(d2, 'ALB*_PAG*_F*.tif'))):
        nombre = os.path.splitext(os.path.basename(p))[0]
        if nombre in numer:
            continue
        img = cv2.imread(p, cv2.IMREAD_COLOR)
        g = int(giros.get(nombre, 0)) % 360
        if g:
            img = cv2.rotate(img, rot[g])
        img, info = mejorar(img)
        numer[nombre] = f'{sig:03d}'
        cv2.imwrite(os.path.join(d3, f'{sig:03d}.jpg'), img, [cv2.IMWRITE_JPEG_QUALITY, 92])
        print(f'{nombre} -> {sig:03d}.jpg  giro {g}  {info}')
        sig += 1
    guardar(os.path.join(album, 'numeracion.json'), numer)
    # versión web de todo JPG final que aún no la tenga (también los que pongas a mano en 03)
    for p in sorted(glob.glob(os.path.join(d3, '*.jpg'))):
        dst = os.path.join(d4, os.path.splitext(os.path.basename(p))[0] + '.webp')
        if os.path.exists(dst):
            continue
        img = cv2.imread(p, cv2.IMREAD_COLOR)
        k = min(1.0, 1600 / max(img.shape[:2]))
        cv2.imwrite(dst, cv2.resize(img, (round(img.shape[1] * k), round(img.shape[0] * k)), interpolation=cv2.INTER_AREA), [cv2.IMWRITE_WEBP_QUALITY, 82])
        print('web:', os.path.basename(dst))


def cmd_publicar(album, album_id, titulo, web):
    d4 = sub(album, '04')
    fdir, mdir = os.path.join(web, 'fotos', album_id), os.path.join(web, 'mini', album_id)
    os.makedirs(fdir, exist_ok=True); os.makedirs(mdir, exist_ok=True)
    data = json.load(open(os.path.join(web, 'albums.json'), encoding='utf-8'))
    alb = next((a for a in data['albumes'] if a['id'] == album_id), None)
    if alb is None:
        alb = {'id': album_id, 'titulo': titulo, 'anios': (re.search(r'19\d\d(?:\s*[-–]\s*19\d\d)?', titulo) or [''])[0].replace('-', '–').replace(' ', ''), 'portada': '', 'fotos': []}
        data['albumes'].append(alb)
    elif titulo:
        alb['titulo'] = titulo
    ya = {f['archivo'] for f in alb['fotos']}
    nuevas = 0
    for p in sorted(glob.glob(os.path.join(d4, '*.webp'))):
        f = os.path.basename(p)
        shutil.copy2(p, os.path.join(fdir, f))
        img = cv2.imread(p, cv2.IMREAD_COLOR)
        k = min(1.0, 560 / img.shape[1])
        cv2.imwrite(os.path.join(mdir, f), cv2.resize(img, (round(img.shape[1] * k), round(img.shape[0] * k)), interpolation=cv2.INTER_AREA), [cv2.IMWRITE_WEBP_QUALITY, 72])
        if f not in ya:
            alb['fotos'].append({'archivo': f}); nuevas += 1
    alb['fotos'].sort(key=lambda x: x['archivo'])
    if not alb['portada'] and alb['fotos']:
        alb['portada'] = alb['fotos'][0]['archivo']
    json.dump(data, open(os.path.join(web, 'albums.json'), 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
    print(f'{album_id}: {nuevas} fotos nuevas, {len(alb["fotos"])} en total')


if __name__ == '__main__':
    c = sys.argv[1]
    if c == 'recortar':
        cmd_recortar(sys.argv[2])
    elif c == 'exportar':
        cmd_exportar(sys.argv[2])
    elif c == 'publicar':
        cmd_publicar(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
    else:
        print(__doc__)
