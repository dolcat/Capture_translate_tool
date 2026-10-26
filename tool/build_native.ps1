# Builds backend\lingosnap_backend.exe (OCR + translation, no Python) into
# build\native\stage. Needs Visual Studio 2022 (Desktop C++), CMake, Git.
param([string]$OnnxRuntimeVersion = '1.28.0')

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$work = Join-Path $projectRoot 'build\native'
$deps = Join-Path $work 'deps'
$stage = Join-Path $work 'stage'
New-Item -ItemType Directory -Path $deps, $stage -Force | Out-Null

function Invoke-Checked { param([scriptblock]$Command) & $Command; if ($LASTEXITCODE -ne 0) { throw "Command failed: $Command" } }
function Get-Source {
    param([string]$Url, [string]$Tag, [string]$Name, [switch]$Recursive)
    $path = Join-Path $deps $Name
    if (-not (Test-Path $path)) {
        $extra = if ($Recursive) { @('--recurse-submodules', '--shallow-submodules') } else { @() }
        Invoke-Checked { git clone --depth 1 --branch $Tag @extra $Url $path }
    }
    return $path
}

# Prebuilt ONNX Runtime.
$ort = Join-Path $deps "onnxruntime-win-x64-$OnnxRuntimeVersion"
if (-not (Test-Path $ort)) {
    $zip = Join-Path $deps 'ort.zip'
    Invoke-WebRequest "https://github.com/microsoft/onnxruntime/releases/download/v$OnnxRuntimeVersion/onnxruntime-win-x64-$OnnxRuntimeVersion.zip" -OutFile $zip
    Expand-Archive $zip -DestinationPath $deps -Force
}

# CTranslate2 headers and import library (shared, Ruy backend, no MKL needed to build), and
# minimal static OpenCV. The ctranslate2.dll shipped at run time comes from the wheel below.
$ct2Version = '4.8.3'
$ct2Src = Get-Source 'https://github.com/OpenNMT/CTranslate2' "v$ct2Version" "ct2-$ct2Version" -Recursive
$ct2Build = Join-Path $deps "ct2-$ct2Version-build"
$ct2Install = Join-Path $deps "ct2-$ct2Version-install"
if (-not (Test-Path $ct2Install)) {
    Invoke-Checked { cmake -S $ct2Src -B $ct2Build -A x64 "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" "-DWITH_MKL=OFF" "-DWITH_RUY=ON" "-DOPENMP_RUNTIME=COMP" "-DBUILD_CLI=OFF" "-DBUILD_SHARED_LIBS=ON" "-DCMAKE_INSTALL_PREFIX=$ct2Install" }
    Invoke-Checked { cmake --build $ct2Build --config Release -j }
    Invoke-Checked { cmake --install $ct2Build --config Release }
}

# CTranslate2 runtime: the official Windows wheel of the same version (same headers, same ABI)
# has ctranslate2.dll built with Intel MKL, about 5x faster for INT8 on x86 than the Ruy build.
# MKL is linked into the dll (Intel Simplified Software License) and libiomp5md.dll is Intel's
# OpenMP runtime; both are redistributable. Makes the backend about 54 MB larger.
$ct2Wheel = Join-Path $deps "ctranslate2-$ct2Version-wheel"
if (-not (Test-Path (Join-Path $ct2Wheel 'ctranslate2\ctranslate2.dll'))) {
    $zip = Join-Path $deps "ctranslate2-$ct2Version-win_amd64.zip"
    Invoke-WebRequest 'https://files.pythonhosted.org/packages/b9/0d/217ea887dbc6feea8954620a020ba674cb5fd0bf17961a44a8b22602c8e4/ctranslate2-4.8.3-cp311-cp311-win_amd64.whl' -OutFile $zip
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne '6833B81FD7C86CB30C4A263033F4B60127F925120CC416EBEEB4C58ECBA1F58B') {
        Remove-Item -LiteralPath $zip -Force
        throw 'SHA256 mismatch for the CTranslate2 wheel'
    }
    Expand-Archive $zip -DestinationPath $ct2Wheel -Force
}

$cvSrc = Get-Source 'https://github.com/opencv/opencv' '4.13.0' 'opencv'
$cvInstall = Join-Path $deps 'opencv-install'
if (-not (Test-Path $cvInstall)) {
    Invoke-Checked { cmake -S $cvSrc -B (Join-Path $deps 'opencv-build') -A x64 "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" "-DBUILD_SHARED_LIBS=OFF" "-DBUILD_WITH_STATIC_CRT=OFF" "-DBUILD_LIST=core,imgproc,imgcodecs" "-DWITH_FFMPEG=OFF" "-DWITH_OPENCL=OFF" "-DWITH_IPP=OFF" "-DWITH_ITT=OFF" "-DWITH_TIFF=OFF" "-DWITH_WEBP=OFF" "-DWITH_OPENEXR=OFF" "-DWITH_JASPER=OFF" "-DWITH_OPENJPEG=OFF" "-DWITH_PROTOBUF=OFF" "-DBUILD_PROTOBUF=OFF" "-DWITH_ADE=OFF" "-DBUILD_opencv_gapi=OFF" "-DBUILD_TESTS=OFF" "-DBUILD_PERF_TESTS=OFF" "-DBUILD_EXAMPLES=OFF" "-DBUILD_opencv_apps=OFF" "-DBUILD_DOCS=OFF" "-DCMAKE_INSTALL_PREFIX=$cvInstall" }
    Invoke-Checked { cmake --build (Join-Path $deps 'opencv-build') --config Release -j }
    Invoke-Checked { cmake --install (Join-Path $deps 'opencv-build') --config Release }
}

# Header-only / small libraries, laid out the way native\CMakeLists.txt expects.
Get-Source 'https://github.com/google/sentencepiece' 'v0.2.0' 'sp' | Out-Null
Get-Source 'https://github.com/yhirose/cpp-httplib' 'v0.62.0' 'httplib' | Out-Null
Get-Source 'https://github.com/nlohmann/json' 'v3.12.0' 'nlohmann' | Out-Null

# On Windows the static OpenCV package lives in x64\vcNN\staticlib; point CMake straight at it.
$cvConfig = Get-ChildItem -LiteralPath $cvInstall -Recurse -Filter OpenCVConfig.cmake |
    Where-Object { $_.FullName -match 'staticlib' } | Select-Object -First 1
if (-not $cvConfig) { throw "OpenCV static package not found under $cvInstall" }
$cvDir = $cvConfig.Directory.FullName

$build = Join-Path $work 'build'
Invoke-Checked { cmake -S (Join-Path $projectRoot 'native') -B $build -A x64 "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" "-DONNXRUNTIME_ROOT=$ort" "-DLS_THIRD_PARTY=$deps" "-DOpenCV_DIR=$cvDir" "-DCMAKE_PREFIX_PATH=$ct2Install" "-Dctranslate2_DIR=$ct2Install\lib\cmake\ctranslate2" }
Invoke-Checked { cmake --build $build --config Release -j }

# A backend left running by the app locks the staged files.
$stagedExe = Join-Path $stage 'lingosnap_backend.exe'
Get-Process lingosnap_backend -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $stagedExe } |
    ForEach-Object { Write-Host "Stopping running backend (PID $($_.Id))"; $_ | Stop-Process -Force; $_.WaitForExit(5000) | Out-Null }

Copy-Item (Join-Path $build 'Release\lingosnap_backend.exe') $stage -Force
Copy-Item (Join-Path $ort 'lib\onnxruntime.dll') $stage -Force
Copy-Item (Join-Path $ct2Wheel 'ctranslate2\ctranslate2.dll') $stage -Force
Copy-Item (Join-Path $ct2Wheel 'ctranslate2\libiomp5md.dll') $stage -Force
Write-Host "Backend staged in $stage"
