# Document de Design — Architecture & Décisions Techniques

## 1. Vue d'ensemble

```
┌──────────────────────────────────────────────────────────┐
│  Navigateur                                              │
│                                                          │
│  ┌─────────────────────────────────────────────────────┐ │
│  │ Superset SPA (React)                                │ │
│  │                                                     │ │
│  │  1. GET /dynamic-plugins/api/read                   │ │
│  │     → [{key, bundle_url}]                           │ │
│  │                                                     │ │
│  │  2. await import(bundle_url)                        │ │
│  │     ← ES Module (self-registering)                  │ │
│  │                                                     │ │
│  │  3. Plugin visible dans Chart Gallery               │ │
│  └─────────────────────────────────────────────────────┘ │
└──────────────────────┬───────────────────────────────────┘
                       │ HTTP
┌──────────────────────▼───────────────────────────────────┐
│  Docker : superset_dynamic_plugins                       │
│                                                          │
│  Flask (Superset 6.0.1)                                  │
│  ├── /dynamic-plugins/api/read  (Blueprint custom)       │
│  ├── /static/assets/plugins/*/index.js  (volume mount)   │
│  └── SQLite: dynamic_plugins table (key, bundle_url)     │
└──────────────────────────────────────────────────────────┘
```

## 2. Mécanisme de chargement — Dynamic Plugins

### Côté Superset (frontend, code existant)

Le fichier `3397.*.entry.js` contient le `DynamicPluginProvider` :

```javascript
// Pseudo-code déminifié du frontend Superset 6.x
async function loadDynamicPlugins() {
  // 1. Charger les dépendances partagées dans window.__superset__/*
  await loadSharedModules({
    'react':                     () => import('react'),
    '@superset-ui/core':         () => import('@superset-ui/core'),
    '@superset-ui/chart-controls': () => import('@superset-ui/chart-controls'),
  });

  // 2. Récupérer la liste des plugins
  const { result } = await fetch('/dynamic-plugins/api/read');

  // 3. Charger chaque plugin via import() natif
  for (const plugin of result) {
    try {
      await import(plugin.bundle_url);  // ← import() natif du navigateur
    } catch (err) {
      console.error(`Failed to load plugin ${plugin.key}`, err);
    }
  }
}
```

### Shared modules — `window.__superset__/*`

Avant de charger les plugins, Superset expose ses dépendances partagées :

| Clé globale | Module |
|---|---|
| `window['__superset__/react']` | React 18 |
| `window['__superset__/react-dom']` | ReactDOM |
| `window['__superset__/@superset-ui/core']` | Core Superset (ChartPlugin, ChartMetadata, etc.) |
| `window['__superset__/@superset-ui/chart-controls']` | Contrôles du chart builder |
| `window['__superset__/lodash']` | Lodash |

### Côté plugin (notre bundle)

Le plugin est un module ES qui :

1. **Résout ses externals** depuis `window['__superset__/*']` (pas de duplication de React)
2. **S'auto-enregistre** via `.configure({ key }).register()` au moment du chargement
3. **Exporte** la classe `ChartPlugin` (convention, non utilisé par Superset)

## 3. Décisions d'architecture

### ADR-001 : Webpack ESM output (pas UMD)

**Contexte** : Superset 6.x charge les plugins via `import()` natif du navigateur.

**Décision** : Output webpack en `library.type: 'module'` avec `experiments.outputModule: true`.

**Raison** : Le `import()` natif nécessite un vrai module ES. Le format UMD ne fonctionne pas avec `import()`.

### ADR-002 : Externals via `window['__superset__/*']`

**Contexte** : Les dépendances partagées (React, @superset-ui/core) sont exposées par Superset sur des clés globales `window['__superset__/<pkg>']`.

**Décision** : Externals webpack avec type `promise` :

```javascript
// webpack.config.js
externals: [
  function ({ request }, callback) {
    if (SHARED_MODULES.includes(request)) {
      return callback(null, `promise window['__superset__/${request}']`);
    }
    callback();
  },
],
```

**Raison** : Les valeurs sont déjà résolues (pas des Promises) au moment du chargement du plugin, mais le type `promise` webpack est compatible avec le format ESM output.

### ADR-003 : `.configure({ key }).register()` (pas `super({ key })`)

**Contexte** : Dans Superset 6.x, la classe `ChartPlugin` hérite de `Plugin` qui stocke la config dans `this.config` via `.configure()`. La méthode `register()` lit `this.config.key`.

**Décision** : L'auto-registration dans `src/index.ts` utilise :

```typescript
new SupersetBreweryExtensionTest1()
  .configure({ key: 'superset-brewery-extension-test-1' })
  .register();
```

**Raison** : Passer `key` dans le constructeur `super({ key })` ne fonctionne PAS — le constructeur de `ChartPlugin` ne propage pas `key` dans `this.config`. C'est le pattern `.configure().register()` qui est utilisé par le code interne de Superset lui-même.

### ADR-004 : Blueprint Flask custom pour `/dynamic-plugins/api/read`

**Contexte** : Dans Superset 6.x, le `DynamicPluginsView` est un FAB `ModelView` qui n'expose qu'une UI HTML CRUD (`/dynamic-plugins/list/`, `/add`, `/edit`). Le frontend attend un endpoint JSON sur `/dynamic-plugins/api/read`.

**Décision** : On ajoute un Blueprint Flask dans `superset_config.py` :

```python
BLUEPRINTS = [dynamic_plugins_api_bp]
```

**Raison** : C'est la seule façon d'exposer l'API JSON sans modifier le code source de Superset.

### ADR-005 : Volume mount (pas docker cp)

**Décision** : Le dossier `dist/` du plugin est monté directement dans le container :

```yaml
volumes:
  - ./plugins-compiled/raw_build/dist:/app/superset/static/assets/plugins/superset-brewery-extension-test-1:ro
```

**Raison** : Permet le hot-reload — après `npm run build-dist`, un simple refresh du navigateur charge le nouveau bundle.

## 4. Structure des fichiers

```
POC-dynamic-plugin/                     # Workspace racine
├── docs/                               # Documentation
│   ├── 01-CONTEXT.md
│   ├── 02-DESIGN.md                    # Ce fichier
│   ├── 03-PROGRESSION.md
│   └── 04-README.md
├── Deploy-Plugin.ps1                   # Script principal (entrée unique)
└── .superset-runtime/                  # Généré par Deploy-Plugin.ps1
    ├── docker-compose.yml              # Stack Docker Superset 6.x
    ├── superset_config.py              # Config Superset + Blueprint API
    └── register_plugin.py              # Enregistrement plugin en DB

# Le dossier source du plugin est EXTERNE (passé via -PluginPath)
<plugin-path>/
├── src/
│   ├── index.ts                        # Point d'entrée (patché pour auto-registration)
│   └── plugin/
│       └── index.ts                    # Classe ChartPlugin
├── dist/                               # Bundle ESM généré (~40 KB)
│   └── index.js
├── webpack.config.js                   # Patché pour ESM + __superset__ externals
└── package.json
```

## 5. Flux de données

```
[Superset DB] → buildQuery.ts → SQL → [Datasource]
                                         ↓
                                    transformProps.ts → { width, height, data, ... }
                                         ↓
                                    ChartComponent.tsx → Render
```
