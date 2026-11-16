# bcrypt_pbkdf (vendored)

암호화된 OpenSSH 개인키(`bcrypt` KDF)를 풀기 위한 OpenBSD `bcrypt_pbkdf`와 Blowfish 구현입니다.

- 출처: Citadel (https://github.com/orlandos-nl/Citadel, MIT License, Copyright (c) 2022 Orlandos)의 `Sources/CCitadelBcrypt`
- 원 저작: OpenBSD — Blowfish (Copyright 1997 Niels Provos, BSD License), bcrypt_pbkdf (Copyright 2013 Ted Unangst, ISC License)
- 변경점: 심볼 접두사 `citadel_` → `ws_`, SHA-512를 CommonCrypto(`CC_SHA512`)로 직접 호출

blf.c의 라이선스 조건에 따라 배포물의 고지 문서에 "This product includes software developed by Niels Provos."를 포함해야 합니다.
