// Baixa o nível telemétrico (15 min) das estações da ANA usadas no estudo
// "Seca 2026" e grava, para cada estação e ano, um CSV diário em dados/.
//
// Fonte: serviço público de telemetria da ANA
//   http://telemetriaws1.ana.gov.br/ServiceANA.asmx/DadosHidrometeorologicos
//   ?codEstacao=<código>&dataInicio=DD/MM/AAAA&dataFim=DD/MM/AAAA
// Sem chave, sem dado pessoal. Uso:  node baixar_ana.mjs [AAAA-MM-DD fim de 2026]
//
// Diário: data como vem em DataHora (horário da ANA), mediana das leituras do
// dia (resiste a picos isolados do sensor), mais mínimo, máximo e número de
// leituras. Dia sem leitura fica com os campos vazios: nada é interpolado.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const aqui = path.dirname(fileURLToPath(import.meta.url));
const pastaDados = path.join(aqui, 'dados');
const pastaBruto = process.env.PASTA_BRUTO || null;   // opcional: guarda o XML bruto
fs.mkdirSync(pastaDados, { recursive: true });

export const ESTACOES = [
  { codigo: '14990000', nome: 'Manaus', rio: 'Rio Negro' },
  { codigo: '16030000', nome: 'Itacoatiara', rio: 'Rio Amazonas' },
  { codigo: '16350002', nome: 'Parintins', rio: 'Rio Amazonas' },
  { codigo: '15630000', nome: 'Humaitá', rio: 'Rio Madeira' },
  { codigo: '15960060', nome: 'Urucurituba (baixo Madeira)', rio: 'Rio Madeira' },
];
const fim2026 = process.argv[2] || new Date().toISOString().slice(0, 10);
const PERIODOS = [
  { ano: 2023, de: '2023-06-01', ate: '2023-11-30' },
  { ano: 2024, de: '2024-06-01', ate: '2024-11-30' },
  { ano: 2026, de: '2026-06-01', ate: fim2026 },
];

const br = (iso) => `${iso.slice(8, 10)}/${iso.slice(5, 7)}/${iso.slice(0, 4)}`;
const maisDias = (iso, n) => new Date(Date.parse(iso + 'T00:00:00Z') + n * 864e5).toISOString().slice(0, 10);
const dormir = (ms) => new Promise((r) => setTimeout(r, ms));

async function pedir(codigo, de, ate) {
  const url = `http://telemetriaws1.ana.gov.br/ServiceANA.asmx/DadosHidrometeorologicos?codEstacao=${codigo}&dataInicio=${br(de)}&dataFim=${br(ate)}`;
  for (let t = 1; t <= 4; t++) {
    try {
      const r = await fetch(url, { signal: AbortSignal.timeout(90000) });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      const xml = await r.text();
      if (!xml.includes('DocumentElement') && !xml.includes('DataTable')) throw new Error('resposta inesperada');
      if (pastaBruto) fs.writeFileSync(path.join(pastaBruto, `${codigo}_${de}_${ate}.xml`), xml);
      const leituras = [];
      for (const m of xml.matchAll(/<DataHora>([^<]+)<\/DataHora>[\s\S]*?<Nivel>([^<]*)<\/Nivel>/g)) {
        const v = m[2].trim();
        if (v !== '') leituras.push({ quando: m[1].trim(), nivel: Number(v) });
      }
      return leituras;
    } catch (e) {
      if (t === 4) throw new Error(`${codigo} ${de}..${ate}: ${e.message}`);
      await dormir(3000 * t);
    }
  }
}

function mediana(v) {
  const s = [...v].sort((a, b) => a - b);
  const k = s.length >> 1;
  return s.length % 2 ? s[k] : (s[k - 1] + s[k]) / 2;
}

const log = [];
for (const est of ESTACOES) {
  for (const p of PERIODOS) {
    const porDia = new Map();
    for (let d = p.de; d <= p.ate; d = maisDias(d, 10)) {
      const ate = maisDias(d, 9) < p.ate ? maisDias(d, 9) : p.ate;
      const ls = await pedir(est.codigo, d, ate);
      for (const l of ls) {
        const dia = l.quando.slice(0, 10);
        if (dia < p.de || dia > p.ate) continue;
        if (!porDia.has(dia)) porDia.set(dia, []);
        porDia.get(dia).push(l.nivel);
      }
      await dormir(400);
    }
    const linhas = ['data,nivel_cm_mediana,nivel_cm_min,nivel_cm_max,leituras'];
    let semDado = 0;
    for (let d = p.de; d <= p.ate; d = maisDias(d, 1)) {
      const v = porDia.get(d);
      if (!v || v.length === 0) { linhas.push(`${d},,,,0`); semDado++; continue; }
      linhas.push(`${d},${mediana(v)},${Math.min(...v)},${Math.max(...v)},${v.length}`);
    }
    const arq = `ana_${est.codigo}_${p.ano}.csv`;
    fs.writeFileSync(path.join(pastaDados, arq), linhas.join('\n') + '\n');
    const msg = `${arq}: ${linhas.length - 1} dias, ${semDado} sem leitura`;
    log.push(msg); console.log(msg);
  }
}
fs.writeFileSync(path.join(pastaDados, 'baixado_em.txt'),
  `Baixado em ${new Date().toISOString()} de telemetriaws1.ana.gov.br (DadosHidrometeorologicos).\n` + log.join('\n') + '\n');
