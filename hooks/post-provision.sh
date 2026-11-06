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

INPUT_SERVICE=""
TIMEOUT_SECONDS=1800

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
	[[ -n ${INPUT_SERVICE} ]] || die "--input-service is required for post-provision"
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

# Wait for the ingress Service to get a load balancer address. That load
# balancer is built by the cluster's OWN cloud controller manager, minutes
# into bootstrap, which is why the *.apps wildcard cannot be created at
# infra-ready: at that point nothing has built it and nothing will.
service_address() {
	local ns=${INPUT_SERVICE%%/*} name=${INPUT_SERVICE##*/}
	local deadline=$(( $(date +%s) + TIMEOUT_SECONDS )) addr=""

	log "waiting up to ${TIMEOUT_SECONDS}s for ${ns}/${name} to get an address"
	while [[ $(date +%s) -lt ${deadline} ]]; do
		addr=$(kube -n "${ns}" get service "${name}" \
			-o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
		[[ -n ${addr} ]] && { printf '%s' "${addr}"; return 0; }
		sleep 15
	done
	die "${ns}/${name} had no load balancer address after ${TIMEOUT_SECONDS}s"
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

	local nlb compartment_id zone_id public_zone ccm_mode apps_ip
	local lb_nsg apps_nlb apps_private apps_public
	nlb=$(jq -r '.nlbId' "${STATE}")
	compartment_id=$(jq -r '.compartmentId' "${STATE}")
	zone_id=$(jq -r '.privateZoneId' "${STATE}")
	public_zone=$(jq -r '.publicZoneId // empty' "${STATE}")
	ccm_mode=$(jq -r '.ccmMode' "${STATE}")
	lb_nsg=$(jq -r '.serviceLbNsgId // empty' "${STATE}")

	# 1. Backends for 22623, first -- everything downstream needs the machine
	#    config server reachable.
	populate_mcs_backends "${nlb}" "${compartment_id}"

	# 2. The first use of the API endpoint in this hook, and therefore the
	#    first DNS lookup of the public api record. See wait_dns_published for
	#    why that lookup must not be made speculatively.
	if [[ -n ${public_zone} ]]; then
		wait_dns_published "api.${CLUSTER_DOMAIN}"
	fi

	# 3. The CCM config, if it could not be day-0 content.
	if [[ ${ccm_mode} != "day0" ]]; then
		log "applying CCM/CSI config"
		kube apply -f "${CCM_STATE}" >/dev/null
	fi

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

	# 5. The ingress wildcard.
	apps_ip=$(service_address)
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
	log "post-provision complete"
}

main "$@"
