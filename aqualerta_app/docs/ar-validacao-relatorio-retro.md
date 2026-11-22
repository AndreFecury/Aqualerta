# Relatório retroativo: modelo de ar × sensores (ago–out 2026)

Gerado em 22/11/2026. Regras definidas antes no
[pré-registro](ar-validacao-preregistro.md) (commit 39e2a33).

## Dados

| | Manaus | Porto Velho |
|---|---|---|
| Sensor (OpenAQ) | AirGradient O-1PST, Greenpeace, a 2 km | AirGradient O-1PST, AIrWatch, a 6 km |
| Horas de MP2,5 | 2.232 (2.225 válidas; 3 saltos) | 2.170 (2.163 válidas; 3 travadas) |
| Dias válidos (≥ 18 h, dia local, 01/08–31/10) | 92 | 87 |
| Modelo | CAMS global via Open-Meteo, no ponto do rio | idem |
| Focos (INPE, mensais América do Sul, satélites polares) | 92 dias, nenhum faltando | 92 dias, nenhum faltando |

- **Recebido × corrigido:** continua sem resposta. As duas estações não aparecem
  no mapa público da AirGradient, então não deu para comparar com o fabricante.
  Há um rascunho de e-mail para a OpenAQ no fim deste relatório.
- **Umidade do sensor é interna:** mediana de 43 % (Manaus) e 48 % (Porto Velho),
  contra 65 % e 82 % no Open-Meteo; nunca passou de 85 %. A regra de neblina
  saiu, e os recortes de umidade usam a do Open-Meteo (grade grosseira).
- **Satélites:** a lista polar é a mesma do app (AQUA, TERRA, NPP-375, NOAA-20,
  NOAA-21). `NPP-375D` (220 mil focos no período) ficou fora, coerente com o app.

## Panorama (todos os dias)

| | Manaus recebido | Manaus corrigido | Porto Velho recebido | Porto Velho corrigido |
|---|---|---|---|---|
| Diferença mediana modelo − sensor (µg/m³) | −2,7 (Q1 −8,3; Q3 2,5) | +3,1 | −3,3 (Q1 −7,8; Q3 1,5) | +3,7 |
| Correlação diária | 0,75 | 0,71 | 0,69 | 0,70 |
| Correlação horária (apoio) | 0,55 | – | 0,52 | – |
| Dias no mesmo nível | 71 de 92 | 66 de 92 | 65 de 87 | 62 de 87 |
| Dias com 2+ níveis de diferença | 2 | 4 | 0 | 0 |

A correlação horária é bem menor que a diária, o que confirma o uso das
métricas diárias (o modelo é interpolado entre saídas de 3 h).

## R1 — viés em dias de fumaça

Diferença mediana modelo − sensor (µg/m³), terço "muitos focos":

| | 300 km recebido | 300 km corrigido | 500 km recebido | 500 km corrigido | Mesmo nível |
|---|---|---|---|---|---|
| Manaus (31 dias) | −5,5 (Q1 −18,5) | +0,6 | −5,5 (Q1 −17,4) | +0,6 | 16–17 de 31 |
| Porto Velho (29–30 dias) | −4,3 | +3,4 | −3,8 | +3,9 | 23–25 de 30 |

Nos dias de poucos focos, a mediana fica entre −0,4 e +1,5 µg/m³ (recebido), e
o nível bate em 27–29 de 30 dias em Manaus.

**Pela regra:** |mediana| < 10 µg/m³ em todos os casos, então nenhuma frase
específica de fumaça.

**Atenção, fora da regra:** a mediana esconde a cauda. Em Manaus, nos dias de
muita fumaça, um quarto dos dias tem o modelo mais de 17 µg/m³ abaixo do
sensor, e o nível só bate em metade dos dias. Os maiores erros:

| Dia | Modelo | Sensor recebido |
|---|---|---|
| 08/10 | 41,5 | 143,3 |
| 17/10 | 61,1 | 198,7 |
| 07/10 | 21,3 | 74,1 |

Sugestão para a próxima revisão do pré-registro: uma regra de cauda (por
exemplo, o quartil inferior), não só a mediana.

## R2 — falsa tranquilidade (modelo "Boa", sensor Moderada ou pior)

| | Recebido | Corrigido |
|---|---|---|
| Manaus | 6 de 33 dias "Boa" (18 %) | 1 de 33 (3 %) |
| Porto Velho | **14 de 34 (41 %)** | 5 de 34 (15 %) |

**Pela regra (> 20 %):**
- Manaus fica sem mudança nas duas séries.
- Porto Velho passa no recebido e não no corrigido. O pré-registro não diz o
  que fazer quando as séries discordam na R2. **Decisão sua.**

## R3 — falso alarme do modelo (modelo Ruim+, sensor Moderada ou melhor)

| | Recebido | Corrigido |
|---|---|---|
| Manaus | 3 de 15 (20 %) | **6 de 15 (40 %)** |
| Porto Velho | 0 de 1 | 1 de 1 |

**Pela regra (> 33 %):**
- Manaus passa no corrigido e não no recebido. Séries discordam. **Decisão sua.**
- Porto Velho: 1 dia só, sem conclusão possível.

**Eventos perdidos pelo modelo** (sensor Ruim+, modelo Moderada ou melhor):

| | Recebido | Corrigido |
|---|---|---|
| Manaus | 4 de 16 | 3 de 12 |
| Porto Velho | 1 de 2 | nenhum dia Ruim+ |

## R4 — limite do aviso pelo sensor (NowCast, 2 h para abrir, 3 h para fechar)

Calibração em agosto e setembro, por dia: acerto = acertos / (acertos +
perdidos + falsos alarmes).

| Candidato | Manaus: dias-evento | Manaus: acertos | Manaus: falsos alarmes | Manaus: acerto | Porto Velho |
|---|---|---|---|---|---|
| > 50 recebido | 3 | 3 | 10 | 0,23 | 0 eventos, 5 falsos |
| **> 75 recebido** | 3 | 3 | 4 | **0,43** | 0 eventos |
| > 50 corrigido | 1 | 1 | 8 | 0,11 | 0 eventos |
| > 75 corrigido | 1 | 1 | 2 | 0,33 | 0 eventos |

- O limite escolhido é **NowCast > 75 µg/m³**, que ganha nas duas séries.
- A calibração é fraca: só 3 dias-evento em Manaus, e Porto Velho não teve
  nenhum, então o limite veio de Manaus.

Teste em outubro, sem reajustar:

| | Dias-evento | Acertos | Perdidos | Falsos | Acerto | Pela regra |
|---|---|---|---|---|---|---|
| Manaus recebido | 13 | 12 | 1 | 0 | 0,92 | passa |
| Manaus corrigido | 11 | 10 | 1 | 0 | 0,91 | passa |
| Porto Velho recebido | 2 | 0 | 2 | 0 | 0 | **falha** |
| Porto Velho corrigido | 0 | – | – | – | – | sem eventos |

**Pela regra:**
- Outubro com acerto abaixo de 0,5, ou perdendo mais de 30 % dos dias-evento,
  significa não ligar avisos na Fase 3.
- Porto Velho falhou: seus 2 dias-evento têm média de 24 h entre 53 e 59
  µg/m³, sem picos acima de 75.
- O pré-registro não diz se a regra vale por região ou para o app inteiro.
  **Decisão sua.**

Opções:
- a) ligar só em Manaus;
- b) não ligar em lugar nenhum até ter mais dados;
- c) rever o evento de referência, que hoje é a média de 24 h acima de 50,
  enquanto o limite do aviso é 75.

Para referência, a simulação do período inteiro:

| | Episódios | Dias com aviso | Maior NowCast (µg/m³) |
|---|---|---|---|
| Manaus, > 75 recebido | 16 | 19 | 415 |
| Manaus, > 75 corrigido | 12 | 13 | 443 |
| Porto Velho, > 75 (as duas séries) | nenhum | – | 79,7 |

## R5 — fuso

Dias no mesmo nível, dia local × dia UTC:

| | Recebido | Corrigido |
|---|---|---|
| Manaus | 71 × 65 | 66 × 67 |
| Porto Velho | 65 × 67 | 62 × 59 |

**Pela regra (> 2 dias):** o fuso **importa**. Manaus no recebido muda 6 dias,
Porto Velho no corrigido muda 3. Já usamos o dia local, então nada muda.

## R6 — recebido × corrigido

Sem decisão, como combinado. As regras R2 e R3 deram resultados opostos nas
duas séries, o que torna essa resposta mais importante.

## R7 — frase de divergência (Fase 4)

- **Configuração atual:** 2 níveis ou 25 µg/m³, por 5 dias seguidos.
- **Resultado:** a frase teria aparecido **0 vezes** nas duas cidades.
- **Sequências de dias divergentes em Manaus:**
  - recebido: 18–19/09, 24–25/09, **07–09/10 (3 dias)**, 12–13/10 e 16–17/10;
  - corrigido: 24–25/09 e 07–09/10.
- **Porto Velho:** nenhum dia divergente.

**Pela regra:** zero vezes, mesmo com uma sequência clara de erro grande
(07–09/10, com o modelo de 53 a 102 µg/m³ abaixo), significa descer os
limiares. Proposta: `divergencia_dias_seguidos` = 3. Fica para a Fase 4.

## Umidade ambiente (Open-Meteo, grade grosseira)

| | Abaixo de 70 % | 70 a 85 % | Acima de 85 % |
|---|---|---|---|
| Manaus | 61 dias: −2,2 rec. / +1,9 cor. | 28 dias: −2,3 / +8,0 | 3 dias: −3,9 / +7,1 |
| Porto Velho | 4 dias: −12,3 / −2,1 | 79 dias: −3,0 / +4,2 | 4 dias: −7,8 / +3,4 |

O efeito da correção da EPA depende da umidade: em Manaus, nos dias úmidos o
corrigido fica bem abaixo do modelo. As amostras nas pontas são pequenas.

## Decisões pendentes (suas)

1. **R2 em Porto Velho:** as séries discordam (41 % × 15 %). Mudar o texto de
   "Boa"?
2. **R3 em Manaus:** as séries discordam (20 % × 40 %). Texto condicional para
   Ruim+ só do modelo?
3. **R4:** ligar avisos por sensor só em Manaus, em nenhum lugar, ou rever o
   evento de referência?
4. **R7:** baixar a frase de divergência para 3 dias seguidos?
5. Mandar o e-mail para a OpenAQ (abaixo)?

## Rascunho de e-mail (para você enviar, se quiser) — info@openaq.org

> Assunto: AirGradient PM2.5 on OpenAQ — raw or corrected?
>
> Hello, we use OpenAQ v3 data from two AirGradient Open Air (O-1PST) locations
> in Brazil (location ids 5040030 and 5616182) in a small flood and air-quality
> app. Could you tell us whether the pm25 values OpenAQ ingests from AirGradient
> are the raw sensor readings or already corrected (e.g. with the EPA
> correction AirGradient offers)? And is the relativehumidity parameter the
> device's internal reading? Thank you.
