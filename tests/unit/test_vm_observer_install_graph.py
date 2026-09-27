"""Actual offline graph consumer controls; no device or target mutation."""
import json
from pathlib import Path
import runpy
import unittest

ROOT=Path(__file__).resolve().parents[2]
MODULE=runpy.run_path(str(ROOT/'payload/vm-observer/install_graph.py'))
DISK='11111111-1111-1111-1111-111111111111'

class InstalledDiskControls(unittest.TestCase):
    def setUp(self):
        self.graph={'blockdevices':[{'name':'/dev/vda','type':'disk','maj:min':'8:0','ptuuid':DISK,'children':[{'name':'/dev/vda3','type':'part','maj:min':'8:3','ptuuid':None}]}]}
    def verify(self,source='/dev/vda3[/stateroot]',major='8:3'):
        return MODULE['verify_partition'](json.dumps(self.graph),source,major,DISK)
    def test_measured_same_row_partition_matches_selected_gpt(self):
        self.assertEqual(self.verify()['selectedDiskDevice'],'/dev/vda')
    def test_foreign_whole_disk_or_source_major_refuses(self):
        self.graph['blockdevices'][0]['ptuuid']='22222222-2222-2222-2222-222222222222'
        with self.assertRaises(ValueError):self.verify()
        self.graph['blockdevices'][0]['ptuuid']=DISK
        with self.assertRaises(ValueError):self.verify('/dev/vdb3')
        with self.assertRaises(ValueError):self.verify(major='8:4')
    def test_missing_parent_loop_or_duplicate_gpt_refuses(self):
        part=self.graph['blockdevices'][0]['children'].pop()
        self.graph['blockdevices'].append(part)
        with self.assertRaises(ValueError):self.verify()
        self.graph['blockdevices']=[dict(part,type='loop')]
        with self.assertRaises(ValueError):self.verify()
        self.setUp();self.graph['blockdevices'].append({'name':'/dev/vdb','type':'disk','maj:min':'9:0','ptuuid':DISK})
        with self.assertRaises(ValueError):self.verify()
    def test_duplicate_fields_and_unknown_graph_shapes_refuse(self):
        with self.assertRaises(ValueError):MODULE['verify_partition']('{"blockdevices":[],"blockdevices":[]}','/dev/vda3','8:3',DISK)
        self.graph['blockdevices'][0]['borrowedParent']='/dev/vdb'
        with self.assertRaises(ValueError):self.verify()

if __name__=='__main__':unittest.main()
