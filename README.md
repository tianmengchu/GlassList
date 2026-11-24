# 一个完美的todolist

原生 macOS 待办应用，使用 SwiftUI 和 WidgetKit。需要 macOS 26 或更新版本。

## 使用

1. 点按底部「添加」或按 ⌘N 打开新建窗口。也可以先在底部输入标题再按回车。添加时可以选择提醒时间并填写备注。
2. 点按任务前的圆圈完成任务。已完成的任务可以恢复。双击标题可以编辑标题、时间和备注，或通过右侧「⋯」菜单删除。
3. 点按主窗口右上角的「侧边贴合」，选择左侧或右侧。鼠标移入边缘标签时，会滑出毛玻璃待办清单，可以直接勾选完成。点按底部「添加」，或输入标题后按回车，即可在侧边填写待办。日期默认是「今天」。点按日期换日，点按「不设时间」可填写时间，也可从「快捷」直接选用预设。标签可沿屏幕边缘上下拖动，右键标签可以换边、复位或打开主窗口。
4. 主窗口和侧边清单按日期分组。侧边默认显示今天和未安排日期。点按右上角「添加日期」可勾选多天，也可用「明天」「本周」和「本月」快速添加。月历红点表示当天已有待办。取消勾选或点按日期旁的叉号可移除显示分组。点按日期标题可展开或折叠。主窗口左栏列出日期，点按可跳到对应组，也可把待办直接拖到左栏或清单中的目标组。改期会保留原有提醒的时刻。主窗口可用「选择日期…」显示尚无待办的一天。拖到「未安排日期」会清除日期和提醒。

主窗口左下角的「外观」可以选择「跟随系统」「日间」或「夜间」。应用会记住选择。

在「设置 → 配色」里可以预览并切换主题。日间和夜间可分别调整窗口背景、导航栏、卡片和输入框、文字与强调色。「恢复默认主题」会恢复两套配色。侧边清单右上角的回转箭头会把日期分组恢复为「今天」和「未安排日期」。

关闭主窗口后，一个完美的todolist留在顶部菜单栏。点菜单栏的勾选方框图标，即可打开清单或完全退出。

在设置的「启动」里，可以分别开启「登录时启动」和「启动时自动贴边」。自动贴边沿用上次选择的方向，首次默认右侧。

点按主窗口右上角的「设置」或按 ⌘,，在主窗口内打开设置。可以自定义时间、备注和侧边条的颜色，以及添加、编辑或移除最多 10 个快捷时间。「显示倒计时」控制主窗口、侧边清单和桌面小组件里的倒计时。可从「到期通知」单独授权系统通知。「版本与更新」显示版本和构建编号，也可以开启自动检查更新或手动检查。

新建和编辑待办时，从月历选择日期。打开「提醒」后，将指针放在小时或分钟栏上滚动，也可直接输入数字。只安排日期的待办也会进入对应分组。列表在标题下方同一行显示日期或时间和备注。

设置里的「完成项」可以选择将完成项移到「已完成」，或在首页划线保留。首页完成项可以保留 1 天、7 天、30 天或一直保留，到期后仍可从「已完成」查看或恢复。

在桌面空白处点按右键，选择「编辑小组件」，搜索「一个完美的todolist」，添加系统小组件。小组件显示时钟、事项时间、备注和事项倒计时，可以直接勾选待办。主窗口与小组件在本机共享待办数据和标签配色。系统单色外观会统一处理小组件颜色。

点按系统小组件右上角的外观图标，可依次切换「跟随系统」「日间」和「夜间」。不同尺寸各自记住选择。系统小组件的玻璃底由 macOS 渲染。

## 开发

用 Xcode 26 或更新版本打开 `GlassList.xcodeproj`，选择 `GlassList` 和 `My Mac` 后运行。工程默认以「Sign to Run Locally」构建。macOS 27.2 上的系统日志显示，这种签名缺少 App Intents 用来连接小组件扩展的团队标识。

### 给桌面小组件签名

1. 打开 Xcode 的 **Settings → Accounts** 并登录 Apple 账户。选择你的 Team，在 **Manage Certificates** 中确认有 **Apple Development** 证书，或点 **+ → Apple Development** 创建。普通账户可先使用 Xcode 显示的 **Personal Team**。 [Apple 证书设置说明](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates)
2. 打开工程，在 **Targets → GlassList** 和 **Targets → GlassListWidget → Signing & Capabilities** 里分别选择同一个 **Team**。打开 **Automatically manage signing**。如果 **Build Settings → Code Signing Identity** 仍显示 **Sign to Run Locally**，把用于本次构建的配置改成 **Apple Development**。
3. 两个 target 使用同一个 App Group。工程的 **Build Settings → GLASSLIST_APP_GROUP** 同时配置应用、小组件和签名权限。开发团队可以使用已有授权的 `group.com.tian.glasslist`。如果 Xcode 无法注册这个组，可以把该设置改成 `你的TeamID.com.tian.glasslist`，macOS 的团队编号前缀格式无需注册 App Group。更换前先备份旧组容器里的 `Tasks` 文件夹，之后再迁入新容器。 [Apple 的 macOS App Group 说明](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)
4. 用 `GlassList` scheme 重新构建应用。使用新签名的 app 替换原本的本地版本，再运行并重新添加桌面小组件。主应用和 `Contents/PlugIns/GlassListWidget.appex` 的 `codesign -dv` 输出应显示同一个 `TeamIdentifier`。

### 发布到 GitHub Releases

应用查询 GitHub 仓库的最新正式 Release。打开「自动检查更新」后，应用会在启动时和运行期间每天检查一次。发现新版后，可在设置或菜单栏点击安装包直链，由默认浏览器下载，再手动安装。 [GitHub Releases API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)

发布时更新 `MARKETING_VERSION` 和 `CURRENT_PROJECT_VERSION`。用 `v3.0.0` 这类纯数字版本标签发布，并将对应的 `GlassList-3.0.0-universal.dmg` 或 `GlassList-3.0.0-universal.zip` 作为 Release 附件上传。macOS 安装权限由系统按应用的签名和公证状态处理。 [Apple 分发签名说明](https://developer.apple.com/developer-id/)

`App` 是主窗口，`Widget` 是 WidgetKit 扩展，`Shared` 包含本地存储和小组件的完成操作。
