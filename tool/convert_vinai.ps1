# One-time conversion of VinAI Translate en2vi v2 (mBART, better English -> Vietnamese than
# Argos) to a CTranslate2 INT8 model in backend\models\vinai-en-vi. The backend uses it
# automatically when present and falls back to Argos otherwise. Release builds and the portable
# ZIP do not ship it; for an installed copy pass -ModelsDir <LingoSnap>\data\backend\models.
#
# Python 3.9+ is needed for this step only (the backend itself stays C++). The script makes a
# throwaway virtualenv in %TEMP% (about 1 GB, removed at the end unless -KeepEnv) and Hugging Face
# caches the 1.7 GB original model in %USERPROFILE%\.cache\huggingface.
#
# License: the VinAI model is AGPL-3.0 (https://huggingface.co/vinai/vinai-translate-en2vi-v2).
# Distributing it together with the app has to follow the AGPL terms.
param([string]$ModelsDir = '', [switch]$KeepEnv)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $ModelsDir) { $ModelsDir = Join-Path $projectRoot 'backend\models' }
New-Item -ItemType Directory -Path $ModelsDir -Force | Out-Null

function Invoke-Checked { param([scriptblock]$Command) & $Command; if ($LASTEXITCODE -ne 0) { throw "Command failed: $Command" } }

$venv = Join-Path ([IO.Path]::GetTempPath()) 'lingosnap-vinai-venv'
$venvPython = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path $venvPython)) {
    Write-Host "Creating Python environment in $venv"
    if (Get-Command py -ErrorAction SilentlyContinue) { Invoke-Checked { py -3 -m venv $venv } }
    elseif (Get-Command python -ErrorAction SilentlyContinue) { Invoke-Checked { python -m venv $venv } }
    else { throw 'Python 3 was not found. Install it from https://www.python.org (only needed for this conversion).' }
}
Invoke-Checked { & $venvPython -m pip install --quiet --upgrade pip }
Invoke-Checked { & $venvPython -m pip install --quiet torch --index-url https://download.pytorch.org/whl/cpu }
# transformers 5 cannot read this model's SentencePiece-only tokenizer, so stay on 4.x.
Invoke-Checked { & $venvPython -m pip install --quiet 'transformers==4.57.6' 'ctranslate2==4.8.3' sentencepiece protobuf }

Invoke-Checked { & $venvPython -X utf8 (Join-Path $PSScriptRoot 'convert_vinai.py') $ModelsDir }

if (-not $KeepEnv) { Remove-Item -LiteralPath $venv -Recurse -Force }
