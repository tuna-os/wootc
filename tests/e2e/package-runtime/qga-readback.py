"""Read-only QGA invocation, bounded externally by the owned runtime deadline."""
import argparse
import json
from pathlib import Path
import runpy


def read(socket,challenge,seconds):
    client=runpy.run_path(str(Path(__file__).with_name('qga-client.py')))['GuestAgent']
    agent=client(str(socket),timeout=seconds)
    try:
        status,out,err=agent.exec('/usr/bin/python3',[
            '/run/wootc-package-seed/readback.py','/run/wootc-package-seed',
            '/var/lib/wootc/package-proof',challenge],exec_timeout=seconds)
        if status!=0:raise ValueError('actual guest readback exit status failed')
        if len(out)>131072 or len(err)>65536:raise ValueError('QGA readback output exceeds bound')
        return json.loads(out)
    finally:agent.close()


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('socket');parser.add_argument('challenge');parser.add_argument('seconds',type=float);args=parser.parse_args()
    print(json.dumps(read(args.socket,args.challenge,args.seconds),sort_keys=True))
