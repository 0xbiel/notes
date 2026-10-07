from pathlib import Path
import tempfile,shutil,subprocess,zipfile,json,hashlib
r=Path(__file__).resolve().parent.parent;stage=Path(tempfile.mkdtemp(prefix='notes-app-stage-'))
try:
    app=stage/'Notes.app'
    shutil.copytree(r/'build/Notes.app',app,copy_function=shutil.copyfile)
    subprocess.run(['xattr','-cr',str(app)],check=True)
    subprocess.run(['codesign','--force','--sign','-','--timestamp=none',str(app)],check=True,capture_output=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True,capture_output=True)
    archive=r/'build/Notes-local.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
        for p in sorted(app.rglob('*')):
            if p.is_file():
                info=zipfile.ZipInfo.from_file(p,str(p.relative_to(stage)))
                info.external_attr=((0o100755 if p.parent.name=='MacOS' else 0o100644)<<16)
                z.writestr(info,p.read_bytes(),compress_type=zipfile.ZIP_DEFLATED)
    evidence={'metadata_free_archive_bundle_strict_verification':True,'zip':'build/Notes-local.zip','sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),'workspace_embedded_in_local_bundle':True,'microphone_started_by_assistant':False,'private_content_sent_to_AI':False,'provider_test':'Exact invented demo succeeded with retention permitted and no-training/free-only filters. Real content still requires ZDR; no eligible endpoint in saved private-profile test. No external calls repeated for packaging.','asr_limit':'Local Whisper small is fast but the authorized real recording produced extensive repetition and garbling; review required.'}
    (r/'qa').mkdir(exist_ok=True)
    (r/'qa/delivery-verification.json').write_text(json.dumps(evidence,indent=2)+'\n')
    print(json.dumps(evidence))
finally:shutil.rmtree(stage)
