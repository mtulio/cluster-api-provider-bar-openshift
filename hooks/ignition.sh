#!/usr/bin/env bash
#
# ignition hook for the Bar (OCI/CAPOCI) payload.
#
# Runs at the installer's IgnitionProvider point of extension: after the
# Cluster reports its infrastructure ready, so the network and the load
# balancers exist, and BEFORE any Machine is created, so no compute does. It
# is the only hook whose output the installer reads back.
#
# Infrastructure existing by this point is what the hook needs: the bucket and
# the pre-authenticated request below are created against the tenancy and the
# compartment, not against anything a Machine would have brought.
#
# Why this payload needs it, and the Foo payload does not:
#
#   CAPOCI base64-encodes machine user data into instance metadata
#   (cloud/scope/machine.go:353) and OCI caps instance metadata at 32,000
#   bytes. That cap is an OCI SERVICE limit, not a check in CAPOCI -- grep
#   finds no such constant in the provider -- so an oversized document fails
#   at the cloud API with a message about metadata size and nothing that
#   mentions Ignition. bootstrap.ign is hundreds of kilobytes, so it does not
#   fit. CAPA takes the same input and has no such problem, because it stages
#   the ignition inside its own controller: the installer hands it the full
#   document in a Secret and CAPA uploads it to AWSCluster.spec.s3Bucket,
#   entirely downstream of anything the installer reads.
#
# So this hook does for CAPOCI what CAPA's controller does for itself: upload
# the real document to Object Storage and hand back a ~300-byte pointer config.
# It is an escape hatch, not an idiom. The first-class fix is the same offload
# capability upstream in CAPOCI, after which this payload would stop declaring
# the hook and nothing else here would change.
#
# It replaces the pilot's three-phase wrapper script, which did exactly this
# between `create ignition-configs` and `create cluster` and relied on the
# asset store re-reading a changed file from disk. One `create cluster` now,
# and no dependence on behaviour every platform shares.
#
# TWO RULES THIS HOOK MUST NOT BREAK:
#
#   1. It never writes <install-dir>/bootstrap.ign. That name belongs to the
#      installer's own artifact. This hook writes a DIFFERENTLY NAMED file in
#      the directory the installer created for it, so there is never a
#      question of which of two files a later step consumed.
#   2. The pre-authenticated request URL is an unauthenticated credential over
#      every secret in bootstrap.ign -- the MCS TLS key, a CA key, the pull
#      secret, the kubeadmin hash. It is never logged, never echoed, never
#      written to the state file, and never left in the environment. Only its
#      OCID is recorded, because an OCID is an identifier and the URL is a
#      bearer token.
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
expect_hook ignition
reject_args "$@"

# ---------------------------------------------------------------------------
# The two variables only this phase is given.
#
# OPENSHIFT_INSTALL_BOOTSTRAP_IGNITION is the installer's finished bootstrap
# ignition. READ-ONLY: this hook reads those bytes and must not modify the
# file.
#
# OPENSHIFT_INSTALL_HOOK_OUTPUT_DIR is a directory the installer creates for
# this hook and removes after it returns. The descriptor's
# spec.openshift.installerHooks.ignition.bootstrapOutputPath is relative to it, and the
# installer reads that path back once the hook exits 0.
# ---------------------------------------------------------------------------
: "${OPENSHIFT_INSTALL_BOOTSTRAP_IGNITION:?not set -- is this wired as the ignition hook?}"
: "${OPENSHIFT_INSTALL_HOOK_OUTPUT_DIR:?not set -- is this wired as the ignition hook?}"

# A payload variable, not an installer concept. The installer knows nothing
# about buckets and must not: it holds no OCI credentials.
: "${OCI_IGNITION_BUCKET:?set it to a private bucket for the bootstrap ignition}"
: "${OCI_REGION:?set it to the region the bucket lives in}"

BOOTSTRAP_IGN=${OPENSHIFT_INSTALL_BOOTSTRAP_IGNITION}
# Must match spec.openshift.installerHooks.ignition.bootstrapOutputPath in openshift.yaml,
# and must NOT be bootstrap.ign -- see rule 1 above.
OUTPUT="${OPENSHIFT_INSTALL_HOOK_OUTPUT_DIR}/bootstrap-staged.ign"
OBJECT_NAME="${INFRA_ID}/bootstrap.ign"
PAR_NAME="${INFRA_ID}-bootstrap"

# How long the pointer stays usable. Long enough for a bootstrap and no more.
# pre-destroy deletes the request; this expiry is only the backstop for when
# that does not run.
: "${OCI_IGNITION_PAR_TTL_HOURS:=2}"

# OCI's raw instance-metadata budget once base64 expansion is accounted for.
# The pointer is ~300 bytes against this, so the thing that could not fit now
# fits with two orders of magnitude to spare. Checked rather than assumed,
# because a pointer that silently grew would fail at the cloud API with the
# same opaque message the full document did.
RAW_USERDATA_BUDGET=23900

[[ -s ${BOOTSTRAP_IGN} ]] || die "no bootstrap ignition at ${BOOTSTRAP_IGN}"

# Size and hash only. The file is the cluster's day-0 secret material and is
# never printed; the hash is the only durable record of which bytes were
# uploaded, and it is what lets a teardown or a support case refer to this
# document without reproducing it.
BOOTSTRAP_BYTES=$(wc -c <"${BOOTSTRAP_IGN}")
BOOTSTRAP_SHA=$(sha256sum "${BOOTSTRAP_IGN}" | cut -d' ' -f1)
log "bootstrap ignition: ${BOOTSTRAP_BYTES} bytes, sha256 ${BOOTSTRAP_SHA}"

# ---------------------------------------------------------------------------
# Record the teardown handle BEFORE creating anything.
#
# preDestroy reads this file and treats its absence as "nothing to do", so a
# run that dies between the upload and the record would leak an object with
# nothing pointing at it. Writing the bucket and object name first, and the
# PAR id as soon as it exists, narrows that window to a single API call.
#
# It does not close it. If the run dies before the installer has written
# metadata.json, `destroy cluster` cannot discover the provider at all and
# this file is never read. That residual window is an open question in the
# enhancement proposal, not something a payload can solve on its own.
# ---------------------------------------------------------------------------
write_ignition_state() {
	local par_id=${1:-}
	mkdir -p "$(dirname "${IGNITION_STATE}")"
	jq -n \
		--arg bucket "${OCI_IGNITION_BUCKET}" \
		--arg object "${OBJECT_NAME}" \
		--arg par "${par_id}" \
		--arg sha "${BOOTSTRAP_SHA}" \
		'{ignitionBucket:$bucket, ignitionObject:$object, ignitionParId:$par, ignitionSha256:$sha}' \
		>"${IGNITION_STATE}"
}

write_ignition_state ""
log "recorded ${OBJECT_NAME} in ${IGNITION_STATE} before uploading it"

oci os object put \
	--bucket-name "${OCI_IGNITION_BUCKET}" \
	--name "${OBJECT_NAME}" \
	--file "${BOOTSTRAP_IGN}" \
	--content-type application/json \
	--force >/dev/null ||
	die "could not upload ${OBJECT_NAME} to ${OCI_IGNITION_BUCKET}"

log "uploaded ${OBJECT_NAME} to ${OCI_IGNITION_BUCKET}"

PAR_EXPIRY=$(date -u -d "+${OCI_IGNITION_PAR_TTL_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)

# Nothing from here until the unset may be traced or printed. If you add
# `set -x` to this script, suspend it across this block -- a trace line of the
# assignment below publishes the credential.
PAR_JSON=$(oci os preauth-request create \
	--bucket-name "${OCI_IGNITION_BUCKET}" \
	--name "${PAR_NAME}" \
	--object-name "${OBJECT_NAME}" \
	--access-type ObjectRead \
	--time-expires "${PAR_EXPIRY}" 2>/dev/null)

PAR_ID=$(printf '%s' "${PAR_JSON}" | jq -r '.data.id // empty')
PAR_PATH=$(printf '%s' "${PAR_JSON}" | jq -r '.data."access-uri" // empty')
unset PAR_JSON

if [[ -z ${PAR_PATH} ]]; then
	die "could not mint a pre-authenticated request for ${OBJECT_NAME}"
fi

write_ignition_state "${PAR_ID}"
log "minted pre-authenticated request ${PAR_ID}, expiring ${PAR_EXPIRY}"

PAR_URL="https://objectstorage.${OCI_REGION}.oraclecloud.com${PAR_PATH}"

# The pointer config. json.dumps escapes the URL correctly and the heredoc is
# quoted at the python end, so the URL is passed as an argument rather than
# interpolated into the program text -- it never appears in a process listing
# as part of a command line either.
mkdir -p "${OPENSHIFT_INSTALL_HOOK_OUTPUT_DIR}"
PAR_URL="${PAR_URL}" python3 - "${OUTPUT}" <<'PY'
import json, os, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "ignition": {
        "version": "3.2.0",
        "config": {"merge": [{"source": os.environ["PAR_URL"]}]},
    }
}))
PY

unset PAR_URL PAR_PATH PAR_ID

STUB_BYTES=$(wc -c <"${OUTPUT}")
log "wrote a ${STUB_BYTES}-byte pointer config to ${OUTPUT##*/}"

if [[ ${STUB_BYTES} -gt ${RAW_USERDATA_BUDGET} ]]; then
	die "the pointer config is larger than OCI's raw userdata budget (${RAW_USERDATA_BUDGET} bytes); something is wrong"
fi

# The installer parses this file and refuses the install if it is absent or is
# not an Ignition config. Checking here as well means the failure names the
# hook that produced it rather than the installer that read it.
jq -e '.ignition.version' "${OUTPUT}" >/dev/null 2>&1 ||
	die "${OUTPUT##*/} is not a parseable Ignition config"

log "ignition complete; the installer reads ${OUTPUT##*/} in place of its own bootstrap ignition"
