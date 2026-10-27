param([string]$Scratch = (Join-Path $env:TEMP ('NetworkSwitch-tests-' + [guid]::NewGuid().ToString('N'))))
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $Scratch -Force | Out-Null
. "$PSScriptRoot\NetworkWorker.ps1" -Mode Library -StateRoot $Scratch
$script:Passed=0
function Check([bool]$Condition,[string]$Text) { if(-not $Condition){throw "FAIL: $Text"}; $script:Passed++; Write-Output "PASS: $Text" }
function Throws([scriptblock]$Action,[string]$Text) { $thrown=$false;try{& $Action | Out-Null}catch{$thrown=$true};Check $thrown $Text }
function Reset-Fixture {
    if(Test-Path $script:StateFile){Remove-Item -LiteralPath $script:StateFile -Force}
    $script:A=[pscustomobject]@{InterfaceGuid='11111111-1111-1111-1111-111111111111';Name='Ethernet';ifIndex=10;Status='Up';HardwareInterface=$true}
    $script:Addresses=@([pscustomobject]@{IPAddress='192.168.1.148';PrefixLength=24;AddressState='Preferred'})
    $script:AllAdapters=@($script:A)
    $script:Dhcp='Enabled';$script:V6=$true;$script:NameServer='';$script:ProxyEnable=0;$script:Pac=''
    $script:GatewayWorks=$true;$script:DnsWorks=$true;$script:FailRoute=$false;$script:FailDnsRestore=$false
    $script:FailSavedRemove=$false;$script:FailRouteRead=$false
    $script:Changes=New-Object 'System.Collections.Generic.List[string]'
    $script:Routes=New-Object System.Collections.ArrayList
    $script:PersistentRoutes=New-Object System.Collections.ArrayList
    $null=$script:Routes.Add([pscustomobject]@{InterfaceIndex=10;DestinationPrefix='0.0.0.0/0';NextHop='192.168.1.1';RouteMetric=0;Protocol='Dhcp';AddressFamily='IPv4'})
    $script:V6Routes=@()
}
# Every system-facing operation used by the worker is replaced before any test.
function Get-NetAdapter { param([switch]$IncludeHidden,[switch]$Physical);return $script:AllAdapters }
function Get-NetIPAddress { param($InterfaceIndex,$AddressFamily,$ErrorAction);return $script:Addresses }
function Get-NetIPInterface { param($InterfaceIndex,$AddressFamily);return [pscustomobject]@{Dhcp=$script:Dhcp} }
function Get-NetAdapterBinding { param($Name,$ComponentID);return [pscustomobject]@{Enabled=$script:V6} }
function Disable-NetAdapterBinding { param($Name,$ComponentID,$Confirm);$script:V6=$false;$script:Changes.Add('IPv6 off') }
function Enable-NetAdapterBinding { param($Name,$ComponentID,$Confirm);$script:V6=$true;$script:Changes.Add('IPv6 on') }
function Get-NetRoute {
    [CmdletBinding()]param($InterfaceIndex,$AddressFamily,$PolicyStore,$DestinationPrefix)
    if($script:FailRouteRead){throw 'Injected route access denied'}
    $items=if($AddressFamily -eq 'IPv6'){@($script:V6Routes)}elseif($PolicyStore -eq 'PersistentStore'){@($script:PersistentRoutes.ToArray())}else{@($script:Routes.ToArray())}
    if($PolicyStore -eq 'PersistentStore' -and @($items).Count -eq 0){
        $record=[System.Management.Automation.ErrorRecord]::new([Exception]::new('Empty persistent store'),'CmdletizationQuery_NotFound',[System.Management.Automation.ErrorCategory]::ObjectNotFound,$null)
        $PSCmdlet.ThrowTerminatingError($record)
    }
    return @($items|Where-Object{($null -eq $InterfaceIndex -or $_.InterfaceIndex -eq $InterfaceIndex) -and (-not $DestinationPrefix -or $_.DestinationPrefix -eq $DestinationPrefix)})
}
function New-NetRoute {
    param($InterfaceIndex,$DestinationPrefix,$NextHop,$RouteMetric,$Protocol,$PolicyStore)
    if($script:FailRoute -and $DestinationPrefix -eq '128.0.0.0/1'){$script:FailRoute=$false;throw 'Injected second-route failure'}
    if($PolicyStore -and $PolicyStore -ne 'ActiveStore'){throw 'New-NetRoute must omit PolicyStore to save in both stores'}
    if(@($script:Routes | Where-Object { $_.InterfaceIndex -eq $InterfaceIndex -and $_.DestinationPrefix -eq $DestinationPrefix -and $_.NextHop -eq $NextHop }).Count -gt 0){throw 'Duplicate active route'}
    $null=$script:Routes.Add([pscustomobject]@{InterfaceIndex=$InterfaceIndex;DestinationPrefix=$DestinationPrefix;NextHop=$NextHop;RouteMetric=$RouteMetric;Protocol=$Protocol;AddressFamily='IPv4'})
    if(-not $PolicyStore){
        if(@($script:PersistentRoutes | Where-Object { $_.InterfaceIndex -eq $InterfaceIndex -and $_.DestinationPrefix -eq $DestinationPrefix -and $_.NextHop -eq $NextHop }).Count -gt 0){throw 'Duplicate persistent route'}
        $null=$script:PersistentRoutes.Add([pscustomobject]@{InterfaceIndex=$InterfaceIndex;DestinationPrefix=$DestinationPrefix;NextHop=$NextHop;RouteMetric=$RouteMetric;Protocol=$Protocol;AddressFamily='IPv4'})
    }
    $script:Changes.Add('Route add '+$DestinationPrefix)
}
function Remove-NetRoute {
    [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject,[switch]$Confirm,$InterfaceIndex,$DestinationPrefix,$NextHop,$RouteMetric,$Protocol,$PolicyStore,$AddressFamily)
    process{
        if($PolicyStore -eq 'PersistentStore' -and $script:FailSavedRemove){throw 'Injected persistent-route removal failure'}
        if($InputObject){$script:Routes.Remove($InputObject)}
        else{
            $table=$script:Routes
            if($PolicyStore -eq 'PersistentStore'){$table=$script:PersistentRoutes}
            foreach($r in @($table.ToArray() | Where-Object { $_.InterfaceIndex -eq $InterfaceIndex -and $_.DestinationPrefix -eq $DestinationPrefix -and $_.NextHop -eq $NextHop -and $_.RouteMetric -eq $RouteMetric -and $_.Protocol -eq $Protocol })){$table.Remove($r)}
        }
        $script:Changes.Add('Route remove '+$DestinationPrefix)
    }
}
function Get-DnsClientServerAddress {
    param($InterfaceIndex,$AddressFamily)
    $servers=if($script:NameServer){@($script:NameServer -split ',')}else{@('192.168.1.1')}
    return [pscustomobject]@{ServerAddresses=$servers;InterfaceIndex=$InterfaceIndex;AddressFamily=$AddressFamily}
}
function Set-DnsClientServerAddress {
    [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject,[switch]$ResetServerAddresses,$ServerAddresses)
    process{
        if($InputObject.AddressFamily -ne 'IPv4'){throw 'Unexpected DNS family'}
        if($ResetServerAddresses -and $script:FailDnsRestore){throw 'Injected restore failure'}
        $script:NameServer=if($ResetServerAddresses){''}else{@($ServerAddresses)-join ','}
        $script:Changes.Add('DNS '+$script:NameServer)
    }
}
function Get-ItemProperty {
    param($LiteralPath,$Path,$Name,$ErrorAction)
    if($LiteralPath){return [pscustomobject]@{NameServer=$script:NameServer}}
    return [pscustomobject]@{ProxyEnable=$script:ProxyEnable;AutoConfigURL=$script:Pac}
}
function Clear-DnsClientCache { }
function Test-Gateway {param($Gateway);return $script:GatewayWorks}
function Resolve-DnsName {param($Name,$Server,$Type,[switch]$DnsOnly,[switch]$QuickTimeout,$ErrorAction);if(-not $script:DnsWorks){throw 'Injected DNS timeout'};return [pscustomobject]@{IPAddress='93.184.216.34'}}

function Simulate-Reboot {
    # Windows discards ActiveStore and loads saved routes into the new store.
    $script:Routes.Clear()
    $null=$script:Routes.Add([pscustomobject]@{InterfaceIndex=10;DestinationPrefix='0.0.0.0/0';NextHop='192.168.1.1';RouteMetric=0;Protocol='Dhcp';AddressFamily='IPv4'})
    foreach($r in $script:PersistentRoutes.ToArray()){$null=$script:Routes.Add($r.PSObject.Copy())}
}

Reset-Fixture
$null=Enable-Proxy $script:A.InterfaceGuid
$beforeReboot=Get-Content $script:StateFile -Raw
Simulate-Reboot
Check ((Inspect-Network).Active) 'Reboot keeps proxy routes paired with the saved DNS without running repair'
Check ((Get-Content $script:StateFile -Raw) -eq $beforeReboot) 'Reboot preserves original recovery data'
$null=Restore-Network
Check ($script:PersistentRoutes.Count -eq 0) 'Restore removes persistent routes'
Simulate-Reboot
Check ($script:Routes.Count -eq 1 -and $script:NameServer -eq '') 'Restore then reboot does not resurrect proxy routes or DNS'

Reset-Fixture
$null=Enable-Proxy $script:A.InterfaceGuid
Check ($script:Dhcp -eq 'Enabled') 'DHCP retained'
Check ($script:Addresses[0].IPAddress -eq '192.168.1.148') 'Address unchanged'
Check ($script:Routes.Count -eq 3 -and $script:Routes[0].NextHop -eq '192.168.1.1') 'DHCP default preserved alongside two proxy routes'
Check ($script:NameServer -eq '192.168.1.192') 'DNS switched'
Check ($script:V6) 'IPv6 unchanged'
Check ((Inspect-Network).Active) 'State detected'
$null=Restore-Network
Check ($script:Routes.Count -eq 1 -and $script:Routes[0].NextHop -eq '192.168.1.1') 'Original gateway restored'
Check ($script:NameServer -eq '' -and $script:Dhcp -eq 'Enabled') 'Automatic DNS and DHCP retained'
Check (-not(Test-Path $script:StateFile)) 'Recovery record cleared'
Reset-Fixture
$null=Enable-Proxy $script:A.InterfaceGuid
$stateBefore=Get-Content $script:StateFile -Raw
$script:Routes.Clear()
$null=$script:Routes.Add([pscustomobject]@{InterfaceIndex=10;DestinationPrefix='0.0.0.0/0';NextHop='192.168.1.1';RouteMetric=0;Protocol='Dhcp';AddressFamily='IPv4'})
$script:NameServer=''
Check (-not (Inspect-Network).Active) 'Lease reset detected'
$null=Repair-Network
Check ((Inspect-Network).Active) 'Lease reset repaired'
Check ($script:Routes.Count -eq 3) 'Repair preserves DHCP route'
Check ((Get-Content $script:StateFile -Raw) -eq $stateBefore) 'Original restore snapshot retained'
$script:Changes.Clear()
$null=Repair-Network
Check ($script:Changes.Count -eq 0) 'Healthy maintenance does not mutate network'
$null=Restore-Network
$script:Changes.Clear()
$null=Repair-Network
Check ($script:Changes.Count -eq 0) 'Restore stops maintenance'

Reset-Fixture
$script:FailRoute=$true
Throws { Enable-Proxy $script:A.InterfaceGuid } 'Second route failure rolls back'
Check ($script:Routes.Count -eq 1 -and $script:NameServer -eq '') 'Partial enable restores routes and DNS'

Reset-Fixture
$null=Enable-Proxy $script:A.InterfaceGuid
$script:Addresses=@([pscustomobject]@{IPAddress='192.168.99.5';PrefixLength=24;AddressState='Preferred'})
$script:Routes.Clear()
$null=Repair-Network
Check ($script:Routes.Count -eq 0) 'Changed network does not receive old gateway'
Check ($script:NameServer -eq '' -and -not(Test-Path $script:StateFile)) 'Changed network releases DNS and intent'

Reset-Fixture
$null=Enable-Proxy $script:A.InterfaceGuid
$vpn=[pscustomobject]@{InterfaceGuid='22222222-2222-2222-2222-222222222222';Name='utun';ifIndex=59;Status='Up';HardwareInterface=$false}
$script:AllAdapters=@($script:A,$vpn)
$null=$script:Routes.Add([pscustomobject]@{InterfaceIndex=59;DestinationPrefix='0.0.0.0/0';NextHop='198.20.0.2';RouteMetric=0;Protocol='NetMgmt';AddressFamily='IPv4'})
$null=Repair-Network
Check (@($script:Routes | Where-Object InterfaceIndex -eq 59).Count -eq 1) 'VPN route untouched'
Check (-not(Test-Path $script:StateFile)) 'VPN conflict releases proxy intent'

Reset-Fixture
$null=Enable-Proxy $script:A.InterfaceGuid
$script:A.Status='Disconnected'
$script:Changes.Clear()
$null=Repair-Network
Check ($script:Changes.Count -eq 0 -and (Test-Path $script:StateFile)) 'Disconnected adapter waits without losing intent'
$script:A.Status='Up'
$script:Routes.RemoveAt(2)
$script:FailRoute=$true
Throws { Repair-Network } 'Repair failure reported'
Check ($script:Routes.Count -eq 1 -and $script:NameServer -eq '') 'Repair failure rolls back to DHCP'

Reset-Fixture
$null=Enable-Proxy $script:A.InterfaceGuid
$script:FailDnsRestore=$true
Throws { Restore-Network } 'Restore DNS failure reported'
Check (Test-Path $script:StateFile) 'Failed restore preserves recovery record'
$script:FailDnsRestore=$false
$null=Restore-Network
Check (-not(Test-Path $script:StateFile)) 'Restore retry succeeds'

Reset-Fixture
$null=Enable-Proxy $script:A.InterfaceGuid
$state=Read-State
$state.Schema=1
$state.PSObject.Properties.Remove('RoutePrefixes')
Write-State $state
$script:Routes.Clear()
$script:PersistentRoutes.Clear()
$null=$script:Routes.Add([pscustomobject]@{InterfaceIndex=10;DestinationPrefix='0.0.0.0/0';NextHop='192.168.1.192';RouteMetric=7;Protocol='NetMgmt';AddressFamily='IPv4'})
$script:Changes.Clear()
$null=Repair-Network
Check ($script:Changes.Count -eq 0) 'Legacy backup not silently migrated'
$null=Restore-Network
Check ($script:Routes.Count -eq 1 -and $script:Routes[0].NextHop -eq '192.168.1.1' -and $script:NameServer -eq '') 'Legacy backup restores old default and DNS'

Reset-Fixture
$null=$script:Routes.Add([pscustomobject]@{InterfaceIndex=23;DestinationPrefix='10.0.0.0/24';NextHop='0.0.0.0';RouteMetric=256;Protocol='Local';AddressFamily='IPv4'})
$null=Enable-Proxy $script:A.InterfaceGuid
$null=Repair-Network
$null=Restore-Network
Check (@($script:Routes | Where-Object InterfaceIndex -eq 23).Count -eq 1) 'Private 40G route preserved'

# A failed restore must never become an instruction to enable proxy again.
Reset-Fixture
$null=Enable-Proxy $script:A.InterfaceGuid
$script:FailDnsRestore=$true
Throws { Restore-Network } 'Interrupted restore reported'
$script:Changes.Clear()
$null=Repair-Network
Check ($script:Changes.Count -eq 0 -and $script:Routes.Count -eq 1) 'Repair cannot re-enable routes after failed restore'
Check (Test-Path $script:StateFile) 'Interrupted restore keeps original recovery snapshot'
$script:FailDnsRestore=$false
$null=Restore-Network
Check ($script:NameServer -eq '' -and -not(Test-Path $script:StateFile)) 'Interrupted restore can be retried manually'

# An unreachable web panel or DNS timeout is not a local configuration change.
Reset-Fixture
$null=Enable-Proxy $script:A.InterfaceGuid
$stateBefore=Get-Content $script:StateFile -Raw
$script:GatewayWorks=$false
$script:DnsWorks=$false
$script:Changes.Clear()
1..24 | ForEach-Object { $null=Repair-Network }
Check ($script:Changes.Count -eq 0) 'Repeated gateway and DNS timeouts do not toggle healthy routes'
Check ((Inspect-Network).Active -and (Get-Content $script:StateFile -Raw) -eq $stateBefore) 'Transient outage preserves mode and original backup'

# Actual worker Inspect remains read-only even when DHCP removes the override.
$script:Routes.RemoveAt(2)
$script:NameServer=''
$script:Changes.Clear()
1..24 | ForEach-Object { $null=Inspect-Network }
Check ($script:Changes.Count -eq 0 -and $script:Routes.Count -eq 2 -and $script:NameServer -eq '') 'Repeated Inspect never repairs missing configuration'
Check ((Get-Content $script:StateFile -Raw) -eq $stateBefore) 'Read-only polling preserves the recovery backup'
$script:GatewayWorks=$true
$script:DnsWorks=$true
$null=Repair-Network
Check ((Inspect-Network).Active) 'Explicit repair still restores missing configuration'
$null=Restore-Network

# Repair either missing half of the saved/current pair without duplicate adds.
Reset-Fixture
$null=Enable-Proxy $script:A.InterfaceGuid
$script:PersistentRoutes.RemoveAt(0)
Check ((Inspect-Network).Active -and -not (Inspect-Network).PersistentReady) 'Active-only route is not reported as reboot-ready'
$null=Repair-Network
Check ($script:PersistentRoutes.Count -eq 2 -and $script:Routes.Count -eq 3) 'Manual repair recreates missing saved route without duplicate active route'
Simulate-Reboot
Check ((Inspect-Network).Active) 'Repaired persistent route survives reboot'
$null=Restore-Network

Reset-Fixture
$script:FailRoute=$true
Throws { Enable-Proxy $script:A.InterfaceGuid } 'Partial persistent enable fails safely'
Check ($script:PersistentRoutes.Count -eq 0) 'Partial enable rollback removes saved route'
Simulate-Reboot
Check ($script:Routes.Count -eq 1 -and $script:NameServer -eq '') 'Failed enable cannot reactivate on reboot'

Reset-Fixture
$null=Enable-Proxy $script:A.InterfaceGuid
$script:FailSavedRemove=$true
Throws { Restore-Network } 'Persistent route removal failure reported'
Check ((Read-State).RestorePending -and $script:PersistentRoutes.Count -eq 2) 'Failed saved-route removal retains pending recovery record'
$script:Changes.Clear()
$null=Repair-Network
Check ($script:Changes.Count -eq 0) 'Repair cannot undo a pending persistent restore'
Simulate-Reboot
$script:FailSavedRemove=$false
$null=Restore-Network
Simulate-Reboot
Check ($script:PersistentRoutes.Count -eq 0 -and $script:Routes.Count -eq 1) 'Retry restore after reboot clears both route stores'

Reset-Fixture
$null=Enable-Proxy $script:A.InterfaceGuid
$legacy=Read-State
$legacy.Schema=1
Write-State $legacy
$script:PersistentRoutes.Clear()
Simulate-Reboot
$script:Changes.Clear()
$null=Repair-Network
Check ((Inspect-Network).LegacyState -and $script:Changes.Count -eq 0) 'Old temporary state after reboot requires explicit restore and enable'
$null=Restore-Network
Check ($script:NameServer -eq '' -and -not(Test-Path $script:StateFile)) 'Legacy reboot residue can restore original DNS'
$null=Enable-Proxy $script:A.InterfaceGuid
Check ((Read-State).Schema -eq 2 -and (Inspect-Network).PersistentReady) 'Fresh enable after legacy restore saves schema 2'
$null=Restore-Network

Reset-Fixture
$script:NameServer='192.168.1.1,1.1.1.1'
$null=Enable-Proxy $script:A.InterfaceGuid
Simulate-Reboot
$null=Restore-Network
Check ($script:NameServer -eq '192.168.1.1,1.1.1.1') 'Original custom DNS restored after reboot'

Reset-Fixture
$null=$script:PersistentRoutes.Add([pscustomobject]@{InterfaceIndex=23;DestinationPrefix='10.0.0.0/24';NextHop='0.0.0.0';RouteMetric=256;Protocol='NetMgmt';AddressFamily='IPv4'})
$null=Enable-Proxy $script:A.InterfaceGuid
$null=Restore-Network
Check ($script:PersistentRoutes.Count -eq 1 -and $script:PersistentRoutes[0].InterfaceIndex -eq 23) 'Unrelated saved private route is preserved'

Reset-Fixture
$null=$script:PersistentRoutes.Add([pscustomobject]@{InterfaceIndex=10;DestinationPrefix='0.0.0.0/1';NextHop='192.168.1.192';RouteMetric=7;Protocol='NetMgmt';AddressFamily='IPv4'})
Throws { Enable-Proxy $script:A.InterfaceGuid } 'Pre-existing saved half-route is not claimed as tool-owned'
Check ($script:Changes.Count -eq 0 -and -not(Test-Path $script:StateFile)) 'Saved-route conflict makes no network changes'

Reset-Fixture
$script:FailRouteRead=$true
Throws { Enable-Proxy $script:A.InterfaceGuid } 'Route read access error is not mistaken for an empty table'
Check ($script:Changes.Count -eq 0) 'Route query failure makes no network changes'

Write-Output "TOTAL: $script:Passed passed"
