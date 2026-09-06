# =============================================================================
# windows-dc-ipv6.ps1
# Dual-stack: habilita y configura IPv6 en el Controlador de Dominio YA
# PROMOVIDO, sin re-ejecutar la promocion de AD DS ni tocar nada de IPv4.
#
# windows-dc.ps1 (FASE 1) explicitamente DESHABILITA IPv6 con
# Disable-NetAdapterBinding, y ademas hace "exit 0" muy al inicio si AD DS
# ya esta instalado -- por eso cualquier cambio de red agregado ahi NUNCA
# se ejecutaria en un DC que ya funciona. Este script es un paso NUEVO e
# independiente, pensado para correrse UNA vez asi:
#
#   vagrant provision --provision-with ipv6-dc windows-dc
#
# (el provisioner tiene run: "never", por lo que jamas se dispara solo con
#  "vagrant up" o "vagrant provision" sin el --provision-with explicito)
# =============================================================================

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Write-Host ""
Write-Host "============================================================"
Write-Host " DUAL-STACK - Configuracion IPv6 del Controlador de Dominio"
Write-Host "============================================================"
Write-Host ""

$DC_IP6      = if ($env:DC_IP6)      { $env:DC_IP6 }      else { "fd00:10::20" }
$GATEWAY6    = if ($env:GATEWAY6)    { $env:GATEWAY6 }    else { "fd00:10::1" }
$PREFIX6     = 64
$DOMAIN      = if ($env:DOMAIN)      { $env:DOMAIN }      else { "empresa.local" }

Write-Host "IPv6 DC   : $DC_IP6/$PREFIX6"
Write-Host "Gateway6  : $GATEWAY6"
Write-Host ""


# =============================================================================
# IDENTIFICAR ADAPTADOR (misma logica que windows-dc.ps1: el que no es NAT)
# =============================================================================

Write-Host "[1/5] Identificando adaptador de red..."

$adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
$bridgeAdapter = $null

foreach ($adapter in $adapters) {
    $ips = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    foreach ($ip in $ips) {
        if ($ip.IPAddress -notlike "10.0.2.*") {
            $bridgeAdapter = $adapter
            break
        }
    }
    if ($bridgeAdapter) { break }
}

if (-not $bridgeAdapter) {
    $bridgeAdapter = $adapters | Sort-Object InterfaceIndex -Descending | Select-Object -First 1
}

if (-not $bridgeAdapter) {
    throw "No se pudo identificar el adaptador de red."
}

$ifIndex = $bridgeAdapter.ifIndex
$ifAlias = $bridgeAdapter.Name

Write-Host "Adaptador seleccionado : $ifAlias"
Write-Host "InterfaceIndex         : $ifIndex"


# =============================================================================
# RE-HABILITAR IPv6 (windows-dc.ps1 lo habia deshabilitado)
# =============================================================================

Write-Host ""
Write-Host "[2/5] Re-habilitando IPv6 en el adaptador..."

Enable-NetAdapterBinding `
    -Name $ifAlias `
    -ComponentID ms_tcpip6 `
    -ErrorAction SilentlyContinue

Start-Sleep -Seconds 3
Write-Host "IPv6 habilitado en $ifAlias."


# =============================================================================
# ASIGNAR IPv6 ESTATICA (idempotente: limpia una direccion previa igual antes)
# =============================================================================

Write-Host ""
Write-Host "[3/5] Configurando direccion IPv6 estatica..."

# Quitar una asignacion previa identica si ya existiera (para poder re-correr
# este script sin errores de "direccion duplicada")
Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $DC_IP6 } |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

# Quitar ruta por defecto IPv6 previa del adaptador (si existe) antes de re-crearla
Get-NetRoute -InterfaceIndex $ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue |
    Where-Object { $_.DestinationPrefix -eq "::/0" } |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

New-NetIPAddress `
    -InterfaceIndex $ifIndex `
    -AddressFamily IPv6 `
    -IPAddress $DC_IP6 `
    -PrefixLength $PREFIX6 `
    -DefaultGateway $GATEWAY6 `
    -ErrorAction Stop | Out-Null

Write-Host "IPv6 configurada: $DC_IP6/$PREFIX6 via $GATEWAY6"

# Ruta hacia VLAN 30 (gestion) tambien por IPv6, igual que ya existe para IPv4
try {
    New-NetRoute `
        -DestinationPrefix "fd00:30::/64" `
        -InterfaceIndex $ifIndex `
        -AddressFamily IPv6 `
        -NextHop $GATEWAY6 `
        -PolicyStore ActiveStore `
        -ErrorAction SilentlyContinue | Out-Null
    Write-Host "Ruta fd00:30::/64 -> $GATEWAY6 configurada."
}
catch {
    Write-Warning "No se pudo crear la ruta IPv6 hacia VLAN 30 (puede que ya exista)."
}


# =============================================================================
# DNS: agregar IPv6 (::1) SIN QUITAR el DNS IPv4 actual (127.0.0.1)
# =============================================================================

Write-Host ""
Write-Host "[4/5] Ajustando DNS del adaptador para dual-stack..."

# Set-DnsClientServerAddress reemplaza TODA la lista del adaptador, asi que
# leemos primero lo que ya esta configurado en IPv4 para no perderlo.
$existingV4Dns = (Get-DnsClientServerAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
if (-not $existingV4Dns -or $existingV4Dns.Count -eq 0) {
    $existingV4Dns = @("127.0.0.1")
}

$combinedDns = $existingV4Dns + @("::1")

Set-DnsClientServerAddress `
    -InterfaceIndex $ifIndex `
    -ServerAddresses $combinedDns `
    -ErrorAction SilentlyContinue

Write-Host "DNS del adaptador ahora incluye: $($combinedDns -join ', ')"


# =============================================================================
# REGISTROS AAAA (opcional, no critico si el rol DNS aun no acepta el cambio)
# =============================================================================

Write-Host ""
Write-Host "[5/5] Registrando AAAA en el DNS del dominio (best-effort)..."

try {
    Import-Module DnsServer -ErrorAction Stop

    $zone = $DOMAIN

    $records = @{
        "dc-empresa" = "fd00:10::20"
        "web-server" = "fd00:10::10"
    }

    foreach ($name in $records.Keys) {
        $addr = $records[$name]
        $exists = Get-DnsServerResourceRecord -ZoneName $zone -Name $name -RRType AAAA -ErrorAction SilentlyContinue |
            Where-Object { $_.RecordData.IPv6Address.IPAddressToString -eq $addr }

        if (-not $exists) {
            Add-DnsServerResourceRecordAAAA `
                -ZoneName $zone `
                -Name $name `
                -IPv6Address $addr `
                -ErrorAction SilentlyContinue
            Write-Host "  AAAA agregado: $name.$zone -> $addr"
        } else {
            Write-Host "  AAAA ya existia: $name.$zone -> $addr"
        }
    }
}
catch {
    Write-Warning "No se pudieron crear los registros AAAA automaticamente (revisar manualmente en el rol DNS)."
}


# =============================================================================
# VERIFICACION
# =============================================================================

Write-Host ""
Write-Host "Verificando conectividad IPv6..."

try {
    $ping = Test-Connection -ComputerName $GATEWAY6 -Count 2 -ErrorAction SilentlyContinue
    if ($ping) {
        Write-Host "Gateway IPv6 ($GATEWAY6) responde correctamente."
    } else {
        Write-Warning "Gateway IPv6 ($GATEWAY6) no respondio. Revisar el router y el bridge de VirtualBox."
    }
}
catch {
    Write-Warning "No se pudo probar conectividad IPv6 hacia el gateway."
}

Write-Host ""
Write-Host "============================================================"
Write-Host " DUAL-STACK IPv6 CONFIGURADO EN EL DC (IPv4 no fue modificado)"
Write-Host "============================================================"
Write-Host ""
