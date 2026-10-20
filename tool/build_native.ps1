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

# CTranslate2 (shared, Ruy INT8 backend, no MKL) and minimal static OpenCV.
$ct2Src = Get-Source 'https://github.com/OpenNMT/CTranslate2' 'v4.8.1' 'ct2' -Recursive
$ct2Install = Join-Path $deps 'ct2-install'
if (-not (Test-Path $ct2Install)) {
    Invoke-Checked { cmake -S $ct2Src -B (Join-Path $deps 'ct2-build') -A x64 "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" "-DWITH_MKL=OFF" "-DWITH_RUY=ON" "-DOPENMP_RUNTIME=COMP" "-DBUILD_CLI=OFF" "-DBUILD_SHARED_LIBS=ON" "-DCMAKE_INSTALL_PREFIX=$ct2Install" }
    Invoke-Checked { cmake --build (Join-Path $deps 'ct2-build') --config Release -j }
    Invoke-Checked { cmake --install (Join-Path $deps 'ct2-build') --config Release }
}

$cvSrc = Get-Source 'https://github.com/opencv/opencv' '4.13.0' 'opencv'
$cvInstall = Join-Path $deps 'opencv-install'
if (-not (Test-Path $cvInstall)) {
    Invoke-Checked { cmake -S $cvSrc -B (Join-Path $deps 'opencv-build') -A x64 "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" "-DBUILD_SHARED_LIBS=OFF" "-DBUILD_WITH_STATIC_CRT=OFF" "-DBUILD_LIST=core,imgproc,imgcodecs" "-DWITH_FFMPEG=OFF" "-DWITH_OPENCL=OFF" "-DWITH_IPP=OFF" "-DWITH_ITT=OFF" "-DWITH_TIFF=OFF" "-DWITH_WEBP=OFF" "-DWITH_OPENEXR=OFF" "-DWITH_JASPER=OFF" "-DWITH_OPENJPEG=OFF" "-DWITH_PROTOBUF=OFF" "-DBUILD_PROTOBUF=OFF" "-DBUILD_TESTS=OFF" "-DBUILD_PERF_TESTS=OFF" "-DBUILD_EXAMPLES=OFF" "-DBUILD_opencv_apps=OFF" "-DBUILD_DOCS=OFF" "-DCMAKE_INSTALL_PREFIX=$cvInstall" }
    Invoke-Checked { cmake --build (Join-Path $deps 'opencv-build') --config Release -j }
    Invoke-Checked { cmake --install (Join-Path $deps 'opencv-build') --config Release }
}

# Header-only / small libraries, laid out the way native\CMakeLists.txt expects.
Get-Source 'https://github.com/google/sentencepiece' 'v0.2.2' 'sp' | Out-Null
Get-Source 'https://github.com/yhirose/cpp-httplib' 'v0.62.0' 'httplib' | Out-Null
Get-Source 'https://github.com/nlohmann/json' 'v3.12.0' 'nlohmann' | Out-Null

$build = Join-Path $work 'build'
Invoke-Checked { cmake -S (Join-Path $projectRoot 'native') -B $build -A x64 "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" "-DONNXRUNTIME_ROOT=$ort" "-DLS_THIRD_PARTY=$deps" "-DCMAKE_PREFIX_PATH=$ct2Install;$cvInstall" }
Invoke-Checked { cmake --build $build --config Release -j }

Copy-Item (Join-Path $build 'Release\lingosnap_backend.exe') $stage -Force
Copy-Item (Join-Path $ort 'lib\onnxruntime.dll') $stage -Force
Copy-Item (Join-Path $ct2Install 'bin\ctranslate2.dll') $stage -Force
Write-Host "Backend staged in $stage"
