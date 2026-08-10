#!/usr/bin/env bash
#
# fetch_aetna_dynamic_lists.sh
# Pulls the Aetna Skyhigh proxyconsole "customer-maintained" dynamic list
# files (Prod_BypassDLP, AllowListProd, DenyListProd, PCI_Inet_Access,
# VDMZAllowList/DenyList, HTTPSAllowListProd, SOCDenyList, ApprovedCloudStorage,
# DenyCloudStorage, etc.) -- the content that is NOT present in the raw
# Aetna-SH-Proxy-*.backup file, since those entries are subscription
# pointers (feature="CUSTOMER_MAINTAINED") with empty <content/> rather
# than snapshots. This script fetches the live .txt source directly.
#
# Requires network access to proxyconsole.aetna.com and pxylist.aetna.com
# from wherever this runs -- these are internal endpoints, so this will
# only work from inside the corporate network / VPN, and may require
# authentication (see AUTH NOTES below).
#
# Usage:
#   ./fetch_aetna_dynamic_lists.sh                 # priority set only (21 files)
#   ./fetch_aetna_dynamic_lists.sh --all            # all 100 known lists
#   ./fetch_aetna_dynamic_lists.sh --all --outdir ./mylists
#
# AUTH NOTES:
#   If these endpoints require authentication (basic, NTLM, or client-cert),
#   set CURL_AUTH_ARGS below before running, e.g.:
#     CURL_AUTH_ARGS="--ntlm -u DOMAIN\\user:password"
#     CURL_AUTH_ARGS="--cert /path/to/client.pem"
#   or export CURL_AUTH_ARGS in your shell before invoking this script.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="${SCRIPT_DIR}/aetna_dynamic_lists_$(date +%Y%m%d)"
MODE="priority"
CURL_AUTH_ARGS="${CURL_AUTH_ARGS:-}"
MAX_RETRIES=3
CONNECT_TIMEOUT=15

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all) MODE="all"; shift ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--all] [--outdir DIR]"
      echo "  --all        fetch all 100 known dynamic lists instead of the 21-item priority set"
      echo "  --outdir DIR save fetched files to DIR (default: ./aetna_dynamic_lists_YYYYMMDD)"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$OUTDIR"
SUMMARY="${OUTDIR}/_fetch_summary.tsv"
echo -e "list_name\turl\tstatus\thttp_code\tbytes\tsaved_as" > "$SUMMARY"

# name<TAB>url pairs. Priority = DLP scope + decrypt scope, the lists that
# actually feed the current PA-parity implementation work. --all pulls
# the full known set (includes narrow app-specific bypass lists: Facebook,
# Box, Kony, OWA MercyMaricopa, Sharepoint, etc.).
PRIORITY_LISTS='
Prod_BypassDLP_Domains	https://proxyconsole.aetna.com/prod/PROD_BypassDLP.domains.txt
Prod_BypassDLP_URLs	https://proxyconsole.aetna.com/prod/PROD_BypassDLP.urls.txt
AllowListProd_Domains	https://proxyconsole.aetna.com/prod/AllowListProd.domains.txt
AllowListProd_URLs	https://proxyconsole.aetna.com/prod/AllowListProd.urls.txt
DenyListProd_Domains	https://proxyconsole.aetna.com/prod/DenyListProd.domains.txt
DenyListProd_URLs	https://proxyconsole.aetna.com/prod/DenyListProd.urls.txt
DenyListProdException_Domains	https://proxyconsole.aetna.com/prod/DenyListProd_Exception.domains.txt
DenyListProdException_URLs	https://proxyconsole.aetna.com/prod/DenyListProd_Exception.urls.txt
PCI_Inet_Access_Domains	https://proxyconsole.aetna.com/prod/PCI_Inet_Access.domains.txt
PCI_Inet_Access_URLs	https://proxyconsole.aetna.com/prod/PCI_Inet_Access.urls.txt
VDMZAllowList_Domains	https://proxyconsole.aetna.com/prod/VDMZAllowList.domains.txt
VDMZAllowList_URLs	https://proxyconsole.aetna.com/prod/VDMZAllowList.urls.txt
VDMZDenyList_Domains	https://proxyconsole.aetna.com/prod/VDMZ_DenyList.Domains.txt
VDMZDenyList_URLs	https://proxyconsole.aetna.com/prod/VDMZ_DenyList.urls.txt
HTTPSAllowListProd_Domains	https://proxyconsole.aetna.com/prod/HTTPSAllowListProd.domains.txt
HTTPSAllowListProd_URLs	https://proxyconsole.aetna.com/prod/HTTPSAllowListProd.urls.txt
SOCDenyList_Domains	https://proxyconsole.aetna.com/prod/SOCDenyList.domains.txt
SOCDenyList_URLs	https://proxyconsole.aetna.com/prod/SOCDenyList.urls.txt
ApprovedCloudStorage_Domains	https://proxyconsole.aetna.com/prod/ApprovedCloudStorage.domains.txt
DenyCloudStorage_Domains	https://proxyconsole.aetna.com/prod/DenyCloudStorage.domains.txt
DenyCloudStorage_URLs	https://proxyconsole.aetna.com/prod/DenyCloudStorage.urls.txt
'

# Full 100-list manifest lives alongside this script as a TSV
# (all_dynamic_list_urls.txt: "Display Name<TAB>URL" per line, pulled
# directly from each list object's <url> element in the raw backup --
# not reconstructed from a naming guess). If missing, --all falls back
# to the priority set with a warning.
FULL_MANIFEST="${SCRIPT_DIR}/all_dynamic_list_urls.txt"

fetch_one() {
  local name="$1" url="$2"
  local safe_name
  safe_name="$(printf '%s' "$name" | tr -d '\r' | tr -c 'A-Za-z0-9_.-' '_')"
  local ext="txt"
  local out_file="${OUTDIR}/${safe_name}.${ext}"

  local http_code
  http_code=$(curl -sS -o "$out_file" -w '%{http_code}' \
    --connect-timeout "$CONNECT_TIMEOUT" \
    --retry "$MAX_RETRIES" --retry-delay 2 \
    -L $CURL_AUTH_ARGS \
    "$url" 2>"${out_file}.stderr")

  local curl_exit=$?
  local bytes=0
  [[ -f "$out_file" ]] && bytes=$(wc -c < "$out_file" | tr -d ' ')

  if [[ $curl_exit -eq 0 && "$http_code" == "200" && "$bytes" -gt 0 ]]; then
    echo "  OK    [$http_code] $name ($bytes bytes) -> $(basename "$out_file")"
    echo -e "${name}\t${url}\tOK\t${http_code}\t${bytes}\t$(basename "$out_file")" >> "$SUMMARY"
    rm -f "${out_file}.stderr"
  else
    echo "  FAIL  [$http_code] $name -- see $(basename "$out_file").stderr"
    echo -e "${name}\t${url}\tFAIL\t${http_code}\t${bytes}\t$(basename "$out_file")" >> "$SUMMARY"
  fi
}

echo "Output directory: $OUTDIR"
echo "Mode: $MODE"
echo ""

if [[ "$MODE" == "all" ]]; then
  if [[ -f "$FULL_MANIFEST" ]]; then
    echo "Fetching all lists from $FULL_MANIFEST ..."
    while IFS=$'\t' read -r name url; do
      [[ -z "$name" || -z "$url" ]] && continue
      fetch_one "$name" "$url"
    done < "$FULL_MANIFEST"
  else
    echo "WARNING: $FULL_MANIFEST not found -- falling back to priority set only." >&2
    echo "$PRIORITY_LISTS" | while IFS=$'\t' read -r name url; do
      [[ -z "$name" || -z "$url" ]] && continue
      fetch_one "$name" "$url"
    done
  fi
else
  echo "Fetching priority set (21 lists -- DLP scope + decrypt scope) ..."
  echo "$PRIORITY_LISTS" | while IFS=$'\t' read -r name url; do
    [[ -z "$name" || -z "$url" ]] && continue
    fetch_one "$name" "$url"
  done
fi

echo ""
echo "Done. Summary: $SUMMARY"
echo ""
FAIL_COUNT=$(awk -F'\t' 'NR>1 && $3=="FAIL"' "$SUMMARY" | wc -l | tr -d ' ')
OK_COUNT=$(awk -F'\t' 'NR>1 && $3=="OK"' "$SUMMARY" | wc -l | tr -d ' ')
echo "Succeeded: $OK_COUNT   Failed: $FAIL_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo ""
  echo "If failures are 401/403: these endpoints likely require corporate"
  echo "network access and/or authentication -- set CURL_AUTH_ARGS (see"
  echo "header of this script) and re-run. If failures are connection"
  echo "timeouts: confirm you're on the Aetna corporate network / VPN,"
  echo "since proxyconsole.aetna.com and pxylist.aetna.com are internal-only."
fi
