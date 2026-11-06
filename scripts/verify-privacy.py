"""Exercise real macOS sandbox permissions using disposable files, no Internet."""
from pathlib import Path
import json, plistlib, shutil, socket, subprocess

root = Path(__file__).resolve().parent.parent
base = root / '.build' / 'privacy-check'
base.mkdir(parents=True, exist_ok=True)
app = base / 'PrivacyProbe.app'
binary_dir = app / 'Contents' / 'MacOS'
binary_dir.mkdir(parents=True, exist_ok=True)
info = dict(CFBundleExecutable='Probe', CFBundleIdentifier='local.qianliyan.privacy-probe', CFBundlePackageType='APPL')
(app / 'Contents' / 'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['swiftc','-module-cache-path',str(root/'.build/module-cache'),str(root/'Tests/PrivacyProbe.swift'),'-o',str(binary_dir/'Probe')],check=True)
shutil.copy2(binary_dir/'Probe',binary_dir/'ChildProbe')
subprocess.run(['codesign','--force','--sign','-','--entitlements',str(root/'Security/Worker.entitlements'),str(binary_dir/'ChildProbe')],check=True)
subprocess.run(['codesign','--force','--sign','-','--entitlements',str(root/'Security/App.entitlements'),str(app)],check=True)
with socket.socket() as server:
    server.bind(('127.0.0.1',0)); server.listen(4)
    port = str(server.getsockname()[1])
    # First prove the host allows the connection and writes to these fixtures.
    baseline = base/'baseline'; baseline.mkdir(exist_ok=True)
    (baseline/'document.txt').write_text('disposable baseline')
    raw = base/'UnsignedProbe'
    subprocess.run(['swiftc','-module-cache-path',str(root/'.build/module-cache'),str(root/'Tests/PrivacyProbe.swift'),'-o',str(raw)],check=True)
    plain = json.loads(subprocess.run([str(raw),str(baseline),port],capture_output=True,text=True,timeout=15,check=True).stdout)
    assert plain['readAllowed'] and not any(v for k,v in plain.items() if k!='readAllowed'), plain
    fixture = base/'protected'; fixture.mkdir(exist_ok=True)
    document = fixture/'document.txt'; document.write_text('must remain unchanged')
    before = document.stat()
    signed = subprocess.run([str(binary_dir/'Probe'),str(fixture),port,'parent'],capture_output=True,text=True,timeout=20)
    if signed.returncode:
        raise RuntimeError(f'Privacy probe exited {signed.returncode}: {signed.stderr}')
    checks = json.loads(signed.stdout)
    assert checks and all(checks.values()), checks
    assert document.read_text()=='must remain unchanged'
    assert document.stat().st_mtime_ns == before.st_mtime_ns
    assert not (fixture/'new.txt').exists() and not (fixture/'moved.txt').exists()
    print('PASS：真实 App Sandbox 主进程及继承的子进程均可读取文档，但联网、覆盖、新建、重命名、删除被系统拒绝；测试文档内容及修改时间未变。')
