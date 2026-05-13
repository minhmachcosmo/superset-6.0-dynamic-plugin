# Dynamic Plugin POC — Superset 6.x

Déploiement dynamique de plugins de visualisation React dans Apache Superset 6.x **sans rebuild du frontend**.

## Prérequis

- **Windows 10/11** avec PowerShell
- **Docker Desktop** installé et lancé
- **Node.js 20+** (`node -v`)
- **npm 10+** (`npm -v`)

## Quick Start

### Déploiement en une commande

```powershell
.\Deploy-Plugin.ps1 -PluginPath "C:\chemin\vers\mon-plugin-superset"
```

Le script fait automatiquement :
1. Patch webpack.config.js pour ESM + externals `__superset__`
2. Patch src/index.ts pour l'auto-registration (`.configure({ key }).register()`)
3. `npm install` + `npm run build-dist`
4. Génère docker-compose + superset_config.py (avec Blueprint API)
5. Lance Superset 6.x en Docker
6. Enregistre le plugin en base
7. Ouvre le navigateur

### Options

```powershell
# Port et image personnalisés
.\Deploy-Plugin.ps1 -PluginPath ".\my-plugin" -Port 9090 -SupersetImage "apache/superset:6.0.1"

# Reset complet (supprime volumes et données)
.\Deploy-Plugin.ps1 -PluginPath ".\my-plugin" -Reset

# Skip le build (utiliser le dist/ existant)
.\Deploy-Plugin.ps1 -PluginPath ".\my-plugin" -SkipBuild
```

### Exemple avec le plugin Brewery

```powershell
.\Deploy-Plugin.ps1 -PluginPath "C:\Users\minh\Documents\WORK\Superset\Extension\superset_brewery_extension_test_1"
```

Puis ouvrir http://localhost:8088, login `admin/admin`, Charts → + Chart → "Superset Brewery Extension Test 1".

## Cycle de développement

```powershell
# 1. Modifier le code source du plugin
# 2. Rebuilder
cd <plugin-path>
npm run build-dist

# 3. Rafraîchir le navigateur (Ctrl+Shift+R)
# Le volume Docker est live — pas besoin de redémarrer le container
```

## Architecture

```
Navigateur
  │
  │  1. GET /dynamic-plugins/api/read → [{key, bundle_url}]
  │  2. import(bundle_url) → ES Module se charge et s'auto-enregistre
  │  3. Plugin disponible dans le Chart Builder
  │
  ▼
Docker (superset_dynamic_plugins)
  ├── Superset 6.0.1
  ├── Blueprint custom → /dynamic-plugins/api/read (JSON API)
  ├── /static/assets/plugins/*/index.js ← volume mount <plugin-path>/dist
  └── SQLite → dynamic_plugins(key, bundle_url)
```

## Fichiers clés

| Fichier | Rôle |
|---|---|
| `Deploy-Plugin.ps1` | Script principal — déploie n'importe quel plugin Superset |
| `.superset-runtime/docker-compose.yml` | Stack Docker Superset 6.x (généré) |
| `.superset-runtime/superset_config.py` | Config Superset + Blueprint API (généré) |
| `.superset-runtime/register_plugin.py` | Enregistrement du plugin en base (généré) |

## Points techniques importants

### Pourquoi `.configure({ key })` ?

Dans Superset 6.x, `ChartPlugin.register()` lit `this.config.key`.
La config est stockée via `.configure()`, pas dans le constructeur :

```typescript
// ❌ Ne fonctionne PAS dans Superset 6.x
new MyPlugin().register()

// ✅ Pattern correct
new MyPlugin().configure({ key: 'my-plugin-key' }).register()
```

### Pourquoi un Blueprint Flask custom ?

Le `DynamicPluginsView` de Superset 6.x est un FAB `ModelView` (UI HTML uniquement).
Le frontend attend un endpoint JSON sur `/dynamic-plugins/api/read` qui n'existe pas.
Le Blueprint dans `superset_config.py` comble ce manque.

### Pourquoi ESM et pas UMD ?

Superset charge les plugins via `import(bundle_url)` — un `import()` **natif du navigateur**.
Seuls les modules ES sont compatibles avec `import()` natif.

### Externals `window['__superset__/*']`

Superset expose React, @superset-ui/core, etc. sur des clés globales avant de charger les plugins.
Le bundle ne contient PAS React — il le résout depuis `window['__superset__/react']` au runtime.

## Scripts npm

| Commande | Description |
|---|---|
| `npm run build-dist` | Build du bundle ESM (webpack) → `dist/index.js` |
| `npm run build` | Build CJS + ESM (babel) → `lib/` + `esm/` |
| `npm test` | Tests unitaires (Jest) |

## Troubleshooting

### Le plugin n'apparaît pas dans les charts

1. Vérifier que `DYNAMIC_PLUGINS: True` est dans `superset_config.py`
2. Vérifier l'API : `curl http://localhost:8088/dynamic-plugins/api/read`
3. Vérifier la console F12 pour des erreurs de chargement
4. Hard refresh : **Ctrl+Shift+R**

### `config.key is required`

Le plugin se charge mais `.register()` échoue → vérifier que `src/index.ts` utilise `.configure({ key: '...' }).register()`.

### `npx webpack` ne fonctionne pas (Windows)

Le script `build-dist` utilise `node node_modules/webpack-cli/bin/cli.js` au lieu de `npx webpack` pour contourner un bug de résolution de binaires sous Windows.

### Cache navigateur

Le Blueprint ajoute `?v=<timestamp>` à la bundle URL pour éviter le cache.
En cas de doute, ouvrir un onglet incognito.
