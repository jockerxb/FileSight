"""Test actual sandbox policies with disposable files and a local TCP listener."""
from pathlib import Path
import json, plistlib, shutil, socket, subprocess, tempfile

root = Path(__file__).resolve().parent.parent
build = root / '.build'
build.mkdir(exist_ok=True)
app_entitlements = root / 'Security/App.entitlements'
worker_entitlements = root / 'Security/Worker.entitlements'

def require(condition, message):
    if not condition:
        raise SystemExit(message)

with tempfile.TemporaryDirectory(prefix='privacy-check-', dir=build) as temp, socket.socket() as server:
    base = Path(temp).resolve()
    app = base / 'PrivacyProbe.app'
    binary_dir = app / 'Contents/MacOS'
    binary_dir.mkdir(parents=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
        CFBundleExecutable='Probe', CFBundleIdentifier='local.qianliyan.privacy-probe', CFBundlePackageType='APPL')))
    raw = base / 'UnsignedProbe'
    subprocess.run(['swiftc', '-module-cache-path', str(build/'module-cache'),
                    str(root/'Tests/PrivacyProbe.swift'), '-o', str(raw)], check=True)
    shutil.copy2(raw, binary_dir/'Probe')
    shutil.copy2(raw, binary_dir/'ChildProbe')
    subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(worker_entitlements),
                    str(binary_dir/'ChildProbe')], check=True)
    server.bind(('127.0.0.1', 0))
    server.listen(4)
    port = str(server.getsockname()[1])

    def run_probe(executable, fixture, *args):
        proc = subprocess.run([str(executable), str(fixture), port, *args], capture_output=True, text=True, timeout=20)
        require(proc.returncode == 0, f'探针失败：{proc.stderr}')
        return json.loads(proc.stdout)

    baseline = base / 'baseline'
    baseline.mkdir()
    (baseline/'document.txt').write_text('disposable baseline')
    plain = run_probe(raw, baseline)
    require(plain['readPolicyPassed'] and not any(v for k, v in plain.items() if k != 'readPolicyPassed'),
            f'未沙盒化对照进程无法访问测试资源：{plain}')
    fixture = base / 'protected'
    fixture.mkdir()
    document = fixture/'document.txt'
    document.write_text('must remain unchanged')
    before = document.stat()

    def verify(entitlements, *args):
        subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(app)], check=True)
        checks = run_probe(binary_dir/'Probe', fixture, 'parent', *args)
        require(checks and all(checks.values()), f'沙盒策略不符合预期：{checks}')
        require(document.read_text() == 'must remain unchanged' and document.stat().st_mtime_ns == before.st_mtime_ns,
                '测试文档被修改')
        require(not (fixture/'new.txt').exists() and not (fixture/'moved.txt').exists(), '探针意外写入测试目录')

    verify(app_entitlements, 'deny-read')
    # Test-only narrowly scoped exception models read access without granting
    # writes. Production picker grants are exercised separately in the App.
    scoped = plistlib.loads(app_entitlements.read_bytes())
    scoped['com.apple.security.temporary-exception.files.absolute-path.read-only'] = [str(fixture) + '/']
    test_entitlements = base / 'ScopedTest.entitlements'
    test_entitlements.write_bytes(plistlib.dumps(scoped))
    verify(test_entitlements)
    print('PASS：发行权限拒绝读取未授权测试目录；模拟单目录只读授权后可读。两种情况下主进程及子进程均不能联网或写入文档。')
