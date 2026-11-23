# Plano: saúde das fontes e aviso de ar de teste (Fase A, confiabilidade)

Situação em 23/11/2026 01:13 UTC. Branch `feat/saude-e-teste`, a partir da main 20952c8 (app 4.11.0+54).
Nada deste plano foi aplicado em produção. Cada migração passa antes por um resumo de 10 linhas e pelo OK do André.

## Diagnóstico do sensor de Manaus (só leitura)
- Coletor: `openaq_estado.erro` está vazio e a última coleta horária deu certo às 00:19 UTC. Porto Velho, lido pelo mesmo código, tem 47 das últimas 48 horas.
- Manaus (sensor 13574643, AirGradient): 25 horas em 96. Os buracos vão de 21/11 02h a 11h e de 21/11 19h a 22/11 05h (UTC). Há dados de 22/11 06h a 22h.
- Cada coleta horária pede de novo as últimas 26 h. As horas que faltam caem dentro dessa janela, então a OpenAQ não as tem. Não é falha nossa.
- Conclusão: o aparelho, ou a conexão dele com a AirGradient, fica fora do ar por várias horas. Para separar isso de uma falha de recepção da OpenAQ, falta conferir o mapa público da AirGradient.
- `ar_avisos_atualizar` (20261126b, linhas 124-131): se a última hora válida tem mais de 1 h + `sensor_max_atraso_h` (3 h), o aviso aberto é encerrado com "o sensor parou de mandar leituras". O `CONTINUE` impede que ele reabra sem dado novo.
- Quando os dados voltam, o buraco zera os contadores (linha 113), e só duas horas seguidas acima de 75 reabrem o aviso. Hoje isso não acontece de qualquer forma: Manaus está com `ligado = false`.
- O plano Free do Supabase não tem backup ("Free Plan does not include project backups", conferido na página Backups).

## A) Saúde das fontes
- RPC pública e somente leitura `saude_fontes()`. Devolve uma linha por fonte com: `fonte`, `ultimo_ok`, `cadencia_min`, `idade_min` e `situacao`. A situação é `ok`, `atrasada` (mais de 2× a cadência), `parada` (mais de 6×) ou `sem_dado` (nunca rodou).
- Os limites ficam na tabela `saude_cfg`, no mesmo molde da `ar_cfg`.
- Fontes:
  - ANA: os níveis vão para `hydro_readings` (não existe `ana_leituras`), cadência de 30 min. Uma linha por estação ativa.
  - CEMADEN: `chuva_estado.ultima_coleta_ok`, 5 min.
  - Satélite: o `max(verificado_em)` de `satelite_verificacoes`, 6 h.
  - Modelo do ar: `ar_estado.modelo_ok_em`, 60 min.
  - OpenAQ: uma linha por sensor de PM2.5, pelo `max(hora)` de `openaq_horas`, 60 min. Somo 2 h de atraso natural do serviço.
  - Fila de push: o item pendente mais antigo de `push_fila`, 30 min. Fila vazia conta como `ok`, não como `sem_dado`.
- Não expõe dado pessoal nem segredo: só nomes de fonte e de sensor (que já são públicos na OpenAQ), datas e contagens.

## B) Dois avisos independentes para o André
1. **GitHub Actions** (`saude-fontes.yml`, a cada 30 min)
   - Chama `saude_fontes()` com a chave anon pública. Falha quando o Supabase não responde ou quando alguma fonte está `parada`, e aí o GitHub manda e-mail.
   - Limites:
     - os horários do GitHub podem atrasar de 5 a 30 min ou pular execuções;
     - em repositório público, o agendamento é desligado depois de 60 dias sem atividade.
   - Proposta para mantê-lo ligado: um passo mensal chama a API `PUT /actions/workflows/{id}/enable` nos dois workflows, com `permissions: actions: write` e só o GITHUB_TOKEN, sem segredo novo.
   - De quebra, o projeto fica ativo, e o `manter-supabase-ativo.yml` continua como reserva.
2. **Push para a conta do André no app**
   - Dispara só na mudança para `parada` e na volta para `ok`.
   - Reaproveita `push_fila.teste_para` e o `push_reivindicar` de 20261123b.
   - Tabela `saude_transicoes` com espera mínima de 6 h por fonte.
   - O id do André fica numa linha de config gravada por ele no SQL Editor, nunca no repositório.
   - Limite: se o próprio Supabase cair, este aviso também cai. Por isso existe o item 1.

## C) Backups (proposta, nada implementado)
- O plano Free não tem backup.
- Os migrations do repositório recriam o esquema e o cadastro (regiões e estações em 20261116).
- Sem backup, perderíamos o histórico de leituras, os perfis e quem segue cada região.
- Opções:
  - (a) `tool/exportar_config.ps1`, rodado pelo André no PC. Lê a senha do banco por prompt e grava um `pg_dump` das tabelas críticas fora do repositório.
  - (b) Plano Pro (US$ 25/mês), com 7 dias de backup diário.
- Nenhuma senha vai para o repositório nem para os secrets do GitHub.

## D) Aviso de ar de teste, visível só ao André
- Coluna `ar_avisos.teste_para uuid` mais `expira_em`. Escolhi isto em vez de uma tabela à parte porque o app já lê `ar_avisos`, então o caminho testado é o mesmo do real.
- RLS: `teste_para IS NULL OR teste_para = auth.uid()`.
- O índice "1 ativo por região" e o laço de `ar_avisos_atualizar` passam a ignorar as linhas de teste.
- Gatilhos:
  - o de push manda o teste só para `teste_para`, com título e corpo "TESTE · …";
  - o `dados_sinal` não dispara para as linhas de teste.
- Função `ar_aviso_teste(usuario uuid, regiao uuid)`: sem acesso para anon e authenticated, roda só pelo SQL Editor ou pela service role.
- Expiração: um cron a cada 10 min encerra o teste depois de 1 h.
- Limite: o app monta o título ("Ar muito ruim em X") a partir dos campos. Para a lista e o detalhe mostrarem "TESTE", o app precisa ler `teste_para`, o que exige uma versão nova (4.11.1). Sem ela, só o push diz TESTE.
- Teste SQL local: dois `request.jwt.claims` diferentes. B não vê, não conta e não recebe push; A vê.

## E) Checklist do celular
Em `docs/checklist-celular.md`, para o André rodar.

## F) Fases
| Fase | Pronto quando | Testes | Arquivos |
|---|---|---|---|
| A1 | `saude_fontes()` devolve todas as fontes. Anon lê, e só isso. | `supabase/tests/saude_fontes_test.sql`: casos ok, atrasada, parada e sem_dado; permissões | migração `20261127a_saude.sql` |
| A2 | Workflow vermelho com fonte parada ou Supabase fora do ar, testado à mão com `workflow_dispatch` | o próprio run | `.github/workflows/saude-fontes.yml` |
| A3 | Uma transição gera um push só para o dono, e a espera bloqueia o segundo | SQL local | `20261127b_saude_push.sql` |
| D1 | O teste aparece só para A, expira e não abre aviso real | `ar_aviso_teste_test.sql` | `20261127c_ar_aviso_teste.sql` |
| D2 (opcional) | A lista e o detalhe mostram TESTE | `flutter test` | `lib/core/domain/ar.dart`, telas de alerta |

Riscos:
- Falso "parada" na ANA quando a própria ANA atrasa, o que pede cadência por estação.
- E-mail do GitHub caindo numa caixa que ninguém lê.
- Mexer no índice e no laço de `ar_avisos`, que estão em produção. Os testes da Fase 3 rodam de novo.

## Decisões do André (23/11)
1. Commits: autor AndreFecury, sem linhas Co-Authored-By/Claude-Session.
2. Preparar a 4.11.1 (marca TESTE na lista e no detalhe, cautela mais branda quando só a época de fumaça se aplica). Não publicar sem OK.
3. Backup: script local de exportação, senha digitada na hora, saída fora do repositório. Sem plano Pro por ora.
4. ANA: uma linha por estação, cada uma com a própria cadência. O vigia falha só se uma estação de região com alerta ativo estiver parada, ou se pelo menos 1/3 das estações estiver parada ao mesmo tempo, num aviso único.

Escolhas minhas na A1, para conferir:
- Folga da ANA de 120 min. Em produção, a última leitura de cada estação tinha 73 a 103 min às 01:20 UTC de 23/11. Com 60 min de folga, todas apareceriam atrasadas.
- Sensor da OpenAQ parado aparece, mas não faz o vigia falhar, porque é aparelho de terceiros. Quem falha é o `openaq_coletor`, que é nosso.
- `sem_dado` não faz o vigia falhar, mas sai listado no resumo.
