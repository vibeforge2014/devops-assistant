# VibeForge DevOps Assistant

VibeForge 旗下 8 个 Apple 客户端应用（包含 DevOps Assistant 自身）+ Pages 站点矩阵的**本地运维助手**。原生 macOS App,沉淀常用的构建、签名、公证、TestFlight/App Store 上传、发布页更新等运维操作。

## 收录的项目

**应用**(8):Tivon · Tellyra · ServerHub · ChargePilot · MinuteFlow · TuneSync · TailTalk · DevOps Assistant
**站点**(8):各 App 的发布页 + Portal 门户

## 功能模块

| 模块 | 能力 |
|------|------|
| **仪表盘总览** | 一屏概览所有应用(版本/路径状态)、站点(克隆状态)与最近发布 |
| **构建打包** | xcodegen + xcodebuild archive,内置导出 IPA / 签名打包 DMG |
| **签名与公证** | iOS:match / cert+sigh;macOS:Developer ID 签名 + notarytool 公证 |
| **TestFlight / App Store** | 全本地执行:项目上传脚本 → 本地 Fastlane → 内置 IPA + altool |
| **一键发布** | 向导式串联:设版本 → 构建 → 签名 → (公证) → 上传 → 联动更新 Portal |
| **发布预检** | 发布前检查路径/版本、Fastlane lane、Bundler、凭据、Git 状态与 Portal 映射 |
| **凭证有效性** | 只读验证 ASC Apple 认证、本机分发证书、Match 仓库与解密密码,失败时引导补录 |
| **发布页更新** | 批量 git pull → 编辑 → push,触发 Pages 自动部署 |

## 官网部署

DevOps Assistant 发布页使用 Cloudflare Pages 托管，静态输出目录为 `docs/`，地址为 [devops-assistant.pages.dev](https://devops-assistant.pages.dev/)。产品门户 `portal` 使用生产域名 [norelle.cc](https://norelle.cc/)。

```bash
npx wrangler pages deploy docs --project-name devops-assistant --branch main
```
| **发布历史** | 记录每次发布的版本/目标/结果,按应用筛选追溯(本地存储) |
| **动态项目管理** | 在应用内新增、编辑、删除应用与站点，支持切换本地目录和完整 GitHub URL |

## 凭据管理

所有凭据集中存入 **macOS 钥匙串**(`com.vibeforge.devops-assistant`):
- App Store Connect API Key(.p8 内容 + Key ID + Issuer ID)
- Match 仓库密码 / 地址
- Apple Team ID

首次使用前在 **设置 → 凭据** 中填入并点击“验证全部”。支持直接导入 `AuthKey_*.p8`;临时密钥文件权限为 `0600`,进程结束后自动删除。

## 构建

```bash
# 1. 生成 Xcode 工程
xcodegen generate

# 2. 用 Xcode 打开,或命令行构建
open DevOpsAssistant.xcodeproj
# 或
xcodebuild -project DevOpsAssistant.xcodeproj -scheme DevOpsAssistant -configuration Debug build

# 运行单元测试
xcodebuild test -project DevOpsAssistant.xcodeproj -scheme DevOpsAssistant -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

## 发布能力说明

- TestFlight 始终在本机执行,不会推 tag 或触发 GitHub Actions;有上传脚本时优先调用脚本。
- 没有脚本时使用本地 Fastlane beta lane;没有 lane 时由助手内置导出 IPA 并通过 altool 上传。
- macOS Developer ID 项目走签名 → ZIP → notarytool → staple → validate。
- native iOS 项目也可使用内置 TestFlight 兜底,项目详情提供独立“打包 IPA / DMG”入口。
- 发布前必须通过预检;Git 未提交修改作为警告展示,缺失凭据/lane/依赖会阻止启动。

## 配置项目

在侧栏打开 **项目管理**，可维护应用与站点的本地目录、完整 GitHub SSH/HTTPS URL，以及构建、签名和部署参数。首次启动会从 `Resources/projects.json` 导入默认项目，之后配置保存在：

`~/Library/Application Support/com.vibeforge.devops-assistant/projects.json`

修改已有本地仓库的 URL 时，助手会检测 `origin` 并询问是否同步。删除项目只会移出管理清单，不会删除本地文件、发布历史或钥匙串凭据。

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
├── Models/       # Project / Credential / ReleaseStep / ReleaseRecord 数据模型
├── Services/     # ShellRunner / KeychainStore / VersionManager / FastlaneRunner
│                  BuildService / NotaryService / PagesDeployer / PortalSync
│                  ReleaseCoordinator / HistoryStore / OnboardingService
└── Views/        # Sidebar / ContentView / ProjectDetail / ConsolePanel
                   DashboardView / HistoryView / VersionEditor / ReleaseFlow
                   Settings / PagesManager / SiteDetail
Resources/
├── projects.json       # 项目矩阵描述符
└── scripts/            # codesign-mac.sh / notarize.sh(改编自 openclaw)
```
