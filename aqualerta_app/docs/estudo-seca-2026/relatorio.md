# Seca 2026 nos rios do Amazonas: comparação com 2023 e 2024

Estudo retrospectivo do AquaAlerta, feito em 23/11/2026 com dados até 22/11/2026.

Todo número deste texto sai de um arquivo em [`dados/`](dados/). Os arquivos são gerados por [`baixar_ana.mjs`](baixar_ana.mjs) e [`analisar.mjs`](analisar.mjs). A regra de aviso foi registrada antes da simulação, em [`preregistro.md`](preregistro.md) (commit c17e270).

## Dados
- **Fonte:** telemetria pública da ANA (`telemetriaws1.ana.gov.br`, serviço `DadosHidrometeorologicos`), com leituras de 15 em 15 min. O valor do dia é a mediana das leituras daquele dia. Dia sem leitura fica sem valor e não é interpolado.
- **Período:** de 1º de junho a 30 de novembro de 2023 e de 2024, e de 1º de junho a 22 de novembro de 2026.
- O banco do AquaAlerta só tem leituras a partir de 13/11/2026, por isso todo o estudo usa a ANA.

| Estação (código ANA) | Rio | Cobertura (`cobertura.csv`) |
|---|---|---|
| Manaus (14990000) | Negro | completa nos 3 anos |
| Itacoatiara (16030000) | Amazonas | completa. Em 2024, 127 dias tiveram menos de 48 leituras. |
| Humaitá (15630000) | Madeira | 4 dias sem leitura em 2023 e 2 em 2024. Em 2023, 121 dias tiveram menos de 48 leituras. |
| Parintins (16350002) | Amazonas | **só a partir de 01/10/2026** (53 dias). Sem dados em 2023 e 2024. |
| Urucurituba (15960060) | baixo Madeira | só em 2026, e **descartada**: o sensor ficou travado em 22,27 m em 55 dias, entre 21/07 e 31/10. |

**Régua de Manaus:** em 02/10/2026 a estação da ANA marcou entre 18,42 m e 18,60 m (mediana 18,52 m). A imprensa registrou [18,59 m no Porto de Manaus](https://clickpetroleoegas.com.br/rio-negro-desceu-a-18-59-m-no-porto-de-manaus-em-2-de-outubro-a-89-cm-da-cota-de-17-7-m-que-pode-antecipar-a-homologacao-da-taxa-de-seca-pela-antaq-btl96/) no mesmo dia. As duas réguas coincidem, mas a mediana do dia pode ficar alguns centímetros abaixo da leitura da manhã do porto.

**Limiar de 17,7 m:** a ANTAQ e o MPF condicionam a cobrança da "taxa da seca" no ciclo 2025/2026 a esse nível no Porto de Manaus ([MPF](https://www.mpf.mp.br/o-mpf/unidades/pr-am/noticias/mpf-recomenda-que-orgaos-e-empresas-de-navegacao-limitem-cobranca-da-201ctaxa-seca201d-no-amazonas), [Agência iNFRA](https://agenciainfra.com/blog/disputa-sobre-quem-paga-taxa-da-seca-segue-entre-empresas-de-navegacao/)). O Centronave contesta o valor e diz que há restrições à navegação acima dele.

## Manaus: quando o rio cruzou cada nível (`cruzamentos_manaus.csv`, `minimos.csv`)
| Ano | Abaixo de 20 m | Abaixo de 19 m | **Abaixo de 17,7 m** | Mínimo do período |
|---|---|---|---|---|
| 2023 | 16/09 | 19/09 | **23/09** | 12,64 m em 26/10 |
| 2024 | 31/08 | 04/09 | **10/09** | 12,14 m em 01/11 |
| 2026 | 24/09 | 29/09 | **12/10** | 15,87 m em 22/11, **provisório** (ainda descendo, cerca de 4 cm/dia) |

- Em 2026 o rio cruzou os 17,7 m **19 dias depois de 2023 e 32 dias depois de 2024**.
- No mesmo dia do ano, 22/11, Manaus estava em 13,28 m em 2023, 14,18 m em 2024 e 15,87 m em 2026 (`mesmo_dia.csv`).
- 2026 veio de uma cheia alta: a máxima de junho a novembro foi 28,50 m, em 30/06. Em 2023 foi 28,26 m e em 2024, 26,84 m.
- A seca de 2026 é, até aqui, menos funda que as duas anteriores, mas ainda não acabou.

## Outras estações: mínimo do período (`minimos.csv`)
Não temos cotas de seca do SGB para estas estações; as cotas cadastradas no AquaAlerta são de cheia. Por isso, esta seção mostra só o mínimo e a data.

| Estação | 2023 | 2024 | 2026 (até 22/11) |
|---|---|---|---|
| Itacoatiara | 0,37 m em 26/10 | −0,16 m em 31/10 | 2,94 m em 22/11, provisório (ainda descendo) |
| Humaitá | 8,12 m em 12/10 | 8,05 m em 14/10 | 10,11 m em 18/10 |
| Parintins | sem dado | sem dado | −0,68 m em 20/11 (série curta) |

## Aviso antecipado: o que a regra pré-registrada teria feito (`simulacao_regra.csv`, `disparos_regra.csv`)
**A regra:** no dia t, uma reta ajustada aos últimos 14 dias projeta o nível cruzando 17,7 m em até N dias.
- Antecedência é o número de dias entre o primeiro disparo e o cruzamento real.
- Alarme falso é o disparo sem cruzamento em até N + 5 dias.

| N | 2023 | 2024 | 2026 |
|---|---|---|---|
| 7 dias | 18/09, 5 dias antes, certo | 03/09, 7 dias antes, certo | 28/09, 14 dias antes, **alarme falso** pela definição |
| 10 dias | 16/09, 7 dias antes, certo | 01/09, 9 dias antes, certo | 26/09, 16 dias antes, **alarme falso** pela definição |
| 15 dias | 13/09, 10 dias antes, certo | 28/08, 13 dias antes, certo | 22/09, 20 dias antes, certo |

- Com N = 15, a regra avisou antes do cruzamento nos 3 anos, com 10 a 20 dias de antecedência e nenhum alarme falso.
- Com N = 7 e N = 10, ela errou em 2026. A descida de setembro (cerca de 20 cm/dia) perdeu força antes de chegar a 17,7 m, e o cruzamento veio depois do prazo.
- Em 2026, nos três valores de N, o rio de fato cruzou 17,7 m entre 14 e 20 dias depois do primeiro disparo.
- Foi testada só esta regra. Nada foi ajustado depois de ver os resultados.

## Limites
- **São só 3 temporadas, com 1 cruzamento cada.** Isso é pouco para falar em taxa de acerto. Para isso seria preciso testar a regra em décadas de série consistida da ANA (HidroWeb), o que este estudo não fez.
- O dado é telemétrico, não consistido. A mediana diária pode diferir da leitura oficial do porto em alguns centímetros, e a data de cruzamento pode mudar em 1 dia.
- A temporada de 2026 ainda está em curso: o mínimo ainda pode cair.
- Parintins e o baixo Madeira não permitem comparação, e não há cotas de seca oficiais nas outras estações.
- A regra é uma tendência linear. Ela não usa chuva, previsão, o rio Solimões nem o efeito de remanso.

Fontes: [ANA, telemetria](http://telemetriaws1.ana.gov.br/ServiceANA.asmx), [ANA HidroWeb](https://www.snirh.gov.br/hidroweb/), [SGB, boletins do Amazonas](https://www.sgb.gov.br/sace/).
