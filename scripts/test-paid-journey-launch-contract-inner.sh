#!/usr/bin/env bash
# Inner journey launch-contract check executed inside the agent container.
# Extracted from test-paid-journey-launch-contract.sh so shellcheck can lint it
# independently and the container-side rules stay readable.
#
# @spec LIVE-PREVIEW-012

set -euo pipefail

GUIDE_PATH="${1:-/workspace/.paid/journeys.md}"
FAILURES=0

# The guide lives at <checkout>/.paid/journeys.md, so the checkout root is two
# directories up. Repository scripts are resolved against it rather than the
# working directory, so the check does not depend on where it was invoked.
CHECKOUT_ROOT="$(cd "$(dirname "${GUIDE_PATH}")/.." && pwd)"

fail() {
    echo "   ERROR: $1" >&2
    FAILURES=$((FAILURES + 1))
}

# The guide documents the launch command as the backgrounded command of the
# journey's launch block, for example:
#   (bundle exec bin/rails server -b 0.0.0.0 -p 3000) > tmp/....log 2>&1 &
# The first documented command wins; a later block is a guide-authoring error
# this check reports rather than silently ignores.
launch_commands=$(sed -n 's/^(\(.*\)) > .*$/\1/p' "${GUIDE_PATH}")
launch_command="${launch_commands%%$'\n'*}"

if [ -z "${launch_command}" ]; then
    echo "Could not find the documented Paid journey launch command in ${GUIDE_PATH}" >&2
    exit 1
fi

if [ "${launch_commands}" != "${launch_command}" ]; then
    fail "the guide documents more than one launch command"
fi

echo "Documented journey launch command: ${launch_command}"

read -r -a tokens <<< "${launch_command}"

# Leading environment assignments are not the command itself.
leading_command=""
for token in "${tokens[@]}"; do
    case "${token}" in
        [A-Za-z_][A-Za-z0-9_]*=*) continue ;;
        *) leading_command="${token}"; break ;;
    esac
done

# The documented command has to start with something this container can run:
# an executable on the image's PATH, or a script in the checkout.
case "${leading_command}" in
    "")
        fail "the documented launch command names no executable"
        ;;
    /*)
        if [ ! -x "${leading_command}" ]; then
            fail "'${leading_command}' is not an executable path"
        fi
        ;;
    */*)
        if [ ! -f "${CHECKOUT_ROOT}/${leading_command}" ]; then
            fail "'${leading_command}' is missing from the checkout"
        elif [ ! -x "${CHECKOUT_ROOT}/${leading_command}" ]; then
            fail "'${leading_command}' is not executable"
        fi
        ;;
    *)
        if ! command -v "${leading_command}" > /dev/null 2>&1; then
            fail "'${leading_command}' is not available in this image"
        fi
        ;;
esac

# Repository scripts the command calls have to exist in the checkout and be
# executable, otherwise the container cannot run the documented command.
for token in "${tokens[@]}"; do
    if [ "${token}" = "${leading_command}" ]; then
        continue
    fi

    case "${token}" in
        bin/*)
            if [ ! -f "${CHECKOUT_ROOT}/${token}" ]; then
                fail "'${token}' is missing from the checkout"
            elif [ ! -x "${CHECKOUT_ROOT}/${token}" ]; then
                fail "'${token}' is not executable"
            fi
            ;;
    esac
done

# Paid's runtime-derived `bin/dev` command supervises its processes through
# Overmind and tmux. Verify both dependencies in the managed image before an
# agent relies on the documented launch command.
case "${launch_command}" in
    *bin/dev*)
        for supervisor in tmux overmind; do
            if ! command -v "${supervisor}" > /dev/null 2>&1; then
                fail "'bin/dev' needs '${supervisor}', which this image does not ship"
            fi
        done
        ;;
esac

if [ "${FAILURES}" -gt 0 ]; then
    echo "FAILED: ${FAILURES} check(s) failed" >&2
    exit 1
fi

echo "All journey launch-contract checks passed!"
