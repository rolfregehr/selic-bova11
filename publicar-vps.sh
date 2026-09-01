#!/usr/bin/env bash
set -euo pipefail

vps_target="${VPS_TARGET:-deploy@145.223.95.176}"
vps_port="${VPS_PORT:-2222}"
remote_dir="${VPS_REMOTE_DIR:-/home/deploy/apps/selic-bova11}"
site_url="${SITE_URL:-https://apos.rolfregehr.com.br/}"
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! "$vps_port" =~ ^[0-9]+$ ]]; then
  echo "VPS_PORT deve ser um número." >&2
  exit 2
fi

for command_name in rsync ssh curl sha256sum; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Comando necessário não encontrado: $command_name" >&2
    exit 2
  fi
done

rsync_excludes=(
  --exclude=/.git/
  --exclude=/.github/
  --exclude=/.agents/
  --exclude=/.codex/
  --exclude=/.Rproj.user/
  --exclude=/.quarto/
  --exclude=/deploy/
  --exclude=/.Rhistory
  --exclude=/.RData
  --exclude=/.Ruserdata
  --exclude=/.gitignore
  --exclude='/*.Rproj'
  --exclude=/publicar-vps.sh
  --exclude=/_site/
  --exclude='/*.html'
  --exclude='/*.knit.md'
  --exclude='/*_files/'
  --exclude=/render.lock
)

publicar() {
  echo "Enviando arquivos para $vps_target..."

  rsync \
    --archive \
    --compress \
    --human-readable \
    --itemize-changes \
    "${rsync_excludes[@]}" \
    -e "ssh -p $vps_port" \
    "$project_dir/" \
    "$vps_target:$remote_dir/"

  echo "Renderizando e publicando no VPS..."
  ssh -p "$vps_port" "$vps_target" \
    "sudo systemctl start selic-bova11.service && test \"\$(sudo systemctl show selic-bova11.service -p Result --value)\" = success"

  curl --fail --silent --show-error --head "$site_url" >/dev/null

  echo "Publicado com sucesso: $site_url"
  echo "Horário: $(date '+%d/%m/%Y %H:%M:%S')"
}

fingerprint() {
  find "$project_dir" \
    -path "$project_dir/.git" -prune -o \
    -path "$project_dir/.github" -prune -o \
    -path "$project_dir/.agents" -prune -o \
    -path "$project_dir/.codex" -prune -o \
    -path "$project_dir/.Rproj.user" -prune -o \
    -path "$project_dir/.quarto" -prune -o \
    -path "$project_dir/deploy" -prune -o \
    -path "$project_dir/_site" -prune -o \
    -name '.Rhistory' -prune -o \
    -name '.RData' -prune -o \
    -name '.Ruserdata' -prune -o \
    -name '.gitignore' -prune -o \
    -name '*.Rproj' -prune -o \
    -name 'publicar-vps.sh' -prune -o \
    -name '*.html' -prune -o \
    -name '*.knit.md' -prune -o \
    -name '*_files' -prune -o \
    -name 'render.lock' -prune -o \
    -type f -print0 |
    sort -z |
    xargs -0 -r sha256sum |
    sha256sum |
    cut -d' ' -f1
}

case "${1:-}" in
  "")
    publicar
    ;;
  --watch)
    echo "Observando alterações em: $project_dir"
    echo "Pressione Ctrl+C para encerrar."
    ultimo_fingerprint="$(fingerprint)"

    while sleep 2; do
      fingerprint_atual="$(fingerprint)"

      if [[ "$fingerprint_atual" != "$ultimo_fingerprint" ]]; then
        # Aguarda o editor terminar operações de gravação/renomeação do arquivo.
        sleep 1
        fingerprint_atual="$(fingerprint)"

        if publicar; then
          ultimo_fingerprint="$fingerprint_atual"
        else
          echo "A publicação falhou; uma nova alteração tentará novamente." >&2
          ultimo_fingerprint="$fingerprint_atual"
        fi
      fi
    done
    ;;
  -h|--help)
    cat <<'EOF'
Uso:
  ./publicar-vps.sh          Envia e publica o estado atual uma vez.
  ./publicar-vps.sh --watch  Publica automaticamente após cada alteração.

Variáveis opcionais:
  VPS_TARGET, VPS_PORT, VPS_REMOTE_DIR e SITE_URL.
EOF
    ;;
  *)
    echo "Opção desconhecida: $1" >&2
    echo "Use --help para ver as opções." >&2
    exit 2
    ;;
esac
