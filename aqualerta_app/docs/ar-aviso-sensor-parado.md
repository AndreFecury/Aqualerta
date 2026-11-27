# Aviso por sensor quando o sensor para, e decisões pendentes

**Só desenho. Nada aqui muda o comportamento de produção.** Os avisos por sensor seguem
desligados em todas as regiões (`ar_aviso_sensor.ligado = false`), e `agora_gatilho_ligado`
segue em 0. As decisões são do dono.

## 1. Como é hoje (fatos)

- `ar_avisos_atualizar()` (`20261126b`, mantida em `20261127b` e `20261128a`): se a última hora
  válida do sensor é mais velha que `sensor_max_atraso_h` (3 h), o aviso aberto é **encerrado**
  com `motivo_fim = 'o sensor parou de mandar leituras'`, e um `CONTINUE` impede que reabra sem
  dado novo. Encerrar **não manda push** (testado em `ar_avisos_test.sql`).
- Quando o dado volta, o buraco zera os contadores: só 2 horas seguidas acima do limite reabrem.
- O app só mostra o aviso enquanto está `ativo`. Depois de fechado, o cartão cai em "Sem medição
  agora" (com o modelo só como estimativa, sem categoria tranquilizadora) e o aviso passa para o
  histórico como "encerrado".
- O sensor de Manaus já teve buracos de várias horas (25 de 96 horas em 21–22/11,
  `docs/plano-saude-e-teste.md`) e parou em 26/11. Falha de sensor **não é rara**.
- A regra de fechar com o sensor parado está nos "decididos em 22/11" do cabeçalho de `20261126b`
  e faz parte do pré-registro v2 (`docs/ar-validacao-preregistro.md`): mudar isto é uma emenda
  ao pré-registro, não só uma mudança de código.

## 2. Opção 1: manter aberto e marcar "sem dados do sensor"

**O que muda:** com o sensor parado, o aviso **não fecha**; fica `ativo` com a marca "sem dados do
sensor desde HH:MM". A gravidade fica congelada no último valor. Fecha quando (a) o sensor volta e
fica 3 h seguidas abaixo do limite, ou (b) passa um prazo máximo configurável
(`ar_config.aviso_sem_dados_max_h`, sugestão 6 a 12 h) e fecha com o motivo "sem dados do sensor
por mais de N h".

**Peças** (nada feito):
- coluna nova `ar_avisos.sensor_sem_dados_desde timestamptz` e a chave de configuração;
- `ar_avisos_atualizar()`: no ramo "sensor parado", marcar em vez de encerrar, e encerrar só pelo
  prazo; sem push novo (ou um único push "sem dados", opcional);
- app: o texto do aviso deixa de dizer "o sensor indica ar muito ruim agora" e passa a "o último
  valor do sensor era X às HH:MM; ele está sem dados há N h"; título do push de novo/subiu continua
  igual;
- testes: SQL (marca, prazo, volta do sensor) e Dart (texto, sem afirmar "agora").

**Riscos:**
- **Alarme velho.** A fumaça pode ter passado e o aviso continua "ativo" até o prazo; quem segue a
  região vê "ar péssimo" sem prova de que ainda é verdade. Cansaço de alerta e perda de confiança.
- **Frase falsa se mal escrita.** Hoje o texto do push diz "indica ar … agora"; com o sensor mudo
  isso seria falso. O texto precisa ser reescrito, não só reaproveitado.
- **Prazo é uma escolha sem dado.** Sem série de 2027 não há como saber qual N minimiza os dois
  erros (fechar cedo demais × manter tempo demais); precisa entrar no pré-registro.
- **Buracos curtos viram "ativo" para sempre?** Sem prazo, sim. Com prazo, o aviso pode ficar
  aberto e fechar sem nunca ter sido "confirmado fechado" por dado.
- Mais estados (`ativo`, `ativo sem dados`, `encerrado`) para testar e explicar.

## 3. Opção 2: fechar como hoje

**O que muda:** nada no servidor. Pode-se melhorar só o texto do fechamento e como o app mostra o
histórico (ver "sem mudar comportamento" abaixo).

**Riscos:**
- **Falha silenciosa justo na pior hora.** Sensores caem com energia, rede ou tempestade, e o
  aviso some sem push e sem prova de melhora. Quem seguia o aviso pode entender o sumiço como
  "melhorou". O cartão agora diz "Sem medição agora" e que o modelo pode subestimar a fumaça, o
  que reduz, mas não elimina, o risco.
- **Só o modelo sobra.** O CAMS subestima fumaça (26/11: ~45 µg/m³ no modelo contra 180–188 no
  sensor), então depois do fechamento a região fica sem sinal forte de perigo.
- **Abre e fecha no vai e vem de um sensor instável** (buracos curtos): o aviso pode piscar. Hoje
  o `CONTINUE` evita reabrir sem dado novo, mas o ciclo pode repetir quando o dado volta.

**Sem mudar comportamento (se escolher esta):**
- texto do `motivo_fim` e do detalhe do aviso encerrado dizendo "encerrado porque o sensor parou,
  não porque o ar melhorou";
- o cartão (já feito nesta fase) mostra "Sem medição agora" em vez de uma categoria do modelo.

## 4. Comparação

| | Opção 1 (manter aberto + marca) | Opção 2 (fechar, como hoje) |
|---|---|---|
| Falha do sensor na pior hora | aviso continua visível, marcado | aviso some, sem push |
| Risco de aviso velho | sim, limitado por um prazo | não |
| Mudança no pré-registro v2 | sim (emenda) | não |
| Código e testes | migração + app + testes | só texto (opcional) |
| Texto do aviso | precisa mudar ("último valor… sem dados") | segue |

Minha leitura, só como opinião: se algum dia o aviso por sensor for ligado, a Opção 1 **com
prazo curto** (ex.: 6 h) e texto honesto é mais segura que fechar em silêncio; mas só vale a pena
junto com a decisão de ligar o aviso, e isso hoje não está decidido. Enquanto os avisos estiverem
desligados, a Opção 2 não custa nada.

## 5. Decisões que ainda são suas (item F)

Nenhuma chave de aviso foi adicionada nem alterada.

**5.1 Ligar o aviso por sensor em Porto Velho?**
- Fatos do repositório: não há linha em `ar_aviso_sensor` para Porto Velho (o código trata a falta
  como desligado). O relatório retro disse "Aviso por sensor só em Manaus… Porto Velho: sem aviso,
  só leitura", e o pré-registro (V2-R6) diz que nada que passar em Manaus ou Porto Velho vale para
  as outras regiões; a decisão de ligar está marcada para **julho de 2027**, com teste de março a
  junho.
- Na validação retro, em Porto Velho o modelo disse "Boa" com o sensor em "Moderada" ou pior em 14
  de 34 dias (41 %) no valor recebido e 5 de 34 (15 %) no corrigido; o relatório deixou "o que fazer
  quando as séries discordam" como decisão sua. É o argumento a favor de ligar o sensor lá; o
  argumento contra é que o pré-registro previa o teste antes.
- Ligar tecnicamente é um dado (`INSERT`/`UPDATE` em `ar_aviso_sensor`), não uma migração. O push
  só vai a quem segue a região **e** ativou "avisos de ar" (`ar_optin`); o aviso aparece na lista
  para todos os usuários logados.
- Se ligar, decidir junto: limite (NowCast > 75 ou 50, recebido ou corrigido), e a regra do item 5.2.

**5.2 Regra de sensor único ("sinal isolado") para regiões com um sensor só.**
Detalhes em `docs/ar-fontes-extras-design.md` §4. Hoje Manaus e Porto Velho têm um aparelho
independente cada. Se a regra for "alerta exige 2 ou mais aparelhos independentes acima do
limite", **nenhuma das duas alertaria nunca**. Opções:
- (a) aceitar: com 1 sensor só há "sinal isolado" no cartão, sem push; o alerta espera uma segunda
  fonte;
- (b) manter o sensor único como alerta, rotulado "um sensor só" (texto próprio);
- (c) começar em (b) e passar para (a) quando houver segunda fonte.
Riscos: (a) deixa as regiões sem alerta por sensor por tempo indeterminado; (b) aceita falso alarme
de um aparelho mal posicionado ou com defeito (os filtros `travado`/`salto` ajudam, não
eliminam).

**5.3 O que não precisa de decisão agora:** o gatilho com a média de 3 h (`agora_gatilho_ligado`)
é redundante com o NowCast (o corpo do PR #5 e a guarda testada em `ar_agora_test.sql` explicam) e segue em 0.

## 6. Checklist para decidir

1. Opção 1 ou 2 para o aviso aberto com o sensor parado (e, se 1, qual prazo).
2. Ligar Porto Velho agora ou esperar julho de 2027 (e, se ligar, limite e série).
3. Regra de sensor único: (a), (b) ou (c).
4. Se qualquer item mudar um aviso: atualizar o pré-registro v2 **antes**, e só então abrir a
   migração, com o resumo de 10 linhas e a aprovação de sempre.
