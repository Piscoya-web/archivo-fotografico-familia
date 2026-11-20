"""Mejora color, brillo y contraste de fotos antiguas, más o menos según lo que necesite cada una.

- Quita el tono rojizo/magenta de las copias a color desvaídas (balance por canal).
- Recupera contraste sin quemar luces (CLAHE suave sobre la luminosidad).
- Devuelve un poco de saturación.
La fuerza de cada paso se calcula por foto: una foto bien conservada apenas cambia.

Uso como módulo: from mejorar import mejorar; img2, info = mejorar(img_bgr)
"""
import cv2
import numpy as np


def _estirar_canal(c, lo_p, hi_p):
    lo, hi = np.percentile(c, (lo_p, hi_p))
    if hi - lo < 10:
        return c.astype(np.float32)
    return np.clip((c.astype(np.float32) - lo) * 255.0 / (hi - lo), 0, 255)


def mejorar(img):
    small = cv2.resize(img, None, fx=600 / max(img.shape[:2]), fy=600 / max(img.shape[:2]), interpolation=cv2.INTER_AREA)
    lab = cv2.cvtColor(small, cv2.COLOR_BGR2LAB).astype(np.float32)
    L, a, b = lab[..., 0], lab[..., 1] - 128, lab[..., 2] - 128
    dominante = float(np.hypot(a.mean(), b.mean()))          # cuánto tono de color tiene
    contraste = float(L.std())                                # cuánto contraste tiene
    sat = float(cv2.cvtColor(small, cv2.COLOR_BGR2HSV)[..., 1].mean())
    # monocromo (blanco y negro o sepia): todos los colores caen sobre un solo eje de tono.
    # A esas se les respeta el tono; solo se mejora brillo y contraste.
    m = (L > 40) & (L < 225)
    ab = np.stack([a[m], b[m]]) if m.sum() > 100 else np.stack([a.ravel(), b.ravel()])
    ev = np.sqrt(np.clip(np.sort(np.linalg.eigvalsh(np.cov(ab))), 0, None))
    perp, eje = float(ev[0]), float(ev[1])
    hsv_s = cv2.cvtColor(small, cv2.COLOR_BGR2HSV).reshape(-1, 3)
    hs = hsv_s[hsv_s[:, 1] > 30, 0].astype(np.float32) * np.pi / 90
    tono_unico = float(np.hypot(np.cos(hs).mean(), np.sin(hs).mean())) if len(hs) > 50 else 1.0
    variedad = round(perp, 2)
    blanco_negro = (perp < 2.0 and eje < 7) or (perp < 2.7 and tono_unico > 0.75 and eje < 6.5) or (sat < 12)

    # fuerza de cada corrección (0 = nada, 1 = completa)
    f_color = 0.0 if blanco_negro else float(np.clip((dominante - 4) / 14, 0, 0.75))
    f_contraste = float(np.clip((62 - contraste) / 30, 0.15, 0.9))

    out = img.astype(np.float32)
    # 1) color: estirar cada canal por separado neutraliza la dominante
    if f_color > 0:
        bal = np.dstack([_estirar_canal(img[..., i], 0.8, 99.6) for i in range(3)])
        out = out * (1 - f_color) + bal * f_color
    # 2) niveles: estirar la luminosidad (blancos y negros reales)
    out8 = np.clip(out, 0, 255).astype(np.uint8)
    lab = cv2.cvtColor(out8, cv2.COLOR_BGR2LAB)
    Lc = lab[..., 0]
    Ls = _estirar_canal(Lc, 0.5, 99.7)
    Lc = (Lc.astype(np.float32) * (1 - f_contraste) + Ls * f_contraste)
    # 3) contraste local suave
    clahe = cv2.createCLAHE(clipLimit=1.2 + 1.0 * f_contraste, tileGridSize=(8, 8))
    Lcl = clahe.apply(np.clip(Lc, 0, 255).astype(np.uint8)).astype(np.float32)
    Lc = Lc * 0.5 + Lcl * 0.5
    lab[..., 0] = np.clip(Lc, 0, 255).astype(np.uint8)
    # 3b) quitar la dominante que quede (p. ej. violeta) en los tonos medios, a medias para no apagar la foto
    if f_color > 0:
        labf = lab.astype(np.float32)
        medios = (labf[..., 0] > 60) & (labf[..., 0] < 200)
        if medios.any():
            for k in (1, 2):
                resto = float(labf[..., k][medios].mean() - 128)
                labf[..., k] -= resto * 0.5 * min(1.0, f_color + 0.2)
        lab = np.clip(labf, 0, 255).astype(np.uint8)
    out8 = cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)
    # 4) un poco de saturación (no en blanco y negro)
    if not blanco_negro:
        hsv = cv2.cvtColor(out8, cv2.COLOR_BGR2HSV).astype(np.float32)
        hsv[..., 1] = np.clip(hsv[..., 1] * (1.0 + 0.12 * (1 - f_color * 0.5)), 0, 255)
        out8 = cv2.cvtColor(hsv.astype(np.uint8), cv2.COLOR_HSV2BGR)
    # 5) nitidez suave (máscara de enfoque solo sobre la luminosidad, para no crear halos de color ni realzar el grano)
    lab = cv2.cvtColor(out8, cv2.COLOR_BGR2LAB)
    Lf = lab[..., 0].astype(np.float32)
    sigma = max(1.0, max(out8.shape[:2]) / 1500)
    detalle = Lf - cv2.GaussianBlur(Lf, (0, 0), sigma)
    detalle[np.abs(detalle) < 2] = 0                      # no tocar el grano fino
    lab[..., 0] = np.clip(Lf + 0.45 * detalle, 0, 255).astype(np.uint8)
    out8 = cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)
    info = {'dominante': round(dominante, 1), 'contraste': round(contraste, 1), 'bn': blanco_negro, 'variedad': round(variedad, 1),
            'f_color': round(f_color, 2), 'f_contraste': round(f_contraste, 2)}
    return out8, info
