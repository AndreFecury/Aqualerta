# Replay de 25-26/11/2026: o que cada versão do cartão mostraria

**Isto usa uma RECONSTRUÇÃO, não a série real.** Não tenho acesso a produção. Os valores e os
ids são **inventados** a partir dos fatos informados pelo dono: Manaus com um único sensor, última
leitura às 10:00 UTC de 26/11 (180 a 188 µg/m³ nas últimas horas), modelo perto de 45 µg/m³ de
manhã e "moderada, IQAr 80" às 19:42; Porto Velho com sensor em dia. Para Porto Velho não há
número informado: os valores (24 a 34 µg/m³, modelo em 15) são de exemplo. O que o replay prova é
a **lógica** de cada versão sobre dados com essa forma; os números exatos não são os de produção.

Como foi feito: as séries entram numa base local (`supabase/tests/fixtures/ar_replay_serie.sql`), as
RPCs reais do servidor (`ar_resumo`, `ar_contexto`, `ar_agora`, nas migrações já aplicadas)
respondem, e o JSON dessas respostas (`test/fixtures/ar_replay.json`) alimenta
`test/ar_replay_test.dart`. A versão nova roda o widget de verdade. As versões 4.11.1 e 4.12.0 são
**cópias congeladas** da lógica daquelas versões dentro do teste (comentadas com a origem); não dá
para rodar o código antigo ao lado do novo no mesmo teste.

## O que cada versão mostraria

Horas locais de Manaus (UTC−4). "Modelo" = CAMS; "sensor" = média de 3 h do sensor.

| Cenário | Dados | 4.11.1 | 4.12.0 (publicada antes) | Nova |
|---|---|---|---|---|
| **Manaus 06:00** | sensor em dia: 3 h = 180,7 (péssima), 24 h = 81,3 (muito ruim); modelo "moderada" 64 | **"Ar moderada · índice 64"** | **"Ar moderada · índice 64"**, com a linha "Agora (sensor): 180,7 µg/m³, faixa péssima" e o aviso de piora logo abaixo | **"Ar péssima"** (sensor), 24 h do sensor ao lado, modelo só como linha rotulada com o aviso "bem abaixo do que o sensor mede" |
| **Manaus 19:42** | sensor parado há 13 h; modelo "moderada", IQAr 80 | **"Ar moderada · índice 80"** | "Sem medição agora" + estimativa do modelo rotulada | "Sem medição agora" + "sem dados há 13 horas" + aviso de que o modelo pode subestimar a fumaça (igual à 4.12.0, com o motivo) |
| **Porto Velho 06:00** | sensor em dia (3 h = 27,7, "moderada"); modelo "boa" 40 | "Ar boa · índice 40" + cautela | "Ar boa · índice 40" + cautela + linha "Agora (sensor): faixa moderada" | **"Ar moderada"** (sensor) |
| **Porto Velho 19:42** | sensor em dia (3 h = 30,7, "moderada"); modelo "boa" 40 | idem | idem | **"Ar moderada"** (sensor) |

Selo do mapa nos mesmos cenários: 4.11.1 e 4.12.0 mostravam sempre a categoria do modelo
("Ar 64 · Moderada", "Ar 80 · Moderada", "Ar 40 · Boa (estimativa)"); a versão nova mostra
"Ar Péssima · sensor", "Ar sem medição", "Ar Moderada · sensor".

**Leitura:** a 4.12.0 já resolveu o caso das 19:42 (sensor parado), mas de manhã, com o sensor em
dia e dizendo "péssima", ela ainda abria com "moderada" do modelo. A nova abre com a medição.

## O que o replay não prova

- A série de Manaus é inventada em torno dos fatos informados; a de Porto Velho é de exemplo. Não
  se pode concluir nada sobre o ar real a partir deles.
- A conferência do "IQAr 80 às 19:42" e do "~45 µg/m³ de manhã" é só de ordem de grandeza.
- As versões antigas são cópias da lógica, não o código antigo rodando.

## Como trocar pelos dados reais (só leitura, no SQL Editor do dono)

1. Rodar as duas consultas abaixo e guardar o resultado **sem** ids de sensor nem nomes de
   estação (as colunas já saem sem eles):

```sql
-- série do sensor por hora (as horas sem leitura simplesmente não aparecem)
SELECT r.name AS regiao, v.hora, v.sensor_pm25
  FROM public.ar_validacao_horas v
  JOIN public.monitored_regions r ON r.id = v.region_id
 WHERE v.origem = 'continua' AND v.sensores_n > 0 AND v.sensor_pm25 IS NOT NULL
   AND r.name IN ('Manaus', 'Porto Velho')
   AND v.hora >= '2026-11-25 10:00+00' AND v.hora < '2026-11-27 00:00+00'
 ORDER BY r.name, v.hora;
-- modelo por hora
SELECT r.name AS regiao, h.hora, h.pm2_5
  FROM public.ar_horas h
  JOIN public.monitored_regions r ON r.id = h.region_id
 WHERE r.name IN ('Manaus', 'Porto Velho')
   AND h.hora >= '2026-11-25 00:00+00' AND h.hora < '2026-11-27 13:00+00'
 ORDER BY r.name, h.hora;
```

2. Trocar os blocos de `INSERT` de `supabase/tests/fixtures/ar_replay_serie.sql` pelos valores
   reais (mantendo os ids e nomes de sensor inventados).
3. Regenerar o JSON (PostGIS local, mesma cadeia de `ar_replay_test.sql`; primeiro as migrações e
   os stubs com a saída descartada, depois só o arquivo do snapshot):
   `psql -q -At -f fixtures/ar_replay_snapshot.sql > ../../test/fixtures/ar_replay.json`
   (com `PGCLIENTENCODING=UTF8` no Windows).
4. Rodar `supabase/tests/ar_replay_test.sql` e `test/ar_replay_test.dart` e **ajustar os valores
   esperados** (os números exatos mudam; a forma, a lógica, deve continuar).
