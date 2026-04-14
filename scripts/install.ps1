# MoVP plugin installer for Windows
# Usage: irm https://get.movp.dev/install.ps1 | iex
#        .\install.ps1 [-Dir <path>] [-Tool claude|cursor|codex] [-Version <tag>]
#
# Requires: PowerShell 5.1+ (ships with Windows 10/11), Node.js 18+, git

param(
    [string]$Dir             = "$env:USERPROFILE\.movp\plugins",
    [string]$Tool            = "",
    [string]$Version         = "",
    [switch]$AllowPrerelease = $false
)

$ErrorActionPreference = 'Stop'

$Repo = "https://github.com/MostViableProduct/movp-plugins"

# Resolve version: default to latest stable semver tag (not main)
if (-not $Version) {
    $tagPattern = if ($AllowPrerelease) {
        'refs/tags/v\d+\.\d+\.\d+'
    } else {
        'refs/tags/v\d+\.\d+\.\d+$'
    }
    $rawTags = & git ls-remote --tags --sort=-version:refname $Repo 2>$null
    $Version = ($rawTags | Select-String -Pattern $tagPattern | Select-Object -First 1 |
        ForEach-Object { $_ -replace '.*refs/tags/', '' })

    if (-not $Version) {
        Write-Error @"
Error: no stable release tags found in $Repo.
  To install from main (development, not recommended for production):
    .\install.ps1 -Version main
  To include prerelease tags:
    .\install.ps1 -AllowPrerelease
"@
        exit 1
    }
}

Write-Host "Installing MoVP plugins$(if ($Version) { " ($Version)" })..." -ForegroundColor White

# Check prerequisites
function Check-Command {
    param([string]$Cmd, [string]$Hint)
    if (-not (Get-Command $Cmd -ErrorAction SilentlyContinue)) {
        Write-Error "Error: $Cmd is required but not installed. $Hint"
        exit 1
    }
}

Check-Command node "Install Node.js 18+ from https://nodejs.org"
Check-Command git  "Install git from https://git-scm.com"

# Validate node version (>=18)
$nodeMajor = [int](node -e "process.stdout.write(process.versions.node.split('.')[0])")
if ($nodeMajor -lt 18) {
    Write-Error "Error: Node.js 18+ is required. Install from https://nodejs.org"
    exit 1
}

# Create install directory
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

# Download plugins
$TmpDir = Join-Path $env:TEMP "movp-install-$(Get-Random)"
New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null

try {
    if ($env:MOVP_RELEASE_URL) {
        Write-Host "Downloading release tarball..."
        $tarPath = Join-Path $TmpDir "release.tar.gz"
        Invoke-WebRequest -Uri $env:MOVP_RELEASE_URL -OutFile $tarPath
        tar -xzf $tarPath -C $TmpDir --strip-components=1
        $Src = $TmpDir
    } else {
        Write-Host "Cloning repository..."
        $cloneArgs = @("clone", "--depth", "1", "--filter=blob:none", "--quiet")
        if ($Version) { $cloneArgs += @("--branch", $Version) }
        $cloneArgs += @($Repo, "$TmpDir\repo")
        & git @cloneArgs
        $Src = "$TmpDir\repo"
    }

    # Determine which plugins to install
    if ($Tool) {
        $Plugins = @("$Tool-plugin")
    } else {
        $Plugins = @("claude-plugin", "codex-plugin", "cursor-plugin")
    }

    foreach ($plugin in $Plugins) {
        $srcPlugin = Join-Path $Src $plugin
        $dstPlugin = Join-Path $Dir $plugin
        if (Test-Path $srcPlugin) {
            if (Test-Path $dstPlugin) { Remove-Item -Recurse -Force $dstPlugin }
            Copy-Item -Recurse $srcPlugin $dstPlugin
        } else {
            Write-Warning "$plugin not found in repository — skipping"
        }
    }

    Write-Host ""
    Write-Host "✓ MoVP plugins installed to $Dir" -ForegroundColor Green
    Write-Host ""

    # Auto-detect installed tools
    $detected = @()
    if (Get-Command claude -ErrorAction SilentlyContinue) { $detected += "claude" }
    if (Get-Command cursor -ErrorAction SilentlyContinue) { $detected += "cursor" }
    if (Get-Command codex  -ErrorAction SilentlyContinue) { $detected += "codex" }
    if ($detected.Count -gt 0) {
        Write-Host "Detected tools: $($detected -join ', ')"
        Write-Host ""
    }

    # Print next steps
    Write-Host "Next steps:" -ForegroundColor White
    Write-Host ""

    function Print-Steps {
        param([string]$ToolName, [string]$Flag, [string]$PluginDir)
        Write-Host "  ${ToolName}:"
        Write-Host "    cd your-project"
        Write-Host "    npx @movp/cli init$Flag"
        Write-Host "    $ToolName --plugin-dir $Dir\$PluginDir"
        Write-Host ""
    }

    if (-not $Tool -or $Tool -eq "claude") { Print-Steps "claude" "" "claude-plugin" }
    if (-not $Tool -or $Tool -eq "cursor") { Print-Steps "cursor" " --cursor" "cursor-plugin" }
    if (-not $Tool -or $Tool -eq "codex")  { Print-Steps "codex"  " --codex"  "codex-plugin" }

    Write-Host "Need help? $Repo#troubleshooting"

} finally {
    Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
}
