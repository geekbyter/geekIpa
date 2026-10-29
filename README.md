# geekIpa

一款**无广告、无弹窗、无版本检测**的 iOS 端 IPA 签名与安装工具。全程在手机上完成：Apple ID 签名、证书签名、IPA 安装与续签提醒。界面按《IPA 签名管理工具 · UI 规格说明书》实现，主框架为三 Tab：**应用 / 证书 / 设备**。

> 致谢与许可：签名内核使用 [Zsign](https://github.com/zhlynn/zsign) 管线，Apple ID 认证栈来自 [AltSign](https://github.com/SideStore/AltSign)（SideStore 分支），UI 组件与部分工具扩展源自 [Feather](https://github.com/claration/feather)（© Samara M.）。本项目以 GPLv3 发布。

## 与上游版本的关键差异

| 方面 | 现状 |
|---|---|
| 服务器 | **自研 `LocalHTTPServer`**（Network.framework），移除 Vapor / NIO / NIOSSL / NIOTLS |
| 安装通道 | 仅局域网 **HTTP**（不再有 TLS / 证书 / 通道切换） |
| 设备识别 | 通过**配置描述文件**自动回传 UDID（不再需要配对文件） |
| 已移除依赖 | Vapor、Nuke、AltSourceKit、IDeviceSwift、NimbleJSON（远端仅剩 Zip、SWCompression） |
| 已移除入口 | 源商店、源浏览、配对文件、后台隧道、安装方式切换 |

## 功能清单

### 应用页（Tab 1，默认落地页）
- 两段分段控件：**已导入 / 已签名**，导航标题随段切换
- 常驻主操作「导入 IPA」（文件或 URL）
- 已导入：原始 IPA 只读；操作 = 签名 / 查看描述 / 导出 / 删除；支持多选批量删除与导出
- 已签名：倒序 + 去重；到期倒计时徽章（剩 3 天绿 / 剩 2 天橙 / 今天红）+ 一键续签；临期横幅
- 不提供「已安装」列表：枚举本机已安装应用需要私有 API 或配对通道，本项目已移除该能力，
  已安装应用请在系统桌面/设置中管理

### 签名流程
- 配置页：Bundle ID（正则校验）/ App 名 / 最低系统版本 / 移除跳转 / 移除插件 / 移除手表 / 文件访问 / 证书选择（未选时红色提示）
- 临时副本原则：顶部常驻「正在处理临时副本，原始文件不受影响」
- 高级区顺序：**签名选项 → 修改图标 → 移除插件 → 注入插件**；两项危险操作置于末尾并默认关闭
- 修改图标：相册选图 → 校验（正方形、边长 ≥120px）→ 居中裁切 1024×1024 写入签名参数
- 注入插件：danger 描边卡片 → 阻断式风险确认 → 吸顶警示条 + 主按钮变「注入并签名」
- 过程页：进度条（解析→校验→配置→注入/移除→重签名→打包）+ 百分比 + 内存日志区（等宽、级别着色、自动滚底、环形上限不落盘、退出即释放）
- 终态：安装 / 导出 / 完成；失败给错误摘要 + 重试 / 查看完整日志 / 关闭

### 证书页（Tab 2）
- 类型徽标：UDID 证书 / Apple ID 证书 / 企业证书
- 列表：名称、徽标、Team ID、序列号、有效期与剩余天数（≤30 天警示、过期禁用签名）
- 导入：类型选择 → 表单 → 解析校验（密码错误 / 已过期 / 无法解析 / UDID 不匹配逐项报因）
- 详情：证书（Subject / Issuer / SHA-1 / 绑定 UDID / entitlements 摘要）+ 描述文件信息
- 导出 P12；删除二次确认（被引用时提示 N 个应用在用）

### Apple ID 免费签名
- 登录：GSA + 双重认证验证码；凭据只发往苹果服务器，可选保存到 Keychain
- 自动流程：录入设备 UDID（设备页）→ 创建/复用开发证书 → 注册 App ID → 拉描述文件 → 一键签名
- 名额管理：App ID 占用（x/3）+ 删除闲置描述文件释放名额
- 续签：第 5 天本地通知 + 「立即续签」（拉新描述文件 → 重签 → 重新安装）

### 设备页（Tab 3）
- 顶部状态卡；设备信息（型号 / iOS 版本 / **UDID 录入与一键获取** / 架构）
- 开发者模式开启指引（公开 API 无法读取开关状态，故给引导而非假状态）
- 存储用量（>90% 警示色）
- 右上进入设置

### 设置页
仅四项：**关于 / 外观 / Apple ID 账号 / 诊断日志**（证书是底部 Tab，不重复放设置）。

### 安装管线
- 全程日志：打包 → HTTP 服务启动 → **链路自检**（先自拉清单）→ itms 触发 → 清单/包体传输 → 安装进度 → 完成
- 12 秒看门狗：系统没来取清单即报错并给排查建议（Wi-Fi / 本地网络权限 / 签名不匹配）
- 固定高度可滚动日志面板（可复制、可导出）；设置内有全屏诊断日志
- 需要连接 Wi-Fi（蜂窝网络下会提示先连 Wi-Fi）

### 界面规范
- 浅色 / 深色 / 跟随系统三态 + 主色调自定义（语义色 token 集中在 `GeekTheme`）
- iPhone 横竖屏 + iPad 全方向自适应；iOS 16.0+

## 目录结构

```
geekIpa/
  AppleID/          账号登录、证书注册、描述文件（AppleIDContracts 定义模块间协议）
  Backend/Storage/  Core Data（geekIpa.xcdatamodeld：CertificatePair / Imported / Signed）
  Backend/Server/   LocalHTTPServer（自研 HTTP）+ ServerInstaller（清单/包体/引导页）
  Install/          安装日志、UDID 描述文件服务、自检
  Renewal/          续签调度与名额管理
  Utilities/        签名、解包、证书解析、Mach-O 工具
  Views/            Apps / Certificates / Device / Settings / Signing
AltSign/            本地 Swift Package（Apple ID 协议栈）
Zsign/              本地 Swift Package（签名内核）
NimbleKit/          本地 Swift Package（NimbleViews / NimbleExtensions）
Scripts/            preflight.py（CI 门禁）、verify_git_tree.py（推送前自检）、verify_staged_tree.py（暂存树按 CI 视角校验）
```

## 构建（云端，无需 Mac）

1. 推到自己的 GitHub 仓库（`main` 或 `master` 分支自动触发，也可在 Actions 里手动 `workflow_dispatch`）
2. Actions → `Build geekIpa IPA` → 下载 Artifacts 里的 `geekIpa-ipa`
3. 本地有 Mac：`make iphoneos` → `packages/geekIpa.ipa`

CI 流程：`Verify repository tree` → `Preflight` → `Build` → 失败摘要 → 打包 IPA → 上传产物。

推送前建议本地先跑：

```bash
git add -A
python Scripts/verify_git_tree.py --index   # 确认提交里真的有新工程树
python Scripts/verify_staged_tree.py        # 把暂存树导出临时目录，按 CI 视角再跑一遍
python Scripts/preflight.py                 # 工作区门禁（结构/配置/模型/依赖）
```

> 注意：本项目目录经历过 `GeekSign → geekIpa` 重命名。若只用 `git commit -am`，新增目录不会入库，
> CI 会拿到「删了旧代码、没有新代码」的仓库。请使用 `git add -A`。

## 安装与首次使用

1. 用爱思或现有签名工具给 `geekIpa.ipa` 签名安装（有付费/企业证书优先用证书装，不占免费 Apple ID 的 3 个名额）
2. 打开 App → 设备页 → 录入 UDID（可点 UDID 一行用描述文件自动获取）
3. 证书页 → 导入证书（或用 Apple ID 登录自动生成）
4. 应用页 → 导入 IPA → 签名 → 安装（需与设备在同一 Wi-Fi）

## 路线图

| 版本 | 计划 | 状态 |
|---|---|---|
| v1.0 | 三 Tab / 签名流程 / 证书页 / 设备页 / 安装日志 / 续签提醒 | ✅ 当前 |
| v1.1 | 无感自动续签（后台重签重装，减少手动确认） | 规划中 |
| v1.2 | 停用/激活 App（释放名额）；导出 P12 时支持重设密码 | 规划中 |
| v1.3 | 已签名产物增加来源 App UUID（Core Data 轻量迁移） | 规划中 |

## 许可与致谢

- 本项目以 GPLv3 发布；UI 与工具扩展部分基于 Feather（© Samara M.）
- AltSign © Riley Testut / SideStore Team
- Zsign © zhlynn

本工具仅供学习交流，请遵守 Apple 开发者协议。
