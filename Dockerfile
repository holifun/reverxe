# syntax=docker/dockerfile:1.6

################
# Builder阶段：仅在构建时出现/使用上游名称
################
FROM alpine:3.19 AS builder
ARG TARGETARCH
# 可选：指定上游版本；留空或 latest 都会走 latest
ARG XRAY_VERSION=latest

RUN set -euo pipefail; \
    apk add --no-cache curl unzip ca-certificates; \
    # 1) 选择资产名（arm64 优先 v8a，失败再回退）
    case "${TARGETARCH:-amd64}" in \
      amd64) asset="Xray-linux-64.zip" ;; \
      arm64) asset="Xray-linux-arm64-v8a.zip" ;; \
      386)   asset="Xray-linux-32.zip" ;; \
      arm)   asset="Xray-linux-arm32-v7a.zip" ;; \
      *)     asset="Xray-linux-64.zip" ;; \
    esac; \
    base="https://github.com/XTLS/Xray-core/releases"; \
    XRAY_VER="${XRAY_VERSION:-}"; \
    if [ -z "$XRAY_VER" ] || [ "$XRAY_VER" = "latest" ]; then \
      url_primary="${base}/latest/download/${asset}"; \
      url_fallback_arm64="${base}/latest/download/Xray-linux-arm64.zip"; \
    else \
      url_primary="${base}/download/${XRAY_VER}/${asset}"; \
      url_fallback_arm64="${base}/download/${XRAY_VER}/Xray-linux-arm64.zip"; \
    fi; \
    echo "Downloading primary: ${url_primary}"; \
    if ! curl -fL "$url_primary" -o /tmp/core.zip; then \
      if [ "${TARGETARCH:-amd64}" = "arm64" ]; then \
        echo "Primary asset not found. Trying fallback: ${url_fallback_arm64}"; \
        curl -fL "$url_fallback_arm64" -o /tmp/core.zip; \
      else \
        echo "Download failed: ${url_primary}"; \
        exit 1; \
      fi; \
    fi; \
    unzip -q /tmp/core.zip -d /tmp/x; \
    # 2) 找到可执行文件并重命名为 reverxe（不依赖 -perm，兼容 BusyBox find）
    b="$(find /tmp/x -type f -name xray -print -quit)"; \
    if [ -z "$b" ]; then \
      echo "ERROR: 解压包内找不到二进制 'xray'，目录结构如下："; \
      ls -lR /tmp/x; \
      exit 1; \
    fi; \
    install -m 0755 "$b" /reverxe

################
# 最终运行镜像：只含 reverxe
################
FROM alpine:3.19

# 运行期依赖（entrypoint 用 jq 生成配置）
RUN apk add --no-cache ca-certificates tzdata bash jq

# 群晖 UI 会显示这些 ENV；必填留空，可选给默认值
ENV BIN_PATH=/usr/local/bin/reverxe \
    CONF_DIR=/etc/reverxe \
    ADDRESS= \
    PORT= \
    UUID= \
    ENCRYPTION=none \
    FLOW= \
    SEND=

# 放置二进制
COPY --from=builder /reverxe /usr/local/bin/reverxe

# 写入入口脚本（注意 heredoc 语法）
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
: "${SEND:=}"

mkdir -p "$CONF_DIR"

# 用 jq 生成配置；FLOW 为空则自动省略该字段
jq -n \
  --arg ADDRESS "$ADDRESS" \
  --argjson PORT "${PORT}" \
  --arg UUID "$UUID" \
  --arg ENCRYPTION "$ENCRYPTION" \
  --arg FLOW "$FLOW" \
  --arg SEND "$SEND" \
'def maybeFlow(f): if (f|length)>0 then {flow:f} else {} end;
def maybeSend(s): if (s|length)>0 then {sendThrough:s} else {} end;
{
  outbounds: [
    ({ protocol: "freedom" } + maybeSend($SEND)),
    {
      protocol: "vless",
      settings: ({
        address: $ADDRESS,
        port: $PORT,
        id: $UUID,
        encryption: $ENCRYPTION
      } + maybeFlow($FLOW) + { reverse: { tag: "reverse0" } })
    }
  ]
}' > "$CONFIG"

echo "[reverxe] starting with $CONFIG"
exec "$BIN" run -c "$CONFIG" >/dev/null 2>&1
EOF

RUN chmod +x /usr/local/bin/entrypoint /usr/local/bin/reverxe

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["run"]
