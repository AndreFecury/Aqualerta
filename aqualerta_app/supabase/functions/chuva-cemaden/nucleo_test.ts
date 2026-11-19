// deno test --allow-read supabase/functions/chuva-cemaden/
//
// Fixtures reais do CEMADEN (fixtures/), baixadas em 19/11/2026 ~04h UTC:
// - estacoes_recorte.js: lista JSONP de 311_24.json cortada para os 6
//   municípios monitorados + 2 estações de outros estados (uma delas com o
//   valor absurdo de 3600 mm que o CEMADEN publicou).
// - horario_manaus_6740.json / horario_mindu_8747.json: 48 h hora a hora.
import { assert, assertEquals } from "jsr:@std/assert@1.0.8";
import { emLotes, estacoesDosMunicipios, leiturasDoHorario, semJsonp } from "./nucleo.ts";

const dir = new URL("./fixtures/", import.meta.url);
const ler = (n: string) => Deno.readTextFileSync(new URL(n, dir));

const MUNICIPIOS = [
  { region_id: "manaus", ibge: 1302603 },
  { region_id: "manacapuru", ibge: 1302504 },
  { region_id: "itacoatiara", ibge: 1301902 },
  { region_id: "parintins", ibge: 1303403 },
  { region_id: "porto-velho", ibge: 1100205 },
  { region_id: "rio-branco", ibge: 1200401 },
];

Deno.test("lista do CEMADEN: estações dos municípios monitorados", () => {
  const lista = semJsonp(ler("estacoes_recorte.js"));
  const es = estacoesDosMunicipios(lista, MUNICIPIOS);
  const manaus = es.filter((e) => e.region_id === "manaus");
  assertEquals(manaus.length, 14); // 12 pluviométricas + 2 hidrológicas (Mindu e Quarenta)
  assert(manaus.some((e) => e.nome === "Igarape do Mindu" && /Hidrol/.test(e.tipo)));
  assertEquals(es.filter((e) => e.region_id === "rio-branco").length, 5);
  // Estações de fora (BA, MG) não entram.
  assert(es.every((e) => MUNICIPIOS.some((m) => m.region_id === e.region_id)));
  assert(!es.some((e) => e.id === 8327 || e.id === 9327));
  // Coordenadas de Manaus.
  for (const e of manaus) assert(e.lat < -2.9 && e.lat > -3.2 && e.lng < -59.8 && e.lng > -60.1);
});

Deno.test("lista: município sem estação e resposta vazia não quebram", () => {
  assertEquals(estacoesDosMunicipios(semJsonp("estacoes([])"), MUNICIPIOS), []);
  assertEquals(estacoesDosMunicipios(null, MUNICIPIOS), []);
  assertEquals(estacoesDosMunicipios(semJsonp(ler("estacoes_recorte.js")), []), []);
});

Deno.test("horário: 48 h reais viram leituras por hora em UTC", () => {
  const ls = leiturasDoHorario(6740, JSON.parse(ler("horario_manaus_6740.json")));
  assertEquals(ls.length, 49); // 48 h cheias + a corrente
  assertEquals(ls[0].hora, "2026-11-17T03:00:00.000Z");
  assertEquals(ls.at(-1)!.hora, "2026-11-19T03:00:00.000Z");
  // Horas consecutivas, sem buraco nem repetição na virada do dia.
  for (let i = 1; i < ls.length; i++) {
    assertEquals(Date.parse(ls[i].hora) - Date.parse(ls[i - 1].hora), 3600_000);
  }
  assert(ls.every((l) => l.estacao === 6740 && l.mm >= 0));
});

Deno.test("horário: valores nulos ficam de fora (sem dado não é zero)", () => {
  const json = {
    horarios: ["22h", "23h", "0h", "1h"],
    datas: ["18/11/2026", "19/11/2026"],
    acumulados: [[12.34, null, null, null], [null, null, 41, null]],
  };
  assertEquals(leiturasDoHorario(1, json), [
    { estacao: 1, hora: "2026-11-18T22:00:00.000Z", mm: 12.3 },
    { estacao: 1, hora: "2026-11-19T00:00:00.000Z", mm: 41 },
  ]);
  assertEquals(leiturasDoHorario(1, {}), []);
  assertEquals(leiturasDoHorario(1, { horarios: ["1h"], datas: [], acumulados: [] }), []);
});

Deno.test("emLotes: respeita o limite de chamadas simultâneas e a ordem", async () => {
  let agora = 0, pico = 0;
  const r = await emLotes([1, 2, 3, 4, 5, 6, 7], 3, async (x) => {
    agora++; pico = Math.max(pico, agora);
    await new Promise((ok) => setTimeout(ok, 5));
    agora--;
    return x * 10;
  });
  assertEquals(r, [10, 20, 30, 40, 50, 60, 70]);
  assert(pico <= 3);
});
