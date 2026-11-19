// deno test --allow-read supabase/functions/satelite-ingest/
//
// Fixtures reais (fixtures/): resposta do STAC da EODC para Manaus, cortada,
// e um recorte de 200 × 200 px (40 m) da camada de água do GFM de 03/11/2026
// no Encontro das Águas, gravado como bytes (0 = seco, 1 = água, 255 = sem dado).
import {
  assert, assertAlmostEquals, assertEquals,
} from "jsr:@std/assert@1.0.8";
import {
  agruparPassagens, bboxDoContorno, camadaVazia, contornoDaGrade, coberturaPct, deEqui7,
  gradeDaEstacao, janelaNoArquivo, lerItens, multiPoligono, paraEqui7, pctUns, preencher,
  resumir, SEM_DADO, vetorizar,
} from "./nucleo.ts";

const dir = new URL("./fixtures/", import.meta.url);
const stac = JSON.parse(Deno.readTextFileSync(new URL("stac_manaus.json", dir)));
const recorte = Deno.readFileSync(new URL("agua_manaus_20261103_200px.bin", dir));

/** Área (em pixels) de um polígono em vértices de pixel: externo − buracos. */
function areaPx(p: number[][][]): number {
  const a = (r: number[][]) => {
    let s = 0;
    for (let i = 0; i < r.length - 1; i++) s += r[i][0] * r[i + 1][1] - r[i + 1][0] * r[i][1];
    return s / 2;
  };
  return p.reduce((t, r) => t + a(r), 0);
}

function grade(linhas: string[]): [Uint8Array, number, number] {
  const alt = linhas.length, larg = linhas[0].length;
  const m = new Uint8Array(larg * alt);
  linhas.forEach((l, i) => [...l].forEach((ch, j) => (m[i * larg + j] = ch === "#" ? 1 : 0)));
  return [m, larg, alt];
}

Deno.test("projeção: cantos do ladrilho E072N066T3 batem com o bbox do STAC", () => {
  const item = stac.features[0];
  assert(String(item.properties.Equi7Tile).endsWith("E072N066T3"));
  // Os quatro cantos do ladrilho (300 km). O STAC publica com ~3 m de
  // diferença (outra implementação da projeção); o pixel é de 40 m, então
  // aceitamos até 1e-4° (~11 m).
  const cantos = [[7_200_000, 6_600_000], [7_200_000, 6_900_000], [7_500_000, 6_900_000], [7_500_000, 6_600_000]];
  cantos.forEach(([x, y], i) => {
    const [lng, lat] = deEqui7(x, y);
    const [gLng, gLat] = item.geometry.coordinates[0][i];
    assertAlmostEquals(lng, gLng, 1e-4);
    assertAlmostEquals(lat, gLat, 1e-4);
  });
  // Ida e volta.
  const [x, y] = paraEqui7(-60.0272, -3.1383);
  const [l2, a2] = deEqui7(x, y);
  assertAlmostEquals(l2, -60.0272, 1e-9);
  assertAlmostEquals(a2, -3.1383, 1e-9);
});

Deno.test("quadrado de 50 km em volta da estação de Manaus", () => {
  const g = gradeDaEstacao(-3.1383, -60.0272);
  assertEquals([g.largura, g.altura], [1250, 1250]);
  const [a, b, c, d] = bboxDoContorno(contornoDaGrade(g));
  assert(a < -60.0272 && c > -60.0272 && b < -3.1383 && d > -3.1383);
  // ~0,45° de lado perto do equador.
  assertAlmostEquals(c - a, 0.45, 0.01);
  assertAlmostEquals(d - b, 0.45, 0.01);
});

Deno.test("STAC: lê os itens e junta as cenas da mesma passagem", () => {
  const itens = lerItens(stac);
  assertEquals(itens.length, 9);
  assert(itens.every((i) => i.agua.endsWith(".tif") && i.exclusao.includes("EXCLAYER")));
  const ps = agruparPassagens(itens);
  assertEquals(ps.map((p) => p.observadoEm), [
    "2026-11-10T09:30:24.000Z", "2026-11-08T09:46:32.000Z", "2026-11-03T09:38:21.000Z",
  ]);
  assertEquals(ps.map((p) => p.itens.length), [3, 3, 3]);
});

Deno.test("STAC: item sem as camadas usadas é ignorado, resposta vazia não quebra", () => {
  assertEquals(lerItens({ features: [{ id: "x", properties: { datetime: "2026-01-01T00:00:00Z" }, assets: {} }] }), []);
  assertEquals(lerItens({}), []);
  assertEquals(agruparPassagens([]), []);
});

Deno.test("mosaico: janela no arquivo e preenchimento só onde falta dado", () => {
  const g = { x0: 1000, y0: 2000, largura: 4, altura: 3 };
  // Arquivo começando 2 px a leste da grade: só as colunas 2-3 caem nele.
  const j = janelaNoArquivo(g, 1080, 2000, 100)!;
  assertEquals(j.janela, [0, 0, 2, 3]);
  assertEquals([j.dc, j.dl], [2, 0]);
  const cam = camadaVazia(g);
  preencher(cam, g, new Uint8Array([1, 0, 1, 0, 1, 0]), 2, 3, j.dc, j.dl);
  preencher(cam, g, new Uint8Array(6).fill(1), 2, 3, j.dc, j.dl); // não sobrescreve
  assertEquals([...cam.slice(0, 4)], [SEM_DADO, SEM_DADO, 1, 0]);
  assertEquals(coberturaPct(cam), 50);
  assertEquals(janelaNoArquivo(g, 9_000_000, 2000, 100), null);
});

Deno.test("números: pixels de 40 m e máscara de exclusão", () => {
  const agua = new Uint8Array([1, 1, 0, SEM_DADO]);
  const inund = new Uint8Array([1, 0, 0, SEM_DADO]);
  const r = resumir(agua, inund);
  assertEquals(r, { pixels: 4, cobertos: 3, agua: 2, inundacao: 1 });
  assertEquals(pctUns(new Uint8Array([1, 0, 0, 0, SEM_DADO])), 25);
  assertEquals(pctUns(new Uint8Array([SEM_DADO])), 0);
});

Deno.test("vetorização: quadrado com buraco vira 1 polígono com 2 anéis", () => {
  const [m, w, h] = grade([
    "#####",
    "#...#",
    "#...#",
    "#...#",
    "#####",
  ]);
  const ps = vetorizar(m, w, h, 0, 0);
  assertEquals(ps.length, 1);
  assertEquals(ps[0].length, 2);
  assertEquals(areaPx(ps[0]), 16); // 25 − 9
  // Externo horário na tela (área > 0), buraco anti-horário.
  assert(areaPx([ps[0][0]]) > 0 && areaPx([ps[0][1]]) < 0);
});

Deno.test("vetorização: pixels que só se tocam na ponta são polígonos separados", () => {
  const [m, w, h] = grade([
    "#.",
    ".#",
  ]);
  const ps = vetorizar(m, w, h, 0, 0);
  assertEquals(ps.length, 2);
  assertEquals(ps.map((p) => areaPx(p)), [1, 1]);
});

Deno.test("vetorização: manchas pequenas somem só do desenho", () => {
  const [m, w, h] = grade([
    "##....",
    "##....",
    "...###",
    "...###",
    "...###",
  ]);
  assertEquals(vetorizar(m, w, h, 0, 5).length, 1); // a de 4 px some, a de 9 fica
  assertEquals(vetorizar(m, w, h, 0, 0).length, 2);
  assertEquals(vetorizar(new Uint8Array(9), 3, 3).length, 0); // sem água
});

Deno.test("vetorização do recorte real: área exata sem simplificar, próxima com", () => {
  const n = 200;
  const g = { x0: 7320240, y0: 6801560, largura: n, altura: n };
  const agua = recorte.reduce((t, v) => t + (v === 1 ? 1 : 0), 0);
  assertEquals(agua, 13443); // gravado do arquivo do GFM
  const exato = vetorizar(recorte, n, n, 0, 0);
  assertEquals(exato.reduce((t, p) => t + areaPx(p), 0), agua);
  const simples = vetorizar(recorte, n, n); // 50 m, sem manchas < 25 px
  const area = simples.reduce((t, p) => t + areaPx(p), 0);
  assert(Math.abs(area - agua) / agua < 0.03, `área simplificada ${area} vs ${agua}`);
  const pontos = (ps: number[][][][]) => ps.flat(2).length;
  assert(pontos(simples) < pontos(exato) / 2);
  // GeoJSON: anéis fechados, dentro do quadrado do recorte.
  const mp = multiPoligono(g, simples);
  const [a, b, c, d] = bboxDoContorno(contornoDaGrade(g));
  for (const p of mp.coordinates) {
    for (const anel of p) {
      assertEquals(anel[0], anel[anel.length - 1]);
      for (const [x, y] of anel) assert(x >= a - 1e-6 && x <= c + 1e-6 && y >= b - 1e-6 && y <= d + 1e-6);
    }
  }
});
