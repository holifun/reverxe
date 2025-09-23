# syntax=docker/dockerfile:1.6                                                                                                                                  

FROM alpine:3.19 AS builder
ARG TARGETARCH
# 可选：指定上游版本；不填为 latest
ARG XRAY_VERSION=latest

RUN set -eux; \
    apk add --no-cache curl jq unzip ca-certificates; \
    # 解析版本
    if [ "$XRAY_VERSION" = "latest" ]; then \
      tag="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)"; \
    else \
      tag="$XRAY_VERSION"; \
    fi; \
    # 选择资产名
    case "$TARGETARCH" in \
      amd64) asset="Xray-linux-64.zip" ;; \
      arm64) asset="Xray-linux-arm64-v8a.zip" ;; \
      386)   asset="Xray-linux-32.zip" ;; \
      arm)   asset="Xray-linux-arm32-v7a.zip" ;; \
      *)     asset="Xray-linux-64.zip" ;; \
    esac; \
    url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset}"; \
    echo "Downloading: ${url}"; \
    curl -fL "$url" -o /tmp/core.zip; \
    unzip -q /tmp/core.zip -d /tmp/x; \
    # 找到可执行文件并重命名为 reverxe
    b="$(find /tmp/x -type f -name 'xray' -perm -u+x | head -n1)"; \
    test -n "$b" || (echo "ERROR: 未找到可执行文件 xray" && exit 1); \
    install -m 0755 "$b" /reverxe

FROM alpine:3.19

# 运行期依赖
RUN apk add --no-cache ca-certificates tzdata bash jq

# 这些 ENV 会在群晖 UI 中显示，便于填写
ENV BIN_PATH=/usr/local/bin/reverxe \
    CONF_DIR=/etc/reverxe \
    ADDRESS= \
    PORT= \
    UUID= \
    ENCRYPTION=none \
    FLOW= \
    REVERSE_TAG=reverse0

# 放置二进制
COPY --from=builder /reverxe /usr/local/bin/reverxe

# 写入入口脚本（注意：这一行必须以 <<'EOF' 结尾，后面不能接 ; 或 \）
RUN set -eux; \
  cat > /usr/local/bin/entrypoint <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BIN=${BIN_PATH:-/usr/local/bin/reverxe}
CONF_DIR=${CONF_DIR:-/etc/reverxe}
CONFIG="${CONF_DIR}/config.json"

# 必填校验（缺少即退出，避免跑错）
: "${ADDRESS:?请设置 ADDRESS}"
: "${PORT:?请设置 PORT}"
: "${UUID:?请设置 UUID}"

# 可选项默认值
: "${ENCRYPTION:=none}"
: "${FLOW:=}"
: "${REVERSE_TAG:=reverse0}"

mkdir -p "$CONF_DIR"

# 用 jq 生成配置；FLOW 为空则自动省略该字段
jq -n \
  --arg ADDRESS "$ADDRESS" \
  --argjson PORT "${PORT}" \
  --arg UUID "$UUID" \
  --arg ENCRYPTION "$ENCRYPTION" \
  --arg FLOW "$FLOW" \
  --arg REVERSE_TAG "$REVERSE_TAG" \
'def maybeFlow(f): if (f|length)>0 then {flow:f} else {} end;
{
  outbounds: [
    { protocol: "direct" },
    {
      protocol: "vless",
      settings: ({
        address: $ADDRESS,
        port: $PORT,
        id: $UUID,
        encryption: $ENCRYPTION
      } + maybeFlow($FLOW) + { reverse: { tag: $REVERSE_TAG } })
    }
  ]
}' > "$CONFIG"

echo "[reverxe] starting with $CONFIG"
exec "$BIN" run -c "$CONFIG"
EOF

RUN chmod +x /usr/local/bin/entrypoint /usr/local/bin/reverxe

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["run"]
