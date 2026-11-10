#!/usr/bin/env bash
#
# postProvision hook for the Bar (OCI/CAPOCI) payload.
#
# Runs after the cluster is up. The only phase that takes arguments -- and it
# must still work with none, because a payload hook has nowhere to carry a
# command line. The defaults below cover the ordinary case.
#
# Two jobs:
#   1. publish the *.apps wildcard at the ingress load balancer, and place
#      that load balancer in the right network security group
#   2. fill the 22623 backend set infra-ready created empty
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
expect_hook post-provision

# ---------------------------------------------------------------------------
# post-provision
# ---------------------------------------------------------------------------

# BOTH OF THESE MUST HAVE A DEFAULT, AND --input-service NOT HAVING ONE WAS A
# BUG THAT MADE THIS PAYLOAD UNINSTALLABLE.
#
# The installer invokes every hook with an empty argv -- the
# platform.external.clusterAPI.hooks.<hook>.args field was removed from the
# API, and a hook is now fully described by its program path. This file was
# written when that field existed and kept `--input-service` as required, so
# every run reached `--input-service is required for post-provision` and died
# before doing any work at all.
#
# The flags survive for one purpose: re-running this hook by hand against a
# half-finished cluster, from a line copied out of the installer log. In an
# install they are never seen and the defaults below are the whole
# configuration. INPUT_SERVICE names the Service that this payload's own
# ../manifests/99_external-04-ingress-nlb.yaml creates, so it is a fact about
# what ships alongside this file rather than a guess about the environment.
INPUT_SERVICE="openshift-ingress/router-external-default"
TIMEOUT_SECONDS=2700

# Steps that failed but did not stop the hook. Only the first step is
# fail-fast; see main(). The hook runs everything it can and exits non-zero at
# the end naming what broke, because these steps take tens of minutes and each
# leaves something durable behind -- stopping at the first failure throws away
# the work that would have succeeded and makes the operator re-run a long
# install to recover a state they could have reached by hand in a minute.
FAILED_STEPS=()

record_failure() {
	FAILED_STEPS+=("$1")
	# Same "ERROR:" prefix die() uses, so one grep of the hook log finds every
	# failure whether it stopped the hook or not.
	log "ERROR: $1"
}

parse_post_provision_args() {
	while [[ $# -gt 0 ]]; do
		case $1 in
		--input-service=*) INPUT_SERVICE=${1#*=} ;;
		--input-service) INPUT_SERVICE=${2:?--input-service needs a value}; shift ;;
		--timeout-seconds=*) TIMEOUT_SECONDS=${1#*=} ;;
		--timeout-seconds) TIMEOUT_SECONDS=${2:?--timeout-seconds needs a value}; shift ;;
		*) die "unknown argument $1" ;;
		esac
		shift
	done
	[[ -n ${INPUT_SERVICE} ]] || die "--input-service was given an empty value"
	[[ ${INPUT_SERVICE} == */* ]] || die "--input-service must be namespace/name, got ${INPUT_SERVICE}"
	[[ ${TIMEOUT_SECONDS} =~ ^[0-9]+$ ]] || die "--timeout-seconds must be a whole number, got ${TIMEOUT_SECONDS}"
}
# Add every control-plane instance to the 22623 backend set.
#
# CAPOCI does this itself for apiserver-lb-backendset
# (cloud/scope/machine.go:874-895) and only for that one, so the second
# backend set is ours to populate.
#
# The bootstrap machine serves 22623 too, and arguably needs to be a backend
# EARLIER than this -- masters fetch their config on first boot, which is
# before post-provision runs. This is the least-settled part of the design and
# is called out in README.md.
# Put the bootstrap into CAPOCI's own API server backend set.
#
# CAPOCI does this for every machine it considers control-plane and for no
# other (cloud/scope/machine.go:322,337, gated on IsControlPlane()). The
# bootstrap deliberately does not carry that label -- dropping it is what lets
# it be placed in the public subnet, which is where every other reference
# payload puts a bootstrap and the only way `gather bootstrap` can SSH in. The
# masters are registered by CAPOCI as before; only this one machine is missing,
# and without it nothing serves api-int:6443 until the first master is up.
#
# Through nlb_mutate, for the same reason populate_mcs_backends is: a
# concurrent CAPOCI reconcile leaves the load balancer busy and the create
# returns 409.
populate_apiserver_bootstrap_backend() {
	local nlb=$1 compartment_id=$2 ocid ip

	ocid=$(oci compute instance list --compartment-id "${compartment_id}" \
		--lifecycle-state RUNNING \
		--query "data[?\"freeform-tags\".\"openshift-cluster-id\"=='${INFRA_ID}' &&
		          \"freeform-tags\".\"openshift-machine-role\"=='bootstrap'].id" \
		--raw-output 2>/dev/null | jq -r '.[0]? // empty')
	if [[ -z ${ocid} ]]; then
		log "no bootstrap instance tagged for ${INFRA_ID}; not adding an ${APISERVER_PORT} backend"
		return 0
	fi

	ip=$(oci compute instance list-vnics --instance-id "${ocid}" \
		--query 'data[0]."private-ip"' --raw-output 2>/dev/null)
	if [[ -z ${ip} || ${ip} == "null" ]]; then
		log "no private IP for the bootstrap instance; not adding an ${APISERVER_PORT} backend"
		return 0
	fi

	if nlb_mutate "${nlb}" "backend ${ip}:${APISERVER_PORT}" \
		oci nlb backend create \
		--network-load-balancer-id "${nlb}" \
		--backend-set-name "${APISERVER_BACKENDSET}" \
		--ip-address "${ip}" --port "${APISERVER_PORT}" \
		--wait-for-state SUCCEEDED 2>/dev/null; then
		log "added the bootstrap ${ip}:${APISERVER_PORT} to ${APISERVER_BACKENDSET}"
	else
		log "bootstrap ${ip}:${APISERVER_PORT} already a backend, or could not be added"
	fi
}

populate_mcs_backends() {
	local nlb=$1 compartment_id=$2 instances ocid ip count=0

	instances=$(oci compute instance list --compartment-id "${compartment_id}" \
		--lifecycle-state RUNNING \
		--query "data[?\"freeform-tags\".\"openshift-cluster-id\"=='${INFRA_ID}' &&
		          (\"freeform-tags\".\"openshift-machine-role\"=='master' ||
		           \"freeform-tags\".\"openshift-machine-role\"=='bootstrap')].id" \
		--raw-output | jq -r '.[]? // empty')

	[[ -n ${instances} ]] || { log "no control-plane instances tagged for ${INFRA_ID} yet"; return 0; }

	while read -r ocid; do
		[[ -n ${ocid} ]] || continue
		ip=$(oci compute instance list-vnics --instance-id "${ocid}" \
			--query 'data[0]."private-ip"' --raw-output)
		[[ -n ${ip} && ${ip} != "null" ]] || { log "no private IP for ${ocid}; skipping"; continue; }

		# Through nlb_mutate, and the loop is why it matters most here: each
		# successful create leaves the load balancer busy, so the second
		# master is the one that would get the 409. The else branch below
		# would then call it "already a backend" and that master would never
		# serve 22623 -- a silently half-populated backend set, which is worse
		# than a failure because the install goes on to time out somewhere
		# else entirely.
		if nlb_mutate "${nlb}" "backend ${ip}:${MCS_PORT}" \
			oci nlb backend create \
			--network-load-balancer-id "${nlb}" \
			--backend-set-name "${MCS_BACKENDSET}" \
			--ip-address "${ip}" --port "${MCS_PORT}" \
			--wait-for-state SUCCEEDED 2>/dev/null; then
			log "added ${ip}:${MCS_PORT} to ${MCS_BACKENDSET}"
			count=$((count + 1))
		else
			log "${ip}:${MCS_PORT} already a backend, or could not be added"
		fi
	done <<<"${instances}"

	log "${count} backend(s) added to ${MCS_BACKENDSET}"
}

# ------------------------------------------- node certificate approval
#
# Nothing in an `external` cluster approves a kubelet's certificate, and the
# component that normally would is running the whole time. A node joins in two
# steps, each gated on a CSR: a client certificate
# (kubernetes.io/kube-apiserver-client-kubelet, requested by the
# machine-config-operator's node-bootstrapper) and then, once registered, its
# own serving certificate (kubernetes.io/kubelet-serving).
# cluster-machine-approver refuses both, because it resolves a CSR by looking
# the node up in the Machine API and `platform: external` has no Machine API
# Machines -- the Cluster API objects that drove this install live in the
# installer's local, temporary control plane and never reach this cluster.
#
# ../cluster-api/machines/30_worker.yaml has said "CSR approval is manual, and
# that is the decision" since 2026-09-30. This is that decision being revisited:
# a reference implementation that cannot finish without a human at the keyboard
# is not demonstrating the flow it claims to demonstrate.
#
# IT IS NOT `certificate approve` ON EVERYTHING PENDING, and that is the point.
# Approving whatever is pending teaches partners to hand out node identities to
# anyone who can file a request. The approver this stands in for is safe
# because it checks the request against a source of truth; the fix is to give
# this hook one, not to drop the check. Here that source is the cloud: CAPOCI
# tags every instance it creates with openshift-cluster-id, the same tag
# populate_mcs_backends already trusts.
#
# THE NAME MATCH IS VERIFIED, NOT ASSUMED. A node registers under its hostname,
# and on this platform that hostname comes from
# ../manifests/99_external-01-oci-hostname-worker.yaml, which reads the OCI
# instance metadata service: it prefers `hostname`, finds none because CAPOCI
# sets no hostnameLabel, falls through to `displayName` -- which CAPOCI sets to
# the Machine name -- and lowercases it. So a CSR subject of
# `system:node:<infra-id>-worker-0` corresponds to the instance whose
# display-name is `<infra-id>-worker-0`, and the comparison below lowercases
# both sides for the same reason that script does.
#
# THIS COVERS DAY 0 ONLY. Certificates rotate and nodes are replaced long after
# the installer has exited, and nothing here will be running then. The durable
# answer is an in-cluster controller; it is an open item in the enhancement
# proposal and deliberately not solved here.

# AN ANSWERING API IS NOT A POPULATED ONE, AND TWO SECONDS WAS THE DIFFERENCE.
#
# The namespaces these Secrets go into -- oci-cloud-controller-manager and
# oci-csi -- come from this payload's own manifests/, which the bootstrap node
# applies during cluster-bootstrap. The API starts answering before that
# finishes. Measured on mrb-bar10 2026-11-10: the API answered at 03:34:59, the
# apply failed at 03:35:01 because neither namespace existed yet, and the same
# apply succeeded unchanged a few minutes later.
#
# Read from the document rather than hardcoded, so that changing a namespace in
# manifests/ cannot leave a stale constant here waiting for the wrong thing.
wait_ccm_namespaces() {
	local deadline=$1 ns missing
	local -a namespaces=()
	mapfile -t namespaces < <(grep -E '^\s+namespace:' "${CCM_STATE}" 2>/dev/null |
		awk '{print $2}' | sort -u)
	if [[ ${#namespaces[@]} -eq 0 ]]; then
		return 0
	fi

	log "waiting for namespace(s) ${namespaces[*]}"
	while [[ $(date +%s) -lt ${deadline} ]]; do
		missing=0
		for ns in "${namespaces[@]}"; do
			kube --request-timeout=15s get namespace "${ns}" >/dev/null 2>&1 || missing=1
		done
		if [[ ${missing} -eq 0 ]]; then
			log "namespace(s) ${namespaces[*]} exist"
			return 0
		fi
		sleep 15
	done
	record_failure "the namespace(s) ${namespaces[*]} never appeared; they come from this payload's own manifests/, so either the bootstrap never applied them or the cluster did not get that far"
	return 1
}

# Does the cluster answer at all yet?
#
# Separate from every other wait because it is the precondition for all of
# them, and because its failure has a different meaning: the waits below are
# about something inside a working cluster not happening, this one is about
# there being no cluster to ask.
wait_api_serving() {
	local deadline=$1
	log "waiting for the cluster API to answer"
	# `date +%s`, not SECONDS: main() builds its deadline from the epoch, and
	# this file already has two clocks -- wait_dns_published counts from shell
	# start. Mixing them silently returns immediately or never.
	while [[ $(date +%s) -lt ${deadline} ]]; do
		if kube --request-timeout=15s get namespace default >/dev/null 2>&1; then
			log "the cluster API is answering"
			return 0
		fi
		sleep 15
	done
	return 1
}

# ------------------------------------------------- console capture on failure
#
# WHEN AN INSTALL DIES WAITING FOR MACHINES, THE ONE THING WORTH HAVING IS THE
# CONSOLE, AND IT IS THE ONE THING NOBODY COLLECTS.
#
# Measured on mrb-bar6 2026-11-09: the masters looped 130 times on
# `GET https://api-int...:22623/config/master: i/o timeout` because the
# bootstrap never served the machine config server, and the only way to learn
# that was to go to the OCI console by hand, one instance at a time, after the
# install had already failed. `openshift-install gather bootstrap` could not
# help -- it needs SSH, and at that point nothing was reachable.
#
# OCI can serve this over its API, with no SSH and no public address:
# `console-history capture` snapshots the serial console of a running instance
# and `get-content` returns it. That is a provider capability, not an installer
# one -- AWS has get-console-output, some clouds have nothing -- which is
# exactly why it belongs in a hook.
#
# URLS ARE REDACTED HERE, NOT LATER. The bootstrap's console contains the
# pre-signed ignition URL, which grants read access to every day-0 secret in
# the cluster. Writing it to disk and cleaning up afterwards would already have
# published it; the redaction happens in the pipe, before anything is stored.
#
# TWO PATTERNS, BECAUSE ONE WAS NOT ENOUGH AND THE GAP WAS REAL. Matching
# `https?://...` alone leaks, because Ignition logs the request a second time
# without a scheme:
#
#   ignition[N]: fetched referenced user config from "/p/<token>/n/<ns>/b/<bucket>/o/<object>"
#
# That `/p/<token>` IS the pre-authenticated request. With the region's object
# storage host -- which is not a secret -- it reconstructs the whole URL.
# Caught on mrb-bar10 2026-11-10 by scanning the captured file for the PAR
# shape rather than for the absence of "http", which is the same lesson the
# workspace guide records about verifying a redaction by the secret's shape and
# never by the placeholder's presence.
capture_consoles() {
	local compartment_id=$1 outdir ocid name hist n=0
	outdir="${OPENSHIFT_INSTALL_STATE_DIR}/console"

	mkdir -p "${outdir}" || return 0
	chmod 700 "${outdir}" 2>/dev/null || true

	while IFS=$'\t' read -r ocid name; do
		[[ -n ${ocid} ]] || continue
		hist=$(oci compute console-history capture --instance-id "${ocid}" \
			--query 'data.id' --raw-output 2>/dev/null) || continue
		[[ -n ${hist} ]] || continue
		# The snapshot is asynchronous; a short wait is enough for the buffer
		# that already exists, and this runs on a failure path where a few
		# seconds cost nothing.
		sleep 10
		if oci compute console-history get-content \
			--instance-console-history-id "${hist}" --length 1000000 --file - 2>/dev/null |
			sed -E -e 's|https?://[^ ")]*|<URL-REDACTED>|g' \
				-e 's#/p/[A-Za-z0-9_-]{16,}(/n/[^ ")]*)?#<PAR-REDACTED>#g' \
				>"${outdir}/${name}.log" 2>/dev/null; then
			chmod 600 "${outdir}/${name}.log" 2>/dev/null || true
			n=$((n + 1))
		else
			rm -f "${outdir}/${name}.log"
		fi
	done <<<"$(oci compute instance list --compartment-id "${compartment_id}" \
		--lifecycle-state RUNNING \
		--query "data[?\"freeform-tags\".\"openshift-cluster-id\"=='${INFRA_ID}'].{i:id,n:\"display-name\"}" \
		--raw-output 2>/dev/null | jq -r '.[]? | [.i, .n] | @tsv')"

	if [[ ${n} -gt 0 ]]; then
		log "captured ${n} serial console(s) into ${outdir} (URLs redacted)"
	else
		log "no serial console could be captured for ${INFRA_ID}"
	fi
}

CSR_SIGNER_CLIENT="kubernetes.io/kube-apiserver-client-kubelet"
CSR_SIGNER_SERVING="kubernetes.io/kubelet-serving"
CSR_BOOTSTRAPPER="system:serviceaccount:openshift-machine-config-operator:node-bootstrapper"

# display-name and machine-role of every running instance CAPOCI tagged for
# this cluster, lowercased on the name so it can be compared with a node name.
bar_instances() {
	local compartment_id=$1
	oci compute instance list --compartment-id "${compartment_id}" \
		--lifecycle-state RUNNING \
		--query "data[?\"freeform-tags\".\"openshift-cluster-id\"=='${INFRA_ID}'].{name:\"display-name\",role:\"freeform-tags\".\"openshift-machine-role\"}" \
		--raw-output 2>/dev/null |
		jq -r '.[]? | [(.name // "" | ascii_downcase), (.role // "")] | @tsv'
}

# The node a CSR is asking to be, read from the request's subject rather than
# from any field on the CSR object, because the subject is what the certificate
# will actually assert.
csr_node_name() {
	kube get csr "$1" -o jsonpath='{.spec.request}' 2>/dev/null |
		base64 -d 2>/dev/null | openssl req -noout -subject 2>/dev/null |
		grep -oE 'CN *= *system:node:[^,/[:space:]]+' |
		sed -E 's/.*system:node://' | head -1
}

# name, signer and requester of every CSR nobody has decided on yet, in one
# call rather than one call per CSR.
pending_csrs() {
	kube get csr -o json 2>/dev/null |
		jq -r '.items[] | select(((.status.conditions // []) | length) == 0)
		       | [.metadata.name, .spec.signerName, .spec.username] | @tsv'
}

ready_node_count() {
	kube get nodes -o json 2>/dev/null |
		jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready") | .status=="True")] | length'
}

approve_node_csrs() {
	local compartment_id=$1 deadline=$2

	# Checked here rather than in common.sh's global tool list, so that the
	# other three phases -- which never read a certificate -- do not acquire a
	# dependency they have no use for.
	if ! command -v openssl >/dev/null 2>&1; then
		record_failure "node certificate approval: openssl is not on PATH, so this hook cannot read a CSR's subject to check it against the cluster's instances. It approves nothing it cannot verify"
		return 1
	fi

	local instances expected
	instances=$(bar_instances "${compartment_id}")
	if [[ -z ${instances} ]]; then
		record_failure "node certificate approval: found no running instances tagged openshift-cluster-id=${INFRA_ID}, so there is no trustworthy set of nodes to approve against"
		return 1
	fi
	# The bootstrap instance runs a kubelet but never registers as a node in
	# the cluster it is building, so it must not be counted as one.
	expected=$(awk -F'\t' '$2 != "bootstrap"' <<<"${instances}" | grep -c . || true)
	if ! [[ ${expected} =~ ^[0-9]+$ ]] || [[ ${expected} -eq 0 ]]; then
		record_failure "node certificate approval: every instance tagged openshift-cluster-id=${INFRA_ID} is the bootstrap, so no node is expected to join"
		return 1
	fi
	local allowed
	allowed=$(cut -f1 <<<"${instances}")
	log "expecting ${expected} node(s), counted from instances tagged openshift-cluster-id=${INFRA_ID}"

	local approved=0 ready=0 name signer user node out
	while :; do
		ready=$(ready_node_count)
		[[ ${ready} =~ ^[0-9]+$ ]] || ready=0
		if [[ ${ready} -ge ${expected} ]]; then
			log "${ready} of ${expected} expected node(s) are Ready; approved ${approved} CSR(s)"
			return 0
		fi

		while IFS=$'\t' read -r name signer user; do
			[[ -n ${name} ]] || continue
			case ${signer} in
			"${CSR_SIGNER_CLIENT}")
				if [[ ${user} != "${CSR_BOOTSTRAPPER}" ]]; then
					log "skipping ${name}: client CSR requested by ${user}, not the node bootstrapper"
					continue
				fi
				;;
			"${CSR_SIGNER_SERVING}")
				if [[ ${user} != system:node:* ]]; then
					log "skipping ${name}: serving CSR requested by ${user}, not a node"
					continue
				fi
				;;
			*)
				log "skipping ${name}: this hook does not approve ${signer}"
				continue
				;;
			esac

			node=$(csr_node_name "${name}" | tr '[:upper:]' '[:lower:]')
			if [[ -z ${node} ]]; then
				log "skipping ${name}: no system:node:<name> subject could be read from it"
				continue
			fi
			if ! grep -qxF "${node}" <<<"${allowed}"; then
				log "REFUSING ${name}: it asks to be node ${node}, which is not an instance tagged for this cluster"
				continue
			fi

			# `oc adm certificate approve`, not `oc certificate approve` --
			# the short form is kubectl's and `oc` answers `unknown command`.
			# The client's own error is kept rather than discarded, because
			# "could not approve" on its own sends the reader somewhere else
			# to find out what happened.
			if out=$(kube adm certificate approve "${name}" 2>&1); then
				approved=$((approved + 1))
				log "approved ${name} for node ${node}"
			else
				log "could not approve ${name}: $(head -1 <<<"${out}")"
			fi
		done <<<"$(pending_csrs)"

		if [[ $(date +%s) -ge ${deadline} ]]; then
			record_failure "node certificate approval: only ${ready} of ${expected} expected node(s) became Ready within ${TIMEOUT_SECONDS}s (${approved} CSR(s) approved). Nothing in an 'external' cluster approves these automatically -- cluster-machine-approver matches CSRs against Machine API Machines and none exist here. Finish by hand with 'oc get csr' and 'oc adm certificate approve <name>'"
			return 1
		fi
		sleep 15
	done
}

# Wait for the ingress Service to get a load balancer address. That load
# balancer is built by the cluster's OWN cloud controller manager, minutes
# into bootstrap, which is why the *.apps wildcard cannot be created at
# infra-ready: at that point nothing has built it and nothing will.
# Takes the hook's shared deadline rather than computing its own, so that
# --timeout-seconds means "how long this hook may take" -- a number the caller
# can reason about -- instead of a per-step budget that multiplies by the
# number of steps. Returns non-zero instead of dying; main() decides.
service_address() {
	local deadline=$1
	local ns=${INPUT_SERVICE%%/*} name=${INPUT_SERVICE##*/}
	local addr=""

	log "waiting for ${ns}/${name} to get an address"
	while [[ $(date +%s) -lt ${deadline} ]]; do
		addr=$(kube -n "${ns}" get service "${name}" \
			-o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
		if [[ -n ${addr} ]]; then
			printf '%s' "${addr}"
			return 0
		fi
		sleep 15
	done
	return 1
}

# Put the service-lb NSG's OCID on the ingress Service, before the CCM has
# built anything.
#
# THIS IS DIVERGENCE 077's DEFECT 1 IN A SECOND COMPONENT: PLACEMENT EXPRESSIBLE
# ONLY BY OCID. CAPOCI builds a correctly-ruled service-lb NSG -- 80 and 443
# from 0.0.0.0/0 -- and the cluster's own CCM never uses it, because the CCM
# attaches an NSG only when the Service names one, and names it by OCID. That
# OCID does not exist when the Service manifest is written: it is created by
# CAPOCI minutes later. So the day-0 manifest CANNOT carry it and a hook is the
# only place the two ends can be joined. The same shape as CAPOCI's machine
# subnets, in a different controller, which is why it is worth naming as a
# class rather than fixing twice: a provider that expresses placement only by
# generated identifier forces an out-of-band step on anyone composing it with
# day-0 manifests.
#
# Why it is not enough to leave this to the subnet's security list: CAPOCI puts
# the service-lb subnet on the VCN's DEFAULT security list, whose ingress is
# SSH and ICMP only. There is no per-subnet list to point
# `securityListManagementMode: Frontend` at -- which is why render_ccm_secrets
# chooses None -- so with no NSG there is nothing anywhere permitting 80/443 to
# the load balancer.
#
# Best-effort by design. A cluster whose ingress is fronted out of band, or
# whose operator has already annotated the Service by hand, is not an error.
annotate_ingress_nsg() {
	local nsg=$1 ns=${INPUT_SERVICE%%/*} name=${INPUT_SERVICE##*/}
	local deadline=$(( $(date +%s) + 300 )) current

	if [[ -z ${nsg} || ${nsg} == "null" ]]; then
		log "WARNING: no service-lb NSG recorded; the ingress load balancer will"
		log "WARNING: be created without one. Unless something else permits 80 and"
		log "WARNING: 443 to it, *.apps will resolve and then time out."
		return 0
	fi

	# Wait for the Service to exist at all. It is a day-0 extra manifest, so it
	# is applied during bootstrap -- which may or may not have reached it by the
	# time post-provision starts. Annotating BEFORE the CCM first reconciles is
	# what makes the load balancer come up with the group already attached,
	# rather than coming up wrong and being corrected.
	while [[ $(date +%s) -lt ${deadline} ]]; do
		kube -n "${ns}" get service "${name}" >/dev/null 2>&1 && break
		sleep 10
	done
	if ! kube -n "${ns}" get service "${name}" >/dev/null 2>&1; then
		log "WARNING: ${ns}/${name} does not exist; cannot annotate it with the"
		log "WARNING: service-lb NSG. Is 99_external-04-ingress-nlb.yaml in"
		log "WARNING: the payload's manifests/ directory?"
		return 0
	fi

	current=$(kube -n "${ns}" get service "${name}" \
		-o "jsonpath={.metadata.annotations.${NSG_ANNOTATION//./\\.}}" 2>/dev/null || true)
	if [[ ${current} == "${nsg}" ]]; then
		log "ingress Service already carries the service-lb NSG"
		return 0
	fi

	if kube -n "${ns}" annotate service "${name}" \
		"${NSG_ANNOTATION}=${nsg}" --overwrite >/dev/null 2>&1; then
		log "annotated ${ns}/${name} with the service-lb NSG"
	else
		log "WARNING: could not annotate ${ns}/${name} with the service-lb NSG"
	fi
}

# The OCID of the load balancer the CCM built for the ingress Service.
#
# RECORDED BECAUSE THERE IS NO OTHER HANDLE ON IT. Measured 2026-10-01 on run
# 13: the CCM names the load balancer
#
#   openshift-ingress/router-external-default/<service-uid>
#
# and tags it with NOTHING -- `freeform-tags: {}`, only Oracle's own
# `Oracle-Tags` namespace. So at destroy time, with the cluster API already
# gone, there is no tag to sweep on and the display name contains neither the
# cluster name nor the infrastructure ID. Worse, the obvious repair -- sweeping
# NLBs whose display name contains the infrastructure ID -- MATCHES
# `<infra-id>-apiserver`, which is CAPOCI's, and would delete the cluster's API
# load balancer out from under the provider that owns it.
#
# The only safe handle is the OCID, captured here while the API still answers.
ingress_nlb_id() {
	local compartment_id=$1 ns=${INPUT_SERVICE%%/*} name=${INPUT_SERVICE##*/}
	local uid id

	uid=$(kube -n "${ns}" get service "${name}" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
	[[ -n ${uid} ]] || return 1

	# Matched on the UID suffix, not on a substring of the cluster name: the
	# UID is unique to this Service and cannot collide with the apiserver NLB.
	id=$(oci nlb network-load-balancer list --compartment-id "${compartment_id}" --all \
		--query "data.items[?ends_with(\"display-name\", '${uid}')]|[0].id" \
		--raw-output 2>/dev/null || true)
	[[ -n ${id} && ${id} != "null" ]] || return 1
	printf '%s' "${id}"
}
main() {
	parse_post_provision_args "$@"

	[[ -f ${STATE} ]] || die "no ${STATE}; infra-ready did not run or did not complete"

	local nlb compartment_id zone_id public_zone apps_ip
	local lb_nsg apps_nlb apps_private apps_public
	nlb=$(jq -r '.nlbId' "${STATE}")
	compartment_id=$(jq -r '.compartmentId' "${STATE}")
	zone_id=$(jq -r '.privateZoneId' "${STATE}")
	public_zone=$(jq -r '.publicZoneId // empty' "${STATE}")
	lb_nsg=$(jq -r '.serviceLbNsgId // empty' "${STATE}")

	# One deadline for everything that waits, taken once and before the first
	# of them -- it used to be declared after the CCM apply, which is itself a
	# wait now.
	local deadline=$(($(date +%s) + TIMEOUT_SECONDS))

	# 1. Backends for 22623, first -- everything downstream needs the machine
	#    config server reachable.
	populate_mcs_backends "${nlb}" "${compartment_id}"

	# 1b. The bootstrap's 6443 backend, which CAPOCI does not add because the
	#     bootstrap is not labelled control-plane. Before the DNS wait below,
	#     because that wait exists so the API endpoint can be used and the
	#     endpoint is this load balancer.
	populate_apiserver_bootstrap_backend "${nlb}" "${compartment_id}"

	# 2. The first use of the API endpoint in this hook, and therefore the
	#    first DNS lookup of the public api record. See wait_dns_published for
	#    why that lookup must not be made speculatively.
	if [[ -n ${public_zone} ]]; then
		wait_dns_published "api.${CLUSTER_DOMAIN}"
	fi

	# 3. The CCM config. Unconditional: this is the only route there is. No
	#    hook can deliver a day-0 manifest, because the bootstrap ignition is
	#    a dependency of the Cluster asset (pkg/asset/cluster/cluster.go:74)
	#    and is therefore already sealed before the first hook runs. The CCM
	#    crash-loops from day 0 until this line, which is the visible cost of
	#    a credential that cannot exist any earlier.
	# WAIT FOR THE API FIRST. This used to apply straight away, and it could
	# never work: post-provision is invoked moments after the machines are
	# created, and the bootstrap is still booting -- on mrb-bar9 it was three
	# minutes past its pivot reboot, with node-image-pull still activating and
	# nothing listening on 6443. The apply failed, and because it was a bare
	# command under `set -e` it took the hook with it, before the failure was
	# recorded and before the consoles were captured.
	#
	# The Foo payload has always waited for its CCM namespace before touching
	# the cluster; this is the same wait, expressed against the one thing that
	# must be true for any of it: the API answers.
	if wait_api_serving "${deadline}" && wait_ccm_namespaces "${deadline}"; then
		log "applying CCM/CSI config"
		if ! kube apply -f "${CCM_STATE}" >/dev/null 2>&1; then
			record_failure "could not apply the CCM/CSI configuration from ${CCM_STATE}; the cloud controller manager will crash-loop until it is applied by hand"
		fi
	else
		record_failure "the cluster API never answered within this hook's ${TIMEOUT_SECONDS}s budget, so the CCM/CSI configuration was not applied. Nothing else in this install creates it, and the cloud controller manager cannot start without it"
	fi

	# 3b. The nodes. Before the address wait, and that order is load-bearing
	#     for a reason beyond this step's own value: a node joining is what
	#     makes the service controller recompute the load balancer's target
	#     set. Measured on the AWS arm 2026-11-09 -- the CCM created the
	#     ingress load balancer with zero targets and left it that way for
	#     fifty-two minutes, because the node set never changed again after
	#     the initial registration. Workers joining here is what produces the
	#     event that fixes it, and nothing about that mechanism is specific to
	#     AWS.
	approve_node_csrs "${compartment_id}" "${deadline}" || true

	# 4. The ingress load balancer's network security group, BEFORE waiting for
	#    an address. Annotating first means the CCM builds the load balancer
	#    with the group already attached instead of building it wrong and being
	#    corrected -- and the correction is not free: the CCM resets
	#    network-security-group-ids to whatever the annotation says on every
	#    reconcile, so a group attached out of band is wiped on the next pass.
	#    Measured 2026-10-01: attached with `oci nlb ... update-network-security-
	#    groups`, gone within the minute. Whatever the CCM reconciles must come
	#    from the Service, which is the same contract CAPOCI imposes for NSG
	#    rules (see cluster.yaml) seen from the other side.
	annotate_ingress_nsg "${lb_nsg}"

	# 5. The ingress wildcard. Skipped rather than guessed at when there is no
	#    address: a record pointing nowhere is worse than no record.
	if ! apps_ip=$(service_address "${deadline}"); then
		record_failure "${INPUT_SERVICE} had no load balancer address within this hook's ${TIMEOUT_SECONDS}s budget. Nothing on this platform creates that address except the cloud controller manager this payload delivers, so either it is not running or it cannot reconcile the Service; check 'oc -n ${INPUT_SERVICE%%/*} describe service ${INPUT_SERVICE##*/}' and the CCM's logs. The *.apps record was not created"
		if [[ ${#FAILED_STEPS[@]} -gt 0 ]]; then
			# This is the failure the console capture exists for: the wait
			# for an address the cluster's own CCM must assign, which does
			# not happen when the machines never finished coming up.
			capture_consoles "${compartment_id}"
			local joined
			joined=$(printf '(%s) ' "${FAILED_STEPS[@]}")
			die "serial consoles are in ${OPENSHIFT_INSTALL_STATE_DIR}/console; ${#FAILED_STEPS[@]} step(s) failed: ${joined%% }"
		fi
	fi
	log "ingress Service has an address; resolving the load balancer behind it"

	# The Service status is a readiness signal, not an address source. Resolve
	# the load balancer and read both of its addresses -- see nlb_public_ip for
	# why the status field alone publishes the wrong one into the public zone.
	apps_private=${apps_ip}
	apps_public=${apps_ip}
	if apps_nlb=$(ingress_nlb_id "${compartment_id}"); then
		apps_private=$(nlb_private_ip "${apps_nlb}")
		apps_public=$(nlb_public_ip "${apps_nlb}") || apps_public=${apps_private}
		log "ingress load balancer ${apps_public} (public) / ${apps_private} (private)"
	else
		# Not fatal: a single-address load balancer, or an installation whose
		# CCM names things differently, still has a usable status field. Say
		# which address is about to be published rather than implying both were
		# resolved.
		apps_nlb=""
		log "WARNING: could not resolve the ingress load balancer's OCID;"
		log "WARNING: publishing ${apps_ip} from the Service status into both"
		log "WARNING: zones, and pre-destroy will have no handle on it."
	fi

	upsert_a_record "${zone_id}" "*.apps.${CLUSTER_DOMAIN}" "${apps_private}" PRIVATE
	if [[ -n ${public_zone} ]]; then
		if [[ ${apps_public} == "${apps_private}" && -n ${apps_nlb} ]]; then
			log "WARNING: the ingress load balancer has no public address, so the"
			log "WARNING: public *.apps record points inside the VCN. Routes will"
			log "WARNING: resolve from the internet and then time out."
		fi
		upsert_a_record "${public_zone}" "*.apps.${CLUSTER_DOMAIN}" "${apps_public}" GLOBAL
	fi

	# The OCID is the point of this file. See ingress_nlb_id.
	jq -n \
		--arg ip "${apps_public}" \
		--arg private "${apps_private}" \
		--arg nlb "${apps_nlb}" \
		'{appsAddress:$ip, appsPrivateAddress:$private, appsNlbId:$nlb}' >"${APPS_STATE}"

	if [[ ${#FAILED_STEPS[@]} -gt 0 ]]; then
		# Before the error, not after: die() exits, and the console is the
		# evidence the operator will want precisely because this failed.
		capture_consoles "${compartment_id}"
		local joined
		joined=$(printf '(%s) ' "${FAILED_STEPS[@]}")
		die "serial consoles are in ${OPENSHIFT_INSTALL_STATE_DIR}/console; ${#FAILED_STEPS[@]} step(s) failed: ${joined%% }"
	fi
	log "post-provision complete"
}

main "$@"
