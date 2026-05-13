# Analyse du `apache-superset-extensions-cli` — Future Architecture Extensions

> Analyse réalisée en mai 2026 dans le cadre du POC `superset-6.0-dynamic-plugin`.

## 1. Découverte

Le package officiel `apache-superset-extensions-cli` v0.1.0 est disponible sur PyPI et fonctionnel :

```powershell
pip install apache-superset-extensions-cli  # installe aussi apache-superset-core v0.1.0
superset-extensions --help
# Commandes: init, build, bundle, validate, dev
```

Ce CLI représente la **direction officielle** d'Apache Superset pour l'extensibilité — une architecture de type "VS Code extensions" basée sur **Webpack Module Federation**.

## 2. Comparaison : notre approche vs Extensions CLI

| Aspect | Notre POC (`DYNAMIC_PLUGINS`) | Extensions CLI (Module Federation) |
|---|---|---|
| **Statut** | ✅ Fonctionne aujourd'hui (6.0.1) | ⏳ CLI prêt, runtime Superset absent |
| **Mécanisme de chargement** | `import()` natif + ESM bundle | `ModuleFederationPlugin` + `remoteEntry.js` |
| **Externals** | `window['__superset__/react']` etc. | `window.superset` (clé unique) |
| **SDK** | `@superset-ui/core` (ChartPlugin) | `@apache-superset/core` (nouveau SDK) |
| **Registration** | `.configure({ key }).register()` | `views.registerView()` |
| **API endpoint** | `/dynamic-plugins/api/read` (Blueprint workaround) | `/api/v1/extensions/{publisher}/{name}/` |
| **Scope** | Charts uniquement | Charts, SQL Lab panels, Homepage, etc. |
| **Format de sortie** | `dist/index.js` (ESM single file) | `dist/remoteEntry.[hash].js` + chunks |
| **Metadata** | `package.json` (name) | `extension.json` (publisher, name, permissions) |
| **Namespacing** | Nom plat (`my-plugin`) | `{publisher}.{name}` (ex: `cosmotech.brewery`) |

## 3. Ce que le CLI génère

```powershell
superset-extensions init --publisher cosmotech --name brewery-test --display-name "Brewery Test" --frontend --no-backend
```

### Structure générée

```
brewery-test/
├── extension.json              # Metadata (publisher, name, version, permissions)
├── .gitignore
└── frontend/
    ├── package.json            # peerDependencies: @apache-superset/core, react
    ├── tsconfig.json
    ├── webpack.config.js       # ModuleFederationPlugin
    └── src/
        └── index.tsx           # views.registerView(...)
```

### `extension.json`

```json
{
  "publisher": "cosmotech",
  "name": "brewery-test",
  "displayName": "Brewery Test",
  "version": "0.1.0",
  "license": "Apache-2.0",
  "permissions": []
}
```

### `webpack.config.js` (template)

```javascript
const { ModuleFederationPlugin } = require("webpack").container;

module.exports = (env, argv) => ({
  output: {
    publicPath: `/api/v1/extensions/${extensionConfig.publisher}/${extensionConfig.name}/`,
  },
  externalsType: "window",
  externals: {
    "@apache-superset/core": "superset",   // ← nouvelle clé globale unique
  },
  plugins: [
    new ModuleFederationPlugin({
      name: "cosmotech_breweryTest",
      filename: "remoteEntry.[contenthash].js",
      exposes: { "./index": "./src/index.tsx" },
      shared: {
        react: { singleton: true, import: false },
        "react-dom": { singleton: true, import: false },
        antd: { singleton: true, import: false },
      },
    }),
  ],
});
```

### `src/index.tsx` (template)

```typescript
import React from "react";
import { views } from "@apache-superset/core";

views.registerView(
  { id: "cosmotech.brewery-test.example", name: "Brewery Test" },
  "sqllab.panels",       // ← slot cible (pas limité aux charts)
  () => <p>Brewery Test</p>,
);
```

## 4. Ce qui manque dans Superset 6.0.1

Vérifié directement dans le container Docker `apache/superset:latest` (6.0.1) :

| Composant runtime | Présent ? | Détail |
|---|---|---|
| `window.superset` (globale) | ❌ | Absent du JS frontend |
| `ModuleFederationPlugin` dans le build Superset | ❌ | Aucune trace de `remoteEntry` |
| `/api/v1/extensions/` endpoint | ❌ | Aucun fichier Python correspondant |
| `views.registerView()` dans le frontend | ❌ | Absent (le `registerView` trouvé est AG Grid) |
| `@apache-superset/core` npm package | ❌ | Non publié sur npm |
| `apache-superset-core` dans le container | ❌ | Non installé dans le venv Superset |

**Conclusion** : le CLI est un **outil de scaffolding et build** publié en avance. Le runtime serveur (qui consomme les extensions Module Federation) n'est pas encore intégré dans la release officielle.

## 5. Chronologie probable

```
v0.1.0 (mai 2026)     CLI + SDK Python publiés sur PyPI
                       → Permet aux développeurs de préparer des extensions

v6.1 ou v7.0 (?)      Runtime Module Federation intégré dans Superset
                       → /api/v1/extensions/ endpoint
                       → window.superset globale exposée
                       → Chargement des remoteEntry.js au démarrage

Futur                  Marketplace / registry d'extensions
                       → Upload de .supx bundles via UI admin
```

## 6. Stratégie de transition recommandée

### Phase 1 — Aujourd'hui (Superset 6.0.1)

Utiliser notre approche `DYNAMIC_PLUGINS` :
- ✅ Fonctionne maintenant
- ✅ Testée avec 2 plugins (ECharts + Leaflet)
- ✅ Automatisée (`Deploy-Plugin.ps1`)

### Phase 2 — Quand le runtime Module Federation arrive

Migrer les plugins existants :

```
# Changements nécessaires par plugin :

1. webpack.config.js
   - ESM output → ModuleFederationPlugin
   - window['__superset__/*'] → window.superset

2. src/index.ts
   - new Plugin().configure({key}).register()
   → views.registerView({id, name}, slot, component)

3. package.json
   - @superset-ui/core → @apache-superset/core

4. Ajouter extension.json
   - publisher, name, version, permissions

5. Superset config
   - Retirer le Blueprint workaround
   - Retirer DYNAMIC_PLUGINS feature flag (remplacé par le nouveau système)
```

### Phase 3 — Production K8s

Le workflow K8s reste similaire — seul le format de livraison change :

| Aspect | Phase 1 (actuel) | Phase 2 (futur) |
|---|---|---|
| Artifact | `dist/index.js` (ESM) | `dist/remoteEntry.[hash].js` + chunks |
| Config | Blueprint + `DYNAMIC_PLUGINS` | Natif (endpoint intégré) |
| Registration | Table `dynamic_plugins` via script Python | `/api/v1/extensions/` via REST API |
| Init container | Copie `index.js` dans `/static/assets/plugins/` | Copie `remoteEntry.js` dans le path extensions |

## 7. Points clés pour le suivi

- [ ] Surveiller les releases Superset pour l'apparition de `/api/v1/extensions/` dans le backend
- [ ] Vérifier quand `window.superset` est exposé dans le frontend build
- [ ] Tester le CLI `build` + `bundle` quand `@apache-superset/core` sera publié sur npm
- [ ] Évaluer si les plugins `@superset-ui/core` existants peuvent coexister avec `@apache-superset/core`

## 8. Conclusion

Le `apache-superset-extensions-cli` confirme que **la direction stratégique d'Apache Superset est alignée avec l'objectif de notre POC** : permettre l'injection de plugins sans rebuild. La nouvelle architecture (Module Federation) sera plus puissante (scope élargi au-delà des charts, namespacing, permissions), mais **n'est pas encore utilisable en production**.

Notre POC `DYNAMIC_PLUGINS` reste **la seule solution fonctionnelle aujourd'hui** et constitue un pont vers l'architecture officielle à venir.
