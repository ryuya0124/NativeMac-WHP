"""Write only NativeMac-owned launch jobs. Invoked by the root guest installer."""
import os
import plistlib
from pathlib import Path
import sys

support=Path('/Library/Application Support/NativeMac/VideoBridge')
if os.geteuid()!=0 or sys.platform!='darwin':raise SystemExit('Requires root in the development macOS guest')
if support.resolve()!=support or support.stat().st_uid!=0 or support.stat().st_mode&0o022:
    raise SystemExit('Invalid support directory ownership')
jobs=[
    (Path('/Library/LaunchDaemons/io.nativemac.video.broker.plist'),{
        'Label':'io.nativemac.video.broker','ProgramArguments':[str(support/'NativeMacVideoBroker')],
        'MachServices':{'io.nativemac.video.broker':True},'RunAtLoad':True,'KeepAlive':True,
        'SoftResourceLimits':{'NumberOfFiles':2048},'HardResourceLimits':{'NumberOfFiles':2048},
        'StandardOutPath':str(support/'broker.log'),'StandardErrorPath':str(support/'broker.log')}),
]
for directory in ('LaunchDaemons','LaunchAgents'):
    jobs.append((Path('/Library')/directory/'io.nativemac.video.environment.plist',{
        'Label':'io.nativemac.video.environment',
        'ProgramArguments':['/bin/bash',str(support/'video_environment.sh'),'enable'],
        'RunAtLoad':True}))
jobs[-1][1]['LimitLoadToSessionType']=['Aqua','LoginWindow']
jobs[-1][1]['ProgramArguments'].append('refresh-cached-video')
jobs.append((Path('/Library/LaunchAgents/io.nativemac.video.background-environment.plist'),{
    'Label':'io.nativemac.video.background-environment',
    'ProgramArguments':['/bin/bash',str(support/'video_environment.sh'),'enable'],
    'LimitLoadToSessionType':'Background','RunAtLoad':True}))
# Validate every destination before changing any job.
for path,value in jobs:
    if path.is_symlink():raise SystemExit('Refusing a symlink launch job')
    if path.exists():
        prior=plistlib.loads(path.read_bytes())
        arguments=prior.get('ProgramArguments')
        legacy=path.name=='io.nativemac.video.environment.plist' and path.parent.name=='LaunchAgents' and arguments==value['ProgramArguments'][:3]
        if path.stat().st_uid!=0 or prior.get('Label')!=value['Label'] or (arguments!=value['ProgramArguments'] and not legacy):
            raise SystemExit('Refusing to replace an unrelated launch job')
for path,value in ([] if '--check' in sys.argv else jobs):
    path.parent.mkdir(exist_ok=True)
    temporary=path.with_suffix('.nativemac-new')
    with temporary.open('xb') as target:target.write(plistlib.dumps(value))
    temporary.chmod(0o644)
    temporary.replace(path)
