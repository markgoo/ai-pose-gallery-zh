#Requires -Version 5.1
<#
  AI 角色参考与合成工作台 · 本地一键启动脚本

  用法（在本目录执行，或直接双击 start.bat）：
    .\start.ps1                 开发模式（热更新，默认 5173 起自动挑空闲端口）
    .\start.ps1 -Port 5180      指定端口（被占用则直接报错，不静默换端口）
    .\start.ps1 -Mode preview   预览已构建的 dist（缺失时自动先构建）
    .\start.ps1 -Local          仅限本机访问（默认已开放局域网/手机访问）
    .\start.ps1 -ComfyUIUrl http://127.0.0.1:8188   指定 ComfyUI 地址（默认自动探测 8000/8188）
    .\start.ps1 -NoBrowser      不自动打开浏览器
    .\start.ps1 -InstallOnly    只安装依赖，不启动

  说明：
    * 浏览器一律用 http://localhost:端口 打开。vite 在 Windows 上默认只监听 ::1，
      访问 http://127.0.0.1:端口 会被拒绝，这是本项目最容易踩的坑。
    * 本地 ComfyUI 生图需要 ComfyUI 在跑（默认 http://127.0.0.1:8000），
      可用环境变量 COMFYUI_URL 指定其他地址，本脚本会自动透传。
#>
[CmdletBinding()]
param(
  [ValidateSet('dev', 'preview')]
  [string]$Mode = 'dev',
  [int]$Port = 0,
  [switch]$Local,
  [string]$ComfyUIUrl = '',
  [switch]$NoBrowser,
  [switch]$InstallOnly
)

$ErrorActionPreference = 'Stop'

# 中文输出：避免 Windows 控制台 GBK 编码把中文/符号打成乱码
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Root = $PSScriptRoot
Set-Location -LiteralPath $Root
$Started = Get-Date

function Write-Ok([string]$msg) { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Write-Info([string]$msg) { Write-Host "  [..]   $msg" -ForegroundColor Gray }
function Write-Warn2([string]$msg) { Write-Host "  [警告] $msg" -ForegroundColor Yellow }
function Stop-WithError([string]$msg) {
  Write-Host ''
  Write-Host "  [失败] $msg" -ForegroundColor Red
  exit 1
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '  AI 角色参考与合成工作台 · 本地启动' -ForegroundColor Cyan
Write-Host '  姿势库 1,439 · 服装库 1,407 · 人像库 1,499' -ForegroundColor DarkCyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''

# ---------- 1. 环境检查 ----------
$nodeExe = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeExe) {
  Stop-WithError '未找到 Node.js。请安装 Node.js 20 或更高版本后重试：https://nodejs.org/'
}
$nodeVerRaw = (& node -v 2>$null)
if (-not $nodeVerRaw) { Stop-WithError 'node -v 执行失败，Node.js 安装可能不完整。' }
$nodeVer = $nodeVerRaw.Trim().TrimStart('v')
$nodeOk = $false
try { $nodeOk = ([version]$nodeVer -ge [version]'20.0.0') } catch { $nodeOk = $false }
if (-not $nodeOk) {
  Stop-WithError "Node.js 版本过低：$nodeVerRaw（需要 v20 及以上）。"
}
Write-Ok "Node.js $nodeVerRaw"

$pnpmExe = Get-Command pnpm -ErrorAction SilentlyContinue
if (-not $pnpmExe) {
  Write-Warn2 '未找到 pnpm。任选一种方式安装后重试：'
  Write-Host '            corepack enable pnpm' -ForegroundColor White
  Write-Host '            npm install -g pnpm' -ForegroundColor White
  Stop-WithError '缺少 pnpm，无法继续。'
}
$pnpmVer = (& pnpm --version 2>$null)
Write-Ok "pnpm $pnpmVer"

# ComfyUI 代理目标：优先用显式参数，其次环境变量，再自动探测 8000/8188
# （8000 = ComfyUI Desktop 默认端口，8188 = 便携版/源码版默认端口）
function Get-RunningComfyUi {
  foreach ($p in 8000, 8188) {
    try {
      $stats = Invoke-RestMethod -Uri "http://127.0.0.1:$p/system_stats" -TimeoutSec 2 -ErrorAction Stop
      if ($stats.system) { return "http://127.0.0.1:$p" }
    }
    catch { }
  }
  return ''
}

$comfyUrl = $ComfyUIUrl
if (-not $comfyUrl) { $comfyUrl = $env:COMFYUI_URL }
$comfyDetected = $false
if (-not $comfyUrl) {
  $comfyUrl = Get-RunningComfyUi
  $comfyDetected = [bool]$comfyUrl
}
if ($comfyUrl) {
  $env:COMFYUI_URL = $comfyUrl
  if ($comfyDetected) { Write-Ok "检测到 ComfyUI 正在运行：$comfyUrl（已设为 /comfy 代理目标）" }
  else { Write-Info "ComfyUI 代理目标：$comfyUrl" }
}
else {
  $env:COMFYUI_URL = $null
  Write-Warn2 '未检测到 ComfyUI（8000/8188 均无响应），合成台的「本地 ComfyUI」暂不可用'
  Write-Host '           启动 ComfyUI 后重跑本脚本即可自动识别；也可用 -ComfyUIUrl 指定地址。' -ForegroundColor Gray
}

# ---------- 2. 依赖安装 ----------
$needInstall = -not (Test-Path (Join-Path $Root 'node_modules/vite/package.json'))
if ($needInstall) {
  Write-Info '首次运行，正在安装依赖（约 30 秒）...'
  & pnpm install --frozen-lockfile
  if ($LASTEXITCODE -ne 0) {
    Write-Warn2 '--frozen-lockfile 安装失败，改用普通安装重试...'
    & pnpm install
    if ($LASTEXITCODE -ne 0) { Stop-WithError '依赖安装失败，请检查网络或代理设置。' }
  }
  Write-Ok '依赖安装完成'
}
else {
  Write-Ok '依赖已就绪（node_modules 存在）'
}

if ($InstallOnly) {
  Write-Host ''
  Write-Ok '仅安装依赖模式完成。'
  exit 0
}

# ---------- 3. 端口 ----------
function Test-PortInUse([int]$p) {
  try {
    $conn = Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue
    if ($conn) { return $true }
  }
  catch {
    # Get-NetTCPConnection 不可用时退化为直接尝试绑定
    foreach ($addr in @([System.Net.IPAddress]::Loopback, [System.Net.IPAddress]::IPv6Loopback)) {
      $listener = $null
      try {
        $listener = [System.Net.Sockets.TcpListener]::new($addr, $p)
        $listener.Start()
        $listener.Stop()
      }
      catch { if ($listener) { $listener.Stop() }; return $true }
    }
    return $false
  }
  return $false
}

if ($Port -gt 0) {
  if (Test-PortInUse $Port) {
    Stop-WithError "端口 $Port 已被占用。换一个端口：.\start.ps1 -Port $($Port + 1)"
  }
}
else {
  $base = 5173
  $Port = 0
  for ($p = $base; $p -lt ($base + 50); $p++) {
    if (-not (Test-PortInUse $p)) { $Port = $p; break }
  }
  if ($Port -eq 0) { Stop-WithError "端口 $base-$($base + 49) 全部被占用，请用 -Port 手动指定。" }
}
Write-Ok "端口 $Port 可用"

# ---------- 4. preview 模式：确保 dist 已构建 ----------
if ($Mode -eq 'preview') {
  if (-not (Test-Path (Join-Path $Root 'dist/index.html'))) {
    Write-Info '未找到 dist/index.html，正在构建（pnpm build）...'
    & pnpm build
    if ($LASTEXITCODE -ne 0) { Stop-WithError '构建失败，请查看上方 tsc/vite 报错。' }
    Write-Ok '构建完成'
  }
  else {
    Write-Ok '使用已有 dist/（如需最新代码请先 pnpm build）'
  }
}

# ---------- 5. 启动 ----------
$url = "http://localhost:$Port/"
$viteArgs = @()
if ($Mode -eq 'preview') { $viteArgs += 'preview' }
$viteArgs += @('--port', "$Port", '--strictPort')
# 默认监听 0.0.0.0，手机/平板/其他电脑可直接访问；-Local 时只监听本机回环
if (-not $Local) { $viteArgs += '--host' }

$pages = @(
  @{ Path = '/'; Name = '总览' },
  @{ Path = '/poses'; Name = '姿势库' },
  @{ Path = '/costumes'; Name = '服装库' },
  @{ Path = '/portraits'; Name = '人像库' },
  @{ Path = '/studio'; Name = '合成台' },
  @{ Path = '/settings'; Name = '设置' }
)

Write-Host ''
Write-Host "  模式：$Mode    地址：$url" -ForegroundColor White
if (-not $Local) {
  $lanIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
      $_.IPAddress -notlike '127.*' -and
      $_.IPAddress -notlike '169.254.*' -and
      $_.PrefixOrigin -ne 'WellKnown'
    } |
    Select-Object -ExpandProperty IPAddress)
  if ($lanIps.Count -gt 0) {
    Write-Host "  局域网/手机访问（与电脑连同一个 WiFi）：" -ForegroundColor DarkCyan
    foreach ($ip in $lanIps) {
      Write-Host "           http://${ip}:$Port/     （合成台 /studio）" -ForegroundColor DarkCyan
    }

    # Windows 防火墙默认拦截入站：没有任何针对 node.exe 的放行规则时，手机通常打不开
    $nodePath = (Get-Command node -ErrorAction SilentlyContinue).Source
    $fwOk = $null
    try {
      if ($nodePath) {
        $fwOk = (@(Get-NetFirewallApplicationFilter -ErrorAction Stop |
            Where-Object { $_.Program -eq $nodePath }).Count -gt 0)
      }
    }
    catch { $fwOk = $null }

    if ($fwOk -eq $true) {
      Write-Info 'Windows 防火墙已有 node.exe 放行规则，手机可直接访问'
    }
    else {
      Write-Host '  手机打不开时：电脑若弹出防火墙提示，勾选「专用网络」并允许；' -ForegroundColor Yellow
      Write-Host '  或用管理员 PowerShell 执行一次下面的命令（只放行 node，仅专用网络）：' -ForegroundColor Yellow
      Write-Host ("    netsh advfirewall firewall add rule name=`"AI Pose Gallery Dev`" dir=in action=allow program=`"$nodePath`" enable=yes profile=private") -ForegroundColor White
    }
  }
  else {
    Write-Warn2 '未检测到局域网 IPv4 地址（可能没连网络），手机将无法访问。'
  }
}
else {
  Write-Info '仅本机访问模式（-Local），已关闭局域网监听。'
}
foreach ($page in $pages) {
  Write-Host ("           {0,-10} {1}" -f $page.Name, "http://localhost:$Port$($page.Path)") -ForegroundColor DarkGray
}
Write-Host ''
Write-Host '  按 Ctrl+C 停止服务' -ForegroundColor Yellow
Write-Host '------------------------------------------------------------' -ForegroundColor DarkGray
Write-Host ''

# 后台等待服务就绪后打开浏览器（不阻塞 vite 的前台日志输出，Ctrl+C 也能正常传递给 vite）
$browserJob = $null
if (-not $NoBrowser) {
  $browserJob = Start-Job -ArgumentList $url -ScriptBlock {
    param($u)
    for ($i = 0; $i -lt 180; $i++) {
      try {
        $res = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 2
        if ($res.StatusCode -ge 200 -and $res.StatusCode -lt 400) {
          Start-Process $u
          return
        }
      }
      catch { }
      Start-Sleep -Milliseconds 500
    }
  }
}

$exitCode = 0
try {
  & pnpm exec vite @viteArgs
  $exitCode = $LASTEXITCODE
}
finally {
  if ($browserJob) {
    $browserJob | Stop-Job -ErrorAction SilentlyContinue
    $browserJob | Remove-Job -Force -ErrorAction SilentlyContinue
  }
}

$elapsed = [int]((Get-Date) - $Started).TotalSeconds
Write-Host ''
if ($Mode -eq 'preview' -and $exitCode -ne 0) {
  Write-Warn2 "预览服务已退出（退出码 $exitCode）。"
}
else {
  Write-Info "服务已停止，本次运行 $elapsed 秒。"
}
if ($exitCode -ne 0 -and $Mode -eq 'dev') {
  Write-Host '  若提示端口被占用，可指定其他端口：.\start.ps1 -Port 5180' -ForegroundColor Yellow
}
exit $exitCode
