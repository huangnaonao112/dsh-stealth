# dsh-stealth — DeepSeek Harness 隐身模式插件

在 DeepSeek Harness 的 **设置 → 隐身模式** 里放一个总开关：**窗口保持正常可用**，
只隐藏外部痕迹——任务栏按钮、Alt-Tab 项、托盘角标。全部通过 Win32 API 操作
DSH 自己的窗口，**不注入任何其他进程**。

## 功能

设置 → 隐身模式 → 「隐藏任务栏图标与托盘角标」开关：

| 状态 | 效果 |
|---|---|
| 开 | 任务栏按钮和 Alt-Tab 项立即消失（WS_EX_TOOLWINDOW）；窗口照常使用 |
| 关 | 全部恢复显示 |

- 开关状态跨重启保持：应用启动后约 10 秒内自动重新应用。
- 不隐藏窗口、不派生任何附属后台进程。
- 任务管理器里的 `DeepSeek Harness` 后台进程行是系统账本，不注入 taskmgr 就无法
  隐藏，这是刻意为之的边界。

## 安装

### 方式一：应用内安装（推荐）

DeepSeek Harness → 插件 → 添加插件 → 输入包名：

```
dsh-stealth
```

（要求插件已发布到 npm，见下方「发布状态」。）

### 方式二：命令行（GitHub，无需 npm 发布）

```powershell
dsh plugin --profile desktop add github:huangnaonao112/dsh-stealth
```

### 方式三：本地 link（开发者）

1. 克隆本仓库到任意目录。
2. 在 `%USERPROFILE%\.dsh\profiles\desktop\node_modules\` 下建 junction：

   ```powershell
   New-Item -ItemType Junction -Path "<profile>\node_modules\dsh-stealth" -Target "<本仓库目录>"
   ```

3. profile `package.json` 的 `dependencies` 加
   `"dsh-stealth": "link:<本仓库目录绝对路径>"`，`pnpm-lock.yaml` 的 importers
   同步加条目，`dsh.profile.bundles` 数组加 `"dsh-stealth"`。
4. 重启 DeepSeek Harness。

## 托盘角标（可选的手动 tweak）

托盘图标条目无法从外部摘除（那需要注入 explorer/应用进程）。本插件作者另行把
DSH 安装目录的 `resources\tray.ico` 替换成了全透明图标，使溢出区里的位置变成
空白；原件备份为 `tray.ico.bak-20261121`。应用自动更新可能还原该文件，需要时
重新覆盖一次即可。此改动不属于插件本身，是否跟随自便。

## 文件

- `scripts/stealth.ps1` — Win32 核心（枚举顶层窗口 / ShowWindow / WS_EX_TOOLWINDOW + 状态文件）
- `index.js` — Host 半：单路由 `/api/dsh-stealth`（`?op=state|toggle`）+ 开机重新应用
- `client.js` — Client 半：设置页「隐身模式」分区卡片 + 开关（`settings.section` / `settings.section.icon` 插槽）

## 状态文件

`~/.dsh/dsh-stealth.state`（key=value 文本）：主标志为 `toolwindow`（0/1），
`styles` 记录被改动窗口的原 exstyle 用于还原。删除该文件即回到默认全显状态。

## 许可

MIT
