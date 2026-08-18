param(
    [string]$PythonVersion = '3.11.9',
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
$requirements = Join-Path $projectRoot 'backend\requirements-portable.txt'

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

$pythonArchive = Join-Path $cacheRoot "python-$PythonVersion-embed-amd64.zip"
$pythonUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
if (-not (Test-Path -LiteralPath $pythonArchive)) {
    Write-Host "Downloading Python Embedded $PythonVersion..."
    Invoke-WebRequest -Uri $pythonUrl -OutFile $pythonArchive
}

$backendRoot = Join-Path $stageRoot 'data\backend'
$pythonRoot = Join-Path $backendRoot 'python'
$javaRoot = Join-Path $backendRoot 'java'
Assert-ChildPath -Path $pythonRoot -Parent $stageRoot
if (Test-Path -LiteralPath $pythonRoot) {
    Remove-Item -LiteralPath $pythonRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $pythonRoot | Out-Null
Expand-Archive -LiteralPath $pythonArchive -DestinationPath $pythonRoot -Force

if (-not $JavaHome) {
    if ($env:JAVA_HOME) {
        $JavaHome = $env:JAVA_HOME
    }
    else {
        $javaCommand = Get-Command java.exe -ErrorAction SilentlyContinue
        if ($javaCommand) {
            $javaSettings = (& $javaCommand.Source -XshowSettings:properties -version 2>&1 | Out-String)
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

$pythonMinor = ($PythonVersion.Split('.')[0..1] -join '')
$pthFile = Join-Path $pythonRoot "python$pythonMinor._pth"
@(
    "python$pythonMinor.zip"
    '.'
    'Lib\site-packages'
    'import site'
) | Set-Content -LiteralPath $pthFile -Encoding ASCII

$sitePackages = Join-Path $pythonRoot 'Lib\site-packages'
New-Item -ItemType Directory -Path $sitePackages -Force | Out-Null
Write-Host 'Installing backend packages into the embedded runtime...'
python -m pip install `
    --disable-pip-version-check `
    --upgrade `
    --ignore-installed `
    --no-compile `
    --target $sitePackages `
    -r $requirements
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# The RapidOCR wheel includes larger default PP-OCRv6 models. LingoSnap uses
# its own PP-OCRv5 mobile files under data\backend\models, so remove duplicates.
$rapidOcrBundledModels = Join-Path $sitePackages 'rapidocr\models'
if (Test-Path -LiteralPath $rapidOcrBundledModels) {
    foreach ($model in Get-ChildItem -LiteralPath $rapidOcrBundledModels -Filter '*.onnx' -File) {
        Remove-Item -LiteralPath $model.FullName -Force
    }
}

foreach ($obsoletePath in @(
    (Join-Path $sitePackages 'paddle'),
    (Join-Path $sitePackages 'paddleocr'),
    (Join-Path $stageRoot 'data\backend\models\paddleocr')
)) {
    if (Test-Path -LiteralPath $obsoletePath) {
        throw "Obsolete Paddle content found in portable package: $obsoletePath"
    }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'vswhere.exe was not found. Visual Studio Desktop development with C++ is required.'
}
$visualStudio = & $vswhere -latest -products * -property installationPath
$redistRoot = Join-Path $visualStudio 'VC\Redist\MSVC'
$crtDirectory = Get-ChildItem -LiteralPath $redistRoot -Directory |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'x64\Microsoft.VC143.CRT' } |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1
if (-not $crtDirectory) {
    throw 'Microsoft VC143 x64 redistributable DLLs were not found.'
}
Write-Host 'Bundling Microsoft Visual C++ runtime DLLs...'
Copy-Item -Path (Join-Path $crtDirectory '*.dll') -Destination $stageRoot -Force
Copy-Item -Path (Join-Path $crtDirectory '*.dll') -Destination $pythonRoot -Force

$embeddedPython = Join-Path $pythonRoot 'python.exe'
$env:PYTHONUTF8 = '1'
$env:LTP_PATH = Join-Path $backendRoot 'models\languagetool'
$env:PATH = (Join-Path $javaRoot 'bin') + ';' + $env:PATH
Push-Location $backendRoot
try {
    & $embeddedPython -c "import sys; sys.path.insert(0, '.'); import ctranslate2, sentencepiece, fastapi, uvicorn, onnxruntime, rapidocr, language_tool_python; from server import engines; engines.ensure_ready(); assert engines.translate('Hello world!'); result = engines.check_grammar('This are wrong.', 'en-US'); assert result['corrected'] != 'This are wrong.'; engines.close()"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
finally {
    Pop-Location
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
