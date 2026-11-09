from pathlib import Path
import plistlib, subprocess, sys

root = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1]) if len(sys.argv) > 1 else root/'dist/千里眼.app'
expected_app = {
    'com.apple.security.app-sandbox': True,
    'com.apple.security.files.bookmarks.app-scope': True,
    'com.apple.security.files.user-selected.read-only': True,
}
expected_worker = {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True}
for binary, expected in [(app,expected_app),(app/'Contents/MacOS/ScanWorker',expected_worker)]:
    result = subprocess.run(['codesign','-d','--entitlements',':-',str(binary)],capture_output=True,check=True)
    actual = plistlib.loads(result.stdout)
    if actual != expected:
        raise SystemExit(f'不符合离线只读权限配置：{binary}: {actual}')
allowed = {
    'Contents/Info.plist', 'Contents/MacOS/QianLiYan', 'Contents/MacOS/ScanWorker',
    'Contents/Resources/QianLiYan.icns', 'Contents/_CodeSignature/CodeResources',
}
contents = list(app.rglob('*'))
actual_files = {p.relative_to(app).as_posix() for p in contents if p.is_file()}
allowed_directories = {str(parent) for item in allowed for parent in Path(item).parents if str(parent) != '.'}
actual_directories = {p.relative_to(app).as_posix() for p in contents if p.is_dir()}
if (actual_files != allowed or actual_directories != allowed_directories
        or any(p.is_symlink() or not (p.is_file() or p.is_dir()) for p in contents)):
    raise SystemExit(f'发布包目录不符合清单：额外 {actual_files - allowed}；缺失 {allowed - actual_files}')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print('PASS：发布包文件清单、签名、无网络及用户授权目录只读权限均通过。')
