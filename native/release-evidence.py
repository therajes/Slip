#!/usr/bin/env python3
"""Generate local artifact provenance and a lock inventory, not a vulnerability clearance."""
import argparse, hashlib, json, os, shutil, subprocess, tomllib
from datetime import datetime, timezone
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('artifact',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
root=Path(__file__).resolve().parent.parent
a.output.mkdir(parents=True,exist_ok=True)
def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest()
lock=tomllib.loads((root/'src-tauri/Cargo.lock').read_text())
packages=[{'name':v['name'],'versionInfo':v['version'],'SPDXID':f'SPDXRef-Package-{i}','downloadLocation':v.get('source','NOASSERTION'),'filesAnalyzed':False,'licenseConcluded':'NOASSERTION','licenseDeclared':'NOASSERTION','copyrightText':'NOASSERTION'} for i,v in enumerate(lock['package'])]
commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
now=datetime.now(timezone.utc).isoformat().replace('+00:00','Z')
sbom={'spdxVersion':'SPDX-2.3','dataLicense':'CC0-1.0','SPDXID':'SPDXRef-DOCUMENT','name':'Slip lockfile dependency inventory','documentNamespace':f'https://github.com/therajes/Slip/sbom/{commit}/{digest(a.artifact)}','creationInfo':{'created':now,'creators':['Tool: Slip release-evidence.py']},'packages':packages}
(a.output/'SBOM.spdx.json').write_text(json.dumps(sbom,indent=2)+'\n')
scans={}
for name,command in [('cargo-audit',['cargo','audit','--file',str(root/'src-tauri/Cargo.lock'),'--json']),('osv-scanner',['osv-scanner','scan','source','--lockfile',str(root/'src-tauri/Cargo.lock'),'--format','json'])]:
    executable=shutil.which(name)
    if not executable:
        scans[name]={'status':'NOT RUN','reason':'Tool not installed'};continue
    # Tool availability alone never constitutes a successful scan.
    result=subprocess.run(command,cwd=root,capture_output=True,text=True,timeout=180)
    (a.output/(name+'.json')).write_text(result.stdout)
    scans[name]={'status':'PASS' if result.returncode==0 else 'REVIEW REQUIRED','exitCode':result.returncode}
(a.output/'PROVENANCE.json').write_text(json.dumps({'schemaVersion':1,'commit':commit,'worktreeModified':bool(subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True).strip()),'cargoLockSHA256':digest(root/'src-tauri/Cargo.lock'),'artifact':a.artifact.name,'sha256':digest(a.artifact),'generatedAt':now,'signingMode':'production requested; inspect signed artifact evidence' if os.getenv('SLIP_PRODUCTION_SIGNING')=='1' else 'local/ad-hoc; not production-notarized','scanners':scans,'limitations':['Lockfile inventory is not a complete OS/framework SBOM','No clean-machine Gatekeeper or physical iPhone result inferred']},indent=2)+'\n')
(a.output/'SHA256SUMS.txt').write_text(digest(a.artifact)+'  '+a.artifact.name+'\n')
