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
    $script:Changes=New-Object 'System.Collections.Generic.List[string]'
    $script:Routes=New-Object System.Collections.ArrayList
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
    param($InterfaceIndex,$AddressFamily,$PolicyStore,$DestinationPrefix,$ErrorAction)
    $items=if($AddressFamily -eq 'IPv6'){@($script:V6Routes)}else{@($script:Routes.ToArray())}
    return @($items|Where-Object{($null -eq $InterfaceIndex -or $_.InterfaceIndex -eq $InterfaceIndex) -and (-not $DestinationPrefix -or $_.DestinationPrefix -eq $DestinationPrefix)})
}
function New-NetRoute {
    param($InterfaceIndex,$DestinationPrefix,$NextHop,$RouteMetric,$Protocol,$PolicyStore)
    if($script:FailRoute -and $DestinationPrefix -eq '128.0.0.0/1'){$script:FailRoute=$false;throw 'Injected second-route failure'}
    if($PolicyStore -ne 'ActiveStore'){throw 'Persistent mutation prohibited'}
    $null=$script:Routes.Add([pscustomobject]@{InterfaceIndex=$InterfaceIndex;DestinationPrefix=$DestinationPrefix;NextHop=$NextHop;RouteMetric=$RouteMetric;Protocol=$Protocol;AddressFamily='IPv4'})
    $script:Changes.Add('Route add '+$DestinationPrefix)
}
function Remove-NetRoute {
    [CmdletBinding()]param([Parameter(ValueFromPipeline=$true)]$InputObject,[switch]$Confirm)
    process{$script:Routes.Remove($InputObject);$script:Changes.Add('Route remove '+$InputObject.DestinationPrefix)}
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

Reset-Fixture
$null=Enable-Proxy $script:A.InterfaceGuid
Check ($script:Dhcp -eq 'Enabled') 'DHCP retained'
Check ($script:Addresses[0].IPAddress -eq '192.168.1.148') 'Address unchanged'
Check ($script:Routes.Count -eq 1 -and $script:Routes[0].NextHop -eq '192.168.1.192') 'Only default gateway replaced'
Check ($script:NameServer -eq '192.168.1.192') 'DNS switched'
Check ($script:V6) 'IPv6 unchanged'
Check ((Inspect-Network).Active) 'State detected'
$null=Restore-Network
Check ($script:Routes.Count -eq 1 -and $script:Routes[0].NextHop -eq '192.168.1.1') 'Original gateway restored'
Check ($script:NameServer -eq '' -and $script:Dhcp -eq 'Enabled') 'Automatic DNS and DHCP retained'
Check (-not(Test-Path $script:StateFile)) 'Recovery record cleared'