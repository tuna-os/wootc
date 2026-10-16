"""Read-only QGA invocation, bounded externally by the owned runtime deadline."""
import argparse
import json
from pathlib import Path
import runpy


def read(socket,challenge,seconds,phase='new'):
    client=runpy.run_path(str(Path(__file__).with_name('qga-client.py')))['GuestAgent']
    agent=client(str(socket),timeout=seconds)
    try:
        status,out,err=agent.exec('/usr/bin/python3',[
            '/run/wootc-package-seed/readback.py','/run/wootc-package-seed',
            '/var/lib/wootc/package-proof',challenge,'--phase',phase],exec_timeout=seconds)
        if type(status) is not int or status!=0:raise ValueError('actual guest readback exit status failed')
        if len(out)>131072 or len(err)>65536:raise ValueError('QGA readback output exceeds bound')
        result=json.loads(out)
        if not isinstance(result,dict):raise ValueError('QGA readback is not a typed object')
        return result
    finally:agent.close()

def acknowledge(socket,challenge,approved,seconds):
    client=runpy.run_path(str(Path(__file__).with_name('qga-client.py')))['GuestAgent']
    agent=client(str(socket),timeout=seconds)
    try:
        status,out,err=agent.exec('/usr/bin/python3',[
            '/run/wootc-package-seed/advance.py','/run/wootc-package-seed',
            '/var/lib/wootc/package-proof',challenge,approved],exec_timeout=seconds)
        if type(status) is not int or status!=0:raise ValueError('actual guest acknowledgement status failed')
        if len(out)>4096 or len(err)>65536:raise ValueError('acknowledgement exceeds output bound')
        result=json.loads(out)
        if not isinstance(result,dict):raise ValueError('acknowledgement is not a typed object')
        return result
    finally:agent.close()


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('socket');parser.add_argument('challenge');parser.add_argument('seconds',type=float);parser.add_argument('--phase',choices=('old','new'),default='new');parser.add_argument('--approved');args=parser.parse_args()
    result=(acknowledge(args.socket,args.challenge,args.approved,args.seconds) if args.approved
            else read(args.socket,args.challenge,args.seconds,args.phase))
    print(json.dumps(result,sort_keys=True))
