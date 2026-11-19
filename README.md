# 浮光清单

原生 macOS 待办应用，使用 SwiftUI 和 WidgetKit。需要 macOS 26 或更新版本。

## 使用

1. 点按底部「添加」或按 ⌘N 打开新建窗口。也可以先在底部输入标题再按回车。添加时可以选择提醒时间并填写备注。
2. 点按任务前的圆圈完成任务。已完成的任务可以恢复。双击标题可以编辑标题、时间和备注，或通过右侧「⋯」菜单删除。
3. 点按主窗口右上角的「侧边贴合」，选择左侧或右侧。鼠标移入边缘标签时，会滑出毛玻璃待办清单，可以直接勾选完成。鼠标移开后清单自动收起。标签可沿屏幕边缘上下拖动，位置按显示器保存。右键标签可以换边、复位或打开主窗口。

主窗口左下角的「外观」可以选择「跟随系统」「日间」或「夜间」。应用会记住选择。

点按主窗口右上角的「设置」或按 ⌘,，在主窗口内打开设置。可以自定义时间、备注和侧边条的颜色，以及添加、编辑或移除最多 10 个快捷时间。「显示倒计时」控制主窗口、侧边清单和桌面小组件里的倒计时。可从「到期通知」单独授权系统通知。「版本与更新」显示版本和构建编号，也可以开启自动检查更新或手动检查。

新建和编辑待办时，从月历选择日期，将指针放在小时或分钟栏上滚动，也可直接输入数字。列表在标题下方同一行显示时间和备注。

设置里的「完成项」可以选择将完成项移到「已完成」，或在首页划线保留。首页完成项可以保留 1 天、7 天、30 天或一直保留，到期后仍可从「已完成」查看或恢复。

在桌面空白处点按右键，选择「编辑小组件」，搜索「浮光清单」，添加系统小组件。小组件显示时钟、事项时间、备注和事项倒计时，可以直接勾选待办。主窗口与小组件在本机共享待办数据和标签配色。系统单色外观会统一处理小组件颜色。

点按系统小组件右上角的外观图标，可依次切换「跟随系统」「日间」和「夜间」。不同尺寸各自记住选择。系统小组件的玻璃底由 macOS 渲染。

## 开发

用 Xcode 26 或更新版本打开 `GlassList.xcodeproj`，选择 `GlassList` 和 `My Mac` 后运行。工程默认以「Sign to Run Locally」构建。macOS 27.2 上的系统日志显示，这种签名缺少 App Intents 用来连接小组件扩展的团队标识。

### 给桌面小组件签名

1. 打开 Xcode 的 **Settings → Accounts** 并登录 Apple 账户。选择你的 Team，在 **Manage Certificates** 中确认有 **Apple Development** 证书，或点 **+ → Apple Development** 创建。普通账户可先使用 Xcode 显示的 **Personal Team**。 [Apple 证书设置说明](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates)
2. 打开工程，在 **Targets → GlassList** 和 **Targets → GlassListWidget → Signing & Capabilities** 里分别选择同一个 **Team**。打开 **Automatically manage signing**。如果 **Build Settings → Code Signing Identity** 仍显示 **Sign to Run Locally**，把用于本次构建的配置改成 **Apple Development**。
3. 两个 target 使用同一个 App Group。工程的 **Build Settings → GLASSLIST_APP_GROUP** 同时配置应用、小组件和签名权限。开发团队可以使用已有授权的 `group.com.tian.glasslist`。如果 Xcode 无法注册这个组，可以把该设置改成 `你的TeamID.com.tian.glasslist`，macOS 的团队编号前缀格式无需注册 App Group。更换前先备份旧组容器里的 `Tasks` 文件夹，之后再迁入新容器。 [Apple 的 macOS App Group 说明](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)
4. 用 `GlassList` scheme 重新构建应用。使用新签名的 app 替换原本的本地版本，再运行并重新添加桌面小组件。主应用和 `Contents/PlugIns/GlassListWidget.appex` 的 `codesign -dv` 输出应显示同一个 `TeamIdentifier`。

### 发布到 GitHub Releases

应用使用 Sparkle。给正式版提供 `GLASSLIST_UPDATE_PUBLIC_KEY`，值为用 Sparkle `generate_keys` 生成的 EdDSA 公钥，私钥保存在登录钥匙串。开发构建可以省略该值。首次发布之前，设置中的 GitHub 发布页链接可直接打开仓库的 Releases 页面。

发布时增加 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`，用同一 Apple 开发团队的 Developer ID Application 证书和 Hardened Runtime 签名主应用与小组件，再完成 Apple 公证。将公证并装订后的应用打包为 ZIP，再用 Sparkle `generate_appcast` 对最终归档生成签名更新源。归档 URL 使用该版本的 GitHub Releases 下载地址，更新源固定为最新正式 Release 的 `appcast.xml` 附件。先上传归档和更新源，再发布 Release。后续版本继续使用同一个 App Group 与 EdDSA 密钥。 [Sparkle 发布说明](https://sparkle-project.org/documentation/publishing/) · [Apple 公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

`App` 是主窗口，`Widget` 是 WidgetKit 扩展，`Shared` 包含本地存储和小组件的完成操作。
