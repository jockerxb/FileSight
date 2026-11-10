# 千里眼 2.1：本地搜索与文档安全

千里眼搜索本机 App 和文件名。它读取 App 名称、图标、路径，以及文件类型、创建时间、修改时间等元数据，不读取文档正文。

- 没有账号、服务器、云端搜索、AI API、上传、遥测、广告 SDK 或自动更新。
- 主程序启用 macOS App Sandbox，不授予网络客户端或服务端权限；扫描 helper 继承相同限制。
- 没有全盘读取例外。搜索外部文档目录前，须在系统目录选择器中授予只读访问。macOS 的 security-scoped bookmark 保存在 App 沙盒内，用于在后续启动恢复同一目录的只读授权；用户可在设置中取消。
- 不提供删除、编辑、移动、重命名、批量处理或直接打开文档的功能。文件结果的回车或双击仅定位 Finder；App 结果只通过 macOS 启动对应的本机应用，另提供用户主动触发的复制路径。
- 文件名、路径、文件类型、创建/修改时间以及派生的拼音和短词候选索引保存在 App Sandbox 的本地 SQLite 数据库中，权限限制为当前用户读写。数据库不保存文档正文或搜索词；取消目录授权会清除对应的本地索引。UserDefaults 仅保存目录只读 bookmark、快捷键组合与外观设置。快捷键录入只接收录入窗口中的按键，不启用全局输入监控。登录启动由 macOS 登录项管理，只在用户操作开关时修改。点击 GitHub 链接只交给默认浏览器打开固定项目网址，不传递搜索内容。macOS 自身仍可能记录目录选择器状态、容器配置和系统缓存。
- 不扫描 NAS、SMB 等非本地卷，也不跨挂载点或跟随符号链接。未下载的云端目录仅保留可见名称并说明内部不可搜索，不请求下载。
- App Sandbox 允许应用写自己的容器和系统许可的临时区域，以维持系统框架运行；文档只读约束针对外部用户文档。千里眼没有文档写入代码。Finder、系统剪贴板、系统诊断及用户另行打开的其他 App 由 macOS 和各自设置控制。

系统文件权限仍然适用：没有访问权的目录会明确提示，不能以安全为由声称已经搜索到全部文件。

## 验证证据

`python3 scripts/verify-privacy.py` 使用一次性文档和本机回环端口测试，不连接互联网：

1. 无 App Sandbox 的对照进程能读取、写入测试文件并连接本机监听端口，排除宿主限制导致假阳性。
2. 与交付包相同权限的主进程和继承权限的子进程均不能读取未授权测试文档。用仅限测试目录的只读授权模拟后，两个进程均能读取该测试文档。
3. 两个进程的联网、覆盖、新建、重命名和删除均被系统以 EPERM 拒绝。
4. 测试文档内容、修改时间均保持不变。

`python3 scripts/verify-entitlements.py` 核对发布包实际签名，拒绝新增网络权限、文档写入权限或非预期可执行文件。每次构建 App 自动执行此检查。

安装版原生界面用合成目录实测：授权前不扫描；授权后范围内的测试文件可查，同级未授权目录的测试文件不出现；新增、改名及删除无需手动刷新。

权限设计依据：[Apple App Sandbox 权限说明](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)、[用户选择文件的访问机制](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)。系统限制和实测结果是防护证据，不能替代对整个 macOS 或其他 App 的安全保证。
