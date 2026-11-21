import json, sys, time, urllib.request, datetime, os
saida = sys.argv[1]
est = "6724:Itacoatiara:Colônia|9699:Itacoatiara:Mamoud Amed|6730:Manacapuru:MANACAPURU|9704:Manacapuru:Estrada|9705:Manacapuru:São Francisco|6740:Manaus:Colônia Antônio Aleixo|8747:Manaus:Igarape do Mindu|8748:Manaus:Igarape do Quarenta|9706:Manaus:Santa Etelvina|9707:Manaus:Tarumã|9708:Manaus:Flores|9709:Manaus:Redenção|9710:Manaus:Cidade de Deus|9711:Manaus:Jorge Teixeira|9712:Manaus:Puraquequara|9713:Manaus:Bairro da União|9715:Manaus:Mauazinho|9716:Manaus:Santa Luzia|9717:Manaus:Compensa|9723:Parintins:São José|9724:Parintins:Centro|9819:Parintins:Itaúna|3014:Porto Velho:Porto Velho|3151:Porto Velho:AC São Sebastião|3152:Rio Branco:AC Oca|8750:Rio Branco:Igarape Judia|17770:Rio Branco:G2-120040105A|17771:Rio Branco:G2-120040104A|17772:Rio Branco:G2-120040103A"
for item in est.split("|"):
    i, reg, nome = item.split(":")
    arq = os.path.join(saida, f"{i}.csv")
    if os.path.exists(arq): continue
    for tentativa in range(3):
        try:
            req = urllib.request.Request(f"https://mapservices.cemaden.gov.br/MapaInterativoWS/resources/horario/{i}/8760", headers={"User-Agent": "aqualerta-calibracao"})
            d = json.load(urllib.request.urlopen(req, timeout=240))
            break
        except Exception as e:
            print(i, "erro", e, flush=True); time.sleep(60)
    else:
        continue
    dd, mm_, aa = d["datas"][0].split("/")
    t0 = datetime.datetime(int(aa), int(mm_), int(dd), int(d["horarios"][0].rstrip("h")))
    vals = {}
    for linha in d["acumulados"]:
        for k, v in enumerate(linha):
            if v is not None: vals[k] = v
    with open(arq, "w", encoding="utf-8") as f:
        f.write("estacao,regiao,nome,hora_utc,mm\n")
        for k in sorted(vals):
            f.write(f'{i},{reg},"{nome}",{(t0 + datetime.timedelta(hours=k)).isoformat()},{vals[k]:.2f}\n')
    print(i, reg, nome, len(vals), "horas", flush=True)
    time.sleep(20)
print("FIM", flush=True)
