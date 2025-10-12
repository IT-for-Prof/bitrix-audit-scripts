Nginx audit helper

This directory contains `collect_nginx.sh` and a small wrapper `run_nginx_audit.sh`.

Purpose
- Produce a static audit of Nginx configuration and perform non-invasive probes of upstreams/backends.

How to run (recommended)
- As root (recommended) to collect full info and avoid permission issues:

  sudo /root/Audit-Bitrix24/run_nginx_audit.sh

- The wrapper runs the collector in a sterile environment (no user RCs or interactive menus).

Important notes and limitations
- The script uses `nginx -T` as the canonical static config dump. Dynamic runtime constructs, positional captures (e.g. `$1`, `$2`), or values injected by environment or runtime logic may not be resolvable from the static dump.
- The collector performs short TCP connects and read-only HTTP HEAD/GET probes to reachable backends. If you want a purely static audit (no network activity), edit `collect_nginx.sh` to skip the probes or request a `--no-active-probes` flag.
- Heuristic substitutions are applied when the collector cannot statically resolve a variable. These include:
  - using `set $var` assignments when present
  - using `map` explicit values or default
  - expanding named `upstream` blocks and testing each defined `server`
  - stripping common suffixes like `$request_uri`/`$uri` from concatenated expressions and attempting lookups
- Heuristics are conservative but may not always reflect runtime routing; heuristic substitutions are annotated in the `upstreams_health.txt` report with a NOTE line so you can tell which entries were inferred rather than direct from config.

Output
- Primary outputs are written to `/root/nginx_audit` (or `$HOME/nginx_audit`) and an archive is created under `/root/audit/nginx.tgz`.
- Key files:
  - `SUMMARY.md` — short audit summary
  - `vhosts.csv` — CSV of server blocks
  - `upstreams_health.txt` — the per-upstream reachability and banner report (heuristic notes included when applied)

If you want me to further tune heuristics for your specific templates (e.g. resolve `$proxyserver$request_uri/` in a particular pattern), tell me an example candidate string from `/root/nginx_audit/dump/nginx_T.txt` and I'll add a focused rule to extract it reliably.
