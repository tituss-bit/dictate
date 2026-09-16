#!/bin/zsh
# Fetch and build everything the app bundles: a static whisper-server (Metal, no dylibs)
# and the quantized large-v3-turbo model. Re-runnable; skips what's already there.
set -euo pipefail
cd "$(dirname "$0")/.."
WHISPER_TAG=v1.9.2
MODEL=ggml-large-v3-turbo-q5_0.bin
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL"

mkdir -p vendor/models
if [[ ! -x vendor/whisper.cpp/build/bin/whisper-server ]]; then
  [[ -d vendor/whisper.cpp ]] || git clone --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp.git vendor/whisper.cpp
  cmake -S vendor/whisper.cpp -B vendor/whisper.cpp/build \
    -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON -DWHISPER_SDL2=OFF -DWHISPER_FFMPEG=OFF \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
  cmake --build vendor/whisper.cpp/build --config Release --target whisper-server -j "$(sysctl -n hw.ncpu)"
fi
if [[ ! -f vendor/models/$MODEL ]]; then
  curl -L --progress-bar -o "vendor/models/$MODEL" "$MODEL_URL"
fi
echo "vendor ready: $(du -h vendor/whisper.cpp/build/bin/whisper-server | cut -f1) server, $(du -h vendor/models/$MODEL | cut -f1) model"
