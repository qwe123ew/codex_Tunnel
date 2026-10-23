# Codex SSH 代理隧道：Windows 便携启动包

适用：在 Windows 上使用 VS Code Remote - SSH 连接 Linux 服务器；服务器不能直接访问外网，需要通过当前电脑的 HTTP/Mixed 代理使用官方 Codex 扩展。

## 图形界面版 v2.4（推荐）

复制 **CodexTunnel-v2.4.exe**（压缩包内名为 **CodexTunnel.exe**）到另一台 Windows 电脑即可使用；Windows 上不需要旁边的脚本、Python 或 Node。双击后显示灰白与浅蓝的简约中文窗口，本机代理与远端隧道状态分开展示。

新版按钮分为浅蓝主操作、细描边次操作和轻量辅助操作，统一线条图标，并有悬停、按下、禁用和键盘焦点样式。运行方式与 v2.0 相同；旧版文件仍可保留。

软件图标为浅蓝底的双链环，已嵌入 EXE、窗口标题栏与页面标题，包含九种 Windows 图标尺寸。

1. 先打开当前电脑的代理软件，启用 HTTP / Mixed 端口。
2. 双击 **CodexTunnel-v2.4.exe**（压缩包内为 **CodexTunnel.exe**）。程序自动读取自己的已保存服务器和本机支持的 SSH 配置，并在下拉框标明来源。若 VS Code 指定了 SSH 客户端，优先显示相应来源。
3. 新电脑没有配置时，直接点击 **启动连接**，软件会打开带填写说明的服务器表单；点击 **保存并连接** 后继续启动。也可通过 **添加服务器** 只保存资料。已有配置未自动发现时，点击 **选择文件**；修改外部配置后点击 **刷新**。
4. 点击 **检测代理**，查看本机代理地址和 HTTPS 检测结果。也可以直接点击 **启动连接**，启动时会自动检测。
5. 点击 **启动连接** 后，在新打开的 **Codex SSH 身份验证与连接** 窗口输入密码、验证码或确认主机指纹。程序不代填或保存密码；认证窗口要保持打开。
6. 等待图形窗口显示 **远端代理已就绪**。在 VS Code 用 Remote - SSH 连接同一服务器和同一账号，然后在本软件点击 **一键配置 VS Code**；需要时在另一个 SSH 窗口完成认证。配置完成后，在 VS Code 按 `Ctrl+Shift+P` 执行 **Developer: Reload Window**，安装远端 Codex 扩展并登录。点击 **停止** 关闭本次隧道；关闭图形窗口也会结束它管理的进程。

**高级设置** 默认收起：远端代理端口为 `11082`（范围 1024–65535），本机代理端口留空自动检测，也可填写自己的 HTTP / Mixed 端口。服务器或端口被其他隧道占用时，停止自己的旧连接或换一个远端端口，并相应调整服务器侧代理地址。

| 界面结果 | 含义 |
|---|---|
| 本机代理 HTTP 401 / 2xx | 连续两次目标 HTTPS 请求通过；401 表示未携带账号凭据，不能据此判断已登录 |
| 正在建立连接 | SSH 认证或远端检查尚未完成 |
| 远端代理已就绪 | 服务器已通过隧道收到目标 HTTPS 的 401 / 2xx 响应 |
| 连接需要检查 | 服务器实际检测失败，隧道保留并继续检查 |
| 远端状态未验证 | 缺少服务器 curl 或远端心跳超时；不继续显示绿色成功 |
| 连接失败 / 已停止 | 查看提示，调整后可重新启动 |

界面显示最近一次远端验证成功的本地时间。远端默认每 60 秒检测一次；超过检测间隔加 45 秒仍未收到新检测结果时，状态转为未验证。代理检测有总超时限制，后台工作不占用界面线程；重复点击不会创建第二个隧道。

图形版的服务器列表保存在 `%LOCALAPPDATA%\CodexProxyTunnel\servers.json`，本次启动的连接快照保存在同目录 `gui-profile.json`。它们与控制台版的 `settings.json` 分开。程序不修改本地 Codex、全局 SSH、系统代理或本地 VS Code 设置；只有点击 **一键配置 VS Code** 才会更新远端代理设置。正常 SSH 登录仍可能按 OpenSSH 的通常行为记录已确认的主机指纹。复制给其他人时只复制 EXE，不带 AppData 中的个人文件。

### 一键配置 VS Code

按钮只修改当前所选服务器账号的 VS Code **远程设置**：`http.proxy` 使用软件当前远端端口，`http.useLocalProxyConfiguration` 设为 `false`。已有其他选项、注释和尾随逗号保留；修改前在远端同目录备份原文件。重复点击且值未变时不重写文件。

配置使用独立 SSH 会话，可能再次要求密码或验证码；不会重新绑定代理端口，也不会停止正在运行的隧道。界面支持取消，等待认证超过 5 分钟会退出。中途断线或取消时，应再次点击确认结果，不能仅凭取消推断远端尚未完成写入。

先用 VS Code Remote - SSH 成功连接一次，使服务器上已有 VS Code Server。配置工具复用其 Node 运行时，不下载或安装依赖。没有找到安装、远端权限不足、设置语法错误或存在不安全文件链接时，会给出原因而保留原设置。配置成功只代表设置已保存；还需保持隧道运行、重新加载 VS Code，并按扩展界面完成登录。详细步骤、检测范围与恢复方式见 `VSCode-快速配置.md`。

### 添加和编辑服务器

1. 点击 **添加服务器**，填写便于识别的名称、实际 IP/域名、服务器用户名和 SSH 端口（默认 22）。
2. 使用密钥登录时可选择私钥文件；密码登录时留空，启动连接后再在 SSH 窗口输入密码或验证码。
3. 没有跳板机时不添加；有跳板机时按实际连接顺序添加，最多四台。每台分别填写地址、用户名、端口，可指定各自的密钥路径。
4. 点击 **保存服务器**。服务器会出现在下拉框，标记为软件保存，并自动选中。以后重新打开软件仍可选择它。
5. 需要改动时选中软件保存的服务器，点击 **编辑**。编辑不会改动从本机读取的 SSH 配置。

服务器列表仅记录名称、连接参数和密钥文件路径，不保存密码、验证码或私钥内容。地址填写 `gpu.example.org` 或 IP，不填写完整的 `ssh user@host` 命令。表单会提示无效字段；保存失败时保留已输入内容。

### 自动读取的范围

- 默认读取 `%USERPROFILE%\.ssh\config` 及其支持的 `Include` 文件。
- 检查 VS Code 和 Code Insiders 默认用户设置文件中的 `remote.SSH.configFile` 和 `remote.SSH.path`，自动采用其指定的配置和 SSH 客户端。支持设置文件中的注释和尾随逗号；只设置客户端而未设置配置路径时，仍读取默认 SSH 配置。
- 相同配置与相同客户端的组合只读取一次；不同来源或客户端中同名的 SSH 别名保留各自来源，按对应文件和客户端解析。无效的显式客户端路径会显示提示。
- 软件保存的服务器和自动读取的服务器合并展示；一个外部配置缺失或不支持，不会使其他来源的服务器消失。
- 未在上述位置发现的配置，可通过 **选择文件** 指定。这不是对所有终端软件会话、SSH 密钥或局域网主机的扫描。

GUI v2.3 使用原生 SSH 配置模式：让本机 SSH 解析地址、用户名和端口，并保留原有认证选项、多个密钥、`ProxyJump` 和 `ProxyCommand`。不再因为这些选项无法放入简化表单而清空主机信息。没有指定客户端时，会尝试本机 Windows、PATH 和常见 Git OpenSSH 客户端；实际使用的路径显示在日志中。源配置及 Include 被复制为本次连接的独立临时文件，只移除原端口转发、会话命令和连接复用等与本次隧道冲突的设置，不修改原文件。

配置列表与解析均不登录服务器。`ProxyCommand` 在用户点击启动后按原 SSH 设置运行，原认证、密钥与主机校验仍由 SSH 处理；缺少某把候选密钥不会阻止显示地址，但实际认证仍需要可用凭据。程序对配置及 Include 设有大小/深度上限，并继续拒绝会在解析阶段执行命令的 `Match exec` 和网络共享配置路径。特殊配置会提示具体原因，不能保证每种第三方 SSH 客户端配置都兼容。相对密钥和命令路径以当前用户主目录为工作目录。

没有现成 SSH 配置时，**启动连接** 会弹出引导，也可直接使用 **添加服务器**。手动保存的条目与脚本/控制台版继续使用原来的简化配置规则。GUI 的 **帮助** 包含 VS Code 设置步骤，保留 **复制远程设置 JSON** 供特殊安装排查；常规使用点击 **一键配置 VS Code** 即可。另见 `VSCode-快速配置.md`。

运行要求：Windows 10/11、.NET Framework 4.8、Windows PowerShell 5.1、OpenSSH 客户端和 curl。缺少组件时提示错误，不自动下载安装。当前 EXE 未做商业代码签名，请遵循所在电脑的应用运行策略。

源代码位于 `gui/`，设计稿及完整颜色、布局和按钮说明见 `gui/design.md`。构建命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\gui\Build-Gui.ps1
```

构建输出 `dist\gui\CodexTunnel.exe`。源码包内的 `gui/assets/design-concept-v2.1.png` 是灰白浅蓝主界面设计参考，`gui/assets/add-server-concept-v2.2.png` 是添加窗口设计参考。界面预览使用实际 WPF 控件与明确的示例数据；设计稿和预览均不是成功登录某台服务器的证据。

## 控制台单文件 EXE 版

只需复制 **CodexProxyTunnel.exe** 到另一台 Windows 电脑，双击运行，无需复制旁边的脚本文件。程序采用中文控制台菜单，SSH 密码、验证码和主机指纹提示直接显示在同一个窗口中。

1. 打开当前电脑的代理软件。
2. 双击 **CodexProxyTunnel.exe**，选择 **2** 配置服务器；输入本机 SSH 服务器列表中的编号，按回车保留默认代理入口 `11082`。
3. 回到主菜单选择 **1** 启动隧道。程序自动查找代理，并按正常 SSH 流程提示认证。
4. 看到 `TUNNEL_READY` 后保持窗口打开，在 VS Code 远程服务器中使用 Codex。

| 菜单项 | 用途 |
|---|---|
| 1 | 启动隧道；尚未配置时自动进入配置向导 |
| 2 | 选择或更换服务器，支持从本机 SSH 配置导入 |
| 3 | 仅检测当前电脑代理，不连接服务器 |
| 4 | 显示地址、用户名、端口、跳板机的手动查询命令 |
| 5 | 只列出本机已有的 SSH 服务器别名 |
| 0 | 退出 |

EXE 的连接设置默认保存在 **`%LOCALAPPDATA%\CodexProxyTunnel\settings.json`**，与本地 Codex 和原 SSH 配置分开。复制 EXE 到新电脑后重新选择那台电脑已有的服务器。原脚本版的 `settings.json` 不会自动迁移；可以重新选择，或通过 `--config` 指定原文件。

运行时，EXE 会把内置脚本释放到本用户的临时目录，正常结束后只清理自己创建的文件。关闭窗口会结束本次启动的 PowerShell/SSH 进程树，不影响其他 VS Code 或 SSH 连接。强制结束时可能留下少量临时脚本文件，不包含登录密码或令牌。程序不安装后台服务、不要求管理员权限。

在 PowerShell 中也可以运行（在 EXE 所在目录执行）：

```powershell
.\CodexProxyTunnel.exe --help
.\CodexProxyTunnel.exe --configure
.\CodexProxyTunnel.exe --configure --ssh-config "D:\ssh\config"
.\CodexProxyTunnel.exe --start --proxy-port 7890
.\CodexProxyTunnel.exe --check --no-prompt
.\CodexProxyTunnel.exe --start --config ".\settings.json"
```

仍需 Windows 的 PowerShell、OpenSSH 客户端和 curl；程序会报告缺少的组件，不会自动下载安装。EXE 使用 Windows 的 .NET Framework 4.x，未附带 Python/Node 或需要下载的第三方运行时。当前发布文件未做商业代码签名，Windows 的提示和组织应用策略以所在电脑为准。

以下是保留的脚本版说明；EXE 中的菜单 **1 / 2 / 3 / 4** 分别对应 **Start.cmd / Configure.cmd / Check.cmd / Ssh-Help.cmd**。

## 最快开始

1. 把整个文件夹复制到新电脑并解压到可写目录。不要在压缩包内直接运行。
2. 打开新电脑的代理软件，确认启用了本地 HTTP 或 Mixed（混合）端口。
3. 双击 **Start.cmd**。第一次会读取当前电脑的 `%USERPROFILE%\.ssh\config`，列出服务器别名。输入编号，即可自动填入实际地址、用户名、SSH 端口及按顺序排列的跳板机；随后按回车使用服务器代理入口 `11082`。找不到配置时选择 `M` 手动填写，或选择 `C` 指定其他 SSH 配置文件。
4. 脚本自动寻找并实测本机代理。随后按 SSH 提示输入密码或验证码；密码输入时通常不显示字符。首次连接时核对 SSH 主机指纹。
5. 等待 **TUNNEL_READY**。保持窗口打开，再用 VS Code Remote - SSH 正常连接该服务器。

本包没有预设任何人的服务器、用户名或跳板机。导入来自运行脚本的那台电脑；换电脑后重新选择即可。没有 SSH 配置也可以手动填写：地址应填实际 IP 或域名，不是 `ssh user@host` 命令；IPv6 地址不加方括号，没有跳板机填 `0`。

**换服务器：双击 Configure.cmd。** 它仅重写本文件夹的 `settings.json`。也可为不同服务器复制多个文件夹，分别配置。

## 四个入口

| 文件 | 用途 |
|---|---|
| Start.cmd | 首次配置、检测代理、建立 SSH 隧道、在服务器持续检查网络 |
| Configure.cmd | 修改服务器、用户名、SSH 端口、跳板机及服务器代理入口 |
| Check.cmd | 只检测当前电脑的代理；不连接服务器，不要求已有服务器配置 |
| Ssh-Help.cmd | 显示可复制的 SSH 信息查询命令；不联网、不保存设置 |

`settings.example.json` 仅为格式示例。真正的配置由向导创建为 `settings.json`。复制文件夹给其他人或换服务器前，可不带 `settings.json`，让新电脑重新填写。密码、API Key 和登录令牌都不应写进配置；程序会拒绝额外的密码字段。

## 选择已有 SSH 服务器

双击 **Configure.cmd** 进入选择菜单。`Host` 后面的名称是服务器别名，例如你平时运行 `ssh my-gpu`，列表中就选择 `my-gpu`。

- 输入服务器编号：用本机 OpenSSH 解析最终生效的 `HostName`、`User`、`Port`、`ProxyJump` 和支持的私钥路径。每个跳板机的用户名、端口会分别解析，不要求相同。
- 输入 `C`：指定其他 SSH 配置文件。VS Code 使用自定义配置时，在本机设置中搜索 `remote.SSH.configFile` 查看路径；本包不会自动扫描所有 VS Code 配置文件。
- 输入 `A`：直接输入 SSH 别名。适用于 `Host gpu-*` 等规则，通配符本身不会列为可选服务器。
- 输入 `M`：手动填写目标和跳板机；输入 `H`：查看查询命令；输入 `Q`：取消，保留旧配置。

支持 `Include` 引用的配置和多个 `Host` 别名。配置中的 `Host *` 等规则由 OpenSSH 合并，而不是简单取同一行的文本；解析范围是所选文件及其 `Include`，不额外读取系统级 `ssh_config`。原来的 `LocalForward`、`RemoteForward`、`RemoteCommand` 等不会导入，避免重复启动原连接中的任务。服务器列表也可能包含 Git 主机或跳板机，请选择实际要使用 Codex 的 Linux 服务器。

导入保存的是本次解析的连接信息。之后修改了原 SSH 配置，或将已配置的文件夹拷到另一台电脑，需要重新运行 **Configure.cmd**。正常启动已有 `settings.json` 时会直接使用保存的信息。

自动导入有明确范围：复杂的 `ProxyCommand`、嵌套跳板规则以及不能安全表示的认证或主机验证配置会给出提示并返回选择菜单。配置中存在 `Match exec` 时不自动导入，因为即使 `ssh -G` 也可能执行它。此时可选择其他配置或按原连接方式核对后手动填写；特殊认证或代理命令可能需要专门适配，手动填写不能代替这些命令。私钥只记录路径；原配置明确写了 `IdentityFile none` 时，会保留为 `none`，不会改成默认密钥文件。

命令行使用示例（在启动包目录中运行）：

```powershell
# 指定 VS Code 使用的 SSH 配置文件，进入选择菜单
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-Tunnel.ps1 -Configure -SshConfigPath "D:\ssh\config"

# 只列出本机别名和来源文件，不连接服务器、不保存设置
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-Tunnel.ps1 -ListSshHosts

# 直接进入原来的手动填写向导
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-Tunnel.ps1 -Configure -ManualSetup
```

## 手动查询地址、用户名、端口和跳板机

在**本机 Windows PowerShell** 运行：

```powershell
# 打开 SSH 配置，找到 Host 后面的服务器别名
notepad "$env:USERPROFILE\.ssh\config"

# 把 YOUR_ALIAS 换成别名，查看最终生效的连接参数
ssh -G YOUR_ALIAS | Select-String '^(hostname|user|port|proxyjump|identityfile) '

# 如果使用其他配置文件
ssh -G -F "D:\ssh\config" YOUR_ALIAS | Select-String '^(hostname|user|port|proxyjump|identityfile) '
```

`hostname` 是服务器地址，`user` 是用户名，`port` 是 SSH 端口。`proxyjump` 按从本机出发的顺序列出跳板；若它包含另一个别名，可再对该别名运行 `ssh -G`。没有 `proxyjump` 行通常表示没有 ProxyJump；还需检查原配置是否通过 `ProxyCommand` 连接。`ssh -G` 不登录服务器，但会遵循配置中的 `Match exec`，手动运行前应确认配置可信。

若已登录 Linux 服务器：

```bash
whoami       # 当前用户名
hostname -I  # 本机网卡 IP，可能包含多个内网地址
```

内网 IP 不一定能从新电脑直接连接；隧道应优先使用已能正常登录的 SSH 配置地址和跳板路线。

## 服务器 VS Code 的一次性设置

GUI v2.4 优先使用 **一键配置 VS Code**，不需要手动修改 JSON。以下手动步骤保留给旧控制台版或特殊安装排查。连接服务器后，按 `Ctrl+Shift+P`，选择 **首选项: 打开远程设置(JSON)** / **Preferences: Open Remote Settings (JSON)**。在已有最外层 `{}` 中合并两项，不覆盖其他设置：

```json
{
  "http.useLocalProxyConfiguration": false,
  "http.proxy": "http://127.0.0.1:11082"
}
```

如果向导选择了其他服务器代理端口，使用启动窗口显示的实际端口替换 `11082`。这里始终填写**服务器入口端口**，不是本机代理软件的端口。

执行 **Developer: Reload Window**。按 `Ctrl+Shift+X` 搜索 `@id:openai.chatgpt`，确认发布者 OpenAI，安装到 **SSH: 当前服务器**。打开 Codex 侧边栏，按 **Sign in with ChatGPT** 完成登录。同一 Linux 账号已经安装、登录时可能可以直接复用，以插件实际显示为准。

若浏览器登录回调 `localhost:1455` 失败，可在 VS Code “端口”面板转发服务器的 `1455` 到本机 `1455` 后重试，确认本地映射也是 `1455`。不要复制本地 Codex 的整个配置目录。设备码登录是否可用取决于账户与客户端；不能假定每个扩展版本都有相应按钮。

正常启动隧道不会修改 Remote 设置；GUI v2.4 通过独立按钮执行用户要求的远端设置更新。软件不自动安装扩展或代替你登录账号。完成登录后，可让插件“运行 pwd 并列出当前目录第一层文件，不修改任何文件”，确认实际调用与远程命令均可用。

## 网络路线及端口

```text
Linux 服务器中的 Codex
  -> 服务器 127.0.0.1:11082
  -> SSH 加密反向隧道（可以经过多台跳板机）
  -> 运行本脚本的 Windows 电脑上的实际 HTTP 代理端口
  -> OpenAI
```

服务器入口默认 `11082`；本机端口每次重新发现，不写死、不自动修改代理软件端口。当前电脑与服务器不需要在同一局域网，但当前电脑必须能够通过所填写的 SSH 路线登录服务器。

代理自动发现读取 Windows 系统代理配置、当前进程的代理环境变量、已监听的常见代理进程和常见端口。只尝试本机回环地址，最多 24 个候选；自动检测有总体时间预算，单次请求有超时。优先实测系统代理入口，要求两次独立目标 HTTPS 请求通过后才启动 SSH。

只有 TUN、PAC、SOCKS 或需要账号密码的代理入口不属于本包自动支持范围；请在代理软件中启用无认证的本机 HTTP/Mixed 监听。不要为此打开“允许局域网连接”；本脚本连接本机回环地址即可。未知代理程序的特殊端口可在自动检测失败后手动输入，或运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-Tunnel.ps1 -ProxyPort 7890
```

`7890` 只是示例，应换成实际 HTTP/Mixed 端口。手动指定的端口也必须通过检测，不会跳过 TLS 验证。

## 如何看检测结果

| 显示 | 含义及处理 |
|---|---|
| 本机代理验证通过 | Windows 本机通过代理访问了目标 HTTPS；还没有证明服务器链路可用 |
| TUNNEL_READY | 服务器自身的 curl 通过反向隧道访问目标 HTTPS 成功；保持窗口打开 |
| TUNNEL_DEGRADED | 检测未通过；隧道仍保留，脚本继续检查代理/网络恢复 |
| TUNNEL_RECOVERED | 原先失败或未验证的目标访问已恢复 |
| TUNNEL_UNVERIFIED | 服务器缺少 curl，无法自动验证；转发仍保留，请自行检查或安装 curl |
| TUNNEL_HEARTBEAT HEALTHY | 本轮目标 HTTPS 检测通过；默认每 60 秒检查一次 |
| TUNNEL_BIND_UNSAFE | 服务器实际监听超出回环地址，本次隧道已关闭；请管理员检查 sshd 的 GatewayPorts 设置 |
| TUNNEL_BIND_UNVERIFIED | 无法读取服务器监听表；监听范围尚未验证，后续 HTTPS 检查仍会继续 |
| remote port forwarding failed | 服务器端口被占用，或服务器 SSH 策略不允许转发；这次隧道没有成功建立 |
| Permission denied | SSH 用户名、密钥、密码或认证权限有问题；按失败的是目标还是跳板机核对 |

检查请求不携带任何 OpenAI 凭据。目标返回 `401` 是正常的未认证响应，`2xx` 也可通过。只收到代理的 `200 Connection established` 不会判成功；`403`、TLS 失败和超时都会显示未通过。`api.openai.com` 的网络通过不等于账号已登录、所有认证域名都可达或模型已有使用权限。

远程监测提示中的时间是 UTC，以 `Z` 结尾。默认每分钟一次检查，可在本包 `settings.json` 的 `checkIntervalSeconds` 修改为 10 到 86400 秒。

## 换电脑、停止和断线

- 换电脑接管同一个服务器端口：先在旧电脑的专用隧道窗口按 `Ctrl+C`，再在新电脑启动。关闭本窗口也会断开这次 SSH 连接。
- 两台电脑同时连接同一服务器时，可以共用一台电脑提供的代理隧道。不要同时创建两条监听同一服务器 `127.0.0.1:11082` 的隧道。
- 同一 Linux 账号的 Remote 设置通常共享；不要为第二台电脑随意改共同代理入口。不同服务器可各自使用 `11082`。
- 当前电脑休眠、断网、关闭代理或结束 SSH 后，服务器不能继续借用它联网。SSH 断线会退出；恢复网络后重新双击 Start.cmd。程序不会自动循环提交密码，也不会杀掉旧隧道。
- SSH 保活用于发现断线，不保证代理节点一直可用。代理监听端口变更后应重新启动脚本，让它重新发现端口。

## 配置隔离与系统要求

运行环境：Windows 10/11、Windows PowerShell 5.1+、OpenSSH 客户端 `ssh.exe`、`curl.exe`。Windows 上不需要 Python、Node、管理员权限或本地 Codex 桌面程序。缺少系统组件时会提示，不自动下载安装。Linux 隧道使用 `sh`、`tr`、`sleep` 和用于检查的 `curl`；可选的一键配置还会复用远端 VS Code Server 已有的 Node 运行时，不安装 Codex CLI 或其他服务。

脚本版保存本文件夹的 `settings.json`；EXE 默认保存 `%LOCALAPPDATA%\CodexProxyTunnel\settings.json`。两者都为每次 SSH 会话生成独立临时配置，正常退出后清理。不会修改：

- Windows 的 `.codex/config.toml`、`.codex/.env`、登录凭据或模型选择；
- 用户的 `.ssh/config`、系统代理、注册表、全局环境变量；
- 本地 VS Code 设置，以及服务器的 Shell 启动文件和 Codex 配置。

唯一主动写入远端配置的操作是 **一键配置 VS Code**：按用户点击更新远端 VS Code Machine 设置中的两个代理键，保留其他内容并备份已有文件。该设置由同一服务器账号的 VS Code 窗口共享，不是只对单个项目生效；使用相同账号时应保持代理端口一致。

SSH 首次验证主机时可能按正常流程写入本机 `known_hosts`；这是 SSH 的主机身份记录。启动器不读取私钥内容，也不记录 SSH 密码输入；SSH 自身按正常流程使用密钥认证。手动保存的私钥只记录路径。GUI 原生模式会读取并临时复制 SSH 配置及 Include，其中的自定义认证命令保持原样；不会把这些内容写入日志、发布包或软件服务器库。临时快照由本次 GUI 进程跟踪，正常结束和停止时均清理；不会修改源 SSH 配置。原始文件中嵌入的凭据仍属于用户自己的配置，应按原有方式管理。

脚本请求远程监听绑定 `127.0.0.1`。服务器的 SSH 策略仍有最终决定权：`GatewayPorts no` 或 `clientspecified` 可保留回环范围，`GatewayPorts yes` 会强制通配地址。启动后若能使用 `ss` 读取监听表，脚本会检查选定端口并在发现非回环监听时关闭本次隧道；没有 `ss` 或无法读取时会标记监听范围未验证。必要时在服务器运行 `ss -ltn` 检查实际地址，并请管理员处理。回环地址也不是 Linux 用户之间的访问隔离机制。参见 [OpenSSH GatewayPorts](https://man.openbsd.org/sshd_config#GatewayPorts)。

## 开发验证

测试脚本在 `tests/` 中，普通使用不需要运行。PowerShell 测试使用系统 PowerShell；Python 测试只用于开发，使用标准库和已有 Git Bash，不是运行依赖。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_tunnel.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_proxy.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_ssh_import.ps1
python -m unittest discover -s tests -p "test_*.py" -v
```

实际验证范围及日期见 `change.md`。在另一台电脑上的密码/MFA 输入、主机指纹确认以及新服务器的 SSH 转发策略仍需首次现场登录确认。

EXE 构建源码在 `exe/` 中。构建复用本机 .NET Framework 编译器，不访问包仓库：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\exe\Build-Exe.ps1
python -m unittest discover -s tests -p "test_exe.py" -v
```

构建产物为 `dist\CodexProxyTunnel.exe`。发布包中的同名 EXE 是该产物的副本。测试会实际运行 EXE，覆盖单文件搬移、中文路径、菜单、配置导入、失败路径及进程清理；开发测试需要 Python，普通运行不需要。

官方参考：[OpenSSH RemoteForward](https://man.openbsd.org/ssh_config#RemoteForward)、[VS Code 远端代理](https://code.visualstudio.com/docs/remote/troubleshooting#_extensions-fail-to-connect-to-the-internet-when-installed-remotely)、[Codex IDE 扩展](https://learn.chatgpt.com/docs/codex/ide)、[远程登录](https://learn.chatgpt.com/docs/auth#login-on-headless-devices)。

SSH 导入与查询参考：[ssh -G / -F](https://man.openbsd.org/ssh.1#G)、[Host、Match、Include 和 ProxyJump](https://man.openbsd.org/ssh_config.5)。

EXE 运行机制参考：[Windows .NET Framework](https://learn.microsoft.com/en-us/dotnet/framework/install/on-windows-and-server)、[Windows Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)。
