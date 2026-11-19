// Edge Function chuva-cemaden: lê a chuva hora a hora dos pluviômetros do
// CEMADEN nos municípios monitorados, grava e atualiza os avisos de chuva.
// Chamada a cada 5 min pelo pg_cron (chuva_cutucar). Sem conta externa: só
// SUPABASE_URL e a chave de serviço (variáveis padrão da Edge Function).
//
// Fonte: Rede Observacional do CEMADEN/MCTI (dados abertos do mapa
// interativo). Partes puras em nucleo.ts.
import {
  emLotes, estacoesDosMunicipios, type Leitura, leiturasDoHorario, type Municipio, semJsonp,
  URL_ESTACOES, urlHorario,
} from "./nucleo.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
/** A lista de estações muda pouco: renova uma vez por dia. */
const RENOVAR_ESTACOES_MS = 24 * 3600_000;
/** 24 h + a hora corrente: o acumulado de 24 h já sai certo na primeira
 *  coleta e uma queda do CEMADEN (ou nossa) se repõe sozinha na volta.
 *  ~500 bytes por estação. */
const HORAS = 24;
const PARALELO = 4;

async function rpc(nome: string, args: unknown = {}) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${nome}`, {
    method: "POST",
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(30_000),
  });
  const txt = await r.text();
  if (!r.ok) throw new Error(`${nome}: HTTP ${r.status} ${txt.slice(0, 200)}`);
  return txt ? JSON.parse(txt) : null;
}

async function obter(url: string, ms: number, tentativas = 2): Promise<string> {
  let erro: unknown;
  for (let i = 0; i < tentativas; i++) {
    try {
      const r = await fetch(url, { signal: AbortSignal.timeout(ms) });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return await r.text();
    } catch (e) {
      erro = e;
      if (i < tentativas - 1) await new Promise((ok) => setTimeout(ok, 1500));
    }
  }
  throw erro;
}

Deno.serve(async () => {
  const inicio = Date.now();
  try {
    const plano = await rpc("chuva_plano");
    let estacoes: number[] = plano.estacoes ?? [];
    let renovou = 0;

    const velha = !plano.estacoes_atualizadas_em ||
      Date.now() - Date.parse(plano.estacoes_atualizadas_em) > RENOVAR_ESTACOES_MS;
    if (estacoes.length === 0 || velha) {
      try {
        const lista = semJsonp(await obter(URL_ESTACOES, 25_000));
        const novas = estacoesDosMunicipios(lista, plano.municipios as Municipio[]);
        if (novas.length > 0) {
          renovou = await rpc("chuva_registrar_estacoes", { p: novas });
          estacoes = novas.map((e) => e.id);
        }
      } catch (e) {
        // Sem a lista nova, segue com a conhecida.
        if (estacoes.length === 0) throw e;
      }
    }

    const falhas: string[] = [];
    const lotes = await emLotes(estacoes, PARALELO, async (id): Promise<Leitura[]> => {
      try {
        return leiturasDoHorario(id, JSON.parse(await obter(urlHorario(id, HORAS), 12_000)));
      } catch (e) {
        falhas.push(`${id}: ${(e as Error).message ?? e}`);
        return [];
      }
    });
    const linhas = lotes.flat();
    const lidas = estacoes.length - falhas.length;

    const gravadas = await rpc("chuva_registrar_leituras", {
      p: {
        linhas,
        lidas,
        falhas: falhas.length,
        erro: falhas.length ? falhas.slice(0, 5).join("; ").slice(0, 500) : null,
      },
    });
    const avisos = await rpc("chuva_atualizar_avisos", {});

    return Response.json({
      estacoes: estacoes.length, renovou, lidas, falhas: falhas.length, leituras: gravadas,
      avisos_alterados: avisos, ms: Date.now() - inicio,
    });
  } catch (e) {
    return Response.json({ erro: String((e as Error).message ?? e) }, { status: 500 });
  }
});
