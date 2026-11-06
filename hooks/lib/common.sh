# shellcheck shell=bash
#
# Shared helpers for the three Bar (OCI/CAPOCI) payload hooks.
#
# SOURCED, NEVER RUN. This file has no shebang and no executable bit, and both
# are load-bearing: openshift.yaml declares exactly four executables --
# bin/controller and the three hook scripts -- and layout validation rejects
# an executable the descriptor did not declare
# (pkg/infrastructure/external/payload/descriptor.go:233). An undeclared
# helper is not "extra", it is a payload that fails to install.
#
#
# THE FILES
#
#   hooks/ignition-ready.sh   stages the oversized bootstrap ignition
#   hooks/infra-ready.sh      DNS, the 22623 listener, the CCM/CSI Secrets
#   hooks/post-provision.sh   the *.apps record and the MCS backends
#   hooks/pre-destroy.sh      removes what the other three created
#   hooks/lib/common.sh       this file
#
# The OCI pilot shipped its phases as one script dispatching on
# OPENSHIFT_INSTALL_HOOK, and that is equally valid -- the descriptor simply
# names the same path several times. This split matches the Foo reference
# payload so the two can be read side by side. What it costs is the thing the
# pilot's single file was written for: a hook and its teardown are no longer
# adjacent on the page. Keep them in step by hand; pre-destroy.sh is the one
# that gets forgotten.
#
# Foo declares three of these. ignition-ready.sh is the one CAPA does not
# need, because CAPA stages an oversized ignition inside its own controller.
#
#
# THE STATE CONTRACT
#
# A hook cannot pass anything to a later hook except through a file.
# OPENSHIFT_INSTALL_STATE_DIR is the installer-provided directory for that,
# and these are this payload's whole inter-phase vocabulary:
#
#   oci-hook-state.json    written by infra-ready, read by pre-destroy: the
#                          private DNS zone and resolver view it created
#   oci-hook-apps.json     written by post-provision, read by pre-destroy: the
#                          *.apps record and the ingress load balancer
#   oci-ccm-secrets.yaml   written by infra-ready: the rendered CCM/CSI
#                          Secrets, kept so a failed placement can be retried
#
# NOTHING WRITTEN HERE MAY BE A CREDENTIAL THAT SURVIVES THE INSTALL.
# oci-ccm-secrets.yaml is the exception that proves the rule: it does hold the
# API signing key when OCI_CCM_AUTH=api-key, and that is one of the reasons
# api-key is a pilot expedient rather than the destination. Pre-authenticated
# request URLs are credentials and are never written anywhere; only their
# OCIDs are.
#
#
# THE CONTRACT WITH THE INSTALLER
#
# The installer sets these before exec'ing a hook
# (pkg/infrastructure/external/hooks/hooks.go):
#
#   OPENSHIFT_INSTALL_HOOK            ignition-ready | infra-ready |
#                                     post-provision | pre-destroy
#   OPENSHIFT_INSTALL_INFRA_ID        the run's infrastructure ID
#   OPENSHIFT_INSTALL_CLUSTER_DOMAIN  e.g. mycluster.example.com
#   OPENSHIFT_INSTALL_BASE_DOMAIN     e.g. example.com
#   OPENSHIFT_INSTALL_PUBLISH         External | Internal
#   OPENSHIFT_INSTALL_STATE_DIR       scratch directory shared across phases
#   OPENSHIFT_INSTALL_DIR             the install directory
#   OPENSHIFT_INSTALL_MANIFEST_DIR    <install-dir>/manifests
#   OPENSHIFT_INSTALL_INFRA_JSON      PATH to the rendered infrastructure object
#   OPENSHIFT_INSTALL_CLUSTER_JSON    PATH to the rendered Cluster object
#
# Two more are set for the ignitionReady phase only, because nothing else may
# see them:
#
#   OPENSHIFT_INSTALL_BOOTSTRAP_IGNITION  PATH to the installer's finished
#                                         bootstrap ignition. READ-ONLY.
#   OPENSHIFT_INSTALL_HOOK_OUTPUT_DIR     a directory the installer creates for
#                                         the hook and removes afterwards; the
#                                         descriptor's bootstrapOutputPath is
#                                         relative to it
#
# THE LAST TWO OF THE COMMON SET ARE PATHS, NOT DOCUMENTS (hooks.go:200-216). Passing the
# variable's value to jq rather than its contents yields "Invalid numeric
# literal at EOF", which reads like malformed JSON and is actually a filename
# being parsed as one. infra_json below cats the file.
#
# Hooks are copied verbatim and never rendered, so every ${...} here is a
# shell expansion evaluated at run time. A clusterctl ${VAR} would be
# substituted away at render time and the script destroyed.

# SC2034: several constants below are read only by the phase scripts that
# source this file, which shellcheck cannot see from here.
# shellcheck disable=SC2034

set -euo pipefail

log() { printf '%s %s\n' "[$(date -u +%H:%M:%S)] external-hook:" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

for tool in oci jq; do
	command -v "${tool}" >/dev/null 2>&1 || die "${tool} is not on PATH"
done


: "${OPENSHIFT_INSTALL_HOOK:?not set -- this program is run by the installer}"
: "${OPENSHIFT_INSTALL_INFRA_ID:?}"
: "${OPENSHIFT_INSTALL_CLUSTER_DOMAIN:?}"
: "${OPENSHIFT_INSTALL_BASE_DOMAIN:?}"
: "${OPENSHIFT_INSTALL_STATE_DIR:?}"

INFRA_ID=${OPENSHIFT_INSTALL_INFRA_ID}
CLUSTER_DOMAIN=${OPENSHIFT_INSTALL_CLUSTER_DOMAIN}
BASE_DOMAIN=${OPENSHIFT_INSTALL_BASE_DOMAIN}
PUBLISH=${OPENSHIFT_INSTALL_PUBLISH:-External}

STATE="${OPENSHIFT_INSTALL_STATE_DIR}/oci-hook-state.json"
APPS_STATE="${OPENSHIFT_INSTALL_STATE_DIR}/oci-hook-apps.json"
CCM_STATE="${OPENSHIFT_INSTALL_STATE_DIR}/oci-ccm-secrets.yaml"

# The bootstrap ignition offload, recorded so it can be undone.
#
# CAPOCI base64-encodes bootstrap data into instance metadata, which OCI caps
# at 32,000 bytes -- a service limit, not a check in cloud/scope/machine.go:353
# -- and bootstrap.ign is hundreds of kilobytes. The pilot solved it OUTSIDE
# the installer: a wrapper script uploaded the real bootstrap.ign to Object
# Storage and left a ~300-byte pointer behind, between `create
# ignition-configs` and `create cluster`.
#
# THE ignitionReady HOOK IS THAT STEP, DECLARED. It runs once the installer's
# ignition assets are final and before any Cluster API object is applied, and
# it hands back a pointer config at the descriptor's bootstrapOutputPath.
# hooks/ignition-ready.sh writes the file below; pre-destroy reads it and
# treats its absence as "nothing to do", which is still the correct reading
# for a payload that does not declare the hook.
#
# It holds the PAR's OCID, never its URL: the OCID is an identifier, the URL
# is a bearer credential over every bootstrap secret.
IGNITION_STATE="${OPENSHIFT_INSTALL_DIR:-.}/.external-hook-state/bootstrap-ignition.json"

# The CCM annotation that places a load balancer in a network security group.
# The doubled `oci-` is correct and is not a typo; see nsg_by_role for what the
# other spelling costs.
NSG_ANNOTATION="oci-network-load-balancer.oraclecloud.com/oci-network-security-groups"

# The second listener. Named, not numbered, because OCI addresses listeners
# and backend sets by name and pre-destroy has to find them again.
MCS_PORT=22623
MCS_LISTENER="mcs-listener"
MCS_BACKENDSET="mcs-backendset"

# The OCIClusterIdentity Secret.
#
# NOT IN THIS IMAGE, AND IT NEVER WILL BE. It holds an OCI API signing key,
# and a payload must be generic and multi-tenant -- an image carrying one
# tenancy's key is not a provider payload. The operator supplies it and points
# this variable at it; the default is a conventional location inside the
# install directory.
#
# Two unrelated things read it: pre-destroy puts it back into the installer's
# local control plane so CAPOCI can authenticate to tear down, and -- when
# OCI_CCM_AUTH=api-key -- infra-ready reads the same six fields to build the
# in-cluster CCM config. Those are the same credential by construction, which
# is the point: this payload does not introduce a second one.
#
# The hooks read this file. They never log it, never copy it anywhere that is
# archived, and never echo a field from it.
PROVIDER_CREDENTIALS="${OCI_PROVIDER_CREDENTIALS_FILE:-${OPENSHIFT_INSTALL_DIR:-.}/oci-credentials.yaml}"

# How the in-cluster CCM and CSI driver authenticate to OCI.
#
#   instance-principal  the intended end state. The node authenticates as
#                       itself, no credential is stored in the cluster, and
#                       OCI's control plane mints short-lived tokens.
#   api-key             a user API signing key, copied into a cluster Secret.
#
# THE DEFAULT IS THE WEAKER ONE, DELIBERATELY, AND IT IS A PILOT EXPEDIENT.
# Instance principals are not something the installer or CAPOCI can turn on.
# They need four IAM objects that only a tenancy administrator can create:
#
#   1. a tag namespace with an `instance-role` key;
#   2. a DEFINED tag of that key on every instance -- a dynamic group cannot
#      match a freeform tag, so the freeform tags CAPOCI applies by default
#      are not enough (oci-openshift/terraform-stacks/shared_modules/iam/
#      dynamic_group.tf:5);
#   3. a dynamic group whose matching rule is
#        all {instance.compartment.id='<compartment>',
#             tag.<ns>.instance-role.value='control_plane'}
#   4. policies granting that group manage volume-family, instance-family,
#      security-lists, virtual-network-family, load-balancers and objects in
#      the compartment, plus `use tag-namespaces in tenancy`
#      (.../iam/policy.tf).
#
# So an operator who has not run Oracle's terraform has none of it, and on
# `platform: external` there is no Oracle terraform. That is a real finding
# about this platform rather than a local inconvenience: the CCM a partner
# ships may need IAM that no CAPI provider creates, and the installer has
# nowhere to say so. See README.md, "What the CCM needs that CAPI cannot give
# it".
#
# api-key is what makes a pilot run possible today. Its cost is stated here
# rather than buried: the Secret holds a USER's signing key, so the CCM runs
# with that user's permissions across the whole tenancy, not with a dynamic
# group's permissions scoped to one compartment. That is strictly worse than
# what we are replacing it with, and it is acceptable only because this
# compartment is disposable. Do not ship it.
: "${OCI_CCM_AUTH:=api-key}"
case ${OCI_CCM_AUTH} in
api-key | instance-principal) ;;
*) die "OCI_CCM_AUTH must be api-key or instance-principal, not ${OCI_CCM_AUTH}" ;;
esac

# A hook runs as whatever phase the descriptor wired it to. Checking means a
# descriptor that points preDestroy at infra-ready.sh fails loudly instead of
# publishing DNS records during a teardown.
expect_hook() {
	local want=$1
	[ "${OPENSHIFT_INSTALL_HOOK}" = "${want}" ] ||
		die "wired as ${OPENSHIFT_INSTALL_HOOK} but this program is the ${want} hook"
}

# Only post-provision takes arguments. The other two phases error on one
# rather than ignoring it, so a wiring mistake is visible.
reject_args() {
	[ $# -eq 0 ] || die "takes no arguments, got: $*"
}

# ---------------------------------------------------------------------------
# Reading the infrastructure object
# ---------------------------------------------------------------------------

infra_json() {
	[[ -n ${OPENSHIFT_INSTALL_INFRA_JSON:-} ]] ||
		die "OPENSHIFT_INSTALL_INFRA_JSON is unset -- the installer sets it only when exactly one infrastructure object exists"
	# A PATH, not the JSON. The installer writes the object to a file in a
	# per-hook temporary directory and exports that file's path
	# (pkg/infrastructure/external/hooks/hooks.go:200-216, `env = append(env,
	# obj.envVar+"="+path)`). This function used to `printf '%s'` the variable
	# itself, which fed jq a 57-character pathname and produced
	# `jq: parse error: Invalid numeric literal at EOF at line 1, column 58`
	# -- column 58 being one past the end of the path. Every lookup below then
	# failed, and the first one to report was the compartment OCID, which made
	# it read like a missing field rather than a misread variable. Found on the
	# first real run of this hook, 2026-10-01. The Foo payload's hooks always
	# had this right because they were written against runs.
	[[ -f ${OPENSHIFT_INSTALL_INFRA_JSON} ]] ||
		die "OPENSHIFT_INSTALL_INFRA_JSON=${OPENSHIFT_INSTALL_INFRA_JSON} is not a file -- the installer exports the path of a file holding the object, not the object"
	cat "${OPENSHIFT_INSTALL_INFRA_JSON}"
}

# jq against the OCICluster, failing loudly on an empty result rather than
# letting an empty string flow into an OCI CLI call.
infra_get() {
	local path=$1 desc=$2 value
	value=$(infra_json | jq -r "${path} // empty")
	[[ -n ${value} ]] || die "${desc} not found at ${path} in the OCICluster"
	printf '%s' "${value}"
}

vcn_id()        { infra_get '.spec.networkSpec.vcn.id' 'VCN OCID'; }
compartment()   { infra_get '.spec.compartmentId' 'compartment OCID'; }
nlb_id()        { infra_get '.spec.networkSpec.apiServerLoadBalancer.loadBalancerId' 'API server NLB OCID'; }
api_endpoint()  { infra_get '.spec.controlPlaneEndpoint.host' 'control plane endpoint host'; }

subnet_by_role() {
	infra_get ".spec.networkSpec.vcn.subnets[] | select(.role==\"$1\") | .id" "$1 subnet OCID"
}

# OPTIONAL, AND NORMALLY ABSENT. CAPOCI secures subnets with NETWORK SECURITY
# GROUPS, not with per-subnet security lists: a subnet it created carries only
# cidr, id, name, role and type, with no `securityList` key at all. Measured on
# the recorded OCICluster of a real run, 2026-10-01 -- all four subnets, same
# shape.
#
# This used to call infra_get, which dies on an empty result, so infra-ready
# aborted at the very first thing it needed after the network existed. Oracle's
# own CCM config has a security list because their *terraform* creates subnets
# with one; CAPOCI's does not, and copying the config shape without copying the
# network shape is what produced the mismatch.
#
# Left as an accessor rather than deleted because a partner who supplies their
# own pre-existing subnets CAN set it, and then the CCM should be told about
# it. Returns empty instead of dying; render_ccm_secrets decides what that
# means.
seclist_by_role() {
	infra_json | jq -r \
		".spec.networkSpec.vcn.subnets[] | select(.role==\"$1\") | .securityList.id // empty"
}

# What CAPOCI actually creates. Recorded in state so post-provision can annotate
# the ingress Service with it -- see annotate_ingress_nsg, which is the only
# consumer.
#
# THE ANNOTATION KEY DEPENDS ON THE LOAD BALANCER TYPE AND THE TWO DIFFER BY ONE
# WORD. For an NLB -- which is what this example uses -- it is
#
#   oci-network-load-balancer.oraclecloud.com/oci-network-security-groups
#
# note the doubled `oci-`. The LBaaS spelling is
# `oci.oraclecloud.com/oci-network-security-groups`. An earlier revision of this
# comment named the LBaaS key, and following it cost four attempts on a live
# cluster: a wrong key is not rejected, not logged and not defaulted. It is
# ignored, the load balancer comes up with no NSG, every health check passes,
# and the only symptom is that traffic from outside the VCN is dropped.
#
# The authoritative list is in the CCM binary and can be read from a running
# cluster, which is how this one was finally settled:
#
#   oc exec -n oci-cloud-controller-manager <pod> -- grep -aoE \
#     'oci[a-z0-9.-]*\.oraclecloud\.com/[a-zA-Z0-9_-]+' \
#     /usr/local/bin/oci-cloud-controller-manager | sort -u
nsg_by_role() {
	infra_json | jq -r \
		".spec.networkSpec.vcn.networkSecurityGroup.list[]? | select(.role==\"$1\") | .id // empty"
}

# ---------------------------------------------------------------------------
# DNS
#
# OCI DNS rather than Route 53, and the shape differs in one way worth
# knowing: OCI has no alias-record concept, so api/api-int are A records
# pointing at the NLB's IP address rather than aliases pointing at the load
# balancer itself.
#
# Which means we have to choose an address, and a public NLB has two. The
# public zone's `api` gets .spec.controlPlaneEndpoint.host, which CAPOCI set to
# the public one. The private zone's `api` and `api-int` get the private one,
# looked up by nlb_private_ip -- read that function before changing either.
# ---------------------------------------------------------------------------

create_private_zone() {
	local compartment_id=$1 vcn=$2 existing

	existing=$(oci dns zone list --compartment-id "${compartment_id}" \
		--name "${CLUSTER_DOMAIN}" --scope PRIVATE \
		--query 'data[0].id' --raw-output 2>/dev/null || true)
	if [[ -n ${existing} && ${existing} != "null" ]]; then
		log "private zone ${CLUSTER_DOMAIN} already exists"
		printf '%s' "${existing}"
		return 0
	fi

	# A private zone needs a view, and each VCN has a default one. Looking it
	# up by VCN rather than by name because the default view's name is not
	# documented as stable.
	local view_id
	view_id=$(oci dns resolver list --compartment-id "${compartment_id}" \
		--scope PRIVATE \
		--query "data[?\"attached-vcn-id\"=='${vcn}'] | [0].\"default-view-id\"" \
		--raw-output)
	[[ -n ${view_id} && ${view_id} != "null" ]] ||
		die "no default private DNS view for VCN ${vcn}"

	log "creating private zone ${CLUSTER_DOMAIN}"
	oci dns zone create --compartment-id "${compartment_id}" \
		--name "${CLUSTER_DOMAIN}" --zone-type PRIMARY --scope PRIVATE \
		--view-id "${view_id}" \
		--query 'data.id' --raw-output
}

# Make the private zone's view actually answer queries from inside the VCN.
#
# CREATING A PRIVATE ZONE IS NOT ENOUGH, and this is the single most expensive
# thing learned in this example so far. A zone created in a VCN resolver's
# DEFAULT view looks completely correct from the outside: the zone exists, the
# records are right, `oci dns record rrset get` returns them. And no instance
# in the VCN can resolve any of it.
#
# MEASURED. On the run that found this, the resolver attached to the cluster's
# VCN reported:
#
#     attached-views: []
#
# while the private zone holding api-int sat in that resolver's default view.
# Every master booted, ran Ignition, and failed identically:
#
#     Ignition: user-provided config was applied
#     Ignition: fetching configuration for <api-int URL>
#       unable to fetch resource in time
#
# There is no fallback to hide it, either: the public zone publishes `api` but
# deliberately NOT `api-int`, so a master that cannot see the private zone has
# no second place to look. The install then fails somewhere else entirely --
# "failed to provision control-plane machines", or a post-provision hook timing
# out against a cluster with no nodes -- and none of those errors mentions DNS.
#
# Attaching the view explicitly fixed it: a master resolved api-int, fetched
# its config and registered within about ninety seconds.
#
# HONEST LIMIT ON THAT CLAIM. The fix was applied to a live cluster and the
# recovery observed, but re-reading the resolver afterwards to confirm the
# final attached-views list was not possible in that session. The causal link
# rests on the before-state, the failure mode and the timing of the recovery,
# which agree -- not on a direct read of the after-state. Treat the mechanism
# as established and the exact OCI semantics of "default view" versus "attached
# view" as worth confirming once.
#
# Idempotent: the current list is read first and the view appended only if it
# is missing, so a re-run neither duplicates nor detaches anything.
ensure_view_attached() {
	local compartment_id=$1 vcn=$2 resolver_id view_id attached payload

	resolver_id=$(oci dns resolver list --compartment-id "${compartment_id}" \
		--scope PRIVATE \
		--query "data[?\"attached-vcn-id\"=='${vcn}'] | [0].id" \
		--raw-output)
	view_id=$(oci dns resolver list --compartment-id "${compartment_id}" \
		--scope PRIVATE \
		--query "data[?\"attached-vcn-id\"=='${vcn}'] | [0].\"default-view-id\"" \
		--raw-output)
	[[ -n ${resolver_id} && ${resolver_id} != "null" ]] ||
		die "no private DNS resolver for VCN ${vcn}; nothing in the VCN could resolve api-int"
	[[ -n ${view_id} && ${view_id} != "null" ]] ||
		die "no default private DNS view for VCN ${vcn}"

	attached=$(oci dns resolver get --resolver-id "${resolver_id}" --scope PRIVATE \
		--query 'data."attached-views"' --output json 2>/dev/null || echo '[]')
	[[ -n ${attached} && ${attached} != "null" ]] || attached='[]'

	if jq -e --arg v "${view_id}" 'any(.[]?; .["view-id"] == $v or .viewId == $v)' \
		<<<"${attached}" >/dev/null 2>&1; then
		log "private DNS view already attached to the VCN resolver"
		return 0
	fi

	# Append rather than replace. The resolver may legitimately carry views for
	# other zones; sending only ours would silently detach them.
	payload=$(jq -c --arg v "${view_id}" \
		'[.[]? | {viewId: (.["view-id"] // .viewId)}] + [{viewId: $v}]' <<<"${attached}")

	log "attaching private DNS view to the VCN resolver"
	oci dns resolver update --resolver-id "${resolver_id}" --scope PRIVATE \
		--attached-views "${payload}" --force >/dev/null ||
		die "could not attach the private DNS view; masters will not resolve api-int"
}

upsert_a_record() {
	local zone_id=$1 fqdn=$2 ip=$3 scope=$4
	log "upserting A ${fqdn} -> ${ip}"
	oci dns record rrset update --zone-name-or-id "${zone_id}" \
		--domain "${fqdn}" --rtype A --scope "${scope}" \
		--items "$(jq -n --arg d "${fqdn}" --arg r "${ip}" \
			'[{domain:$d, rtype:"A", ttl:60, rdata:$r}]')" \
		--force >/dev/null
}

# Wait until a record is visible on the zone's own nameservers, WITHOUT ever
# asking this host's resolver.
#
# MEASURED on a real OCI run, 2026-10-01. The public `api` record was upserted
# at 23:14:55. `oc` resolved it for the first time at 23:17:16 -- 2m21s later
# -- and got NXDOMAIN, and the install died there. OCI publishes a zone change
# to its public nameservers asynchronously; 2m21s was not enough.
#
# The failed lookup is not the damage. The recursive resolver CACHES that
# NXDOMAIN for the zone's SOA minimum, which is 1800s here, so every later
# attempt in the same run fails too -- long after the record is genuinely
# live. Confirmed both ways: a direct query to the authoritative nameserver
# returned the address while the system resolver still said NXDOMAIN, and
# `resolvectl flush-caches` made it resolve immediately.
#
# **A fresh cluster name per run does not prevent this**, which is what the
# earlier mitigation assumed. The poisoning query happens inside the same run,
# against a name that has never existed before. Negative caching is not a
# name-reuse problem; it is an ordering problem.
#
# Hence: poll the AUTHORITATIVE servers. A query addressed to them directly
# cannot put anything in the local cache, so the first recursive lookup -- the
# one `oc` makes -- happens only once there is a positive answer to find.
authoritative_ns() {
	# Learned from the delegation of the base domain, which has existed since
	# long before this install, so it cannot itself be the unpublished thing.
	dig +short NS "${BASE_DOMAIN}" 2>/dev/null | sed 's/\.$//' | grep . || true
}

wait_dns_published() {
	local fqdn=$1 deadline ns answer found
	local -a servers=()

	if ! command -v dig >/dev/null 2>&1; then
		log "dig is not on PATH; cannot wait for ${fqdn} to publish"
		return 0
	fi

	mapfile -t servers < <(authoritative_ns)
	if [[ ${#servers[@]} -eq 0 ]]; then
		log "no nameservers found for ${BASE_DOMAIN}; not waiting on ${fqdn}"
		return 0
	fi

	log "waiting for ${fqdn} on ${#servers[@]} authoritative nameserver(s)"
	deadline=$((SECONDS + 600))
	while ((SECONDS < deadline)); do
		# Every one of them, not the first to answer: a partial publish still
		# lets the recursive resolver pick a server that says NXDOMAIN.
		found=yes
		for ns in "${servers[@]}"; do
			answer=$(dig +short +time=3 +tries=1 "@${ns}" "${fqdn}" A 2>/dev/null | grep . || true)
			[[ -n ${answer} ]] || {
				found=no
				break
			}
		done
		if [[ ${found} == yes ]]; then
			log "${fqdn} is published on every authoritative nameserver"
			# Only now is it safe to let the recursive resolver see this name.
			[[ -n $(getent hosts "${fqdn}" 2>/dev/null || true) ]] && return 0
			log "${fqdn} answers authoritatively but not through this host's resolver."
			log "  A negative answer for it is cached locally; it will expire on"
			log "  its own in up to the zone's SOA minimum. To clear it now:"
			log "      resolvectl flush-caches"
			die "local resolver has a stale NXDOMAIN for ${fqdn}"
		fi
		sleep 10
	done
	die "${fqdn} did not publish on its authoritative nameservers within 10m"
}

delete_rrset() {
	local zone_id=$1 fqdn=$2 rtype=$3 scope=$4
	if oci dns record rrset delete --zone-name-or-id "${zone_id}" \
		--domain "${fqdn}" --rtype "${rtype}" --scope "${scope}" \
		--force >/dev/null 2>&1; then
		log "deleted ${rtype} ${fqdn}"
	else
		log "${rtype} ${fqdn} already gone"
	fi
}

# ---------------------------------------------------------------------------
# The API server network load balancer
#
# All three phases touch it: infra-ready adds the 22623 listener,
# post-provision fills its backend set, pre-destroy takes the listener away.
# ---------------------------------------------------------------------------

# Wait until the load balancer will accept another change.
#
# `--wait-for-state SUCCEEDED` waits on the WORK REQUEST, and a work request
# can succeed while the load balancer itself is still Updating. The next
# mutation then fails:
#
#   "code": "Conflict", "status": 409, "message": "NLB in Updating state",
#   "operation_name": "create_listener"
#
# -- measured 2026-10-01, creating the 22623 listener one second after the
# backend set's work request reported SUCCEEDED. The backend set really was
# created; only the follow-up was rejected.
#
# So every mutation is gated on the LOAD BALANCER's own lifecycle state rather
# than on the preceding work request. This is not a sleep: it polls.
#
# Called only from nlb_mutate, which is where the gate is paired with a retry
# of the call itself -- read that function for why the gate alone is not
# enough. Returns a status rather than dying, because what a timeout means
# differs between the create and destroy paths and only the caller knows
# which it is on.
nlb_wait_active() {
	local nlb=$1 state="" i
	for ((i = 0; i < 60; i++)); do
		state=$(oci nlb network-load-balancer get --network-load-balancer-id "${nlb}" \
			--query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)
		[[ ${state} == "ACTIVE" ]] && return 0
		sleep 5
	done
	log "network load balancer ${nlb} never returned to ACTIVE (last state: ${state:-unknown})"
	return 1
}

# The load balancer's PRIVATE address, which is what api-int must resolve to.
#
# WHY THIS IS NOT .spec.controlPlaneEndpoint.host. CAPOCI fills that field from
# getNetworkLoadbalancerIp (cloud/scope/network_load_balancer_reconciler.go:279-297),
# which returns IpAddresses[0] when the load balancer is private and otherwise
# the first address with IsPublic true. This cluster's NLB is
# `networkVisibility: Public`, so controlPlaneEndpoint.host is the PUBLIC IP --
# correct for the public `api` record and wrong for everything else.
#
# An OCI public network load balancer has both addresses. Pointing api-int at
# the public one still WORKS, which is what makes it dangerous: the masters sit
# in a private subnet, so every api-int request would leave through the NAT
# gateway and come back in through the internet gateway. It would have installed
# a cluster whose control-plane-to-control-plane traffic hairpins through the
# public internet, and nothing in the install would have complained.
#
# It also forecloses the security property the NSG block in cluster.yaml depends
# on: 22623 is permitted from the VCN CIDR only, on the grounds that every
# legitimate machine-config-server client is inside the VCN. That is true only
# while api-int is the private address. These two decisions have to move
# together -- if this function ever returns a public address, that rule must be
# widened, and a cluster's day-0 Ignition secrets become internet-reachable.
#
# Dies rather than falling back to the public address. A silent fallback here
# would reintroduce exactly the configuration this exists to prevent.
nlb_private_ip() {
	local nlb=$1 ip
	# The single quotes and the backticks are both deliberate: this is a
	# JMESPath expression, where `false` is a literal and "..." quotes an
	# identifier containing a hyphen. Nothing here is shell syntax, so nothing
	# should expand.
	# shellcheck disable=SC2016
	ip=$(oci nlb network-load-balancer get --network-load-balancer-id "${nlb}" \
		--query 'data."ip-addresses"[?"is-public"==`false`]|[0]."ip-address"' \
		--raw-output 2>/dev/null || true)
	[[ -n ${ip} && ${ip} != "null" ]] ||
		die "no private IP on network load balancer ${nlb}; api-int cannot be published"
	printf '%s' "${ip}"
}

# The public address of an NLB, for the one record that needs it.
#
# WHY THIS EXISTS RATHER THAN `.status.loadBalancer.ingress[0].ip`. An OCI NLB
# in a public subnet has TWO addresses, and the Service status reports only one
# of them. Measured 2026-10-01 on run 13's ingress load balancer:
#
#   ip-addresses: [ {is-public: true,  129.213.x.x},
#                   {is-public: false, 10.0.32.20 } ]
#   Service .status.loadBalancer.ingress[0].ip -> 10.0.32.20
#
# The CCM reported the PRIVATE one. Publishing that into the public zone gives
# a `*.apps` record that resolves, from the internet, to an address inside the
# VCN -- so every Route times out while DNS, the load balancer, the Service and
# the routers are all individually correct. This is the same trap as
# getNetworkLoadbalancerIp returning the public address where api-int needs the
# private one (see nlb_private_ip above), with the polarity reversed: in both
# cases the convenient field is the wrong one, in opposite directions.
#
# So neither zone is served from the Service status. The status is used only as
# a readiness signal; the addresses come from the load balancer itself.
nlb_public_ip() {
	local nlb=$1 ip
	# shellcheck disable=SC2016
	ip=$(oci nlb network-load-balancer get --network-load-balancer-id "${nlb}" \
		--query 'data."ip-addresses"[?"is-public"==`true`]|[0]."ip-address"' \
		--raw-output 2>/dev/null || true)
	[[ -n ${ip} && ${ip} != "null" ]] || return 1
	printf '%s' "${ip}"
}

# Run one NLB mutation, retrying while the load balancer is busy.
#
# THE STATE GATE ABOVE IS NECESSARY AND NOT SUFFICIENT, and this is the part
# that took two runs to see. Gating alone assumes we are the only writer. We
# are not: at infra-ready CAPOCI has just reported the network ready and is
# still reconciling the same load balancer -- it attaches its own 6443 backend
# set and listener in the same window. So the sequence is
#
#   nlb_wait_active -> ACTIVE          our check, honestly passed
#   CAPOCI issues its own update       the NLB goes Updating
#   our create lands                   409
#
# and the error says so almost in words: "Invalid State Transition of NLB
# lifeCycle state from Updating to Updating" (run 7, 2026-10-01, one second
# after the gate passed). A longer wait cannot fix a race whose other party is
# a controller; only retrying the losing call can.
#
# Retries ONLY on conflict. Any other failure is returned immediately with its
# output, because "already exists" and "no such backend set" are answers, not
# congestion, and retrying them for five minutes would hide them.
#
# Returns non-zero rather than dying, so the destroy path can carry on -- see
# nlb_wait_active for why that distinction matters there.
nlb_mutate() {
	local nlb=$1 what=$2
	shift 2
	local i out=""
	for ((i = 1; i <= 30; i++)); do
		nlb_wait_active "${nlb}" || true
		if out=$("$@" 2>&1); then
			return 0
		fi
		if ! grep -qE 'Invalid State Transition|in Updating state|in Creating state' <<<"${out}"; then
			printf '%s\n' "${out}" >&2
			return 1
		fi
		log "${what}: the load balancer is busy (attempt ${i}/30); retrying"
		sleep 10
	done
	printf '%s\n' "${out}" >&2
	log "${what}: the load balancer stayed busy across 30 attempts"
	return 1
}

kube() {
	oc --kubeconfig "${OPENSHIFT_INSTALL_KUBECONFIG:?}" "$@"
}
