# Previsão de 48 h do ar: por que está marcada como experimental e como medir o erro

Estado: a tela **não mostra mais** o número da previsão de 48 h ("pior previsto em
48 h: moderada (70) ter 20h"). Mostra só "Previsão de 48 h: experimental, ainda sem
validação". O dado continua no banco (`ar_resumo.iqar_previsto_48h`) e no modelo do
app (`ResumoAr.previsto48h`); volta à tela quando a validação abaixo passar.

Motivo: no episódio de 22/11/2026 em Manaus o pico observado foi de IQAr ~177 e a
previsão era ~70. **Não consegui reproduzir esses números aqui**: não consultei o
banco de produção; eles vêm do relato do dono. Tratar como não verificado.

## O que a previsão é

`iqar_previsto_48h` = o **maior** IQAr (índice de 24 h: média móvel de 24 h do MP2,5 do
CAMS e dos outros poluentes, o pior vale) entre as próximas 48 horas, de
`v_ar_indice_horas`. Comparar com um pico de sensor exige a mesma janela: o IQAr de
24 h de um pico de horas é muito mais baixo que a concentração do pico (a média de
24 h dilui). Parte da distância entre 70 e 177 pode ser só isso; a outra parte é erro
do modelo (fumaça local que o CAMS, com grade de dezenas de km, não capta).

## O que as tabelas de validação já medem (e o que não medem)

`ar_horas` tem **uma linha por hora** (`PRIMARY KEY (region_id, hora)`) e é
sobrescrita a cada coleta (`docs/plano-qualidade-do-ar.md`: "a previsão é sobrescrita a
cada coleta"). `ar_validacao_horas.modelo_pm25` copia, de hora em hora, o valor dessa
linha para as últimas 26 h. Logo cada hora guardada traz **a última versão do modelo
para aquela hora, de antecedência curta (horas), não a previsão feita 24 ou 48 h
antes**.

Consequência: `ar_validacao_dias`, `ar_validacao_resumo` e
`ar_validacao_resumo_horario` medem o **viés modelo × sensor de antecedência curta**.
Isso é um **limite inferior** do erro da previsão de 48 h (a previsão de 24–48 h erra
pelo menos isso, e em geral mais). **O erro real de 24–48 h ainda não é mensurável com
o que está gravado.** Há um teste que fixa isso
(`supabase/tests/ar_previsao_erro_test.sql`, bloco D).

### Consultas (rodam hoje; verificadas em `ar_previsao_erro_test.sql` com valores inventados)

A. Viés e concordância por região (mediana de modelo − sensor, em µg/m³; dias com o
mesmo nível):

```sql
SELECT regiao, dias, dif_mediana, dif_q1, dif_q3, correlacao_diaria, dias_mesmo_nivel
  FROM public.ar_validacao_resumo
 WHERE origem = 'continua' AND fuso = 'local' AND recorte = 'todos';
```

B. Dias perdidos (o que importa para quem confia em "Boa/Moderada"): sensor em
Muito ruim/Péssima e modelo em Boa/Moderada.

```sql
SELECT regiao, dia, sensor_24h, modelo_24h, nivel_sensor, nivel_modelo
  FROM public.ar_validacao_dias
 WHERE origem = 'continua' AND fuso = 'local'
   AND nivel_sensor IN ('N4', 'N5') AND nivel_modelo IN ('N1', 'N2')
 ORDER BY dia;
```

C. Erro de pico: maior IQAr de média móvel de 24 h por dia, sensor × modelo (mesma
janela dos dois lados; ver o bloco C do teste para a consulta completa).

Ler junto com `ar_cobertura` (o sensor estava saudável?) e com os recortes de fumaça
de `ar_validacao_resumo`. Sem porcentagem, como nas demais métricas do projeto.

## Como medir o erro de 24–48 h de verdade (proposta; nada disto foi aplicado)

Arquivar a previsão **no momento em que é feita**, antes de a próxima coleta a
sobrescrever. Esboço (não é migração):

```sql
CREATE TABLE public.ar_previsoes_arquivo (
    region_id      uuid        NOT NULL REFERENCES public.monitored_regions(id) ON DELETE CASCADE,
    emitida_em     timestamptz NOT NULL,   -- hora da coleta (início da hora)
    alvo_hora      timestamptz NOT NULL,   -- hora prevista
    antecedencia_h integer     NOT NULL GENERATED ALWAYS AS
                   ((extract(epoch FROM alvo_hora - emitida_em) / 3600)::integer) STORED,
    pm2_5          numeric,
    PRIMARY KEY (region_id, emitida_em, alvo_hora)
);
```

Preenchida por `ar_processar()` com as linhas futuras que acabou de gravar (cerca de
72 por região e hora; guardar só as antecedências 6, 12, 24, 36 e 48 h reduz para 5 por
hora). Depois, juntar `alvo_hora` com `ar_validacao_horas.sensor_pm25` e calcular, por
antecedência (≤ 6 h, 24 h, 48 h):

- viés (mediana de previsto − observado, µg/m³) e erro absoluto mediano;
- erro do **pico diário** (IQAr de 24 h previsto × observado pelo sensor);
- dias perdidos (consulta B, mas com a previsão emitida 24 e 48 h antes);
- separado por classe de fumaça (`ar_fumaca_dias`), porque é aí que o modelo falha.

Critério para voltar a mostrar o número: definir **antes** de olhar os dados (como no
pré-registro `docs/ar-validacao-preregistro.md`), por exemplo "nos dias de fumaça
'muitos', o modelo emitido 24 h antes não perde mais que X% dos dias de nível N4+".
O X é decisão do dono; não escolhi um valor.

## Chave de servidor (migração `20261128b_ar_previsao_oculta.sql`)

**Estado: já aplicada em produção** (informado pelo dono). Com o padrão `previsao_48h_visivel = 0`
a previsão já não chega a quem usa 4.10.2 ou anterior.

Quem ainda usa 4.10.2 (ou anterior) continuaria vendo o número, porque o app que o
esconde ainda não foi publicado. A migração esconde no **servidor**:
`ar_config.previsao_48h_visivel = 0` (padrão) faz `ar_resumo()` devolver
`iqar_previsto_48h` e `hora_pior_prevista` como NULL; as outras colunas ficam iguais.
Chave apagada também esconde. O app novo trata NULL como "sem previsão" (e então não
mostra nem o aviso de "experimental", só a tendência).

Para mostrar de novo, depois da validação: `UPDATE public.ar_config SET valor = 1 WHERE
chave = 'previsao_48h_visivel';`. Reaplicar a migração não desfaz essa escolha. Os dados
continuam em `v_ar_indice_horas` para a validação. Teste: `ar_previsao_oculta_test.sql`.
