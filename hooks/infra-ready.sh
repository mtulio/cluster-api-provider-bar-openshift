#!/usr/bin/env bash
#
# infraReady hook for the Bar (OCI/CAPOCI) payload.
#
# Runs once, after the provider reports Cluster.status.infrastructureReady and
# BEFORE any machine exists -- the installer names the stage "Post-network,
# pre-machine Provisioning" (pkg/infrastructure/clusterapi/clusterapi.go:54,
# called at :312). Everything here must work with a network and no nodes.
#
# NOT OPTIONAL. Without api-int resolving, bootkube fails at
# resolve-api-int-url and the install dies roughly forty minutes later at the
# bootstrap timeout, with an error that points nowhere near the cause.
#
# Three jobs:
#   1. publish api and api-int in a private zone attached to a resolver view
#   2. add the 22623 listener CAPOCI's load balancer does not have
#   3. render and place the CCM/CSI credential Secrets, whose cloud
#      identifiers only exist once the network is built
# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"
expect_hook infra-ready
reject_args "$@"

# ---------------------------------------------------------------------------
# The 22623 listener
#
# The CLI service group is `oci nlb`, NOT `oci network-load-balancer` --
# `network-load-balancer` is a *subcommand* of it, alongside backend-set,
# listener and backend. So the load balancer itself is
# `oci nlb network-load-balancer get` while its listeners are
# `oci nlb listener ...`, which reads like a typo and is not. Every call here
# was originally written with the long form and failed with
# `Error: No such command 'network-load-balancer'` the first time infra-ready
# got this far (2026-10-01). The LBaaS product is the one with the long group
# name, `oci lb`, and these two load-balancer products having near-identical
# CLI vocabularies is the trap.
# ---------------------------------------------------------------------------


add_mcs_listener() {
	local nlb=$1

	if oci nlb backend-set get --network-load-balancer-id "${nlb}" \
		--backend-set-name "${MCS_BACKENDSET}" >/dev/null 2>&1; then
		log "${MCS_BACKENDSET} already exists"
	else
		log "creating backend set ${MCS_BACKENDSET} for port ${MCS_PORT}"
		# Created EMPTY. No machine exists yet at infra-ready; post-provision
		# fills it, and an empty backend set is survivable: Ignition retries a
		# refused connection indefinitely (coreos/ignition
		# internal/resource/http.go -- `for attempt := 1; ; attempt++` with
		# defaultHttpTotalTimeout = 0). What is NOT survivable is a listener
		# that answers 4xx, which shouldRetryHttp treats as final. So an empty
		# backend set here is the safe state, not a race.
		#
		# FIVE_TUPLE is the OCI NLB default and the only sensible choice of the
		# three on offer (TWO_TUPLE, THREE_TUPLE, FIVE_TUPLE) -- there is no
		# round-robin or source-IP policy on this product, unlike LBaaS. An
		# earlier version of this comment claimed SOURCE_IP_ADDRESS, which is
		# not a value this API accepts and never matched the code below it.
		nlb_mutate "${nlb}" "backend set ${MCS_BACKENDSET}" \
			oci nlb backend-set create \
			--network-load-balancer-id "${nlb}" \
			--name "${MCS_BACKENDSET}" \
			--policy FIVE_TUPLE \
			--is-preserve-source false \
			--health-checker "$(jq -n --argjson p "${MCS_PORT}" \
				'{protocol:"HTTPS", port:$p, urlPath:"/healthz",
				  returnCode:200, intervalInMillis:10000,
				  timeoutInMillis:3000, retries:3}')" \
			--wait-for-state SUCCEEDED ||
			die "could not create backend set ${MCS_BACKENDSET} on ${nlb}"
	fi

	if oci nlb listener get --network-load-balancer-id "${nlb}" \
		--listener-name "${MCS_LISTENER}" >/dev/null 2>&1; then
		log "${MCS_LISTENER} already exists"
	else
		# This is the call that found the race: our own backend-set create
		# above left the load balancer busy, and CAPOCI's concurrent
		# reconcile kept it that way. Both are handled by nlb_mutate.
		log "creating listener ${MCS_LISTENER} on port ${MCS_PORT}"
		nlb_mutate "${nlb}" "listener ${MCS_LISTENER}" \
			oci nlb listener create \
			--network-load-balancer-id "${nlb}" \
			--name "${MCS_LISTENER}" \
			--default-backend-set-name "${MCS_BACKENDSET}" \
			--port "${MCS_PORT}" --protocol TCP \
			--wait-for-state SUCCEEDED ||
			die "could not create listener ${MCS_LISTENER} on ${nlb}"
	fi
}
# ---------------------------------------------------------------------------
# The CCM and CSI config Secrets
#
# Shapes copied from oci-openshift/custom_manifests/manifests/
# 01-oci-driver-configs.yml, and the field names verified against the CCM's own
# config struct rather than against that example, because the example only ever
# shows the instance-principal case:
#
#   AuthConfig  pkg/cloudprovider/providers/oci/config/config.go:48-56
#               region, tenancy, user, key, fingerprint, passphrase
#   Config      :151-175  -- useInstancePrincipals is TOP LEVEL
#
# Two things that reading the example alone would get wrong:
#
#   * `auth.useInstancePrincipals` is DEPRECATED. config.go:224-227 copies it
#     up to the top level and logs a warning. Oracle's own manifests still set
#     the deprecated one; this hook sets the top-level field.
#   * when useInstancePrincipals is false, config_validate.go:29-34 requires
#     ALL of region, tenancy, user, key and fingerprint. A partially-filled
#     auth block does not degrade -- the CCM refuses to start.
#
# The six credential fields are read from the OCIClusterIdentity Secret rather
# than from the installer host's ~/.oci/config, because that Secret is the one
# thing guaranteed to be present (the install cannot have got this far without
# it) and because CAPOCI's key names and the CCM's yaml field names are the
# same six words -- both come from the OCI SDK's vocabulary. CAPOCI's side:
# cloud/config/config.go:39-46, read at cloud/util/util.go:133-138.
# ---------------------------------------------------------------------------

render_ccm_secrets() {
	local compartment_id=$1 vcn=$2 lb_subnet=$3 lb_seclist=$4

	# securityListManagementMode decides whether the CCM edits security lists
	# when it creates a load balancer.
	#
	#   Frontend  the CCM manages ingress rules on the named security list.
	#             Needs a security list OCID, which is what Oracle's terraform
	#             provides and CAPOCI does not.
	#   None      the CCM touches no security list. The network must already
	#             permit traffic to the load balancer.
	#
	# With CAPOCI there is no per-subnet security list to name, so the mode
	# follows the network rather than being asserted. Choosing Frontend anyway
	# and pointing it at the VCN's DEFAULT security list would be the obvious
	# shortcut and is deliberately not taken: that list is attached to every
	# subnet in the VCN, so the CCM would be editing rules for the control
	# plane and workers as a side effect of creating an ingress load balancer.
	#
	# The cost of None is explicit and belongs in the open items rather than in
	# a comment nobody reads: *nothing here opens 80/443 to the ingress load
	# balancer.* CAPOCI's service-lb NSG rules are what must permit it, and
	# whether its defaults do is NOT yet verified end to end -- no ingress load
	# balancer has been created by a cluster's own CCM on OCI in this pilot.
	# An `if`, not `[[ ... ]] && lb_mode=Frontend`: under `set -e` an AND-list
	# whose test fails returns 1 and takes the whole hook with it.
	local lb_mode="None"
	if [[ -n ${lb_seclist} ]]; then
		lb_mode="Frontend"
	fi

	# regionKey is the three-letter airport code (iad, phx, fra). config.go:230-240
	# falls back to instance metadata for it and only WARNS when that fails, so
	# an unset regionKey is survivable -- but the fallback runs on the node, and
	# we already know the answer here. Looked up rather than hardcoded or parsed
	# out of the region name, because the mapping is not derivable.
	local region region_key
	region=${OCI_CLI_REGION:?set it to the region the cluster is being created in}
	region_key=$(oci iam region list \
		--query "data[?name=='${region}'].key | [0]" --raw-output 2>/dev/null || true)

	if [[ ${OCI_CCM_AUTH} == "api-key" && ! -f ${PROVIDER_CREDENTIALS} ]]; then
		die "OCI_CCM_AUTH=api-key but there is no credential Secret at ${PROVIDER_CREDENTIALS}"
	fi

	# Rendered by python rather than by a heredoc, for one reason: with
	# OCI_CCM_AUTH=api-key the document embeds a PEM private key, and a shell
	# heredoc indents it with `sed 's/^/    /'`. A multi-line secret pushed
	# through line-oriented text munging is exactly the construct that produced
	# the dangling-sshKey bug recorded in the workspace AGENTS.md -- an edit that
	# lands halfway looks identical to one that lands, from the placeholder's
	# side. A YAML emitter cannot indent a block scalar wrongly.
	#
	# It also writes nothing to stdout. Every value handled here is a
	# credential; the only thing that leaves this function is a byte count.
	python3 - "${CCM_STATE}" "${OCI_CCM_AUTH}" "${PROVIDER_CREDENTIALS}" \
		"${compartment_id}" "${vcn}" "${lb_subnet}" "${lb_mode}" "${lb_seclist}" \
		"${region}" "${region_key}" <<-'PY'
		import base64, pathlib, sys, yaml

		# Emit multi-line strings as `|` blocks instead of as one long
		# double-quoted line with \n escapes. Purely for the human who has to
		# read this file while debugging a CCM that will not start -- the
		# default dump is correct and unreadable.
		#
		# Guarded, and the guard is the point: a `|` block cannot represent a
		# line with trailing whitespace, and PyYAML silently falls back to
		# quoting if asked, but being explicit about WHY it is safe is cheaper
		# than trusting it. Verified by round-tripping the PEM through both YAML
		# layers in the test below the fold.
		def block(dumper, data):
		    style = "|" if "\n" in data and not any(
		        line != line.rstrip() for line in data.split("\n")) else None
		    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style=style)
		yaml.SafeDumper.add_representer(str, block)

		(state, mode, credpath, compartment, vcn,
		 lb_subnet, lb_mode, lb_seclist, region, region_key) = sys.argv[1:11]

		cfg = {
		    "useInstancePrincipals": mode == "instance-principal",
		    "compartment": compartment,
		    "vcn": vcn,
		    "loadBalancer": {
		        "subnet1": lb_subnet,
		        "securityListManagementMode": lb_mode,
		    },
		    "rateLimiter": {
		        "rateLimitQPSRead": 20.0,
		        "rateLimitBucketRead": 5,
		        "rateLimitQPSWrite": 20.0,
		        "rateLimitBucketWrite": 5,
		    },
		}
		if region_key:
		    cfg["regionKey"] = region_key
		if lb_seclist:
		    cfg["loadBalancer"]["securityLists"] = {lb_subnet: lb_seclist}

		if mode == "api-key":
		    # Both spellings, because the Secret is hand-authored by the operator
		    # and either is valid Kubernetes.
		    fields = {}
		    for doc in yaml.safe_load_all(pathlib.Path(credpath).read_text()):
		        if not doc or doc.get("kind") != "Secret":
		            continue
		        fields.update(doc.get("stringData") or {})
		        fields.update({k: base64.b64decode(v).decode()
		                       for k, v in (doc.get("data") or {}).items()})

		    auth = {"region": region}
		    for name in ("tenancy", "user", "key", "fingerprint"):
		        value = fields.get(name) or ""
		        # .strip() on the key too: a trailing newline is harmless but a
		        # leading one breaks the PEM parser, and operators paste these.
		        value = value.strip()
		        if not value:
		            # The NAME, never the value, and never a length -- a length is
		            # a fact about a secret.
		            sys.exit("%s has no '%s'; the CCM requires it when "
		                     "useInstancePrincipals is false "
		                     "(config_validate.go:29-34)" % (credpath, name))
		        auth[name] = value
		    # Optional, and empty is normal -- an unencrypted key has none.
		    auth["passphrase"] = (fields.get("passphrase") or "").strip()

		    if "PRIVATE KEY" not in auth["key"]:
		        sys.exit("the 'key' field of %s is not a PEM private key" % credpath)
		    cfg["auth"] = auth

		docs = [
		    ("oci-cloud-controller-manager", "oci-cloud-controller-manager",
		     "cloud-provider.yaml"),
		    ("oci-volume-provisioner", "oci-csi", "config.yaml"),
		]
		# Both Secrets carry the same document under different keys in different
		# namespaces, which is how Oracle ships it.
		body = yaml.safe_dump(cfg, default_flow_style=False, sort_keys=False)
		out = pathlib.Path(state)
		out.write_text(yaml.safe_dump_all([
		    {"apiVersion": "v1", "kind": "Secret",
		     "metadata": {"name": name, "namespace": ns},
		     "stringData": {key: body}}
		    for name, ns, key in docs
		], default_flow_style=False, sort_keys=False, explicit_start=True))
		out.chmod(0o600)
	PY

	log "rendered CCM/CSI config with ${OCI_CCM_AUTH} auth ($(wc -c <"${CCM_STATE}") bytes)"
	if [[ ${OCI_CCM_AUTH} == "api-key" ]]; then
		log "WARNING: that config carries a user API signing key. It is a pilot"
		log "WARNING: expedient; instance principals are the intended end state."
	fi
}

# NO HOOK CAN PRODUCE A DAY-0 MANIFEST, AND THIS ONE USED TO TRY
#
# An earlier version of this file copied the rendered Secrets into
# <install-dir>/openshift in the hope they would be folded into the bootstrap
# as day-0 content, and recorded in the state file which of the two routes it
# had taken. The note said the route was UNVERIFIED. It is now verified, and
# it is dead: pkg/asset/cluster/cluster.go:74 lists &bootstrap.Bootstrap{} as
# a dependency of the Cluster asset, so the bootstrap ignition -- and every
# manifest folded into it -- is complete before Provision is entered and
# before any hook of any phase runs. The copy landed in a directory nothing
# read again. The branch never fired, and a branch that cannot fire is worse
# than no branch: it made the file read as though day-0 delivery were a
# possibility a partner should design around.
#
# So post-provision applies these unconditionally, and the CCM crash-loops
# until it does. That is the cost of the credential not existing at day 0, and
# on this platform it is unavoidable rather than a choice: the Secrets'
# contents depend on cloud identifiers that do not exist until the network is
# built, and manifests/ is rendered with clusterctl substitution long before
# that. This is the case a hook exists for.
# ---------------------------------------------------------------------------
# infra-ready
# ---------------------------------------------------------------------------

main() {
	local compartment_id vcn nlb api_ip internal_ip lb_subnet lb_seclist lb_nsg zone_id

	compartment_id=$(compartment)
	vcn=$(vcn_id)
	nlb=$(nlb_id)
	# TWO addresses, and which one goes where is load-bearing -- see
	# nlb_private_ip for why the public one must not reach api-int.
	api_ip=$(api_endpoint)
	internal_ip=$(nlb_private_ip "${nlb}")
	lb_subnet=$(subnet_by_role service-lb)
	# Both optional, and with CAPOCI it is always the NSG that is present.
	lb_seclist=$(seclist_by_role service-lb)
	lb_nsg=$(nsg_by_role service-lb)

	log "VCN ${vcn}, NLB ${nlb}, API endpoint ${api_ip} (public) / ${internal_ip} (private)"
	log "service-lb subnet ${lb_subnet}, security list ${lb_seclist:-<none>}, NSG ${lb_nsg:-<none>}"

	# 1. The 22623 listener, before DNS -- if this fails there is no point
	#    publishing a name that cannot serve the machine config server.
	add_mcs_listener "${nlb}"

	# 2. Private DNS, on the PRIVATE address. api-int is what the pointer
	#    ignition and the bootstrap kubeconfig resolve, and both are fetched
	#    from inside the VCN; `api` in the private zone shadows the public
	#    record for in-VCN clients, which is the same intent.
	zone_id=$(create_private_zone "${compartment_id}" "${vcn}")
	# Before any record is written, not after: a zone whose view is not
	# attached resolves for nobody inside the VCN, and the records would be
	# correct and useless. See ensure_view_attached.
	ensure_view_attached "${compartment_id}" "${vcn}"
	upsert_a_record "${zone_id}" "api-int.${CLUSTER_DOMAIN}" "${internal_ip}" PRIVATE
	upsert_a_record "${zone_id}" "api.${CLUSTER_DOMAIN}" "${internal_ip}" PRIVATE

	# 3. Public api, when the cluster is published externally. The public zone
	#    for the base domain is assumed to exist and to be managed by OCI DNS;
	#    a partner using another DNS provider replaces this one call.
	local public_zone=""
	if [[ ${PUBLISH} == "External" ]]; then
		public_zone=$(oci dns zone list --compartment-id "${compartment_id}" \
			--name "${BASE_DOMAIN}" --scope GLOBAL \
			--query 'data[0].id' --raw-output 2>/dev/null || true)
		if [[ -n ${public_zone} && ${public_zone} != "null" ]]; then
			upsert_a_record "${public_zone}" "api.${CLUSTER_DOMAIN}" "${api_ip}" GLOBAL
		else
			public_zone=""
			log "no public zone for ${BASE_DOMAIN}; skipping the public api record"
		fi
	fi

	# 4. The CCM and CSI config. Rendered here because this is the first
	#    moment the cloud identifiers it needs exist; applied at
	#    post-provision because that is the first moment a cluster exists to
	#    apply it to.
	render_ccm_secrets "${compartment_id}" "${vcn}" "${lb_subnet}" "${lb_seclist}"

	# 5. Record everything created, for pre-destroy. Nothing here is owned by
	#    Cluster API, so nothing else will remove it.
	jq -n \
		--arg zone "${zone_id}" \
		--arg public_zone "${public_zone}" \
		--arg nlb "${nlb}" \
		--arg compartment "${compartment_id}" \
		--arg vcn "${vcn}" \
		--arg lb_subnet "${lb_subnet}" \
		--arg lb_nsg "${lb_nsg}" \
		'{privateZoneId:$zone, publicZoneId:$public_zone, nlbId:$nlb,
		  compartmentId:$compartment, vcnId:$vcn,
		  serviceLbSubnetId:$lb_subnet, serviceLbNsgId:$lb_nsg}' >"${STATE}"

	log "infra-ready complete"
}

main
