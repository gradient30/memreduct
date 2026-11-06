#Requires -Version 5.1
<#
	为 memreduct webui 放行 Tailnet 入站流量
	- 仅允许来源 100.64.0.0/10 (Tailscale CGNAT 段), 局域网/公网来源不受影响
	- 需要管理员权限运行 (右键"使用 PowerShell 运行", 或经 UAC 提权调用)
	- 重复运行安全: 先删旧规则再新建
#>

$rule = 'memreduct-webui-tailnet'

netsh advfirewall firewall delete rule name="$rule" | Out-Null
netsh advfirewall firewall add rule name="$rule" dir=in action=allow protocol=TCP localport=8765 remoteip=100.64.0.0/10 profile=any

Write-Host ''
Write-Host '完成。规则内容:' -ForegroundColor Green
netsh advfirewall firewall show rule name="$rule"
