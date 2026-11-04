#!/bin/sh
# 生成自签 CA + 叶子证书（叶子 SAN 含 VPS 公网 IP）。
# ⚠️ 叶子有效期必须 ≤ 825 天：Apple Security 框架（Tailscale 网络扩展走它校验 TLS）
# 拒绝超长有效期的服务器叶子证书（报 not standards compliant / OtherTrustValidityPeriod）；
# CA 不受此限，仍 10 年。curl/openssl 不做此校验，所以不能靠 curl 验证发现。
# 用法: VPS_IP=x.x.x.x ./gen-certs.sh [输出目录]（默认 ./tls）
# 产出: ca.crt ca.key server.crt server.key
# 纪律: 私钥只留在 VPS 上，不进 git、不回传本地。
set -eu

IP="${VPS_IP:?请先 export VPS_IP=<你的VPS公网IP>}"
OUT="${1:-./tls}"
mkdir -p "$OUT"
cd "$OUT"

# 1. CA 根证书（10 年）
openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -x509 -new -key ca.key -sha256 -days 3650 \
  -subj "/CN=dsh-mobile tailnet CA" \
  -out ca.crt

# 2. 叶子证书（825 天，Apple 上限；SAN = VPS 公网 IP）
openssl ecparam -name prime256v1 -genkey -noout -out server.key
openssl req -new -key server.key \
  -subj "/CN=headscale" \
  -out server.csr

cat > server.ext <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
IP.1 = ${IP}
EOF

openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 825 -sha256 -extfile server.ext -out server.crt

rm -f server.csr server.ext ca.srl
chmod 600 ca.key server.key

# 自检：叶子证书与私钥必须配对（公钥指纹一致才放行，防止不配套的产物流出去）
crt_pub=$(openssl x509 -in server.crt -noout -pubkey | openssl sha256)
key_pub=$(openssl pkey -in server.key -pubout | openssl sha256)
if [ "$crt_pub" != "$key_pub" ]; then
  echo "错误: server.crt 与 server.key 不配对（生成过程异常），请删除 $OUT 重跑" >&2
  exit 1
fi

echo "已生成: $OUT/{ca.crt, ca.key, server.crt, server.key}（crt/key 配对自检通过）"
echo "下一步: ca.crt + server.crt + server.key 上传 VPS 的 /etc/headscale/tls/（ca.key 留本地冷备，不上服务器）"
