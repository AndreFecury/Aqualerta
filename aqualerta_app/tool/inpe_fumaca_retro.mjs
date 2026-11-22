// Teste retroativo da qualidade do ar (Fase 1b): "dias de fumaça" pelos focos
// do INPE, fora do banco.
//
// Uso:  node tool/inpe_fumaca_retro.mjs <pasta-de-download> <saida.sql>
//
// - Baixa os arquivos MENSAIS da América do Sul (o INPE só guarda ~30 dias
//   de arquivos diários): julho (para os 2 dias antes de 1º/08) a outubro de 2026.
// - Usa só satélites de órbita polar (VIIRS/MODIS), como o ar_resumo do app;
//   o mesmo fogo visto por mais de um satélite conta 1 (célula de ~1 km).
// - Para cada região com sensor: focos a até 300 km e a até 500 km do ponto
//   do modelo, por dia LOCAL (UTC-4), somando o dia e os 2 anteriores.
// - Classes por terços dentro de ago-out, por região e raio.
// - Gera INSERTs para public.ar_fumaca_dias.
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { pipeline } from 'node:stream/promises';

const [, , pasta, saida] = process.argv;
if (!pasta || !saida) { console.error('uso: node tool/inpe_fumaca_retro.mjs <pasta> <saida.sql>'); process.exit(1); }

const REGIOES = [
  { id: 'e2c0c436-759c-4c30-8b06-27fc275b8b63', nome: 'Manaus', lat: -3.1383, lon: -60.0272, fuso: -4 },
  { id: 'd7d7dd6a-3441-4400-a0a9-d5018203686e', nome: 'Porto Velho', lat: -8.7483, lon: -63.9169, fuso: -4 },
];
const RAIOS = [300, 500];
const POLARES = new Set(['AQUA_M-T', 'AQUA_M-M', 'TERRA_M-T', 'TERRA_M-M', 'NPP-375', 'NOAA-20', 'NOAA-21']);
const MESES = ['202607', '202608', '202609', '202610'];
const BASE = 'https://dataserver-coids.inpe.br/queimadas/queimadas/focos/csv/mensal/America_Sul/';
const INICIO = '2026-08-01', FIM = '2026-10-31';

function km(a, b, c, d) {
  const r = Math.PI / 180, dLat = (c - a) * r, dLon = (d - b) * r;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a * r) * Math.cos(c * r) * Math.sin(dLon / 2) ** 2;
  return 6371 * 2 * Math.asin(Math.sqrt(h));
}

async function baixar(mes) {
  const arq = path.join(pasta, `focos_mensal_${mes}.csv`);
  if (fs.existsSync(arq) && fs.statSync(arq).size > 1e6) return arq;
  const r = await fetch(BASE + `focos_mensal_${mes}.csv`);
  if (!r.ok) throw new Error(`${mes}: HTTP ${r.status}`);
  await pipeline(r.body, fs.createWriteStream(arq));
  return arq;
}

fs.mkdirSync(pasta, { recursive: true });
// celulas[regiao][raio][dia] = Set de células únicas
const celulas = Object.fromEntries(REGIOES.map(g => [g.id, Object.fromEntries(RAIOS.map(k => [k, new Map()]))]));
const porSatelite = new Map();
let linhas = 0;

for (const mes of MESES) {
  const arq = await baixar(mes);
  const rl = readline.createInterface({ input: fs.createReadStream(arq, 'utf8'), crlfDelay: Infinity });
  let cab = null;
  for await (const l of rl) {
    if (!cab) { cab = l.split(','); continue; }
    const c = l.split(',');
    const sat = c[4];
    porSatelite.set(sat, (porSatelite.get(sat) ?? 0) + 1);
    if (!POLARES.has(sat)) continue;
    const lat = parseFloat(c[1]), lon = parseFloat(c[2]);
    const utc = new Date(c[3].replace(' ', 'T') + 'Z');
    if (Number.isNaN(lat) || Number.isNaN(lon) || Number.isNaN(utc.getTime())) continue;
    linhas++;
    for (const g of REGIOES) {
      const d = km(g.lat, g.lon, lat, lon);
      if (d > Math.max(...RAIOS)) continue;
      const dia = new Date(utc.getTime() + g.fuso * 3600e3).toISOString().slice(0, 10);
      const cel = `${lat.toFixed(2)},${lon.toFixed(2)}`;
      for (const k of RAIOS) {
        if (d > k) continue;
        const m = celulas[g.id][k];
        if (!m.has(dia)) m.set(dia, new Set());
        m.get(dia).add(cel);
      }
    }
  }
  console.error(`${mes}: lido`);
}

function dias(de, ate) {
  const out = []; for (let t = new Date(de + 'T00:00:00Z'); t <= new Date(ate + 'T00:00:00Z'); t = new Date(t.getTime() + 864e5)) out.push(t.toISOString().slice(0, 10));
  return out;
}
const menos = (dia, n) => new Date(new Date(dia + 'T00:00:00Z').getTime() - n * 864e5).toISOString().slice(0, 10);

const linhasSql = [];
const resumo = [];
for (const g of REGIOES) for (const k of RAIOS) {
  const m = celulas[g.id][k];
  const serie = dias(INICIO, FIM).map(dia => ({ dia, n: [0, 1, 2].reduce((s, i) => s + (m.get(menos(dia, i))?.size ?? 0), 0) }));
  const ord = serie.map(s => s.n).sort((a, b) => a - b);
  const t1 = ord[Math.floor(ord.length / 3)], t2 = ord[Math.floor((2 * ord.length) / 3)];
  for (const s of serie) {
    const classe = s.n < t1 ? 'poucos' : s.n < t2 ? 'medios' : 'muitos';
    linhasSql.push(`('${g.id}', '${s.dia}', ${k}, ${s.n}, '${classe}')`);
  }
  resumo.push(`${g.nome} ${k} km: mín ${ord[0]}, terços em ${t1} e ${t2}, máx ${ord.at(-1)}`);
}

const sql = `-- Gerado por tool/inpe_fumaca_retro.mjs em ${new Date().toISOString()}
-- Fonte: INPE, focos mensais América do Sul (${MESES.join(', ')}), satélites polares, células de 0,01°.
-- Focos somados no dia local e nos 2 anteriores; classes por terços de ${INICIO} a ${FIM}.
${resumo.map(r => '-- ' + r).join('\n')}
INSERT INTO public.ar_fumaca_dias (region_id, dia, raio_km, focos_3d, classe) VALUES
${linhasSql.join(',\n')}
ON CONFLICT (region_id, dia, raio_km) DO UPDATE SET focos_3d = excluded.focos_3d, classe = excluded.classe;
`;
fs.writeFileSync(saida, sql);
console.error('satélites no arquivo:', [...porSatelite.entries()].sort((a, b) => b[1] - a[1]).map(([s, n]) => `${s}=${n}`).join(' '));
console.error('focos polares lidos:', linhas);
console.error(resumo.join('\n'));
