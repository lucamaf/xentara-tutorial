#!/bin/bash
# Runs the Xentara lab: a simulated Modbus TCP device (water-tank station) and Xentara (UBI 10 container) that reads it.
#
#   ./lab.sh build            build the images (simulator, Xentara, dashboard)
#   ./lab.sh init             create ./run/config (model, config.json) and ./run/licence
#   ./lab.sh password [user]  set the password of a Xentara user (asks for it)
#   ./lab.sh up               start the simulator, Xentara and the dashboard (http://<address>:8091)
#   ./lab.sh logs [name]      show the log (xentara, modbus-sim or xentara-dashboard)
#   ./lab.sh status           show the containers and the open ports
#   ./lab.sh licence-id       print the licence ID that Xentara sees in a container on this computer
#   ./lab.sh down             stop and remove the containers and the network
#
# Environment:
#   CONTAINER_CMD     container engine command (default "sudo podman"). Use a ROOTFUL engine: Xentara's licence helper is
#                     a setuid-root program that reads the hardware ID, and that fails in a rootless container.
#   LAB_ADDRESS       address of this computer for the browser (default: first address of "hostname -I"),
#                     used for the TLS certificate and the CORS origins of the Inspector
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
C="${CONTAINER_CMD:-sudo podman}"
run_dir="${here}/run"
net=xentara-lab
address="${LAB_ADDRESS:-$(hostname -I | awk '{print $1}')}"

case "${1:-}" in
  build)
    $C build -t modbus-sim -f "${here}/simulator/Containerfile" "${here}/simulator"
    $C build -t xentara-ubi10 -f "${here}/container/Containerfile" "${here}/container"
    $C build --format docker -t xentara-dashboard -f "${here}/dashboard/Containerfile" "${here}/dashboard"
    ;;

  init)
    mkdir -p "${run_dir}/config" "${run_dir}/licence"
    # the model refers to the simulator by its container name
    python3 "${here}/model/make_plant_model.py" modbus-sim:5020 "${run_dir}/config/model.json"
    cat > "${run_dir}/config/config.json" <<JSON
{
  "\$schema": "https://docs.xentara.io/xentara/schema-xentara-config.json",
  "httpServer": {
    "services": ["WebSocket"],
    "portNumber": 19670,
    "authentication": { "schemes": ["Bearer", "Basic"] },
    "CORS": {
      "allowedOrigins": [
        "http://${address}:8090", "https://${address}:8090",
        "http://localhost:8090", "https://localhost:8090",
        "http://${address}:8091", "https://${address}:8091",
        "http://localhost:8091", "https://localhost:8091"
      ]
    }
  }
}
JSON
    # By default remote clients may only read. The "Operator" role may also write (the dashboard and the Inspector write
    # the set point, the pump speed and so on). The user "admin" gets this role; set its password with ./lab.sh password.
    cat > "${run_dir}/config/security.json" <<JSON
{
  "roles": [ { "name": "Operator", "UUID": "$(python3 -c 'import uuid; print(uuid.uuid5(uuid.NAMESPACE_DNS, "operator.xentara-lab"))')" } ],
  "ACL": { "entries": [ { "role": "Operator", "allow": ["write"] } ] }
}
JSON
    cat > "${run_dir}/config/users.json" <<JSON
{
  "users": [ { "UUID": "$(python3 -c 'import uuid; print(uuid.uuid5(uuid.NAMESPACE_DNS, "admin.xentara-lab"))')", "userName": "admin", "roles": ["Operator"] } ]
}
JSON
    echo "Created ${run_dir}/config (model.json, config.json, security.json, users.json) for the address ${address}."
    echo "Copy your Xentara licence file(s) into ${run_dir}/licence, set the password of the user admin (./lab.sh password), then run: ./lab.sh up"
    ;;

  password)
    user="${2:-admin}"
    $C run --rm -it --entrypoint xentara-password -v "${run_dir}/config:/config:Z" xentara-ubi10 --config-dir=/config "${user}"
    ;;

  up)
    [ -f "${run_dir}/config/model.json" ] || { echo "Run './lab.sh init' first." >&2; exit 1; }
    $C network exists "${net}" 2> /dev/null || $C network create "${net}" > /dev/null
    $C rm -f modbus-sim xentara xentara-dashboard > /dev/null 2>&1 || true
    $C run -d --name modbus-sim --network "${net}" --init -p 5020:5020 modbus-sim > /dev/null
    # SYS_NICE and the rtprio limit allow real-time scheduling inside the container
    $C run -d --name xentara --network "${net}" --init \
        --cap-add SYS_NICE --ulimit rtprio=99 --ulimit memlock=-1 \
        -e "XENTARA_TLS_SAN=DNS:localhost,IP:127.0.0.1,IP:${address}" \
        -p 19670:19670 \
        -v "${run_dir}/config:/config:Z" \
        -v "${run_dir}/licence:/usr/local/share/xentara/licence:ro,Z" \
        xentara-ubi10 > /dev/null
    # the dashboard is a web page: the browser talks to Xentara directly (port 19670), like the Xentara Inspector
    $C run -d --name xentara-dashboard --restart unless-stopped -p 8091:8080 xentara-dashboard > /dev/null
    sleep 2
    $C ps --format '{{.Names}}  {{.Status}}  {{.Ports}}'
    echo
    echo "Dashboard: http://${address}:8091   (log in with the Xentara user; the first time accept the certificate at https://${address}:19670)"
    echo "Follow the log with: ./lab.sh logs xentara"
    ;;

  logs)
    $C logs -f "${2:-xentara}"
    ;;

  status)
    $C ps -a --format '{{.Names}}  {{.Status}}  {{.Ports}}'
    ss -ltn 2> /dev/null | grep -E ':(19670|5020|8091)\b' || echo "(nothing listening on 19670 / 5020 / 8091)"
    ;;

  licence-id)
    $C run --rm --entrypoint xentara-licence-id xentara-ubi10
    ;;

  down)
    $C rm -f modbus-sim xentara xentara-dashboard > /dev/null 2>&1 || true
    $C network rm "${net}" > /dev/null 2>&1 || true
    echo "stopped"
    ;;

  *)
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
