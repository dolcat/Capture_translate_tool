param(
    [string]$JavaHome = '',
    [switch]$SkipFlutterBuild
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$releaseRoot = Join-Path $projectRoot 'build\windows\x64\runner\Release'
$portableRoot = Join-Path $projectRoot 'build\portable'
$stageRoot = Join-Path $portableRoot 'LingoSnap'
$cacheRoot = Join-Path $portableRoot 'cache'
$zipPath = Join-Path $portableRoot 'LingoSnap-windows-x64.zip'

function Assert-ChildPath {
    param([string]$Path, [string]$Parent)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullParent = [IO.Path]::GetFullPath($Parent).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not $fullPath.StartsWith($fullParent + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Unsafe build path: $fullPath"
    }
}

if (-not $SkipFlutterBuild) {
    Push-Location $projectRoot
    try {
        flutter build windows
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    finally {
        Pop-Location
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $releaseRoot 'capture_translate_tool.exe'))) {
    throw 'Windows Release build was not found. Run without -SkipFlutterBuild first.'
}

New-Item -ItemType Directory -Path $portableRoot -Force | Out-Null
New-Item -ItemType Directory -Path $cacheRoot -Force | Out-Null
Assert-ChildPath -Path $stageRoot -Parent $portableRoot
if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $stageRoot | Out-Null
Copy-Item -Path (Join-Path $releaseRoot '*') -Destination $stageRoot -Recurse -Force

$backendRoot = Join-Path $stageRoot 'data\backend'
$javaRoot = Join-Path $backendRoot 'java'

if (-not $JavaHome) {
    if ($env:JAVA_HOME) {
        $JavaHome = $env:JAVA_HOME
    }
    else {
        $javaCommand = Get-Command java.exe -ErrorAction SilentlyContinue
        if ($javaCommand) {
            # java prints settings to stderr; with 'Stop' PowerShell 5.1 would treat that as an error.
            $ErrorActionPreference = 'Continue'
            $javaSettings = (& $javaCommand.Source -XshowSettings:properties -version 2>&1 | Out-String)
            $ErrorActionPreference = 'Stop'
            $javaHomeMatch = [regex]::Match($javaSettings, '(?m)^\s*java\.home\s*=\s*(.+?)\s*$')
            if ($javaHomeMatch.Success) {
                $JavaHome = $javaHomeMatch.Groups[1].Value
            }
        }
    }
}
if (-not $JavaHome -or -not (Test-Path -LiteralPath (Join-Path $JavaHome 'bin\java.exe'))) {
    throw 'Java 17 was not found. Install Java 17 or pass -JavaHome with a Java 17 runtime path.'
}
$JavaHome = (Resolve-Path -LiteralPath $JavaHome).Path
Assert-ChildPath -Path $javaRoot -Parent $stageRoot
if (Test-Path -LiteralPath $javaRoot) {
    Remove-Item -LiteralPath $javaRoot -Recurse -Force
}
Write-Host 'Bundling Java runtime for LanguageTool...'
Copy-Item -LiteralPath $JavaHome -Destination $javaRoot -Recurse -Force

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'vswhere.exe was not found. Visual Studio Desktop development with C++ is required.'
}
$visualStudio = & $vswhere -latest -products * -property installationPath
$redistRoot = Join-Path $visualStudio 'VC\Redist\MSVC'
$crtDirectory = Get-ChildItem -LiteralPath $redistRoot -Directory |
    Sort-Object Name -Descending |
    ForEach-Object { Get-ChildItem -Path (Join-Path $_.FullName 'x64') -Directory -Filter 'Microsoft.VC14?.CRT' -ErrorAction SilentlyContinue } |
    Sort-Object Name -Descending |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $crtDirectory) {
    throw 'Microsoft VC14x x64 redistributable DLLs were not found.'
}
Write-Host 'Bundling Microsoft Visual C++ runtime DLLs...'
# onnxruntime.dll needs a recent CRT; an older redist (e.g. VS 2019's 14.29) makes the backend
# exit on start, so use the installed system copy whenever it is newer.
$system32 = Join-Path $env:SystemRoot 'System32'
foreach ($dll in Get-ChildItem -Path (Join-Path $crtDirectory '*.dll')) {
    $source = $dll.FullName
    $systemDll = Join-Path $system32 $dll.Name
    if ((Test-Path -LiteralPath $systemDll) -and
        ([version](Get-Item -LiteralPath $systemDll).VersionInfo.ProductVersion -gt [version]$dll.VersionInfo.ProductVersion)) {
        $source = $systemDll
    }
    Copy-Item -LiteralPath $source -Destination $stageRoot -Force
    Copy-Item -LiteralPath $source -Destination $backendRoot -Force
}

# Smoke test: start the backend, check translation, then stop it.
$backendExe = Join-Path $backendRoot 'lingosnap_backend.exe'
if (-not (Test-Path -LiteralPath $backendExe)) { throw 'lingosnap_backend.exe is missing. Run tool\build_native.ps1 first.' }
$probe = Start-Process -FilePath $backendExe -ArgumentList '--port', '8791' -WorkingDirectory $backendRoot -PassThru -WindowStyle Hidden
try {
    $body = '{"text":"Hello world!","sourceLanguage":"en","targetLanguage":"vi"}'
    $translated = $null
    for ($i = 0; $i -lt 60 -and -not $translated; $i++) {
        Start-Sleep -Milliseconds 500
        try { $translated = (Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8791/translate' -ContentType 'application/json' -Body $body).translated } catch { }
    }
    if (-not $translated) { throw 'Backend smoke test failed: no translation returned.' }
    $grammar = Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8791/grammar' -ContentType 'application/json' -Body '{"text":"This are wrong.","language":"en-US"}'
    if ($grammar.corrected -eq 'This are wrong.') { throw 'Backend smoke test failed: grammar not corrected.' }
}
finally {
    if (-not $probe.HasExited) { Stop-Process -Id $probe.Id -Force }
}

Assert-ChildPath -Path $zipPath -Parent $portableRoot
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Write-Host 'Creating portable ZIP...'
Compress-Archive -LiteralPath $stageRoot -DestinationPath $zipPath -CompressionLevel Optimal

$archive = Get-Item -LiteralPath $zipPath
$hash = Get-FileHash -LiteralPath $zipPath -Algorithm SHA256
Write-Host "Portable package: $($archive.FullName)"
Write-Host ("Size: {0:N1} MB" -f ($archive.Length / 1MB))
Write-Host "SHA256: $($hash.Hash)"
