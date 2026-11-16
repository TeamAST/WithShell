#!/bin/zsh
# FreeRDP를 WithShell에 넣을 정적 라이브러리로 빌드한다.
# 결과: ThirdParty/FreeRDP/{include,lib}
# 필요: brew install cmake ninja pkg-config
# OpenSSL도 같은 최소 macOS 버전(15.0)으로 직접 빌드한다 (Homebrew 판은 설치된 OS 버전용).
set -euo pipefail

FREERDP_VERSION=3.33.1
OPENSSL_VERSION=3.5.9
MACOS_MIN=15.0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/freerdp/src"
BUILD="$ROOT/build/freerdp/build"
PREFIX="$ROOT/ThirdParty/FreeRDP"
OPENSSL_SRC="$ROOT/build/openssl/src"
OPENSSL="$ROOT/build/openssl/install"

if [[ ! -f "$OPENSSL/lib/libcrypto.a" ]]; then
  [[ -d "$OPENSSL_SRC" ]] || git clone --depth 1 --branch "openssl-$OPENSSL_VERSION" https://github.com/openssl/openssl.git "$OPENSSL_SRC"
  (
    cd "$OPENSSL_SRC"
    ./Configure darwin64-arm64-cc no-shared no-tests no-docs no-apps \
      -mmacosx-version-min=$MACOS_MIN --prefix="$OPENSSL" --libdir=lib
    make -j"$(sysctl -n hw.ncpu)"
    make install_sw
  )
fi

if [[ ! -d "$SRC" ]]; then
  git clone --depth 1 --branch "$FREERDP_VERSION" https://github.com/FreeRDP/FreeRDP.git "$SRC"
fi

cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTING=OFF \
  -DWITH_CLIENT_COMMON=ON \
  -DWITH_CLIENT=OFF \
  -DWITH_CLIENT_SDL=OFF \
  -DWITH_CLIENT_MAC=OFF \
  -DWITH_SERVER=OFF \
  -DWITH_SAMPLE=OFF \
  -DWITH_SHADOW=OFF \
  -DWITH_PROXY=OFF \
  -DWITH_PLATFORM_SERVER=OFF \
  -DWITH_WINPR_TOOLS=OFF \
  -DWITH_MANPAGES=OFF \
  -DWITH_X11=OFF \
  -DWITH_WAYLAND=OFF \
  -DWITH_FFMPEG=OFF \
  -DWITH_SWSCALE=OFF \
  -DWITH_DSP_FFMPEG=OFF \
  -DWITH_OPENH264=OFF \
  -DWITH_CAIRO=OFF \
  -DWITH_JPEG=OFF \
  -DWITH_CUPS=OFF \
  -DWITH_PCSC=OFF \
  -DWITH_SMARTCARD_EMULATE=OFF \
  -DWITH_KRB5=OFF \
  -DWITH_FUSE=OFF \
  -DWITH_PULSE=OFF \
  -DWITH_OSS=OFF \
  -DWITH_ALSA=OFF \
  -DWITH_FAAD2=OFF \
  -DWITH_FAAC=OFF \
  -DWITH_SOXR=OFF \
  -DWITH_LAME=OFF \
  -DWITH_OPUS=OFF \
  -DWITH_WEBVIEW=OFF \
  -DWITH_AAD=OFF \
  -DWITH_JSON_DISABLED=ON \
  -DWITH_URIPARSER=OFF \
  -DWITH_SIMD=ON \
  -DWITH_VERBOSE_WINPR_ASSERT=OFF \
  -DCHANNEL_URBDRC=OFF \
  -DBUILTIN_CHANNELS=ON \
  -DOPENSSL_ROOT_DIR="$OPENSSL" \
  -DOPENSSL_USE_STATIC_LIBS=TRUE

cmake --build "$BUILD"
cmake --install "$BUILD"

# OpenSSL 정적 라이브러리도 함께 둔다
install -m 644 "$OPENSSL/lib/libssl.a" "$OPENSSL/lib/libcrypto.a" "$PREFIX/lib/"
# PEM 키 가져오기(WSPEMKey.c)가 OpenSSL 헤더를 쓴다
rm -rf "$PREFIX/include/openssl"
cp -R "$OPENSSL/include/openssl" "$PREFIX/include/openssl"
echo "FreeRDP $FREERDP_VERSION 설치 완료: $PREFIX"
