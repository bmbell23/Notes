#!/bin/bash -e
#
#   Seal Analyzer's credentials into the k8s.git fleet files.
#
#   A SealedSecret is encrypted against one (secret name, namespace) pair, so the blobs in one
#   app's fleet file cannot be copied into another's. Standing up the dev pair of apps, or rotating
#   a credential, means sealing every key again for that name and namespace. This script does that
#   and writes the results into the fleet files, so the only manual step is putting the plaintext
#   in a directory.
#
#   Nothing is decrypted here and nothing is read out of the cluster: sealing is one-way and
#   offline, against the public certificate committed in k8s.git.
#
#   What you have to supply, in the -d directory:
#       backend_config.yaml   Analyzer backend config with real values - database, Jira, and the
#                             Gerrit host/user. Start from scripts/backend_config.yaml. The
#                             server.key/server.cert paths are corrected automatically.
#       git.key               SSH private key for 'git archive' against sfa/sfaos.git
#       ldap.conf             Apache mod_authnz_ldap AuthLDAPURL + bind DN and password
#
#   What this script generates, so you do not have to:
#       grpc.key/grpc.crt     gRPC server pair with a SAN naming the target namespace. gRPC checks
#                             the dialled address against the SAN, so each namespace needs its own.
#       config.yaml           Frontend config: a fresh Django secret_key, the backend service
#                             address for the target environment, and the cert path.
#       session_passphrase    Fresh Apache login-cookie key. Nothing outside the pod needs to know
#                             it, so there is no reason to reuse production's.
#
#   Anything already present in the -d directory is used as-is instead of being generated, which is
#   how you reuse a certificate or pin a passphrase.
#
#   Plaintext assembled here is written to a private directory under /dev/shm (tmpfs, never
#   swapped) and deleted on exit, including on failure.
#
#   Examples:
#       # Stand up the dev apps
#       seal_fleet_secrets.sh -d ~/analyzer-secrets \\
#           -a ~/projects/infra/docker/services/triage/Analyzer \\
#           -k ~/projects/k8s-SFAP-106662-analyzer-dev
#
#       # Re-seal production after rotating the Jira token
#       seal_fleet_secrets.sh -e prod -d ~/analyzer-secrets \\
#           -a ~/projects/infra/docker/services/triage/Analyzer -k ~/projects/k8s
script=$(basename "${BASH_SOURCE[0]}")
# This script lives outside infra.git, but it runs Analyzer's own make_ssl.sh and make_passwd.sh and
# reads its config templates, so it needs to be told where a checkout is. -a, or $ANALYZER_ROOT.
analyzer_root="${ANALYZER_ROOT:-}"

ENVIRONMENT="dev"
PLAINTEXT_DIR=""
K8S_REPO="${K8S_REPO:-${HOME}/projects/k8s}"
DRY_RUN=0

function die() {
    echo "ERROR: $*" >&2
    exit 1
}

function usage() {
    cat <<EOF

Usage: ${script} -d DIR -a PATH [-e dev|prod] [-k PATH] [-n]

  -d DIR   Directory holding the plaintext you supply (see the header of this script)
  -e ENV   Which pair of apps to seal for: 'dev' (default) or 'prod'
  -a PATH  infra.git .../docker/services/triage/Analyzer checkout, needed for
           make_ssl.sh, make_passwd.sh and the config templates (or \$ANALYZER_ROOT)
  -k PATH  k8s.git checkout holding sealed-secrets-cert.pem and the fleet files
           (default: ${K8S_REPO}, or \$K8S_REPO)
  -n       Seal and report, but do not modify the fleet files
  -h       This message

EOF
}

while getopts "d:e:k:a:nh" opt; do
    case ${opt} in
        d) PLAINTEXT_DIR="${OPTARG}" ;;
        e) ENVIRONMENT="${OPTARG}" ;;
        k) K8S_REPO="${OPTARG}" ;;
        a) analyzer_root="${OPTARG%/}" ;;
        n) DRY_RUN=1 ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

[[ -n "${PLAINTEXT_DIR}" ]] || { usage; die "-d is required"; }
[[ -d "${PLAINTEXT_DIR}" ]] || die "${PLAINTEXT_DIR} is not a directory"
[[ -n "${analyzer_root}" ]] || { usage; die "-a (or ANALYZER_ROOT) is required"; }
[[ -x "${analyzer_root}/scripts/make_ssl.sh" ]] || \
    die "${analyzer_root} is not an Analyzer checkout"
command -v kubeseal >/dev/null || die "kubeseal is not installed"

# Everything that differs between the two environments. The frontend's backend_host has to be the
# in-cluster address of ITS backend: point dev at the production backend and dev testing runs
# through production's gRPC server.
case "${ENVIRONMENT}" in
    dev)
        backend_app="analyzer-backend-dev"
        backend_ns="app-analyzer-backend-dev"
        backend_secret="analyzer-backend-dev-secrets"
        backend_fleet="analyzer-backend-dev.yaml"
        frontend_ns="app-analyzer-dev"
        frontend_secret="analyzer-dev-secrets"
        frontend_fleet="analyzer-dev.yaml"
        ;;
    prod)
        backend_app="analyzer-backend"
        backend_ns="app-analyzer-backend"
        backend_secret="analyzer-backend-secrets"
        backend_fleet="analyzer-backend.yaml"
        frontend_ns="app-analyzer"
        frontend_secret="analyzer-secrets"
        frontend_fleet="analyzer.yaml"
        ;;
    *) die "-e must be 'dev' or 'prod', not '${ENVIRONMENT}'" ;;
esac

cert="${K8S_REPO}/sealed-secrets-cert.pem"
fleet_dir="${K8S_REPO}/gitops/app-fleet"

################################################################################
#   Print an error naming other k8s checkouts that do carry the fleet file, then exit.
#
#   k8s.git is normally worked in as several git worktrees - one per ticket - so the checkout
#   holding the fleet files being sealed is often not the default one. Sealing into the wrong
#   worktree produces blobs that are correct and a commit that goes nowhere, which is a slow thing
#   to notice. Point at the alternatives instead of just refusing.
#
#   Args:
#       $1: Fleet file that could not be found
################################################################################
function die_wrong_checkout() {
    local wanted=$1
    local candidate
    echo "ERROR: ${fleet_dir}/${wanted} does not exist." >&2
    echo "       -k must point at the k8s.git checkout that holds the fleet file." >&2
    for candidate in "$(dirname "${K8S_REPO}")"/*/gitops/app-fleet/"${wanted}"; do
        [[ -f "${candidate}" ]] || continue
        echo "       Found one in: ${candidate%/gitops/app-fleet/*}" >&2
    done
    exit 1
}

[[ -f "${cert}" ]] || die "No sealing certificate at ${cert} - is -k pointing at a k8s.git checkout?"
for file in "${backend_fleet}" "${frontend_fleet}"; do
    [[ -f "${fleet_dir}/${file}" ]] || die_wrong_checkout "${file}"
done

# tmpfs, so assembled plaintext never reaches a disk. Removed on any exit path.
work_dir="$(mktemp -d /dev/shm/analyzer-seal.XXXXXX)"
chmod 700 "${work_dir}"
trap 'rm -rf "${work_dir}"' EXIT

################################################################################
#   Copy a supplied plaintext file into the work directory, if it exists
#   Args:
#       $1: File name
#   Returns:
#       0 if the file was supplied, 1 if it was not
################################################################################
function take_supplied() {
    local name=$1
    if [[ -f "${PLAINTEXT_DIR}/${name}" ]]; then
        install -m 600 "${PLAINTEXT_DIR}/${name}" "${work_dir}/${name}"
        echo "  ${name}: supplied"
        return 0
    fi
    return 1
}

echo "Sealing for '${ENVIRONMENT}': ${backend_secret}/${backend_ns} and ${frontend_secret}/${frontend_ns}"
echo
echo "Collecting plaintext"

missing=()
for name in backend_config.yaml git.key ldap.conf; do
    take_supplied "${name}" || missing+=("${name}")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo
    echo "Missing from ${PLAINTEXT_DIR}:"
    for name in "${missing[@]}"; do
        echo "  ${name}"
    done
    echo
    die "Cannot seal without those. See the header of this script for what each one is."
fi

# The gRPC pair. A supplied pair is used as-is; otherwise one is generated with a SAN naming the
# target service and namespace, which is what makes it valid for this environment and no other.
if ! take_supplied grpc.key || ! take_supplied grpc.crt; then
    echo "  grpc.key/grpc.crt: generating with a SAN for ${backend_app}.${backend_ns}"
    "${analyzer_root}/scripts/make_ssl.sh" -g -s "${backend_app}" -n "${backend_ns}" \
        >/dev/null 2>&1
    install -m 600 "${analyzer_root}/build/grpc.key" "${work_dir}/grpc.key"
    install -m 600 "${analyzer_root}/build/grpc.crt" "${work_dir}/grpc.crt"
fi

take_supplied session_passphrase || {
    echo "  session_passphrase: generating"
    # printf '%s' rather than echo: a trailing newline ends up inside the passphrase Apache uses.
    printf '%s' "$("${analyzer_root}/scripts/make_passwd.sh")" > "${work_dir}/session_passphrase"
    chmod 600 "${work_dir}/session_passphrase"
}

take_supplied config.yaml || {
    echo "  config.yaml: generating (fresh Django secret_key, backend at ${backend_app}.${backend_ns})"
    DJANGO_KEY="$("${analyzer_root}/scripts/make_passwd.sh")" \
    BACKEND_HOST="${backend_app}.${backend_ns}.svc.cluster.local" \
    python3 - "${analyzer_root}/scripts/config.yaml" "${work_dir}/config.yaml" <<'PYTHON'
import os
import sys
import yaml

template, out = sys.argv[1], sys.argv[2]
with open(template, 'r', encoding='utf-8') as file:
    config = yaml.safe_load(file)
config['django']['secret_key'] = os.environ['DJANGO_KEY']
config['backend']['host'] = os.environ['BACKEND_HOST']
# Where the fleet file mounts the backend's certificate for Django to trust.
config['backend']['cert'] = '/etc/analyzer/django/secrets/grpc.crt'
with open(out, 'w', encoding='utf-8') as file:
    yaml.safe_dump(config, file, default_flow_style=False)
PYTHON
    chmod 600 "${work_dir}/config.yaml"
}

# The backend reads its own key and certificate from the paths the fleet file mounts them at, which
# are not the paths a locally-generated config carries. Correct them rather than making the caller
# remember to.
BACKEND_SECRETS_DIR="/etc/analyzer/backend/secrets" \
python3 - "${work_dir}/backend_config.yaml" <<'PYTHON'
import os
import sys
import yaml

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as file:
    config = yaml.safe_load(file)
secrets = os.environ['BACKEND_SECRETS_DIR']
config['server']['key'] = os.path.join(secrets, 'grpc.key')
config['server']['cert'] = os.path.join(secrets, 'grpc.crt')
config['git']['key'] = os.path.join(secrets, 'git.key')
empty = [
    "{}.{}".format(section, key)
    for section, values in config.items() if isinstance(values, dict)
    for key, value in values.items() if value in (None, '')
]
if empty:
    sys.exit("backend_config.yaml has no value for: {}".format(", ".join(empty)))
with open(path, 'w', encoding='utf-8') as file:
    yaml.safe_dump(config, file, default_flow_style=False)
PYTHON

################################################################################
#   Seal one file and write the blob into a fleet file's encryptedData block
#   Args:
#       $1: Fleet file name
#       $2: Secret name to seal against
#       $3: Namespace to seal against
#       $4: encryptedData key to write the blob under
#       $5: File in the work directory to seal. Defaults to $4, and differs from it only for the
#           two config.yaml files, which share a key name but hold different content.
################################################################################
function seal_into_fleet() {
    local fleet=$1
    local secret=$2
    local namespace=$3
    local key=$4
    local source_file=${5:-$4}
    local blob

    blob="$(kubeseal --raw --cert "${cert}" --scope strict \
                     --name "${secret}" --namespace "${namespace}" \
                     < "${work_dir}/${source_file}")"
    [[ -n "${blob}" ]] || die "kubeseal produced nothing for ${key}"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        echo "  ${key}: sealed (${#blob} chars), fleet file not modified"
        return 0
    fi
    # Targeted replacement of the one line, so the comments explaining the block survive. Each key
    # appears once per fleet file, and the blob is base64 so it needs no YAML quoting.
    FLEET="${fleet_dir}/${fleet}" KEY="${key}" BLOB="${blob}" python3 <<'PYTHON'
import os
import re
import sys

path, key, blob = os.environ['FLEET'], os.environ['KEY'], os.environ['BLOB']
with open(path, 'r', encoding='utf-8') as file:
    lines = file.readlines()
pattern = re.compile(r'^(\s+){}:\s.*$'.format(re.escape(key)))
hits = [i for i, line in enumerate(lines) if pattern.match(line)]
if len(hits) != 1:
    sys.exit("{}: expected exactly one '{}:' line, found {}".format(path, key, len(hits)))
indent = pattern.match(lines[hits[0]]).group(1)
lines[hits[0]] = "{}{}: {}\n".format(indent, key, blob)
with open(path, 'w', encoding='utf-8') as file:
    file.writelines(lines)
PYTHON
    echo "  ${key}: sealed into ${fleet}"
}

echo
echo "Sealing backend keys into ${backend_fleet}"
for key in config.yaml git.key grpc.key grpc.crt; do
    # The backend's config.yaml is supplied under a name that says which half it belongs to, so it
    # is copied to the name the secret uses. The frontend's config.yaml keeps that name, hence the
    # same-file guard.
    if [[ "${key}" == "config.yaml" ]]; then
        cp "${work_dir}/backend_config.yaml" "${work_dir}/config.yaml.backend"
        mv "${work_dir}/config.yaml.backend" "${work_dir}/config.yaml.sealing"
        seal_into_fleet "${backend_fleet}" "${backend_secret}" "${backend_ns}" \
                        "config.yaml" "config.yaml.sealing"
        continue
    fi
    seal_into_fleet "${backend_fleet}" "${backend_secret}" "${backend_ns}" "${key}"
done

echo
echo "Sealing frontend keys into ${frontend_fleet}"
for key in config.yaml grpc.crt ldap.conf session_passphrase; do
    seal_into_fleet "${frontend_fleet}" "${frontend_secret}" "${frontend_ns}" "${key}"
done

echo
if [[ ${DRY_RUN} -eq 1 ]]; then
    echo "Dry run: nothing was written."
    exit 0
fi
cat <<EOF
Done. ${fleet_dir}/{${backend_fleet},${frontend_fleet}} now carry sealed values.

Next:
  1. Review the diff in ${K8S_REPO} - the only changes should be encryptedData lines.
  2. Commit and push. ArgoCD creates the namespaces and starts the apps.
  3. Push images for this environment:
EOF
if [[ "${ENVIRONMENT}" == "dev" ]]; then
    echo "       scripts/push.sh -bD"
else
    echo "       scripts/push.sh -b"
fi
