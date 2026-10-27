param(
    [ValidateSet('Inspect','Proxy','Restore','Library')][string]$Mode = 'Inspect',
    [string]$AdapterId = '',
    [string]$StateRoot = "$env:ProgramData\MAXsGatewaySwitch",
    [int]$OwnerProcessId = 0,
    [long]$OwnerStartTicks = 0
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$script:Prefixes = @('0.0.0.0/0')
$script:StateFile = Join-Path $StateRoot 'restore.json'

function Get-Plan($Addresses) {
    $good = @($Addresses | Where-Object { [string]$_.AddressState -eq 'Preferred' -and [int]$_.PrefixLength -eq 24 })
    $lanAddresses = @($good | Where-Object { $_.IPAddress -match '^192\.168\.1\.\d+$' })
    $proxy = @($good | Where-Object { $_.IPAddress -match '^192\.168\.30\.\d+$' })
    if ($lanAddresses.Count -gt 0 -and $proxy.Count -gt 0) { throw '同一网卡同时配置了两个家庭网段，请先整理地址。' }
    if ($lanAddresses.Count -eq 1) {
        if ($lanAddresses[0].IPAddress -in @('192.168.1.0','192.168.1.1','192.168.1.192','192.168.1.255')) { throw '当前地址属于网关或保留地址，请先检查网络配置。' }
        return [pscustomobject]@{Gateway='192.168.1.192'; Network='家庭主网络'; Address=$lanAddresses[0].IPAddress}
    }
    if ($proxy.Count -eq 1) {
        if ($proxy[0].IPAddress -in @('192.168.30.0','192.168.30.1','192.168.30.255')) { throw '当前地址属于网关或保留地址。' }
        return [pscustomobject]@{Gateway='192.168.30.1'; Network='Proxy-WiFi'; Address=$proxy[0].IPAddress}
    }
    throw '只支持家庭 192.168.1.x/24 或 Proxy-WiFi 192.168.30.x/24。请先连接家庭网络并通过 DHCP 获取地址。'
}

function Get-AdapterById([string]$Id) {
    $items = @(Get-NetAdapter -IncludeHidden | Where-Object { ([string]$_.InterfaceGuid).Trim('{}') -eq $Id.Trim('{}') })
    if ($items.Count -ne 1) { throw '找不到原来的网卡。请重新连接网卡后再还原；备份已保留。' }
    return $items[0]
}

function Get-Addresses($Adapter) {
    return @(Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
}

function Get-IPv6Enabled($Adapter) {
    $escaped = [WildcardPattern]::Escape([string]$Adapter.Name)
    return [bool](Get-NetAdapterBinding -Name $escaped -ComponentID ms_tcpip6).Enabled
}

function Set-IPv6Enabled($Adapter,[bool]$Enabled) {
    $escaped = [WildcardPattern]::Escape([string]$Adapter.Name)
    if ($Enabled) { Enable-NetAdapterBinding -Name $escaped -ComponentID ms_tcpip6 -Confirm:$false | Out-Null }
    else { Disable-NetAdapterBinding -Name $escaped -ComponentID ms_tcpip6 -Confirm:$false | Out-Null }
}

function Read-State {
    if (Test-Path -LiteralPath $script:StateFile) {
        $state = Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.Schema -ne 1 -or $state.Gateway -notin @('192.168.1.192','192.168.30.1')) { throw '还原备份格式异常，未修改网络。' }
        return $state
    }
    return $null
}

function Write-State($State) {
    if (-not (Test-Path -LiteralPath $StateRoot)) { throw '备份目录不存在，请从 NetworkSwitch.exe 启动。' }
    $temp = Join-Path $StateRoot 'restore.tmp'
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $script:StateFile -Force
}

function Get-DnsSnapshot($Adapter) {
    $guid = ([guid]$Adapter.InterfaceGuid).ToString('B')
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"
    $value = Get-ItemProperty -LiteralPath $key -Name NameServer -ErrorAction SilentlyContinue
    $raw = if ($null -ne $value) { [string]$value.NameServer } else { '' }
    return [pscustomobject]@{ Automatic=[string]::IsNullOrWhiteSpace($raw); Servers=@($raw -split '[,;\s]+' | Where-Object { $_ }) }
}

function Set-IPv4Dns($Adapter,$Dns) {
    $client = Get-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4
    if ($Dns.Automatic) { $client | Set-DnsClientServerAddress -ResetServerAddresses }
    else { $client | Set-DnsClientServerAddress -ServerAddresses @($Dns.Servers) }
}

function Get-OurRoutes($Adapter,$State) {
    return @(Get-NetRoute -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -in $script:Prefixes -and $_.NextHop -eq $State.Gateway -and [int]$_.RouteMetric -eq 7 -and [string]$_.Protocol -eq 'NetMgmt' })
}

function Test-Gateway([string]$Gateway) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $wait = $tcp.BeginConnect($Gateway,80,$null,$null)
        if (-not $wait.AsyncWaitHandle.WaitOne(2500)) { return $false }
        $tcp.EndConnect($wait)
        return $true
    } catch { return $false } finally { $tcp.Close() }
}

function Assert-OwnerAlive {
    if ($OwnerProcessId -eq 0) { return }
    $owner = Get-Process -Id $OwnerProcessId -ErrorAction SilentlyContinue
    if (-not $owner -or $owner.StartTime.ToUniversalTime().Ticks -ne $OwnerStartTicks) {
        throw '主窗口已经退出，取消切换。'
    }
}

function Assert-CanSwitch($Adapter) {
    # Some Mellanox drivers report HardwareInterface=false even though Windows
    # includes the adapter in -Physical. Use the OS physical-adapter inventory.
    $physicalIds = @(Get-NetAdapter -Physical | ForEach-Object { ([string]$_.InterfaceGuid).Trim('{}') })
    if ([string]$Adapter.Status -ne 'Up' -or ([string]$Adapter.InterfaceGuid).Trim('{}') -notin $physicalIds) { throw '请选择已连接的实体有线或 Wi-Fi 网卡。' }
    $addresses = @(Get-Addresses $Adapter)
    if (@($addresses | Where-Object { [string]$_.AddressState -eq 'Duplicate' }).Count -gt 0) { throw '检测到 IPv4 地址冲突。请先改为自动获取 IP，由路由器分配地址。' }
    $plan = Get-Plan $addresses
    $ipif = Get-NetIPInterface -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4
    if ([string]$ipif.Dhcp -ne 'Enabled') { throw '此网卡当前使用手动 IPv4。本工具不猜测空闲 IP；请先在 Windows 将 IP 分配改为自动(DHCP)，再切换。原设置未修改。' }
    if ($plan.Gateway -eq '192.168.30.1') { throw '已经连接 Proxy-WiFi：网关本来就是 192.168.30.1，无需切换。若要一键切换直连/代理，请连接普通家庭网络后使用本工具。' }
    $routes = @(Get-NetRoute -AddressFamily IPv4 -PolicyStore ActiveStore)
    if (@($routes | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/1','128.0.0.0/1') }).Count -gt 0) { throw '检测到现有 VPN/半默认路由。请先退出 Clash Verge、Clash Mi 或其他 VPN，再切换。' }
    $up = @(Get-NetAdapter -IncludeHidden | Where-Object { [string]$_.Status -eq 'Up' })
    $upIndices = @($up | ForEach-Object { [int]$_.ifIndex })
    $otherDefault = @($routes | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.InterfaceIndex -ne $Adapter.ifIndex -and $_.InterfaceIndex -in $upIndices })
    $otherV6 = @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceIndex -ne $Adapter.ifIndex -and $_.InterfaceIndex -in $upIndices })
    if ($otherDefault.Count -gt 0 -or $otherV6.Count -gt 0) { throw '检测到另一个正在上网的网卡或 VPN。请暂时断开另一条网络，只保留选中的网卡，避免流量绕行。' }
    $virtual = @($up | Where-Object { -not $_.HardwareInterface -and $_.Name -match 'clash|mihomo|utun|wireguard|openvpn|tailscale' })
    if ($virtual.Count -gt 0) { throw '检测到活动的 VPN/TUN 网卡，请先退出电脑上的代理或 VPN。' }
    $proxy = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($proxy -and ($proxy.ProxyEnable -eq 1 -or -not [string]::IsNullOrWhiteSpace([string]$proxy.AutoConfigURL))) { throw 'Windows 系统代理或 PAC 仍在启用，请先关闭电脑上的代理软件/系统代理。工具不会覆盖原有代理设置。' }
    if (-not (Test-Gateway $plan.Gateway)) { throw '无法连接 iStoreOS 的 192.168.1.192:80。请确认在家庭主网络且 iStoreOS 已开机。未修改网络。' }
    try { Resolve-DnsName example.com -Server $plan.Gateway -Type A -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null }
    catch { throw 'iStoreOS DNS 没有响应，未切换。请检查 OpenClash/DNS 服务。' }
    return $plan
}

function Restore-Network {
    $state = Read-State
    if ($null -eq $state) { return '没有待还原的修改，当前网络保持不变。' }
    if ($OwnerProcessId -ne 0 -and ($state.OwnerProcessId -ne $OwnerProcessId -or $state.OwnerStartTicks -ne $OwnerStartTicks)) {
        return '备份属于另一次运行，守护进程不修改它。'
    }
    $adapter = Get-AdapterById $state.AdapterId
    # Restore the previous DHCP-provided gateways before removing our override.
    foreach ($r in @($state.DefaultRoutes)) {
        $exists = @(Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 | Where-Object { $_.NextHop -eq $r.NextHop -and $_.RouteMetric -eq $r.RouteMetric })
        if ($exists.Count -eq 0) {
            New-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -NextHop $r.NextHop -RouteMetric $r.RouteMetric -PolicyStore ActiveStore | Out-Null
        }
    }
    $errors = New-Object 'System.Collections.Generic.List[string]'
    try {
        foreach ($route in @(Get-OurRoutes $adapter $state)) { $route | Remove-NetRoute -Confirm:$false }
    } catch { $errors.Add('路由：' + $_.Exception.Message) }
    try { Set-IPv4Dns $adapter $state.Dns } catch { $errors.Add('DNS：' + $_.Exception.Message) }
    try { if ((Get-IPv6Enabled $adapter) -ne [bool]$state.IPv6Enabled) { Set-IPv6Enabled $adapter ([bool]$state.IPv6Enabled) } }
    catch { $errors.Add('IPv6：' + $_.Exception.Message) }
    try { Clear-DnsClientCache } catch { }
    if ($errors.Count -gt 0) { throw ('部分还原未完成，备份已保留，可再次点击还原。' + ($errors -join '；')) }
    if (@(Get-OurRoutes $adapter $state).Count -ne 0) { throw '临时路由仍然存在，备份已保留，请再次还原。' }
    $dnsNow = Get-DnsSnapshot $adapter
    if ([bool]$dnsNow.Automatic -ne [bool]$state.Dns.Automatic -or
        ((@($dnsNow.Servers) -join ',') -ne (@($state.Dns.Servers) -join ','))) { throw 'DNS 还原校验未通过，备份已保留。' }
    if ((Get-IPv6Enabled $adapter) -ne [bool]$state.IPv6Enabled) { throw 'IPv6 还原校验未通过，备份已保留。' }
    Remove-Item -LiteralPath $script:StateFile -Force
    return '已还原切换前的上网路径、DNS 和 IPv6 设置。IPv4 地址始终由 DHCP 管理。'
}

function Enable-Proxy([string]$Id) {
    Assert-OwnerAlive
    $state = Read-State
    if ($null -ne $state) { throw '已有切换备份，请先点击一键还原，再重新代理。' }
    $adapter = Get-AdapterById $Id
    $plan = Assert-CanSwitch $adapter
    $state = [pscustomobject]@{
        Schema=1; AdapterId=([string]$adapter.InterfaceGuid).Trim('{}'); AdapterName=[string]$adapter.Name
        Gateway=$plan.Gateway; Address=$plan.Address; Started=(Get-Date).ToString('o')
        OwnerProcessId=$OwnerProcessId; OwnerStartTicks=$OwnerStartTicks
        Dns=(Get-DnsSnapshot $adapter); IPv6Enabled=(Get-IPv6Enabled $adapter)
        DefaultRoutes=@(Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 | Select-Object NextHop,RouteMetric)
    }
    Assert-OwnerAlive
    Write-State $state
    try {
        # The original DHCP address/default route are never removed. More specific
        # routes override only public IPv4 routing; connected LAN routes still win.
        # IPv6 is left unchanged.
        # Binding changes may briefly cycle the interface. Wait for the DHCP lease.
        $ready = $false
        for ($n=0; $n -lt 20; $n++) {
            $current = @(Get-Addresses $adapter | Where-Object { [string]$_.AddressState -eq 'Preferred' -and $_.IPAddress -match '^192\.168\.1\.' })
            if ($current.Count -gt 0) { $ready=$true; break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $ready) { throw '切换期间网卡没有重新获得地址。' }
        Set-IPv4Dns $adapter ([pscustomobject]@{Automatic=$false; Servers=@($plan.Gateway)})
        Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 | Remove-NetRoute -Confirm:$false
        foreach ($prefix in $script:Prefixes) {
            New-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix $prefix -NextHop $plan.Gateway -RouteMetric 7 -Protocol NetMgmt -PolicyStore ActiveStore | Out-Null
        }
        Clear-DnsClientCache
        if (@(Get-OurRoutes $adapter $state).Count -ne 1) { throw '代理路由校验失败。' }
        $dns = @(Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 | ForEach-Object { $_.ServerAddresses })
        if ($dns.Count -ne 1 -or $dns[0] -ne $plan.Gateway) { throw 'DNS 设置校验失败。' }
        if (-not (Test-Gateway $plan.Gateway)) { throw '切换后 iStoreOS 不可达。' }
        try { Resolve-DnsName example.com -Server $plan.Gateway -Type A -DnsOnly -QuickTimeout -ErrorAction Stop | Out-Null }
        catch { throw '切换后的 DNS 检查失败。' }
        return '代理已开启：经 192.168.1.192 分流，IPv4 继续自动获取。请保持此窗口运行；关闭窗口会自动还原。'
    } catch {
        $cause = $_.Exception.Message
        try { $null = Restore-Network; throw "切换失败，已自动还原。原因：$cause" }
        catch {
            if (Test-Path -LiteralPath $script:StateFile) { throw "切换失败：$cause。自动还原未完成，请点击一键还原。$($_.Exception.Message)" }
            throw
        }
    }
}

function Inspect-Network {
    $state = Read-State
    $items = @()
    foreach ($a in @(Get-NetAdapter -Physical | Where-Object { [string]$_.Status -eq 'Up' })) {
        $addresses = @(Get-Addresses $a)
        $v4 = @($addresses | Where-Object { $_.IPAddress -notlike '169.254.*' } | ForEach-Object { [string]$_.IPAddress })
        if ($v4.Count -eq 0) { continue }
        $plan = $null
        try { $plan = Get-Plan $addresses } catch { }
        $dhcp = [string](Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4).Dhcp
        $gw = @(Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.NextHop })
        $dns = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 | ForEach-Object { $_.ServerAddresses })
        $items += [pscustomobject]@{
            Id=([string]$a.InterfaceGuid).Trim('{}'); Name=[string]$a.Name; Address=($v4 -join ', ')
            Dhcp=($dhcp -eq 'Enabled'); Gateway=($gw -join ', '); Dns=($dns -join ', ')
            Target=$(if ($plan) { $plan.Gateway } else { '' }); IPv6=(Get-IPv6Enabled $a)
        }
    }
    $active=$false
    if ($state) {
        try {
            $a = Get-AdapterById $state.AdapterId
            $p = Get-Plan (Get-Addresses $a)
            $dns = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 | ForEach-Object { $_.ServerAddresses })
            $active = ([string]$a.Status -eq 'Up' -and $p.Gateway -eq $state.Gateway -and
                @(Get-OurRoutes $a $state).Count -eq 1 -and
                $dns.Count -eq 1 -and $dns[0] -eq $state.Gateway)
        } catch { $active=$false }
    }
    return [pscustomobject]@{ Adapters=@($items); HasBackup=($null -ne $state); Active=$active; BackupAdapter=$(if($state){$state.AdapterName}else{''}) }
}

if ($Mode -eq 'Library') { return }
$operationMutex = $null
$operationLock = $false
try {
    if ($Mode -in @('Proxy','Restore')) {
        $operationMutex = New-Object System.Threading.Mutex($false,'Global\MAXsGatewaySwitch-operation-v1')
        try { $operationLock = $operationMutex.WaitOne(65000) }
        catch [System.Threading.AbandonedMutexException] { $operationLock=$true }
        if (-not $operationLock) { throw '另一个网络操作仍在执行，请稍后重试。' }
    }
    $message = switch ($Mode) {
        'Proxy' { Enable-Proxy $AdapterId }
        'Restore' { Restore-Network }
        default { '已读取当前网卡；没有修改网络。' }
    }
    [pscustomobject]@{Ok=$true; Message=$message; Data=(Inspect-Network)} | ConvertTo-Json -Depth 8 -Compress
} catch {
    [pscustomobject]@{Ok=$false; Message=$_.Exception.Message; Data=$null} | ConvertTo-Json -Depth 5 -Compress
    exit 1
} finally {
    if ($operationLock) { $operationMutex.ReleaseMutex() }
    if ($operationMutex) { $operationMutex.Dispose() }
}
