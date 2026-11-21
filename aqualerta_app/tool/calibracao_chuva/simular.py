import csv, glob, sys, datetime as dt, collections, os
pasta = sys.argv[1]; fator = float(sys.argv[2]); LIM = float(sys.argv[3]); M24 = float(sys.argv[4])
EV = {dt.date.fromisoformat(x) for x in "2025-11-29,2025-12-03,2025-12-07,2025-12-15,2026-01-11,2026-01-21,2026-01-24,2026-01-31,2026-02-02,2026-02-26,2026-03-25,2026-05-20".split(",")}
series = collections.defaultdict(lambda: collections.defaultdict(dict))
for arq in glob.glob(os.path.join(pasta, "*.csv")):
    for r in csv.DictReader(open(arq, encoding="utf-8")):
        mm = float(r["mm"])
        if mm > LIM: continue
        t = dt.datetime.fromisoformat(r["hora_utc"]) - dt.timedelta(hours=4)
        series[r["regiao"]][r["estacao"]][t] = mm
R = {"MEDIUM": 1, "HIGH": 2, "CRITICAL": 3}
def atual(h1s, d24s):
    m1, m24 = max(h1s), max(d24s)
    if m1 > 60 or m24 > 100: return "CRITICAL"
    if m1 >= 30 or m24 >= 50: return "HIGH"
    if m1 >= 20: return "MEDIUM"
def proposta(h1s, d24s):
    m1, m24 = max(h1s), max(d24s)
    n30 = sum(v >= 30 for v in h1s); n40 = sum(v >= 40 for v in h1s)
    if m1 >= 60 or n40 >= 3 or m24 >= 130: return "CRITICAL"
    if m1 >= 40 or n30 >= 2 or m24 >= 100: return "HIGH"
    if m1 >= 20 or m24 >= M24: return "MEDIUM"
for reg, ests in sorted(series.items()):
    # por hora: valores 1h e 24h de cada estação; severidade da hora; dia = pior hora
    todas = sorted({t for s in ests.values() for t in s})
    d24 = {e: {} for e in ests}
    for e, s in ests.items():
        ts = sorted(s); jan = collections.deque(); soma = 0
        for t in ts:
            jan.append((t, s[t])); soma += s[t]
            while jan[0][0] <= t - dt.timedelta(hours=24): soma -= jan.popleft()[1]
            d24[e][t] = soma
    dias = {"atual": {}, "proposta": {}}
    for t in todas:
        h1s = [ests[e][t] * fator for e in ests if t in ests[e]]
        ds = [d24[e][t] for e in ests if t in d24[e]]
        for nome, f in (("atual", atual), ("proposta", proposta)):
            sev = f(h1s, ds)
            if sev and R[sev] > R.get(dias[nome].get(t.date()), 0): dias[nome][t.date()] = sev
    print(f"\n== {reg} ({len(ests)} estações)")
    for nome in ("atual", "proposta"):
        c = collections.Counter(dias[nome].values())
        linha = f"  {nome:8s}: dias com aviso={len(dias[nome]):3d}  MEDIUM={c['MEDIUM']:3d} HIGH={c['HIGH']:3d} CRITICAL={c['CRITICAL']:3d}"
        if reg == "Manaus":
            pegos = [d for d in EV if d in dias[nome]]
            linha += f" | alagamentos pegos {len(pegos)}/{len(EV)}: " + " ".join(f"{d:%d/%m}={dias[nome][d][0]}" for d in sorted(pegos))
        print(linha)
