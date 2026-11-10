#!/usr/bin/env bash
#
# preDestroy hook for the Bar (OCI/CAPOCI) payload.
#
# Runs before `destroy cluster` tears the infrastructure down
# (pkg/destroy/external/external.go:118, ahead of the delete at :121).
#
# Removes what the other two phases created, and does one thing they did not:
# it puts the OCIClusterIdentity Secret back into the installer's local
# control plane. WITHOUT THAT THE TEARDOWN HANGS FOREVER AND THE WHOLE NETWORK
# LEAKS -- the installer does not persist Secrets across runs
# (pkg/infrastructure/clusterapi/clusterapi.go:696-700), so on a fresh destroy
# CAPOCI has no credential, cannot authenticate, and never finishes
# reconciling the delete.
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
expect_hook pre-destroy
reject_args "$@"

# ---------------------------------------------------------------------------
# pre-destroy
# ---------------------------------------------------------------------------

# The load balancer the cluster's CCM built for the ingress Service is not a
# Cluster API resource and deleting the Cluster will not touch it. Deleting the
# Service makes the CCM remove its own load balancer, which is both tidier and
# more correct than deleting the load balancer behind the CCM's back. If the
# API is already gone, fall back to deleting by tag.
destroy_ingress() {
	local ns name service

	# INPUT_SERVICE BELONGS TO post-provision AND IS NEVER SET IN THIS PHASE.
	#
	# This used to read it into ns and name first and test it for emptiness
	# afterwards, which cannot work under `set -u`: the parameter is unset, not
	# empty, so the first expansion aborts the hook and the guard below it is
	# never reached. Measured on mrb-bar6 2026-11-09 --
	#
	#   pre-destroy.sh: line 32: INPUT_SERVICE: unbound variable
	#
	# -- and the teardown stopped there, with six instances, a VCN and a load
	# balancer still running. It stayed latent until that run because this
	# function is reached only after the bootstrap-ignition cleanup above
	# finds something to clean, which needs the ignition hook to have
	# succeeded; until then every teardown returned before getting here.
	#
	# The default is the Service this payload's own manifests create, which is
	# the same fact post-provision defaults to.
	service=${INPUT_SERVICE:-openshift-ingress/router-external-default}
	ns=${service%%/*}
	name=${service##*/}

	if [[ -n ${OPENSHIFT_INSTALL_KUBECONFIG:-} ]] &&
		kube -n "${ns}" get service "${name}" >/dev/null 2>&1; then
		log "deleting service ${ns}/${name} so the CCM removes its load balancer"
		kube -n "${ns}" delete service "${name}" --wait=true --timeout=5m >/dev/null || true
		return 0
	fi

	# THE FALLBACK IS BY OCID AND BY NOTHING ELSE, and the two things it does
	# not do are both bugs this path had.
	#
	# 1. It used to call `oci lb load-balancer delete`. That is LBaaS; the CCM
	#    builds a NETWORK load balancer (`load-balancer-type: nlb`, set by the
	#    Service annotation). The LBaaS list is empty on this cluster, so the
	#    sweep found nothing and returned 0 -- "already gone" and "I looked in
	#    the wrong service" being the same code path, which is precisely the
	#    hazard a destroy hook always faces: it must be idempotent.
	#
	# 2. It used to match on `contains(display-name, INFRA_ID)`. The CCM's
	#    display name is `<namespace>/<name>/<service-uid>` and contains the
	#    infrastructure ID NOWHERE, so that predicate could never match the
	#    load balancer it was aimed at -- while `<infra-id>-apiserver`, which
	#    is CAPOCI's and must not be touched by this hook, matches it exactly.
	#    A sweep that cannot find its target but can find its neighbour is
	#    worse than no sweep.
	#
	# Both measured 2026-10-01 against run 13's live cluster, along with the
	# reason there is no third option: the CCM tags the load balancer with
	# nothing at all (`freeform-tags: {}`).
	local apps_nlb
	apps_nlb=$(jq -r '.appsNlbId // empty' "${APPS_STATE}" 2>/dev/null || true)
	if [[ -z ${apps_nlb} ]]; then
		log "WARNING: the cluster API is unreachable and no ingress load balancer"
		log "WARNING: OCID was recorded, so there is no safe way to find it: the"
		log "WARNING: CCM tags it with nothing and its name carries neither the"
		log "WARNING: cluster name nor the infrastructure ID. If post-provision"
		log "WARNING: ever ran, look for a network load balancer named"
		log "WARNING: ${ns}/${name}/<uid> in this compartment and delete it by hand."
		return 0
	fi

	if ! oci nlb network-load-balancer get --network-load-balancer-id "${apps_nlb}" \
		>/dev/null 2>&1; then
		log "ingress load balancer is already gone"
		return 0
	fi
	log "cluster API not reachable; deleting the recorded ingress load balancer"
	if oci nlb network-load-balancer delete --network-load-balancer-id "${apps_nlb}" \
		--force --wait-for-state SUCCEEDED >/dev/null 2>&1; then
		log "deleted the ingress load balancer"
	else
		log "WARNING: could not delete ingress load balancer ${apps_nlb}; remove it by hand"
	fi
}

# The bootstrap ignition object and its pre-authenticated request.
#
# The PAR is an unauthenticated URL over the cluster's day-0 secrets. Its
# expiry is a backstop; this is the cleanup. Never log the URL -- it IS the
# credential. Log the object name only.
destroy_bootstrap_ignition() {
	local bucket object par_id

	if [[ ! -f ${IGNITION_STATE} ]]; then
		log "no ${IGNITION_STATE}; no bootstrap ignition object was offloaded"
		return 0
	fi

	bucket=$(jq -r '.ignitionBucket // empty' "${IGNITION_STATE}")
	object=$(jq -r '.ignitionObject // empty' "${IGNITION_STATE}")
	par_id=$(jq -r '.ignitionParId // empty' "${IGNITION_STATE}")

	[[ -n ${bucket} ]] || { log "no bucket recorded in ${IGNITION_STATE}"; return 0; }

	if [[ -n ${par_id} ]]; then
		log "deleting the pre-authenticated request over ${object}"
		oci os preauth-request delete --bucket-name "${bucket}" \
			--par-id "${par_id}" --force >/dev/null 2>&1 ||
			log "pre-authenticated request already gone"
	fi
	if [[ -n ${object} ]]; then
		log "deleting object ${object} from ${bucket}"
		oci os object delete --bucket-name "${bucket}" \
			--object-name "${object}" --force >/dev/null 2>&1 ||
			log "object already gone"
	fi
}

# The listener and backend set added at infra-ready. Normally moot, because
# CAPOCI deletes the whole NLB when the Cluster goes -- but a destroy re-run
# after a partial failure may find the NLB still there, and the standing rule
# is that whatever this hook creates, it removes.
destroy_mcs_listener() {
	local nlb
	nlb=$(jq -r '.nlbId // empty' "${STATE}" 2>/dev/null || true)
	[[ -n ${nlb} ]] || return 0

	oci nlb network-load-balancer get --network-load-balancer-id "${nlb}" >/dev/null 2>&1 || {
		log "NLB ${nlb} is already gone"
		return 0
	}

	# Listener before backend set: OCI refuses to delete a backend set that a
	# listener still points at.
	#
	# Both go through nlb_mutate, and on this path the conflict retry matters
	# more than on the create path. A 409 here would land in an `else` reading
	# "already gone" -- precisely the hazard a destroy hook always faces:
	# "already gone" and "I failed to recognise it" are the same code path and
	# the second one exits 0. The listener delete leaves the load balancer
	# busy, so without the retry the backend-set delete below it would report
	# success having deleted nothing.
	#
	# Stderr is NOT suppressed on either, and the else branches say what they
	# actually know. A teardown that cannot tell "gone" from "refused" is how
	# the *.apps record leaked on the AWS pilot.
	if nlb_mutate "${nlb}" "delete listener ${MCS_LISTENER}" \
		oci nlb listener delete --network-load-balancer-id "${nlb}" \
		--listener-name "${MCS_LISTENER}" --force; then
		log "deleted listener ${MCS_LISTENER}"
	else
		log "listener ${MCS_LISTENER} is already gone, or could not be deleted (see above)"
	fi

	if nlb_mutate "${nlb}" "delete backend set ${MCS_BACKENDSET}" \
		oci nlb backend-set delete --network-load-balancer-id "${nlb}" \
		--backend-set-name "${MCS_BACKENDSET}" --force; then
		log "deleted backend set ${MCS_BACKENDSET}"
	else
		log "backend set ${MCS_BACKENDSET} is already gone, or could not be deleted (see above)"
	fi
}

# Put CAPOCI's credential Secret back into the local control plane before the
# Cluster is deleted.
#
# THIS IS NOT A TIDINESS STEP -- WITHOUT IT THE TEARDOWN CANNOT COMPLETE AND
# THE WHOLE NETWORK LEAKS.
#
# `destroy cluster` rebuilds the local control plane and re-applies the objects
# recorded under <install-dir>/.clusterapi_output/. That recording deliberately
# excludes Secrets:
#
#   // pkg/infrastructure/clusterapi/clusterapi.go:696-700
#   // Skip secrets to avoid writing sensitive data to disk.
#   if gvk.Kind == "Secret" { ... continue }
#
# which is the right call -- an OCI API signing key must not be written into an
# install directory that ends up in a support bundle. But OCIClusterIdentity
# resolves its credentials through a Secret (cloud/util/util.go:118-163), so on
# the destroy path CAPOCI finds nothing, cannot build an OCI client, and the
# OCICluster finalizer is never cleared:
#
#   "Reconciler error" err="Unable to fetch ClientSecret:
#       Secret \"<infra-id>-oci-credentials\" not found" controllerKind="OCICluster"
#   "Cluster still has descendants - waiting for infrastructure cluster deletion"
#
# It spins there forever. Measured 2026-10-01: ten minutes of that loop with
# the VCN, four subnets, two gateways and the NLB all still AVAILABLE.
#
# CAPA never shows this because it authenticates from the controller process's
# own environment, not from a Secret -- so this is a gap the reference provider
# structurally cannot expose, and the first genuinely external provider hits it
# on its first teardown. See README.md.
#
# The hook can repair it because pre-destroy runs BEFORE the delete
# (pkg/destroy/external/external.go:118, ahead of deleteCluster at :121) and
# the local control plane is already up by then. Its kubeconfig is not in the
# hook contract; it is at a fixed path under the install directory
# (pkg/clusterapi/system.go:63, ArtifactsDir = ".clusterapi_output"). Relying
# on an internal path is a wart, and it is recorded as a requirement rather
# than hidden: the contract should hand the hook this kubeconfig.
restore_provider_credentials() {
	local kubeconfig secret
	kubeconfig="${OPENSHIFT_INSTALL_DIR:-.}/.clusterapi_output/envtest.kubeconfig"
	secret="${PROVIDER_CREDENTIALS}"

	if [[ ! -f ${kubeconfig} ]]; then
		log "WARNING: no local control plane kubeconfig at ${kubeconfig};"
		log "WARNING: if CAPOCI cannot find its credential Secret the delete will hang"
		return 0
	fi
	if [[ ! -f ${secret} ]]; then
		log "WARNING: no provider credential Secret at ${secret}."
		log "WARNING: CAPOCI will not be able to authenticate and the OCICluster"
		log "WARNING: finalizer will never clear -- the VCN, subnets, gateways and"
		log "WARNING: NLB will be left behind and must be removed by hand."
		return 0
	fi

	# THE NAME HAS TO BE REWRITTEN, AND APPLYING THE FILE VERBATIM DID NOT WORK.
	#
	# OCIClusterIdentity.spec.principalSecret names ${INFRA_ID}-oci-credentials,
	# which is per-run, while the file on disk is a template the operator keeps
	# across runs -- its metadata.name is a placeholder. Applying it unchanged
	# creates a Secret under the wrong name, CAPOCI still finds nothing, and the
	# finalizer still never clears. Measured on mrb-bar5 2026-11-09: the delete
	# hung on ocicluster.infrastructure.cluster.x-k8s.io until the correctly
	# named Secret was applied by hand, after which the OCICluster, the VCN and
	# the load balancer went away within three minutes.
	#
	# The hook is the right place to do the rewrite because it is the only
	# party that knows both halves: the operator's file and this run's INFRA_ID.
	#
	# Rendered by python rather than sed: the document embeds a PEM private key
	# as a block scalar, and line-oriented munging of a block scalar is exactly
	# the construct that produced the dangling-key bug recorded in the workspace
	# guide. Nothing is written to stdout.
	local renamed
	renamed=$(mktemp) || return 0
	chmod 600 "${renamed}"
	if ! python3 -I - "${secret}" "${INFRA_ID}-oci-credentials" "${renamed}" <<-'PY'
		import sys, yaml
		src, name, dst = sys.argv[1], sys.argv[2], sys.argv[3]
		doc = yaml.safe_load(open(src))
		if not doc or doc.get("kind") != "Secret":
		    sys.exit("%s is not a Secret document" % src)
		doc.setdefault("metadata", {})["name"] = name
		doc["metadata"]["namespace"] = "openshift-cluster-api-guests"
		with open(dst, "w") as f:
		    yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False)
	PY
	then
		rm -f "${renamed}"
		log "WARNING: could not rename the credential Secret to ${INFRA_ID}-oci-credentials;"
		log "WARNING: the delete below will probably hang on the OCICluster finalizer"
		return 0
	fi

	# Retried, because pre-destroy can win a race it should not: the local
	# control plane is started just before this hook and may not be serving on
	# the first attempt. A single try that lost that race is indistinguishable
	# from a credential that does not exist, and the cost of being wrong is
	# cloud resources nobody deletes.
	#
	# apply, not create: a re-run of a failed destroy must not fail here.
	# `oc apply` echoes the object reference only, never Secret data.
	local attempt=0
	while [[ ${attempt} -lt 10 ]]; do
		attempt=$((attempt + 1))
		if oc --kubeconfig "${kubeconfig}" apply -f "${renamed}" >/dev/null 2>&1; then
			rm -f "${renamed}"
			log "restored the CAPOCI credential Secret as ${INFRA_ID}-oci-credentials"
			return 0
		fi
		sleep 6
	done
	rm -f "${renamed}"
	log "WARNING: could not apply the credential Secret to the local control plane"
	log "WARNING: after 60s; the delete below will probably hang on the"
	log "WARNING: OCICluster finalizer, leaving the VCN and NLB behind."
}
main() {
	# First, because everything after it depends on CAPOCI being able to talk
	# to OCI at all.
	restore_provider_credentials

	# The bootstrap ignition object is next, and unconditional -- ahead of the
	# STATE check below rather than after it. It is
	# recorded in a different file, written by the create script before the
	# installer ever started, so an install that failed before infra-ready can
	# still have left an unauthenticated URL over the cluster's day-0 secrets
	# sitting in object storage. That is exactly the case where an early
	# return would be worst.
	destroy_bootstrap_ignition

	if [[ ! -f ${STATE} ]]; then
		log "no ${STATE}; infra-ready left nothing else to remove"
		return 0
	fi

	destroy_ingress
	destroy_mcs_listener

	local zone_id public_zone
	zone_id=$(jq -r '.privateZoneId // empty' "${STATE}")
	public_zone=$(jq -r '.publicZoneId // empty' "${STATE}")

	# The public records first, and by exact name. That zone belongs to the
	# base domain and holds other clusters' records; deleting anything not
	# named here would take out somebody else's cluster.
	if [[ -n ${public_zone} ]]; then
		delete_rrset "${public_zone}" "api.${CLUSTER_DOMAIN}" A GLOBAL
		delete_rrset "${public_zone}" "*.apps.${CLUSTER_DOMAIN}" A GLOBAL
	fi

	# Then the private zone, whole. It was created for this cluster and holds
	# nothing else, so it goes rather than being emptied record by record.
	if [[ -n ${zone_id} ]]; then
		if oci dns zone get --zone-name-or-id "${zone_id}" --scope PRIVATE >/dev/null 2>&1; then
			log "deleting private zone ${CLUSTER_DOMAIN}"
			oci dns zone delete --zone-name-or-id "${zone_id}" --scope PRIVATE \
				--force >/dev/null
		else
			log "private zone is already gone"
		fi
	fi

	rm -f "${STATE}" "${APPS_STATE}" "${CCM_STATE}"
	log "pre-destroy complete"
}

main
