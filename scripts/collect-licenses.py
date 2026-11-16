#!/usr/bin/env python3
"""앱에 포함되는 서드파티 라이브러리의 라이선스 원문을 모아
WithShell/Resources/OpenSourceLicenses.json 을 만든다.

실행: python3 scripts/collect-licenses.py
(Swift 패키지 체크아웃·FreeRDP·OpenSSL 소스가 build/ 아래에 있어야 한다)
"""
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHECKOUTS = ROOT / "build/DerivedData/SourcePackages/checkouts"
RESOLVED = ROOT / "WithShell.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
OUTPUT = ROOT / "WithShell/Resources/OpenSourceLicenses.json"

# macOS 앱에 실제로 링크되는 Swift 패키지 (Linux 전용 swift-png/h, 도구용 argument-parser 제외)
SWIFT_PACKAGES = [
    ("SwiftTerm", "swiftterm", "MIT", "https://github.com/migueldeicaza/SwiftTerm"),
    ("Citadel", "citadel", "MIT", "https://github.com/orlandos-nl/Citadel"),
    ("swift-nio-ssh", "swift-nio-ssh", "Apache-2.0", "https://github.com/Wellz26/swift-nio-ssh"),
    ("swift-nio", "swift-nio", "Apache-2.0", "https://github.com/apple/swift-nio"),
    ("swift-crypto", "swift-crypto", "Apache-2.0", "https://github.com/apple/swift-crypto"),
    ("swift-asn1", "swift-asn1", "Apache-2.0", "https://github.com/apple/swift-asn1"),
    ("swift-log", "swift-log", "Apache-2.0", "https://github.com/apple/swift-log"),
    ("swift-atomics", "swift-atomics", "Apache-2.0", "https://github.com/apple/swift-atomics"),
    ("swift-collections", "swift-collections", "Apache-2.0", "https://github.com/apple/swift-collections"),
    ("swift-system", "swift-system", "Apache-2.0", "https://github.com/apple/swift-system"),
    ("BigInt", "bigint", "MIT", "https://github.com/attaswift/BigInt"),
]


def read_first(directory: pathlib.Path, patterns):
    for pattern in patterns:
        for path in sorted(directory.glob(pattern)):
            if path.is_file():
                return path.read_text(encoding="utf-8", errors="replace").strip()
    return None


def versions():
    data = json.loads(RESOLVED.read_text())
    return {pin["identity"]: pin["state"].get("version") or pin["state"].get("revision", "")[:7]
            for pin in data.get("pins", [])}


def license_comment(path: pathlib.Path) -> str:
    """C 파일에서 저작권·라이선스 문구가 들어 있는 첫 주석 블록"""
    text = path.read_text(encoding="utf-8", errors="replace")
    for match in re.finditer(r"/\*(.*?)\*/", text, re.S):
        body = match.group(1)
        if "Copyright" in body:
            lines = [re.sub(r"^\s*\* ?", "", line) for line in body.splitlines()]
            return "\n".join(lines).strip()
    raise SystemExit(f"저작권 주석 없음: {path}")


def main():
    pinned = versions()
    entries = [{
        "name": "WithShell",
        "version": "",
        "license": "MIT",
        "url": "https://github.com/TeamAST/WithShell",
        "text": (ROOT / "LICENSE").read_text().strip(),
    }]

    for name, identity, license_id, url in SWIFT_PACKAGES:
        directory = CHECKOUTS / name
        text = read_first(directory, ["LICENSE", "LICENSE.txt", "LICENSE.md", "COPYING"])
        if text is None:
            raise SystemExit(f"라이선스 파일 없음: {directory}")
        notice = read_first(directory, ["NOTICE", "NOTICE.txt"])
        if notice:
            text += "\n\n----- NOTICE -----\n\n" + notice
        entries.append({"name": name, "version": pinned.get(identity, ""), "license": license_id,
                        "url": url, "text": text})

    freerdp = ROOT / "build/freerdp/src"
    entries.append({"name": "FreeRDP", "version": "3.33.1", "license": "Apache-2.0",
                    "url": "https://github.com/FreeRDP/FreeRDP",
                    "text": (freerdp / "LICENSE").read_text().strip()})

    openssl = ROOT / "build/openssl/src"
    entries.append({"name": "OpenSSL", "version": "3.5.9", "license": "Apache-2.0",
                    "url": "https://www.openssl.org",
                    "text": (openssl / "LICENSE.txt").read_text().strip()})

    vendor = ROOT / "WithShell/Vendor/BcryptPBKDF"
    entries.append({"name": "Blowfish (OpenBSD)", "version": "", "license": "BSD-4-Clause",
                    "url": "https://www.openbsd.org",
                    "text": "This product includes software developed by Niels Provos.\n\n"
                            + license_comment(vendor / "blf.c")})
    entries.append({"name": "bcrypt_pbkdf (OpenBSD, via Citadel)", "version": "", "license": "ISC",
                    "url": "https://www.openbsd.org",
                    "text": license_comment(vendor / "bcrypt-kdf.c")
                            + "\n\nWithShell에 포함된 사본은 Citadel(MIT)을 거쳐 가져와 수정했습니다."})

    OUTPUT.write_text(json.dumps(entries, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"{len(entries)}개 항목 → {OUTPUT.relative_to(ROOT)}")
    for entry in entries:
        print(f"  {entry['name']:<36} {entry['license']:<14} {entry['version']}  ({len(entry['text'])}자)")


if __name__ == "__main__":
    main()
