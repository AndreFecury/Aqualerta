# Calibração dos avisos de chuva

Refaz a análise que gerou `supabase/migrations/20261121_chuva_calibracao.sql`.

1. `python baixar.py dados` — baixa 1 ano de chuva hora a hora de cada
   pluviômetro (endpoint aberto do mapa interativo do CEMADEN). Uma estação
   por vez, com pausa: leva ~1 h. Não rodar em paralelo (o CEMADEN bloqueia).
2. `python simular.py dados 1.13 110 50` — simula, dia a dia, a regra antiga
   e a nova em cada município e mostra quantos dias de alagamento registrado
   em Manaus cada uma pegou. Argumentos: fator hora cheia → janela móvel de
   60 min (1.13), filtro de falha de sensor (mm/h) e limite de 24 h do nível
   "forte".

Os dias de alagamento (lista `EV` em `simular.py`) vieram de notícias da
Prefeitura de Manaus e da imprensa local (nov/2025 a mai/2026). Ao fim de cada
estação chuvosa, acrescente os dias novos e rode de novo.
