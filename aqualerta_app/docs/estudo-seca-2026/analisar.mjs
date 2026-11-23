// Análise do estudo "Seca 2026": lê dados/ana_<código>_<ano>.csv (de
// baixar_ana.mjs) e grava em dados/ os cruzamentos, mínimos, a simulação da
// regra pré-registrada (preregistro.md) e, em graficos/, um SVG por estação.
// Uso: node analisar.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const aqui = path.dirname(fileURLToPath(import.meta.url));
const D = path.join(aqui, 'dados');
const G = path.join(aqui, 'graficos');
fs.mkdirSync(G, { recursive: true });

const ESTACOES = [
  { codigo: '14990000', nome: 'Manaus', rio: 'Rio Negro', limiares: [2000, 1900, 1770] },
  { codigo: '16030000', nome: 'Itacoatiara', rio: 'Rio Amazonas', limiares: [] },
  { codigo: '16350002', nome: 'Parintins', rio: 'Rio Amazonas', limiares: [] },
  { codigo: '15630000', nome: 'Humaitá', rio: 'Rio Madeira', limiares: [] },
  { codigo: '15960060', nome: 'Urucurituba (baixo Madeira)', rio: 'Rio Madeira', limiares: [] },
];
const ANOS = [2023, 2024, 2026];
const LIMIAR_REGRA = 1770;
const NS = [7, 10, 15];

function ler(codigo, ano) {
  const arq = path.join(D, `ana_${codigo}_${ano}.csv`);
  if (!fs.existsSync(arq)) return null;
  const [, ...ls] = fs.readFileSync(arq, 'utf8').trim().split(/\r?\n/);
  return ls.map((l) => {
    const [data, med, , , n] = l.split(',');
    return { data, nivel: med === '' ? null : Number(med), leituras: Number(n) };
  });
}
const csv = (nome, cab, linhas) =>
  fs.writeFileSync(path.join(D, nome), [cab, ...linhas.map((l) => l.join(','))].join('\n') + '\n');
const dias = (a, b) => Math.round((Date.parse(b) - Date.parse(a)) / 864e5);

// Primeiro dia abaixo do limiar depois de um dia >= limiar (preregistro.md).
function cruzamento(serie, lim) {
  let antAcima = false;
  for (const d of serie) {
    if (d.nivel == null) continue;
    if (d.nivel < lim && antAcima) return d.data;
    antAcima = d.nivel >= lim;
  }
  return null;
}

// ---- Cobertura e mínimos ----
const cobertura = [], minimos = [], cruz = [];
const series = {};
for (const e of ESTACOES) {
  for (const ano of ANOS) {
    const s = ler(e.codigo, ano);
    if (!s) continue;
    series[`${e.codigo}_${ano}`] = s;
    const com = s.filter((d) => d.nivel != null);
    const incompletos = com.filter((d) => d.leituras < 48).length;
    // Buracos: sequências de dias sem valor.
    const buracos = []; let ini = null;
    s.forEach((d, i) => {
      if (d.nivel == null && ini == null) ini = d.data;
      if ((d.nivel != null || i === s.length - 1) && ini != null) {
        const fimB = d.nivel == null ? d.data : s[i - 1].data;
        buracos.push(`${ini}..${fimB}`); ini = null;
      }
    });
    cobertura.push([e.codigo, `"${e.nome}"`, ano, s[0].data, s[s.length - 1].data, s.length, com.length,
                    s.length - com.length, incompletos, `"${buracos.join(' ')}"`]);
    if (com.length) {
      const m = com.reduce((a, b) => (b.nivel < a.nivel ? b : a));
      minimos.push([e.codigo, `"${e.nome}"`, ano, m.data, m.nivel, com[com.length - 1].data, com[com.length - 1].nivel]);
    }
    for (const lim of e.limiares) cruz.push([e.codigo, `"${e.nome}"`, ano, lim, cruzamento(s, lim) ?? '']);
  }
}
csv('cobertura.csv', 'codigo,estacao,ano,de,ate,dias,dias_com_valor,dias_sem_valor,dias_com_menos_de_48_leituras,buracos', cobertura);
csv('minimos.csv', 'codigo,estacao,ano,data_minimo,minimo_cm,ultimo_dia_com_valor,nivel_ultimo_dia_cm', minimos);
csv('cruzamentos_manaus.csv', 'codigo,estacao,ano,limiar_cm,primeiro_dia_abaixo', cruz);

// ---- Simulação da regra pré-registrada (Manaus, 1770 cm) ----
function simular(serie, N) {
  const real = cruzamento(serie, LIMIAR_REGRA);
  const disparos = [];
  let ligado = false, subidas = 0, anterior = null;
  for (let i = 0; i < serie.length; i++) {
    const t = serie[i];
    if (t.nivel != null && anterior != null) subidas = t.nivel > anterior ? subidas + 1 : 0;
    if (t.nivel != null) anterior = t.nivel;
    if (ligado && subidas >= 5) ligado = false;
    if (real && t.data >= real) break;               // depois do cruzamento não há o que avisar
    if (t.nivel == null) continue;
    const jan = serie.slice(Math.max(0, i - 13), i + 1).filter((d) => d.nivel != null);
    if (jan.length < 10) continue;
    const xs = jan.map((d) => dias(serie[0].data, d.data)), ys = jan.map((d) => d.nivel);
    const mx = xs.reduce((a, b) => a + b) / xs.length, my = ys.reduce((a, b) => a + b) / ys.length;
    let sxy = 0, sxx = 0;
    xs.forEach((x, k) => { sxy += (x - mx) * (ys[k] - my); sxx += (x - mx) ** 2; });
    const incl = sxy / sxx;                            // cm por dia
    const xt = dias(serie[0].data, t.data);
    const ajustado = my + incl * (xt - mx);
    if (!(incl < 0) || t.nivel < LIMIAR_REGRA) continue;
    const emDias = (ajustado - LIMIAR_REGRA) / -incl;
    if (emDias <= N && !ligado) {
      ligado = true;
      const prazo = new Date(Date.parse(t.data) + (N + 5) * 864e5).toISOString().slice(0, 10);
      const falso = !(real && real <= prazo);
      disparos.push({ data: t.data, nivel: t.nivel, incl: Math.round(incl * 10) / 10, emDias: Math.round(emDias * 10) / 10, falso });
    }
  }
  return { real, disparos };
}
const sim = [], disp = [];
for (const ano of ANOS) {
  const s = series[`14990000_${ano}`];
  if (!s) continue;
  for (const N of NS) {
    const { real, disparos } = simular(s, N);
    const primeiro = disparos[0];
    const bons = disparos.filter((d) => !d.falso);
    // Antecedência como no pré-registro: do PRIMEIRO disparo ao cruzamento real.
    sim.push([ano, N, real ?? '', primeiro?.data ?? '', primeiro && real ? dias(primeiro.data, real) : '',
              primeiro ? (primeiro.falso ? 'falso' : 'certo') : '',
              disparos.filter((d) => d.falso).length, disparos.length]);
    for (const d of disparos) disp.push([ano, N, d.data, d.nivel, d.incl, d.emDias, d.falso ? 'falso' : 'certo']);
  }
}
csv('simulacao_regra.csv', 'ano,N,cruzamento_real_1770,primeiro_disparo,antecedencia_dias,primeiro_disparo_resultado,alarmes_falsos,disparos', sim);
csv('disparos_regra.csv', 'ano,N,dia_disparo,nivel_cm,inclinacao_cm_dia,projecao_dias,resultado', disp);

// ---- Gráficos (SVG, sem dependências) ----
const CORES = { 2023: '#8a5a00', 2024: '#6b4fbb', 2026: '#0b5cad' };
const TRACO = { 2023: '6 4', 2024: '2 3', 2026: '' };
function grafico(e) {
  const W = 440, H = 330, m = { e: 58, d: 12, c: 34, b: 46 };
  const todas = ANOS.map((a) => series[`${e.codigo}_${a}`]).filter(Boolean);
  const vals = todas.flat().filter((d) => d.nivel != null).map((d) => d.nivel);
  if (!vals.length) return;
  let lo = Math.min(...vals, ...e.limiares.filter((l) => l === 1770)), hi = Math.max(...vals);
  const pad = (hi - lo) * 0.06; lo -= pad; hi += pad;
  const x = (doy) => m.e + (doy / 182) * (W - m.e - m.d);
  const y = (v) => m.c + (1 - (v - lo) / (hi - lo)) * (H - m.c - m.b);
  const doy = (iso) => dias(`${iso.slice(0, 4)}-06-01`, iso);
  const fmt = (cm) => (cm / 100).toFixed(1).replace('.', ',');
  let s = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" role="img" aria-labelledby="t d" font-family="system-ui,sans-serif" font-size="15">`;
  s += `<title id="t">${e.nome} (${e.rio}): nível diário, junho a novembro de 2023, 2024 e 2026</title>`;
  s += `<desc id="d">Mediana diária da telemetria ANA ${e.codigo}, em metros. Dias sem leitura ficam em branco.</desc>`;
  s += `<rect width="${W}" height="${H}" fill="#fff"/>`;
  const passo = (hi - lo) > 1500 ? 500 : (hi - lo) > 800 ? 200 : 100;
  for (let v = Math.ceil(lo / passo) * passo; v <= hi; v += passo) {
    s += `<line x1="${m.e}" x2="${W - m.d}" y1="${y(v)}" y2="${y(v)}" stroke="#e3e7eb"/>`;
    s += `<text x="${m.e - 6}" y="${y(v) + 4}" text-anchor="end" fill="#57606a">${fmt(v)} m</text>`;
  }
  ['jun', 'jul', 'ago', 'set', 'out', 'nov'].forEach((mes, k) => {
    const d0 = dias('2026-06-01', `2026-${String(6 + k).padStart(2, '0')}-01`);
    s += `<line x1="${x(d0)}" x2="${x(d0)}" y1="${m.c}" y2="${H - m.b}" stroke="#eef1f4"/>`;
    s += `<text x="${x(d0) + 4}" y="${H - m.b + 18}" fill="#57606a">${mes}</text>`;
  });
  if (e.limiares.includes(1770)) {
    s += `<line x1="${m.e}" x2="${W - m.d}" y1="${y(1770)}" y2="${y(1770)}" stroke="#c62828" stroke-width="1.5" stroke-dasharray="5 4"/>`;
    s += `<text x="${W - m.d - 4}" y="${y(1770) - 6}" text-anchor="end" fill="#c62828">17,7 m</text>`;
  }
  ANOS.forEach((a, k) => {
    const ser = series[`${e.codigo}_${a}`]; if (!ser) return;
    let d = '', caneta = false;
    for (const p of ser) {
      if (p.nivel == null) { caneta = false; continue; }
      d += `${caneta ? 'L' : 'M'}${x(doy(p.data)).toFixed(1)},${y(p.nivel).toFixed(1)}`; caneta = true;
    }
    s += `<path d="${d}" fill="none" stroke="${CORES[a]}" stroke-width="${a === 2026 ? 2.6 : 1.8}" stroke-dasharray="${TRACO[a]}"/>`;
    s += `<line x1="${m.e + 4 + k * 100}" x2="${m.e + 30 + k * 100}" y1="16" y2="16" stroke="${CORES[a]}" stroke-width="2.4" stroke-dasharray="${TRACO[a]}"/>`;
    s += `<text x="${m.e + 36 + k * 100}" y="21" fill="#1b1f24">${a}</text>`;
  });
  s += `<text x="${m.e}" y="${H - 8}" fill="#57606a" font-size="13">Fonte: ANA ${e.codigo}, mediana diária</text>`;
  s += '</svg>\n';
  fs.writeFileSync(path.join(G, `${e.codigo}.svg`), s);
}
// Urucurituba fica sem gráfico: sensor travado em 2227 cm por 55 dias (21/07 a 31/10/2026).
ESTACOES.filter((e) => e.codigo !== '15960060').forEach(grafico);
console.log('cobertura'); console.table(cobertura.map((c) => c.slice(0, 9)));
console.log('mínimos'); console.table(minimos);
console.log('cruzamentos'); console.table(cruz);
console.log('simulação'); console.table(sim);

// ---- Mesmo dia do ano (último dia baixado de 2026) nos três anos ----
{
  const ult = series['14990000_2026']?.at(-1)?.data;
  if (ult) {
    const md = ult.slice(5);
    const linhas = [];
    for (const e of ESTACOES) for (const ano of ANOS) {
      const p = series[`${e.codigo}_${ano}`]?.find((d) => d.data === `${ano}-${md}`);
      linhas.push([e.codigo, `"${e.nome}"`, ano, `${ano}-${md}`, p?.nivel ?? '']);
    }
    csv('mesmo_dia.csv', 'codigo,estacao,ano,data,nivel_cm', linhas);
  }
}
