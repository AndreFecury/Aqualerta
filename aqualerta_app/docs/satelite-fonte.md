# Fonte dos dados de satélite

**Escolhida:** Copernicus EMS — Global Flood Monitoring (GFM), lida pelo catálogo
STAC aberto da EODC. Produto "ensemble" (três algoritmos, voto da maioria), 20 m,
a partir de cada passagem do Sentinel-1 (radar banda C, polarização VV).

- **Conta/chave:** nenhuma. Catálogo e arquivos são públicos (testado em 18/11/2026:
  `GET` sem cabeçalho de autorização devolveu 200; CORS aberto).
  A API própria do GFM (`api.gfm.eodc.eu/v2`) exige cadastro e AOI — não usada.
- **Busca:** `GET https://stac.eodc.eu/api/v1/search?collections=GFM&bbox=…&datetime=…`
  → itens STAC (um por cena × ladrilho Equi7 de 300 km).
- **Formato:** GeoTIFF otimizado para nuvem (COG), 15000 × 15000 px, compressão ZSTD,
  projeção Equi7 América do Sul (azimutal equidistante, lat0 −14, lon0 −60,5).
  Valores: 0 = não, 1 = sim, 255 = fora da cena. Lemos só a janela da região
  (pedidos HTTP com `Range`) no nível de 40 m do COG.
- **Camadas usadas:** `ensemble_water_extent` (água aberta observada),
  `ensemble_flood_extent` (água fora da máscara de referência = inundação),
  `exclusion_mask` (onde o radar não consegue classificar: floresta densa,
  sombra de relevo, áreas urbanas). Disponíveis e não usadas: `*_likelihood`,
  `reference_water_mask`, `advisory_flags`.
- **Atualidade:** cena em Manaus de 10/11/2026 já estava no catálogo em 18/11.
  O GFM declara ~8 h após a passagem. Revisita no ponto: ~6–12 dias
  (só um satélite em operação em parte do período).
- **Cota:** sem cota publicada para o STAC/arquivos. Uso previsto:
  6 regiões × 4 verificações/dia = 24 buscas STAC/dia (~720/mês). Cena nova
  (~1 por região a cada 6–12 dias): ~3 camadas × poucas centenas de KB.
  Total < 50 MB/mês. Uma região já verificada há menos de 1 h é pulada.
- **Alternativa (não escolhida):** Sentinel Hub no Copernicus Data Space —
  exige conta e chave OAuth; teríamos de criar o limiar de água nós mesmos.

## Limites conhecidos (aparecem no app)

1. Radar banda C não enxerga água sob floresta densa: várzea e igapó
   alagados sob a copa NÃO aparecem. Nunca é a "extensão total da cheia".
2. Uma imagem por passagem; entre passagens o mapa fica velho (mostramos a data
   e a idade, e "desatualizado" com mais de 14 dias).
3. Vento e chuva forte na hora da passagem podem esconder água; áreas urbanas
   e relevo entram na máscara de exclusão.
4. O satélite é informação complementar. O nível do alerta continua vindo só
   das cotas oficiais do SGB/ANA.

Atribuição: "Copernicus Emergency Management Service — Global Flood Monitoring".
