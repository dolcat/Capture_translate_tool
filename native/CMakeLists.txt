cmake_minimum_required(VERSION 3.20)
project(lingosnap_backend LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release)
endif()

# Prebuilt dependencies (see tool/build_native.ps1 for the Windows recipe):
#   ONNXRUNTIME_ROOT  unpacked onnxruntime release (include/, lib/)
#   CTranslate2       found through CMAKE_PREFIX_PATH (static build with Ruy)
#   OpenCV            found through CMAKE_PREFIX_PATH (core, imgproc, imgcodecs)
#   LS_THIRD_PARTY    folder with sentencepiece/, httplib/, nlohmann/ checkouts
set(ONNXRUNTIME_ROOT "" CACHE PATH "onnxruntime release directory")
set(LS_THIRD_PARTY "" CACHE PATH "folder with sentencepiece, httplib and nlohmann checkouts")

find_package(OpenCV REQUIRED COMPONENTS core imgproc imgcodecs)
find_package(ctranslate2 CONFIG REQUIRED)

set(SPM_ENABLE_SHARED OFF CACHE BOOL "" FORCE)
set(SPM_BUILD_TEST OFF CACHE BOOL "" FORCE)
add_subdirectory(${LS_THIRD_PARTY}/sp ${CMAKE_BINARY_DIR}/sentencepiece EXCLUDE_FROM_ALL)

find_library(ORT_LIB onnxruntime PATHS ${ONNXRUNTIME_ROOT}/lib NO_DEFAULT_PATH REQUIRED)

add_executable(lingosnap_backend
  src/main.cc src/ocr.cc src/translator.cc src/grammar.cc src/process.cc)
target_include_directories(lingosnap_backend PRIVATE
  ${ONNXRUNTIME_ROOT}/include
  ${LS_THIRD_PARTY}/httplib
  ${LS_THIRD_PARTY}/nlohmann/include
  ${LS_THIRD_PARTY}/sp/src
  ${LS_THIRD_PARTY}/sp)
target_link_libraries(lingosnap_backend PRIVATE
  ${ORT_LIB} ${OpenCV_LIBS} CTranslate2::ctranslate2 sentencepiece-static)
if(WIN32)
  target_compile_definitions(lingosnap_backend PRIVATE _WIN32_WINNT=0x0A00 NOMINMAX)
  target_link_libraries(lingosnap_backend PRIVATE ws2_32)
else()
  find_package(Threads REQUIRED)
  target_link_libraries(lingosnap_backend PRIVATE Threads::Threads)
  set_target_properties(lingosnap_backend PROPERTIES BUILD_RPATH ${ONNXRUNTIME_ROOT}/lib)
endif()
