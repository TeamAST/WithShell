#!/bin/zsh
# 개발용 테스트 RDP 서버 (Docker, xrdp + XFCE). localhost:3390 에서만 열린다.
# 계정은 이미지 기본 테스트 계정이다.
set -euo pipefail

export WITHSHELL_TEST_RDP_HOST=127.0.0.1
export WITHSHELL_TEST_RDP_PORT=3390
export WITHSHELL_TEST_RDP_USER=ubuntu
export WITHSHELL_TEST_RDP_PASSWORD=ubuntu

case "${1:-up}" in
  up)
    docker rm -f withshell-test-rdp >/dev/null 2>&1 || true
    docker run -d --name withshell-test-rdp --shm-size=1g \
      -p 127.0.0.1:${WITHSHELL_TEST_RDP_PORT}:3389 \
      scottyhardy/docker-remote-desktop:latest >/dev/null
    # 클립보드 테스트용 (원격 X 세션의 클립보드를 읽고 쓰기)
    docker exec withshell-test-rdp sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xclip' >/dev/null 2>&1 || true
    echo "테스트 RDP 서버 시작: ${WITHSHELL_TEST_RDP_USER}@${WITHSHELL_TEST_RDP_HOST}:${WITHSHELL_TEST_RDP_PORT}"
    ;;
  down)
    docker rm -f withshell-test-rdp
    ;;
  test)
    cd "$(dirname "$0")/.."
    TEST_RUNNER_WITHSHELL_TEST_RDP_HOST=$WITHSHELL_TEST_RDP_HOST \
    TEST_RUNNER_WITHSHELL_TEST_RDP_PORT=$WITHSHELL_TEST_RDP_PORT \
    TEST_RUNNER_WITHSHELL_TEST_RDP_USER=$WITHSHELL_TEST_RDP_USER \
    TEST_RUNNER_WITHSHELL_TEST_RDP_PASSWORD=$WITHSHELL_TEST_RDP_PASSWORD \
    TEST_RUNNER_WITHSHELL_TEST_RDP_CLIPBOARD=1 \
    TEST_RUNNER_WLOG_APPENDER=CONSOLE \
    xcodebuild test -project WithShell.xcodeproj -scheme WithShell \
      -derivedDataPath build/DerivedData -skipPackagePluginValidation -skipMacroValidation \
      -only-testing:WithShellTests/RDPConnectionTests &
    TEST_PID=$!

    # 클립보드 테스트와 파일로 신호를 주고받는다 (테스트는 샌드박스라 docker 를 직접 못 부른다)
    SIGNAL="$HOME/Library/Containers/com.teamast.withshell/Data/tmp"
    rm -f "$SIGNAL"/clip-*.txt(N)
    XRUN=(docker exec -u ubuntu -e DISPLAY=:10 withshell-test-rdp)
    for i in $(seq 1 120); do
      if [[ -f "$SIGNAL/clip-request.txt" ]]; then
        # Mac → 원격: 원격 X 클립보드에서 읽어 돌려준다
        "${XRUN[@]}" timeout 10 xclip -selection clipboard -o > "$SIGNAL/clip-response.tmp" 2>/dev/null || true
        mv "$SIGNAL/clip-response.tmp" "$SIGNAL/clip-response.txt"
        # 원격 → Mac: 원격 클립보드에 값을 넣는다
        REMOTE="withshell-remote-$RANDOM"
        docker exec withshell-test-rdp pkill xclip >/dev/null 2>&1 || true
        print -n "$REMOTE" | docker exec -i -u ubuntu withshell-test-rdp sh -c 'cat > /tmp/withshell-clip.txt'
        docker exec -d -u ubuntu -e DISPLAY=:10 withshell-test-rdp xclip -selection clipboard -i -loops 5 /tmp/withshell-clip.txt
        print -n "$REMOTE" > "$SIGNAL/clip-remote.txt"
        break
      fi
      kill -0 $TEST_PID 2>/dev/null || break
      sleep 0.5
    done
    wait $TEST_PID
    ;;
esac
