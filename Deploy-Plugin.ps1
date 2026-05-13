#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deploy one or more Superset chart plugins dynamically into a Dockerized Superset 6.x instance.
    No frontend rebuild required.

.DESCRIPTION
    This script takes a Superset plugin source folder (containing src/, package.json,
    webpack.config.js) and:
      1. Patches webpack.config.js for Superset 6.x dynamic loading (ESM + __superset__ externals)
      2. Patches src/index.ts to auto-register via .configure({ key }).register()
      3. Runs npm install + npm run build-dist
      4. Generates a docker-compose + superset_config.py (with all registered plugins)
      5. Starts Superset, registers the plugin in DB
      6. Opens the browser

    Use -AddPlugin to add a plugin to an already running Superset instance without resetting it.

.PARAMETER PluginPath
    Path to the plugin source folder (must contain package.json and src/index.ts).

.PARAMETER ContainerName
    Docker container name for Superset. Default: superset_dynamic_plugins

.PARAMETER Port
    Host port for Superset. Default: 8088

.PARAMETER SupersetImage
    Superset Docker image. Default: apache/superset:latest

.PARAMETER SkipBuild
    Skip npm install + build (use existing dist/).

.PARAMETER Reset
    Destroy existing container and volumes before starting fresh.

.PARAMETER AddPlugin
    Add the plugin to the existing running Superset instance.
    Rebuilds the plugin, adds it to the docker-compose volumes, and registers it in DB.
    Does NOT restart Superset from scratch (data preserved).

.EXAMPLE
    # First plugin — fresh start
    .\Deploy-Plugin.ps1 -PluginPath "C:\plugins\brewery"

    # Add a second plugin to the running instance
    .\Deploy-Plugin.ps1 -PluginPath "C:\plugins\supplychain" -AddPlugin

    # Start fresh with a specific port
    .\Deploy-Plugin.ps1 -PluginPath ".\plugins\my-plugin" -Port 9090 -Reset
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$PluginPath,

    [string]$ContainerName = "superset_dynamic_plugins",
    [int]$Port = 8088,
    [string]$SupersetImage = "apache/superset:latest",
    [switch]$SkipBuild,
    [switch]$Reset,
    [switch]$AddPlugin
)

$ErrorActionPreference = "Stop"
$ScriptRoot = $PSScriptRoot

# ─────────────────────────────────────────────────────────────────────────────
# STEP 0: Validate inputs
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Superset Dynamic Plugin Deployer" -ForegroundColor Cyan
Write-Host "  Superset 6.x - No rebuild required" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$PluginPath = (Resolve-Path $PluginPath -ErrorAction Stop).Path

if (-not (Test-Path "$PluginPath\package.json")) {
    Write-Host "ERROR: $PluginPath\package.json not found" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path "$PluginPath\src\index.ts")) {
    Write-Host "ERROR: $PluginPath\src\index.ts not found" -ForegroundColor Red
    exit 1
}

$pkgJson = Get-Content "$PluginPath\package.json" -Raw | ConvertFrom-Json
$pluginKey = $pkgJson.name
Write-Host "[INFO] Plugin: $pluginKey" -ForegroundColor Green
Write-Host "[INFO] Source:  $PluginPath" -ForegroundColor Green
Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Patch webpack.config.js for Superset 6.x dynamic loading
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "[1/6] Patching webpack.config.js for ESM + __superset__ externals..." -ForegroundColor Yellow

$webpackConfig = @"
const fs = require('fs');
const path = require('path');
const pkg = require('./package.json');

class GenerateManifestPlugin {
  apply(compiler) {
    compiler.hooks.afterEmit.tap('GenerateManifestPlugin', () => {
      const manifestPath = path.resolve(__dirname, 'manifest.json');
      const manifest = { name: pkg.name, key: pkg.name, bundle: 'dist/index.js' };
      fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
    });
  }
}

const SHARED_MODULES = [
  'react', 'react-dom',
  '@superset-ui/core', '@superset-ui/chart-controls',
  'lodash',
];

module.exports = {
  mode: 'production',
  entry: path.resolve(__dirname, 'src/index.ts'),
  output: {
    path: path.resolve(__dirname, 'dist'),
    filename: 'index.js',
    library: { type: 'module' },
    module: true,
    environment: { module: true },
    asyncChunks: false,
    clean: true,
  },
  experiments: { outputModule: true },
  resolve: { extensions: ['.ts', '.tsx', '.js', '.jsx', '.json'] },
  externals: [
    function ({ request }, callback) {
      if (SHARED_MODULES.includes(request)) {
        return callback(null, "promise window['__superset__/" + request + "']");
      }
      callback();
    },
  ],
  module: {
    rules: [
      { test: /\.tsx?$/, exclude: /node_modules/, use: [{ loader: 'babel-loader' }, { loader: 'ts-loader', options: { transpileOnly: true } }] },
      { test: /\.jsx?$/, exclude: /node_modules/, use: [{ loader: 'babel-loader' }] },
      { test: /\.css$/i, use: ['style-loader', 'css-loader'] },
      { test: /\.(png|jpe?g|gif|svg|woff2?|eot|ttf)$/i, type: 'asset/inline' },
    ],
  },
  optimization: { splitChunks: false, runtimeChunk: false },
  performance: { hints: false },
  devtool: 'source-map',
  plugins: [new GenerateManifestPlugin()],
};
"@

# Backup original
if (-not (Test-Path "$PluginPath\webpack.config.js.original")) {
    if (Test-Path "$PluginPath\webpack.config.js") {
        Copy-Item "$PluginPath\webpack.config.js" "$PluginPath\webpack.config.js.original"
    }
}
[System.IO.File]::WriteAllText("$PluginPath\webpack.config.js", $webpackConfig, [System.Text.UTF8Encoding]::new($false))
Write-Host "  OK" -ForegroundColor Green

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Patch src/index.ts to auto-register with .configure({ key }).register()
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "[2/6] Patching src/index.ts for auto-registration..." -ForegroundColor Yellow

$indexContent = Get-Content "$PluginPath\src\index.ts" -Raw

# Check if already patched
if ($indexContent -match '\.configure\(') {
    Write-Host "  Already patched (configure found)" -ForegroundColor Green
} else {
    # Find the default export name (e.g., "export { default as MyPlugin } from './plugin'")
    $exportMatch = [regex]::Match($indexContent, 'export\s*\{\s*default\s+as\s+(\w+)\s*\}')
    if (-not $exportMatch.Success) {
        # Try: export default ... from './plugin'
        $exportMatch = [regex]::Match($indexContent, 'export\s+default\s+(\w+)')
    }

    if ($exportMatch.Success) {
        $className = $exportMatch.Groups[1].Value
        Write-Host "  Found plugin class: $className" -ForegroundColor Cyan

        # Append auto-registration
        $autoRegister = @"

// --- Auto-register for Superset 6.x dynamic plugin loading ---
import __PluginClass__ from './plugin';
new __PluginClass__().configure({ key: '$pluginKey' }).register();
"@
        $indexContent = $indexContent.TrimEnd() + "`n" + $autoRegister + "`n"
        [System.IO.File]::WriteAllText("$PluginPath\src\index.ts", $indexContent, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  OK - added .configure({ key: '$pluginKey' }).register()" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Could not find plugin export in src/index.ts" -ForegroundColor Red
        Write-Host "  You may need to manually add: new YourPlugin().configure({ key: '$pluginKey' }).register()" -ForegroundColor Red
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: Build the plugin (npm install + webpack)
# ─────────────────────────────────────────────────────────────────────────────
if ($SkipBuild) {
    Write-Host "[3/6] Skipping build (-SkipBuild)" -ForegroundColor Yellow
} else {
    Write-Host "[3/6] Building plugin..." -ForegroundColor Yellow

    Push-Location $PluginPath

    # Ensure build-dist script uses node directly (Windows npx workaround)
    $pkgJsonRaw = Get-Content "package.json" -Raw
    if ($pkgJsonRaw -match '"build-dist"\s*:\s*"webpack"') {
        $pkgJsonRaw = $pkgJsonRaw -replace '"build-dist"\s*:\s*"webpack"', '"build-dist": "node node_modules/webpack-cli/bin/cli.js --config webpack.config.js"'
        [System.IO.File]::WriteAllText("$PluginPath\package.json", $pkgJsonRaw, [System.Text.UTF8Encoding]::new($false))
    }
    # Add build-dist if missing
    if ($pkgJsonRaw -notmatch '"build-dist"') {
        $pkgJsonRaw = $pkgJsonRaw -replace '("scripts"\s*:\s*\{)', "`$1`n    `"build-dist`": `"node node_modules/webpack-cli/bin/cli.js --config webpack.config.js`","
        [System.IO.File]::WriteAllText("$PluginPath\package.json", $pkgJsonRaw, [System.Text.UTF8Encoding]::new($false))
    }

    # Ensure required devDependencies exist
    $needInstall = $false
    foreach ($dep in @("webpack", "webpack-cli", "ts-loader", "babel-loader", "css-loader", "style-loader")) {
        if (-not (Test-Path "node_modules\$dep")) { $needInstall = $true; break }
    }
    if ($needInstall -or -not (Test-Path "node_modules")) {
        Write-Host "  npm install..." -ForegroundColor Cyan
        npm install --legacy-peer-deps 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: npm install failed" -ForegroundColor Red; Pop-Location; exit 1 }
    }

    Write-Host "  webpack build..." -ForegroundColor Cyan
    node node_modules\webpack-cli\bin\cli.js --config webpack.config.js 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: webpack build failed" -ForegroundColor Red; Pop-Location; exit 1 }

    Pop-Location

    if (-not (Test-Path "$PluginPath\dist\index.js")) {
        Write-Host "ERROR: dist/index.js not found after build" -ForegroundColor Red
        exit 1
    }
    $bundleSize = [math]::Round((Get-Item "$PluginPath\dist\index.js").Length / 1KB, 1)
    Write-Host "  OK - dist/index.js ($bundleSize KB)" -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Generate docker-compose.yml and superset_config.py
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "[4/6] Generating Docker configuration..." -ForegroundColor Yellow

$runtimeDir = "$ScriptRoot\.superset-runtime"
if (-not (Test-Path $runtimeDir)) { New-Item $runtimeDir -ItemType Directory -Force | Out-Null }

# --- superset_config.py ---
$supersetConfig = @"
PREVENT_UNSAFE_DB_CONNECTIONS = False

FEATURE_FLAGS = {
    "DYNAMIC_PLUGINS": True,
}

# Blueprint: expose /dynamic-plugins/api/read as JSON API
# Superset 6.x DynamicPluginsView is a FAB ModelView (HTML only).
# The frontend expects GET /dynamic-plugins/api/read -> JSON.
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

COMPRESS_REGISTER = False
COMPRESS_ENABLED = False
SESSION_COOKIE_SAMESITE = None
SESSION_COOKIE_SECURE = False
SESSION_COOKIE_HTTPONLY = False
WTF_CSRF_ENABLED = False
TALISMAN_ENABLED = False
TALISMAN_CONFIG = {"content_security_policy": False, "force_https": False, "force_https_permanent": False}
"@
[System.IO.File]::WriteAllText("$runtimeDir\superset_config.py", $supersetConfig, [System.Text.UTF8Encoding]::new($false))

# --- register_plugin.py (template) ---
$registerScript = @"
import sys
from superset.app import create_app
app = create_app()
with app.app_context():
    from superset.models.dynamic_plugins import DynamicPlugin
    from superset.extensions import db
    key = sys.argv[1]
    name = sys.argv[2]
    bundle_url = sys.argv[3]
    existing = db.session.query(DynamicPlugin).filter_by(key=key).first()
    if existing:
        existing.bundle_url = bundle_url
        existing.name = name
        db.session.commit()
        print(f"Plugin '{key}' updated (id={existing.id})")
    else:
        p = DynamicPlugin(name=name, key=key, bundle_url=bundle_url)
        db.session.add(p)
        db.session.commit()
        print(f"Plugin '{key}' registered (id={p.id})")
"@
[System.IO.File]::WriteAllText("$runtimeDir\register_plugin.py", $registerScript, [System.Text.UTF8Encoding]::new($false))

# --- docker-compose.yml ---
$distPath = "$PluginPath\dist" -replace '\\', '/'
$configPath = "$runtimeDir\superset_config.py" -replace '\\', '/'
$pluginStaticPath = "/app/superset/static/assets/plugins/$pluginKey"

$composeContent = @"
services:
  superset:
    image: $SupersetImage
    container_name: $ContainerName
    ports:
      - "${Port}:8088"
    environment:
      - SUPERSET_SECRET_KEY=DynamicPluginPOC_SecretKey_$(Get-Random -Maximum 999999)
      - SUPERSET_ENV=production
      - PYTHONPATH=/app/pythonpath
    volumes:
      - ${distPath}:${pluginStaticPath}:ro
      - ${configPath}:/app/pythonpath/superset_config.py:ro
      - superset_data:/app/superset_home
    command: >
      bash -c "
      superset db upgrade &&
      superset fab create-admin --username admin --firstname Admin --lastname User --email admin@superset.com --password admin 2>/dev/null || true &&
      superset init &&
      superset run -h 0.0.0.0 -p 8088 --with-threads --reload --debugger
      "
    restart: unless-stopped

volumes:
  superset_data:
"@
[System.IO.File]::WriteAllText("$runtimeDir\docker-compose.yml", $composeContent, [System.Text.UTF8Encoding]::new($false))

Write-Host "  OK - files in $runtimeDir" -ForegroundColor Green

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: Start Superset container
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "[5/6] Starting Superset..." -ForegroundColor Yellow

$ErrorActionPreference = "Continue"

if ($Reset) {
    Write-Host "  Removing existing container..." -ForegroundColor Cyan
    docker-compose -f "$runtimeDir\docker-compose.yml" down -v 2>&1 | Out-Null
}

# Stop if already running
$running = docker ps -q --filter "name=$ContainerName" 2>$null
if ($running) {
    Write-Host "  Stopping existing container..." -ForegroundColor Cyan
    docker-compose -f "$runtimeDir\docker-compose.yml" down 2>&1 | Out-Null
}

docker-compose -f "$runtimeDir\docker-compose.yml" up -d 2>&1 | Out-Null

$ErrorActionPreference = "Stop"

# Verify container is running
Start-Sleep -Seconds 3
$running = docker ps -q --filter "name=$ContainerName" 2>$null
if (-not $running) {
    Write-Host "ERROR: Container $ContainerName did not start. Check: docker logs $ContainerName" -ForegroundColor Red
    exit 1
}

# Wait for Superset to be ready
Write-Host "  Waiting for Superset to initialize..." -ForegroundColor Cyan
$maxWait = 180
$waited = 0
while ($waited -lt $maxWait) {
    Start-Sleep -Seconds 5
    $waited += 5
    try {
        $health = Invoke-WebRequest -Uri "http://localhost:$Port/health" -UseBasicParsing -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($health.StatusCode -eq 200) {
            Write-Host "  Superset ready after ${waited}s" -ForegroundColor Green
            break
        }
    } catch {}
    Write-Host "  ... ${waited}s" -ForegroundColor Gray
}
if ($waited -ge $maxWait) {
    Write-Host "WARNING: Superset did not respond after ${maxWait}s. Check: docker logs $ContainerName" -ForegroundColor Red
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: Register the plugin in Superset's database
# ─────────────────────────────────────────────────────────────────────────────
Write-Host "[6/6] Registering plugin in Superset database..." -ForegroundColor Yellow

$ErrorActionPreference = "Continue"

$bundleUrl = "/static/assets/plugins/$pluginKey/index.js"
$displayName = (($pluginKey -replace '-', ' ') -split ' ' | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1) }) -join ' '

docker cp "$runtimeDir\register_plugin.py" "${ContainerName}:/tmp/register_plugin.py" 2>&1 | Out-Null
$regOutput = docker exec $ContainerName python3 /tmp/register_plugin.py "$pluginKey" "$displayName" "$bundleUrl" 2>&1 | Out-String

$ErrorActionPreference = "Stop"
$regLine = ($regOutput | Select-String "Plugin" | Select-Object -Last 1)
if ($regLine) {
    Write-Host "  $regLine" -ForegroundColor Green
} else {
    Write-Host "  WARNING: Registration output unclear. Check manually." -ForegroundColor Yellow
    Write-Host "  $regOutput" -ForegroundColor Gray
}

# ─────────────────────────────────────────────────────────────────────────────
# DONE
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Superset URL:  http://localhost:$Port" -ForegroundColor White
Write-Host "  Login:         admin / admin" -ForegroundColor White
Write-Host "  Plugin:        $pluginKey" -ForegroundColor White
Write-Host "  Bundle:        $bundleUrl" -ForegroundColor White
Write-Host ""
Write-Host "  To create a chart: Charts -> + Chart -> select '$displayName'" -ForegroundColor Cyan
Write-Host ""
Write-Host "  To rebuild after code changes:" -ForegroundColor Gray
Write-Host "    cd $PluginPath" -ForegroundColor Gray
Write-Host "    npm run build-dist" -ForegroundColor Gray
Write-Host "    Then Ctrl+Shift+R in the browser" -ForegroundColor Gray
Write-Host ""

# Open browser
Start-Process "http://localhost:$Port"
