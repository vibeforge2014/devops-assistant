# VibeForge DevOps Assistant

VibeForge 旗下 7 个 Apple 客户端应用 + GitHub Pages 站点矩阵的**本地运维助手**。原生 macOS App,沉淀常用的构建、签名、公证、TestFlight/App Store 上传、发布页更新等运维操作。

## 收录的项目

**应用**(7):Tivon · Tellyra · ServerHub · ChargePilot · MinuteFlow · TuneSync · TailTalk
**站点**(8):各 App 的发布页 + Portal 门户

## 功能模块

| 模块 | 能力 |
|------|------|
| **构建打包** | xcodegen 生成工程 + xcodebuild archive,管理版本号/Build 号 |
| **签名与公证** | iOS:match / cert+sigh;macOS:Developer ID 签名 + notarytool 公证 |
| **TestFlight / App Store** | 封装 fastlane beta/release lane,注入 ASC API Key |
| **发布页更新** | 批量 git pull → 编辑 → push,触发 GitHub Pages 自动部署;联动 Portal |

## 凭据管理

所有凭据集中存入 **macOS 钥匙串**(`com.vibeforge.devops-assistant`):
- App Store Connect API Key(.p8 内容 + Key ID + Issuer ID)
- Match 仓库密码 / 地址
- Apple Team ID

首次使用前在 **设置 → 凭据** 中填入。运行时从钥匙串读取并注入进程环境变量,不落盘。

## 构建

```bash
# 1. 生成 Xcode 工程
xcodegen generate

# 2. 用 Xcode 打开,或命令行构建
open DevOpsAssistant.xcodeproj
# 或
xcodebuild -project DevOpsAssistant.xcodeproj -scheme DevOpsAssistant -configuration Debug build
```

## 配置项目

编辑 `Resources/projects.json`,声明每个项目的路径、平台、scheme、bundle id、签名机制、版本号来源。详见该文件的注释。

## 技术栈

- **SwiftUI macOS App**(macOS 14+)
- **XcodeGen**(project.yml 管理工程)
- **进程调度**:`Process` + `Pipe` 流式捕获输出
- **凭据**:Keychain Services(`Security.framework`)
- 封装现有 fastlane / openclaw 脚本,不重造轮子

## 项目结构

```
Sources/
├── App/          # @main 入口 + 菜单
├── Models/       # Project / Credential / ReleaseStep 数据模型
├── Services/     # ShellRunner / KeychainStore / VersionManager / FastlaneRunner
│                  BuildService / NotaryService / PagesDeployer / PortalSync
└── Views/        # Sidebar / ProjectDetail / ConsolePanel / VersionEditor
                   Settings / PagesManager / SiteDetail
Resources/
├── projects.json       # 项目矩阵描述符
└── scripts/            # codesign-mac.sh / notarize.sh(改编自 openclaw)
```
