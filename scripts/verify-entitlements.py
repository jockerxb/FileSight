from pathlib import Path
import plistlib, subprocess, sys

root = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1]) if len(sys.argv) > 1 else root/'dist/千里眼.app'
expected_app = {
    'com.apple.security.app-sandbox': True,
    'com.apple.security.files.user-selected.read-only': True,
    'com.apple.security.temporary-exception.files.absolute-path.read-only': ['/'],
}
expected_worker = {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True}
for binary, expected in [(app,expected_app),(app/'Contents/MacOS/ScanWorker',expected_worker)]:
    result = subprocess.run(['codesign','-d','--entitlements',':-',str(binary)],capture_output=True,check=True)
    actual = plistlib.loads(result.stdout)
    assert actual == expected, f'不符合离线只读权限配置：{binary}: {actual}'
assert {p.name for p in (app/'Contents/MacOS').iterdir()} == {'QianLiYan','ScanWorker'}, '发布包包含非预期程序'
print('PASS：发布包只含主程序与扫描 helper；系统权限严格限定为离线、文档只读。')
