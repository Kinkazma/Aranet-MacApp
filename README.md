# Aranet4MacApp

> Application macOS (SwiftUI) pour connecter, lire et synchroniser un capteur **Aranet4** via **Bluetooth Low Energy**, afficher des **graphiques** (CO₂, température, humidité, pression), exporter/importer en **CSV**, gérer **plusieurs appareils** et planifier des **récupérations automatiques** au-delà de 4 mois.

<p align="center">
  <img src="Aranet4MacApp/Aranet4.icns](https://github.com/Kinkazma/Aranet-MacApp/blob/main/Aranet4.icns" alt="Icône Aranet4MacApp" width="96" />
</p>

---

## Table des matières

- [Aperçu](#aperçu)
- [Fonctionnalités](#fonctionnalités)
- [Captures d’écran](#captures-décran)
- [Prérequis](#prérequis)
- [Installation](#installation)
  - [Depuis les sources](#depuis-les-sources)
- [Utilisation](#utilisation)
  - [Connexion BLE et synchronisation](#connexion-ble-et-synchronisation)
  - [Affichage et filtres de période](#affichage-et-filtres-de-période)
  - [Export CSV](#export-csv)
  - [Import CSV](#import-csv)
  - [Gestion multi-appareils](#gestion-multi-appareils)
  - [Planification (Scheduler)](#planification-scheduler)
- [Architecture du code](#architecture-du-code)
  - [Schéma d’ensemble](#schéma-densemble)
  - [Fichiers principaux](#fichiers-principaux)
  - [Caractéristiques BLE Aranet4 (UUIDs)](#caractéristiques-ble-aranet4-uuids)
  - [Modèle de données](#modèle-de-données)
  - [Stockage et fichiers générés](#stockage-et-fichiers-générés)
- [Permissions et confidentialité](#permissions-et-confidentialité)
- [Dépannage](#dépannage)
- [Développement](#développement)
  - [Exigences outil / build](#exigences-outil--build)
  - [Qualité et style](#qualité-et-style)
  - [Roadmap](#roadmap)
- [Crédits et références](#crédits-et-références)
- [Licence](#licence)

---

## Aperçu

**Aranet4MacApp** est une application macOS native permettant de :

- Scanner et se connecter à un ou plusieurs capteurs **Aranet4** via **CoreBluetooth** ;
- Afficher les mesures courantes (CO₂, température, humidité, pression) et récupérer l’**historique** ;
- Visualiser les données avec des **graphiques** (Swift Charts) et des **filtres de période** ;
- **Exporter** et **importer** les données en **CSV** ;
- Gérer **plusieurs appareils** (ajout, renommage, suppression) avec des historiques distincts ;
- Planifier des **récupérations périodiques** des mesures.

---

## Fonctionnalités

- ✅ **Connexion BLE** à un ou plusieurs capteurs **Aranet4** (CoreBluetooth).
- ✅ **Lecture en temps réel** et **récupération d’historique** depuis l’appareil.
- ✅ **Interface SwiftUI** + **Charts** pour la visualisation.
- ✅ **Application barre de menus** (status bar) + **fenêtre** (Dock) optionnelle.
- ✅ **Gestion multi-appareils** : ajout, renommage, suppression, sélection et historiques indépendants.
- ✅ **Export CSV** (ISO 8601, UTC) et **import CSV** (fusion et validation).
- ✅ **Planification** de synchronisations récurrentes (Timer) avec exécution immédiate optionnelle.
- ✅ **Persistance** locale de l’historique agrégé + journaux CSV par synchronisation.
- ✅ Compatible **macOS 13+**.

---

## Captures d’écran

> *(Placeholders – à compléter dans le dépôt)*
>
> - `docs/screenshot-main-light.png` : Vue principale (thème clair)  
> - `docs/screenshot-main-dark.png` : Vue principale (thème sombre)  
> - `docs/screenshot-menubar.png` : Popover barre de menus  
> - `docs/screenshot-devices.png` : Gestion des appareils  
>
> Vous pouvez référencer les images comme suit :
>
> ```md
> ![Vue principale](docs/screenshot-main-light.png)
> ```

---

## Prérequis

- macOS **13.0** (Ventura) ou supérieur
- **Bluetooth** activé
- **Xcode 15+** (pour compiler depuis les sources)
- Un capteur **Aranet4** à proximité

---

## Installation

### Depuis les sources

1. **Cloner** le dépôt puis ouvrir le projet **Aranet4MacApp** dans Xcode.  
2. Vérifier la cible macOS 13+ et les capacités Bluetooth.  
3. **Build & Run** (⌘R). À la première exécution, macOS demandera l’autorisation **Bluetooth**.

> `Info.plist` doit contenir la clé d’usage Bluetooth :
>
> ```xml
> <key>NSBluetoothAlwaysUsageDescription</key>
> <string>This app uses Bluetooth to communicate with Aranet4 sensor.</string>
> ```

---

## Utilisation

### Connexion BLE et synchronisation

- L’application **scanne** et affiche les capteurs détectés.  
- Sélectionnez votre **Aranet4** pour vous connecter.  
- Une fois connecté, les **mesures courantes** et l’**historique** s’affichent et se mettent à jour.

L’app tient compte de :
- **Nombre total** de lectures disponibles,  
- **Intervalle** de mesure,  
- **Âge** de la dernière lecture,  
afin d’orchestrer proprement la récupération (éviter les lectures concurrentes, pagination si nécessaire).

### Affichage et filtres de période

La vue principale propose des **périodes prédéfinies** : *Aujourd’hui*, *7 jours*, *1 mois*, *Tout* et une **plage personnalisée**.  
Les graphiques (Framework **Charts**) s’adaptent au filtre actif.

### Export CSV

Menu **Exporter** → génère un fichier `CSV` trié par date avec l’en-tête :

```csv
date,co2,temperature,humidity,pressure
```

- Date au format **ISO 8601** (UTC, avec ou sans fractions de seconde).

### Import CSV

Menu **Importer** → sélection d’un fichier CSV **conforme** (en-tête identique).  
Les lignes sont **validées** et **fusionnées** dans l’historique de l’appareil sélectionné.

> En cas d’échec (format incorrect), corrigez l’en-tête/les colonnes et réessayez.

### Gestion multi-appareils

- **Ajouter** un nouvel Aranet4 repéré via scan.  
- **Renommer** un appareil (alias persistant).  
- **Supprimer** un appareil.  
- La **sélection courante** détermine l’historique utilisé pour l’affichage et l’import/export.

> Principe : **1 appareil = 1 historique** (pas de fusion implicite entre appareils).

### Planification (Scheduler)

- Définissez un **intervalle** (par ex. toutes les 5 minutes) pour déclencher une récupération automatique.
- Option : **heure spécifique quotidienne** (par ex. 07:00), avec ou sans **exécution immédiate**.

---

## Architecture du code

### Schéma d’ensemble

```
SwiftUI Views  ─┬─> ContentView.swift (UI, filtres, feuilles, export/import)
                │
Managers/Services│
  ├─ DeviceManager.swift     (scan, association, firmware, batterie, renommage)
  ├─ Aranet4Service.swift    (CoreBluetooth, caractéristiques Aranet4, décodage, historique)
  ├─ HistoryStorage.swift    (persistance locale + CSV agrégés/logs)
  ├─ CSVManager.swift        (export/import CSV)
  └─ Scheduler.swift         (Timer, planification, heure spécifique)
                │
macOS UI        └─ StatusBarManager.swift   (icône barre de menus, popover, fenêtre Dock)
```

### Fichiers principaux

- **`ContentView.swift`** — Vue principale : sélection de période, graphiques, feuilles (renommer/import/export), planification.  
- **`Aranet4Service.swift`** — Cœur BLE : découverte/connexion, **lecture des caractéristiques Aranet4**, **décodage big‑endian**, flux live et récupération d’historique, publication vers l’UI.  
- **`DeviceManager.swift`** — Scan, association, renommage, lecture **Firmware** (2A26) et **Batterie** (2A19), identification des services.  
- **`HistoryStorage.swift`** — Agrégation `MeasurementRecord`, index par **deviceID**, **CSV logs** par synchronisation + **CSV agrégé**.  
- **`CSVManager.swift`** — **Export** (ISO 8601 UTC) et **import** (validation/parse avec gestion d’erreurs).  
- **`Scheduler.swift`** — Planification (Timer), exécution **immédiate** optionnelle, respect du **MainActor**.  
- **`StatusBarManager.swift`** — Gestion **NSStatusItem**, **NSPopover** SwiftUI, fenêtre Dock (affichage/masquage).  

### Caractéristiques BLE Aranet4 (UUIDs)

> **Note** : Les UUIDs Aranet4 sont propriétaires ; voici les plus courants documentés publiquement pour la lecture des métriques et métadonnées :

- `f0cd2001-95da-4f4b-9ac8-aa55d312af0c` — **Nombre total** de lectures  
- `f0cd2002-95da-4f4b-9ac8-aa55d312af0c` — **Intervalle** de mesure  
- `f0cd2004-95da-4f4b-9ac8-aa55d312af0c` — **Âge** de la dernière lecture (secondes)  
- `f0cd3001-95da-4f4b-9ac8-aa55d312af0c` — **Mesure courante** (CO₂, T, RH, P) — **big‑endian**  
- Services GATT standard :
  - **Device Information (0x180A)** → `Firmware Revision (0x2A26)`  
  - **Battery Service (0x180F)** → `Battery Level (0x2A19)`

**Décodage big‑endian (exemple d’helpers)** :

```swift
private extension Data {
    @inline(__always) func beUInt16(at offset: Int) -> UInt16 {
        precondition(count >= offset + 2, "Data too short")
        return withUnsafeBytes { ptr in
            let raw = ptr.load(fromByteOffset: offset, as: UInt16.self)
            return UInt16(bigEndian: raw)
        }
    }
    @inline(__always) func beInt16(at offset: Int) -> Int16 {
        precondition(count >= offset + 2, "Data too short")
        return withUnsafeBytes { ptr in
            let raw = ptr.load(fromByteOffset: offset, as: Int16.self)
            return Int16(bigEndian: raw)
        }
    }
}
```

### Modèle de données

```swift
struct MeasurementRecord: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let co2: Int           // ppm (0…9999)
    let temperature: Double// °C
    let humidity: Double   // %
    let pressure: Double   // hPa
}
```

### Stockage et fichiers générés

- Répertoire applicatif : `~/Library/Application Support/Aranet4MacApp/`  
  - `CSVLogs/` : journaux CSV **par synchronisation**  
  - `history_full.csv` : **historique agrégé** de toutes les mesures  
- Exports : par défaut dans `~/Documents/` (ou chemin choisi via le panneau d’enregistrement).

---

## Permissions et confidentialité

- **Bluetooth** : accès requis pour découvrir/communiquer avec le capteur Aranet4.  
- **Données** : **stockées localement** uniquement. Aucun envoi réseau.  
- **CSV** : les exports contiennent des **horodatages** et des **mesures** ; manipulez-les conformément à vos politiques internes.

---

## Dépannage

- **Aucun appareil détecté**
  - Vérifiez que le **Bluetooth** macOS est **activé**.
  - Réveillez/réinitialisez l’**Aranet4** (veille, piles).
  - Réduisez les interférences (environnements BLE saturés).

- **Valeurs incohérentes (ex. T = −500 °C, RH > 100 %)**
  - Assurez-vous d’utiliser les helpers **big‑endian**.
  - Vérifiez la **version de firmware** de l’Aranet4 et la correspondance des **UUIDs**.
  - Écartez d’anciens CSV importés au format incorrect et testez d’abord avec la **mesure courante**.

- **Import CSV en erreur**
  - En‑tête exigée : `date,co2,temperature,humidity,pressure`
  - Dates en **ISO 8601** ; colonnes numériques **sans unités**.

- **Barre de menus / fenêtre**
  - Cliquez l’icône barre de menus pour le **popover**, ou utilisez l’action **Afficher la fenêtre** (Dock).
  - Voir `StatusBarManager.swift` pour la logique d’affichage.

---

## Développement

### Exigences outil / build

- **Xcode** 15+  
- **Swift** 5.9+  
- **macOS Deployment Target** : 13.0  
- **Frameworks** : `SwiftUI`, `Charts`, `CoreBluetooth`, `AppKit`, `UniformTypeIdentifiers`

> Pas de dépendances `CocoaPods` / `SwiftPM` externes non standard à ce stade (à adapter selon le projet).

### Qualité et style

- Utiliser `@MainActor` pour les services/managers exposant de l’état UI.  
- Éviter les **captures fortes** dans les closures BLE/Timer.  
- Séparer **scan/association** (DeviceManager) de **lecture & historique** (Aranet4Service).  
- Tester : appareils multiples, renommage, import/export, filtres, scheduling.

### Roadmap

- [ ] Pagination plus robuste de l’historique (blocs & reprise).  
- [ ] **Icône** et **captures** (AppIcon, README).  
- [ ] Préférences avancées (seuils CO₂ → couleurs, unités, thèmes).  
- [ ] Notifications (seuils CO₂ dépassés).  
- [ ] Extraction en **Swift Packages** (CSVManager/HistoryStorage).  
- [ ] CI (lint + build + notarisation si distribution).

---

## Crédits et références

- **Aranet4 Python** : reverse‑engineering, protocoles, exemples  
  - <https://github.com/Anrijs/Aranet4-Python>  
  - <https://github.com/Anrijs/Aranet4-Python/tree/master/aranet4>
- **Aranet4 ESP32** : références firmware/UUIDs, interprétation  
  - <https://github.com/Anrijs/Aranet4-ESP32>  
  - <https://github.com/Anrijs/Aranet4-ESP32/blob/main/src/Aranet4.cpp>  
  - <https://github.com/Anrijs/Aranet4-ESP32/blob/main/src/Aranet4.h>

> Merci à la communauté open‑source Aranet4 pour la documentation des UUIDs et les exemples de décodage **big‑endian**.

---

## Licence

Ce projet est publié sous licence **MIT**.  
Veuillez consulter le fichier [`LICENSE`](LICENSE) pour plus de détails.
