// Partes puras da ingestão (sem rede): projeção, recorte da região,
// agrupamento das cenas, mosaico e vetorização da máscara de água.
// Testadas em nucleo_test.ts com dados reais gravados em fixtures/.
import proj4 from "npm:proj4@2.12.1";

/** Grade Equi7 da América do Sul (a mesma dos arquivos do GFM). */
export const EQUI7_SA =
  "+proj=aeqd +lat_0=-14 +lon_0=-60.5 +x_0=7257179.23559 +y_0=5592024.44605 +datum=WGS84 +units=m +no_defs";
const conv = proj4("EPSG:4326", EQUI7_SA);

export function paraEqui7(lng: number, lat: number): [number, number] {
  return conv.forward([lng, lat]) as [number, number];
}
/** Inversa por Newton sobre a direta. O inverse() do proj4js (2.12) erra a
 *  latitude no hemisfério sul nesta projeção (dá ~177°); a direta confere
 *  com os cantos dos ladrilhos publicados no STAC (ver nucleo_test.ts). */
export function deEqui7(x: number, y: number): [number, number] {
  let lat = -14 + (y - 5592024.44605) / 110_574;
  let lng = -60.5 + (x - 7257179.23559) / (111_320 * Math.cos((lat * Math.PI) / 180));
  const h = 1e-6;
  for (let i = 0; i < 10; i++) {
    const [fx, fy] = paraEqui7(lng, lat);
    const ex = fx - x, ey = fy - y;
    if (Math.abs(ex) < 1e-4 && Math.abs(ey) < 1e-4) break;
    const [ax, ay] = paraEqui7(lng + h, lat);
    const [bx, by] = paraEqui7(lng, lat + h);
    const j11 = (ax - fx) / h, j21 = (ay - fy) / h, j12 = (bx - fx) / h, j22 = (by - fy) / h;
    const det = j11 * j22 - j12 * j21;
    lng -= (j22 * ex - j12 * ey) / det;
    lat -= (-j21 * ex + j11 * ey) / det;
  }
  return [lng, lat];
}

/** Pixel usado (nível de 40 m do COG; o original é 20 m). */
export const PIXEL_M = 40;
/** Meio lado do quadrado analisado em volta da estação. */
export const RAIO_M = 25_000;

/** Quadrado da região na grade Equi7, alinhado aos pixels de 40 m. */
export interface Grade {
  x0: number; // borda oeste (m)
  y0: number; // borda norte (m)
  largura: number; // colunas
  altura: number; // linhas
  px?: number; // tamanho do pixel em m (padrão PIXEL_M)
}

/** Mesma área em pixels maiores (fator 16 → 640 m): para saber, lendo
 *  poucos KB, se a cena cobre a região antes de baixar a camada inteira. */
export function gradeGrossa(g: Grade, fator: number): Grade {
  return {
    x0: g.x0, y0: g.y0, px: (g.px ?? PIXEL_M) * fator,
    largura: Math.ceil(g.largura / fator), altura: Math.ceil(g.altura / fator),
  };
}

export function gradeDaEstacao(lat: number, lng: number, raio = RAIO_M): Grade {
  const [cx, cy] = paraEqui7(lng, lat);
  const x0 = Math.floor((cx - raio) / PIXEL_M) * PIXEL_M;
  const y0 = Math.ceil((cy + raio) / PIXEL_M) * PIXEL_M;
  const n = Math.round((2 * raio) / PIXEL_M);
  return { x0, y0, largura: n, altura: n };
}

/** Passo da malha de pontos exatos usada para interpolar os cantos. */
const PASSO_MALHA = 50; // 50 px = 2 km; erro da interpolação < 1 mm aqui
const malhas = new WeakMap<Grade, Float64Array>();

function malha(g: Grade): Float64Array {
  let m = malhas.get(g);
  if (m) return m;
  const px = g.px ?? PIXEL_M;
  const nc = Math.ceil(g.largura / PASSO_MALHA) + 1, nl = Math.ceil(g.altura / PASSO_MALHA) + 1;
  m = new Float64Array(nc * nl * 2);
  for (let l = 0; l < nl; l++) {
    for (let c = 0; c < nc; c++) {
      const [lng, lat] = deEqui7(g.x0 + c * PASSO_MALHA * px, g.y0 - l * PASSO_MALHA * px);
      m[(l * nc + c) * 2] = lng;
      m[(l * nc + c) * 2 + 1] = lat;
    }
  }
  malhas.set(g, m);
  return m;
}

/** Canto (coluna, linha) da grade em lon/lat, arredondado para 6 casas
 *  (~10 cm). Interpolado numa malha de pontos exatos (a projeção é suave;
 *  inverter ponto a ponto custava ~1 s de CPU). Sempre a mesma conta para o
 *  mesmo canto, então retângulos vizinhos dividem exatamente as mesmas
 *  coordenadas e o PostGIS os funde. */
export function canto(g: Grade, col: number, lin: number): [number, number] {
  const m = malha(g);
  const nc = Math.ceil(g.largura / PASSO_MALHA) + 1;
  const fc = col / PASSO_MALHA, fl = lin / PASSO_MALHA;
  const c0 = Math.min(Math.floor(fc), nc - 2), l0 = Math.floor(fl);
  const l0c = Math.min(l0, Math.ceil(g.altura / PASSO_MALHA) - 1);
  const tc = fc - c0, tl = fl - l0c;
  const p = (c: number, l: number, k: number) => m[(l * nc + c) * 2 + k];
  const v = (k: number) =>
    (1 - tl) * ((1 - tc) * p(c0, l0c, k) + tc * p(c0 + 1, l0c, k)) +
    tl * ((1 - tc) * p(c0, l0c + 1, k) + tc * p(c0 + 1, l0c + 1, k));
  return [Math.round(v(0) * 1e6) / 1e6, Math.round(v(1) * 1e6) / 1e6];
}

/** Contorno do quadrado em lon/lat (com pontos intermediários nas bordas). */
export function contornoDaGrade(g: Grade, passos = 8): [number, number][] {
  const anel: [number, number][] = [];
  const { largura: w, altura: h } = g;
  for (let i = 0; i < passos; i++) anel.push(canto(g, (w * i) / passos, 0));
  for (let i = 0; i < passos; i++) anel.push(canto(g, w, (h * i) / passos));
  for (let i = passos; i > 0; i--) anel.push(canto(g, (w * i) / passos, h));
  for (let i = passos; i > 0; i--) anel.push(canto(g, 0, (h * i) / passos));
  anel.push(anel[0]);
  return anel;
}

export function bboxDoContorno(anel: [number, number][]): [number, number, number, number] {
  let a = Infinity, b = Infinity, c = -Infinity, d = -Infinity;
  for (const [x, y] of anel) {
    a = Math.min(a, x); b = Math.min(b, y); c = Math.max(c, x); d = Math.max(d, y);
  }
  return [a, b, c, d];
}

// ---------------------------------------------------------------- STAC

export interface ItemStac {
  id: string;
  datetime: string;
  agua: string;
  inundacao: string;
  exclusao: string;
}

export interface Passagem {
  observadoEm: string; // a cena mais antiga do grupo (ISO)
  itens: ItemStac[];
}

// deno-lint-ignore no-explicit-any
export function lerItens(resposta: any): ItemStac[] {
  const itens: ItemStac[] = [];
  for (const f of resposta?.features ?? []) {
    const a = f?.assets ?? {};
    const agua = a.ensemble_water_extent?.href;
    const inundacao = a.ensemble_flood_extent?.href;
    const exclusao = a.exclusion_mask?.href;
    const dt = f?.properties?.datetime;
    if (!agua || !inundacao || !exclusao || !dt) continue;
    itens.push({ id: String(f.id), datetime: dt, agua, inundacao, exclusao });
  }
  return itens;
}

/** Junta as cenas da mesma passagem do satélite (cenas consecutivas da
 *  mesma órbita saem com segundos de diferença). Mais nova primeiro. */
export function agruparPassagens(itens: ItemStac[], janelaMin = 10): Passagem[] {
  const ord = [...itens].sort((p, q) => Date.parse(p.datetime) - Date.parse(q.datetime));
  const grupos: Passagem[] = [];
  let ultimo = -Infinity;
  for (const it of ord) {
    const t = Date.parse(it.datetime);
    if (t - ultimo > janelaMin * 60_000 || grupos.length === 0) {
      grupos.push({ observadoEm: new Date(t).toISOString(), itens: [] });
    }
    grupos[grupos.length - 1].itens.push(it);
    ultimo = t;
  }
  return grupos.reverse();
}

// ------------------------------------------------------------- mosaico

export const SEM_DADO = 255;

/** Uma camada da região: começa toda "sem dado" e cada cena preenche
 *  só os pixels que ainda não têm valor. */
export function camadaVazia(g: Grade): Uint8Array {
  return new Uint8Array(g.largura * g.altura).fill(SEM_DADO);
}

/** Posição de uma janela do arquivo (origem oX, oY em metros, no nível
 *  com o pixel da grade) dentro da grade, cortada às bordas do arquivo
 *  (tamanho lado). */
export function janelaNoArquivo(g: Grade, oX: number, oY: number, lado: number) {
  const px = g.px ?? PIXEL_M;
  const c0 = Math.round((g.x0 - oX) / px);
  const l0 = Math.round((oY - g.y0) / px);
  const a = Math.max(0, c0), b = Math.max(0, l0);
  const c = Math.min(lado, c0 + g.largura), d = Math.min(lado, l0 + g.altura);
  if (c <= a || d <= b) return null;
  return { janela: [a, b, c, d] as [number, number, number, number], dc: a - c0, dl: b - l0 };
}

export function preencher(
  camada: Uint8Array, g: Grade, valores: Uint8Array, larg: number, alt: number,
  dc: number, dl: number,
) {
  for (let l = 0; l < alt; l++) {
    const base = (l + dl) * g.largura + dc;
    for (let c = 0; c < larg; c++) {
      const v = valores[l * larg + c];
      if (v !== SEM_DADO && camada[base + c] === SEM_DADO) camada[base + c] = v;
    }
  }
}

// ------------------------------------------------------------- números

/** Porcentagem da grade com dado (qualquer valor diferente de SEM_DADO). */
export function coberturaPct(camada: Uint8Array): number {
  let n = 0;
  for (const v of camada) if (v !== SEM_DADO) n++;
  return (100 * n) / camada.length;
}

export interface Resumo {
  pixels: number;
  cobertos: number;
  agua: number;
  inundacao: number;
}

export function resumir(agua: Uint8Array, inundacao: Uint8Array): Resumo {
  const r: Resumo = { pixels: agua.length, cobertos: 0, agua: 0, inundacao: 0 };
  for (let i = 0; i < agua.length; i++) {
    if (agua[i] === SEM_DADO) continue;
    r.cobertos++;
    if (agua[i] === 1) r.agua++;
    if (inundacao[i] === 1) r.inundacao++;
  }
  return r;
}

/** % dos pixels com dado que valem 1 (para a máscara de exclusão). */
export function pctUns(camada: Uint8Array): number {
  let validos = 0, uns = 0;
  for (const v of camada) {
    if (v === SEM_DADO) continue;
    validos++;
    if (v === 1) uns++;
  }
  return validos ? (100 * uns) / validos : 0;
}

export const km2 = (pixels: number) => (pixels * PIXEL_M * PIXEL_M) / 1e6;

// ---------------------------------------------------------- vetorização
//
// Contorna os pixels de água (valor 1) e devolve polígonos prontos, com
// buracos, em coordenadas de canto de pixel (coluna, linha). Feito aqui, e
// não com ST_Union no banco: fundir milhares de quadradinhos no PostGIS
// levou ~10 s por região e chegou a derrubar o processo num teste local.

const DC = [1, 0, -1, 0]; // direção 0 = leste, 1 = sul, 2 = oeste, 3 = norte
const DL = [0, 1, 0, -1];

/** Componentes de água ligadas pelos lados (4-vizinhança). 0 = sem água. */
export function rotular(m: Uint8Array, larg: number, alt: number): Int32Array {
  const rot = new Int32Array(larg * alt);
  const pilha = new Int32Array(larg * alt);
  let n = 0;
  for (let i = 0; i < m.length; i++) {
    if (m[i] !== 1 || rot[i] !== 0) continue;
    n++;
    let topo = 0;
    pilha[topo++] = i;
    rot[i] = n;
    while (topo > 0) {
      const p = pilha[--topo];
      const c = p % larg, l = (p - c) / larg;
      if (c > 0 && m[p - 1] === 1 && rot[p - 1] === 0) { rot[p - 1] = n; pilha[topo++] = p - 1; }
      if (c < larg - 1 && m[p + 1] === 1 && rot[p + 1] === 0) { rot[p + 1] = n; pilha[topo++] = p + 1; }
      if (l > 0 && m[p - larg] === 1 && rot[p - larg] === 0) { rot[p - larg] = n; pilha[topo++] = p - larg; }
      if (l < alt - 1 && m[p + larg] === 1 && rot[p + larg] === 0) { rot[p + larg] = n; pilha[topo++] = p + larg; }
    }
  }
  return rot;
}

/** Douglas-Peucker num anel fechado (primeiro ponto repetido no fim). */
export function simplificarAnel(anel: number[][], tol: number): number[][] {
  const n = anel.length;
  if (n <= 5) return anel;
  const manter = new Uint8Array(n);
  manter[0] = manter[n - 1] = 1;
  // Ponto mais longe do primeiro, para o anel não colapsar.
  let meio = 1, dmax = -1;
  for (let i = 1; i < n - 1; i++) {
    const d = (anel[i][0] - anel[0][0]) ** 2 + (anel[i][1] - anel[0][1]) ** 2;
    if (d > dmax) { dmax = d; meio = i; }
  }
  manter[meio] = 1;
  const pilha: number[] = [0, meio, meio, n - 1];
  const tol2 = tol * tol;
  while (pilha.length) {
    const b = pilha.pop()!, a = pilha.pop()!;
    const [ax, ay] = anel[a], [bx, by] = anel[b];
    const dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy;
    let k = -1, maior = tol2;
    for (let i = a + 1; i < b; i++) {
      const px = anel[i][0] - ax, py = anel[i][1] - ay;
      const cruz = px * dy - py * dx;
      const d2 = len2 > 0 ? (cruz * cruz) / len2 : px * px + py * py;
      if (d2 > maior) { maior = d2; k = i; }
    }
    if (k >= 0) { manter[k] = 1; pilha.push(a, k, k, b); }
  }
  const out = anel.filter((_, i) => manter[i] === 1);
  return out.length >= 4 ? out : anel;
}

function areaAnel(anel: number[][]): number {
  let s = 0;
  for (let i = 0; i < anel.length - 1; i++) {
    s += anel[i][0] * anel[i + 1][1] - anel[i + 1][0] * anel[i][1];
  }
  return s / 2; // em pixels; > 0 = sentido horário na tela (linha cresce para baixo)
}

/** Polígonos (anel externo + buracos) em vértices de pixel. Manchas com
 *  menos de minPixels são descartadas (só do desenho: as áreas vêm da
 *  contagem de pixels). tol: tolerância do Douglas-Peucker em pixels. */
export function vetorizar(
  m: Uint8Array, larg: number, alt: number, tol = 1.25, minPixels = 25,
): number[][][][] {
  const rot = rotular(m, larg, alt);
  const agua = (c: number, l: number) =>
    c >= 0 && l >= 0 && c < larg && l < alt && m[l * larg + c] === 1;
  // Arestas da borda, com a água à direita de quem anda (sentido horário na
  // tela). Até 2 saídas por vértice (quando duas águas se tocam só na ponta).
  const nv = (larg + 1) * (alt + 1);
  const saida1 = new Int8Array(nv).fill(-1), saida2 = new Int8Array(nv).fill(-1);
  const por = (c: number, l: number, d: number) => {
    const v = l * (larg + 1) + c;
    if (saida1[v] < 0) saida1[v] = d; else saida2[v] = d;
  };
  for (let l = 0; l < alt; l++) {
    for (let c = 0; c < larg; c++) {
      if (m[l * larg + c] !== 1) continue;
      if (!agua(c, l - 1)) por(c, l, 0);
      if (!agua(c + 1, l)) por(c + 1, l, 1);
      if (!agua(c, l + 1)) por(c + 1, l + 1, 2);
      if (!agua(c - 1, l)) por(c, l + 1, 3);
    }
  }
  // Pixel à direita da aresta que sai de (c, l) na direção d.
  const pixelDireita = (c: number, l: number, d: number) =>
    d === 0 ? [c, l] : d === 1 ? [c - 1, l] : d === 2 ? [c - 1, l - 1] : [c, l - 1];

  const externos = new Map<number, number[][]>();
  const buracos = new Map<number, number[][][]>();
  const tamanho = new Map<number, number>();
  for (let i = 0; i < m.length; i++) if (rot[i]) tamanho.set(rot[i], (tamanho.get(rot[i]) ?? 0) + 1);

  // Começa só em vértices com uma saída: um anel passa uma única vez por
  // eles, então "voltei ao início" fecha o anel sem ambiguidade.
  for (let v0 = 0; v0 < nv; v0++) {
    while (saida1[v0] >= 0 && saida2[v0] < 0) {
      let d = saida1[v0];
      const c0 = v0 % (larg + 1), l0 = (v0 - c0) / (larg + 1);
      const [pc, pl] = pixelDireita(c0, l0, d);
      const dono = rot[pl * larg + pc];
      const anel: number[][] = [[c0, l0]];
      let c = c0, l = l0, v = v0;
      for (;;) {
        if (saida1[v] === d) { saida1[v] = saida2[v]; saida2[v] = -1; } else saida2[v] = -1;
        c += DC[d]; l += DL[d]; v = l * (larg + 1) + c;
        if (v === v0) break;
        // Prefere virar à direita (contorna o mesmo pixel: 4-vizinhança),
        // depois seguir reto, depois esquerda.
        let prox = -1;
        for (const o of [(d + 1) % 4, d, (d + 3) % 4]) {
          if (saida1[v] === o || saida2[v] === o) { prox = o; break; }
        }
        if (prox < 0) break; // não acontece com borda bem formada
        if (prox !== d) anel.push([c, l]);
        d = prox;
      }
      anel.push([c0, l0]);
      if (anel.length < 4) continue;
      const area = areaAnel(anel);
      if (area > 0) externos.set(dono, anel);
      else {
        const b = buracos.get(dono) ?? [];
        b.push(anel);
        buracos.set(dono, b);
      }
    }
  }

  const poligonos: number[][][][] = [];
  for (const [dono, ext] of externos) {
    if ((tamanho.get(dono) ?? 0) < minPixels) continue;
    const aneis = [simplificarAnel(ext, tol)];
    for (const b of buracos.get(dono) ?? []) {
      if (-areaAnel(b) < minPixels) continue; // ilhota seca minúscula: some do desenho
      aneis.push(simplificarAnel(b, tol));
    }
    poligonos.push(aneis);
  }
  return poligonos;
}

/** GeoJSON MultiPolygon em lon/lat. A linha cresce para o sul, então o
 *  sentido horário na tela vira anti-horário no mapa: externos já saem no
 *  sentido que o GeoJSON pede. */
export function multiPoligono(g: Grade, poligonos: number[][][][]) {
  return {
    type: "MultiPolygon",
    coordinates: poligonos.map((p) => p.map((anel) => anel.map(([c, l]) => canto(g, c, l)))),
  };
}
