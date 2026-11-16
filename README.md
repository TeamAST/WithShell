# WithShell

SSH·RDP 접속 정보를 저장해 두고 여러 세션을 탭으로 띄워 쓰는 macOS 앱입니다.

- SSH 터미널 (SwiftTerm), 색상 프리셋·터미널 종류(TERM) 설정
- RDP 원격 데스크톱 (FreeRDP 3), 클립보드 공유·원격 커서·해상도 자동 조절
- 키 관리자: SSH 개인키(OpenSSH·PEM, Ed25519·ECDSA·RSA)와 비밀번호를 키체인에 보관, Touch ID 확인

## 빌드

필요: macOS 15 이상 (Apple Silicon), Xcode, Homebrew

```bash
brew install xcodegen cmake ninja pkg-config
./scripts/build-freerdp.sh      # OpenSSL + FreeRDP 정적 라이브러리 → ThirdParty/FreeRDP (처음 한 번)
xcodegen generate
xcodebuild -project WithShell.xcodeproj -scheme WithShell -configuration Release \
  -derivedDataPath build/DerivedData -skipPackagePluginValidation -skipMacroValidation build
```

Xcode에서 처음 빌드할 때 SwiftTerm 빌드 플러그인의 "Trust & Enable"을 눌러야 합니다.

### 배포 (Developer ID 서명 + 공증)

```bash
./scripts/release.sh            # → dist/WithShell-<버전>-arm64.zip
```

Release 구성은 팀 4Y6Z5689CK의 "Developer ID Application" 인증서로 서명하고,
Xcode에 로그인된 계정으로 Apple 공증을 받은 뒤 스테이플합니다.

## 테스트

Docker로 테스트 서버를 띄운 뒤 통합 테스트를 실행합니다.

```bash
./scripts/test-sshd.sh up && ./scripts/test-sshd.sh test
./scripts/test-rdp.sh up && ./scripts/test-rdp.sh test
```

`WithShellTests/Fixtures`의 키는 테스트 전용입니다.

## 서드파티

- [FreeRDP](https://github.com/FreeRDP/FreeRDP) (Apache 2.0), [OpenSSL](https://www.openssl.org) (Apache 2.0)
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT), [Citadel](https://github.com/orlandos-nl/Citadel) (MIT), swift-nio-ssh / swift-crypto (Apache 2.0)
- bcrypt_pbkdf / Blowfish: `WithShell/Vendor/BcryptPBKDF/README.md` 참고 — This product includes software developed by Niels Provos.
