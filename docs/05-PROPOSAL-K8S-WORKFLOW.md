# Proposition de Workflow — Dynamic Plugins Superset sur Kubernetes (PaaS)

> Basé sur les conclusions du POC `superset-6.0-dynamic-plugin` — testé avec 2 plugins (Brewery ECharts + Supplychain Leaflet) sur Superset 6.0.1.

## 1. Résumé exécutif

Le POC a démontré qu'un plugin de visualisation React peut être **buildé indépendamment** et **chargé dynamiquement** dans Superset 6.x sans rebuild de l'image Docker. Ce document propose un workflow pour intégrer cette approche dans notre plateforme PaaS sur Kubernetes.

**Principe** : L'image Superset ne change jamais. Seuls les bundles JS des plugins sont livrés et enregistrés.

## 2. Architecture cible

```
┌─────────────────────────────────────────────────────────────────┐
│  CI/CD Pipeline (GitHub Actions / Azure DevOps)                 │
│                                                                 │
│  1. git push sur le repo d'un plugin                            │
│  2. npm install + webpack build → dist/index.js (bundle ESM)    │
│  3. Upload du bundle vers le stockage (Blob / S3 / PVC)         │
│  4. Enregistrement du plugin en base (API ou Job K8s)           │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│  Kubernetes Cluster                                             │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Pod Superset (image apache/superset:6.x inchangée)       │  │
│  │                                                           │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │ Init Container (optionnel)                          │  │  │
│  │  │ - Télécharge les bundles depuis le stockage         │  │  │
│  │  │ - Les copie dans /plugins/                          │  │  │
│  │  └─────────────────────────────────────────────────────┘  │  │
│  │                                                           │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │ Superset Container                                  │  │  │
│  │  │                                                     │  │  │
│  │  │ superset_config.py (ConfigMap)                      │  │  │
│  │  │ ├─ DYNAMIC_PLUGINS: True                            │  │  │
│  │  │ └─ Blueprint /dynamic-plugins/api/read              │  │  │
│  │  │                                                     │  │  │
│  │  │ /app/superset/static/assets/plugins/ (Volume)       │  │  │
│  │  │ ├─ plugin-a/index.js                                │  │  │
│  │  │ ├─ plugin-b/index.js                                │  │  │
│  │  │ └─ plugin-c/index.js                                │  │  │
│  │  └─────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  PostgreSQL                                               │  │
│  │  └─ Table dynamic_plugins (key, name, bundle_url)         │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## 3. Composants à mettre en place

### 3.1. Configuration Superset (ConfigMap)

Un seul `ConfigMap` suffit pour activer les dynamic plugins. C'est le même `superset_config.py` que celui du POC :

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: superset-config
data:
  superset_config.py: |
    FEATURE_FLAGS = {
        "DYNAMIC_PLUGINS": True,
    }

    from flask import Blueprint, jsonify

    _dp_api = Blueprint("dynamic_plugins_api", __name__)

    @_dp_api.route("/dynamic-plugins/api/read")
    def _dp_api_read():
        import time
        from superset.extensions import db
        from superset.models.dynamic_plugins import DynamicPlugin
        plugins = db.session.query(DynamicPlugin).all()
        ts = int(time.time())
        return jsonify({
            "result": [
                {"id": p.id, "name": p.name, "key": p.key,
                 "bundle_url": p.bundle_url + f"?v={ts}"}
                for p in plugins
            ]
        })

    BLUEPRINTS = [_dp_api]
```

> **Note** : Le Blueprint est un workaround pour Superset 6.x. Si une future version expose `/dynamic-plugins/api/read` nativement, il suffira de retirer le Blueprint du ConfigMap.

### 3.2. Stockage des bundles — 3 options

| Option | Mécanisme | Avantages | Inconvénients |
|---|---|---|---|
| **A. PVC partagé** | PersistentVolumeClaim monté dans le pod | Simple, filesystem standard | Couplage au cluster, scaling limité |
| **B. Object Storage (S3/GCS/Azure Blob)** | Init container télécharge au démarrage | Découplé, scalable, versionnable | Latence au démarrage, coût stockage |
| **C. Image sidecar** | Image Docker dédiée avec les bundles | Immuable, versionné via tags | Nécessite un rebuild d'image (mais pas celle de Superset) |

### Recommandation : **Option B (Object Storage)** pour la production

```
Blob Storage
├── plugins/
│   ├── plugin-brewery/v1.2.0/index.js
│   ├── plugin-supplychain/v2.0.1/index.js
│   └── plugin-dashboard-kpi/v1.0.0/index.js
└── manifest.json  (liste des plugins actifs + versions)
```

### 3.3. Init Container — téléchargement des bundles

```yaml
initContainers:
  - name: download-plugins
    image: curlimages/curl:latest
    command:
      - sh
      - -c
      - |
        # Télécharger le manifest
        curl -s $PLUGIN_STORAGE_URL/manifest.json -o /tmp/manifest.json

        # Télécharger chaque bundle
        for plugin in $(cat /tmp/manifest.json | jq -r '.plugins[].key'); do
          version=$(cat /tmp/manifest.json | jq -r ".plugins[] | select(.key==\"$plugin\") | .version")
          mkdir -p /plugins/$plugin
          curl -s "$PLUGIN_STORAGE_URL/plugins/$plugin/$version/index.js" -o /plugins/$plugin/index.js
          echo "Downloaded $plugin v$version"
        done
    volumeMounts:
      - name: plugins-volume
        mountPath: /plugins
    env:
      - name: PLUGIN_STORAGE_URL
        valueFrom:
          configMapKeyRef:
            name: superset-plugins-config
            key: storageUrl
```

### 3.4. Enregistrement en base — Job K8s

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: register-plugin-brewery
spec:
  template:
    spec:
      containers:
        - name: register
          image: apache/superset:6.0.1
          command:
            - python3
            - -c
            - |
              from superset.app import create_app
              app = create_app()
              with app.app_context():
                  from superset.models.dynamic_plugins import DynamicPlugin
                  from superset.extensions import db
                  key = "plugin-brewery"
                  existing = db.session.query(DynamicPlugin).filter_by(key=key).first()
                  if not existing:
                      p = DynamicPlugin(
                          name="Brewery Process Chart",
                          key=key,
                          bundle_url="/static/assets/plugins/plugin-brewery/index.js"
                      )
                      db.session.add(p)
                      db.session.commit()
                      print(f"Registered {key}")
          env:
            - name: SUPERSET_CONFIG_PATH
              value: /app/pythonpath/superset_config.py
          # ... DB connection env vars
      restartPolicy: Never
```

## 4. Pipeline CI/CD — Workflow type

```
┌──────────────────────────────────────────────────────────────┐
│  Développeur                                                 │
│                                                              │
│  1. Développe le plugin dans son repo dédié                  │
│  2. git push / merge PR                                      │
└──────────────────┬───────────────────────────────────────────┘
                   │ trigger
                   ▼
┌──────────────────────────────────────────────────────────────┐
│  CI Pipeline                                                 │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ Stage 1: Build                                          │ │
│  │  - npm install --legacy-peer-deps                       │ │
│  │  - Patch webpack.config.js (ESM + __superset__)         │ │
│  │  - Patch src/index.ts (.configure().register())         │ │
│  │  - webpack build → dist/index.js                        │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ Stage 2: Publish                                        │ │
│  │  - Upload dist/index.js → Blob Storage (versioned)      │ │
│  │  - Mettre à jour manifest.json                          │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │ Stage 3: Deploy                                         │ │
│  │  - kubectl apply -f register-plugin-job.yaml            │ │
│  │  - kubectl rollout restart deployment/superset          │ │
│  │    (l'init container re-télécharge les bundles)          │ │
│  └─────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

### Exemple GitHub Actions

```yaml
name: Build & Deploy Superset Plugin
on:
  push:
    branches: [main]

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20

      - name: Install dependencies
        run: npm install --legacy-peer-deps

      - name: Patch webpack for Superset 6.x
        run: |
          # Le webpack.config.js doit déjà être configuré pour ESM + __superset__
          # (identique à celui généré par Deploy-Plugin.ps1)
          node node_modules/webpack-cli/bin/cli.js --config webpack.config.js

      - name: Verify bundle
        run: |
          test -f dist/index.js
          echo "Bundle size: $(du -h dist/index.js | cut -f1)"

      - name: Upload to Azure Blob / S3
        run: |
          PLUGIN_KEY=$(jq -r .name package.json)
          VERSION=$(jq -r .version package.json)
          az storage blob upload \
            --container-name superset-plugins \
            --name "plugins/$PLUGIN_KEY/$VERSION/index.js" \
            --file dist/index.js

      - name: Register plugin in Superset DB
        run: |
          kubectl apply -f k8s/register-plugin-job.yaml
          kubectl wait --for=condition=complete job/register-plugin --timeout=60s

      - name: Restart Superset pods (reload plugins)
        run: kubectl rollout restart deployment/superset
```

## 5. Gestion multi-tenant

Pour un PaaS multi-tenant, chaque tenant peut avoir ses propres plugins :

```
Blob Storage
├── tenants/
│   ├── tenant-acme/
│   │   ├── manifest.json
│   │   └── plugins/
│   │       ├── acme-kpi-chart/index.js
│   │       └── acme-process-viz/index.js
│   └── tenant-cosmo/
│       ├── manifest.json
│       └── plugins/
│           ├── brewery-chart/index.js
│           └── supplychain-chart/index.js
```

Le `manifest.json` par tenant permet à l'init container de ne charger que les plugins pertinents. La table `dynamic_plugins` étant globale dans Superset, la séparation se fait au niveau du déploiement (un pod Superset par tenant, ou un namespace par tenant).

## 6. Prérequis techniques confirmés par le POC

| Prérequis | Confirmé | Détail |
|---|---|---|
| Bundle ESM unique | ✅ | `asyncChunks: false` + `splitChunks: false` |
| Externals `window.__superset__/*` | ✅ | React, @superset-ui/core, chart-controls, lodash |
| Auto-registration `.configure({key}).register()` | ✅ | Pattern obligatoire dans Superset 6.x |
| Blueprint API `/dynamic-plugins/api/read` | ✅ | Workaround nécessaire en 6.x |
| `npm install --legacy-peer-deps` | ✅ | Nécessaire pour certains plugins |
| Pas de rebuild image Superset | ✅ | Volume mount + ConfigMap suffisent |
| Fonctionne avec différents types de plugins | ✅ | ECharts (40 KB) + Leaflet (178 KB) |

## 7. Risques et mitigations

| Risque | Impact | Mitigation |
|---|---|---|
| Blueprint API est un workaround | Maintenance à chaque upgrade Superset | Vérifier à chaque montée de version si l'endpoint est natif |
| Compatibilité Superset 5.x non testée | Plugins buildés pour 6.x pourraient ne pas fonctionner | Tester avec `-SupersetImage "apache/superset:5.0.0"` |
| `window.__superset__/*` clés pourraient changer | Bundles deviennent incompatibles | Versionner les bundles par version Superset |
| Plugins tiers avec des dépendances non externalisées | Bundle trop gros ou conflits | Étendre la liste `SHARED_MODULES` dans webpack |
| Cache navigateur | Ancien bundle servi après update | `?v=<timestamp>` déjà implémenté dans le Blueprint |

## 8. Prochaines étapes

1. **Créer un template de repo plugin** avec webpack.config.js + auto-registration déjà configurés
2. **Adapter `Deploy-Plugin.ps1`** en version CI/CD (Linux, sans Docker local)
3. **Tester sur Superset 5.x** avec le flag `-SupersetImage`
4. **Implémenter l'init container** dans le Helm chart Superset existant
5. **Valider le workflow end-to-end** sur un cluster K8s de staging

## 9. Conclusion

Le POC prouve que l'approche **build → upload → register** fonctionne sans modification de l'image Superset. Le passage en production nécessite principalement de l'infrastructure (stockage, init container, CI/CD) — la logique de build et de chargement est **identique** à celle validée dans le POC.

**L'image Superset reste inchangée. Seuls les bundles JS et un ConfigMap sont déployés.**
