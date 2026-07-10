#!/usr/bin/env bash
set -euo pipefail

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

validate_compose() {
    local name=$1
    local compose_source=$2
    local example_suffix=$3
    local runtime_suffix=$4
    local root="$TMP_DIR/$name"

    mkdir -p "$root/infra" "$root/env"
    cp "$ROOT/$compose_source" "$root/infra/docker-compose.yml"
    cp "$ROOT/env/.env${example_suffix}.example" "$root/.env"
    for service in backend eats business adminpanel; do
        cp \
            "$ROOT/env/${service}${example_suffix}.env.example" \
            "$root/env/${service}${runtime_suffix}.env"
    done

    docker compose \
        -f "$root/infra/docker-compose.yml" \
        --env-file "$root/.env" \
        config >/dev/null
    echo "$name compose config ok"
}

validate_compose development docker-compose.yml "" ""
validate_compose production docker-compose.prod.yml ".prod" ".prod"
