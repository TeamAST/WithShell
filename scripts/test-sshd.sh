#!/bin/zsh
# 개발용 테스트 SSH 서버 (Docker). localhost:2222 에서만 열린다.
# 아래 계정은 이 컨테이너 전용 테스트 값이다.
set -euo pipefail

export WITHSHELL_TEST_SSH_HOST=127.0.0.1
export WITHSHELL_TEST_SSH_PORT=2222
export WITHSHELL_TEST_SSH_USER=withshell
export WITHSHELL_TEST_SSH_PASSWORD=withshell-test-pw

case "${1:-up}" in
  up)
    docker rm -f withshell-test-sshd >/dev/null 2>&1 || true
    docker run -d --name withshell-test-sshd \
      -p 127.0.0.1:${WITHSHELL_TEST_SSH_PORT}:2222 \
      -e PASSWORD_ACCESS=true \
      -e USER_NAME=${WITHSHELL_TEST_SSH_USER} \
      -e USER_PASSWORD=${WITHSHELL_TEST_SSH_PASSWORD} \
      -e PUBLIC_KEY_DIR=/pubkeys \
      -v "$(cd "$(dirname "$0")/.." && pwd)/WithShellTests/Fixtures/authorized:/pubkeys:ro" \
      lscr.io/linuxserver/openssh-server:latest >/dev/null
    echo "테스트 SSH 서버 시작: ${WITHSHELL_TEST_SSH_USER}@${WITHSHELL_TEST_SSH_HOST}:${WITHSHELL_TEST_SSH_PORT}"
    ;;
  down)
    docker rm -f withshell-test-sshd
    ;;
  test)
    # 통합 테스트 실행 (서버가 떠 있어야 함)
    cd "$(dirname "$0")/.."
    TEST_RUNNER_WITHSHELL_TEST_SSH_HOST=$WITHSHELL_TEST_SSH_HOST \
    TEST_RUNNER_WITHSHELL_TEST_SSH_PORT=$WITHSHELL_TEST_SSH_PORT \
    TEST_RUNNER_WITHSHELL_TEST_SSH_USER=$WITHSHELL_TEST_SSH_USER \
    TEST_RUNNER_WITHSHELL_TEST_SSH_PASSWORD=$WITHSHELL_TEST_SSH_PASSWORD \
    xcodebuild test -project WithShell.xcodeproj -scheme WithShell \
      -derivedDataPath build/DerivedData -skipPackagePluginValidation -skipMacroValidation
    ;;
esac
