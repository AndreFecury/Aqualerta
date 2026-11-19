// Edge Function chuva-cemaden: lê a chuva hora a hora dos pluviômetros do
// CEMADEN nos municípios monitorados, grava e atualiza os avisos de chuva.
// Chamada a cada 5 min pelo pg_cron (chuva_cutucar). Sem conta externa: só
// SUPABASE_URL e a chave de serviço (variáveis padrão da Edge Function).
//
// Fonte: Rede Observacional do CEMADEN/MCTI (dados abertos do mapa
// interativo). Partes puras em nucleo.ts.
import {
  acumuladosDaLista, estacoesDosMunicipios, horaCheiaUtc, type Leitura, leiturasDoHorario,
  type Municipio, quemConsultar, semJsonp, URL_ESTACOES, urlHorario,
} from "./nucleo.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
/** A lista de estações muda pouco: renova uma vez por dia. */
const RENOVAR_ESTACOES_MS = 24 * 3600_000;
/** 24 h + a hora corrente: o acumulado de 24 h já sai certo na primeira
 *  coleta e uma queda do CEMADEN (ou nossa) se repõe sozinha na volta.
 *  ~500 bytes por estação. */
const HORAS = 24;
/** Estações com chuva consultadas hora a hora por coleta. */
const MAX_CONSULTAS = 8;
/** Pausa entre consultas (o CEMADEN bloqueia rajadas). */
const INTERVALO_MS = 1_000;
/** Prazo da coleta inteira. O pg_net desiste em 60 s; com o CEMADEN lento,
 *  melhor gravar o que chegou do que perder tudo. A estação que ficar de
 *  fora volta na próxima coleta (que repõe as últimas 24 h). */
const PRAZO_TOTAL_MS = 35_000;
/** Espera máxima por estação. */
const PRAZO_ESTACAO_MS = 8_000;

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

/** GET com prazo por tentativa, sem passar do horário-limite `ate`. */
async function obter(url: string, ms: number, ate: number, tentativas = 2): Promise<string> {
  let erro: unknown = new Error("sem tempo");
  for (let i = 0; i < tentativas; i++) {
    const resta = ate - Date.now();
    if (resta < 1500) break;
    try {
      const r = await fetch(url, { signal: AbortSignal.timeout(Math.min(ms, resta)) });
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
  const limite = inicio + PRAZO_TOTAL_MS;
  try {
    const plano = await rpc("chuva_plano");
    let estacoes: number[] = plano.estacoes ?? [];
    let renovou = 0;

    // 1 pedido: a lista do Brasil todo, com o acumulado de 24 h por estação.
    let lista: unknown = null;
    let erroLista: string | null = null;
    try {
      lista = semJsonp(await obter(URL_ESTACOES, 20_000, limite, 1));
    } catch (e) {
      erroLista = `lista: ${(e as Error).message ?? e}`;
    }

    const velha = !plano.estacoes_atualizadas_em ||
      Date.now() - Date.parse(plano.estacoes_atualizadas_em) > RENOVAR_ESTACOES_MS;
    if (lista && (estacoes.length === 0 || velha)) {
      const novas = estacoesDosMunicipios(lista, plano.municipios as Municipio[]);
      if (novas.length > 0) {
        renovou = await rpc("chuva_registrar_estacoes", { p: novas });
        estacoes = novas.map((e) => e.id);
      }
    }

    const linhas: Leitura[] = [];
    const falhas: string[] = erroLista ? [erroLista] : [];
    let lidas = 0;
    if (lista) {
      const acum = acumuladosDaLista(lista);
      const { consultar, secas } = quemConsultar(estacoes, acum, MAX_CONSULTAS);
      // Seca há 24 h: a hora corrente também é zero (e a leitura fica "fresca").
      const hora = horaCheiaUtc();
      for (const id of secas) linhas.push({ estacao: id, hora, mm: 0 });
      lidas += secas.length;
      // Com chuva: hora a hora, uma estação de cada vez, com intervalo.
      for (const id of consultar) {
        if (limite - Date.now() < PRAZO_ESTACAO_MS) {
          falhas.push(`${id}: sem tempo`);
          continue;
        }
        try {
          linhas.push(...leiturasDoHorario(id,
            JSON.parse(await obter(urlHorario(id, HORAS), PRAZO_ESTACAO_MS, limite, 1))));
          lidas++;
        } catch (e) {
          falhas.push(`${id}: ${(e as Error).message ?? e}`);
        }
        await new Promise((ok) => setTimeout(ok, INTERVALO_MS));
      }
    }

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
      avisos_alterados: avisos, ms: Date.now() - inicio, erro: falhas[0] ?? null,
    });
  } catch (e) {
    return Response.json({ erro: String((e as Error).message ?? e) }, { status: 500 });
  }
});
