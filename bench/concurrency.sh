#!/usr/bin/env bash
# concurrency.sh — how a registry behaves as simultaneous pullers pile up.
#
# bench.sh answers "which implementation is faster" at one fixed concurrency.
# This answers a different question: at what point does a registry stop scaling,
# and what does it look like when it does. It sweeps concurrency across a range
# (1 -> 200 by default), runs every selected engine at every point, and reports
# latency percentiles, aggregate throughput, completed pulls/second and
# registry-side CPU for each.
#
# It shares bench.sh's ground rules, for the same reasons:
#   - every engine on one VM, one running at a time, same local NVMe
#   - identical image list in identical order
#   - engine restarted and page cache dropped before every point, so no point
#     inherits the previous one's warm caches
# and adds two of its own:
#   - the work list is round-robin, not grouped. 200 concurrent pulls of one
#     image is a cache benchmark; 200 spread over the corpus is a load test.
#   - pulls per point scale with concurrency, so a 200-client point is not
#     measured from two waves of work.
#
# The provisioning preamble deliberately mirrors bench.sh rather than being
# factored out of it: the two scripts must be able to drift apart (this one has
# no rounds, no managed-registry mode and no baseline column), and a shared
# library that both must satisfy would constrain both.
#
# Usage: see --help.

set -euo pipefail

# ---------- paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
LOADTEST_DIR="$SCRIPT_DIR/loadtest"
REPORTS_DIR="$SCRIPT_DIR/reports"
CONFIG_DIR="$SCRIPT_DIR/config"
ENGINE_CATALOG="$CONFIG_DIR/engines.json"

log()  { printf '[conc %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$ENGINE_CATALOG" ]] || die "engine catalog not found: $ENGINE_CATALOG"

# ---------- defaults ----------
PROVIDER="aws"
ENGINES="summ-release,distribution"
SUMM_RELEASE="v0.1.0-rc.1"
SUMM_SRC="$REPO_ROOT/../summ"
IMAGES_FILE="$CONFIG_DIR/images-concurrency.txt"
SWEEP="1,8,25,50,100,200"
PULLS_PER_CLIENT=5
MIN_PULLS=150
MAX_PULLS=1000
BLOB_CONCURRENCY=3
REPEATS=1
DESTROY=false
SKIP_PROVISION=false
SKIP_POPULATE=false
SKIP_LOADTEST=false
SUMMARY_ONLY=""
RUN_ID="$(date +%Y%m%d-%H%M%S)"

usage() {
  cat <<EOF
Usage: $0 [options]

  --provider <azure|aws>     Cloud provider (default: $PROVIDER)
  --engines <a,b,...>        Engines to sweep (default: $ENGINES)
  --summ-release <tag>       Install summ from this GitHub release tag instead
                             of building the working tree (default: $SUMM_RELEASE).
                             Pass "" to build from --summ-src instead.
  --summ-src <path>          Working tree to build when --summ-release is empty
  --images <file>            Image corpus (default: $(basename "$IMAGES_FILE"))
  --sweep <c1,c2,...>        Concurrency levels (default: $SWEEP)
  --pulls-per-client <n>     Pulls per point = n x concurrency (default: $PULLS_PER_CLIENT)
  --min-pulls <n>            Floor on pulls per point (default: $MIN_PULLS)
  --max-pulls <n>            Ceiling on pulls per point (default: $MAX_PULLS)
  --blob-concurrency <n>     Per-image blob fanout (default: $BLOB_CONCURRENCY)
  --repeats <n>              Repeat the whole sweep n times, interleaved
                             (default: $REPEATS)
  --destroy                  terraform destroy at the end
  --keep                     Leave infra running (default)
  --skip-provision           Reuse existing terraform state and VM setup
  --skip-populate            Reuse existing registry contents
  --skip-loadtest            Provision and populate only
  --summary-only <run-dir>   Re-render summary.md from the JSON reports already
                             in that directory. Touches no cloud resources, so a
                             report can be reworked long after the VMs are gone.
  -h, --help                 This help

Available engines:
$(jq -r '.engines | to_entries[] | "  \(.key)\(" " * (16 - (.key | length)))\(.value.label)"' "$ENGINE_CATALOG")
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)          PROVIDER="$2"; shift 2 ;;
    --engines)           ENGINES="$2"; shift 2 ;;
    --summ-release)      SUMM_RELEASE="$2"; shift 2 ;;
    --summ-src)          SUMM_SRC="$2"; shift 2 ;;
    --images)            IMAGES_FILE="$2"; shift 2 ;;
    --sweep)             SWEEP="$2"; shift 2 ;;
    --pulls-per-client)  PULLS_PER_CLIENT="$2"; shift 2 ;;
    --min-pulls)         MIN_PULLS="$2"; shift 2 ;;
    --max-pulls)         MAX_PULLS="$2"; shift 2 ;;
    --blob-concurrency)  BLOB_CONCURRENCY="$2"; shift 2 ;;
    --repeats)           REPEATS="$2"; shift 2 ;;
    --destroy)           DESTROY=true; shift ;;
    --keep)              DESTROY=false; shift ;;
    --skip-provision)    SKIP_PROVISION=true; shift ;;
    --skip-populate)     SKIP_POPULATE=true; shift ;;
    --skip-loadtest)     SKIP_LOADTEST=true; shift ;;
    --summary-only)      SUMMARY_ONLY="$2"; shift 2 ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -n "$SUMMARY_ONLY" ]]; then
  [[ -d "$SUMMARY_ONLY" ]] || die "--summary-only: no such directory: $SUMMARY_ONLY"
  SKIP_PROVISION=true; SKIP_POPULATE=true; SKIP_LOADTEST=true; DESTROY=false
fi

[[ "$PROVIDER" == "azure" || "$PROVIDER" == "aws" ]] || die "unsupported provider '$PROVIDER'"
[[ "$REPEATS" =~ ^[0-9]+$ && "$REPEATS" -ge 1 ]] || die "--repeats must be a positive integer"

SWEEP_LIST="$(echo "$SWEEP" | tr ',' ' ')"
for c in $SWEEP_LIST; do
  [[ "$c" =~ ^[0-9]+$ && "$c" -ge 1 ]] || die "--sweep entry '$c' is not a positive integer"
done

ENGINE_LIST="$(echo "$ENGINES" | tr ',' ' ')"
[[ -n "${ENGINE_LIST// /}" ]] || die "--engines is empty"

needs_summ=false
for e in $ENGINE_LIST; do
  jq -e --arg e "$e" '.engines[$e]' "$ENGINE_CATALOG" >/dev/null 2>&1 \
    || die "unknown engine '$e'. Known: $(jq -r '.engines | keys | join(", ")' "$ENGINE_CATALOG")"
  req="$(jq -r --arg e "$e" '.engines[$e].requires_provider // ""' "$ENGINE_CATALOG")"
  [[ -z "$req" || "$req" == "$PROVIDER" ]] \
    || die "engine '$e' requires --provider $req (running $PROVIDER)"
  [[ "$(jq -r --arg e "$e" '.engines[$e].kind' "$ENGINE_CATALOG")" == "summ" ]] && needs_summ=true
done

# A summ engine needs a binary from somewhere: a release tag, or a local tree.
if [[ "$needs_summ" == true && -z "$SUMM_RELEASE" ]]; then
  [[ -d "$SUMM_SRC" ]] || die "summ source not found at $SUMM_SRC (set --summ-src or --summ-release)"
  [[ -f "$SUMM_SRC/summ-server/Cargo.toml" ]] \
    || die "$SUMM_SRC does not look like the summ workspace (no summ-server/Cargo.toml)"
  SUMM_SRC="$(cd "$SUMM_SRC" && pwd)"
fi

case "$PROVIDER" in
  azure) TERRAFORM_DIR="$SCRIPT_DIR/terraform/azure" ;;
  aws)   TERRAFORM_DIR="$SCRIPT_DIR/terraform/aws" ;;
esac

# ---------- prereqs ----------
require() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }
log "checking prerequisites..."
for t in terraform ansible-playbook jq ssh scp rsync bc; do require "$t"; done
case "$PROVIDER" in
  azure) require az; az account show >/dev/null 2>&1 || die "az not logged in" ;;
  aws)   require aws; aws sts get-caller-identity >/dev/null 2>&1 \
           || die "aws not authenticated (set AWS_PROFILE or run aws configure)" ;;
esac

[[ -f "$IMAGES_FILE" ]] || die "images file not found: $IMAGES_FILE"
N_IMAGES="$(grep -cvE '^[[:space:]]*(#|$)' "$IMAGES_FILE" || true)"
[[ "$N_IMAGES" -gt 0 ]] || die "no image refs in $IMAGES_FILE"

if [[ ! -f "$TERRAFORM_DIR/terraform.tfvars" && "$SKIP_PROVISION" == false ]]; then
  die "Missing $TERRAFORM_DIR/terraform.tfvars"
fi

RUN_DIR="$REPORTS_DIR/conc-$RUN_ID"
if [[ -n "$SUMMARY_ONLY" ]]; then
  RUN_DIR="$(cd "$SUMMARY_ONLY" && pwd)"
  RUN_ID="$(basename "$RUN_DIR" | sed 's/^conc-//')"
  ENGINE_SPEC="$RUN_DIR/engines-selected.json"
  [[ -f "$ENGINE_SPEC" ]] || die "--summary-only: $ENGINE_SPEC not found"
  # The sweep and engine list are whatever the directory actually contains, not
  # whatever the defaults say: re-rendering must describe the run that happened.
  ENGINE_LIST="$(jq -r '.selected_engines[].name' "$ENGINE_SPEC" | tr '\n' ' ')"
  SWEEP_LIST="$(ls "$RUN_DIR"/report-*-c*-r*.json 2>/dev/null \
    | sed -E 's|.*-c([0-9]+)-r[0-9]+\.json|\1|' | sort -n -u | tr '\n' ' ')"
  SWEEP="$(echo "$SWEEP_LIST" | tr ' ' ',' | sed 's/,$//')"
  [[ -n "${ENGINE_LIST// /}" ]] || die "--summary-only: no report-*.json files in $RUN_DIR"
  REPEATS="$(ls "$RUN_DIR"/report-*-r*.json | sed -E 's|.*-r([0-9]+)\.json|\1|' | sort -n -u | tail -1)"
  log "re-rendering $RUN_DIR (engines:${ENGINE_LIST} sweep: $SWEEP)"
else
  mkdir -p "$RUN_DIR"
  log "run directory: $RUN_DIR"
fi

# Defined ahead of the cloud phases because the summary needs it too, and the
# summary runs in --summary-only mode where none of those phases execute.
engine_field() { jq -r --arg n "$1" --arg f "$2" '.selected_engines[] | select(.name == $n) | .[$f]' "$ENGINE_SPEC"; }

# ---------- 1. terraform ----------
if [[ -z "$SUMMARY_ONLY" ]]; then
if [[ "$SKIP_PROVISION" == false ]]; then
  log "terraform init"
  terraform -chdir="$TERRAFORM_DIR" init -input=false -upgrade >/dev/null
  log "terraform apply"
  terraform -chdir="$TERRAFORM_DIR" apply -input=false -auto-approve
fi

TF_RAW="$(terraform -chdir="$TERRAFORM_DIR" output -json)"
tf() { jq -r --arg k "$1" '.[$k].value // ""' <<<"$TF_RAW"; }

# Redacted before it lands in the run directory, which gets uploaded wholesale.
jq 'with_entries(if .value.sensitive == true then .value.value = "[redacted]" else . end)' \
  <<<"$TF_RAW" > "$RUN_DIR/terraform.json"

REG_PUB="$(tf registry_public_ip)"
REG_PRIV="$(tf registry_private_ip)"
LT_PUB="$(tf loadtester_public_ip)"
ADMIN="$(tf admin_username)"
SSH_KEY="$(tf ssh_private_key_path)"

[[ -n "$REG_PUB" && -n "$LT_PUB" ]] || die "terraform outputs are empty — did apply run?"
log "registry   vm: $REG_PUB (private $REG_PRIV)"
log "loadtester vm: $LT_PUB"

# ---------- 2. engine spec ----------
ENGINE_SPEC="$RUN_DIR/engines-selected.json"
SUMM_REV="n/a"
if [[ "$needs_summ" == true ]]; then
  if [[ -n "$SUMM_RELEASE" ]]; then
    SUMM_REV="$SUMM_RELEASE"
    log "summ: release $SUMM_RELEASE"
  else
    if git -C "$SUMM_SRC" rev-parse HEAD >/dev/null 2>&1; then
      SUMM_REV="$(git -C "$SUMM_SRC" rev-parse --short HEAD)"
      git -C "$SUMM_SRC" diff --quiet || SUMM_REV="$SUMM_REV-dirty"
    fi
    log "summ: source $SUMM_SRC @ $SUMM_REV"
  fi
fi

jq --arg names "$ENGINES" --arg summ_src "$SUMM_SRC" --arg summ_rev "$SUMM_REV" \
   --arg cloud "$PROVIDER" '
  . as $cfg
  | {
      cloud: $cloud,
      summ_src: $summ_src,
      summ_src_rev: $summ_rev,
      distribution_version: $cfg.distribution_version,
      selected_engines: [
        ($names | split(",") | map(select(length > 0))[]) as $n
        | $cfg.engines[$n] + {
            name: $n,
            data_dir: ($cfg.registry_data_root + "/" + $n),
            unit: ("bench-registry-" + $n + ".service")
          }
      ]
    }' "$ENGINE_CATALOG" > "$ENGINE_SPEC"

log "engines: $(jq -r '.selected_engines | map("\(.name):\(.port)") | join("  ")' "$ENGINE_SPEC")"

# ---------- 3. inventory ----------
INV="$ANSIBLE_DIR/inventory/${PROVIDER}.ini"
mkdir -p "$ANSIBLE_DIR/inventory"
{
  printf '[registry]\n%s ansible_user=%s ansible_ssh_private_key_file=%s ansible_python_interpreter=/usr/bin/python3\n\n' \
    "$REG_PUB" "$ADMIN" "$SSH_KEY"
  printf '[loadtester]\n%s ansible_user=%s ansible_ssh_private_key_file=%s ansible_python_interpreter=/usr/bin/python3\n\n' \
    "$LT_PUB" "$ADMIN" "$SSH_KEY"
  printf "[all:vars]\nansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'\n"
} > "$INV"

# ---------- 4. wait for SSH ----------
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
ssh_lt()  { ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$ADMIN@$LT_PUB" "$@"; }
ssh_reg() { ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" "$ADMIN@$REG_PUB" "$@"; }

ssh_wait() {
  local ip="$1"
  for _ in $(seq 1 40); do
    ssh -i "$SSH_KEY" "${SSH_OPTS[@]}" -o ConnectTimeout=5 "$ADMIN@$ip" 'echo ok' >/dev/null 2>&1 && return 0
    sleep 5
  done
  die "SSH to $ip timed out"
}
log "waiting for SSH..."
ssh_wait "$REG_PUB"
ssh_wait "$LT_PUB"

# ---------- 5. ansible ----------
export ANSIBLE_CONFIG="$ANSIBLE_DIR/ansible.cfg"

if [[ "$SKIP_PROVISION" == false ]]; then
  storage_vars=()
  case "$PROVIDER" in
    azure) storage_vars=(
             --extra-vars "azure_storage_account=$(tf storage_account_name)"
             --extra-vars "azure_storage_key=$(tf storage_account_key)"
             --extra-vars "azure_storage_container=$(tf registry_blob_container)" ) ;;
    aws)   storage_vars=(
             --extra-vars "s3_bucket=$(tf s3_registry_bucket)"
             --extra-vars "s3_region=$(tf aws_region)" ) ;;
  esac

  log "ansible: registry-setup.yml"
  ansible-playbook -i "$INV" "$ANSIBLE_DIR/registry-setup.yml" \
    --extra-vars "@$ENGINE_SPEC" \
    --extra-vars "summ_release=$SUMM_RELEASE" \
    "${storage_vars[@]}"

  log "ansible: loadtester-setup.yml"
  ansible-playbook -i "$INV" "$ANSIBLE_DIR/loadtester-setup.yml" \
    --extra-vars "loadtest_local_dir=$LOADTEST_DIR" \
    --extra-vars "cloud=$PROVIDER"
fi

# ---------- 5b. kernel limits for the high-concurrency points ----------
# 200 pulls x 3 blob fetches is ~600 sockets on each side, opened in a burst.
# Stock somaxconn (4096 on noble) is fine; the accept backlog and the file
# descriptor ceiling are not, and a run that fails here fails as "connection
# reset" in the report, where it reads like a registry defect.
log "raising connection limits on both VMs"
tune='sudo sysctl -qw net.core.somaxconn=8192 net.ipv4.tcp_max_syn_backlog=16384 \
        net.ipv4.ip_local_port_range="10240 65535" net.ipv4.tcp_fin_timeout=15 || true'
ssh_reg "$tune"
ssh_lt  "$tune"

scp -q -i "$SSH_KEY" "${SSH_OPTS[@]}" "$SCRIPT_DIR/reg-counters.sh" "$ADMIN@$REG_PUB:/tmp/reg-counters.sh"
ssh_reg "chmod +x /tmp/reg-counters.sh"

# ---------- engine lifecycle ----------
ALL_UNITS="$(jq -r '.selected_engines | map(.unit) | join(" ")' "$ENGINE_SPEC")"

stop_all_engines() { ssh_reg "sudo systemctl stop $ALL_UNITS 2>/dev/null || true"; }

wait_engine() {
  local name="$1" unit port
  unit="$(engine_field "$name" unit)"; port="$(engine_field "$name" port)"
  ssh_reg "for i in \$(seq 1 60); do
             curl -sf -o /dev/null http://127.0.0.1:$port/v2/ && exit 0
             sleep 1
           done
           echo 'engine $name did not become healthy on :$port' >&2
           sudo journalctl -u $unit -n 40 --no-pager >&2
           exit 1" || die "engine '$name' failed to become healthy"
}

start_engine() { ssh_reg "sudo systemctl start $(engine_field "$1" unit)"; wait_engine "$1"; }

start_all_engines() {
  ssh_reg "sudo systemctl start $ALL_UNITS"
  for e in $ENGINE_LIST; do wait_engine "$e"; done
}

drop_caches() { ssh_reg "sudo sync && sudo bash -c 'echo 3 > /proc/sys/vm/drop_caches'"; }

# ---------- 6. populate ----------
if [[ "$SKIP_POPULATE" == false ]]; then
  log "populating ${ENGINES//,/, } with $N_IMAGES images from $(basename "$IMAGES_FILE")"
  scp -q -i "$SSH_KEY" "${SSH_OPTS[@]}" \
      "$SCRIPT_DIR/populate.sh" "$IMAGES_FILE" "$ENGINE_SPEC" "$ADMIN@$REG_PUB:/tmp/"
  start_all_engines
  ssh_reg "bash /tmp/populate.sh /tmp/$(basename "$IMAGES_FILE") /tmp/engines-selected.json /tmp/populate-report.json"
  scp -q -i "$SSH_KEY" "${SSH_OPTS[@]}" \
      "$ADMIN@$REG_PUB:/tmp/populate-report.json" "$RUN_DIR/populate-report.json"
  stop_all_engines
fi

# ---------- 7. the sweep ----------
REMOTE_IMAGES="/tmp/images-conc-${RUN_ID}.txt"
DIST_VERSION="$(jq -r '.distribution_version' "$ENGINE_SPEC")"

if [[ "$SKIP_LOADTEST" == false ]]; then
  scp -q -i "$SSH_KEY" "${SSH_OPTS[@]}" "$IMAGES_FILE" "$ADMIN@$LT_PUB:$REMOTE_IMAGES"

  # pulls at concurrency c, clamped. A point must be several waves of work or
  # its percentiles describe the ramp-up rather than the steady state.
  pulls_for() {
    local c="$1" p
    p=$(( c * PULLS_PER_CLIENT ))
    [[ "$p" -lt "$MIN_PULLS" ]] && p="$MIN_PULLS"
    [[ "$p" -gt "$MAX_PULLS" ]] && p="$MAX_PULLS"
    echo "$p"
  }

  run_point() {
    local name="$1" conc="$2" repeat="$3"
    local port kind version unit out pulls iters before after
    port="$(engine_field "$name" port)"
    kind="$(engine_field "$name" kind)"
    unit="$(engine_field "$name" unit)"
    case "$kind" in summ) version="$SUMM_REV" ;; *) version="$DIST_VERSION" ;; esac

    pulls="$(pulls_for "$conc")"
    iters=$(( (pulls + N_IMAGES - 1) / N_IMAGES ))
    out="report-${name}-c${conc}-r${repeat}.json"

    log "repeat $repeat/$REPEATS  c=$conc  engine=$name ($version)  pulls=$pulls"

    stop_all_engines
    start_engine "$name"
    drop_caches

    before="$(ssh_reg "/tmp/reg-counters.sh $unit")"

    # ulimit is raised in the same shell that runs the binary: at c=200 the
    # client holds ~600 sockets, well over the 1024 soft default.
    ssh_lt "ulimit -n 262144
      RUST_LOG=warn /home/$ADMIN/loadtest/target/release/loadtest \
        --target http://$REG_PRIV:$port \
        --scenario $name \
        --engine-label $(printf '%q' "$(engine_field "$name" label)") \
        --engine-version $version \
        --round $repeat \
        --images-file $REMOTE_IMAGES \
        --image-order round-robin \
        --concurrency $conc \
        --iterations $iters \
        --max-pulls $pulls \
        --blob-concurrency $BLOB_CONCURRENCY \
        --output /tmp/$out"

    after="$(ssh_reg "/tmp/reg-counters.sh $unit")"

    scp -q -i "$SSH_KEY" "${SSH_OPTS[@]}" "$ADMIN@$LT_PUB:/tmp/$out" "$RUN_DIR/$out"

    # Fold the registry-side counters into the report so one file per point
    # carries both the client's view and the server's.
    jq --arg conc "$conc" --arg before "$before" --arg after "$after" '
      ($before | split(" ") | map(tonumber)) as $b
      | ($after  | split(" ") | map(tonumber)) as $a
      | (($a[2] - $b[2]) // 0) as $cpu_total
      | . + {
          sweep_concurrency: ($conc | tonumber),
          registry: {
            window_seconds: ($a[0] - $b[0]),
            cpu_percent:      (if $cpu_total > 0 then ($a[1] - $b[1]) * 100 / $cpu_total else null end),
            engine_cpu_percent:(if $cpu_total > 0 then ($a[5] - $b[5]) * 100 / $cpu_total else null end),
            tx_bytes: ($a[4] - $b[4]),
            rx_bytes: ($a[3] - $b[3]),
            tx_mb_per_sec: (if ($a[0] - $b[0]) > 0 then ($a[4] - $b[4]) / 1048576 / ($a[0] - $b[0]) else null end)
          }
        }' "$RUN_DIR/$out" > "$RUN_DIR/$out.tmp" && mv "$RUN_DIR/$out.tmp" "$RUN_DIR/$out"

    stop_all_engines
  }

  # Concurrency outermost, engines innermost: the two engines at a given point
  # run back to back, so if the machine drifts over the hour it moves both
  # halves of a comparison together instead of one of them.
  for repeat in $(seq 1 "$REPEATS"); do
    for conc in $SWEEP_LIST; do
      for engine in $ENGINE_LIST; do
        run_point "$engine" "$conc" "$repeat"
      done
    done
  done
fi

fi  # end of the cloud phases

# ---------- 8. summary ----------
SUMMARY_MD="$RUN_DIR/summary.md"
log "rendering summary -> $SUMMARY_MD"

# Percentiles are pooled from raw samples across repeats, never averaged from
# each repeat's percentiles: the mean of two p95s is not the p95 of the union.
POOL_JQ='
def pct($p): if length == 0 then 0 else .[((($p / 100) * (length - 1)) | floor)] end;
def r2: . * 100 | round / 100;
[ inputs ] as $reports
| ($reports | map(.samples[] | select(.ok))) as $ok
| ($reports | map(.samples[] | select(.ok | not)) | length) as $failed
| ($ok | map(.duration_ms) | sort) as $d
| ($reports | map(.wall_clock_seconds) | add) as $wall
| ($ok | map(.bytes) | add // 0) as $bytes
| {
    engine:  $reports[0].scenario,
    label:   ($reports[0].engine_label // $reports[0].scenario),
    version: ($reports[0].engine_version // ""),
    conc:    ($reports[0].sweep_concurrency // $reports[0].concurrency),
    runs:    ($reports | length),
    ok:      ($ok | length),
    failed:  $failed,
    bytes:   $bytes,
    wall:    $wall,
    agg_mb_s:   (if $wall > 0 then ($bytes / 1048576 / $wall | r2) else 0 end),
    pulls_s:    (if $wall > 0 then (($ok | length) / $wall | r2) else 0 end),
    d50: ($d | pct(50) | r2), d90: ($d | pct(90) | r2), d95: ($d | pct(95) | r2),
    d99: ($d | pct(99) | r2), dmax: (($d | max) // 0 | r2),
    cpu:     ([$reports[].registry.cpu_percent        | select(. != null)] | if length > 0 then (add / length | r2) else null end),
    eng_cpu: ([$reports[].registry.engine_cpu_percent | select(. != null)] | if length > 0 then (add / length | r2) else null end),
    tx_mb_s: ([$reports[].registry.tx_mb_per_sec      | select(. != null)] | if length > 0 then (add / length | r2) else null end)
  }'

POOLED="$RUN_DIR/.pooled.jsonl"
: > "$POOLED"
for engine in $ENGINE_LIST; do
  for conc in $SWEEP_LIST; do
    files=( "$RUN_DIR"/report-"$engine"-c"$conc"-r*.json )
    [[ -f "${files[0]}" ]] || continue
    jq -n "$POOL_JQ" "${files[@]}" >> "$POOLED"
  done
done

PRIMARY="$(echo "$ENGINE_LIST" | awk '{print $1}')"
N_ENGINES="$(echo "$ENGINE_LIST" | wc -w | tr -d ' ')"

{
  echo "# Registry pull performance under concurrency — $RUN_ID"
  echo
  echo "One VM, one engine running at a time, same local NVMe, same image list in"
  echo "the same order. Concurrency is swept; everything else is held still."
  echo
  echo "| Setting | Value |"
  echo "|---------|-------|"
  echo "| Provider | $PROVIDER |"
  echo "| Registry VM | $(jq -r '.instance_type_registry.value // "n/a"' "$RUN_DIR/terraform.json" 2>/dev/null || echo n/a) |"
  echo "| Corpus | \`$(basename "$IMAGES_FILE")\` — $N_IMAGES images |"
  echo "| Concurrency sweep | $SWEEP |"
  echo "| Pulls per point | ${PULLS_PER_CLIENT}× concurrency, clamped to [$MIN_PULLS, $MAX_PULLS] |"
  echo "| Blob fanout per pull | $BLOB_CONCURRENCY |"
  echo "| Image order | round-robin over the corpus |"
  echo "| Repeats | $REPEATS |"
  echo "| Engines | $(jq -r '.selected_engines | map(.label) | join(", ")' "$ENGINE_SPEC") |"
  echo

  for engine in $ENGINE_LIST; do
    label="$(engine_field "$engine" label)"
    echo "## $label"
    echo
    echo "| Concurrency | Pulls ok/fail | Aggregate MB/s | Pulls/s | p50 ms | p90 ms | p95 ms | p99 ms | max ms | Registry CPU % | Engine CPU % |"
    echo "|---|---|---|---|---|---|---|---|---|---|---|"
    jq -r --arg e "$engine" 'select(.engine == $e)
      | "| \(.conc) | \(.ok)/\(.failed) | \(.agg_mb_s) | \(.pulls_s) | \(.d50) | \(.d90) | \(.d95) | \(.d99) | \(.dmax) | \(.cpu // "—") | \(.eng_cpu // "—") |"' "$POOLED"
    echo
    echo "> Registry CPU % is the whole 8-vCPU machine (100% = one core saturated,"
    echo "> 800% = all eight). Engine CPU % is the registry process alone, so the"
    echo "> gap between the two is kernel time spent on its behalf — network stack"
    echo "> and page cache."
    echo
  done

  if [[ "$N_ENGINES" -gt 1 ]]; then
    echo "## Head to head"
    echo
    echo "Every point, with \`$PRIMARY\` as the reference. Each ratio is stated so"
    echo "that **above 1.00× means \`$PRIMARY\` is ahead** on that metric: throughput is"
    echo "$PRIMARY ÷ that row, latency is that row ÷ $PRIMARY. So \`2.00×\` in a latency"
    echo "column means that engine took twice as long as $PRIMARY at that concurrency."
    echo
    echo "| Concurrency | Engine | Aggregate MB/s | vs $PRIMARY | p50 ms | vs $PRIMARY | p99 ms | vs $PRIMARY |"
    echo "|---|---|---|---|---|---|---|---|"
    for conc in $SWEEP_LIST; do
      jq -r -s --arg p "$PRIMARY" --arg c "$conc" '
        def r2: . * 100 | round / 100;
        map(select(.conc == ($c | tonumber))) as $rows
        | ($rows | map(select(.engine == $p)) | first) as $base
        | if $base == null then empty else
            $rows[]
            | . as $r
            | if $r.engine == $p
              then "| \($c) | **\($r.engine)** | \($r.agg_mb_s) | — | \($r.d50) | — | \($r.d99) | — |"
              else "| \($c) | \($r.engine) | \($r.agg_mb_s) | \(if $r.agg_mb_s > 0 then (($base.agg_mb_s / $r.agg_mb_s) | r2 | tostring) + "×" else "—" end) | \($r.d50) | \(if $base.d50 > 0 then (($r.d50 / $base.d50) | r2 | tostring) + "×" else "—" end) | \($r.d99) | \(if $base.d99 > 0 then (($r.d99 / $base.d99) | r2 | tostring) + "×" else "—" end) |"
              end
          end' "$POOLED"
    done
    echo
  fi

  echo "## How to read this"
  echo
  echo "- **Aggregate MB/s** is the honest headline: total bytes delivered ÷ wall"
  echo "  clock. Per-pull throughput rises and falls with concurrency for"
  echo "  arithmetic reasons; this does not."
  echo "- **p99 against p50** is where a registry's concurrency behaviour shows."
  echo "  Both rising together is queueing, which is expected once the link is"
  echo "  full. p99 pulling away from p50 is contention inside the server."
  echo "- **Failures are not a footnote.** A point with a non-zero fail count is"
  echo "  not a faster point; read the failure column before the latency columns."
  echo "- Every point starts with the engine restarted and the page cache dropped,"
  echo "  so the first pulls of each point are genuinely cold. The corpus is"
  echo "  smaller than RAM, so later pulls in a long point are served warm — this"
  echo "  measures the request path, not the disk."

  if [[ -f "$RUN_DIR/populate-report.json" ]]; then
    echo
    echo "## Corpus"
    echo
    jq -r '[.images[] | select(.ok)] as $ok
      | "\($ok | length) images mirrored, "
        + (([$ok[].size_bytes] | add / 1073741824 * 100 | round / 100 | tostring))
        + " GB of linux/amd64 content (0 means a multi-arch index, whose size the"
        + " manifest does not carry)."' "$RUN_DIR/populate-report.json"
  fi
} > "$SUMMARY_MD"

rm -f "$POOLED"
cat "$SUMMARY_MD"

# ---------- 9. upload ----------
if [[ -n "$SUMMARY_ONLY" ]]; then
  log "summary-only: $SUMMARY_MD re-rendered; no cloud resources touched"
  exit 0
fi

case "$PROVIDER" in
  aws)
    S3_REPORTS_BUCKET="$(tf s3_reports_bucket)"
    AWS_REGION="$(tf aws_region)"
    if [[ -n "$S3_REPORTS_BUCKET" ]]; then
      log "uploading reports to s3://$S3_REPORTS_BUCKET/conc-$RUN_ID/"
      for f in "$RUN_DIR"/*; do
        [[ -f "$f" ]] || continue
        aws s3 cp "$f" "s3://$S3_REPORTS_BUCKET/conc-$RUN_ID/$(basename "$f")" \
          --region "$AWS_REGION" >/dev/null 2>&1 || log "WARN: upload $(basename "$f") failed"
      done
    fi
    ;;
esac

# ---------- 10. teardown ----------
log "reports saved to: $RUN_DIR"
if [[ "$DESTROY" == true ]]; then
  log "terraform destroy"
  terraform -chdir="$TERRAFORM_DIR" destroy -input=false -auto-approve
  log "infrastructure destroyed"
else
  log "leaving infra running. To destroy: terraform -chdir=$TERRAFORM_DIR destroy"
fi
