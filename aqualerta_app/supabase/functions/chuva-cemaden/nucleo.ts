// Partes puras da coleta de chuva do CEMADEN (sem rede). Testadas em
// nucleo_test.ts com respostas reais gravadas em fixtures/.
//
// Fontes abertas (sem conta), as mesmas do mapa interativo do CEMADEN:
// - lista de estações + acumulado de 24 h, JSONP, todo o Brasil (~2 MB):
//   https://resources.cemaden.gov.br/dados/311_24.json
// - chuva hora a hora de uma estação (horas em UTC, a última é a corrente):
//   https://mapservices.cemaden.gov.br/MapaInterativoWS/resources/horario/{id}/{horas}

export const URL_ESTACOES = "https://resources.cemaden.gov.br/dados/311_24.json";
export const urlHorario = (id: number, horas = 3) =>
  `https://mapservices.cemaden.gov.br/MapaInterativoWS/resources/horario/${id}/${horas}`;

export interface Municipio { region_id: string; ibge: number }

export interface Estacao {
  id: number;
  codigo: string;
  nome: string;
  tipo: string;
  region_id: string;
  lat: number;
  lng: number;
}

export interface Leitura { estacao: number; hora: string; mm: number }

/** Tira o invólucro JSONP: `estacoes([...])` → `[...]`. */
export function semJsonp(texto: string): unknown {
  const t = texto.trim();
  const a = t.indexOf("("), b = t.lastIndexOf(")");
  return JSON.parse(a >= 0 && b > a ? t.slice(a + 1, b) : t);
}

/** Estações dos municípios monitorados, a partir da lista do CEMADEN. Só
 *  as que medem chuva (pluviométricas e hidrológicas, que também têm
 *  pluviômetro) e estão ativas (status 0). */
export function estacoesDosMunicipios(lista: unknown, municipios: Municipio[]): Estacao[] {
  const porIbge = new Map(municipios.map((m) => [Number(m.ibge), m.region_id]));
  // deno-lint-ignore no-explicit-any
  const blocos = Array.isArray(lista) ? lista as any[] : [];
  const saida: Estacao[] = [];
  for (const bloco of blocos) {
    for (const e of bloco?.estacao ?? []) {
      const region = porIbge.get(Number(e?.codibge));
      if (!region || e?.status !== 0) continue;
      if (!/pluviom|hidrol/i.test(String(e?.tipoestacao ?? ""))) continue;
      if (typeof e.latitude !== "number" || typeof e.longitude !== "number") continue;
      saida.push({
        id: Number(e.idestacao),
        codigo: String(e.codestacao),
        nome: String(e.nomeestacao),
        tipo: String(e.tipoestacao),
        region_id: region,
        lat: e.latitude,
        lng: e.longitude,
      });
    }
  }
  return saida.sort((p, q) => p.id - q.id);
}

/** Resposta do endpoint "horario" → leituras por hora (início da hora, UTC).
 *
 *  Formato: `datas` = dias em ordem ("17/11/2026"), `horarios` = rótulos
 *  "3h", "4h"… em sequência, e `acumulados` = um vetor por dia, alinhado a
 *  `horarios`, com valor só nas posições daquele dia. O dia avança quando o
 *  rótulo da hora volta para trás (23h → 0h). Hora sem valor (null) fica de
 *  fora: sem dado não é zero. */
export function leiturasDoHorario(estacao: number, json: unknown): Leitura[] {
  // deno-lint-ignore no-explicit-any
  const d = json as any;
  const horarios: string[] = d?.horarios ?? [];
  const datas: string[] = d?.datas ?? [];
  const acum: (number | null)[][] = d?.acumulados ?? [];
  const saida: Leitura[] = [];
  let dia = 0;
  for (let i = 0; i < horarios.length; i++) {
    const h = parseInt(horarios[i], 10);
    if (i > 0 && h < parseInt(horarios[i - 1], 10)) dia++;
    const data = datas[dia];
    if (data === undefined || Number.isNaN(h)) break;
    const v = acum[dia]?.[i];
    if (typeof v !== "number" || !Number.isFinite(v) || v < 0) continue;
    const [dd, mm, aaaa] = data.split("/").map(Number);
    const hora = new Date(Date.UTC(aaaa, mm - 1, dd, h));
    saida.push({ estacao, hora: hora.toISOString(), mm: Math.round(v * 10) / 10 });
  }
  return saida;
}

/** Executa tarefas com no máximo `n` ao mesmo tempo (educado com o CEMADEN). */
export async function emLotes<T, R>(itens: T[], n: number, f: (x: T) => Promise<R>): Promise<R[]> {
  const saida: R[] = new Array(itens.length);
  let prox = 0;
  const trabalhador = async () => {
    while (prox < itens.length) {
      const i = prox++;
      saida[i] = await f(itens[i]);
    }
  };
  await Promise.all(Array.from({ length: Math.min(n, itens.length) }, trabalhador));
  return saida;
}
