// AquaAlerta — envia os avisos de alerta pelo Firebase Cloud Messaging (HTTP v1).
//
// Quem chama (gatilho em public.alerts ou o cron) não manda dados: a função
// só processa public.push_fila. Chamar de novo não reenvia nada.
//
// Segredo necessário (Supabase > Edge Functions > Secrets):
//   FCM_SERVICE_ACCOUNT = o JSON inteiro da conta de serviço do Firebase.
// SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já vêm prontos no ambiente.
// Publicar com "Verify JWT" desligado (o gatilho chama sem chave).

type Destino = {
  fila_id: number;
  alert_id: string;
  user_id: string | null;
  token: string | null;
  titulo: string | null;
  corpo: string | null;
  severity: string;
};

type Envio = {
  fila_id: number;
  alert_id: string;
  user_id: string | null;
  token: string | null;
  ok: boolean;
  invalido?: boolean;
  erro?: string;
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

async function rpc<T>(nome: string, args: unknown): Promise<T> {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${nome}`, {
    method: "POST",
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(args),
  });
  if (!r.ok) throw new Error(`rpc ${nome}: ${r.status} ${await r.text()}`);
  return await r.json() as T;
}

// ---------- token de acesso do Google (OAuth 2.0 com JWT da conta de serviço)

function b64url(dados: ArrayBuffer | Uint8Array | string): string {
  const bytes = typeof dados === "string"
    ? new TextEncoder().encode(dados)
    : new Uint8Array(dados);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function tokenGoogle(conta: {
  client_email: string;
  private_key: string;
}): Promise<string> {
  const agora = Math.floor(Date.now() / 1000);
  const cabecalho = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const corpo = b64url(JSON.stringify({
    iss: conta.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: agora,
    exp: agora + 3600,
  }));
  const pem = conta.private_key
    .replace(/-----(BEGIN|END) PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const chave = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const assinatura = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    chave,
    new TextEncoder().encode(`${cabecalho}.${corpo}`),
  );
  const jwt = `${cabecalho}.${corpo}.${b64url(assinatura)}`;

  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!r.ok) throw new Error(`oauth: ${r.status} ${await r.text()}`);
  return (await r.json()).access_token as string;
}

// ---------- envio de uma mensagem

async function enviar(
  projeto: string,
  acesso: string,
  d: Destino,
): Promise<Envio> {
  const base = { fila_id: d.fila_id, alert_id: d.alert_id, user_id: d.user_id, token: d.token };
  const alta = d.severity === "HIGH" || d.severity === "CRITICAL";
  const mensagem = {
    message: {
      token: d.token,
      notification: { title: d.titulo, body: d.corpo },
      data: { alert_id: d.alert_id, severity: d.severity },
      android: {
        priority: "HIGH",
        ttl: "21600s", // 6 h: depois disso o aviso já está velho
        notification: {
          channel_id: "aqualerta_alerts", // o mesmo canal criado pelo app
          icon: "ic_notification",
          tag: d.alert_id, // a mudança de severidade substitui o aviso anterior
          default_sound: alta,
          notification_priority: alta ? "PRIORITY_MAX" : "PRIORITY_HIGH",
        },
      },
    },
  };
  const r = await fetch(
    `https://fcm.googleapis.com/v1/projects/${projeto}/messages:send`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${acesso}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(mensagem),
    },
  );
  if (r.ok) return { ...base, ok: true };
  let codigo = `HTTP_${r.status}`;
  try {
    const e = await r.json();
    const fcm = (e?.error?.details ?? []).find((x: { errorCode?: string }) => x.errorCode);
    codigo = fcm?.errorCode ?? e?.error?.status ?? codigo;
  } catch { /* corpo não é JSON */ }
  // Token que não existe mais (app desinstalado, dados apagados) ou malformado.
  const invalido = codigo === "UNREGISTERED" ||
    (r.status === 400 && codigo === "INVALID_ARGUMENT");
  return { ...base, ok: false, invalido, erro: codigo };
}

// ---------- entrada

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("use POST", { status: 405 });
  try {
    const bruto = Deno.env.get("FCM_SERVICE_ACCOUNT");
    if (!bruto) throw new Error("segredo FCM_SERVICE_ACCOUNT não configurado");
    const conta = JSON.parse(bruto);

    let acesso: string | null = null;
    let total = 0, enviados = 0;
    // Até 5 rodadas de 20 itens por chamada.
    for (let rodada = 0; rodada < 5; rodada++) {
      const destinos = await rpc<Destino[]>("push_reivindicar", { limite: 20 });
      if (destinos.length === 0) break;
      const comToken = destinos.filter((d) => d.token);
      if (comToken.length > 0 && acesso === null) acesso = await tokenGoogle(conta);

      const envios: Envio[] = [];
      // Itens sem destinatário: fecham com zero envios.
      for (const d of destinos.filter((d) => !d.token)) {
        envios.push({ fila_id: d.fila_id, alert_id: d.alert_id, user_id: null, token: null, ok: false });
      }
      // Envia em lotes de 10 em paralelo.
      for (let i = 0; i < comToken.length; i += 10) {
        const lote = comToken.slice(i, i + 10);
        const res = await Promise.all(lote.map((d) =>
          enviar(conta.project_id, acesso!, d).catch((e) => ({
            fila_id: d.fila_id, alert_id: d.alert_id, user_id: d.user_id, token: d.token,
            ok: false, erro: String(e).slice(0, 120),
          }))
        ));
        envios.push(...res);
      }
      await rpc<number>("push_concluir", { envios });
      total += comToken.length;
      enviados += envios.filter((e) => e.ok).length;
    }
    return Response.json({ destinatarios: total, enviados });
  } catch (e) {
    console.error("push-alertas:", e);
    return Response.json({ erro: "falha ao processar a fila" }, { status: 500 });
  }
});
