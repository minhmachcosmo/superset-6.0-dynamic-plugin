# Contexte & Objectifs du Projet

## Contexte

**Cosmo Tech** utilise Apache Superset comme solution de data-visualization pour ses clients.
L'ajout de visualisations personnalisées nécessite aujourd'hui un **rebuild complet** du frontend Superset — un processus lourd, couplé au cycle de release, et peu compatible avec un déploiement SaaS multi-tenant.

Ce projet est un **Proof of Concept (POC)** visant à démontrer la faisabilité d'une approche alternative : **l'injection dynamique de plugins de visualisation React dans Superset 6.x, sans rebuild du frontend**.

## Objectifs

### Objectif principal

Prouver qu'un plugin de visualisation React custom (chart ECharts de monitoring d'un processus brassicole) peut être :

1. **Développé** de manière autonome, en dehors du monorepo Superset
2. **Compilé** en un bundle JavaScript unique (UMD/ESM)
3. **Déployé** à chaud dans une instance Superset 6.x Dockerisée
4. **Visible et utilisable** dans le Chart Builder de Superset, comme n'importe quel chart natif

### Objectifs secondaires

- Documenter les **workarounds** nécessaires pour Superset 6.x (endpoint API manquant, pattern `configure().register()`)
- Produire un **kit de déploiement reproductible** (docker-compose + scripts PowerShell)
- Évaluer la viabilité de cette approche pour une **mise en production**

## Périmètre

| In scope | Out of scope |
|---|---|
| Plugin chart React + ECharts | Backend Python custom (viz endpoints) |
| Build webpack ESM autonome | Intégration CI/CD |
| Déploiement Docker local | Déploiement Kubernetes / cloud |
| Superset 6.x (latest) | Versions antérieures (4.x, 5.x) |
| Feature flag `DYNAMIC_PLUGINS` | Mécanisme `superset-extensions` (pas mature) |

## Stack technique

| Composant | Technologie |
|---|---|
| Superset | 6.0.1 (image Docker `apache/superset:latest`) |
| Plugin framework | `@superset-ui/core`, `@superset-ui/chart-controls` |
| Visualisation | ECharts 6 via `echarts-for-react` |
| Build | Webpack 5 (output ESM module) |
| Runtime | Dynamic `import()` natif du navigateur |
| Environnement dev | Windows 11, PowerShell, Docker Desktop |
| Node.js | 20.x |

## Structure du projet

```
POC-dynamic-plugin/                        Workspace racine
├── docs/                                  Documentation
│   ├── 01-CONTEXT.md                      Ce fichier
│   ├── 02-DESIGN.md                       Architecture & décisions techniques
│   ├── 03-PROGRESSION.md                  Journal de progression
│   └── 04-README.md                       Guide d'utilisation
├── Deploy-Plugin.ps1                      Script principal — déploie n'importe quel plugin
└── .superset-runtime/                     (généré) Configs Docker + Superset
    ├── docker-compose.yml
    ├── superset_config.py
    └── register_plugin.py
```

> Le dossier source du plugin est **externe** au projet. `Deploy-Plugin.ps1` accepte n'importe quel chemin via `-PluginPath`.

## Équipe

| Rôle | Personne |
|---|---|
| Développeur / POC lead | Minh |
| Publisher | cosmotech-platform-team |
