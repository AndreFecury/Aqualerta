# Pré-registro: regra de aviso antecipado da seca (Manaus, 17,7 m)

Escrito em 23/11/2026, **antes** de rodar a simulação. Depois de rodar, a regra não muda. Se outra regra for testada, ela é relatada junto, com o rótulo "testada depois".

## Dados
- Estação ANA 14990000 (Rio Negro em Manaus), telemetria de 15 em 15 min, baixada por `baixar_ana.mjs`.
- O valor de cada dia é a mediana das leituras daquele dia, em `dados/ana_14990000_<ano>.csv`.
- Anos: 2023, 2024 e 2026, de 1º de junho até 30 de novembro (em 2026, até o último dia baixado).
- Dia sem leitura fica sem valor. Não é interpolado.

## Limiar
17,7 m (1770 cm) na régua da estação, que é o gatilho citado pelo dono para a "taxa da seca". A fonte ainda precisa ser confirmada no relatório.

O **cruzamento real** é o primeiro dia D em que o nível diário fica abaixo de 1770 cm, depois de um dia com valor maior ou igual a 1770 cm.

## Regra (a mesma para N = 7, 10 e 15 dias)
No dia t, usando só os dias até t:
1. Pega os dias com valor entre t−13 e t (janela de 14 dias). A regra só roda se houver pelo menos 10 dias com valor na janela e o dia t tiver valor.
2. Ajusta uma reta por mínimos quadrados: nível × dia.
3. Se a inclinação é negativa e o nível em t ainda está acima ou igual a 1770 cm, projeta o dia em que a reta chega a 1770 cm: t + (nível ajustado em t − 1770) / |inclinação|.
4. O aviso **dispara** em t se essa projeção cair em até N dias depois de t.
5. Depois que dispara, o aviso fica "ligado" e não conta de novo até o nível voltar a subir por 5 dias seguidos, ou até o cruzamento acontecer.

## Medidas (por ano e por N)
- **Primeiro disparo:** o primeiro dia t em que o aviso dispara.
- **Antecedência:** dias entre o primeiro disparo e o cruzamento real.
- **Alarme falso:** um disparo depois do qual o cruzamento não acontece em até N + 5 dias.
- **Ano sem cruzamento:** todo disparo é alarme falso.

Os mesmos números saem para 20 m e 19 m, só como referência, sem regra nova.
