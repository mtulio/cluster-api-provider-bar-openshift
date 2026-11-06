#!/bin/sh
# bin/controller -- argument shim in front of the CAPOCI manager.
#
# THIS FILE EXISTS BECAUSE OF A GAP IN THE PAYLOAD CONTRACT, NOT BECAUSE A
# PROVIDER PAYLOAD NORMALLY NEEDS ONE. Read the whole comment before copying
# the pattern; the Foo reference payload has no shim and does not need one.
#
# THE MISMATCH
#
# The installer starts the provider controller with a fixed flag set and then
# polls the address it passed:
#
#   pkg/clusterapi/external.go:155   --health-addr={{suggestHealthHostPort}}
#
# CAPOCI does not have that flag. It declares the controller-runtime spelling:
#
#   main.go:100   --health-probe-bind-address
#
# and at main.go:178-180 it folds the stdlib flag set into pflag and calls
# pflag.Parse(), which exits non-zero on an unknown flag. So the controller
# does not start at all -- it is not a warning, it is an immediate exit.
#
# Everything else the installer passes is already accepted by CAPOCI:
# --webhook-port (main.go:128), --webhook-cert-dir (main.go:133) and -v (via
# logs.AddFlags). --health-addr is the single translation needed.
#
# The flag cannot simply be dropped. The installer polls /healthz at exactly
# the host:port it passed, so a controller that is healthy on some other port
# is, to the installer, a controller that never came up.
#
# WHY A SHIM, AND WHY IT IS AWKWARD IN IMAGE MODE
#
# In the local-path pilot the shim was just another file on disk. In image
# mode it collides with layout validation:
#
#   - the descriptor can declare only the executables it names --
#     layout.controller plus its hooks, five of them in this payload
#     (descriptor.go:170)
#   - `oc image extract` writes every file 0640, and ApplyExecutableModes
#     (descriptor.go:204) restores the executable bit only for those
#   - Validate() (descriptor.go:233) then *rejects* any executable the payload
#     did not declare
#
# So the real manager cannot be declared and cannot be shipped executable. It
# is shipped as data (0644 in the image, 0640 after extraction) and this shim
# -- which is what layout.controller points at -- makes it executable at run
# time. There is no loader-based way around it: CAPOCI is built
# CGO_ENABLED=0 with -extldflags '-static', so `ld.so ./manager` is not
# available.
#
# THIS IS A FINDING, NOT A DESIGN. See README.md, "The shim is a gap", for the
# three candidate first-class fixes. A payload author should not have to write
# this file.

set -eu

log() { printf '%s %s\n' "[$(date -u +%H:%M:%S)] external-shim:" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# The payload root is the parent of the directory holding this script, since
# the descriptor places it at bin/controller. Resolve through symlinks so a
# caller invoking us by a link still finds the manager.
self=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
root=$(dirname "$(dirname "$self")")
manager="${root}/bin/manager"

[ -f "${manager}" ] || die "CAPOCI manager not found at ${manager}"

# Make the manager runnable. It arrives 0640 from `oc image extract` because
# the descriptor could not declare it. Add only the owner execute bit, exactly
# as ApplyExecutableModes does for the declared paths -- do not widen the mode.
if [ ! -x "${manager}" ]; then
    if chmod u+x "${manager}" 2>/dev/null; then
        log "made ${manager} executable"
    else
        # The payload tree can be read-only (an extraction onto a noexec or
        # read-only mount, or a hardened CI runner). Fall back to a private
        # copy. OPENSHIFT_INSTALL_STATE_DIR is preferred when the installer
        # provides it: it is per-install and already cleaned up.
        tmpdir="${OPENSHIFT_INSTALL_STATE_DIR:-${TMPDIR:-/tmp}}"
        mkdir -p "${tmpdir}" || die "cannot create ${tmpdir}"
        copy="${tmpdir}/capoci-manager"
        cp "${manager}" "${copy}" || die "cannot copy manager to ${copy}"
        chmod u+x "${copy}" || die "cannot make ${copy} executable"
        log "payload tree is read-only; running from ${copy}"
        manager="${copy}"
    fi
fi

# Translate --health-addr to --health-probe-bind-address, in both the
# `--flag=value` and the `--flag value` spellings. Rotate the argument list
# through itself: POSIX sh has no arrays, and "$@" is the only list we get.
#
# In the two-token spelling only the name is rewritten; the value rotates
# through untouched on the next iteration, which is what keeps this loop from
# having to carry state.
argc=$#
i=0
while [ "${i}" -lt "${argc}" ]; do
    arg=$1
    shift
    case ${arg} in
    --health-addr=*)
        set -- "$@" "--health-probe-bind-address=${arg#--health-addr=}"
        ;;
    --health-addr)
        set -- "$@" --health-probe-bind-address
        ;;
    *)
        set -- "$@" "${arg}"
        ;;
    esac
    i=$((i + 1))
done

# exec, not a subshell: the installer supervises this PID and signals it on
# teardown. A wrapper that stays in the process tree would swallow SIGTERM and
# leave the controller running after the installer thinks it stopped.
exec "${manager}" "$@"
