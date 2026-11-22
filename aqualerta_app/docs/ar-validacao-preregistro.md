# Teste retroativo do ar (ago–out 2026): o que cada resultado decide

Escrito em 22/11/2026, **antes** de calcular os recortes de fumaça, a separação
ago–set × out e as taxas abaixo. Commitado antes de rodar as consultas.

## O que já foi visto (transparência)

Na primeira passada (21–22/11) já apareceram, para o período inteiro, sem
separar fumaça nem meses:

- diferença mediana diária modelo − sensor: Manaus −2,6 µg/m³ (recebido) e
  +3,1 (corrigido EPA); Porto Velho −3,3 e +3,7; correlação diária 0,75 e 0,69;
- tabela de níveis modelo × sensor (recebido) do período inteiro, incluindo um
  dia em Manaus com modelo N2 e sensor N5;
- contagens da simulação de aviso por NowCast (50 e 75 µg/m³) no período inteiro;
- a umidade do sensor é interna (mediana 43–48 % contra 65–82 % no Open-Meteo).

Por isso as regras R2 e R3 abaixo **não** são cegas no período inteiro: a
tabela de níveis já vista permite calcular essas taxas. Os limiares foram
escolhidos sem fazer essa conta, mas fica o registro.

## Definições fixas

- Dia = dia local da região (UTC−4), com pelo menos 18 h válidas de modelo e sensor.
- Período: 01/08 a 31/10/2026 (31/07 fica fora das métricas).
- Níveis: IQAr do MMA para MP2,5 sobre a média de 24 h (N1 Boa … N5 Péssima).
- "Recebido" = valor da OpenAQ; "corrigido" = EPA com a umidade do sensor.
  Os dois são sempre reportados; nenhum é escolhido aqui.
- Dia de fumaça: focos do INPE (satélites polares, células de 0,01°) a até
  **300 km** e, separadamente, a até **500 km** do ponto da região, somando o
  dia e os 2 anteriores; classes por terços dentro de ago–out, por região e
  raio. Dia sem arquivo do INPE = faltando (não zero). **Não** usa 100 km.

## Regras

**R1 — viés em dias de fumaça** (terço "muitos", cada raio, cada série).
- Mediana modelo − sensor ≤ −10 µg/m³ no recebido **e** no corrigido →
  o modelo subestima fumaça: nenhum aviso por modelo em nenhuma hipótese, e
  nas regiões sem sensor o cartão ganha a frase "em dias de fumaça a
  estimativa costuma ficar abaixo do medido".
- |mediana| < 10 nas duas séries → sem frase específica de fumaça.
- Séries discordam (uma ≤ −10, outra não) → aplica a frase (lado conservador)
  e a decisão fica para quando se souber se a OpenAQ entrega recebido ou corrigido.

**R2 — falsa tranquilidade**: dias com modelo N1 (Boa) e sensor N2 ou pior,
dividido pelos dias com modelo N1.
- \> 20 % → o cartão não mostra "Boa" do modelo sozinho: vira "Boa (estimativa)"
  com "medições locais podem ser maiores".
- ≤ 20 % → sem mudança.

**R3 — falso alarme do modelo**: dias com modelo N3+ e sensor N2 ou melhor,
dividido pelos dias com modelo N3+.
- \> 33 % → texto do cartão para N3+ só do modelo fica condicional
  ("a estimativa indica…"), nunca imperativo.

**R4 — limite do aviso por sensor (NowCast)**.
- Candidatos: NowCast > 50 e > 75 µg/m³, recebido e corrigido; abre com 2 h
  seguidas acima, fecha com 3 h seguidas abaixo (ar_config).
- Evento de referência: dia com média de 24 h da **mesma série** > 50 µg/m³ (N3+).
- Escolha em **ago+set** (dias locais): maior CSI = acertos / (acertos +
  perdidos + falsos), por dia; empate → menos episódios.
- Teste em **outubro** com o limite escolhido, sem reajustar.
- Outubro com CSI < 0,5 **ou** perdendo mais de 30 % dos dias-evento →
  a Fase 3 não liga avisos; o limite é revisto com mais dados.
- Se uma região não tiver nenhum dia-evento em ago+set, o limite vem da outra
  e isso é dito no relatório.

**R5 — fuso**: se dia local × dia UTC mudar a concordância de nível em mais
de 2 dias por região → registrar que o fuso importa (já usamos o local);
senão, registrar que não muda.

**R6 — recebido × corrigido**: sem decisão nesta fase; vai depender da
resposta da OpenAQ.

**R7 — frase de divergência (Fase 4)**: contar quantas vezes ela teria
aparecido em ago–out com a configuração atual (2 níveis ou 25 µg/m³, 5 dias
seguidos, 21 dias válidos na janela de 28). Mais de 3 vezes por região em 3
meses → subir os limiares; zero vezes havendo sequências claras de erro
grande → descer.
