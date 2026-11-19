// Edge Function satelite-ingest: água detectada por satélite (Copernicus EMS
// — GFM, Sentinel-1). Lógica em ingestao.ts; partes puras em nucleo.ts.
//
// Corpo opcional {"region_id": "<uuid>"}; sem ele, verifica todas as regiões.
// O banco pula regiões verificadas há menos de 50 min, então chamadas
// repetidas não custam nada. Sem conta externa: só SUPABASE_URL e a chave de
// serviço (variáveis padrão da Edge Function) para gravar.
import { processarRegiao, type Regiao } from "./ingestao.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

async function rpc(nome: string, args: unknown) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${nome}`, {
    method: "POST",
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(60_000),
  });
  const txt = await r.text();
  if (!r.ok) throw new Error(`${nome}: HTTP ${r.status} ${txt.slice(0, 200)}`);
  return txt ? JSON.parse(txt) : null;
}

Deno.serve(async (req) => {
  // deno-lint-ignore no-explicit-any
  let corpo: any = {};
  try { corpo = await req.json(); } catch { /* sem corpo */ }

  let regioes: Regiao[];
  try {
    regioes = await rpc("satelite_regioes_para_verificar", {
      p_region: corpo?.region_id ?? null,
    }) ?? [];
  } catch (e) {
    return Response.json({ erro: String((e as Error).message ?? e) }, { status: 500 });
  }

  const resultado = [];
  for (const r of regioes) {
    try {
      resultado.push(await processarRegiao(r, async (p) => (await rpc("satelite_registrar", { p })) === true));
    } catch (e) {
      resultado.push({ region: r.name, inserted: 0, skipped: 0, error: String((e as Error).message ?? e) });
    }
  }
  return Response.json(resultado);
});
