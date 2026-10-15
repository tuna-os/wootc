"""Typed serial comparator; package success also needs independent fresh QGA readback."""
import hashlib
import json
import re

PREFIX='WOOTC_PACKAGE_RUNTIME_V1 '
STAGES=('baseline-observed','old-installed','new-installed','complete')


def inventory_digest(value):
    return hashlib.sha256((json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()).hexdigest()


def validate(serial, plan, qga=None,through=None):
    if through not in (None,'old'):raise ValueError('unknown serial observation phase')
    required={'bootstrap.py','package-consumer.py','packages.json','readback.py','advance.py'}
    if (set(plan['helperHashes'])!=required or
            any(not re.fullmatch('[0-9a-f]{64}',value) for value in plan['helperHashes'].values()) or
            plan['policySha256']!=plan['helperHashes']['packages.json'] or
            plan['qgaReadbackSourceSha256']!=plan['helperHashes']['readback.py']):
        raise ValueError('complete pinned helper closure required')
    if len(serial.encode())>262144: raise ValueError('serial proof exceeds bound')
    records=[]
    for line in serial.splitlines():
        if not line.startswith(PREFIX):continue
        if len(line)>65536:raise ValueError('serial record exceeds bound')
        value=json.loads(line[len(PREFIX):])
        if not isinstance(value,dict):raise ValueError('serial proof is not an object')
        records.append(value)
    stages=STAGES[:2] if through=='old' else STAGES
    if [value.get('stage') for value in records] != list(stages):
        raise ValueError('missing duplicate or out-of-order actual package stages')
    boot=records[0].get('bootId','')
    if not re.fullmatch('[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}',boot):
        raise ValueError('actual boot identity malformed')
    expected=[plan['policy']['phases']['old']['beforeInventory'],
              plan['policy']['phases']['old']['afterInventory'],
              plan['policy']['phases']['new']['afterInventory'],
              plan['policy']['phases']['new']['afterInventory']]
    if through=='old':expected=expected[:2]
    for value,inventory in zip(records,expected):
        if (type(value.get('schemaVersion')) is not int or value['schemaVersion']!=1 or
                type(value.get('exitStatus')) is not int or value['exitStatus']!=0 or
                value.get('bootId')!=boot or value.get('inventory')!=inventory or
                value.get('inventorySha256')!=inventory_digest(inventory)):
            raise ValueError('serial status boot or exact inventory differs')
        for name in ('scratchId','challenge','seedSha256','helperHashes','policySha256'):
            if value.get(name)!=plan[name]:raise ValueError('serial source or current challenge differs')
    if qga is None:
        return {'serialObservationsMatch':True,'packageInstallationAccepted':False,
                'reason':'fresh independent QGA readback remains required','firmwareAcceptance':False}
    if (not re.fullmatch('[0-9a-f]{64}',plan.get('readbackChallenge','')) or
            plan['readbackChallenge']==plan['challenge']):
        raise ValueError('new independent readback challenge required')
    if (qga.get('os')!='Linux' or qga.get('bootId')!=boot or
            qga.get('challenge')!=plan['readbackChallenge'] or
            qga.get('currentInventory')!=expected[-1] or qga.get('result')!=records[-1] or
            qga.get('sourceSha256')!=plan['qgaReadbackSourceSha256'] or qga.get('seedSha256')!=plan['seedSha256'] or
            type(qga.get('exitStatus')) is not int or qga['exitStatus']!=0):
        raise ValueError('independent current QGA readback differs')
    return {'serialObservationsMatch':True,'oldPhaseObserved':through=='old','packageInstallationAccepted':through is None,
            'firmwareAcceptance':False,'classicOsBootAcceptance':False,'scope':'guest package installation only'}
