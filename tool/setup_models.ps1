# Downloads the offline models into backend\models (no Python needed).
param([string]$ModelsDir = '')

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $ModelsDir) { $ModelsDir = Join-Path $projectRoot 'backend\models' }
New-Item -ItemType Directory -Path $ModelsDir -Force | Out-Null
$temp = Join-Path ([IO.Path]::GetTempPath()) 'lingosnap-models'
New-Item -ItemType Directory -Path $temp -Force | Out-Null

function Get-Model {
    param([string]$Url, [string]$Destination, [string]$Sha256 = '')
    if (Test-Path -LiteralPath $Destination) {
        if (-not $Sha256 -or (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -eq $Sha256.ToUpper()) { return }
    }
    Write-Host "Downloading $Url"
    New-Item -ItemType Directory -Path (Split-Path $Destination) -Force | Out-Null
    Invoke-WebRequest -Uri $Url -OutFile $Destination
    if ($Sha256 -and (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash -ne $Sha256.ToUpper()) {
        Remove-Item -LiteralPath $Destination -Force
        throw "SHA256 mismatch for $Url"
    }
}

# OCR: PP-OCRv5 mobile detection + English recognition (ONNX, from RapidOCR v3.9.2).
$ocrBase = 'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.2/onnx/PP-OCRv5'
Get-Model "$ocrBase/det/ch_PP-OCRv5_det_mobile.onnx" (Join-Path $ModelsDir 'rapidocr\ch_PP-OCRv5_det_mobile.onnx') '4d97c44a20d30a81aad087d6a396b08f786c4635742afc391f6621f5c6ae78ae'
Get-Model "$ocrBase/rec/en_PP-OCRv5_rec_mobile.onnx" (Join-Path $ModelsDir 'rapidocr\en_PP-OCRv5_rec_mobile.onnx') 'c3461add59bb4323ecba96a492ab75e06dda42467c9e3d0c18db5d1d21924be8'

# Translation: Argos English -> Vietnamese (CTranslate2 model + SentencePiece).
$mtDir = Join-Path $ModelsDir 'argos-en-vi'
if (-not (Test-Path (Join-Path $mtDir 'model\model.bin'))) {
    $archive = Join-Path $temp 'translate-en_vi-1_9.zip'
    Get-Model 'https://argos-net.com/v1/translate-en_vi-1_9.argosmodel' $archive
    $extract = Join-Path $temp 'argos'
    if (Test-Path $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
    Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
    $package = Join-Path $extract 'translate-en_vi-1_9'
    if (-not (Test-Path (Join-Path $package 'model\model.bin'))) { throw 'Unexpected Argos package layout.' }
    if (Test-Path $mtDir) { Remove-Item -LiteralPath $mtDir -Recurse -Force }
    Copy-Item -LiteralPath $package -Destination $mtDir -Recurse
}

# Grammar: LanguageTool 6.8 (needs Java 17 at run time).
$ltJar = Join-Path $ModelsDir 'languagetool\LanguageTool-6.8\languagetool-server.jar'
if (-not (Test-Path $ltJar)) {
    $archive = Join-Path $temp 'LanguageTool-6.8.zip'
    Get-Model 'https://github.com/jxmorris12/language_tool_python/releases/download/LanguageTool-6.8/LanguageTool-6.8.zip' $archive
    Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $ModelsDir 'languagetool') -Force
}

Write-Host "Models are ready: $ModelsDir"
