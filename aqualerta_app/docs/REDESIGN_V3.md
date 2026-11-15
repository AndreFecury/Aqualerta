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

Regra de severidade única: **pelas cotas da estação mais próxima da região**
(`lib/core/domain/severidade.dart`). Sem leitura recente (até 48 h), vale a
severidade gravada no alerta.

## Passos manuais (uma vez)

1. **Banco (obrigatório para contornos no mapa e para a tela Rios).**
   No Supabase, abra *SQL Editor* e rode `supabase/migrations/20261115_v3_views.sql`.
   Sem isso o app abre, mas o mapa fica sem contornos e a tela Rios vazia.
   O arquivo tem, comentadas no final, duas leituras de exemplo (Manaus 27,3 m e
   Porto Velho 15,2 m) para testar.

2. **Mapas (opcional para testar, necessário para publicar).**
   Sem chave, o app usa CARTO (carta e ruas) e EOX Sentinel-2 (satélite), que
   são gratuitos para uso não comercial com atribuição. Para publicar, crie uma
   conta gratuita em maptiler.com e rode:
   `flutter run --dart-define=MAPTILER_KEY=sua_chave`

3. **Push com o app fechado (opcional).**
   Hoje o app avisa por notificação local quando chega um alerta novo pelo
   Supabase Realtime numa região que você segue. Para avisar com o app fechado:
   - rode `flutterfire configure` (gera `firebase_options.dart` e configura o Android);
   - adicione o plugin `com.google.gms.google-services` no Gradle;
   - crie no servidor (por exemplo, uma Edge Function do Supabase) o envio para
     os tokens salvos em `user_profiles.fcm_token`, com `alert_id` nos dados.
   O app já pede permissão, salva o token e abre o alerta tocado.

## Pontos para validar com dados reais

- **Cota normal de Manaus (22 m no seed).** Com a regra das cotas, o Negro acima
  de 22 m já aparece como "Médio — fique atento". Confira o valor com a ANA antes
  de ligar notificações para o público.
- **Área afetada.** Só é exata quando `flood_events.affected_geometry` está
  preenchida; senão o app mostra o contorno da região e avisa que é estimativa.

## Testes

`flutter test` roda 39 testes, incluindo cada tela nos temas claro e escuro, com
letra normal e com letra 1,6×, procurando textos cortados ou sobrepostos.
