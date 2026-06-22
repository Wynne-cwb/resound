// 伞头文件：把 sherpa-onnx 的 C API 暴露给 Swift。
// 真正的头文件在仓库的 Vendor/sherpa-onnx/include/ 下（构建产物，由 scripts/build-sherpa-onnx.sh 生成）。
// CSherpaOnnx target 的 cSettings 用 -I Vendor/sherpa-onnx/include 让编译器找到它。
#include "sherpa-onnx/c-api/c-api.h"
