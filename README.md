<div align="center">

# AquaAlerta

Sistema inteligente de monitoramento e alerta de enchentes.

![Java](https://img.shields.io/badge/Java-ED8B00?style=for-the-badge&logo=openjdk&logoColor=white)
![Android](https://img.shields.io/badge/Android-Studio-3DDC84?style=for-the-badge&logo=androidstudio&logoColor=white)
![Firebase](https://img.shields.io/badge/Firebase-FFCA28?style=for-the-badge&logo=firebase&logoColor=black)
![Status](https://img.shields.io/badge/Status-Em%20Desenvolvimento-yellow?style=for-the-badge)
![License](https://img.shields.io/github/license/SEU-USUARIO/Aqualerta?style=for-the-badge)

</div>
# 🌊 AQUALERTA — Monitoramento de Enchentes em Tempo Real

Plataforma mobile para detecção, alerta e visualização de enchentes na Amazônia, com dados de satélites SAR (Sentinel-1), estações hidrológicas da ANA e meteorologia em tempo real.

---

## 🚀 Setup em 5 passos

### Pré-requisitos

| Ferramenta | Versão mínima | Link |
|---|---|---|
| Flutter SDK | 3.22+ | https://flutter.dev/docs/get-started/install |
| Dart | 3.3+ | Incluso no Flutter |
| Android Studio / VS Code | Qualquer | |
| Conta Supabase | Free tier | https://supabase.com |

---

### 1. Clonar e instalar dependências

```bash
git clone <url-do-repositorio>
cd aqualerta_app
flutter pub get
```

---

### 2. Configurar Supabase

1. Acesse https://app.supabase.com e crie um projeto (grátis)
2. Vá em **SQL Editor** e execute todo o conteúdo de `supabase/schema.sql`
3. Copie a **URL** e a **anon key** do projeto (Settings → API)

---

### 3. Configurar variáveis de ambiente

Edite o arquivo `lib/main.dart` e substitua os valores:

```dart
await Supabase.initialize(
  url: 'https://SEU_PROJETO.supabase.co',   // ← sua URL
  anonKey: 'SUA_ANON_KEY',                  // ← sua anon key
);
```

Ou, para builds com `--dart-define`:

```bash
flutter run \
  --dart-define=SUPABASE_URL=https://SEU_PROJETO.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=SUA_ANON_KEY
```

---

### 4. Instalar fontes (obrigatório)

Baixe e coloque em `assets/fonts/`:

**Space Grotesk** → https://fonts.google.com/specimen/Space+Grotesk
- `SpaceGrotesk-Light.ttf`
- `SpaceGrotesk-Regular.ttf`
- `SpaceGrotesk-Medium.ttf`
- `SpaceGrotesk-SemiBold.ttf`
- `SpaceGrotesk-Bold.ttf`

**JetBrains Mono** → https://fonts.google.com/specimen/JetBrains+Mono
- `JetBrainsMono-Regular.ttf`

---

### 5. Configurar Firebase (push notifications)

1. Acesse https://console.firebase.google.com
2. Crie um projeto e adicione app Android com package: `br.com.aqualerta`
3. Baixe `google-services.json` e substitua o placeholder em:
   `android/app/google-services.json`

> ⚠️ Sem Firebase, o app funciona normalmente — apenas sem push notifications.

---

### Executar o app

```bash
# Emulador ou device físico
flutter run

# Build APK debug (para testar)
flutter build apk --debug

# Build APK release (para distribuição)
flutter build apk --release \
  --dart-define=SUPABASE_URL=https://SEU_PROJETO.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=SUA_ANON_KEY
```

O APK gerado fica em: `build/app/outputs/flutter-apk/app-release.apk`

---

## 📱 Funcionalidades

| Tela | Descrição |
|---|---|
| **Login/Cadastro** | Autenticação via Supabase Auth (email + senha) |
| **Mapa** | Mapa interativo com overlay de enchentes detectadas por satélite SAR |
| **Alertas** | Lista de alertas ativos e histórico, com filtros por severidade |
| **Regiões** | Gerenciar regiões monitoradas e configurar notificações |
| **Configurações** | Preferências de notificação, perfil e dados do sistema |

---

## 🏗️ Arquitetura

```
lib/
├── app/                    # Router (GoRouter) + App root + Login
├── core/
│   ├── constants/          # Cores, tipografia, espaçamento
│   ├── error/              # Classes de falha
│   └── network/            # Supabase service
├── features/
│   ├── map/                # Mapa + BLoC + FloodEvent entity
│   ├── alerts/             # Alertas + BLoC + Alert entity
│   ├── regions/            # Regiões + BLoC + MonitoredRegion entity
│   └── settings/           # Configurações + perfil
└── shared/
    ├── theme/              # AppTheme dark
    └── widgets/            # Componentes reutilizáveis
```

**Estado**: Flutter BLoC (`flutter_bloc`)
**Navegação**: GoRouter com auth redirect automático
**Backend**: Supabase (PostgreSQL + PostGIS + Auth + Realtime)
**Mapas**: flutter_map + OpenStreetMap (100% gratuito)

---

## 💾 Banco de dados (Supabase)

Tabelas criadas pelo `supabase/schema.sql`:

| Tabela | Descrição |
|---|---|
| `monitored_regions` | Regiões geográficas monitoradas (PostGIS) |
| `user_monitored_regions` | Assinaturas de usuários a regiões |
| `flood_events` | Eventos de enchente detectados por satélite |
| `alerts` | Alertas emitidos com severidade e status |
| `alert_deliveries` | Rastreamento de leitura de alertas |
| `hydro_stations` | Estações hidrológicas da ANA |
| `hydro_readings` | Leituras de nível do rio em tempo real |

---

## 💰 Custo operacional

| Serviço | Plano | Custo |
|---|---|---|
| Supabase | Free (500MB DB, 2GB Storage) | **R$ 0** |
| OpenStreetMap tiles | Free (sem limite razoável) | **R$ 0** |
| Firebase FCM | Free (ilimitado) | **R$ 0** |
| Copernicus CDSE | Free (imagens SAR) | **R$ 0** |
| **Total MVP** | | **R$ 0/mês** |

---

## 🗺️ Roadmap

- [x] Mapa interativo com overlay SAR
- [x] Sistema de alertas com severidade
- [x] Gerenciamento de regiões
- [x] Autenticação Supabase
- [ ] Push notifications via FCM
- [ ] Modo offline com cache SQLite
- [ ] Previsão de risco com ML (XGBoost)
- [ ] Dashboard web (Next.js)
- [ ] Integração CEMADEN
- [ ] Widget Android de nível do rio

---

## 📄 Licença

MIT — uso livre para fins educacionais e humanitários.
