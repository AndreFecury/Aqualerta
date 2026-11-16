# AquaAlerta — redesign v3 ("a régua sobre a carta")

O que mudou, como rodar e o que ainda depende de configuração manual.

## O que já funciona

| Tela | O que tem |
|---|---|
| Login | Entrar e criar conta (Supabase Auth), mensagens de erro em português |
| Mapa | Régua do rio da sua região, regiões e áreas alagadas no mapa, estações da ANA, busca por bairro/região, "minha localização", painel **Exibição do mapa** (Automático, Carta, Ruas, Satélite + camadas), escolhas salvas no aparelho |
| Alertas | Ativos e encerrados (90 dias), puxar para atualizar, atualização em tempo real |
| Detalhe do alerta | Régua, quanto falta para a inundação, o que fazer (lista para marcar), área afetada, ligar para a Defesa Civil (199), compartilhar |
| Rios | Réguas horizontais de todas as estações, estado "sem leitura recente", seguir/deixar de seguir regiões |
| Perfil | Tamanho do texto (do celular ou A−/A/A+/A++), tema claro/escuro/automático, avisos (liga/desliga, som, severidade mínima), fontes de dados, sair |

Regra de severidade única: **pelas cotas oficiais do SGB da estação da região**
(`lib/core/domain/severidade.dart`, a mesma regra de `ana_atualizar_alertas()`
no banco):

| Nível do rio | Severidade | O app diz |
|---|---|---|
| abaixo da cota de alerta | Baixo | Situação normal |
| a partir da cota de alerta | Médio | Fique atento |
| a partir da cota de inundação | Alto | Prepare-se |
| a partir da cota de inundação severa | Crítico | Saia de áreas de risco |

Sem leitura recente (até 48 h), vale a severidade gravada no alerta.

## Dados (todos reais)

| O quê | De onde | Atualização |
|---|---|---|
| Nível dos rios | Telemetria da ANA (`telemetriaws1.ana.gov.br`) | a cada 30 min, pelo próprio Supabase (pg_net + pg_cron) |
| Cotas de alerta, inundação e inundação severa | SGB, Sistemas de Alerta Hidrológico (Amazonas, Madeira, Acre) | manual, quando o SGB revisar |
| Regiões | Limites municipais do IBGE (malha 2022, qualidade intermediária) | manual |
| Alertas | Gerados pelo banco quando o rio passa da cota de alerta; encerrados quando volta a baixar | a cada 30 min |

Estações: Manaus (14990000, Rio Negro), Manacapuru (14100000, Solimões),
Itacoatiara (16030000, Amazonas), Parintins (16350002, Amazonas), Porto Velho
(15400000, Madeira) e Rio Branco (13600002, Acre). Porto Velho e Rio Branco não
têm cota de inundação severa publicada, então o máximo ali é "Alto".

O seed fictício antigo (30 regiões, 22 eventos e 22 alertas) foi apagado; uma
cópia ficou no schema `arquivo_seed`, fora da API.

## Passos manuais (uma vez)

1. **Banco (obrigatório para contornos no mapa e para a tela Rios).**
   No Supabase, abra *SQL Editor* e rode `supabase/migrations/20261115_v3_views.sql`.
   Sem isso o app abre, mas o mapa fica sem contornos e a tela Rios vazia.

2. **Leituras da ANA (obrigatório para a régua e a tela Rios).**
   Rode `supabase/migrations/20261115_ana_leituras.sql` e depois
   `supabase/migrations/20261116_dados_reais.sql` no SQL Editor. O primeiro liga
   as extensões pg_net e pg_cron e agenda a busca do nível na telemetria pública
   da ANA a cada 30 minutos; o segundo troca o seed pelas estações, cotas e
   municípios reais e agenda a geração automática dos alertas.

3. **Mapas (opcional para testar, necessário para publicar).**
   Sem chave, o app usa CARTO (carta e ruas) e EOX Sentinel-2 (satélite), que
   são gratuitos para uso não comercial com atribuição. Para publicar, crie uma
   conta gratuita em maptiler.com e rode:
   `flutter run --dart-define=MAPTILER_KEY=sua_chave`

4. **Push com o app fechado (opcional).**
   Hoje o app avisa por notificação local quando chega um alerta novo pelo
   Supabase Realtime numa região que você segue. Para avisar com o app fechado:
   - rode `flutterfire configure` (gera `firebase_options.dart` e configura o Android);
   - adicione o plugin `com.google.gms.google-services` no Gradle;
   - crie no servidor (por exemplo, uma Edge Function do Supabase) o envio para
     os tokens salvos em `user_profiles.fcm_token`, com `alert_id` nos dados.
   O app já pede permissão, salva o token e abre o alerta tocado.

## Pontos para validar

- **Referência da régua.** A telemetria da ANA e as cotas do SGB usam a mesma
  régua nas estações do SGB, mas vale conferir o nível do app com o boletim do
  SGB na próxima cheia.
- **Área afetada.** Os alertas vêm do nível do rio, não de imagem de satélite,
  então o mapa pinta o município inteiro e avisa que é estimativa.

## Testes

`flutter test` roda 40 testes, incluindo cada tela nos temas claro e escuro, com
letra normal e com letra 1,6×, procurando textos cortados ou sobrepostos.
