#!/usr/bin/env python3
"""Descarga de BEDCA (Base de Datos Española de Composición de Alimentos, AESAN) a datos/bedca.json.

Uso puntual (no forma parte de la app): python3 datos/descargar_bedca.py
Usa el mismo buscador que la web pública de BEDCA (bdpub/procquery.php), con pausas entre peticiones.
Guarda por alimento: nombre, grupo y valores por 100 g de porción comestible (energía en kcal convertida desde kJ).
Fuente que hay que citar siempre: «BEDCA, Consorcio BEDCA y AESAN» (www.bedca.net).
Es reanudable: si se corta, vuelve a ejecutarlo y sigue donde se quedó (datos/.bedca_cache.json).
"""
import json, os, re, sys, time, urllib.request

Q = 'https://www.bedca.net/bdpub/procquery.php'
AQUI = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(AQUI, '.bedca_cache.json')
SALIDA = os.path.join(AQUI, 'bedca.json')
PAUSA = 0.35
# componentes de BEDCA (c_id) → clave en nuestro catálogo
COMP = {'409': 'kj', '416': 'prot', '410': 'grasa', '53': 'hc', '307': 'fibra', '299': 'sat', '323': 'na', '319': 'fe'}

def consulta(xml):
    for intento in range(4):
        try:
            req = urllib.request.Request(Q, data=xml.encode('utf-8'), headers={'Content-Type': 'text/xml', 'User-Agent': 'NutriLogos-importacion-puntual'})
            with urllib.request.urlopen(req, timeout=40) as r:
                return r.read().decode('utf-8', 'replace')
        except Exception as e:
            time.sleep(2 * (intento + 1))
    raise RuntimeError('sin respuesta de BEDCA')

def pares(texto, campos):
    out = []
    for blk in re.findall(r'<food>(.*?)</food>', texto, re.S):
        d = {}
        for c in campos:
            m = re.search(r'<%s>([^<]*)</%s>' % (c, c), blk)
            d[c] = m.group(1) if m else None
        out.append(d)
    return out

def main():
    cache = json.load(open(CACHE, encoding='utf-8')) if os.path.exists(CACHE) else {'grupos': None, 'alimentos': None, 'valores': {}}
    if not cache['grupos']:
        t = consulta('<?xml version="1.0" encoding="utf-8"?><foodquery><type level="3"/><selection><atribute name="fg_id"/><atribute name="fg_ori_name"/></selection><order ordtype="ASC"><atribute3 name="fg_id"/></order></foodquery>')
        cache['grupos'] = {g['fg_id']: g['fg_ori_name'] for g in pares(t, ['fg_id', 'fg_ori_name'])}
        time.sleep(PAUSA)
    if not cache['alimentos']:
        al = []
        for gid in cache['grupos']:
            t = consulta('<?xml version="1.0" encoding="utf-8"?><foodquery><type level="3f"/><selection><atribute name="f_id"/><atribute name="f_ori_name"/><atribute name="f_eng_name"/></selection><condition><cond1><atribute1 name="foodgroup_id"/></cond1><relation type="EQUAL"/><cond3>%s</cond3></condition><condition><cond1><atribute1 name="f_origen"/></cond1><relation type="EQUAL"/><cond3>BEDCA</cond3></condition><order ordtype="ASC"><atribute3 name="f_ori_name"/></order></foodquery>' % gid)
            for f in pares(t, ['f_id', 'f_ori_name', 'f_eng_name']):
                f['g'] = gid; al.append(f)
            time.sleep(PAUSA)
        cache['alimentos'] = al
        json.dump(cache, open(CACHE, 'w', encoding='utf-8'), ensure_ascii=False)
    total = len(cache['alimentos']); print('alimentos:', total, flush=True)
    for i, f in enumerate(cache['alimentos']):
        fid = f['f_id']
        if fid in cache['valores']: continue
        t = consulta('<?xml version="1.0" encoding="utf-8"?><foodquery><type level="3m"/><selection><atribute name="v_comp_id"/><atribute name="best_location"/><atribute name="v_unit"/></selection><condition><cond1><atribute1 name="v_food_id"/></cond1><relation type="EQUAL"/><cond3>%s</cond3></condition></foodquery>' % fid)
        v = {}
        for p in pares(t, ['v_comp_id', 'best_location', 'v_unit']):
            if p['v_comp_id'] in COMP and p['best_location'] not in (None, ''):
                v[COMP[p['v_comp_id']]] = [p['best_location'], p['v_unit']]
        cache['valores'][fid] = v
        if i % 25 == 0:
            json.dump(cache, open(CACHE, 'w', encoding='utf-8'), ensure_ascii=False); print(i, '/', total, flush=True)
        time.sleep(PAUSA)
    json.dump(cache, open(CACHE, 'w', encoding='utf-8'), ensure_ascii=False)
    # salida compacta
    out = []; incoherentes = []
    for f in cache['alimentos']:
        v = cache['valores'].get(f['f_id'], {})
        def num(k):
            if k not in v: return None
            x = float(v[k][0]); u = v[k][1]
            if k == 'na' and u == 'g': x *= 1000
            return x
        kj = num('kj')
        if kj is None: continue
        macros = {k: num(k) for k in ('prot', 'grasa', 'hc')}
        faltan = [k for k, x in macros.items() if x is None]
        if len(faltan) > 1: continue   # sin al menos dos macros no sirve para el catálogo
        if faltan:
            # BEDCA deja en blanco lo que no hay (trazas): se toma 0 solo si las kcal cuadran con los otros macros
            macros[faltan[0]] = 0.0
            est = 4 * macros['prot'] + 4 * macros['hc'] + 9 * macros['grasa']
            if abs(est - kj / 4.184) > max(25, 0.2 * kj / 4.184): continue
        est = 4 * macros['prot'] + 4 * macros['hc'] + 9 * macros['grasa']
        if abs(est - kj / 4.184) > max(30, 0.25 * kj / 4.184):
            incoherentes.append(f['f_ori_name']); continue   # las kcal no cuadran con los macros (alcohol o dato erróneo): no se usa
        r = {'id': int(f['f_id']), 'n': f['f_ori_name'], 'e': f['f_eng_name'], 'g': int(f['g']),
             'k': round(kj / 4.184, 1), 'p': round(macros['prot'], 2), 'h': round(macros['hc'], 2), 'f': round(macros['grasa'], 2)}
        if faltan: r['z'] = faltan   # macro ausente en BEDCA, tomado como 0
        for k, c in (('fibra', 'fi'), ('sat', 'sa'), ('na', 'na'), ('fe', 'fe')):
            x = num(k)
            if x is not None: r[c] = round(x, 2)
        out.append(r)
    json.dump({'fuente': 'BEDCA, Consorcio BEDCA y AESAN (www.bedca.net)', 'por': '100 g de porción comestible', 'grupos': cache['grupos'], 'alimentos': out}, open(SALIDA, 'w', encoding='utf-8'), ensure_ascii=False, separators=(',', ':'))
    print('guardado', SALIDA, len(out), 'alimentos; descartados por incoherentes:', len(incoherentes))

if __name__ == '__main__':
    main()
