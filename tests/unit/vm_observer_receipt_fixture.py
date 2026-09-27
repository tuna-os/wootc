"""Actual installer/emit composition with controlled offline target facts only."""
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
fixture=runpy.run_path(str(ROOT/'tests/unit/test_vm_observer_installer_entry.py'))
control=fixture['InstallerCallerControls']();control.setUp()
entry=fixture['ENTRY']
stage=runpy.run_path(str(ROOT/'payload/vm-observer/stage_bundle.py'))
with tempfile.TemporaryDirectory(prefix='wootc-observer-ipc-') as directory:
    directory=Path(directory);bundle=directory/'bundle';hashes=stage['stage'](bundle)
    catalogue=json.loads((bundle/'catalogue.json').read_text())
    raw={name:(bundle/name).read_bytes() for name in entry['FILES']}
    with patch.object(Path,'lstat',return_value=Path('/').stat()):
        with patch.dict(entry['install'].__globals__,{'load_catalogue':lambda _:(catalogue,raw),'load_module':lambda name,_:control.modules[name]}):
            receipt=entry['install'](control.args)
    source=(ROOT/'payload/builder/wootc-builder.sh').read_text()
    definition=source[source.index('emit() {'):source.index('\n}',source.index('emit() {'))+2]
    script=directory/'emit.sh';script.write_text(definition+'\nIPC=$1\nemit "$(cat "$2")"\n')
    record=directory/'record.json';record.write_text(json.dumps(receipt)+'\n')
    ipc=directory/'private-ipc';ipc.touch(mode=0o600)
    result=subprocess.run(['/bin/sh',str(script),str(ipc),str(record)],capture_output=True,check=True,timeout=3)
    if result.stdout!=ipc.read_bytes():raise ValueError('actual private emit bytes differ')
    print(ipc.read_text(),end='')
