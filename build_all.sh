#!/bin/sh
set -eu

cd "$(dirname "$0")"

echo "=== Vérification / création du réseau data-net ==="
if ! docker network ls | grep -q 'data-net'; then
  docker network create data-net
fi

echo "=== Arrêt des conteneurs existants ==="
docker compose down || true

echo "=== Build cr-pipeline ==="
docker build -t rendu-cr-pipeline:latest ./cr-pipeline

echo "=== Build cr-render ==="
docker build -t rendu-cr-render:latest ./cr-render

echo "=== Démarrage des services ==="
docker compose up -d cr-pipeline cr-render

echo "=== Vérification des /ping (attente readiness) ==="

check_ping() {
  name="$1"
  url="$2"
  tries="${3:-30}"

  i=1
  while [ "$i" -le "$tries" ]; do
    code="$(curl -s -o /dev/null -w "%{http_code}" "$url" || true)"
    if [ "$code" = "200" ]; then
      echo "$name joignable ($url)"
      return 0
    fi
    sleep 1
    i=$((i+1))
  done

  echo "$name non joignable ($url)"
  return 1
}

# 127.0.0.1 est le plus fiable en local ; gardez 192.168.1.20 si vous préférez.
check_ping "cr-pipeline" "http://127.0.0.1:8090/ping" 30 || true
check_ping "cr-render"   "http://127.0.0.1:8081/ping" 30 || true

echo "=== Terminé ==="
