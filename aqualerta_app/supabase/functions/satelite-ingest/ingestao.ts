// Ingestão de água detectada por satélite (Copernicus EMS — GFM, Sentinel-1).
//
// Para cada região: quadrado de 50 km em volta da estação → busca no STAC
// público da EODC as passagens mais novas que a última guardada → lê só a
// janela da região nos COGs (água observada, inundação, máscara de exclusão)
// → conta pixels e vetoriza a água → satelite_registrar() funde, simplifica,
// recorta e grava (ON CONFLICT DO NOTHING).
//
// Sem conta nem chave externa. Este arquivo não fala com o banco: quem grava
// é a função `gravar` recebida (index.ts usa a RPC; o teste local, o psql).
import { addDecoder, fromUrl } from "npm:geotiff@2.1.3";
import { decompress } from "npm:fzstd@0.1.1";
import {
  agruparPassagens, bboxDoContorno, camadaVazia, contornoDaGrade, type Grade,
  coberturaPct, gradeDaEstacao, gradeGrossa, janelaNoArquivo, km2, lerItens, multiPoligono, type Passagem,
  pctUns, PIXEL_M, preencher, resumir, vetorizar,
} from "./nucleo.ts";

const STAC = "https://stac.eodc.eu/api/v1/search";
const FONTE = "copernicus-gfm";
const PRODUTO = "ensemble_water_extent";
const TEMPO_MS = 20_000;
/** Primeira carga: quanto voltar no tempo. */
const DIAS_INICIAIS = 30;
/** Só grava se a passagem cobriu pelo menos isto do quadrado. */
const COBERTURA_MIN = 60;
/** Passagens examinadas (pela leitura grossa) por chamada. */
const MAX_PASSAGENS = 8;
/** Passagens gravadas por chamada. */
const MAX_GRAVADAS = 1;
/** Leitura grossa: pixel de 640 m. */
const FATOR_GROSSO = 16;

// Os arquivos do GFM usam compressão ZSTD (código 50000), que o geotiff.js
// não traz. Sem preditor (Predictor = 1) nestes arquivos; tratamos o 2 por via
// das dúvidas.
class Zstd {
  // deno-lint-ignore no-explicit-any
  decode(fd: any, b: ArrayBuffer) {
    const out = decompress(new Uint8Array(b));
    if ((fd.Predictor ?? 1) === 2) {
      const w = fd.TileWidth ?? fd.ImageWidth;
      for (let i = 0; i < out.length; i += w) {
        for (let j = 1; j < w; j++) out[i + j] = (out[i + j] + out[i + j - 1]) & 255;
      }
    }
    return Promise.resolve(out.buffer.slice(out.byteOffset, out.byteOffset + out.byteLength));
  }
}
addDecoder(50000, () => Promise.resolve(Zstd));

// ------------------------------------------------------------ utilidades

function comPrazo<T>(p: Promise<T>, ms = TEMPO_MS): Promise<T> {
  let t: number | undefined;
  return Promise.race([
    p.finally(() => clearTimeout(t)),
    new Promise<T>((_, rej) => { t = setTimeout(() => rej(new Error("tempo esgotado")), ms); }),
  ]);
}

async function tentar<T>(f: () => Promise<T>, vezes = 3): Promise<T> {
  let erro: unknown;
  for (let i = 0; i < vezes; i++) {
    try { return await f(); } catch (e) {
      erro = e;
      if (i < vezes - 1) await new Promise((r) => setTimeout(r, 1000 * 2 ** i));
    }
  }
  throw erro;
}

// ---------------------------------------------------------------- etapas

async function buscarPassagens(bbox: number[], desde: Date): Promise<Passagem[]> {
  const u = new URL(STAC);
  u.searchParams.set("collections", "GFM");
  u.searchParams.set("bbox", bbox.map((v) => v.toFixed(5)).join(","));
  const iso = (d: Date) => d.toISOString().replace(/\.\d{3}Z$/, "Z");
  u.searchParams.set("datetime", `${iso(desde)}/${iso(new Date())}`);
  u.searchParams.set("limit", "100");
  const dados = await tentar(async () => {
    const r = await fetch(u, { signal: AbortSignal.timeout(TEMPO_MS) });
    if (!r.ok) throw new Error(`STAC HTTP ${r.status}`);
    return await r.json();
  });
  return agruparPassagens(lerItens(dados));
}

/** Lê a janela da grade num COG do GFM (no nível com o pixel da grade) e
 *  soma na camada. */
async function lerNaCamada(url: string, g: Grade, camada: Uint8Array) {
  await tentar(() =>
    comPrazo((async () => {
      const tif = await fromUrl(url);
      const base = await tif.getImage(0);
      const [oX, oY] = base.getOrigin();
      const [rx] = base.getResolution();
      const px = g.px ?? PIXEL_M;
      const nivel = Math.round(Math.log2(px / rx));
      const img = await tif.getImage(nivel);
      const lado = img.getWidth();
      // 40 m bate exato (7500 px); os níveis grossos arredondam (468 px ≈
      // 641 m), o que só importa para a prévia de cobertura.
      if (Math.abs(base.getWidth() * rx / lado - px) > px * 0.01) {
        throw new Error(`nível de ${px} m não encontrado`);
      }
      const j = janelaNoArquivo(g, oX, oY, lado);
      if (!j) return;
      const [a, b, c, d] = j.janela;
      const [valores] = await img.readRasters({ window: j.janela }) as unknown as Uint8Array[];
      preencher(camada, g, valores, c - a, d - b, j.dc, j.dl);
    })())
  );
}

export interface Regiao { id: string; name: string; lat: number; lng: number; desde: string | null }

/** Chama gravar(payload) para cada passagem completa; gravar devolve true
 *  se a observação é nova. */
export async function processarRegiao(
  r: Regiao, gravar: (p: Record<string, unknown>) => Promise<boolean>,
) {
  const g = gradeDaEstacao(r.lat, r.lng);
  const contorno = contornoDaGrade(g);
  const bbox = bboxDoContorno(contorno);
  const desde = r.desde
    ? new Date(Date.parse(r.desde) + 1000)
    : new Date(Date.now() - DIAS_INICIAIS * 86_400_000);

  const passagens = (await buscarPassagens(bbox, desde)).slice(0, MAX_PASSAGENS);
  const saida = { region: r.name, inserted: 0, skipped: 0, notas: [] as string[] };
  if (passagens.length === 0) saida.notas.push("sem passagem nova");

  for (const p of passagens) {
    if (saida.inserted >= MAX_GRAVADAS) break;
    // A busca casa pelo ladrilho de 300 km, não pela faixa da cena: muitas
    // passagens nem tocam a região. Confere com poucos KB antes.
    const grossa = gradeGrossa(g, FATOR_GROSSO);
    const previa = camadaVazia(grossa);
    const usadas = [];
    for (const it of p.itens) {
      const antes = coberturaPct(previa);
      await lerNaCamada(it.agua, grossa, previa);
      if (coberturaPct(previa) > antes) usadas.push(it); // cena que toca a região
    }
    const coberturaPrevia = coberturaPct(previa);
    if (coberturaPrevia < COBERTURA_MIN - 10) {
      saida.skipped++;
      saida.notas.push(`${p.observadoEm}: cobriu ~${coberturaPrevia.toFixed(0)}% do quadrado`);
      continue;
    }
    // A máscara de exclusão só vira uma porcentagem no cartão: basta 160 m.
    const gExcl = gradeGrossa(g, 4);
    const agua = camadaVazia(g), inund = camadaVazia(g), excl = camadaVazia(gExcl);
    for (const it of usadas) {
      await lerNaCamada(it.agua, g, agua);
      await lerNaCamada(it.inundacao, g, inund);
      await lerNaCamada(it.exclusao, gExcl, excl);
    }
    const s = resumir(agua, inund);
    const excluidaPct = pctUns(excl);
    const cobertura = (100 * s.cobertos) / s.pixels;
    if (cobertura < COBERTURA_MIN) {
      saida.skipped++;
      saida.notas.push(`${p.observadoEm}: cobriu ${cobertura.toFixed(0)}% do quadrado`);
      continue;
    }
    const poligonos = vetorizar(agua, g.largura, g.altura);
    const novo = await gravar({
        region_id: r.id,
        fonte: FONTE,
        produto: PRODUTO,
        observado_em: p.observadoEm,
        area_agua_km2: +km2(s.agua).toFixed(3),
        area_inundada_km2: +km2(s.inundacao).toFixed(3),
        cobertura_pct: +cobertura.toFixed(1),
        agua: multiPoligono(g, poligonos),
        recorte: { type: "Polygon", coordinates: [contorno] },
        metadata: {
          cenas: usadas.map((i) => i.id),
          pixel_m: PIXEL_M,
          quadrado_km2: km2(s.pixels),
          excluida_pct: +excluidaPct.toFixed(1),
          atribuicao: "Copernicus Emergency Management Service — Global Flood Monitoring",
        },
    });
    if (novo === true) saida.inserted++; else saida.skipped++;
  }
  return saida;
}

