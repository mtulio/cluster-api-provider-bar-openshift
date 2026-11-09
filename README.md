# cluster-api-provider-bar-openshift

Reference implementation of a **provider payload image** — the artifact a cloud provider
publishes so that `openshift-install` can provision infrastructure on their platform with
`platform: external` and their own Cluster API provider.

This repository is the whole thing: a `Containerfile` and the files it packages.

It is the second of two reference payloads. The first,
`cluster-api-provider-foo-openshift`, demonstrates the mechanism. **This one is the
evidence.** Read "What has and has not been proven" before you rely on either.

## "Bar" is CAPOCI, and that is the point

Bar is a fictional cloud name for **Oracle Cloud Infrastructure**, driven by
**Cluster API Provider OCI (CAPOCI)** and running on real OCI.

The Foo payload reuses Cluster API Provider AWS. CAPA is **vendored into
`openshift-install`** — the installer ships it, knows its types and can start it without
any payload at all. So a successful Foo install cannot distinguish *"the installer ran the
binary the payload handed it"* from *"the installer ran the binary it already had"*. That
is the whole claim the mechanism makes, and the Foo arm cannot test it.

Nothing in `openshift-install` has ever heard of CAPOCI. There is no OCI code path, no
vendored CAPOCI, no OCI entry in any installer table, and no feature gate. If a Bar
install provisions infrastructure, the binary came from this image and nowhere else.

That asymmetry is why this repository exists, and why its two gaps below are worth more
than its successes.

## The repository root is the payload root

`openshift.yaml` declares a layout under `spec`, and every path it declares is a file or
directory in this repository. The installer extracts the image into `capiInstallerPath` (default
`<install-dir>/capi-installer`) and validates that layout before it makes a single cloud
call.

| Path | `openshift.yaml` key | Where it comes from | Reaches the cluster? |
| --- | --- | --- | --- |
| `bin/controller` | `spec.capi.controller` | Oracle's released CAPOCI manager, copied out of their controller image at build time and renamed | no — runs as a local installer process |
| `infrastructure-components.yaml` | `spec.capi.infrastructureComponents` | CAPOCI's release assets at build time | no — only its CRDs and webhooks are applied, to the local control plane |
| `metadata.yaml` | — | CAPOCI's release assets at build time | no |
| `openshift.yaml` | — | this repository | no |
| `cluster-api/` | `spec.capi.clusterTemplates` | this repository | **no** — applied to the installer's ephemeral control plane |
| `manifests/` | `spec.openshift.manifestTemplates` | this repository | **yes** — folded into `<install-dir>/manifests/` |
| `hooks/` | `spec.openshift.installerHooks.<phase>.program` | this repository | no — run on the installer host |

One key in `spec.capi` declares no path: `controllerArgs` is the controller's **whole**
command line, which the payload owns rather than contributes to. On this payload it is the
key that removed a file — see below. The installer renders `{{.WebhookPort}}`,
`{{.WebhookCertDir}}` and `{{suggestHealthHostPort}}` into it and appends `--kubeconfig`;
everything else is the provider's to declare. A cluster creator who needs one more flag
adds it with `clusterAPI.controllerExtraArgs`, which is appended after this list.

The three build-time files are not committed. They are fetched by the `Containerfile`,
pinned by image digest and SHA-256, and a build that cannot reproduce those digests fails.

`cluster-api/` and `manifests/` look alike and are not alike: same `${VAR}` syntax, two
different destinations and two different lifetimes. That is why they are separate keys
rather than one rendered directory. `manifests/` has one further constraint `cluster-api/`
does not: the bootstrap node counts documents in each extra manifest and rejects a
multi-document file, so every file there holds exactly one object. CI enforces it.

## The shim was a gap, and the gap is closed

**This payload used to ship a shim at `bin/controller` and it no longer does.** The finding
that produced it is recorded here because it is what changed the contract, and because a
payload author hitting the same wall should be able to recognise it.

**The finding.** The installer started the provider controller with a *fixed* flag set
including `--health-addr=<host:port>`, then polled `/healthz` at exactly that address.
CAPOCI declares the controller-runtime spelling, `--health-probe-bind-address`
([`main.go:100`](https://github.com/oracle/cluster-api-provider-oci/blob/main/main.go)),
folds the stdlib flag set into pflag and calls `pflag.Parse()` — which exits non-zero on an
unknown flag. The controller did not start at all. The flag could not simply be dropped
either: a controller healthy on some other port is, to the installer, a controller that
never came up. And the installer's list was *appended to*, never replaced, so no amount of
configuration could remove the wrong spelling.

**Why that cost a second file too.** A payload may declare only the executables it names,
and layout validation *rejects* an executable the payload did not declare. The descriptor
had one controller slot and the wrapper was in it, so Oracle's binary had to ship as
**data** at `0644` and be `chmod`'d at run time. There was no loader-based escape: CAPOCI
is built `CGO_ENABLED=0` with `-extldflags '-static'`, so `ld.so ./manager` is not
available. One mismatched flag name therefore produced a wrapper script, a non-executable
binary and a CI check to keep the two honest.

**The fix.** `spec.capi.controllerArgs` — the payload declares the controller's whole
command line, and the installer renders its three tokens into it rather than injecting
flags of its own. This payload now names `--health-probe-bind-address={{suggestHealthHostPort}}`
directly, `bin/controller` *is* Oracle's manager, and `shim/`, `bin/manager` and the shim's
CI job are all gone. It is also what every *integrated* provider already does: Nutanix
declares `--health-probe-bind-address` where AWS declares `--health-addr`
(`pkg/clusterapi/system.go:381` and `:345`), so the external path was the odd one out.

Two things worth keeping from the episode. First, the problem was invisible in local-path
mode and only bit in image mode, because that is where the declared-executable rule makes
the wrapper and the wrapped binary compete for the one controller slot — a reminder that
the packaging mode is part of the contract, not a detail of it. Second, "the partner ships
a wrapper script" was the enhancement proposal's own answer to *"what if the provider's
flags differ"*, and it was wrong; this repository is where that was found out.

## The ignition offload, and the hook that declares it

This was the install-blocking gap in the first version of this payload. The enhancement
proposal closes it with a fourth hook, and this payload now declares that hook. **It
depends on installer support that does not exist yet** — see "What has and has not been
proven" below.

CAPOCI base64-encodes bootstrap data into OCI instance metadata, and OCI rejects a launch
whose metadata exceeds 32,000 bytes. `bootstrap.ign` is hundreds of kilobytes. The cap is
an **OCI service limit, not a check in CAPOCI** — `grep` finds no such constant in the
provider — so an oversized document fails at the cloud API with a message about metadata
size and nothing that mentions Ignition. CAPA takes the same input and never meets this,
because it stages the document inside its own controller via `AWSCluster.spec.s3Bucket`,
downstream of anything the installer reads. That asymmetry is the whole reason the hook
exists, and it is why the Foo payload does not declare it.

The OCI pilot solved it **outside the installer**: a wrapper script uploaded the real
`bootstrap.ign` to Object Storage and replaced it with a ~300-byte pointer config, in the
window between `create ignition-configs` and `create cluster`. That worked only because
the asset store re-reads a changed file from disk across process boundaries — shared
behaviour every platform relies on, which is a poor thing to build a partner contract on.

`ignition` turns that wrapper into a declared phase. It is named for the installer's
`IgnitionProvider` point of extension, which is where the integrated providers stage an
oversized bootstrap ignition too, and it runs there: **after the Cluster reports its
infrastructure ready and before any Machine is created**. The network and the load
balancers exist by then; no compute does. It is the only hook whose output the installer
reads back. Two properties
are deliberate and this payload depends on both:

- **The installer's `bootstrap.ign` is never touched.** The hook writes
  `bootstrap-staged.ign` into a directory the installer creates for it, named by
  `spec.openshift.installerHooks.ignition.bootstrapOutputPath`, and that name may not collide with the
  installer's own artifact.
- **The phase is gated.** `platform.external.clusterAPI.bootstrapIgnitionStaging` must be
  `Allowed`. This is the only hook handed the cluster's day-0 secret material — the MCS TLS
  key, a CA key, the pull secret, the kubeadmin hash — so consent belongs to the cluster
  creator rather than to the payload.

`hooks/ignition.sh` is the implementation. It logs the ignition's size and SHA-256 and
never its content, records the bucket and object name *before* uploading so a run that dies
mid-way still leaves `preDestroy` something to clean up, and stores the pre-authenticated
request's **OCID and never its URL** — the OCID is an identifier, the URL is a bearer
credential over every bootstrap secret.

**It remains an escape hatch, not an idiom.** The first-class fix is object-store offload
upstream in CAPOCI, mirroring CAPA. If that lands, this payload stops declaring the hook and
nothing else here changes.

## What has and has not been proven

Be precise about this; the two arms prove different things.

| Claim | Status |
| --- | --- |
| A payload image can be built from a provider's own published release artifacts, with no clone and no compiler | **proven** — this repository builds from an image digest and two SHA-256-pinned assets |
| The layout contract is expressible for a provider the installer has never heard of | **proven** — `openshift.yaml` here describes CAPOCI with no installer change |
| The installer can start a controller it does not ship | **payload validated through `create manifests`; not yet run end to end for CAPOCI.** The installer implements the `ignition` phase, so the contract is no longer the blocker |
| `platform: external` + CAPI can install a cluster on OCI | **proven by the pilot, not by this payload.** The pilot ran from local paths with an out-of-band ignition offload |
| The hooks in this repository do what they claim on real OCI | **proven as pilot code, except one.** Every comment marked `MEASURED` records a real run, and none has been re-run from inside a payload image. `hooks/ignition.sh` is the exception: it is a port of the pilot's wrapper into the hook contract and **has never been run in either form from this repository** |
| The image carries no credential and nothing tenancy-specific | **proven, and checked in CI on every build** |

Everything carried over from the pilot is marked in place. Where a claim could not be
re-verified in image mode, it says so rather than being quietly restated.

## Build

```sh
podman build -t quay.io/<you>/cluster-api-provider-bar-openshift:v0.1.0 .
```

Any builder will do — podman, docker, buildah. The release assets are fetched and
checksummed in a throwaway stage rather than with `ADD --checksum`, which would have
imposed a podman 5.0 / BuildKit floor on everyone copying this repository.

To move to a new CAPOCI release, bump `PROVIDER_VERSION` and `PROVIDER_DIGEST` and
re-derive the two asset checksums:

```sh
V=v0.24.2
R=https://github.com/oracle/cluster-api-provider-oci/releases/download
for f in infrastructure-components.yaml metadata.yaml; do
  curl -sSL "$R/$V/$f" | sha256sum | sed "s|-|$f|"
done
skopeo inspect docker://ghcr.io/oracle/cluster-api-oci-controller:$V \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["Digest"])'
```

**Sort CAPOCI release tags by version, never by publication date.** `v0.23.5` is listed
first by the GitHub API because it was *published* later than `v0.24.2`; it is a backport.

Always fetch release assets through the stable
`https://github.com/<org>/<repo>/releases/download/<tag>/<asset>` form and let it redirect.
The URL your browser ends up on is signed, carries a bearer token in its query string and
expires within the hour — pasting it into a `Containerfile`, a log or a commit records a
credential.

## Publish and consume

```sh
podman push quay.io/<you>/cluster-api-provider-bar-openshift:v0.1.0
skopeo inspect docker://quay.io/<you>/cluster-api-provider-bar-openshift:v0.1.0 \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["Digest"])'
```

```yaml
platform:
  external:
    platformName: bar
    cloudControllerManager: External
    clusterAPI:
      payloadImage: quay.io/<you>/cluster-api-provider-bar-openshift@sha256:<digest>
      # Consent to the payload's ignition hook, the only hook handed the
      # cluster's day-0 secret material. A payload that declares it while this
      # is absent is refused at PreProvision -- before the local control plane
      # starts and before any cloud resource is created -- and again at the
      # handover itself.
      #
      # `create manifests` resolves the payload earlier without consulting this
      # field, so it accepts a non-consenting install-config and `create
      # cluster` is where the refusal lands. Nothing is spent in between.
      bootstrapIgnitionStaging: Allowed
      variables:
        OCI_COMPARTMENT_ID: ocid1.compartment.oc1..CHANGE-ME
        OCI_REGION: us-ashburn-1
        OCI_IMAGE_ID: ocid1.image.oc1.iad.CHANGE-ME
        OCI_CCM_IMAGE: ghcr.io/oracle/cloud-provider-oci:v1.34.0
```

A conforming payload needs no path configuration at all — every path defaults beneath
`capiInstallerPath`, and `openshift.yaml` supplies the rest.

Compute replicas must be `0`: on `platform: external` the installer creates no MachineSets,
and the worker Machines in `cluster-api/machines/` are what bring the nodes up.

### Variables

Rendered with clusterctl substitution: `${VAR}`, `${VAR=default}`, `${VAR:="default"}`.
`INSTALLER_`-prefixed variables are supplied by the installer; everything else comes from
`clusterAPI.variables`. An unresolvable variable fails validation before any cloud call.

| Variable | Required | Default | Notes |
| --- | --- | --- | --- |
| `OCI_COMPARTMENT_ID` | yes | — | the compartment every resource is created in |
| `OCI_REGION` | yes | — | |
| `OCI_IMAGE_ID` | yes | — | the RHCOS custom image — see "RHCOS boot images" |
| `OCI_CCM_IMAGE` | yes | — | drives the CCM **and** the CSI driver; Oracle ships both from one image. The CSI sidecars stay pinned to `registry.k8s.io/sig-storage/*` |
| `OCI_SHAPE` | no | `VM.Standard.E4.Flex` | |
| `OCI_OCPUS` | no | `4` | |
| `OCI_MEMORY_GB` | no | `16` | |
| `OCI_BOOT_VOLUME_GB` | no | `120` | |
| `OCI_VCN_DNS_LABEL` | no | `ocpvcn` | ≤15 chars, alphanumeric, must start with a letter. A short literal rather than `${INSTALLER_INFRA_ID}`, because clusterctl substitution cannot truncate |
| `INSTALLER_INFRA_ID` | — | supplied by the installer | |

**The network CIDRs are deliberately not variables.** The VCN, subnet and ~40 network
security group rules in `cluster-api/cluster.yaml` are written against those exact ranges,
and CAPOCI prunes NSG rules it did not create. Parameterising the CIDRs without
parameterising every rule that references them produces a cluster whose security rules
silently do not match its network. Edit the file if you need different ranges.

**Two names for the region, and it is a wart.** `OCI_REGION` is a template variable; the
hooks read `OCI_CLI_REGION`, which is the OCI CLI's own environment variable, because they
shell out to `oci`. Set both, to the same value.

### Hooks

Hooks are copied verbatim and **never rendered** — they expand `${OPENSHIFT_INSTALL_INFRA_ID}`,
`${OCI_CLI_REGION}` and the rest as *shell* variables at run time, and substituting those at
render time would destroy the scripts. They receive **paths, not documents**:
`OPENSHIFT_INSTALL_INFRA_JSON`, `OPENSHIFT_INSTALL_KUBECONFIG`, `OPENSHIFT_INSTALL_STATE_DIR`.

| Hook | When | What it must do here |
| --- | --- | --- |
| `infraReady` | after CAPOCI reports `Cluster.status.infrastructureReady` | publish `api` and `api-int` DNS; add the 22623 machine-config-server listener to the API network load balancer; render and place the CCM/CSI credential Secrets, whose cloud identifiers only exist once the network is built |
| `postProvision` | after the cluster is up | publish the `*.apps` wildcard at the ingress load balancer, and annotate it into the service-lb network security group — placement CAPOCI can express only by an OCID it mints minutes after the manifests are written |
| `preDestroy` | before `destroy cluster` tears infrastructure down | remove what the other two created, and **restore the provider credential Secret into the local control plane** so CAPOCI can authenticate to tear down |

`infraReady` is not optional in practice. Without `api-int` resolving, bootkube fails at
`resolve-api-int-url` and the install dies roughly forty minutes later at the bootstrap
timeout, with an error that points nowhere near the cause.

`preDestroy` is not optional either, and its failure mode is worse: omit the credential
restore and the teardown hangs indefinitely rather than erroring, because the destroy path
waits on a controller that cannot authenticate.

`postProvision` is the only phase that takes arguments. The other two reject them, so a
descriptor wired to the wrong script fails loudly instead of, say, publishing DNS records
during a teardown. Each script also asserts `OPENSHIFT_INSTALL_HOOK` matches the phase it
believes it is.

The three phases share [`hooks/lib/common.sh`](hooks/lib/common.sh), which is **sourced,
never run, and ships without an execute bit** — layout validation rejects an executable the
descriptor does not name, so an undeclared helper is not "extra", it is a payload that fails
to install. One script dispatching on `OPENSHIFT_INSTALL_HOOK` would work equally well; the
OCI pilot did exactly that.

The hooks require `oci`, `jq`, `oc` and `python3` on the installer host's `PATH`.

Environment the hooks read beyond the installer's own:

| Variable | Required | Default |
| --- | --- | --- |
| `OCI_CLI_REGION` | yes | — |
| `OCI_CLI_CONFIG_FILE` | effectively | the `oci` CLI's own default |
| `OCI_PROVIDER_CREDENTIALS_FILE` | no | `<install-dir>/oci-credentials.yaml` |
| `OCI_CCM_AUTH` | no | `api-key` (`api-key` or `instance-principal`) |

### The credential Secret you must supply

**No credential of any kind is in this image, and none ever will be.** A provider payload is
a generic, multi-tenant artifact; an image carrying one tenancy's signing key is not one.

`cluster-api/cluster.yaml` declares an `OCIClusterIdentity` of type `UserPrincipal` naming a
Secret `${INSTALLER_INFRA_ID}-oci-credentials` in `openshift-cluster-api-guests`. You create
that Secret. Point `OCI_PROVIDER_CREDENTIALS_FILE` at the file holding it.

CAPOCI's published `infrastructure-components.yaml` also declares a Secret named
`capoci-auth-config`. It is **inert here** — the installer runs the controller as a local OS
process and applies only CRDs and webhook configurations, so the bundle's Namespace, RBAC,
Deployment and Secret are never applied. It carries clusterctl placeholders, not values.

The same file is read by two unrelated things: `preDestroy` puts it back into the local
control plane so CAPOCI can authenticate to tear down, and — when `OCI_CCM_AUTH=api-key` —
`infraReady` reads the same six fields to build the in-cluster CCM configuration. That is
deliberate: one credential, not two.

**`OCI_CCM_AUTH=api-key` should not ship.** The Secret holds a *user's* API signing key, so
the CCM runs with that user's permissions across the whole tenancy rather than a dynamic
group's permissions scoped to one compartment. It is the default here only because it is
what makes a pilot run possible today. `instance-principal` is the correct production
answer.

### What the CCM needs that CAPI cannot give it

Some of what a `platform: external` cluster needs cannot be a static manifest, and this is
the general reason a payload declares hooks at all rather than shipping `manifests/` alone:

- **Cloud identifiers that do not exist at render time.** The CCM/CSI configuration embeds
  the VCN, subnet and NSG OCIDs CAPOCI mints while building the network. `manifests/` is
  rendered long before that, so the Secrets are written by `infraReady`.
- **Placement expressible only by OCID.** The OCI CCM attaches a load balancer to a network
  security group only when the Service names it by OCID. `postProvision` annotates it.
- **A second load balancer listener.** An `OCICluster` has exactly one load balancer, the
  API server's, and no concept of a second. The 22623 machine-config-server listener is
  added by `infraReady`; ingress asks for its own through the CCM.

None of these is specific to OCI. Each is an instance of "the controller knows something at
run time that the manifest author could not know at write time."

### RHCOS boot images

`OCI_IMAGE_ID` must be a **custom image you have already imported into your tenancy**. Red
Hat does not publish an RHCOS image to OCI's marketplace, so there is no generic image to
default to — and a payload must not reference a tenancy-specific OCID, which is why this
variable is required with no default.

RHCOS already ships Ignition with the `oraclecloud` provider compiled in, so the capability
is present; only the published artifact is missing. Boot the image with
`ignition.platform.id=openstack`, which is the configuration the pilot ran: it is the
platform ID whose Ignition provider reads OCI's metadata channel. Afterburn then asks the
OpenStack metadata API for a hostname, OCI does not serve that API, and the hostname stays
at its default — which is what
[`manifests/99_external-01-oci-hostname-master.yaml`](manifests/99_external-01-oci-hostname-master.yaml)
exists to repair. Without it, every machine registers as `localhost.localdomain` and three
masters contend for one Node object.

## Before you publish

The payload image is the provider's supported artifact. Nobody else validates it.

```sh
# export the image once; every check below reads the extracted tree.
# the command argument is required and never runs — a scratch image has no
# ENTRYPOINT, and podman 4.x refuses to create a container without one.
root=$(mktemp -d)
id=$(podman create <image> /bin/controller)
podman export "$id" | tar -x -C "$root"; podman rm "$id"

# 1. the layout the descriptor promises is the layout the image has
ls -la "$root"

# 2. exactly the declared executables, and no others
find "$root" -type f -perm -u+x

# 3. the controller is statically linked — the installer runs it on the host,
#    not in a container, so it cannot rely on the image's libc. bin/controller
#    is Oracle's manager, renamed; before the shim was removed this check had
#    to target bin/manager instead, because bin/controller was a shell script
#    and would have passed vacuously.
file "$root/bin/controller"       # must say "statically linked"

# 4. no credentials, nothing tenancy-specific. An OCID names one tenancy,
#    compartment or subnet; a payload carrying one is not generic, even though
#    an OCID is not itself a secret. There is no allowlist here, and that is
#    measured, not assumed: CAPOCI's published bundle matches none of these.
grep -rIoE 'BEGIN [A-Z ]*PRIVATE KEY|ssh-(rsa|ed25519|dss)|AKIA[0-9A-Z]{16}|ocid1\.[a-z0-9]+\.oc1|eyJ[A-Za-z0-9_-]{20,}' "$root"
```

Check 4 prints matches by design — run it on an image you built, never paste its output
anywhere. CI runs the same patterns but reports **counts and filenames only**.

All of these run in CI on every pull request, plus the template checks below. Run them
locally before you open one.

## Continuous integration

[`.github/workflows/payload-image.yaml`](.github/workflows/payload-image.yaml) has two jobs.

`verify-sources` needs no image and no registry permission:

- `bash -n` over the hooks.
- `shellcheck`, in the same container image the installer's own `hack/shellcheck.sh` uses.
- Every YAML parses; every file in `manifests/` holds exactly one object.
- **Every `${...}` token belongs to the `INSTALLER_` or `OCI_` namespace.** The renderer
  matches tokens in the file *text* — it does not know what a YAML comment is and has no
  escape for a literal. A shell snippet reproduced in a comment for reviewability becomes a
  set of undeclared variables and the install is refused at validation. This check exists
  because that happened here.
- **An embedded base64 script matches the plaintext reproduced above it.** Editing the
  readable copy and not the encoded one is silent: the manifest stays valid and the node
  runs the old script.
- **`spec.capi.controllerArgs` carries each render token exactly once** and does not
  declare `--kubeconfig`, which the installer appends itself. Parsed from the descriptor,
  so no image and no cloud are needed.

`build` builds the image, runs the "Before you publish" checks against the extracted tree,
and publishes to GitHub Container Registry:

| Event | Tag |
| --- | --- |
| pull request | `PR-<number>`, overwritten on each push to that PR |
| push to `main` | `main` |
| push of a `v*` tag | the tag, plus `latest` for a final `vX.Y.Z` only |

Untagged versions left behind by an overwritten `PR-<number>` are pruned after each push, so
an active pull request costs one image, not one per commit.

A pull request from a fork is built and verified but not published: its `GITHUB_TOKEN` is
read-only for packages. Nothing in the job needs a secret beyond that token.

Consume a published image **by digest**, not by tag — the job prints the digest in its
summary. `PR-<number>` and `main` are moving tags and are for testing, not for an install
you intend to keep.

## What is not in this image

- **No cloud credentials.** On `platform: external` the installer holds none by design. The
  controller takes them from the Secret you supply; the hooks use the operator's own `oci`
  CLI configuration.
- **No OCIDs, and nothing tenancy-specific.** Every OCI identifier is a variable the cluster
  creator supplies. CI fails the build on a literal OCID.
- **No OpenShift release content.** Red Hat supports the release payload; the provider
  supports what the provider ships.
- **Nothing from the installer's Cluster API control plane.** It is local to the installer
  process and ephemeral. Its objects, and especially its Secrets, never reach the installed
  cluster.
- **No repository furniture.** The `Containerfile` names each path explicitly rather than
  copying `.`, so adding a file here does not add it to the payload. `README.md`,
  `LICENSE`, `.github/` and `.git` are all outside the image.

## License

Apache License 2.0 — see [LICENSE](LICENSE). The upstream artifacts the build pulls in carry
their own licenses: the CAPOCI controller binary and release manifests are Apache-2.0 from
[oracle/cluster-api-provider-oci](https://github.com/oracle/cluster-api-provider-oci), and
the CCM, CSI and hostname manifests derive from Oracle's
[oci-openshift](https://github.com/oracle-quickstart/oci-openshift) assets.
