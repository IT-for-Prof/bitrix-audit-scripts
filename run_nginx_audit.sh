#!/usr/bin/env bash
# Wrapper to run collect_nginx.sh in a clean environment to avoid interactive menus
# Usage: sudo ./run_nginx_audit.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COLLECT="$SCRIPT_DIR/collect_nginx.sh"
if [ ! -x "$COLLECT" ]; then
  echo "Collector not found or not executable: $COLLECT" >&2
  exit 2
fi
# Recommended sterile invocation; preserves minimal PATH and HOME
env -i HOME=/root PATH=/usr/sbin:/usr/bin:/bin BX_NOMENU=1 BITRIX_NO_MENU=1 DISABLE_BITRIX_MENU=1 BASH_ENV= \
  /usr/bin/env bash --noprofile --norc "$COLLECT" "$@"
EXIT_CODE=$?
if [ $EXIT_CODE -ne 0 ]; then
  echo "Collector exited with status $EXIT_CODE" >&2
fi
echo "Done. Archive (if created) is under /root/audit/nginx.tgz or output directory under /root/nginx_audit"
exit $EXIT_CODE