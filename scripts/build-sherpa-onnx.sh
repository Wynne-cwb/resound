#!/usr/bin/env bash
# 重新生成 Vendor/sherpa-onnx/ 下的静态库（派生物，不进 git）。
# 为 macOS arm64 构建 sherpa-onnx 纯静态 C API 库（仅声纹，裁掉 TTS），
# 合并成单个 libsherpa-onnx.a，连同独立的 libonnxruntime.a 一起 vendor 进仓库。
#
# 用法：scripts/build-sherpa-onnx.sh
# 产物：Vendor/sherpa-onnx/{include/sherpa-onnx/..., lib/libsherpa-onnx.a, lib/libonnxruntime.a}
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC=/tmp/sherpa-onnx-build
VENDOR="$REPO/Vendor/sherpa-onnx"

rm -rf "$SRC"
git clone --depth 1 https://github.com/k2-fsa/sherpa-onnx "$SRC"
cd "$SRC" && mkdir -p build-static && cd build-static

cmake \
  -DSHERPA_ONNX_ENABLE_BINARY=OFF \
  -DSHERPA_ONNX_BUILD_C_API_EXAMPLES=OFF \
  -DCMAKE_OSX_ARCHITECTURES="arm64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_INSTALL_PREFIX=./install \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
  -DSHERPA_ONNX_ENABLE_TESTS=OFF \
  -DSHERPA_ONNX_ENABLE_CHECK=OFF \
  -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
  -DSHERPA_ONNX_ENABLE_JNI=OFF \
  -DSHERPA_ONNX_ENABLE_C_API=ON \
  -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
  -DSHERPA_ONNX_ENABLE_TTS=OFF \
  ../
make -j8
make install

# 合并除 onnxruntime 外的所有静态库
libtool -static -o install/lib/libsherpa-onnx.a $(ls install/lib/*.a | grep -v onnxruntime)

mkdir -p "$VENDOR/include" "$VENDOR/lib"
cp -R install/include/sherpa-onnx "$VENDOR/include/"
cp install/lib/libsherpa-onnx.a "$VENDOR/lib/"
# onnxruntime 静态库可能在 install/lib 或 _deps 下
ORT=$(find . -name "libonnxruntime.a" | head -1)
cp "$ORT" "$VENDOR/lib/"

echo "✅ vendored:"
ls -la "$VENDOR/lib/"*.a
rm -rf "$SRC"
