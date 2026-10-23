"""Compare authored FetchProductProbe observations without numeric tolerances."""
import argparse
import json
from pathlib import Path

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('reference',type=Path)
p.add_argument('candidate',type=Path)
a=p.parse_args()

def cases(path):
    result={}
    for case in json.loads(path.read_text(encoding='utf-8'))['cases']:
        key=(case['format'],case['function'],case['mask'])
        if key in result:raise ValueError('Duplicate observation')
        result[key]=bytes.fromhex(case['hex'])
    if not result:raise ValueError('No observations')
    return result

reference,candidate=cases(a.reference),cases(a.candidate)
missing=reference.keys()-candidate.keys()
extra=candidate.keys()-reference.keys()
mismatches=[]
for key in reference.keys()&candidate.keys():
    if reference[key]!=candidate[key]:
        mismatches.append({'case':key,'referenceBytes':len(reference[key]),'candidateBytes':len(candidate[key]),
                           'differentBytes':sum(x!=y for x,y in zip(reference[key],candidate[key]))})
passed=not(missing or extra or mismatches)
print(json.dumps({'passed':passed,'cases':len(reference),'exactBytes':sum(map(len,reference.values())),
                  'missing':list(missing),'extra':list(extra),'mismatches':mismatches},indent=2))
raise SystemExit(0 if passed else 1)
