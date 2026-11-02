#!/usr/bin/env bash
# 创建自签名代码签名证书「Resound Dev」并导入 login keychain（跑一次即可）。
# 目的：bundle-app.sh 检测到它后用稳定身份签名 → 重新打包不再让「屏幕录制」TCC 授权失效
# （ad-hoc 签名按可执行哈希记授权，每次重打包都要重新去系统设置勾选）。
set -euo pipefail
if security find-identity -p codesigning 2>/dev/null | grep -qF "Resound Dev"; then
  echo "✅ 「Resound Dev」证书已存在，无需重复创建"; exit 0
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes \
  -subj "/CN=Resound Dev" -addext "extendedKeyUsage=codeSigning" -addext "keyUsage=digitalSignature" >/dev/null 2>&1
openssl pkcs12 -export -legacy -out "$TMP/dev.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -password pass:resound-dev >/dev/null 2>&1 \
  || openssl pkcs12 -export -out "$TMP/dev.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -password pass:resound-dev >/dev/null 2>&1
security import "$TMP/dev.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P resound-dev -T /usr/bin/codesign
echo "✅ 已创建并导入「Resound Dev」证书。之后 bundle-app.sh 会自动用它签名。"
echo "   注意：换用新签名后的第一个包，屏幕录制要再授一次权——之后所有重新打包都不再失效。"
