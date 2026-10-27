import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import diagnostics

class QueryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.identity = {"session": "fixture", "pid": 123, "processStart": 1760000000.25, "recorderStart": 1760000001., "binaryUUID": "ABC-123", "bundleID": "test.explorer", "version": "1.0", "build": "2"}
        (self.root / 'session.json').write_text(json.dumps({"identity": self.identity, "coverage": ["synthetic"]}))
    def test_corrupt_records_and_duplicates_remain_observable(self):
        row = {"schema": 1, "session": "fixture", "sequence": 1, "uptimeNS": 1, "event": "read.end", "fields": {"duration_ms": 5}}
        raw = (json.dumps(row) + '\n') * 2 + '{bad}\n' + json.dumps(dict(row, fields=[])) + '\n' + '{partial'
        path = self.root / 'events-0000000000.jsonl'
        path.write_text(raw)
        result = diagnostics.summarize(self.root)['sessions'][0]
        self.assertEqual(result['nonincreasing_sequences'], 1)
        self.assertEqual(result['recovery']['malformed'], 2)
        self.assertEqual(result['recovery']['partial'], 1)
        self.assertEqual(result['timings']['read.end']['mean_ms'], 5)
        self.assertEqual(path.read_text(), raw)
    def test_os_report_requires_all_identity_dimensions(self):
        launch = '2025-10-09 10:53:20.250 +0200'
        self.assertEqual(diagnostics.parse_time(launch), self.identity['processStart'])
        report = {"pid":123,"procName":"CodexChats","procLaunch":launch,"captureTime":"2025-10-09 10:53:25.000 +0200","bundleInfo":{"CFBundleIdentifier":"test.explorer","CFBundleShortVersionString":"1.0","CFBundleVersion":"2"},"usedImages":[{"name":"CodexChats","uuid":"abc-123"}],"exception":{"type":"EXC_CRASH"}}
        path = self.root / 'CodexChats-fixture.ips'
        def write(value):
            path.write_text('{}\n'+json.dumps(value)+'\nSystem Profile:\nsynthetic fixture')
        write(report)
        self.assertEqual(len(diagnostics.correlate(self.root,self.root)['matches']),1)
        mutations = [('pid',456),('procLaunch','2025-10-09T08:50:00+00:00'),('usedImages',[]),('procName','Other')]
        for key,value in mutations:
            changed=copy.deepcopy(report); changed[key]=value; write(changed)
            self.assertEqual(diagnostics.correlate(self.root,self.root)['matches'],[])
        for key in ['CFBundleIdentifier','CFBundleShortVersionString','CFBundleVersion']:
            changed=copy.deepcopy(report); changed['bundleInfo'][key]='wrong'; write(changed)
            self.assertEqual(diagnostics.correlate(self.root,self.root)['matches'],[])
    def test_bundle_hash_detects_mutation_and_traversal(self):
        raw=b'original\n'; (self.root/'data').write_bytes(raw)
        manifest={'files':[{'path':'data','bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}]}
        (self.root/'bundle.json').write_text(json.dumps(manifest))
        self.assertTrue(diagnostics.verify(self.root)['verified'])
        (self.root/'data').write_bytes(b'changed\n')
        self.assertFalse(diagnostics.verify(self.root)['verified'])
        manifest['files'][0]['path']='../outside'
        (self.root/'bundle.json').write_text(json.dumps(manifest))
        with self.assertRaises(ValueError): diagnostics.verify(self.root)

if __name__ == '__main__': unittest.main()
