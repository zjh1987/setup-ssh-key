# Windows 一键 SSH 免密配置

针对场景：**Windows 10/11 电脑通过 SSH 免密管理局域网内的 NAS / 树莓派 / Linux 服务器**。一个 PowerShell 脚本搞定，零外部依赖，不需要 WSL、不需要 Python、不需要装任何模块。

适合谁：

- 想让 AI Agent（如本机部署的大模型助手）免密操作 NAS，但不想把密码写进提示词
- 受够了每次 `ssh admin@192.168.x.x` 都要输密码
- 在 Windows 原生环境下找不到顺手的 `ssh-copy-id` 等价工具

## 特性

- **一键配置**：只需输入一次 NAS 密码，之后永久免密
- **幂等安全**：重复执行不会重复生成密钥，远端公钥自动去重，权限自动收敛（`~/.ssh` 700、`authorized_keys` 600）
- **双向操作**：`-Remove` 一键断开免密，含「预检 → 移除 → 复检」三段式验证，结果可确认
- **交互式向导**：不带参数直接运行，中文提示一步一步操作，新手友好
- **自动验证**：配置完成后自动用 BatchMode 模式验证免密是否真正生效（不会卡在密码提示）
- **智能排障**：家目录缺失、权限不对、老版本 OpenSSH 等常见 NAS 问题自动识别并给出修复命令
- **安全实践**：默认 ed25519 密钥，私钥不出本机；支持 `-Passphrase` 口令保护 + ssh-agent
- **兼容性**：兼容 Windows PowerShell 5.1（系统自带）；极老版本 OpenSSH 不支持 `accept-new` 时自动降级
- **不闪退**：所有失败路径都会暂停显示完整错误信息，双击运行也能看清原因

## 环境要求

- Windows 10/11（自带的 Windows PowerShell 5.1 或 PowerShell 7 均可）
- OpenSSH 客户端（Win10 1809+ / Win11 通常已内置；没有的话：设置 → 应用 → 可选功能 → 添加「OpenSSH 客户端」）
- 对端 NAS/服务器开启 SSH 服务

## 快速开始

### 第 0 步（只需一次）：允许运行 PowerShell 脚本

以管理员或当前用户身份执行：

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### 第 1 步：一键配置免密

**方式 A —— 交互式向导（推荐新手）：** 直接双击脚本或在 PowerShell 中运行

```powershell
.\setup-ssh-key.ps1
```

按提示选择「配置免密登录」并输入目标账号即可。

**方式 B —— 命令行直接指定：**

```powershell
.\setup-ssh-key.ps1 admin@192.168.1.100

# 常用组合：写入别名 nas（之后可直接 ssh nas 连接）
.\setup-ssh-key.ps1 admin@192.168.1.100 -Alias nas
```

过程中只需输入 **一次** NAS 密码。脚本可重复执行（幂等）：已生成的密钥不会重新生成，远端公钥自动去重。

### 第 2 步：验证

```powershell
ssh admin@192.168.1.100 "docker version"
# 或使用别名
ssh nas "docker version"
```

不再提示密码即为成功。此时可以把这句话写进 AI Agent 的提示词（**不包含任何密码**）：

> NAS 的 SSH 访问已配置为免密登录：`ssh admin@192.168.1.100 "<命令>"` 或 `ssh nas "<命令>"` 可直接执行，无需密码。

## 断开免密

想让某台服务器恢复密码登录时：

```powershell
# 交互式向导：选择 [2] 断开免密登录
.\setup-ssh-key.ps1

# 或命令行直接指定
.\setup-ssh-key.ps1 admin@192.168.1.100 -Remove

# 同时清理 ~/.ssh/config 中写入的别名
.\setup-ssh-key.ps1 admin@192.168.1.100 -Remove -Alias nas
```

断开流程包含三段式验证：

1. **预检** —— 先测试当前免密是否生效（BatchMode，不输密码不卡住）
2. **移除** —— 从远端 `~/.ssh/authorized_keys` 精确移除本机公钥（只删自己那行，不动其他公钥）
3. **复检** —— 移除后再次测试，确认免密真正失效；若公钥删了免密仍生效，会提示检查 NAS 的 `AuthorizedKeysFile` 自定义路径

本机密钥对默认保留（可能被其他服务器使用），脚本会给出手动删除的方法。

## 参数说明

| 参数 | 说明 |
|---|---|
| `Target` | `用户名@IP`，如 `admin@192.168.1.100`；省略时进入交互式向导 |
| `-Port 22` | SSH 端口 |
| `-KeyPath` | 自定义私钥路径，默认 `~\.ssh\id_ed25519` |
| `-Passphrase "xxx"` | 给私钥加口令（更安全），脚本自动尝试注册到 ssh-agent |
| `-Alias nas` | 写入 SSH config 别名，之后可直接 `ssh nas` |
| `-Force` | 删除旧密钥对并重新生成（谨慎） |
| `-Remove` | 断开免密：从远端移除本机公钥 |
| `-NoPause` | 结束后不暂停等待回车（供脚本/自动化调用） |

## NAS 常见问题

- **群晖 DSM**：控制面板 → 终端机和 SNMP → 启用 SSH；**控制面板 → 用户家目录 → 启用**（不启用会导致密钥登录失败，脚本检测到该问题会直接给出修复命令）
- **威联通 QTS**：控制台 → Telnet / SSH → 允许 SSH 连接
- **家目录不存在报错**（`Could not chdir to home directory ... Permission denied`）：需要 NAS 管理员账号一次性修复：

  ```bash
  sudo mkdir -p /home/<用户名>/.ssh
  sudo chown -R <用户名> /home/<用户名>
  sudo chmod 700 /home/<用户名>/.ssh
  ```

- 远端权限要求（脚本已自动设置）：`~` 为 755、`~/.ssh` 为 700、`authorized_keys` 为 600

## FAQ

<details>
<summary><b>免密验证失败怎么办？</b></summary>

重新运行脚本，按输出的排障提示逐项检查：NAS 是否开启 SSH、是否启用「用户家目录」、部分固件是否默认禁用 `PubkeyAuthentication`。脚本会在失败时显示 ssh 的原始返回信息，方便定位。
</details>

<details>
<summary><b>提示 <code>WARNING: UNPROTECTED PRIVATE KEY FILE</code>？</b></summary>

远端权限问题，在 NAS 上执行 `chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`。
</details>

<details>
<summary><b>双击运行窗口一闪而过？</b></summary>

脚本已内置暂停机制，任何结果（包括错误）都会停在「按 Enter 键关闭窗口」。如仍闪退，请确认用 Windows PowerShell 而非 cmd 运行，并检查文件编码是否为 UTF-8 with BOM。
</details>

<details>
<summary><b>断开免密后仍然不用密码就能登录？</b></summary>

说明公钥还配置在其他位置（如 NAS 的自定义 `AuthorizedKeysFile` 路径或 `authorized_keys2`）。脚本复检发现这种情况会主动提示，检查远端 `/etc/ssh/sshd_config` 即可。
</details>

<details>
<summary><b>私钥会被上传吗？</b></summary>

不会。整个流程只把 **公钥**（`.pub` 文件）追加到远端 `~/.ssh/authorized_keys`，私钥始终留在本机。
</details>

## 工作原理

1. 本地生成 ed25519 密钥对（已有则跳过，幂等）
2. 通过一次 SSH 连接（输入一次密码）把公钥安全追加到远端 `~/.ssh/authorized_keys`：自动创建目录、去重、收敛权限
3. 可选写入本地 `~/.ssh/config` 别名
4. 用 BatchMode 模式验证免密登录是否真正生效（失败不会卡在密码提示）

断开免密则反向执行：从 `authorized_keys` 精确移除本机公钥所在行，并复检确认失效。

## 许可证

[MIT](LICENSE)
