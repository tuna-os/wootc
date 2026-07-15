#!/bin/bash
# shellcheck disable=SC2154,SC2034  # root, rootok are set/used by dracut
# /usr/lib/dracut/modules.d/99wootc-boot/wootc-parse-cmdline.sh
# Hook 1: cmdline phase. Intercepts root= and loop= from the kernel
# command line. If loop= is present, hijacks the root handler so dracut
# doesn't try to mount the NTFS block device directly.

LOOP_PATH=$(getarg loop=)
WOOTC_HOST_UUID=$(getarg wootc.host_uuid=)

if [ -n "$LOOP_PATH" ] && [ -n "$WOOTC_HOST_UUID" ]; then
    echo "wootc_host_uuid=\"$WOOTC_HOST_UUID\"" > /tmp/wootc.env
    echo "wootc_loop_path=\"$LOOP_PATH\""       >> /tmp/wootc.env

    # Keep the target's normal root= argument intact in its BLS entry, but
    # take ownership of mounting it through the Windows-backed loop device.
    root="wootc"
    rootok=1
fi
