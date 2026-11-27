# Fontes de solo extras para o ar (PurpleAir, WAQI): desenho, sem código

**Só desenho.** Nada aqui foi implementado nem aplicado. Nenhuma fonte nova entra em
alerta publicado sem decisão do dono e leitura dos termos de cada fonte (seção 5).

## 1. Por que

Hoje o aviso por sensor depende de **um** aparelho por região (em Manaus, um AirGradient
a ~2 km, via OpenAQ). Um sensor sozinho trava, salta, é posto ao lado de um escapamento
ou fica sem energia; e quando ele cala o app só tem o modelo (ver `bloco_ar.dart`:
"Sem medição agora"). Mais fontes independentes servem a duas coisas: **confirmar**
antes de alertar e **cobrir** quando um sensor para.

## 2. Onde isto se encaixa no que já existe

O pedido falava em "ingestão do `ar_horas`". Na prática são duas famílias, e a fonte
nova entra na **segunda**, não na primeira:

| Família | Tabelas | Função de coleta | O que é |
|---|---|---|---|
| Modelo | `ar_horas` (1 linha por hora, sobrescrita) | `ar_pedir()` / `ar_processar()` (Open-Meteo/CAMS) | estimativa de modelo |
| Sensores | `openaq_sensores`, `openaq_horas`, `openaq_ur_horas` → `ar_validacao_horas` | `openaq_pedir()` / `openaq_processar()` / `ar_validacao_registrar()` | medição local |

Plano: copiar o **molde** de `openaq_*` (pedido por `pg_net` na hora X, leitura na hora
X+3, chave no Vault, limpeza de respostas) para cada fonte, gravando numa tabela por
hora **com a fonte e o aparelho**, e só depois consolidar. Nada de misturar as linhas
na `ar_horas` (que é do modelo).

### Tabelas novas (esboço)

```
ar_fontes(fonte text PK, nome text, licenca_uso text,       -- 'publico' | 'validacao_interna'
          atribuicao text, ligado_para_alerta boolean DEFAULT false, ligado_coleta boolean DEFAULT false)
ar_aparelhos(fonte text, ref text, region_id uuid, lat, lon, distancia_m, grupo_fisico text,
             PRIMARY KEY (fonte, ref))
ar_aparelhos_horas(fonte text, ref text, hora timestamptz, pm25_bruto numeric, pm25_corrigido numeric,
                   ur numeric, marcas text[], PRIMARY KEY (fonte, ref, hora))
ar_concordancia_horas(region_id uuid, hora timestamptz, n_independentes int, n_acima int,
                      n_abaixo int, estado text, PRIMARY KEY (region_id, hora))
```

Todas com RLS ligado e **sem** `GRANT` para `anon`/`authenticated` (como
`ar_validacao_horas`). O app só lê o derivado (seção 4).

## 3. Fontes

### 3.1 PurpleAir (API própria)

- **Chave** no Vault (`purpleair_key`), nunca no repositório. Chamada só pelo banco
  (`pg_net`), nunca pelo app.
- Ler, por sensor: `pm2.5_cf_1` (canais A e B), `humidity`, e a marca de qualidade
  (diferença A×B). A **correção da EPA com umidade** já existe no repositório:
  `ar_correcao_epa(x, ur)` (Barkjohn et al. 2021 + extensão para fumaça intensa).
  Aplicar sobre `pm2.5_cf_1` (a média de A e B, descartando a hora quando A e B
  divergem demais). Guardar bruto **e** corrigido, como já se faz com a OpenAQ.
- **Limite honesto da correção:** foi ajustada com dados dos EUA; a umidade da Amazônia
  fica no fim ou fora da faixa de calibração, e a umidade do aparelho é medida dentro
  dele (no AirGradient de Manaus a mediana foi 43% contra 65% do ambiente, ver
  `20261125c`). Por isso a correção continua um **recorte de validação**, não a série
  do alerta, até haver dados locais.
- Custo e cota da API: **não verifiquei**. Conferir antes de qualquer coleta contínua.

### 3.2 WAQI

- Chave pedida (já registrado em `ar-fonte.md`). O que a API devolve por estação é
  tipicamente o **sub-índice (AQI)** do poluente, não µg/m³; para entrar na nossa série
  seria preciso converter de volta, com perda de precisão e dependendo de qual tabela
  de pontos de corte a estação usa. **Não verifiquei o formato atual da resposta.**
  Se não houver µg/m³, WAQI fica só como **contexto** ("há estação X dizendo Y"), nunca
  como voto no acordo da seção 4.
- Procedência: WAQI agrega estações de terceiros (oficiais e de baixo custo). Pode
  repetir um aparelho que já entra por outra rota (ver independência).

### 3.3 OpenAQ (já existe)

Agrega vários provedores, **inclusive PurpleAir e AirGradient**. Então o mesmo aparelho
pode chegar por mais de uma rota (PurpleAir direto, via OpenAQ e via WAQI).

## 4. Regra de concordância

### Independência

Dois sinais só contam como independentes se forem **aparelhos físicos diferentes**.
Aparelhos de rotas diferentes que estejam a menos de 50 m um do outro, ou com o mesmo
identificador de origem, recebem o mesmo `grupo_fisico` e contam **um**. (O limite de
50 m e o uso do identificador de origem são escolhas minhas; não verifiquei se
OpenAQ/WAQI expõem o identificador original do PurpleAir.)

### Estados por região e hora

Para cada aparelho, a hora válida segue as regras que já existem (`travado`, `salto`,
cobertura) e o valor comparado é o mesmo do aviso (NowCast, ou a média de 3 h do
indicador "agora" quando o gatilho estiver ligado). "Acima" = acima do limite do aviso.

| Aparelhos independentes válidos acima do limite | Outros válidos abaixo | Estado | O que o app faz |
|---|---|---|---|
| ≥ 2 | qualquer | `confirmado` | alerta permitido (regra de 2 horas seguidas mantida) |
| 1 | ≥ 1 | `sinal_isolado` | texto "sinal isolado: um sensor indica ar ruim e outros perto não confirmam"; **sem push** |
| 1 | 0 (só ele reporta) | `sinal_isolado` | idem, "sem outro sensor para confirmar"; **sem push** |
| 0 | — | `sem_sinal` | normal |

Encerramento: o aviso fecha quando menos de 2 independentes ficam acima por 3 h seguidas
(a histerese de hoje, aplicada ao estado).

### Consequência que precisa de decisão

**Em Manaus há um só aparelho independente.** Com "≥ 2 para alertar", o aviso por sensor
de Manaus nunca abriria. Opções: (a) aceitar (Manaus só alerta com 2+ fontes; até lá,
"sinal isolado"); (b) manter a regra atual de sensor único como `confirmado_unico` para
regiões com 1 aparelho, com texto próprio; (c) começar em (b) e migrar para (a) quando
houver segunda fonte. **Não escolhi.** (Os avisos por sensor continuam desligados em
todas as regiões de qualquer forma.)

### Modo sombra

As fontes novas entram com `ligado_para_alerta = false`. A concordância é calculada e
gravada em `ar_concordancia_horas`, mas `ar_avisos_atualizar()` **não a lê**. Em
paralelo, comparar (relatório estilo `ar_validacao_*`): quantas vezes o acordo teria
confirmado ou barrado cada aviso que o sensor único abriu, por classe de fumaça.
Só depois, com critério escrito antes de olhar os dados (como `ar-validacao-preregistro.md`),
discutir ligar.

## 5. Licenças e termos: leitura obrigatória do André antes de qualquer coleta

**Eu não li os termos de nenhuma fonte para este documento.** O que segue são alertas,
não conclusões jurídicas.

1. **PurpleAir, seção 7.3 (saúde/emergência): o André precisa ler antes.** Não li. Este
   desenho trata o uso de alerta de saúde como **proibido até confirmação por escrito**
   da PurpleAir. Por isso: PurpleAir só em **modo sombra de validação**, atrás de
   `ligado_para_alerta = false`, e fora de qualquer alerta publicado até essa
   confirmação.
2. **Restrições repassadas pelo outro agente da sessão (não verificadas por mim contra
   os termos):**
   - chamadas à API PurpleAir só do **nosso servidor** (a ingestão do banco), nunca do
     app nem por terceiros;
   - **nunca expor valor bruto por sensor** do PurpleAir no app nem em API pública;
     só valores derivados (nível do IQAr, estado de concordância como "sinal isolado");
   - **atribuição visível** (conspícua);
   - uso para saúde/emergência pede **termo de isenção do usuário** nos termos do app e
     aviso visível de que exatidão e disponibilidade não são garantidas;
   - a cláusula "No Open Source Materials" pode conflitar com **misturar CAMS e OpenAQ**
     (licenças abertas) na saída derivada de PurpleAir. **Sinalizado:** o desenho evita
     esse risco mantendo as saídas derivadas de PurpleAir **separadas** (estado de
     concordância por região, sem fundir o número do PurpleAir com o do modelo), mas só
     o texto dos termos diz se basta.
3. **WAQI:** uso **não comercial**; exige atribuição e chave. O André decide se o
   AquaAlerta é "não comercial" no sentido dos termos (há receita, anúncios ou plano
   pago? não sei).
4. **Open-Meteo gratuito: uso não comercial** (já registrado em `ar-fonte.md`).
   **Isto já vale hoje**: `ar_pedir()` usa o endpoint gratuito sem chave em produção.
   Se o app for comercial, o plano pago precisa existir **antes** de qualquer expansão,
   não só para fontes novas. Pergunta aberta ao André.
5. **OpenAQ:** cada provedor tem a sua licença (o campo `licenca` já é guardado);
   atribuição já é mostrada ("OpenAQ · provedor").

## 6. Pergunta aberta: a regra "sem valor bruto por sensor" vale para PurpleAir que chega pela OpenAQ?

Levantada pelo outro agente. O que eu verifiquei no repositório:

- O texto "Medição local: MP2,5 de 21,3" com fonte "OpenAQ · PurpleAir" existiu na
  versão 4.10.2 (commit `76541d2`, ponta de `chore/versao-4.10.2`; `feat/ar-retro` é
  outro commit, `983ec4a`). **Nesta linha de trabalho o cartão já mudou:** mostra
  "Sensor perto: Muito ruim (80 µg/m³). Modelo: Moderada" e a fonte como "AirGradient, a
  2 km, via OpenAQ" (`bloco_ar.dart`, `test/ar_test.dart`).
- "PurpleAir" aparece no repositório **só numa resposta montada à mão** em
  `supabase/tests/openaq_test.sql:42-43` (formato da documentação da OpenAQ, não captura
  real). **Não sei se algum sensor real de produção é PurpleAir.** Verificação sugerida
  (só leitura, SQL Editor): `SELECT provedor, licenca, count(*) FROM openaq_sensores
  GROUP BY 1, 2;`
- O app **exibe µg/m³ de um sensor** (média de 24 h do sensor perto e, com o indicador
  "agora" deste PR, a média de 3 h da região). Se esse sensor for PurpleAir, isso é
  valor por sensor, mesmo vindo pela OpenAQ.
- Se a regra vale ou não para dados de PurpleAir recebidos via OpenAQ depende dos
  termos da PurpleAir e da licença que a OpenAQ registra (CC BY 4.0 na resposta
  montada). **Eu não decido isso.** Pergunta para o André, junto com a leitura da 7.3.
- Nenhum comportamento já publicado foi mudado por causa desta pergunta.

## 7. Fases propostas

0. **Antes de tudo:** André lê PurpleAir §7.3 e os termos de WAQI; responde as perguntas
   da seção 8. Sem isso, nada é coletado.
1. **Sombra de uma fonte** (a que os termos liberarem): tabelas novas, coleta, sem
   leitura pelo aviso, sem nada no app.
2. **Relatório de concordância** por 2 a 3 meses (inclui a época de fumaça).
3. **Decisão escrita** sobre ligar o acordo para alerta, região por região.
4. Só então texto novo no app ("sinal isolado") e termo de isenção.

## 8. Perguntas para o André

1. Leu a PurpleAir §7.3? PurpleAir só como validação interna até resposta por escrito?
2. O AquaAlerta é comercial? (afeta WAQI e o plano do Open-Meteo, que **já** está em uso.)
3. A regra "sem valor bruto por sensor" vale para PurpleAir via OpenAQ? Há sensor
   PurpleAir real nas listas de produção?
4. Regiões com 1 aparelho: aceitar "nunca alerta" (a), manter sensor único rotulado (b)
   ou (c)?
5. Orçamento para chave/cota paga de alguma fonte?

## 9. O que não verifiquei

Termos de PurpleAir, WAQI e OpenAQ; formato atual e cotas das APIs; preço da API do
PurpleAir; se OpenAQ/WAQI expõem o identificador original do aparelho; se há sensor
PurpleAir real nas listas de produção; a validade da correção da EPA para a umidade da
Amazônia.
