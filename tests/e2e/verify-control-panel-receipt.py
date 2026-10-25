#!/usr/bin/env python3
"""Validate a current-run rendered DOM receipt against independent Linux facts."""
import json
import sys


def verify(directive, state):
    if state.get('screen') != 'control':
        raise ValueError('actual app is not on the control panel')
    receipt = state.get('installedBootVerification')
    if not isinstance(receipt, dict):
        raise ValueError('real UI has not reported a rendered first-boot summary')
    for key in ('action', 'runId', 'nonce'):
        if not directive.get(key) or receipt.get(key) != directive[key]:
            raise ValueError('UI receipt is not for this run/directive: ' + key)
    if receipt.get('passed') is not True or receipt.get('errors') != []:
        raise ValueError('rendered UI rejected the independently observed facts')
    facts = directive['expected']
    observed = receipt.get('observed', {})
    for key in ('kernel', 'sourceImageRef', 'boundFolders', 'matchedUsers'):
        if observed.get(key) != str(facts[key]):
            raise ValueError('rendered UI field differs: ' + key)
    summary = (f"Linux {facts['kernel']} · {facts['sourceImageRef']} · "
               f"{facts['boundFolders']} folders connected for {facts['matchedUsers']} users")
    if observed.get('summary') != summary or not str(observed.get('heading', '')).endswith(' boot verified'):
        raise ValueError('rendered UI literal summary/heading differs')
    return receipt


if __name__ == '__main__':
    try:
        with open(sys.argv[1], encoding='utf-8-sig') as stream:
            directive = json.load(stream)
        with open(sys.argv[2], encoding='utf-8-sig') as stream:
            state = json.load(stream)
        verify(directive, state)
    except (ValueError, KeyError, TypeError) as exc:
        sys.exit(str(exc))
