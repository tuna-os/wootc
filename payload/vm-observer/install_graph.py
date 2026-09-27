"""Independent offline selected-disk ancestry before observer installation.

This is an installer prerequisite, never an observation of a target guest boot.
"""
import json
import re


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate installed block field')
        result[key] = value
    return result


def verify_partition(raw, source, major, expected_disk):
    if (type(raw) is not str or not raw or len(raw.encode()) > 131072 or
            type(source) is not str or not re.fullmatch(r'/dev/[A-Za-z0-9._/-]+(?:\[/[^\s\\\[\]]*\])?', source) or
            type(major) is not str or not re.fullmatch('[0-9]+:[0-9]+', major) or
            type(expected_disk) is not str or not re.fullmatch('[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', expected_disk)):
        raise ValueError('installed partition observations unavailable')
    try:
        graph = json.loads(raw, object_pairs_hook=unique)
    except (ValueError, RecursionError) as error:
        raise ValueError('installed block graph malformed') from error
    if type(graph) is not dict or set(graph) != {'blockdevices'} or type(graph['blockdevices']) is not list:
        raise ValueError('installed block inventory unavailable')
    nodes = {}; parents = {}; count = 0
    def visit(node, parent, depth):
        nonlocal count
        count += 1
        if depth > 16 or count > 256 or type(node) is not dict or set(node)-{'name','type','maj:min','ptuuid','children'}:
            raise ValueError('installed block graph unsupported')
        name, device, kind = node.get('name'), node.get('maj:min'), node.get('type')
        if (type(name) is not str or not re.fullmatch('/dev/[A-Za-z0-9._/-]+', name) or
                type(device) is not str or not re.fullmatch('[0-9]+:[0-9]+', device) or
                kind not in {'disk','part'} or device in nodes):
            raise ValueError('installed block edge ambiguous or unsupported')
        if kind == 'disk' and parent is not None or kind == 'part' and parent is None:
            raise ValueError('installed block parent edge unavailable')
        nodes[device] = node; parents[device] = parent
        children = node.get('children', [])
        if type(children) is not list:
            raise ValueError('installed block children malformed')
        for child in children:
            visit(child, device, depth+1)
    for node in graph['blockdevices']:
        visit(node, None, 0)
    selected = [device for device, node in nodes.items() if node['type'] == 'disk' and node.get('ptuuid') == expected_disk]
    if len(selected) != 1:
        raise ValueError('unique selected GPT disk unavailable')
    if major not in nodes or nodes[major]['type'] != 'part' or nodes[major]['name'] != source.split('[',1)[0]:
        raise ValueError('installed source and major observations disagree')
    if parents[major] != selected[0]:
        raise ValueError('installed partition belongs to another disk')
    return {'source':source,'majorMinor':major,'selectedDisk':expected_disk,'selectedDiskDevice':nodes[selected[0]]['name'],
            'offlineInstallationOnly':True}
