#!/bin/bash
# shellcheck disable=SC2154,SC2034  # root, rootok are set/used by dracut
# /usr/lib/dracut/modules.d/99wootc-boot/wootc-parse-cmdline.sh
# Hook 1: cmdline phase. Intercepts root= and loop= from the kernel
# command line. If loop= is present, hijacks the root handler so dracut
# doesn't try to mount the NTFS block device directly.

LOOP_PATH=$(getarg loop=)

if [ -n "$LOOP_PATH" ]; then
    ORIG_ROOT=$(getarg root=)

    if [[ "$ORIG_ROOT" == UUID=* ]]; then
        WOOTC_HOST_UUID="${ORIG_ROOT#UUID=}"

        echo "wootc_host_uuid=\"$WOOTC_HOST_UUID\"" > /tmp/wootc.env
        echo "wootc_loop_path=\"$LOOP_PATH\""       >> /tmp/wootc.env

        # Hijack the standard root assignment. Setting it to 'wootc'
        # stops systemd/dracut from trying to mount the NTFS block directly.
        root="wootc"
        rootok=1
    fi
fi
