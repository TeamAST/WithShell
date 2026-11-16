테스트 전용 SSH 키입니다. 실제 서버에 등록하지 마세요.
- 이름에 `_enc`·`_cbc`가 붙은 키의 패스프레이즈: `withshell-fixture`
- `authorized/` 공개키는 `scripts/test-sshd.sh up`이 테스트 컨테이너에 등록합니다.
- `expected.txt`는 `ssh-keygen -lf`로 계산한 지문입니다.
