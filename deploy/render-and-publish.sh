#!/usr/bin/env bash
set -euo pipefail

app_dir="/home/deploy/apps/selic-bova11"
web_dir="/var/www/apos.rolfregehr.com.br"
release_dir="$web_dir/releases/$(date +%Y%m%d-%H%M%S)"

exec 9>"$app_dir/render.lock"
if ! flock -n 9; then
  echo "Uma atualização já está em andamento; encerrando."
  exit 0
fi

mkdir -p "$release_dir"

if ! quarto render "$app_dir/selic_bova11.qmd" --output-dir "$release_dir"; then
  rm -rf "$release_dir"
  exit 1
fi

test -s "$release_dir/index.html"

ln -sfn "$release_dir" "$web_dir/.current.new"
mv -Tf "$web_dir/.current.new" "$web_dir/current"

# Conserva as cinco publicações mais recentes para permitir recuperação rápida.
mapfile -t releases_antigos < <(
  find "$web_dir/releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
    sort -r |
    tail -n +6
)

for release in "${releases_antigos[@]}"; do
  rm -rf "$web_dir/releases/$release"
done
