<#
.SYNOPSIS
    一键配置 Windows -> Linux/NAS 的 SSH 密钥免密登录（幂等，可重复执行）

.DESCRIPTION
    功能步骤：
      1. 检查/生成 ed25519 SSH 密钥对（默认 ~/.ssh/id_ed25519，已有则跳过）
      2. 将公钥安全追加到远端 ~/.ssh/authorized_keys（自动去重、自动设置权限）
      3. 可选写入 ~/.ssh/config 别名（如 -Alias nas，之后直接 ssh nas 即可连接）
      4. 自动验证免密登录是否生效（BatchMode 测试，不会卡在密码提示）
      5. -Remove 反向清除：从远端移除本机公钥断开免密（恢复密码登录），可选清理 SSH config 别名
    适用对象：Win10/11 -> 群晖/威联通 NAS、树莓派、Linux 服务器等任何 OpenSSH 服务端

.EXAMPLE
    .\setup-ssh-key.ps1                                   # 不带参数运行：进入交互式向导，按提示操作

.EXAMPLE
    .\setup-ssh-key.ps1 admin@192.168.1.100

.EXAMPLE
    .\setup-ssh-key.ps1 -Target admin@192.168.1.100 -Port 22 -Alias nas

.EXAMPLE
    .\setup-ssh-key.ps1 admin@192.168.1.100 -Passphrase "my-secret"   # 用口令保护私钥（更安全）

.EXAMPLE
    .\setup-ssh-key.ps1 admin@192.168.1.100 -Force                    # 重新生成密钥对

.EXAMPLE
    .\setup-ssh-key.ps1 admin@192.168.1.100 -Remove                   # 断开免密：从远端删除本机公钥

.EXAMPLE
    .\setup-ssh-key.ps1 admin@192.168.1.100 -Remove -Alias nas        # 断开免密并删除 SSH config 别名
#>

[CmdletBinding()]
param(
    # 不设为必填：无参数运行时进入交互式向导（提示更友好），-Remove 清除模式同样按提示输入
    [Parameter(Position = 0, HelpMessage = '目标账号，格式：用户名@IP，例如 admin@192.168.1.100')]
    [string]$Target,                 # 用户名@IP，例如 admin@192.168.1.100

    [int]$Port = 22,                 # SSH 端口
    [string]$KeyPath = '',           # 私钥路径，默认 ~/.ssh/id_ed25519
    [string]$Passphrase = '',        # 私钥口令（可选，保护私钥本身）
    [string]$Alias = '',             # SSH config 别名（可选），如 nas
    [switch]$Force,                  # 强制删除旧密钥并重新生成
    [switch]$Remove,                 # 反向操作：从远端移除本机公钥，断开免密（恢复密码登录）
    [switch]$NoPause                 # 结束后不暂停等待回车（供脚本/自动化调用）
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Step { param($m) Write-Host "[..] $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Err  { param($m) Write-Host "[X ] $m" -ForegroundColor Red }

function Wait-BeforeExit {
    # 双击运行时窗口会随脚本结束立即关闭（表现为"闪退"），暂停让用户看清结果
    param([int]$Code)
    if (-not $NoPause) {
        Write-Host ""
        Read-Host "按 Enter 键关闭窗口" | Out-Null
    }
    exit $Code
}

function Invoke-RemoteSsh {
    # 统一封装 ssh 远程调用（安装公钥 / 移除公钥 / 验证 共用）：
    # 1) 局部降级 EAP=Continue：PS 5.1 下全局 EAP=Stop 会把 ssh 写到 stderr 的提示
    #    （如首次连接必有的 "Warning: Permanently added ..."）当作异常中断导致"闪退"
    # 2) 兼容极老版本 OpenSSH：不支持 StrictHostKeyChecking=accept-new 时自动降级重试
    # 返回输出对象数组，调用方用 $LASTEXITCODE 判断成败
    param(
        [int]$Port,
        [string]$UserHost,
        [string]$RemoteCmd,
        [string[]]$ExtraOpts = @()
    )
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $sshOpts = @('-p', "$Port", '-o', 'StrictHostKeyChecking=accept-new')
        $o = & ssh @ExtraOpts @sshOpts $UserHost $RemoteCmd 2>&1
        if ($LASTEXITCODE -ne 0 -and ("$o" -match 'Bad configuration option|unknown option')) {
            $sshOpts = @('-p', "$Port", '-o', 'StrictHostKeyChecking=no')
            $o = & ssh @ExtraOpts @sshOpts $UserHost $RemoteCmd 2>&1
        }
        return $o
    }
    finally { $ErrorActionPreference = $prevEap }
}

function Remove-SshConfigAlias {
    # 从 ~/.ssh/config 中删除指定 Host 别名区块（幂等：别名不存在则不做任何修改）
    param([string]$SshDir, [string]$AliasName)
    $cfgFile = Join-Path $SshDir 'config'
    if (-not (Test-Path $cfgFile)) { return }
    $kept = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    $changed = $false
    foreach ($line in (Get-Content $cfgFile)) {
        if ($line -match ("^Host\s+" + [regex]::Escape($AliasName) + "\s*$")) {
            $inBlock = $true; $changed = $true; continue
        }
        if ($inBlock -and $line -match '^\s*Host\s+') { $inBlock = $false }
        if (-not $inBlock) { $kept.Add($line) }
    }
    if ($changed) {
        Set-Content -Path $cfgFile -Value $kept -Encoding ASCII
        Write-Ok "SSH config 别名已删除：ssh $AliasName 不再可用"
    }
}

try {
    # ---------- 0. 交互式向导（无参数运行时给出友好中文提示） ----------
    if (-not $Target) {
        Write-Host ""
        Write-Host "============== SSH 密钥免密管理向导 ==============" -ForegroundColor Cyan
        Write-Host "  [1] 配置免密登录（默认，可重复执行不会重复添加）" -ForegroundColor White
        Write-Host "  [2] 断开免密登录（从远端移除本机公钥，恢复密码登录）" -ForegroundColor White
        Write-Host ""
        $mode = Read-Host "请选择操作 [1/2]（直接回车默认 1）"
        if ("$mode".Trim() -eq '2') { $Remove = $true }
        Write-Host ""
        $Target = Read-Host "请输入目标账号（格式：用户名@IP，例如 admin@192.168.1.100）"
    }
    if ($Target -notmatch '^[^@\s]+@[^@\s]+$') {
        throw "参数格式应为 用户名@IP，例如 admin@192.168.1.100"
    }
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        throw "未找到 ssh 命令。请在 设置->应用->可选功能 中安装 'OpenSSH 客户端' 后重试。"
    }
    $user, $hostName = $Target -split '@', 2

    # ---------- 1. 生成/复用本地密钥（幂等） ----------
    $sshDir = Join-Path $HOME '.ssh'
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
    if (-not $KeyPath) { $KeyPath = Join-Path $sshDir 'id_ed25519' }
    $pubPath = "$KeyPath.pub"

    if ((Test-Path $KeyPath) -and -not $Force) {
        Write-Ok "本地密钥已存在：$KeyPath（跳过生成，幂等）"
    }
    elseif (-not $Remove) {
        if ($Force -and (Test-Path $KeyPath)) {
            Write-Step "-Force：删除旧密钥对并重新生成"
            Remove-Item $KeyPath, $pubPath -Force -ErrorAction SilentlyContinue
        }
        Write-Step "生成 ed25519 密钥对：$KeyPath"
        & ssh-keygen -q -t ed25519 -N $Passphrase -C "$env:USERNAME@$env:COMPUTERNAME" -f $KeyPath
        if ($LASTEXITCODE -ne 0) { throw "ssh-keygen 生成密钥失败" }
        Write-Ok "密钥对生成完成"
    }

    # 解析公钥内容（取 keyType 与 keyMaterial，二者均不含空格/引号，可安全拼入远程命令）
    if (-not (Test-Path $pubPath)) {
        if ($Remove) { throw "本机不存在公钥 $pubPath，远端不可能配置过本机免密，无需断开" }
        throw "公钥文件不存在：$pubPath"
    }
    $pubKey = (Get-Content $pubPath -Raw).Trim()
    $tokens = $pubKey -split '\s+'
    $keyType, $keyMaterial = $tokens[0], $tokens[1]
    if (-not $keyMaterial) { throw "公钥内容异常：$pubPath" }

    # ---------- 1b. -Remove：断开免密（预检 -> 移除 -> 复检 三段式验证） ----------
    if ($Remove) {
        # 预检：当前免密是否生效（BatchMode 模式，不输密码、不会卡住）
        Write-Step "预检当前免密状态（BatchMode 模式，不会要求密码）..."
        $pre = Invoke-RemoteSsh -Port $Port -UserHost $Target -RemoteCmd 'echo SSH_OK' -ExtraOpts @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8')
        $wasWorking = ($LASTEXITCODE -eq 0)
        if ($wasWorking) {
            Write-Ok "当前免密登录生效中，开始移除公钥（无需密码）"
        }
        else {
            Write-Host "[..] 当前免密未生效（此前公钥可能未安装成功）。如需清理远端公钥可继续（将要求输入一次密码）" -ForegroundColor Yellow
            $pre | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
        }

        Write-Step "从 $Target 移除本机公钥"
        # 远端命令同样刻意避开双引号与变量，规避 PS 5.1 传参转义问题
        $remoteCmd = (
            "umask 077; if [ -f ~/.ssh/authorized_keys ] && grep -qF $keyMaterial ~/.ssh/authorized_keys; then " +
            "grep -vF $keyMaterial ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.tmp; " +
            "mv -f ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; echo RESULT=KEY_REMOVED; " +
            "else echo RESULT=KEY_NOT_FOUND; fi"
        )
        $out = Invoke-RemoteSsh -Port $Port -UserHost $Target -RemoteCmd $remoteCmd
        $out | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) {
            Write-Err "远端移除失败（exit=$LASTEXITCODE）"
            if ("$out" -match 'Could not chdir to home directory|Permission denied|No such file or directory') {
                Write-Host "     ★ 检测到远端家目录缺失/不可写：请先用 NAS 管理员账号执行（一次性）：" -ForegroundColor Yellow
                Write-Host "       sudo mkdir -p /home/$user/.ssh; sudo chown -R $user /home/$user; sudo chmod 700 /home/$user/.ssh" -ForegroundColor Yellow
            }
            Write-Host "     其他常见原因：IP/端口/账号错误、NAS 不在线、密码输入错误" -ForegroundColor Yellow
            Wait-BeforeExit 1
        }
        if ("$out" -match 'RESULT=KEY_REMOVED') {
            # 复检：移除后免密应当失效
            Write-Step "复检免密是否已断开（BatchMode 模式）..."
            $post = Invoke-RemoteSsh -Port $Port -UserHost $Target -RemoteCmd 'echo SSH_OK' -ExtraOpts @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8')
            if ($LASTEXITCODE -eq 0) {
                Write-Err "公钥已从默认位置移除，但免密仍然生效！可能原因："
                Write-Host "     - NAS 的 sshd 使用自定义 AuthorizedKeysFile 路径（检查远端 /etc/ssh/sshd_config）" -ForegroundColor Yellow
                Write-Host "     - 远端还配置了本机的其他公钥（如 authorized_keys2）" -ForegroundColor Yellow
            }
            else {
                Write-Ok "已验证：免密登录已断开（BatchMode 预检不再通过），后续 SSH 将恢复密码登录"
            }
        }
        else {
            if ($wasWorking) {
                Write-Err "默认位置未找到本机公钥，但免密仍生效：公钥可能配置在 NAS 的自定义位置"
                Write-Host "     请检查远端 /etc/ssh/sshd_config 中 AuthorizedKeysFile 的设置" -ForegroundColor Yellow
            }
            else {
                Write-Ok "远端没有本机公钥，且免密本来未生效——无需断开，当前已是密码登录"
            }
        }
        if ($Alias) { Remove-SshConfigAlias -SshDir $sshDir -AliasName $Alias }
        Write-Host ""
        Write-Host "  补充说明：" -ForegroundColor White
        Write-Host "    - 本机密钥对已保留（可能被其他服务器使用）。如确认不再需要，可手动删除：" -ForegroundColor Gray
        Write-Host "      Remove-Item `"$KeyPath`", `"$pubPath`"" -ForegroundColor Gray
        Wait-BeforeExit 0
    }

    # ---------- 2. 将公钥安装到远端（一次 ssh 调用，只需输入一次密码） ----------
    # 说明：整条远程命令刻意避开双引号与变量，规避 PowerShell 5.1 向 ssh.exe 传参时的引号转义问题
    Write-Step "将公钥安装到 $Target（首次会要求输入一次密码）"
    $remoteCmd = (
        "umask 077; mkdir -p ~/.ssh; chmod 700 ~/.ssh; " +
        "if grep -qF $keyMaterial ~/.ssh/authorized_keys 2>/dev/null; then echo RESULT=ALREADY_EXISTS; " +
        "else echo $keyType $keyMaterial >> ~/.ssh/authorized_keys && echo RESULT=KEY_ADDED; fi; " +
        "chmod 600 ~/.ssh/authorized_keys"
    )
    $out = Invoke-RemoteSsh -Port $Port -UserHost $Target -RemoteCmd $remoteCmd
    $out | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
    if ($LASTEXITCODE -ne 0) {
        Write-Err "公钥安装失败（exit=$LASTEXITCODE）"
        # 精准提示：远端账号家目录缺失或不可写（最常见于未启用"用户家目录"的 NAS）
        if ("$out" -match 'Could not chdir to home directory|Permission denied|No such file or directory') {
            Write-Host "     ★ 检测到远端家目录缺失/不可写：请先用 NAS 管理员账号执行（一次性）：" -ForegroundColor Yellow
            Write-Host "       sudo mkdir -p /home/$user/.ssh; sudo chown -R $user /home/$user; sudo chmod 700 /home/$user/.ssh" -ForegroundColor Yellow
            Write-Host "       （群晖 DSM：控制面板 -> 用户家目录 -> 启用）然后重新运行本脚本" -ForegroundColor Yellow
        }
        Write-Host "     常见原因：" -ForegroundColor Yellow
        Write-Host "     - NAS 未开启 SSH：群晖/威联通 控制面板 -> 终端机和 SNMP -> 启用 SSH" -ForegroundColor Yellow
        Write-Host "     - 用户家目录未启用：群晖 控制面板 -> 用户家目录 -> 启用" -ForegroundColor Yellow
        Write-Host "     - 用户名/IP/端口错误" -ForegroundColor Yellow
        Wait-BeforeExit 1
    }
    if ("$out" -match 'RESULT=ALREADY_EXISTS') { Write-Ok "公钥已存在于远端（自动去重，幂等）" }
    else { Write-Ok "公钥已写入远端 ~/.ssh/authorized_keys" }

    # ---------- 3. 可选：注册私钥口令到 ssh-agent ----------
    if ($Passphrase) {
        Write-Step "检测到私钥口令，尝试启用 ssh-agent 缓存（避免每次输口令）"
        try {
            $svc = Get-Service ssh-agent -ErrorAction SilentlyContinue
            if ($svc) {
                if ($svc.StartType -eq 'Disabled') { Set-Service ssh-agent -StartupType Automatic }
                if ($svc.Status -ne 'Running') { Start-Service ssh-agent }
                Write-Host "     请在下方提示中输入一次私钥口令：" -ForegroundColor Yellow
                & ssh-add $KeyPath
            }
            else { Write-Host "     未找到 ssh-agent 服务，可稍后手动执行：ssh-add $KeyPath" -ForegroundColor Yellow }
        }
        catch { Write-Host "     ssh-agent 设置失败（可能需要管理员权限）：$($_.Exception.Message)" -ForegroundColor Yellow }
    }

    # ---------- 4. 可选：写入 SSH config 别名（幂等） ----------
    if ($Alias) {
        $cfgFile = Join-Path $sshDir 'config'
        $exists = $false
        if (Test-Path $cfgFile) {
            $exists = Select-String -Path $cfgFile -Pattern ("^Host\s+" + [regex]::Escape($Alias) + "\s*$") -Quiet
        }
        if ($exists) {
            Write-Ok "SSH config 别名已存在：ssh $Alias（跳过，幂等）"
        }
        else {
            $block = "`nHost $Alias`n    HostName $hostName`n    User $user`n    Port $Port`n    IdentityFile $KeyPath`n"
            Add-Content -Path $cfgFile -Value $block -Encoding ASCII
            Write-Ok "别名已写入：以后可直接 ssh $Alias 连接 NAS"
        }
    }

    # ---------- 5. 验证免密登录 ----------
    Write-Step "验证免密登录（BatchMode 模式，不会卡在密码提示）..."
    $vout = Invoke-RemoteSsh -Port $Port -UserHost $Target -RemoteCmd 'echo SSH_OK' -ExtraOpts @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8')
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Ok "免密登录配置成功！"
        Write-Host ""
        Write-Host "  现在可以直接免密执行远程命令，例如：" -ForegroundColor White
        Write-Host "    ssh $Target `"docker version`"" -ForegroundColor White
        if ($Alias) { Write-Host "    ssh $Alias `"docker version`"" -ForegroundColor White }
        Write-Host ""
        Write-Host "  可以把下面这段话写进 AI Agent 的提示词（无需包含任何密码）：" -ForegroundColor White
        Write-Host "    NAS 的 SSH 访问已配置为免密登录：ssh $Target `<命令`> 即可直接执行，" -ForegroundColor Gray
        if ($Alias) { Write-Host "    也可使用别名：ssh $Alias `<命令`>。" -ForegroundColor Gray }
    }
    else {
        Write-Err "免密验证未通过（exit=$LASTEXITCODE）。ssh 返回信息："
        $vout | ForEach-Object { Write-Host "     $_" -ForegroundColor DarkGray }
        Write-Host "     排障建议：" -ForegroundColor Yellow
        Write-Host "     1) 确认 NAS 已开启 SSH 且允许密钥登录（部分固件默认禁用 PubkeyAuthentication）" -ForegroundColor Yellow
        Write-Host "     2) 家目录及 ~/.ssh 权限：chmod 755 ~ ; chmod 700 ~/.ssh ; chmod 600 ~/.ssh/authorized_keys" -ForegroundColor Yellow
        Write-Host "     3) 若私钥设有口令，请先执行 ssh-add $KeyPath 或重跑本脚本查看 ssh-agent 步骤" -ForegroundColor Yellow
        Write-Host "     4) 服务端日志排查：/var/log/auth.log 或 NAS 的 SSH 日志" -ForegroundColor Yellow
        Wait-BeforeExit 1
    }
    Wait-BeforeExit 0
}
catch {
    Write-Err "配置中止：$($_.Exception.Message)"
    Wait-BeforeExit 1
}
