# 更新日志

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循语义化版本。发布流程会把对应版本的一节作为 GitHub Release 说明。

## [0.1.0] - 2026-10-18

首个版本。

### 安装方式

本版本**只发布源码，不提供 App 安装包**：项目没有 Developer ID 签名，而 File Provider 扩展与钥匙串共享都依赖开发团队签名，未签名的构建无法正常运行。

请用自己的 Apple 账号从源码构建，需要 macOS 26、Xcode 27、Apple Silicon：

```bash
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # 填入自己的 DEVELOPMENT_TEAM（个人免费团队即可）
Scripts/bootstrap-mac.sh
```

### 功能

- Finder 集成：每个云盘作为 File Provider 域出现在 Finder 侧栏「位置」，按需下载、双向同步。
- 远端变更推送：App 订阅服务端 SSE，网页端改动约 5 秒出现在 Finder；推送中断时自动降级为定期全量核对。
- 本地变更：上传支持 10 种存储策略与断点续传；覆盖时检测服务端版本，冲突副本另存为 `__conflict__时间_原文件名` 并通知。
- 菜单栏弹窗：同步活动（正在同步 / 最近）、按云盘筛选、在 Finder 中定位，显示实时上传速度。
- 登录：OAuth2 + PKCE，复用服务端内置桌面端 client；凭证失效时通知并可一键重新登录。
- 设置：单云盘时显示概览（容量、分享、回收站、上次完整核对、用户组、存储策略、服务端版本）；每个云盘可配置忽略规则；登录时启动。
- 新添加的云盘若未在「系统设置 -> 通用 -> 登录项与扩展」中启用，弹窗会提示并提供跳转按钮。

### 已验证环境

- macOS 26 + Xcode 27.1，Apple Silicon。
- Cloudreve 4.19.1 与 [OpenCloudreve](https://github.com/Lynricsy/OpenCloudreve) 4.19.7（本地存储策略）。

### 已知问题

- 上游 Cloudreve 在网页端撤销某个 OAuth 应用授权后再重新授权，新令牌约一小时后无法刷新，客户端会持续提示「需要重新登录」。这是服务端缺陷（撤销为软删除，重新授权不会恢复该记录），OpenCloudreve 4.19.7 已修复，详见 [Lynricsy/OpenCloudreve#1](https://github.com/Lynricsy/OpenCloudreve/issues/1)。
- 其余限制见 README「已知限制」。
