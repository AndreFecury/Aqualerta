# Plano: qualidade do ar por região (não implementado)

Status: proposta de 21/11/2026, na branch `feat/qualidade-ar-plano`. Nada foi
aplicado no banco nem no app. As decisões abertas estão no fim.

## 1. Fontes verificadas (requisições reais em 21/11/2026, ~17h de Manaus)

| Fonte | Resultado | Por quê |
|---|---|---|
| Open-Meteo Air Quality (CAMS) | **Aprovada** | Sem chave, CC BY 4.0; as 6 regiões em **1 requisição** (lat/lon separados por vírgula), 44 KB, `pm2_5`, `pm10`, `ozone`, `nitrogen_dioxide`, `carbon_monoxide` em µg/m³, horário, ontem + 5 dias |
| INPE Queimadas (dados abertos) | **Aprovada** | Sem chave; CSV a cada 10 min (`.../focos/csv/10min/focos_10min_AAAAMMDD_HHMM.csv`, ~10 KB, colunas `lat,lon,satelite,data`) e diário (`.../csv/diario/Brasil/focos_diario_br_AAAAMMDD.csv`, 2,2–2,7 MB). Não há filtro por área: baixa e filtra |
| OpenAQ v3 | Reprovada para o v1 | HTTP 401 sem `X-API-Key` (exige conta) |
| WAQI/aqicn | Reprovada para o v1 | O token `demo` devolve Xangai; precisa de token próprio, e os dados não são validados |

Amostra real, Manaus (-3.1383, -60.0272), Open-Meteo, 21/11 17:00 (America/Manaus):
PM2,5 = 26,7 µg/m³ agora; média de 24 h = 27,3 µg/m³; PM10 de 24 h = 28,8; O3 maior média de 8 h = 85.
Pelo IQAr oficial, isso dá **54 (N2 Moderada), puxado pelo MP2,5**. A previsão é de no máximo 55 nos próximos 5 dias.
Outras regiões no mesmo horário: Itacoatiara 65, Parintins 57, Porto Velho 41, Manacapuru 40, Rio Branco 16.

- **Grade:** o Open-Meteo devolve pontos de grade distintos para Manaus (-3,10; -60,00) e Manacapuru (-3,30; -60,60). A diferença média de PM2,5 entre as duas é de 5,3 µg/m³, e a máxima de 16,7. Os valores são parecidos, mas não iguais. É um modelo grosseiro (~0,4°, interpolado), e o app tem de dizer isso.
- **Focos de queimada (dia 21/11, todos os satélites, raio de 100 km):** Manaus 1, Manacapuru 4, Itacoatiara 6, Parintins 91 (73 de VIIRS/AQUA), Rio Branco 8, Porto Velho 0. O mesmo fogo aparece em vários satélites, então a contagem precisa de deduplicação (item 5).
- **Comparação com medição local:** não foi feita, porque as duas redes de sensores pedem conta. A ressalva fica no texto do app.

Atribuição (vai em `docs/ar-fonte.md` e no app): "Qualidade do ar: Open-Meteo.com (CAMS/Copernicus), CC BY 4.0. Focos de queimada: INPE, Programa Queimadas."

### Proposta para `docs/ar-fonte.md` (no formato de `satelite-fonte.md`)
Fonte escolhida, sem conta; volume; "Limites conhecidos (aparecem no app)":
- estimativa de modelo, e não medição local;
- resolução de dezenas de km;
- fumaça de queimada pode ser subestimada ou deslocada no tempo;
- foco de calor não é incêndio confirmado: nuvem esconde fogo, e queima agrícola também conta.

## 2. Coleta: pg_net no banco (como a chuva), sem Edge Function
JSON e CSV simples cabem no padrão `chuva_pedir`/`chuva_processar`.
- **`ar_pedir()`**, cron `11 * * * *` (de hora em hora): faz 1 `net.http_get` ao Open-Meteo com as 6 regiões. São 24 pedidos/dia, ~1 MB/dia. O limite gratuito do Open-Meteo, de 10 mil pedidos/dia para uso não comercial, sobra muito. Se o app virar comercial, é preciso o plano pago.
- **Focos**, no mesmo cron: pede os 3 últimos arquivos de 10 min, com nome calculado como agora menos 20/30/40 min em UTC, porque o INPE publica com atraso. Isso dá 72 pedidos/dia, ~0,7 MB. Gravar é idempotente por `(lat, lon, satelite, data)`.
- **`ar_processar()`**, cron `14 * * * *`:
  - lê `net._http_response`;
  - grava uma região por vez, num subbloco com `EXCEPTION`: erro numa região não derruba as outras;
  - registra o erro em `ar_estado`.
- **Falhas:** timeout de 30 s; sem retry dentro da hora, porque o próximo ciclo já é a nova tentativa.
- **Poda (`ar_podar`)**, semanal: apaga horas com mais de 30 dias e focos com mais de 7 dias.

## 3. Modelo de dados (migração `20261122_ar.sql`, idempotente)
- **`ar_horas(region_id, hora, pm2_5, pm10, o3, no2, co, fonte, previsao bool, ingerido_em)`**: chave única `(region_id, hora)`, e a previsão é sobrescrita a cada coleta.
- **`ar_focos(lat, lon, satelite, detectado_em)`**: chave única nas quatro colunas, com índice em `detectado_em`.
- **`ar_estado`**: uma linha (`ultima_coleta_ok`, `erro`, `focos_ok_em`), no padrão de `chuva_estado`.
- **View `v_ar_regiao`**: por região, o IQAr atual (com o poluente que define), o IQAr máximo previsto para 48 h, a tendência de 24 h (sobe/estável/desce), os focos em 100 km nas últimas 24 h deduplicados por célula de ~1 km, `fumaca_provavel` e `atualizado_em`.
- **Cálculo no SQL:** função `ar_iqar(poluente, conc)`, IMMUTABLE, com a tabela oficial.
- **Segurança:** RLS de leitura pública (anon, authenticated) no padrão de `satelite_observacoes`; escrita só pelo servidor; `ar_pedidos` fechada.
- **Teste:** `supabase/tests/ar_test.sql` com `stub_base.sql` (`net.http_get` e cron já existem lá) e as respostas reais salvas desta verificação como fixtures.

## 4. Classificação: IQAr oficial
Fonte: MMA, *Orientação Técnica – Índice de Qualidade do Ar* (Res. CONAMA 506/2024), PDF de **10/01/2025** ([link](https://www.gov.br/mma/pt-br/assuntos/meio-ambiente-urbano-recursos-hidricos-qualidade-ambiental/qualidade-do-ar/indice-de-qualidade-do-ar-iqar/orientacao-tecnica-indice-de-qualidade-do-ar-jan-25.pdf)), Quadro 1.
O documento avisa que ainda será incorporado ao Guia Técnico, então guardamos a data e revisamos quando o guia sair.

| Nível | Índice | MP2,5 24h | MP10 24h | O3 8h | NO2 1h | CO 8h (ppm) |
|---|---|---|---|---|---|---|
| N1 Boa | 0–40 | 0–15 | 0–45 | 0–100 | 0–200 | 0–9 |
| N2 Moderada | 41–80 | >15–50 | >45–100 | >100–130 | >200–240 | >9–11 |
| N3 Ruim | 81–120 | >50–75 | >100–150 | >130–160 | >240–320 | >11–13 |
| N4 Muito ruim | 121–200 | >75–125 | >150–250 | >160–200 | >320–1130 | >13–15 |
| N5 Péssima | 201–400 | >125–300 | >250–600 | >200–800 | >1130–3750 | >15–50 |

- **Equação 1 do MMA:** IQAr = Iini + (Ifin−Iini)/(Cfin−Cini) × (C−Cini). O Cini da faixa é o inteiro seguinte (ex.: 151).
- **Arredondamento:** o CO fica com 1 casa e os demais poluentes viram inteiros; X,5 arredonda para o par.
- **Resultado:** vale o maior índice entre os poluentes.
- **SO2:** fica de fora no v1, porque é pouco relevante na região e o modelo é fraco nele.
- **CO:** converter µg/m³ para ppm (÷ 1145).
- **Texto de saúde:** só a partir de N2, usando o Quadro 2 do MMA com a fonte citada.
- **N1:** aparece como "Boa (estimativa)". Nunca "excelente", e sem selo verde de "tudo certo".
- **Paleta própria**, para não confundir com a cheia (verde/amarelo/laranja/vermelho):
  - rampa ardósia → violeta: N1 `#5B7A8C`, N2 `#7B6FA8`, N3 `#6A4C9C`, N4 `#4B2C7F`, N5 `#2E1A47`;
  - sempre com o número e o nome do nível;
  - contraste a conferir nos temas claro e escuro.

## 5. "Fumaça provável" (texto com ressalva)
`fumaca_provavel` = os três ao mesmo tempo:
- ≥ 10 focos deduplicados em 100 km nas últimas 24 h, contando só AQUA_M-T, NOAA-20/21 e NPP;
- MP2,5 de 24 h acima de 15 µg/m³;
- MP2,5 subindo, ou ≥ 25 µg/m³.

Texto no app: "Há focos de queimada perto e o modelo indica mais partículas no ar: a fumaça pode ser a causa."
Os limiares serão calibrados como a chuva, usando a estação seca de 2026 e os relatórios do INPE.

## 6. Alertas e push: só informativo no v1 (recomendado)
- **Sem linhas em `alerts`:** o gatilho `trg_alerts_push` envia push para qualquer alerta ativo, e o ar viraria spam junto com os avisos de cheia e chuva.
- **Estimativa grosseira:** com resolução de 45 km, o modelo não sustenta um alarme.
- **Fase 3, se o uso pedir:** `metadata.origem = 'ar-cams'`, só a partir de N4 (IQAr > 120) por 2 ciclos seguidos, e uma opção para desligar no Perfil.
- **Severidade da cheia:** o ar nunca muda a severidade da cheia.

## 7. App
- **Bloco "Qualidade do ar" na `_FolhaRegiao`**, logo depois de `_BlocoSatelite`, na linha ~1063 de `mapa_screen.dart`. Ele mostra:
  - o nível e o número;
  - o poluente que define o índice;
  - a tendência de 24 h e o pior valor previsto para 48 h;
  - a linha de fumaça provável;
  - o texto de saúde a partir de N2;
  - "Estimativa de modelo, não medição local. Atualizado às HH:MM."
- **Camada `Camada.qualidadeAr`** ("Qualidade do ar", "Estimativa do modelo CAMS, por região"): desligada por padrão e salva nas preferências pelo `CamadasCubit`. Pinta o contorno da região com a paleta do ar.
- **`FonteAr` + `ArRepository` + `ArCubit`:** cache de 30 min por região, como `SateliteCubit`.
- **Estados:**
  - carregando: `EsqueletoAlertas(linhas: 1)`;
  - ok;
  - desatualizado, se passar de 3 h (a coleta é de hora em hora);
  - vazio: "Sem estimativa para esta região ainda.";
  - erro, com "Tentar de novo".
- **Acessibilidade:** `Semantics` lendo "Qualidade do ar moderada, índice 54, estimativa de modelo".
- **Perfil → Fontes de dados:** nova linha "Open-Meteo/CAMS, qualidade do ar (modelo)", com o estado vindo de `ar_estado`.

## 8. Relatório semanal (fase posterior)
- **Conteúdo:**
  - média e pior dia de IQAr;
  - poluente dominante;
  - focos por dia;
  - gráfico de 7 dias;
  - página de metodologia (fontes, tabela do MMA, limites).
- **Formato:** recomendo uma página no app (rota `/ar/:regiao`) com botão de compartilhar imagem ou texto, usando o `share_plus`, que já é dependência. O PDF fica para depois, se alguém pedir.

## 9. Testes
- **SQL:** `ar_iqar` nas fronteiras de faixa (15/16, 50/51, 75/76, 125/126 de MP2,5) e no exemplo do MMA (MP10 210 → 168, O3 135 → 86, NO2 220 → 60).
- **SQL:** processamento das respostas reais salvas (Open-Meteo e CSV de 10 min); deduplicação de focos; erro isolado por região; poda; RLS.
- **Dart:** cache do `ArCubit`; estados do bloco (widget); camada salva nas preferências; `flutter analyze` limpo.

## 10. Documentação e versão
- **Fontes de dados:** novas linhas no `README.md` e em `docs/REDESIGN_V3.md`, mais o `docs/ar-fonte.md`.
- **Privacidade:** `docs/privacidade.html` não muda. O ar usa só coordenadas fixas das regiões, nunca a localização da pessoa. Vou conferir o texto antes de publicar.
- **Versão:** funcionalidade nova, então **4.10.0+52**. Publicação pelo `tool/publicar_versao.ps1`.

## 11. Fases
| Fase | Entrega | Pronto quando | Tamanho |
|---|---|---|---|
| 1 | Migração + coleta + IQAr no banco | 24 h de coleta em produção sem erro; testes SQL verdes | M |
| 2 | Bloco na folha + camada + Perfil | Bloco nos 5 estados; testes verdes; publicado | M |
| 3 | Fumaça provável calibrada (+ alerta opcional) | Limiar revisado com a estação seca | S |
| 4 | Relatório semanal | Página compartilhável com metodologia | M |

**Riscos:**
- **Resolução grosseira:** a fumaça local ou de um bairro não aparece no modelo.
- **Focos:** podem ser falsos positivos (queima agrícola, reflexo) ou faltar quando há nuvem.
- **Sensores:** não há medição local validada para checar viés.
- **Atribuição:** a licença CC BY exige crédito visível.
- **Mudança nas faixas:** o Guia Técnico pode mudar as faixas do IQAr.

## Decisões do dono (21/11/2026)
1. Bloco no mesmo cartão da região (`_FolhaRegiao`).
2. O ar **gera alerta e push** (item 6 vira fase 1): `metadata.origem = 'ar-cams'`, só a partir de N4 (IQAr > 120) em 2 coletas seguidas, sem mexer na severidade da cheia, com opção de desligar no Perfil.
3. Sensores locais pelo **OpenAQ**: o dono cria a conta e guarda a chave no Vault como `openaq_key`; a coleta lê do Vault (nunca no app nem no repositório).
4. Relatório semanal como página no app com botão de compartilhar.
