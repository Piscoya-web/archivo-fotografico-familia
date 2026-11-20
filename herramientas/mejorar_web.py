"""Aplica mejorar() a las fotos ya publicadas de uno o varios álbumes de la web.

Uso: python mejorar_web.py <carpeta_web> <carpeta_respaldo> [id_album ...]
- Antes de tocar una foto, guarda la original en <carpeta_respaldo>/<id_album>/ (si no estaba ya).
- Siempre parte de la original del respaldo, así se puede repetir sin acumular retoques.
- Regenera la miniatura de cada foto.
"""
import sys, os, json, shutil
import cv2
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mejorar import mejorar

web, resp = sys.argv[1], sys.argv[2]
data = json.load(open(os.path.join(web, 'albums.json'), encoding='utf-8'))
ids = sys.argv[3:] or [a['id'] for a in data['albumes']]
total = {'bn': 0, 'color': 0}
for a in data['albumes']:
    if a['id'] not in ids:
        continue
    os.makedirs(os.path.join(resp, a['id']), exist_ok=True)
    for f in a['fotos']:
        src = os.path.join(web, 'fotos', a['id'], f['archivo'])
        orig = os.path.join(resp, a['id'], f['archivo'])
        if not os.path.exists(orig):
            shutil.copy2(src, orig)
        img = cv2.imread(orig, cv2.IMREAD_COLOR)
        out, info = mejorar(img)
        total['bn' if info['bn'] else 'color'] += 1
        ext = os.path.splitext(f['archivo'])[1].lower()
        params = [cv2.IMWRITE_WEBP_QUALITY, 88] if ext == '.webp' else [cv2.IMWRITE_JPEG_QUALITY, 90]
        cv2.imwrite(src, out, params)
        k = min(1.0, 560 / out.shape[1])
        mini = cv2.resize(out, (round(out.shape[1] * k), round(out.shape[0] * k)), interpolation=cv2.INTER_AREA)
        cv2.imwrite(os.path.join(web, 'mini', a['id'], f['archivo']), mini, [cv2.IMWRITE_WEBP_QUALITY, 72] if ext == '.webp' else [cv2.IMWRITE_JPEG_QUALITY, 80])
    print(a['id'], len(a['fotos']), flush=True)
print('blanco y negro / sepia:', total['bn'], ' color:', total['color'])
