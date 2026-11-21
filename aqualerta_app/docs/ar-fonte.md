# Fonte dos dados de qualidade do ar

**Escolhida:** Open-Meteo Air Quality API (modelo CAMS do Copernicus) para os
poluentes, e INPE Programa Queimadas para os focos de calor. Verificadas com
requisições reais em 21/11/2026.

- **Conta/chave:** nenhuma nas duas. (OpenAQ e WAQI pedem chave; o OpenAQ entra
  depois como medição local complementar, com a chave no Vault como `openaq_key`.)
- **Poluentes:** `GET https://air-quality-api.open-meteo.com/v1/air-quality`
  com as 6 regiões numa requisição (`latitude=a,b,…&longitude=…`),
  `hourly=pm2_5,pm10,ozone,nitrogen_dioxide,carbon_monoxide`, `past_days=1`,
  `forecast_days=3`, `timezone=GMT`, `timeformat=unixtime`. Unidades µg/m³.
  Resposta: lista JSON, um objeto por coordenada, na ordem pedida (~8 KB por região).
- **Focos:** `GET https://dataserver-coids.inpe.br/queimadas/queimadas/focos/csv/10min/focos_10min_AAAAMMDD_HHMM.csv`
  (UTC, ~10 KB, colunas `lat,lon,satelite,data`; latitude às vezes sem o zero:
  `-.0828`). Sem filtro por área: o banco filtra 100 km em volta de cada região.
- **Cota/volume:** Open-Meteo gratuito para uso não comercial, 10 mil pedidos/dia;
  usamos 24/dia (~0,2 MB/dia). INPE sem cota publicada; ~144 arquivos/dia de
  ~10 KB (~1,5 MB/dia).
- **Índice:** IQAr do MMA, Orientação Técnica de 10/01/2025 (Res. Conama
  506/2024), Quadro 1 e Equação 1, implementado em `ar_iqar()`. MP e SO2 em
  média de 24 h, O3 e CO em 8 h, NO2 em 1 h; vale o maior índice.
- **Atribuição (no app):** "Open-Meteo.com (CAMS/Copernicus, CC BY 4.0) e INPE Queimadas".

## Limites conhecidos (aparecem no app)

- É estimativa de modelo, com grade de dezenas de quilômetros: não é medição
  na rua de ninguém. Manaus e Manacapuru caem em pontos de grade diferentes,
  mas vizinhos.
- Fumaça de queimada pode aparecer antes ou depois do que o modelo mostra.
- Foco de calor não é incêndio confirmado: nuvens escondem fogo e queima de
  roçado também conta. Só contamos satélites de órbita polar (VIIRS/MODIS), e o
  mesmo fogo visto por vários satélites conta uma vez.
- A qualidade do ar nunca muda o risco de cheia da região.
