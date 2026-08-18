$ErrorActionPreference = 'Stop'
$backendRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$requirements = Join-Path $backendRoot 'requirements.txt'
$modelSetup = Join-Path $backendRoot 'setup_models.py'

if (-not (Get-Command java.exe -ErrorAction SilentlyContinue)) {
    throw 'LanguageTool local requires Java 17. Install Java 17, then run this script again.'
}

python -m pip install --user --upgrade -r $requirements
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

python $modelSetup
exit $LASTEXITCODE
