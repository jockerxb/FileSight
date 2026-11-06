# 千里眼 2.0：本地搜索与文档安全

千里眼按文件名搜索并展示路径，读取类型、创建时间、修改时间等元数据，不读取文档正文。

- 没有账号、服务器、云端搜索、AI API、上传、遥测、广告 SDK 或自动更新。
- 主程序启用 macOS App Sandbox，不授予网络客户端或服务端权限；扫描 helper 继承相同限制。
- 为支持全机文件名搜索，文件系统例外只授予读取；用户选择目录也仅申请只读权限。没有文档读写授权。
- 不提供删除、编辑、移动、重命名、批量处理、直接打开文档或执行搜索结果的功能。回车或双击仅定位 Finder，另提供用户主动触发的复制路径。
- 文件名索引、搜索词、当前范围、错误详情都仅在进程内存中使用，应用代码不保存这些内容或搜索历史。仅将用户保存的快捷键组合与外观设置保存在 UserDefaults，不保存目录设置。快捷键录入只接收设置窗口中的按键，不启用全局输入监控。macOS 自身仍可能记录目录选择器状态、容器配置和系统缓存。
- 不扫描 NAS、SMB 等非本地卷。未下载的云端目录仅保留可见名称并说明内部不可搜索，不请求下载。
- App Sandbox 允许应用写自己的容器和系统许可的临时区域，以维持系统框架运行；文档只读约束针对外部用户文档。千里眼没有文档写入代码。Finder、系统剪贴板、系统诊断及用户另行打开的其他 App 由 macOS 和各自设置控制。

系统文件权限仍然适用：没有访问权的目录会明确提示，不能以安全为由声称已经搜索到全部文件。

## 验证证据

`python3 scripts/verify-privacy.py` 使用一次性文档和本机回环端口测试，不连接互联网：

1. 无 App Sandbox 的对照进程能读取、写入测试文件并连接本机监听端口，排除宿主限制导致假阳性。
2. 与交付包相同权限的主进程和继承权限的子进程均能读取测试文件。
3. 两个进程的联网、覆盖、新建、重命名和删除均被系统以 EPERM 拒绝。
4. 测试文档内容、修改时间均保持不变。

`python3 scripts/verify-entitlements.py` 核对发布包实际签名，拒绝新增网络权限、文档写入权限或非预期可执行文件。每次构建 App 自动执行此检查。

安装版原生界面也已实测：搜索三个跨目录匹配项、切换时间和类型排序成功；菜单仅含定位 Finder、复制路径；扫描前后受控文档内容及修改时间不变。

权限设计依据：[Apple App Sandbox 权限说明](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html)、[只读文件系统例外](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)。系统限制和实测结果是防护证据，不能替代对整个 macOS 或其他 App 的安全保证。
