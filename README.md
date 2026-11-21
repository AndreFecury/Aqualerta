# AquaAlerta

<div align="center">

### Intelligent Flood Monitoring and Early Warning Platform

<br>

![Flutter](https://img.shields.io/badge/Flutter-02569B?style=for-the-badge\&logo=flutter\&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-0175C2?style=for-the-badge\&logo=dart\&logoColor=white)
![Supabase](https://img.shields.io/badge/Supabase-3FCF8E?style=for-the-badge\&logo=supabase\&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-336791?style=for-the-badge\&logo=postgresql\&logoColor=white)
![Firebase](https://img.shields.io/badge/Firebase-FCM-FFCA28?style=for-the-badge\&logo=firebase\&logoColor=black)
![OpenStreetMap](https://img.shields.io/badge/OpenStreetMap-7EBC6F?style=for-the-badge\&logo=openstreetmap\&logoColor=white)
![Architecture](https://img.shields.io/badge/Architecture-BLoC-blue?style=for-the-badge)
![Status](https://img.shields.io/badge/Status-In%20Development-yellow?style=for-the-badge)
![License](https://img.shields.io/github/license/SEU-USUARIO/Aqualerta?style=for-the-badge)

</div>

---

## Overview

AquaAlerta is a mobile platform focused on real-time flood monitoring, risk visualization, and early warning systems for vulnerable regions.

The project combines:

* hydrological monitoring;
* geospatial analysis;
* satellite-based flood detection;
* meteorological data integration;
* real-time notifications;
* scalable cloud infrastructure.

The platform was designed to support disaster prevention initiatives through accessible and data-driven environmental monitoring.

---

## Problem Statement

Flood events affect thousands of people annually across the Amazon region, generating infrastructure damage, displacement, communication disruption, and public safety risks.

Many affected areas lack accessible monitoring systems capable of delivering preventive alerts and real-time situational awareness.

AquaAlerta addresses this challenge by integrating geospatial intelligence, environmental monitoring, and real-time communication into a unified platform.

---

## Core Features

### Real-Time Monitoring

* Interactive flood monitoring map;
* Geospatial visualization of critical regions;
* Real-time hydrological and meteorological updates.

### Flood Detection

* SAR satellite imagery integration;
* Flood event identification and visualization;
* Region-based monitoring system.

### Alert Infrastructure

* Severity-based alert system;
* Push notification delivery;
* Historical alert tracking.

### User Management

* Secure authentication flow;
* Personalized monitored regions;
* Notification preference management.

### Cloud Architecture

* Realtime backend communication;
* Scalable PostgreSQL/PostGIS infrastructure;
* Event-driven data synchronization.

---

## System Architecture

```text id="m25vl0"
                 Sentinel-1 SAR Satellites
                             │
                             ▼
              Geospatial Processing Pipeline
                             │
                             ▼
                Supabase + PostgreSQL/PostGIS
                             │
         ┌───────────────────┼───────────────────┐
         ▼                                       ▼
    Realtime API                          Firebase FCM
         │                                       │
         ▼                                       ▼
                    Flutter Mobile Application
                             │
                             ▼
                      End Users & Alerts
```

---

## Technology Stack

### Mobile

* Flutter
* Dart

### Backend

* Supabase
* PostgreSQL
* PostGIS

### Geospatial Services

* Sentinel-1 SAR
* OpenStreetMap
* flutter_map

### Architecture

* BLoC Pattern
* Clean Architecture
* GoRouter

### Cloud Services

* Firebase Cloud Messaging
* Supabase Auth
* Supabase Realtime

---

## Project Structure

```bash id="8q8l2o"
lib/
├── app/
│   ├── router/
│   └── app.dart
│
├── core/
│   ├── constants/
│   ├── error/
│   ├── network/
│   └── services/
│
├── features/
│   ├── auth/
│   ├── map/
│   ├── alerts/
│   ├── regions/
│   └── settings/
│
├── shared/
│   ├── theme/
│   └── widgets/
│
└── main.dart
```

---

## Installation

### Requirements

| Tool             | Version   |
| ---------------- | --------- |
| Flutter SDK      | 3.22+     |
| Dart SDK         | 3.3+      |
| Android Studio   | Latest    |
| Supabase Account | Free Tier |

---

### Clone Repository

```bash id="qj6n4o"
git clone https://github.com/SEU-USUARIO/Aqualerta.git
cd Aqualerta
```

---

### Install Dependencies

```bash id="s4rf1w"
flutter pub get
```

---

### Configure Supabase

Create a project at:

```text id="h80ddf"
https://supabase.com
```

Execute:

```bash id="n72x7g"
supabase/schema.sql
```

Configure credentials:

```dart id="otd7gn"
await Supabase.initialize(
  url: 'YOUR_SUPABASE_URL',
  anonKey: 'YOUR_SUPABASE_ANON_KEY',
);
```

---

### Configure Firebase

1. Create a Firebase project;
2. Register Android application:

   * `br.com.aqualerta`
3. Download:

   * `google-services.json`

Move file to:

```text id="y01nq9"
android/app/google-services.json
```

---

## Running the Application

```bash id="42jlwm"
flutter run
```

Release build:

```bash id="25afm4"
flutter build apk --release
```

---

## Database Structure

| Table             | Description                      |
| ----------------- | -------------------------------- |
| monitored_regions | Geographic monitored regions     |
| flood_events      | Satellite-detected flood events  |
| alerts            | Issued alert records             |
| hydro_stations    | Hydrological monitoring stations |
| hydro_readings    | Real-time river level readings   |

---

## Roadmap

### Current Scope

* [x] Authentication system
* [x] Interactive map visualization
* [x] Realtime alerts
* [x] Supabase integration
* [x] Region monitoring

### Planned Features

* [x] Push notification infrastructure
* [x] Offline caching layer (regions on device)
* [ ] Machine learning risk prediction
* [ ] Administrative dashboard
* [x] CEMADEN integration (rain gauges)
* [x] Air quality per region (CAMS model via Open-Meteo, INPE fire hotspots, MMA IQAr)
* [ ] Android home widget
* [ ] Web platform

---

## Scalability

The platform architecture was designed to support:

* realtime environmental monitoring;
* multiple monitored regions;
* geospatial data processing;
* scalable cloud infrastructure;
* integration with governmental APIs;
* future nationwide deployment.

---

## Social Impact

AquaAlerta aims to improve access to critical environmental information in vulnerable areas through accessible monitoring technology and early warning mechanisms.

The project focuses on prevention, risk communication, and disaster response support.

---

## License

This project is licensed under the MIT License.
