# FileSight GitHub 发布检查清单

## 仓库与验证

- [x] `main` 包含 FileSight 2.3（build 30）源码
- [x] 中英文 README 功能、隐私边界与版本保持一致
- [x] GitHub Actions 自动执行搜索、SQLite/FSEvents、沙盒隐私与打包验证
- [x] `main` 要求通过 CI，禁止 force push 与删除
- [x] Secret scanning 与 push protection 已开启
- [x] GitHub Topics 已补充 macOS、Swift、本地搜索与隐私标签
- [x] Issue 模板提醒用户移除个人文件名和路径
- [x] `SECURITY.md` 与 Private Vulnerability Reporting 已配置
- [ ] 确定代码授权方式并增加 `LICENSE`

## v2.3 预览版

- [x] 构建版本与 Release 标签均为 `v2.3`
- [x] 发布 `FileSight.zip`
- [x] 发布 SHA-256 校验文件
- [x] Release 明确标注未经 Apple 公证的 Pre-release
- [x] 远端 `main`、tag、Release 资产与 README 下载链接已复核

## 后续正式分发

- [ ] 申请 Developer ID Application 证书
- [ ] 使用 Hardened Runtime 签名并完成 Apple notarization
- [ ] 从 Pre-release 升级为经公证的正式 Release
- [ ] 配置 tag/commit 签名，提升源码与发布产物的可验证性
