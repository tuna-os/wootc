#!/bin/bash
# Painted from dracut's pre-trigger hook — before udev settle and the
# network-online wait, which is the stretch where the user otherwise stares
# at a black screen right after the scariest click of the whole migration
# (GRUB → deployer, DHCP can take tens of seconds). The full animated splash
# (deploy.sh splash_start) replaces this the moment the deployer starts.
# Harmless under E2E observation (serial output is untouched); skipped only
# in debug, where raw console is the point.
grep -q 'wootc\.debug' /proc/cmdline 2>/dev/null && return 0
{
    printf '\033[?25l\033[2J\033[H\n\n\n\n'
    printf '\033[1;96m                     Setting up your new Linux system\033[0m\n\n\n'
    printf '\033[0;97m                     Getting started - this can pause for a moment...\033[0m\n\n\n\n\n\n\n'
    printf '\033[0;92m                Please keep your PC plugged in.\033[0m\n'
} > /dev/tty1 2>/dev/null || true
return 0
