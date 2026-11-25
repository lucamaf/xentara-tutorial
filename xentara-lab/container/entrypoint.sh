#!/bin/bash
# Entry point of the Xentara container.
#
#   /config                           configuration directory (model.json, config.json, users.json, passwords.json, ...)
#   /usr/local/share/xentara/licence  licence files
#
# Environment:
#   XENTARA_CONFIG_DIR   configuration directory (default /config)
#   XENTARA_TLS_SAN      subjectAltName of the self-signed certificate that is created when the HTTP server is
#                        configured and no certificate exists, e.g. "DNS:localhost,IP:192.168.122.9"
#                        (default "DNS:localhost,IP:127.0.0.1")
#
# Any arguments are passed on to xentara (for example --model=/config/other.json).
set -e

config_dir="${XENTARA_CONFIG_DIR:-/config}"

# The HTTP/WebSocket server only speaks HTTPS and Xentara stops at start-up when there is no certificate.
# If the HTTP server is configured and there is no certificate, create a self-signed one.
if grep -qs '"httpServer"' "${config_dir}/config.json" && [ ! -f "${config_dir}/certs/xentara.pem" ]; then
    echo "entrypoint: creating a self-signed TLS certificate in ${config_dir} (subjectAltName ${XENTARA_TLS_SAN:-DNS:localhost,IP:127.0.0.1})"
    mkdir -p "${config_dir}/certs" "${config_dir}/private"
    openssl req -nodes -x509 -newkey rsa:4096 -sha256 -days 3650 \
        -subj "/CN=xentara" \
        -addext "subjectAltName=${XENTARA_TLS_SAN:-DNS:localhost,IP:127.0.0.1}" \
        -keyout "${config_dir}/private/xentara.key.pem" \
        -out "${config_dir}/certs/xentara.pem" 2> /dev/null
    chmod 0600 "${config_dir}/private/xentara.key.pem"
fi

exec xentara --config-dir="${config_dir}" "$@"
