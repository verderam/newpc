#Requires -Version 5.1
<#
.SYNOPSIS
    Configurazione iniziale di Windows 11 Pro.

.DESCRIPTION
    - Abilita Desktop remoto e aggiunge Everyone al gruppo Utenti desktop remoto.
    - Installa Chocolatey con WinGet e le applicazioni richieste con WinGet/Chocolatey.
    - Usa la sottocartella cache accanto allo script e poi ripristina le cache predefinite.
    - Installa gli eventuali MSI nella sottocartella sw con /passive /norestart.
    - Configura le associazioni predefinite per nuovi utenti tramite DISM e per tutti tramite criterio.
    - Configura subito l'utente corrente tramite SetUserFTA.exe, se presente in bin o C:\bin.
    - Rinomina il computer W-XXXXXX usando gli ultimi 6 caratteri del primo MAC fisico.
    - Copia bin, apps e settings\softwarepolicy.ini, aggiorna la PATH e crea gli account adm/usr.
    - Imposta a 9 tentativi la soglia di blocco degli account locali.
    - Disabilita la richiesta di consenso UAC per gli amministratori, lasciando UAC attivo.
    - Rimuove le app Store consumer per tutti gli utenti e dal provisioning dei nuovi utenti.
    - Disabilita servizi non essenziali con attività in background su disco e memoria.
    - Attiva Telnet Client e .NET Framework 3.5; con -InstallRSAT installa tutte le funzionalità RSAT disponibili.
    - Configura condivisioni amministrative, WinRM e LiteManager Server per amministratori.
    - Applica preimpostazioni uniformi alle applicazioni e ai profili utente.
    - Configura Open-Shell, desktop, taskbar, servizi, Windows Update e risparmio energia.
    - Applica tweak di sistema e utente per AutoPlay, notifiche, reattività ed effetti grafici.
    - Applica le preferenze all'utente corrente e al profilo predefinito per i nuovi utenti.
    - Sopprime animazione, privacy, benvenuto e richieste OOBE al primo accesso utente.
    - Offre al termine Chris Titus WinUtil e attende fino a 20 minuti; default: non eseguire.
    - Esporta i pacchetti installati in winget.json nella cartella corrente.
    - Svuota %TEMP% e la cache Delivery Optimization, ignorando gli elementi bloccati.

.NOTES
    Eseguire da Windows PowerShell 5.1 con privilegi di amministratore,
    nell'account per il quale si vogliono impostare le associazioni correnti.

    Per le associazioni dell'utente corrente serve SetUserFTA.exe:
    inserirlo nella sottocartella bin accanto allo script oppure in C:\bin.
    Senza questo strumento le associazioni degli altri utenti vengono applicate al
    successivo accesso tramite criterio, ma non subito a quello corrente.

    LiteManager richiede settings\LiteManagerServer.reg, esportato da un Server di
    riferimento con WinNT security, Administrators con controllo completo, nessun
    fallback password e nessuna richiesta di autorizzazione all'utente.

    I file facoltativi in settings\user-presets replicano la struttura del profilo:
    esempio settings\user-presets\AppData\Roaming\Notepad++\config.xml.
    Vengono distribuiti agli utenti esistenti e al profilo Default.

    Per .NET 3.5 offline usare: -NetFx3Source 'D:\sources\sxs'.
    RSAT non viene installato per default; per installarlo usare -InstallRSAT.

    Le richieste di password scadono dopo 10 secondi: senza input vengono creati
    account senza password e con cambio obbligatorio al primo accesso. Se viene
    immessa una password, questa non scade. Non viene installato o usato WMIC.

    WinUtil viene proposto al termine: dopo 10 secondi il default è non eseguirlo.
    Se avviato, lo script attende fino a 20 minuti; allo scadere WinUtil resta aperto.
    Usare -RunChrisTitus per avviarlo senza conferma oppure -SkipChrisTitus per saltarlo.

    ATTENZIONE: l'accesso RDP a Everyone, l'elevazione amministrativa senza consenso
    e l'esecuzione di codice remoto riducono la sicurezza del sistema.
#>
param(
    [switch]$SkipChrisTitus,
    [switch]$RunChrisTitus,
    [switch]$InstallRSAT,
    [string]$SetUserFTAPath,
    [string]$NetFx3Source
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$WorkDirectory = Join-Path $env:ProgramData 'NewPC'
$LogDirectory = Join-Path $WorkDirectory 'logs'
$null = New-Item -Path $LogDirectory -ItemType Directory -Force
$LogPath = Join-Path $LogDirectory ('Setup-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
$script:Failures = @()
$script:WingetExe = $null
$script:ChocoExe = $null
$script:WingetCacheConfigured = $false
$script:ChocoCacheConfigured = $false
$CacheDirectory = Join-Path $PSScriptRoot 'cache'

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = '[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Level, $Message
    switch ($Level) {
        'OK'    { Write-Host $line -ForegroundColor Green }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
}

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    Write-Log "Inizio: $Name"
    try {
        & $Action
        Write-Log "Completato: $Name" -Level OK
    }
    catch {
        $script:Failures += $Name
        Write-Log ("{0}: {1}" -f $Name, $_.Exception.Message) -Level ERROR
    }
}

function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int[]]$SuccessCodes = @(0)
    )

    & $FilePath @Arguments 2>&1 | ForEach-Object {
        if ($null -ne $_) { Write-Log ([string]$_) }
    }
    $exitCode = $LASTEXITCODE
    if ($SuccessCodes -notcontains $exitCode) {
        throw "$FilePath terminato con codice $exitCode (0x$('{0:X8}' -f $exitCode))."
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-AccountNameFromSid {
    param([string]$Sid)
    $securityIdentifier = New-Object System.Security.Principal.SecurityIdentifier($Sid)
    return $securityIdentifier.Translate([System.Security.Principal.NTAccount]).Value
}

function Enable-RemoteDesktopForEveryone {
    $terminalServerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    Set-ItemProperty -Path $terminalServerKey -Name 'fDenyTSConnections' -Type DWord -Value 0

    $firewallRules = @(Get-NetFirewallRule -Name 'RemoteDesktop*' -ErrorAction SilentlyContinue)
    if ($firewallRules.Count -eq 0) {
        throw 'Regole firewall Desktop remoto non trovate.'
    }
    $firewallRules | Enable-NetFirewallRule

    # SID localizzabili: S-1-5-32-555 = Remote Desktop Users; S-1-1-0 = Everyone.
    $rdpGroup = Get-LocalGroup -SID 'S-1-5-32-555'
    $everyoneName = Get-AccountNameFromSid -Sid 'S-1-1-0'
    $memberSids = @(Get-LocalGroupMember -Group $rdpGroup.Name | ForEach-Object { $_.SID.Value })
    if ($memberSids -notcontains 'S-1-1-0') {
        Add-LocalGroupMember -Group $rdpGroup.Name -Member $everyoneName
    }

    Write-Log "Desktop remoto abilitato; $everyoneName aggiunto a $($rdpGroup.Name)." -Level OK
}

function Set-ComputerNameFromMac {
    # Prima scheda fisica secondo ifIndex; vengono escluse le schede virtuali.
    $adapter = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Sort-Object ifIndex |
        Select-Object -First 1
    if ($null -eq $adapter -or [string]::IsNullOrWhiteSpace($adapter.MacAddress)) {
        throw 'Nessuna scheda di rete fisica con indirizzo MAC trovata.'
    }

    $macHex = ($adapter.MacAddress -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    if ($macHex.Length -lt 6) {
        throw "MAC non valido per la scheda $($adapter.Name): $($adapter.MacAddress)"
    }
    $newName = 'W-' + $macHex.Substring($macHex.Length - 6, 6)

    $pendingName = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
    if ($env:COMPUTERNAME -ieq $newName -or $pendingName -ieq $newName) {
        Write-Log "Nome computer già corretto o già impostato per il prossimo riavvio: $newName"
        return
    }

    Rename-Computer -NewName $newName -Force
    Write-Log "Computer rinominato $newName usando la scheda $($adapter.Name) ($($adapter.MacAddress)). Riavvio necessario." -Level WARN
}

function Copy-OptionalDirectory {
    param(
        [string]$Name,
        [string]$Destination
    )

    $source = Join-Path $PSScriptRoot $Name
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        Write-Log "Cartella opzionale non presente: $source"
        return
    }

    $null = New-Item -Path $Destination -ItemType Directory -Force
    Write-Log "Robocopy: $source -> $Destination"
    & "$env:SystemRoot\System32\robocopy.exe" $source $Destination /E /COPY:DAT /DCOPY:T /R:2 /W:2 /XJ /NP /NFL /NDL /NJH /NJS 2>&1 |
        ForEach-Object { if ($null -ne $_) { Write-Log ([string]$_) } }
    $code = $LASTEXITCODE
    if ($code -gt 7) {
        throw "Robocopy per $Name terminato con codice $code."
    }
    Write-Log "Copia $Name completata (Robocopy: $code)." -Level OK
}

function Copy-SoftwarePolicyFile {
    $source = Join-Path $PSScriptRoot 'settings\softwarepolicy.ini'
    $destinationDirectory = 'C:\Windows\softwarepolicy'
    $destination = Join-Path $destinationDirectory 'softwarepolicy.ini'

    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "File di configurazione non trovato: $source"
    }

    $null = New-Item -Path $destinationDirectory -ItemType Directory -Force
    Copy-Item -LiteralPath $source -Destination $destination -Force
    Write-Log "Copiato $source in $destination." -Level OK
}

function Add-SystemPathEntry {
    param([string]$Entry)

    $environmentKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', $true)
    if ($null -eq $environmentKey) {
        throw 'Impossibile aprire in scrittura la chiave della PATH di sistema.'
    }
    $machinePath = [string]$environmentKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $pathKind = $environmentKey.GetValueKind('Path')
    $entries = @($machinePath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $normalizeEntry = {
        param([string]$Value)
        $text = $Value.Trim()
        if ($text.Length -gt 3) { $text = $text.TrimEnd('\') }
        return $text
    }
    $normalizedEntry = & $normalizeEntry $Entry
    $normalizedEntries = @($entries | ForEach-Object { & $normalizeEntry $_ })

    if ($normalizedEntries -notcontains $normalizedEntry) {
        $newPath = (($entries + $Entry) -join ';')
        $environmentKey.SetValue('Path', $newPath, $pathKind)
        Write-Log "$Entry aggiunto alla PATH di sistema." -Level OK
    }
    else {
        Write-Log "$Entry già presente nella PATH di sistema."
    }

    $currentPathEntries = @($env:Path -split ';' | ForEach-Object { & $normalizeEntry $_ } | Where-Object { $_ })
    if ($currentPathEntries -notcontains $normalizedEntry) {
        $env:Path = "$env:Path;$Entry"
    }
    $environmentKey.Dispose()
}

function Read-SecureStringWithTimeout {
    param(
        [string]$Prompt,
        [int]$TimeoutSeconds = 10
    )

    if ([Console]::IsInputRedirected) {
        Write-Log "$Prompt input non interattivo: uso il default senza password." -Level WARN
        return $null
    }

    Write-Host "$Prompt (Invio per confermare; default senza password tra $TimeoutSeconds secondi): " -NoNewline
    $securePassword = New-Object System.Security.SecureString
    $started = [DateTime]::UtcNow
    $timedOut = $true

    while (([DateTime]::UtcNow - $started).TotalSeconds -lt $TimeoutSeconds) {
        if (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds 50
            continue
        }

        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Enter) {
            $timedOut = $false
            break
        }
        if ($key.Key -eq [ConsoleKey]::Backspace) {
            if ($securePassword.Length -gt 0) {
                $securePassword.RemoveAt($securePassword.Length - 1)
                Write-Host "`b `b" -NoNewline
            }
            continue
        }
        if (-not [char]::IsControl($key.KeyChar)) {
            $securePassword.AppendChar($key.KeyChar)
            Write-Host '*' -NoNewline
        }
    }
    Write-Host ''

    if ($timedOut) {
        Write-Log 'Timeout inserimento password: uso il default senza password.' -Level WARN
        return $null
    }
    if ($securePassword.Length -eq 0) {
        return $null
    }
    return $securePassword
}

function Read-YesNoWithTimeout {
    param(
        [string]$Prompt,
        [bool]$Default = $false,
        [int]$TimeoutSeconds = 10
    )

    if ([Console]::IsInputRedirected) { return $Default }
    Write-Host "$Prompt Premere S/N oppure Invio; default $Default tra $TimeoutSeconds secondi: " -NoNewline
    $started = [DateTime]::UtcNow

    while (([DateTime]::UtcNow - $started).TotalSeconds -lt $TimeoutSeconds) {
        if (-not [Console]::KeyAvailable) {
            Start-Sleep -Milliseconds 50
            continue
        }
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq [ConsoleKey]::Enter) { Write-Host ''; return $Default }
        switch ($key.KeyChar) {
            { $_ -in @('s', 'S', 'y', 'Y') } { Write-Host ''; return $true }
            { $_ -in @('n', 'N') } { Write-Host ''; return $false }
        }
    }
    Write-Host ''
    Write-Log "Timeout conferma: uso il default $Default." -Level WARN
    return $Default
}

function Set-LocalAccountPasswordState {
    param(
        [string]$Name,
        [bool]$NeverExpires,
        [bool]$MustChangeAtNextLogon
    )

    Set-LocalUser -Name $Name -PasswordNeverExpires $NeverExpires
    $account = [ADSI]"WinNT://./$Name,user"
    $account.PasswordExpired = $(if ($MustChangeAtNextLogon) { 1 } else { 0 })
    $account.SetInfo()
}

function Ensure-LocalAccount {
    param(
        [string]$Name,
        [switch]$Administrator
    )

    $user = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $user) {
        $password = Read-SecureStringWithTimeout -Prompt "Password per il nuovo account $Name" -TimeoutSeconds 10
        if ($null -eq $password) {
            $user = New-LocalUser -Name $Name -FullName $Name -AccountNeverExpires
            Set-LocalAccountPasswordState -Name $Name -NeverExpires $false -MustChangeAtNextLogon $true
            Write-Log "Creato account $Name senza password; cambio obbligatorio al primo accesso." -Level WARN
        }
        else {
            $user = New-LocalUser -Name $Name -Password $password -PasswordNeverExpires -FullName $Name -AccountNeverExpires
            Set-LocalAccountPasswordState -Name $Name -NeverExpires $true -MustChangeAtNextLogon $false
            Write-Log "Creato account $Name con password senza scadenza." -Level OK
        }
    }
    else {
        Write-Log "Account $Name già esistente; password e relativa scadenza invariate."
    }

    Enable-LocalUser -Name $Name
    $administrators = Get-LocalGroup -SID 'S-1-5-32-544'
    $isAdministrator = @(Get-LocalGroupMember -Group $administrators.Name | ForEach-Object { $_.SID.Value }) -contains $user.SID.Value

    if ($Administrator) {
        if (-not $isAdministrator) {
            Add-LocalGroupMember -Group $administrators.Name -Member $Name
            Write-Log "$Name aggiunto al gruppo $($administrators.Name)." -Level OK
        }
    }
    elseif ($isAdministrator) {
        Remove-LocalGroupMember -Group $administrators.Name -Member $Name
        Write-Log "$Name rimosso dal gruppo $($administrators.Name)." -Level OK
    }
}

function Set-AdministratorUacBehavior {
    $policyKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'

    # UAC resta abilitato. Gli amministratori elevano senza prompt; gli utenti
    # standard continuano a ricevere la richiesta di credenziali/consenso.
    Set-ItemProperty -Path $policyKey -Name 'EnableLUA' -Type DWord -Value 1
    Set-ItemProperty -Path $policyKey -Name 'ConsentPromptBehaviorAdmin' -Type DWord -Value 0
    Set-ItemProperty -Path $policyKey -Name 'PromptOnSecureDesktop' -Type DWord -Value 0
    Write-Log 'Prompt UAC disabilitato per gli amministratori; UAC ancora attivo nel sistema.' -Level WARN
}

function Enable-EnterpriseWindowsFeatures {
    foreach ($featureName in @('TelnetClient', 'NetFx3')) {
        try {
            $currentFeature = Get-WindowsOptionalFeature -Online -FeatureName $featureName
            if ($currentFeature.State -in @('Enabled', 'EnablePending')) {
                Write-Log "$featureName già abilitato o in attesa di riavvio; nessuna azione."
                continue
            }

            Write-Log "Attivazione funzionalità Windows: $featureName"
            $featureParameters = @{
                Online = $true
                FeatureName = $featureName
                All = $true
                NoRestart = $true
                ErrorAction = 'Stop'
            }
            if ($featureName -eq 'NetFx3' -and $NetFx3Source) {
                $featureParameters['Source'] = $NetFx3Source
                $featureParameters['LimitAccess'] = $true
            }
            Enable-WindowsOptionalFeature @featureParameters | Out-Null
        }
        catch {
            $script:Failures += "Funzionalità $featureName"
            Write-Log "Impossibile attivare ${featureName}: $($_.Exception.Message)" -Level ERROR
        }
    }

    if (-not $InstallRSAT) {
        Write-Log 'Installazione RSAT saltata; usare -InstallRSAT per abilitarla.'
        return
    }

    $rsatCapabilities = @(Get-WindowsCapability -Online -Name 'RSAT*' | Where-Object { $_.State -notin @('Installed', 'InstallPending') })
    foreach ($capability in $rsatCapabilities) {
        try {
            Write-Log "Installazione RSAT: $($capability.Name)"
            Add-WindowsCapability -Online -Name $capability.Name | Out-Null
        }
        catch {
            $script:Failures += "RSAT $($capability.Name)"
            Write-Log "Impossibile installare $($capability.Name): $($_.Exception.Message)" -Level ERROR
        }
    }
    Write-Log "Funzionalità RSAT elaborate: $($rsatCapabilities.Count)." -Level OK
}

function Wait-ServiceStatus {
    param(
        [string]$Name,
        [ValidateSet('Running', 'Stopped')]
        [string]$Status,
        [int]$TimeoutSeconds = 30
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $service = Get-Service -Name $Name -ErrorAction Stop
        if ($service.Status -eq $Status) { return $service }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "Servizio $Name ancora nello stato $($service.Status); atteso $Status."
}

function Start-ServiceIfNeeded {
    param([string]$Name)

    $service = Get-Service -Name $Name -ErrorAction Stop
    if ($service.Status -eq 'Running') { return }
    if ($service.Status -eq 'StopPending') {
        $null = Wait-ServiceStatus -Name $Name -Status Stopped
        $service = Get-Service -Name $Name
    }
    if ($service.Status -eq 'StartPending') {
        $null = Wait-ServiceStatus -Name $Name -Status Running
        return
    }

    Start-Service -Name $Name -ErrorAction Stop
    $null = Wait-ServiceStatus -Name $Name -Status Running
}

function Stop-ServiceIfNeeded {
    param([string]$Name)

    $service = Get-Service -Name $Name -ErrorAction Stop
    if ($service.Status -eq 'Stopped') { return }
    if ($service.Status -eq 'StopPending') {
        $null = Wait-ServiceStatus -Name $Name -Status Stopped
        return
    }
    if ($service.Status -eq 'StartPending') {
        $null = Wait-ServiceStatus -Name $Name -Status Running
    }

    Stop-Service -Name $Name -Force -ErrorAction Stop
    $null = Wait-ServiceStatus -Name $Name -Status Stopped
}

function Enable-EnterpriseRemoteManagement {
    # Mantiene le condivisioni amministrative C$/ADMIN$ e consente agli amministratori
    # locali remoti di ricevere un token completo. SMB1 non viene abilitato.
    $lanmanParametersPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
    $autoShareValue = Get-ItemProperty -Path $lanmanParametersPath -Name 'AutoShareWks' -ErrorAction SilentlyContinue
    $restartLanmanServer = ($null -eq $autoShareValue -or $autoShareValue.AutoShareWks -ne 1)

    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path 'SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name 'AutoShareWks' -Value 1
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'LocalAccountTokenFilterPolicy' -Value 1

    Set-Service -Name 'LanmanServer' -StartupType Automatic
    Start-ServiceIfNeeded -Name 'LanmanServer'

    $sharingRules = @(Get-NetFirewallRule -Name 'FileAndPrinterSharing*' -ErrorAction SilentlyContinue)
    if ($sharingRules.Count -gt 0) {
        $sharingRules | Set-NetFirewallRule -Profile @('Domain','Private')
        $sharingRules | Enable-NetFirewallRule
    }

    # Amministrazione remota PowerShell/WMI. Il profilo di rete non viene modificato:
    # su reti pubbliche possono continuare a valere le limitazioni del firewall.
    Enable-PSRemoting -Force -SkipNetworkProfileCheck
    Set-Service -Name 'WinRM' -StartupType Automatic
    Start-ServiceIfNeeded -Name 'WinRM'

    foreach ($rulePattern in @('RemoteServiceManagement*', 'WMI*')) {
        $rules = @(Get-NetFirewallRule -Name $rulePattern -ErrorAction SilentlyContinue)
        if ($rules.Count -gt 0) { $rules | Enable-NetFirewallRule }
    }

    if ($restartLanmanServer) {
        Restart-Service -Name 'LanmanServer' -Force
        $null = Wait-ServiceStatus -Name 'LanmanServer' -Status Running
        Write-Log 'Servizio LanmanServer riavviato per attivare le condivisioni amministrative.'
    }
    else {
        Write-Log 'Condivisioni amministrative già configurate; riavvio LanmanServer non necessario.'
    }
    Write-Log 'Condivisioni amministrative, accesso amministratori locali remoti, WinRM e WMI configurati.' -Level WARN
}

function Initialize-PackageManagers {
    $wingetCommand = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if ($null -eq $wingetCommand) {
        throw 'WinGet non trovato. Installare/aggiornare App Installer e rieseguire lo script.'
    }
    $script:WingetExe = $wingetCommand.Source

    $existingChoco = Get-Command 'choco.exe' -ErrorAction SilentlyContinue
    $defaultChoco = Join-Path $env:ProgramData 'chocolatey\bin\choco.exe'
    if ($null -ne $existingChoco) {
        $script:ChocoExe = $existingChoco.Source
    }
    elseif (Test-Path -LiteralPath $defaultChoco) {
        $script:ChocoExe = $defaultChoco
    }

    if ($null -eq $script:ChocoExe) {
        Write-Log 'Installazione Chocolatey tramite WinGet.'
        Invoke-Native -FilePath $script:WingetExe -Arguments @(
            'install', '--id', 'Chocolatey.Chocolatey', '--exact', '--source', 'winget',
            '--silent', '--accept-package-agreements', '--accept-source-agreements',
            '--disable-interactivity'
        ) -SuccessCodes @(0, -1978334963, -1978334967, -1978334966, -1978334965)

        if (Test-Path -LiteralPath $defaultChoco) {
            $script:ChocoExe = $defaultChoco
        }
        else {
            $existingChoco = Get-Command 'choco.exe' -ErrorAction SilentlyContinue
            if ($null -ne $existingChoco) { $script:ChocoExe = $existingChoco.Source }
        }
    }

    if ($null -eq $script:ChocoExe) {
        throw 'Chocolatey installato ma choco.exe non è stato trovato.'
    }
    Write-Log "WinGet: $script:WingetExe"
    Write-Log "Chocolatey: $script:ChocoExe"
}

function Get-WingetSettingsPath {
    return (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\settings.json')
}

function Read-WingetSettings {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{}
    }
    $content = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($content)) { return [pscustomobject]@{} }
    return ($content | ConvertFrom-Json)
}

function Save-WingetSettings {
    param(
        [string]$Path,
        [object]$Settings
    )

    $directory = Split-Path -Path $Path -Parent
    $null = New-Item -Path $directory -ItemType Directory -Force
    $json = $Settings | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-WingetCacheLocation {
    $cachePath = Join-Path $CacheDirectory 'winget'
    try { $null = New-Item -Path $cachePath -ItemType Directory -Force -ErrorAction Stop }
    catch {
        Write-Log "Cache WinGet non scrivibile in $cachePath; resta attivo il default. $($_.Exception.Message)" -Level WARN
        return
    }
    $settingsPath = Get-WingetSettingsPath
    $settings = Read-WingetSettings -Path $settingsPath

    if (-not $settings.PSObject.Properties['downloadBehavior'] -or $null -eq $settings.downloadBehavior) {
        $settings | Add-Member -MemberType NoteProperty -Name 'downloadBehavior' -Value ([pscustomobject]@{}) -Force
    }
    $settings.downloadBehavior | Add-Member -MemberType NoteProperty -Name 'defaultDownloadDirectory' -Value $cachePath -Force
    Save-WingetSettings -Path $settingsPath -Settings $settings
    $script:WingetCacheConfigured = $true
    Write-Log "Cache download WinGet impostata su $cachePath."
}

function Set-ChocolateyCacheLocation {
    if ($null -eq $script:ChocoExe) { throw 'Chocolatey non disponibile.' }
    $cachePath = Join-Path $CacheDirectory 'choco'
    try { $null = New-Item -Path $cachePath -ItemType Directory -Force -ErrorAction Stop }
    catch {
        Write-Log "Cache Chocolatey non scrivibile in $cachePath; resta attivo il default. $($_.Exception.Message)" -Level WARN
        return
    }
    Invoke-Native -FilePath $script:ChocoExe -Arguments @(
        'config', 'set', '--name', 'cacheLocation', '--value', $cachePath
    ) -SuccessCodes @(0, 2)
    $script:ChocoCacheConfigured = $true
    Write-Log "Cache Chocolatey impostata su $cachePath."
}

function Reset-PackageCacheLocations {
    $resetErrors = @()

    if ($script:WingetCacheConfigured) {
        try {
            $settingsPath = Get-WingetSettingsPath
            $settings = Read-WingetSettings -Path $settingsPath
            if ($settings.PSObject.Properties['downloadBehavior'] -and $null -ne $settings.downloadBehavior -and
                $settings.downloadBehavior.PSObject.Properties['defaultDownloadDirectory']) {
                $settings.downloadBehavior.PSObject.Properties.Remove('defaultDownloadDirectory')
                Save-WingetSettings -Path $settingsPath -Settings $settings
            }
            $script:WingetCacheConfigured = $false
            Write-Log 'Directory download WinGet ripristinata al valore predefinito.'
        }
        catch { $resetErrors += "WinGet: $($_.Exception.Message)" }
    }

    if ($script:ChocoCacheConfigured) {
        try {
            if ($null -eq $script:ChocoExe) { throw 'choco.exe non disponibile.' }
            Invoke-Native -FilePath $script:ChocoExe -Arguments @(
                'config', 'unset', '--name', 'cacheLocation'
            ) -SuccessCodes @(0, 2)
            $script:ChocoCacheConfigured = $false
            Write-Log 'Cache Chocolatey ripristinata al valore predefinito (%TEMP%).'
        }
        catch { $resetErrors += "Chocolatey: $($_.Exception.Message)" }
    }

    if ($resetErrors.Count -gt 0) {
        throw ('Ripristino cache non completato: ' + ($resetErrors -join '; '))
    }
}

function Test-WingetApplicationInstalled {
    param([string]$WingetId)

    $output = & $script:WingetExe 'list' '--id' $WingetId '--exact' '--accept-source-agreements' '--disable-interactivity' 2>&1 | Out-String
    return ($output -match [regex]::Escape($WingetId))
}

function Test-ChocolateyPackageInstalled {
    param([string]$ChocoId)

    $output = & $script:ChocoExe 'list' $ChocoId '--local-only' '--exact' '--limit-output' 2>&1 | Out-String
    return ($output -match ('(?im)^' + [regex]::Escape($ChocoId) + '\|'))
}

function Install-Application {
    param(
        [string]$Name,
        [string]$WingetId,
        [string]$ChocoId
    )

    if ($WingetId -and (Test-WingetApplicationInstalled -WingetId $WingetId)) {
        Write-Log "$Name già installato; pacchetto WinGet $WingetId saltato."
        return
    }
    if ($ChocoId -and (Test-ChocolateyPackageInstalled -ChocoId $ChocoId)) {
        Write-Log "$Name già installato; pacchetto Chocolatey $ChocoId saltato."
        return
    }

    $installed = $false
    if ($WingetId) {
        Write-Log "Installazione $Name con WinGet ($WingetId)."
        try {
            Invoke-Native -FilePath $script:WingetExe -Arguments @(
                'install', '--id', $WingetId, '--exact', '--source', 'winget',
                '--silent', '--accept-package-agreements', '--accept-source-agreements',
                '--disable-interactivity'
            ) -SuccessCodes @(0, -1978334963, -1978334967, -1978334966, -1978334965)
            $installed = $true
        }
        catch {
            Write-Log "WinGet non ha installato ${Name}: $($_.Exception.Message) Provo Chocolatey." -Level WARN
        }
    }

    if (-not $installed) {
        Write-Log "Installazione $Name con Chocolatey ($ChocoId)."
        Invoke-Native -FilePath $script:ChocoExe -Arguments @(
            'install', $ChocoId, '-y', '--no-progress', '--limit-output'
        ) -SuccessCodes @(0, 1641, 3010)
    }
    Write-Log "$Name installato." -Level OK
}

function Install-LiteManagerServer {
    $configuration = Join-Path $PSScriptRoot 'settings\LiteManagerServer.reg'

    # Il pacchetto viene installato anche se il REG aziendale non è ancora presente.
    Install-Application -Name 'LiteManager Server' -WingetId $null -ChocoId 'litemanager-server'

    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $romServer = Get-ChildItem -Path @(
        (Join-Path $programFiles 'LiteManager*'),
        (Join-Path $programFilesX86 'LiteManager*')
    ) -Filter 'ROMServer.exe' -File -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $romServer) {
        throw 'LiteManager installato, ma ROMServer.exe non è stato trovato.'
    }

    # Il file REG deve contenere WinNT security con Administrators Full Control,
    # fallback password disattivato e richieste di consenso utente disabilitate.
    $romProcess = Get-Process -Name 'ROMServer' -ErrorAction SilentlyContinue
    if ($null -ne $romProcess) {
        & $romServer.FullName '/stop' 2>&1 | ForEach-Object { if ($null -ne $_) { Write-Log ([string]$_) } }
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 250
            $romProcess = Get-Process -Name 'ROMServer' -ErrorAction SilentlyContinue
        } while ($null -ne $romProcess -and [DateTime]::UtcNow -lt $deadline)
        if ($null -ne $romProcess) { throw 'ROMServer non si è arrestato entro 10 secondi.' }
    }

    if (-not (Test-Path -LiteralPath $configuration -PathType Leaf)) {
        throw "LiteManager Server installato e arrestato, ma non configurato: file obbligatorio assente $configuration. Aggiungerlo e rieseguire lo script."
    }

    Invoke-Native -FilePath "$env:SystemRoot\regedit.exe" -Arguments @('/s', $configuration) -SuccessCodes @(0)

    $firewallName = 'NewPC - LiteManager Server'
    if ($null -eq (Get-NetFirewallRule -DisplayName $firewallName -ErrorAction SilentlyContinue)) {
        $null = New-NetFirewallRule -DisplayName $firewallName -Direction Inbound -Action Allow -Program $romServer.FullName -Profile @('Domain','Private')
    }

    if ($null -eq (Get-Process -Name 'ROMServer' -ErrorAction SilentlyContinue)) {
        Invoke-Native -FilePath $romServer.FullName -Arguments @('/start') -SuccessCodes @(0)
    }
    else {
        Write-Log 'ROMServer già in esecuzione; avvio non ripetuto.'
    }
    Write-Log 'LiteManager Server configurato dal file aziendale e avviato.' -Level OK
}

function Set-EverythingEnterpriseConfiguration {
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $everything = Find-InstalledExecutable -Candidates @(
        (Join-Path $programFiles 'Everything\Everything.exe'),
        (Join-Path $programFilesX86 'Everything\Everything.exe')
    )

    # Attende la chiusura del client prima di modificare le opzioni: altrimenti
    # Everything può restituire codice 1 mentre il processo è ancora attivo.
    & $everything '-exit' '-wait' 2>&1 | ForEach-Object { if ($null -ne $_) { Write-Log ([string]$_) } }
    $arguments = @(
        '-disable-update-notification',
        '-disable-run-as-admin',
        '-uninstall-run-on-system-startup',
        '-uninstall-all-users-run-on-system-startup'
    )
    if ($null -eq (Get-Service -Name 'Everything' -ErrorAction SilentlyContinue)) {
        $arguments = @('-install-service') + $arguments
    }
    Invoke-Native -FilePath $everything -Arguments $arguments -SuccessCodes @(0)

    Set-Service -Name 'Everything' -StartupType Automatic
    Start-ServiceIfNeeded -Name 'Everything'
    Write-Log 'Everything configurato come servizio, senza avvio automatico della GUI o notifiche aggiornamenti.' -Level OK
}

function Copy-UniformUserPresets {
    $presetStage = Join-Path $WorkDirectory 'UserPresets'
    if (Test-Path -LiteralPath $presetStage) {
        Remove-Item -LiteralPath $presetStage -Recurse -Force
    }
    $vlcDirectory = Join-Path $presetStage 'AppData\Roaming\vlc'
    $null = New-Item -Path $vlcDirectory -ItemType Directory -Force

    # Sopprime la richiesta privacy iniziale, aggiornamenti e accesso di rete ai metadati.
    $vlcConfig = @'
[core]
metadata-network-access=0

[qt]
qt-privacy-ask=0
qt-updates-notif=0
'@
    [System.IO.File]::WriteAllText((Join-Path $vlcDirectory 'vlcrc'), $vlcConfig, (New-Object System.Text.UTF8Encoding($false)))

    # Eventuali preset aziendali sovrascrivono quelli generati. Struttura esempio:
    # settings\user-presets\AppData\Roaming\Notepad++\config.xml
    $customPresets = Join-Path $PSScriptRoot 'settings\user-presets'
    if (Test-Path -LiteralPath $customPresets -PathType Container) {
        & "$env:SystemRoot\System32\robocopy.exe" $customPresets $presetStage /E /COPY:DAT /DCOPY:T /R:2 /W:2 /XJ /NP /NFL /NDL /NJH /NJS 2>&1 |
            ForEach-Object { if ($null -ne $_) { Write-Log ([string]$_) } }
        if ($LASTEXITCODE -gt 7) { throw "Importazione preset aziendali non riuscita: codice $LASTEXITCODE." }
    }

    $profilePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $null = $profilePaths.Add([Environment]::GetFolderPath('UserProfile'))
    $null = $profilePaths.Add((Join-Path $env:SystemDrive 'Users\Default'))
    foreach ($profile in @(Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath })) {
        $null = $profilePaths.Add($profile.LocalPath)
    }

    foreach ($profilePath in $profilePaths) {
        if (-not (Test-Path -LiteralPath $profilePath -PathType Container)) { continue }
        Write-Log "Applicazione preset utente: $profilePath"
        & "$env:SystemRoot\System32\robocopy.exe" $presetStage $profilePath /E /COPY:DAT /DCOPY:T /R:2 /W:2 /XJ /NP /NFL /NDL /NJH /NJS 2>&1 |
            ForEach-Object { if ($null -ne $_) { Write-Log ([string]$_) } }
        if ($LASTEXITCODE -gt 7) { throw "Copia preset in $profilePath non riuscita: codice $LASTEXITCODE." }
    }
    Write-Log 'Preset applicazioni distribuiti ai profili esistenti e al profilo Default.' -Level OK
}

function Install-RequestedApplications {
    # Google.Chrome usa il pacchetto MSI Google Chrome Enterprise.
    $applications = @(
        @{ Name = 'VLC';                            Winget = 'VideoLAN.VLC';                       Choco = 'vlc' },
        @{ Name = 'Veeam Agent';                    Winget = 'Veeam.VeeamAgent';                   Choco = 'veeam-agent' },
        @{ Name = 'dupeGuru';                       Winget = 'DupeGuru.DupeGuru';                  Choco = 'dupeguru' },
        @{ Name = 'FileZilla';                      Winget = 'TimKosse.FilezillaClient';           Choco = 'filezilla' },
        @{ Name = 'Notepad++';                      Winget = 'Notepad++.Notepad++';                Choco = 'notepadplusplus' },
        @{ Name = 'PDF-XChange Editor';             Winget = 'TrackerSoftware.PDF-XChangeEditor';  Choco = 'pdfxchangeeditor' },
        @{ Name = '7-Zip';                          Winget = '7zip.7zip';                          Choco = '7zip' },
        @{ Name = 'LibreOffice';                    Winget = 'TheDocumentFoundation.LibreOffice';  Choco = 'libreoffice-fresh' },
        @{ Name = 'Open-Shell';                     Winget = 'Open-Shell.Open-Shell-Menu';         Choco = 'open-shell' },
        @{ Name = 'PDF24 Creator';                  Winget = 'geeksoftwareGmbH.PDF24Creator';      Choco = 'pdf24' },
        @{ Name = 'Google Chrome Enterprise';       Winget = 'Google.Chrome';                      Choco = 'googlechrome' },
        @{ Name = 'Google Drive';                   Winget = 'Google.GoogleDrive';                 Choco = 'googledrive' },
        @{ Name = 'Revo Uninstaller';               Winget = 'RevoUninstaller.RevoUninstaller';    Choco = 'revo-uninstaller' },
        @{ Name = 'XnView MP';                      Winget = 'XnSoft.XnViewMP';                    Choco = 'xnviewmp' },
        @{ Name = 'Everything';                     Winget = 'voidtools.Everything';                Choco = 'everything' },
        @{ Name = 'Simple Software Restriction Policy'; Winget = $null;                            Choco = 'simple-software-restriction-policy' },
        @{ Name = 'WordCraft';                      Winget = $null;                                  Choco = 'wordcraft' },
        @{ Name = 'DeckCraft';                      Winget = $null;                                  Choco = 'deckcraft' },
        @{ Name = 'GridCraft';                      Winget = $null;                                  Choco = 'gridcraft' },
        @{ Name = 'PdfCraft';                       Winget = $null;                                  Choco = 'pdfcraft' },
        @{ Name = 'PhotoCraft';                     Winget = $null;                                  Choco = 'photocraft' },
        @{ Name = 'ArtCraft';                       Winget = $null;                                  Choco = 'artcraft' }
    )

    foreach ($application in $applications) {
        try {
            Install-Application -Name $application.Name -WingetId $application.Winget -ChocoId $application.Choco
        }
        catch {
            $script:Failures += "Installazione $($application.Name)"
            Write-Log "Installazione $($application.Name) non riuscita: $($_.Exception.Message)" -Level ERROR
        }
    }
}

function Install-LocalMsiPackages {
    $source = Join-Path $PSScriptRoot 'sw'
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        Write-Log "Cartella MSI opzionale non presente: $source"
        return
    }

    $packages = @(Get-ChildItem -LiteralPath $source -Filter '*.msi' -File -Recurse | Sort-Object FullName)
    if ($packages.Count -eq 0) {
        Write-Log "Nessun MSI trovato in $source."
        return
    }

    foreach ($package in $packages) {
        try {
            Write-Log "Installazione MSI: $($package.FullName)"
            Invoke-Native -FilePath "$env:SystemRoot\System32\msiexec.exe" -Arguments @(
                '/i', $package.FullName, '/passive', '/norestart'
            ) -SuccessCodes @(0, 1641, 3010)
            Write-Log "MSI installato: $($package.Name)" -Level OK
        }
        catch {
            $script:Failures += "MSI $($package.Name)"
            Write-Log "Installazione MSI $($package.FullName) non riuscita: $($_.Exception.Message)" -Level ERROR
        }
    }
}

function New-Association {
    param([string]$Identifier, [string]$ProgId, [string]$ApplicationName)
    return @{ Identifier = $Identifier.ToLowerInvariant(); ProgId = $ProgId; ApplicationName = $ApplicationName }
}

function Get-ChromeAssociations {
    $associations = @()
    $registered = Get-ItemProperty 'HKLM:\SOFTWARE\RegisteredApplications'
    $chromeRegistration = $registered.PSObject.Properties |
        Where-Object { $_.Name -match 'Google Chrome|Chrome' } |
        Select-Object -First 1

    if ($null -ne $chromeRegistration) {
        $capabilitiesPath = Join-Path 'Registry::HKEY_LOCAL_MACHINE' ([string]$chromeRegistration.Value)
        foreach ($section in @('FileAssociations', 'URLAssociations')) {
            $sectionKey = Get-Item (Join-Path $capabilitiesPath $section) -ErrorAction SilentlyContinue
            if ($null -eq $sectionKey) { continue }
            foreach ($property in $sectionKey.Property) {
                if ($property -ieq '.pdf') { continue }
                $progId = [string]$sectionKey.GetValue($property)
                if ($progId) {
                    $associations += New-Association -Identifier $property -ProgId $progId -ApplicationName 'Google Chrome'
                }
            }
        }
    }

    if ($associations.Count -eq 0) {
        Write-Log 'Capabilities Chrome non trovate; uso le associazioni HTTP/HTTPS/HTML standard.' -Level WARN
        foreach ($identifier in @('.htm', '.html', 'http', 'https')) {
            $associations += New-Association -Identifier $identifier -ProgId 'ChromeHTML' -ApplicationName 'Google Chrome'
        }
    }
    return $associations
}

function Get-PdfXChangeProgId {
    $extensionKey = Get-Item 'HKLM:\SOFTWARE\Classes\.pdf' -ErrorAction SilentlyContinue
    $candidates = @()
    if ($null -ne $extensionKey) {
        $defaultProgId = [string]$extensionKey.GetValue('')
        if ($defaultProgId) { $candidates += $defaultProgId }
        $openWithKey = Get-Item (Join-Path $extensionKey.PSPath 'OpenWithProgIds') -ErrorAction SilentlyContinue
        if ($null -ne $openWithKey) { $candidates += @($openWithKey.Property) }
    }

    # PDF-XChange 11 usa anche il ProgID PXCEditor.PDF.
    $pdfProgId = $candidates | Where-Object { $_ -match 'PDFX|PDF-XChange|PXCEditor' } | Select-Object -First 1
    if ($pdfProgId) { return [string]$pdfProgId }

    $classKeys = Get-ChildItem 'HKLM:\SOFTWARE\Classes' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match 'PDFX|PDF-XChange|PXCEditor' }
    foreach ($classKey in $classKeys) {
        $commandKey = Get-Item (Join-Path $classKey.PSPath 'shell\open\command') -ErrorAction SilentlyContinue
        if ($null -ne $commandKey -and [string]$commandKey.GetValue('') -match 'PDFXEdit\.exe') {
            return [string]$classKey.PSChildName
        }
    }
    # Se il programma è installato ma non ha registrato le classi, crea un ProgID
    # classico stabile invece di interrompere tutte le associazioni.
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $executable = Find-InstalledExecutable -Candidates @(
        (Join-Path $programFiles 'Tracker Software\PDF Editor\PDFXEdit.exe'),
        (Join-Path $programFilesX86 'Tracker Software\PDF Editor\PDFXEdit.exe')
    )
    $progId = 'NewPC.PDFXChange.Document'
    Register-ClassicApplicationProgId -ProgId $progId -Executable $executable -Description 'PDF-XChange Editor document'
    Write-Log "Classi PDF-XChange non registrate; creato il ProgID $progId." -Level WARN
    return $progId
}

function Get-SevenZipAssociations {
    $associations = @()
    $excluded = @('.iso', '.vhd', '.vhdx')
    $extensionKeys = Get-ChildItem 'HKLM:\SOFTWARE\Classes' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like '.*' -and $excluded -notcontains $_.PSChildName.ToLowerInvariant() }

    foreach ($extensionKey in $extensionKeys) {
        $progIds = @()
        $defaultProgId = [string]$extensionKey.GetValue('')
        if ($defaultProgId -like '7-Zip.*') { $progIds += $defaultProgId }

        $openWithKey = Get-Item (Join-Path $extensionKey.PSPath 'OpenWithProgIds') -ErrorAction SilentlyContinue
        if ($null -ne $openWithKey) {
            $progIds += @($openWithKey.Property | Where-Object { $_ -like '7-Zip.*' })
        }

        foreach ($progId in @($progIds | Select-Object -Unique)) {
            $associations += New-Association -Identifier $extensionKey.PSChildName -ProgId $progId -ApplicationName '7-Zip'
        }
    }
    return $associations
}

function Find-InstalledExecutable {
    param([string[]]$Candidates)

    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }
    throw "Eseguibile non trovato. Percorsi controllati: $($Candidates -join '; ')"
}

function Register-ClassicApplicationProgId {
    param(
        [string]$ProgId,
        [string]$Executable,
        [string]$Description
    )

    $progIdPath = Join-Path 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes' $ProgId
    $commandPath = Join-Path $progIdPath 'shell\open\command'
    $iconPath = Join-Path $progIdPath 'DefaultIcon'
    $null = New-Item -Path $commandPath -Force
    $null = New-Item -Path $iconPath -Force
    Set-Item -Path $progIdPath -Value $Description
    Set-Item -Path $commandPath -Value ('"{0}" "%1"' -f $Executable)
    Set-Item -Path $iconPath -Value ('"{0}",0' -f $Executable)
}

function Get-PerceivedTypeAssociations {
    param(
        [ValidateSet('image', 'video')]
        [string]$PerceivedType,
        [string]$ProgId,
        [string]$ApplicationName,
        [string[]]$AdditionalExtensions
    )

    $identifiers = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($extension in $AdditionalExtensions) {
        $null = $identifiers.Add($extension.ToLowerInvariant())
    }

    $extensionKeys = Get-ChildItem 'HKLM:\SOFTWARE\Classes' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like '.*' }
    foreach ($extensionKey in $extensionKeys) {
        if ([string]$extensionKey.GetValue('PerceivedType') -ieq $PerceivedType) {
            $null = $identifiers.Add($extensionKey.PSChildName.ToLowerInvariant())
        }
    }

    $associations = @()
    foreach ($identifier in @($identifiers | Sort-Object)) {
        $associations += New-Association -Identifier $identifier -ProgId $ProgId -ApplicationName $ApplicationName
    }
    return $associations
}

function Get-XnViewImageAssociations {
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $executable = Find-InstalledExecutable -Candidates @(
        (Join-Path $programFiles 'XnViewMP\xnviewmp.exe'),
        (Join-Path $programFilesX86 'XnViewMP\xnviewmp.exe'),
        (Join-Path $programFiles 'XnView\xnview.exe'),
        (Join-Path $programFilesX86 'XnView\xnview.exe')
    )
    Register-ClassicApplicationProgId -ProgId 'NewPC.XnView.Image' -Executable $executable -Description 'XnView MP/Pro image'

    $extensions = @(
        '.jpg', '.jpeg', '.jpe', '.jfif', '.png', '.gif', '.bmp', '.dib',
        '.tif', '.tiff', '.webp', '.heic', '.heif', '.avif', '.jxl',
        '.ico', '.cur', '.tga', '.psd', '.raw', '.dng', '.cr2', '.cr3',
        '.nef', '.nrw', '.arw', '.orf', '.rw2', '.pef', '.srw', '.raf',
        '.svg', '.jp2', '.j2k', '.jxr', '.wdp', '.pcx', '.pbm', '.pgm',
        '.ppm', '.pnm', '.xbm', '.xpm', '.dds', '.exr', '.hdr', '.qoi'
    )
    return @(Get-PerceivedTypeAssociations -PerceivedType 'image' -ProgId 'NewPC.XnView.Image' -ApplicationName 'XnView MP/Pro' -AdditionalExtensions $extensions)
}

function Get-VlcVideoAssociations {
    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $executable = Find-InstalledExecutable -Candidates @(
        (Join-Path $programFiles 'VideoLAN\VLC\vlc.exe'),
        (Join-Path $programFilesX86 'VideoLAN\VLC\vlc.exe')
    )
    Register-ClassicApplicationProgId -ProgId 'NewPC.VLC.Video' -Executable $executable -Description 'VLC video'

    $extensions = @(
        '.avi', '.mp4', '.m4v', '.mkv', '.mov', '.qt', '.wmv', '.asf',
        '.mpg', '.mpeg', '.mpe', '.m1v', '.m2v', '.ts', '.m2ts', '.mts',
        '.vob', '.webm', '.flv', '.f4v', '.3gp', '.3g2', '.ogv', '.rm',
        '.rmvb', '.divx', '.xvid', '.dv', '.yuv', '.amv', '.mxf'
    )
    return @(Get-PerceivedTypeAssociations -PerceivedType 'video' -ProgId 'NewPC.VLC.Video' -ApplicationName 'VLC media player' -AdditionalExtensions $extensions)
}

function Save-DefaultAssociationsXml {
    param([array]$Associations, [string]$Path)

    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = [System.Xml.XmlWriter]::Create($Path, $settings)
    try {
        $writer.WriteStartDocument()
        $writer.WriteStartElement('DefaultAssociations')
        $writer.WriteAttributeString('Version', (Get-Date -Format 'yyyyMMddHHmmss'))
        foreach ($association in $Associations) {
            $writer.WriteStartElement('Association')
            $writer.WriteAttributeString('Identifier', $association.Identifier)
            $writer.WriteAttributeString('ProgId', $association.ProgId)
            $writer.WriteAttributeString('ApplicationName', $association.ApplicationName)
            $writer.WriteAttributeString('Suggested', 'false')
            $writer.WriteEndElement()
        }
        $writer.WriteEndElement()
        $writer.WriteEndDocument()
    }
    finally {
        $writer.Close()
    }
}

function Set-DefaultApplications {
    Write-Log 'Lettura delle associazioni registrate; ogni applicazione viene gestita separatamente.'
    $chrome = @()
    $pdf = @()
    $sevenZip = @()
    $xnView = @()
    $vlc = @()

    try { $chrome = @(Get-ChromeAssociations) }
    catch {
        $script:Failures += 'Associazioni Chrome'
        Write-Log "Associazioni Chrome non disponibili: $($_.Exception.Message)" -Level ERROR
    }
    try { $pdf = @(New-Association -Identifier '.pdf' -ProgId (Get-PdfXChangeProgId) -ApplicationName 'PDF-XChange Editor') }
    catch {
        $script:Failures += 'Associazioni PDF-XChange'
        Write-Log "Associazioni PDF-XChange non disponibili: $($_.Exception.Message)" -Level ERROR
    }
    try { $sevenZip = @(Get-SevenZipAssociations) }
    catch {
        $script:Failures += 'Associazioni 7-Zip'
        Write-Log "Associazioni 7-Zip non disponibili: $($_.Exception.Message)" -Level ERROR
    }
    try { $xnView = @(Get-XnViewImageAssociations) }
    catch {
        $script:Failures += 'Associazioni XnView'
        Write-Log "Associazioni XnView non disponibili: $($_.Exception.Message)" -Level ERROR
    }
    try { $vlc = @(Get-VlcVideoAssociations) }
    catch {
        $script:Failures += 'Associazioni VLC'
        Write-Log "Associazioni VLC non disponibili: $($_.Exception.Message)" -Level ERROR
    }

    if ($sevenZip.Count -eq 0) {
        $script:Failures += 'Associazioni 7-Zip'
        Write-Log 'Nessuna associazione 7-Zip trovata; le altre associazioni verranno comunque applicate.' -Level WARN
    }

    # Una sola voce per identificatore; le voci successive sostituiscono le precedenti.
    $map = @{}
    foreach ($association in @($chrome + $pdf + $sevenZip + $xnView + $vlc)) {
        $map[$association.Identifier] = $association
    }
    $associations = @($map.Values | Sort-Object Identifier)
    if ($associations.Count -eq 0) {
        throw 'Nessuna associazione valida disponibile.'
    }
    Write-Log ("Associazioni preparate: Chrome {0}, PDF {1}, 7-Zip {2}, XnView {3}, VLC {4}; totale {5}." -f $chrome.Count, $pdf.Count, $sevenZip.Count, $xnView.Count, $vlc.Count, $associations.Count)

    $xmlPath = Join-Path $WorkDirectory 'DefaultAppAssociations.xml'
    Save-DefaultAssociationsXml -Associations $associations -Path $xmlPath

    # DISM applica queste associazioni ai nuovi profili al primo accesso.
    # Un eventuale errore non deve impedire criterio e configurazione dell'utente corrente.
    try {
        Invoke-Native -FilePath "$env:SystemRoot\System32\dism.exe" -Arguments @(
            '/Online', "/Import-DefaultAppAssociations:$xmlPath"
        ) -SuccessCodes @(0)
        Write-Log 'Associazioni predefinite importate per i nuovi utenti.' -Level OK
    }
    catch {
        $script:Failures += 'Importazione DISM associazioni'
        Write-Log "Importazione DISM non riuscita: $($_.Exception.Message)" -Level ERROR
    }

    # Il criterio applica lo stesso XML anche agli altri utenti al successivo accesso.
    # Suggested=false applica le scelte aziendali anche agli utenti con associazioni precedenti.
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path 'SOFTWARE\Policies\Microsoft\Windows\System' -Name 'DefaultAssociationsConfiguration' -Value $xmlPath -Kind String
    Write-Log 'Criterio associazioni configurato per tutti gli utenti al successivo accesso.' -Level OK

    $candidates = @()
    if ($SetUserFTAPath) { $candidates += $SetUserFTAPath }
    $candidates += @(
        (Join-Path $PSScriptRoot 'bin\SetUserFTA.exe'),
        'C:\bin\SetUserFTA.exe'
    )
    $setUserFta = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1

    if ($null -eq $setUserFta) {
        throw 'SetUserFTA.exe non trovato: associazioni dei nuovi utenti importate, ma utente corrente non configurato. Inserire SetUserFTA.exe in bin o C:\bin e rieseguire.'
    }

    $fileVersion = [version](Get-Item -LiteralPath $setUserFta).VersionInfo.FileVersion
    if ($fileVersion.Major -ge 2) {
        # Raggruppa gli identificatori per ridurre le chiamate e ogni possibile prompt.
        foreach ($group in @($associations | Group-Object ProgId)) {
            $identifierList = ($group.Group.Identifier -join ',')
            try {
                Invoke-Native -FilePath $setUserFta -Arguments @('set', $identifierList, $group.Name) -SuccessCodes @(0)
            }
            catch {
                $script:Failures += "SetUserFTA $($group.Name)"
                Write-Log "Associazione $($group.Name) non applicata: $($_.Exception.Message)" -Level ERROR
            }
        }
    }
    else {
        # SetUserFTA 1.x accetta un file di configurazione: una sola chiamata.
        $configPath = Join-Path $WorkDirectory 'SetUserFTA.txt'
        $lines = @($associations | ForEach-Object { "$($_.Identifier), $($_.ProgId)" })
        [System.IO.File]::WriteAllLines($configPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
        Invoke-Native -FilePath $setUserFta -Arguments @($configPath) -SuccessCodes @(0)
    }
    Write-Log "Associazioni elaborate per l'utente corrente con $setUserFta; verificare eventuali errori parziali." -Level OK
}

function Set-RegistryValue {
    param(
        [string]$Root,
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [Microsoft.Win32.RegistryValueKind]$Kind = [Microsoft.Win32.RegistryValueKind]::DWord
    )

    switch ($Root) {
        'Registry::HKEY_LOCAL_MACHINE' { $rootKey = [Microsoft.Win32.Registry]::LocalMachine }
        'Registry::HKEY_CURRENT_USER'  { $rootKey = [Microsoft.Win32.Registry]::CurrentUser }
        'Registry::HKEY_USERS'         { $rootKey = [Microsoft.Win32.Registry]::Users }
        default { throw "Radice del Registro non supportata: $Root" }
    }

    $registryKey = $null
    try {
        # CreateSubKey apre la chiave in scrittura anche quando esiste già.
        $registryKey = $rootKey.CreateSubKey($Path, $true)
        if ($null -eq $registryKey) { throw 'CreateSubKey non ha restituito una chiave.' }
        $registryKey.SetValue($Name, $Value, $Kind)
    }
    catch {
        throw "Impossibile impostare $Root\$Path [$Name]: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $registryKey) { $registryKey.Dispose() }
    }
}

function Get-NavyWallpaperPath {
    $wallpaperPath = Join-Path $WorkDirectory 'navy.bmp'
    if (Test-Path -LiteralPath $wallpaperPath -PathType Leaf) { return $wallpaperPath }

    Add-Type -AssemblyName System.Drawing
    $bitmap = New-Object System.Drawing.Bitmap 64, 64
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::FromArgb(0, 32, 64))
        $bitmap.Save($wallpaperPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    return $wallpaperPath
}

function Set-UserRegistryPreferences {
    param([string]$UserRoot)

    # Open-Shell: MenuStyle 1 = Classic with two columns; ShowedStyle2 evita il primo avvio.
    Set-RegistryValue -Root $UserRoot -Path 'Software\OpenShell\StartMenu' -Name 'MenuStyle' -Value 1
    Set-RegistryValue -Root $UserRoot -Path 'Software\OpenShell\StartMenu' -Name 'ShowedStyle2' -Value 1

    $explorerAdvanced = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-RegistryValue -Root $UserRoot -Path $explorerAdvanced -Name 'TaskbarDa' -Value 0
    Set-RegistryValue -Root $UserRoot -Path $explorerAdvanced -Name 'TaskbarMn' -Value 0
    Set-RegistryValue -Root $UserRoot -Path $explorerAdvanced -Name 'ShowTaskViewButton' -Value 1
    Set-RegistryValue -Root $UserRoot -Path $explorerAdvanced -Name 'SeparateProcess' -Value 1
    Set-RegistryValue -Root $UserRoot -Path $explorerAdvanced -Name 'TaskbarAl' -Value 0

    Set-RegistryValue -Root $UserRoot -Path 'Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Value 0

    # Sfondo blu navy scuro RGB 0,32,64 tramite immagine reale, non soltanto colore Registry.
    $wallpaperPath = Get-NavyWallpaperPath
    Set-RegistryValue -Root $UserRoot -Path 'Control Panel\Desktop' -Name 'Wallpaper' -Value $wallpaperPath -Kind String
    Set-RegistryValue -Root $UserRoot -Path 'Control Panel\Desktop' -Name 'WallpaperStyle' -Value '2' -Kind String
    Set-RegistryValue -Root $UserRoot -Path 'Control Panel\Desktop' -Name 'TileWallpaper' -Value '0' -Kind String
    Set-RegistryValue -Root $UserRoot -Path 'Control Panel\Colors' -Name 'Background' -Value '0 32 64' -Kind String

    # Impedisce l'installazione automatica di app consumer/suggerite nei profili.
    $contentDelivery = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($valueName in @(
        'ContentDeliveryAllowed', 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled',
        'PreInstalledAppsEverEnabled', 'SilentInstalledAppsEnabled', 'SoftLandingEnabled',
        'SystemPaneSuggestionsEnabled', 'SubscribedContentEnabled',
        'SubscribedContent-310093Enabled', 'SubscribedContent-338387Enabled',
        'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
        'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled',
        'SubscribedContent-353696Enabled', 'SubscribedContent-353698Enabled'
    )) {
        Set-RegistryValue -Root $UserRoot -Path $contentDelivery -Name $valueName -Value 0
    }

    # Sopprime benvenuto Windows, suggerimenti e richiesta "Completa configurazione dispositivo".
    $cloudPolicy = 'Software\Policies\Microsoft\Windows\CloudContent'
    foreach ($valueName in @(
        'DisableWindowsSpotlightWindowsWelcomeExperience',
        'DisableWindowsSpotlightOnActionCenter', 'DisableWindowsSpotlightOnSettings',
        'DisableTailoredExperiencesWithDiagnosticData', 'DisableThirdPartySuggestions'
    )) {
        Set-RegistryValue -Root $UserRoot -Path $cloudPolicy -Name $valueName -Value 1
    }
    Set-RegistryValue -Root $UserRoot -Path 'Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' -Name 'ScoobeSystemSettingEnabled' -Value 0

    # Disattiva acquisizione Game Bar/DVR anche per i profili nei quali restano componenti di sistema.
    Set-RegistryValue -Root $UserRoot -Path 'Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -Value 0
    Set-RegistryValue -Root $UserRoot -Path 'Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'HistoricalCaptureEnabled' -Value 0
    Set-RegistryValue -Root $UserRoot -Path 'System\GameConfigStore' -Name 'GameDVR_Enabled' -Value 0

    # Tweak aggiuntivi: notifiche, AutoPlay, reattività e effetti grafici ridotti.
    Set-RegistryValue -Root $UserRoot -Path 'Software\Microsoft\Windows\Windows Error Reporting' -Name 'DontShowUI' -Value 1
    Set-RegistryValue -Root $UserRoot -Path 'Software\Microsoft\Windows\Windows Error Reporting' -Name 'Disabled' -Value 1

    $explorerPolicies = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    Set-RegistryValue -Root $UserRoot -Path $explorerPolicies -Name 'HideSCAHealth' -Value 1
    Set-RegistryValue -Root $UserRoot -Path $explorerPolicies -Name 'NoInternetOpenWith' -Value 1
    Set-RegistryValue -Root $UserRoot -Path $explorerPolicies -Name 'NoDriveTypeAutoRun' -Value 255
    Set-RegistryValue -Root $UserRoot -Path 'Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers' -Name 'DisableAutoplay' -Value 1
    Set-RegistryValue -Root $UserRoot -Path 'Software\Microsoft\Windows\CurrentVersion\Explorer' -Name 'link' -Value ([byte[]](0,0,0,0)) -Kind Binary

    Set-RegistryValue -Root $UserRoot -Path $explorerAdvanced -Name 'Start_ShowRun' -Value 1
    Set-RegistryValue -Root $UserRoot -Path $explorerAdvanced -Name 'ListviewShadow' -Value 0
    Set-RegistryValue -Root $UserRoot -Path $explorerAdvanced -Name 'IconsOnly' -Value 1
    Set-RegistryValue -Root $UserRoot -Path $explorerAdvanced -Name 'WebView' -Value 0
    Set-RegistryValue -Root $UserRoot -Path $explorerAdvanced -Name 'TaskbarAnimations' -Value 0
    Set-RegistryValue -Root $UserRoot -Path $explorerAdvanced -Name 'ListviewAlphaSelect' -Value 0
    Set-RegistryValue -Root $UserRoot -Path 'Software\Microsoft\Windows\DWM' -Name 'ColorizationOpaqueBlend' -Value 1

    $desktop = 'Control Panel\Desktop'
    Set-RegistryValue -Root $UserRoot -Path $desktop -Name 'MenuShowDelay' -Value '1' -Kind String
    Set-RegistryValue -Root $UserRoot -Path $desktop -Name 'DragFullWindows' -Value '0' -Kind String
    Set-RegistryValue -Root $UserRoot -Path $desktop -Name 'AutoEndTasks' -Value 1
    Set-RegistryValue -Root $UserRoot -Path $desktop -Name 'HungAppTimeout' -Value '2000' -Kind String
    Set-RegistryValue -Root $UserRoot -Path $desktop -Name 'WaitToKillAppTimeout' -Value '4000' -Kind String
    Set-RegistryValue -Root $UserRoot -Path $desktop -Name 'WaitToKillServiceTimeout' -Value '4000' -Kind String
    Set-RegistryValue -Root $UserRoot -Path "$desktop\WindowMetrics" -Name 'MinAnimate' -Value '0' -Kind String
    Set-RegistryValue -Root $UserRoot -Path 'Software\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'AutoRestartShell' -Value 1

    Set-RegistryValue -Root $UserRoot -Path 'Software\Microsoft\Internet Explorer\TabbedBrowsing' -Name 'PopupsUseNewWindow' -Value 2
    Set-RegistryValue -Root $UserRoot -Path 'Software\Microsoft\Internet Explorer\TabbedBrowsing' -Name 'WarnOnClose' -Value 0
    Set-RegistryValue -Root $UserRoot -Path 'Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell' -Name 'FolderType' -Value 'NotSpecified' -Kind String

}

function Set-DefaultProfilePreferences {
    $hiveName = 'NewPCDefault'
    $hiveRoot = "Registry::HKEY_USERS\$hiveName"
    $defaultHive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'

    if (-not (Test-Path -LiteralPath $defaultHive -PathType Leaf)) {
        throw "Hive del profilo predefinito non trovato: $defaultHive"
    }
    if (Test-Path -LiteralPath $hiveRoot) {
        Write-Log "Rilevato HKU\$hiveName da una precedente esecuzione; scaricamento in corso." -Level WARN
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Invoke-Native -FilePath "$env:SystemRoot\System32\reg.exe" -Arguments @('unload', "HKU\$hiveName") -SuccessCodes @(0)
    }

    Invoke-Native -FilePath "$env:SystemRoot\System32\reg.exe" -Arguments @(
        'load', "HKU\$hiveName", $defaultHive
    ) -SuccessCodes @(0)

    try {
        Set-UserRegistryPreferences -UserRoot $hiveRoot
        Write-Log 'Preferenze applicate al profilo utente predefinito.' -Level OK
    }
    finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 500
        & "$env:SystemRoot\System32\reg.exe" 'unload' "HKU\$hiveName" 2>&1 |
            ForEach-Object { if ($null -ne $_) { Write-Log ([string]$_) } }
        if ($LASTEXITCODE -ne 0) {
            throw "Impossibile scaricare HKU\$hiveName (codice $LASTEXITCODE)."
        }
    }
}

function Remove-PublicDesktopShortcuts {
    $publicDesktop = Join-Path $env:ALLUSERSPROFILE 'Desktop'
    if (-not (Test-Path -LiteralPath $publicDesktop -PathType Container)) {
        Write-Log "Desktop pubblico non trovato: $publicDesktop" -Level WARN
        return
    }

    $shortcuts = @(Get-ChildItem -LiteralPath $publicDesktop -Filter '*.lnk' -File -ErrorAction SilentlyContinue)
    foreach ($shortcut in $shortcuts) {
        Remove-Item -LiteralPath $shortcut.FullName -Force
        Write-Log "Rimosso $($shortcut.FullName)"
    }
    Write-Log "Collegamenti rimossi dal desktop pubblico: $($shortcuts.Count)." -Level OK
}

function Remove-StoreApplications {
    # App consumer e strumenti sostituiti dai programmi installati dallo script.
    # Vengono sempre preservati Calcolatrice, Foto, Store, App Installer/WinGet,
    # Windows Terminal, Edge, framework e componenti Shell necessari a Windows.
    $protectedPackages = @(
        'Microsoft.WindowsCalculator',
        'Microsoft.Windows.Photos',
        'Microsoft.WindowsStore',
        'Microsoft.StorePurchaseApp',
        'Microsoft.DesktopAppInstaller',
        'Microsoft.WindowsTerminal'
    )
    $packagePatterns = @(
        'Clipchamp.Clipchamp',
        'Microsoft.549981C3F5F10',
        'Microsoft.3DBuilder',
        'Microsoft.BingFinance',
        'Microsoft.BingFoodAndDrink',
        'Microsoft.BingHealthAndFitness',
        'Microsoft.BingNews',
        'Microsoft.BingSearch',
        'Microsoft.BingSports',
        'Microsoft.BingTravel',
        'Microsoft.BingWeather',
        'Microsoft.Copilot',
        'Microsoft.GamingApp',
        'Microsoft.GamingServices',
        'Microsoft.GetHelp',
        'Microsoft.Getstarted',
        'Microsoft.Messaging',
        'Microsoft.Microsoft3DViewer',
        'Microsoft.MicrosoftJournal',
        'Microsoft.MicrosoftOfficeHub',
        'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MicrosoftStickyNotes',
        'Microsoft.MixedReality.Portal',
        'Microsoft.MSPaint',
        'Microsoft.Office.OneNote',
        'Microsoft.OneConnect',
        'Microsoft.OutlookForWindows',
        'Microsoft.Paint',
        'Microsoft.People',
        'Microsoft.PowerAutomateDesktop',
        'Microsoft.Print3D',
        'Microsoft.ScreenSketch',
        'Microsoft.SkypeApp',
        'Microsoft.Todos',
        'Microsoft.Windows.DevHome',
        'Microsoft.WindowsAlarms',
        'Microsoft.WindowsCamera',
        'Microsoft.WindowsCommunicationsApps',
        'Microsoft.WindowsFeedbackHub',
        'Microsoft.WindowsMaps',
        'Microsoft.WindowsNotepad',
        'Microsoft.WindowsSoundRecorder',
        'Microsoft.Xbox.TCUI',
        'Microsoft.XboxApp',
        'Microsoft.XboxGameOverlay',
        'Microsoft.XboxGamingOverlay',
        'Microsoft.XboxIdentityProvider',
        'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.YourPhone',
        'Microsoft.ZuneMusic',
        'Microsoft.ZuneVideo',
        'MicrosoftCorporationII.MicrosoftFamily',
        'MicrosoftCorporationII.QuickAssist',
        'MicrosoftTeams',
        'MSTeams',
        'MicrosoftWindows.CrossDevice',
        'SpotifyAB.SpotifyMusic',
        'Disney.37853FC22B2CE',
        'king.com.*',
        'ZyngaNetworks.*'
    )

    $installedPackages = @(Get-AppxPackage -AllUsers | Where-Object {
        $packageName = $_.Name
        $protectedPackages -notcontains $packageName -and
            @($packagePatterns | Where-Object { $packageName -like $_ }).Count -gt 0
    })
    foreach ($package in $installedPackages) {
        try {
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers
            Write-Log "AppX rimosso per gli utenti: $($package.Name)" -Level OK
        }
        catch {
            $allUsersError = $_.Exception.Message
            try {
                Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
                Write-Log "AppX rimosso almeno per l'utente corrente: $($package.Name)" -Level WARN
            }
            catch {
                $script:Failures += "Rimozione AppX $($package.Name)"
                Write-Log "Impossibile rimuovere $($package.Name): $allUsersError; fallback utente: $($_.Exception.Message)" -Level ERROR
            }
        }
    }

    $provisionedPackages = @(Get-AppxProvisionedPackage -Online | Where-Object {
        $packageName = $_.DisplayName
        $protectedPackages -notcontains $packageName -and
            @($packagePatterns | Where-Object { $packageName -like $_ }).Count -gt 0
    })
    foreach ($package in $provisionedPackages) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName | Out-Null
            Write-Log "Provisioning rimosso per i nuovi utenti: $($package.DisplayName)" -Level OK
        }
        catch {
            $script:Failures += "Rimozione provisioning $($package.DisplayName)"
            Write-Log "Impossibile rimuovere il provisioning $($package.DisplayName): $($_.Exception.Message)" -Level ERROR
        }
    }

    Write-Log "Elaborazione app Store completata: $($installedPackages.Count) installati e $($provisionedPackages.Count) provisioning trovati." -Level OK
}

function Set-MachinePolicies {
    # Applica lo stesso stile Open-Shell a ogni utente e impedisce il prompt iniziale.
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path 'SOFTWARE\Policies\OpenShell\StartMenu' -Name 'MenuStyle' -Value 1

    # Disabilita i Widget di Windows 11 a livello di computer.
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path 'SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0

    # Cortana non è un servizio autonomo: viene disabilitato tramite il relativo criterio.
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path 'SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'AllowCortana' -Value 0

    # Primo accesso: niente animazione iniziale, pagine privacy o suggerimenti OOBE.
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'EnableFirstLogonAnimation' -Value 0
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path 'SOFTWARE\Policies\Microsoft\Windows\OOBE' -Name 'DisablePrivacyExperience' -Value 1
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path 'SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableSoftLanding' -Value 1
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path 'SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableCloudOptimizedContent' -Value 1

    # Windows Update: solo controllo/installazione manuale; interfaccia manuale ancora disponibile.
    $windowsUpdatePolicy = 'SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path "$windowsUpdatePolicy\AU" -Name 'NoAutoUpdate' -Value 1
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path "$windowsUpdatePolicy\AU" -Name 'AUOptions' -Value 2
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path $windowsUpdatePolicy -Name 'SetUpdateNotificationLevel' -Value 1
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path $windowsUpdatePolicy -Name 'UpdateNotificationLevel' -Value 2

    # Evita nuove app consumer, riduce l'attività in background e disabilita Game DVR/WER.
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path 'SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Value 1

    # Blocca a livello macchina nuove installazioni consumer per ogni profilo.
    $machineContentDelivery = 'SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($valueName in @(
        'ContentDeliveryAllowed', 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled',
        'SilentInstalledAppsEnabled', 'SoftLandingEnabled', 'SubscribedContentEnabled'
    )) {
        Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path $machineContentDelivery -Name $valueName -Value 0
    }

    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path 'SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' -Name 'LetAppsRunInBackground' -Value 2
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path 'SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name 'AllowGameDVR' -Value 0
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path 'SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' -Name 'Disabled' -Value 1

    # Chrome Enterprise: niente richiesta browser predefinito, schede promozionali,
    # esecuzione in background o aggiunta guidata di nuovi profili/persone.
    $chromePolicy = 'SOFTWARE\Policies\Google\Chrome'
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path $chromePolicy -Name 'DefaultBrowserSettingEnabled' -Value 0
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path $chromePolicy -Name 'PromotionalTabsEnabled' -Value 0
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path $chromePolicy -Name 'BackgroundModeEnabled' -Value 0
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path $chromePolicy -Name 'BrowserAddPersonEnabled' -Value 0
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path $chromePolicy -Name 'WelcomePageOnOSUpgradeEnabled' -Value 0
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path $chromePolicy -Name 'MetricsReportingEnabled' -Value 0
    Write-Log 'Criteri Windows e preimpostazioni Chrome Enterprise configurati.' -Level OK
}

function Set-AdditionalMachineTweaks {
    $root = 'Registry::HKEY_LOCAL_MACHINE'

    # Mostra "Apri prompt dei comandi" senza richiedere MAIUSC nel menu contestuale.
    foreach ($path in @(
        'Registry::HKEY_CLASSES_ROOT\Directory\Background\shell\cmd',
        'Registry::HKEY_CLASSES_ROOT\Directory\shell\cmd'
    )) {
        $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
        if ($null -ne $key -and $null -ne $key.GetValue('Extended', $null)) {
            Remove-ItemProperty -LiteralPath $path -Name 'Extended' -ErrorAction Stop
        }
    }

    # Niente riavvio automatico o dump dopo un arresto anomalo; messaggi di stato dettagliati.
    Set-RegistryValue -Root $root -Path 'SYSTEM\CurrentControlSet\Control\CrashControl' -Name 'AutoReboot' -Value 0
    Set-RegistryValue -Root $root -Path 'SYSTEM\CurrentControlSet\Control\CrashControl' -Name 'CrashDumpEnabled' -Value 0
    Set-RegistryValue -Root $root -Path 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'VerboseStatus' -Value 1

    foreach ($valueName in @(
        'AntiVirusDisableNotify', 'AntiSpyWareDisableNotify', 'FirewallDisableNotify',
        'AutoUpdateDisableNotify', 'UacDisableNotify'
    )) {
        Set-RegistryValue -Root $root -Path 'SOFTWARE\Microsoft\Security Center' -Name $valueName -Value 1
    }

    Set-RegistryValue -Root $root -Path 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'NoInternetOpenWith' -Value 1
    Set-RegistryValue -Root $root -Path 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'FilterAdministratorToken' -Value 0
    Set-RegistryValue -Root $root -Path 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'DontDisplayLastUserName' -Value 1
    Set-RegistryValue -Root $root -Path 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'ReportBootOk' -Value '0' -Kind String
    Set-RegistryValue -Root $root -Path 'SYSTEM\CurrentControlSet\Services\cdrom' -Name 'AutoRun' -Value 0

    # Consente a Windows Installer di operare anche in modalità provvisoria.
    Set-RegistryValue -Root $root -Path 'SYSTEM\CurrentControlSet\Control\SafeBoot\Minimal\MSIServer' -Name '' -Value 'Service' -Kind String
    Set-RegistryValue -Root $root -Path 'SYSTEM\CurrentControlSet\Control\SafeBoot\Network\MSIServer' -Name '' -Value 'Service' -Kind String
    Set-RegistryValue -Root $root -Path 'SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI\BootAnimation' -Name 'DisableStartupSound' -Value 1

    Write-Log 'Tweak aggiuntivi di sistema applicati.' -Level OK
}

function Set-TaskbarLayout {
    $layoutPath = Join-Path $WorkDirectory 'TaskbarLayout.xml'
    $layout = @'
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
        <taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer" />
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
'@
    [System.IO.File]::WriteAllText($layoutPath, $layout, (New-Object System.Text.UTF8Encoding($false)))

    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path 'SOFTWARE\Policies\Microsoft\Windows\Explorer' -Name 'StartLayoutFile' -Value $layoutPath -Kind ExpandString
    Invoke-Native -FilePath "$env:SystemRoot\System32\gpupdate.exe" -Arguments @('/target:computer', '/force') -SuccessCodes @(0)
    Write-Log "Layout taskbar applicato tramite criterio: solo Esplora risorse; Visualizzazione attività resta attiva." -Level OK
}

function Disable-RequestedServices {
    # Servizi non essenziali con attività residente o periodica su disco/memoria.
    # Non vengono toccati Defender, rete, RPC, audio, archiviazione, Spooler,
    # BITS e i servizi necessari al controllo manuale di Windows Update.
    $serviceNames = @(
        'WSearch',                 # Indicizzazione Windows Search
        'Themes',                  # Richiesto esplicitamente; modifica l'aspetto visivo
        'SysMain',                 # Prefetch/Superfetch
        'DiagTrack',               # Diagnostica e telemetria
        'dmwappushservice',        # Telemetria WAP push
        'WerSvc',                  # Segnalazione errori Windows
        'DPS',                     # Diagnostic Policy Service
        'WdiServiceHost',          # Host diagnostica
        'WdiSystemHost',           # Host diagnostica di sistema
        'PcaSvc',                  # Assistente compatibilità programmi
        'MapsBroker',              # Gestione mappe scaricate
        'RetailDemo',              # Modalità demo retail
        'WMPNetworkSvc',           # Condivisione rete Windows Media Player
        'Fax',
        'wisvc',                   # Windows Insider
        'shpamsvc',                # Shared PC
        'PhoneSvc',                # Collegamento telefono
        'SSDPSRV',
        'upnphost',
        'XblAuthManager',
        'XblGameSave',
        'XboxGipSvc',
        'XboxNetApiSvc',
        'GamingServices',
        'GamingServicesNet'
    )

    foreach ($serviceName in $serviceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            Write-Log "Servizio non presente: $serviceName"
            continue
        }

        try {
            Write-Log "Disabilitazione servizio $serviceName."
            Set-Service -Name $serviceName -StartupType Disabled
            Stop-ServiceIfNeeded -Name $serviceName
            Write-Log "Servizio $serviceName disabilitato e arrestato." -Level OK
        }
        catch {
            $script:Failures += "Disabilitazione servizio $serviceName"
            Write-Log "Impossibile disabilitare ${serviceName}: $($_.Exception.Message)" -Level ERROR
        }
    }

    # Coerente con SysMain disabilitato; può aumentare i tempi di avvio delle app.
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path 'SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' -Name 'EnablePrefetcher' -Value 0
    Set-RegistryValue -Root 'Registry::HKEY_LOCAL_MACHINE' -Path 'SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' -Name 'EnableSuperfetch' -Value 0
}

function Set-AcPowerPreferences {
    $powercfg = "$env:SystemRoot\System32\powercfg.exe"

    # Sola alimentazione AC: niente sospensione, ibernazione, spegnimento disco,
    # sospensione ibrida o azione di sospensione tramite chiusura coperchio/pulsante.
    Invoke-Native -FilePath $powercfg -Arguments @('/x', '-standby-timeout-ac', '0') -SuccessCodes @(0)
    Invoke-Native -FilePath $powercfg -Arguments @('/x', '-hibernate-timeout-ac', '0') -SuccessCodes @(0)
    Invoke-Native -FilePath $powercfg -Arguments @('/x', '-disk-timeout-ac', '0') -SuccessCodes @(0)
    Invoke-Native -FilePath $powercfg -Arguments @('/setacvalueindex', 'scheme_current', 'sub_sleep', 'hybridsleep', '0') -SuccessCodes @(0)
    Invoke-Native -FilePath $powercfg -Arguments @('/setacvalueindex', 'scheme_current', 'sub_buttons', 'lidaction', '0') -SuccessCodes @(0)
    Invoke-Native -FilePath $powercfg -Arguments @('/setacvalueindex', 'scheme_current', 'sub_buttons', 'sbuttonaction', '0') -SuccessCodes @(0)
    Invoke-Native -FilePath $powercfg -Arguments @('/setactive', 'scheme_current') -SuccessCodes @(0)
    Invoke-Native -FilePath $powercfg -Arguments @('/h', 'off') -SuccessCodes @(0)

    # -monitor-timeout-ac non viene modificato: il monitor conserva il proprio timeout.
    Write-Log 'Sospensione e ibernazione disabilitate su AC; timeout monitor invariato.' -Level OK
}

function Restart-WindowsShell {
    & "$env:SystemRoot\System32\rundll32.exe" 'user32.dll,UpdatePerUserSystemParameters'
    Get-Process -Name 'explorer' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    if ($null -eq (Get-Process -Name 'explorer' -ErrorAction SilentlyContinue)) {
        Start-Process "$env:SystemRoot\explorer.exe"
    }
    Write-Log 'Shell Windows riavviata; per tutte le preferenze è comunque consigliato un nuovo accesso.' -Level OK
}

function Invoke-ChrisTitusWinUtil {
    Write-Log 'Avvio di https://christitus.com/win in una finestra PowerShell elevata separata.' -Level WARN
    $command = "Invoke-RestMethod -Uri 'https://christitus.com/win' | Invoke-Expression"
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $powerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $winUtil = Start-Process -FilePath $powerShell -ArgumentList @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand
    ) -PassThru

    Write-Log 'Attesa di WinUtil per un massimo di 20 minuti.'
    if (-not $winUtil.WaitForExit(1200000)) {
        Write-Log 'Timeout di 20 minuti raggiunto: WinUtil resta aperto e lo script termina.' -Level WARN
        return
    }
    if ($winUtil.ExitCode -ne 0) {
        throw "WinUtil terminato con codice $($winUtil.ExitCode)."
    }
    Write-Log 'WinUtil chiuso prima del timeout.' -Level OK
}

function Export-WingetSoftware {
    if ($null -eq $script:WingetExe) {
        throw 'WinGet non disponibile: impossibile esportare i pacchetti installati.'
    }

    $exportPath = Join-Path (Get-Location).Path 'winget.json'
    if (Test-Path -LiteralPath $exportPath) {
        Remove-Item -LiteralPath $exportPath -Force
    }

    Invoke-Native -FilePath $script:WingetExe -Arguments @(
        'export', '--output', $exportPath, '--include-versions',
        '--accept-source-agreements', '--disable-interactivity'
    ) -SuccessCodes @(0)
    if (-not (Test-Path -LiteralPath $exportPath -PathType Leaf)) {
        throw "WinGet non ha creato il file di esportazione: $exportPath"
    }
    Write-Log "Pacchetti installati esportati in $exportPath." -Level OK
}

function Clear-Temp {
    if ([string]::IsNullOrWhiteSpace($env:TEMP)) {
        throw 'Variabile TEMP non definita.'
    }

    $tempPath = [System.IO.Path]::GetFullPath($env:TEMP)
    if (-not (Test-Path -LiteralPath $tempPath -PathType Container)) {
        Write-Log "Cartella temporanea non trovata: $tempPath" -Level WARN
        return
    }

    $removed = 0
    $skipped = 0
    $items = @(Get-ChildItem -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue)
    foreach ($item in $items) {
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            $removed++
        }
        catch {
            $skipped++
            Write-Log "Elemento temporaneo non rimosso: $($item.FullName). $($_.Exception.Message)" -Level WARN
        }
    }
    Write-Log "Pulizia %TEMP% completata: $removed elementi rimossi, $skipped bloccati o non rimovibili." -Level OK
}

function Clear-DeliveryOptimizationCache {
    $service = Get-Service -Name 'DoSvc' -ErrorAction SilentlyContinue
    if ($null -ne $service) {
        Stop-ServiceIfNeeded -Name 'DoSvc'
    }
    else {
        Write-Log 'Servizio DoSvc non presente; pulizia cache comunque eseguita.' -Level WARN
    }

    try {
        $cachePath = Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
        if (-not (Test-Path -LiteralPath $cachePath -PathType Container)) {
            Write-Log "Cache Delivery Optimization non presente: $cachePath"
            return
        }

        $removed = 0
        $skipped = 0
        $items = @(Get-ChildItem -LiteralPath $cachePath -Force -ErrorAction Stop)
        foreach ($item in $items) {
            try {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                $removed++
            }
            catch {
                $skipped++
                Write-Log "Elemento cache non rimosso: $($item.FullName). $($_.Exception.Message)" -Level WARN
            }
        }
        Write-Log "Cache Delivery Optimization pulita: $removed elementi rimossi, $skipped non rimovibili." -Level OK
    }
    finally {
        if ($null -ne $service) {
            Start-ServiceIfNeeded -Name 'DoSvc'
        }
    }
}

if (-not (Test-IsAdministrator)) {
    throw 'Eseguire lo script da Windows PowerShell come amministratore, nel profilo utente da configurare.'
}

$os = Get-CimInstance Win32_OperatingSystem
if ($os.Caption -notmatch 'Windows 11' -or $os.Caption -notmatch 'Pro') {
    Write-Log "Sistema rilevato: $($os.Caption). Lo script è predisposto per Windows 11 Pro." -Level WARN
}

try {
    Start-Transcript -Path $LogPath -Force | Out-Null
    Write-Log "Cartella sorgente: $PSScriptRoot"
    Write-Log "Log: $LogPath"

    Invoke-Step 'Desktop remoto per Everyone' { Enable-RemoteDesktopForEveryone }
    Invoke-Step 'Ridenominazione computer da indirizzo MAC' { Set-ComputerNameFromMac }
    Invoke-Step 'Copia cartella bin' { Copy-OptionalDirectory -Name 'bin' -Destination 'C:\bin' }
    Invoke-Step 'Aggiornamento PATH di sistema' { Add-SystemPathEntry -Entry 'C:\bin' }
    Invoke-Step 'Copia cartella apps' { Copy-OptionalDirectory -Name 'apps' -Destination 'C:\apps' }
    Invoke-Step 'Copia configurazione Software Policy' { Copy-SoftwarePolicyFile }
    Invoke-Step 'Creazione account adm' { Ensure-LocalAccount -Name 'adm' -Administrator }
    Invoke-Step 'Creazione account usr' { Ensure-LocalAccount -Name 'usr' }
    Invoke-Step 'Soglia blocco account locali' {
        Invoke-Native -FilePath "$env:SystemRoot\System32\net.exe" -Arguments @('accounts', '/lockoutthreshold:9') -SuccessCodes @(0)
    }
    Invoke-Step 'Configurazione UAC amministratori' { Set-AdministratorUacBehavior }
    Invoke-Step 'Configurazione cache temporanea WinGet' { Set-WingetCacheLocation }
    Invoke-Step 'Inizializzazione WinGet e Chocolatey' { Initialize-PackageManagers }

    if ($null -ne $script:ChocoExe) {
        Invoke-Step 'Configurazione cache temporanea Chocolatey' { Set-ChocolateyCacheLocation }
        Invoke-Step 'Installazione applicazioni' { Install-RequestedApplications }
    }
    else {
        $script:Failures += 'Installazione applicazioni e associazioni'
        Write-Log 'Chocolatey non disponibile: installazioni e associazioni saltate.' -Level ERROR
    }
    Invoke-Step 'Installazione MSI dalla cartella sw' { Install-LocalMsiPackages }

    Invoke-Step 'Attivazione Telnet, .NET 3.5 ed eventuale RSAT' { Enable-EnterpriseWindowsFeatures }
    Invoke-Step 'Amministrazione remota e condivisioni amministrative' { Enable-EnterpriseRemoteManagement }

    if ($null -ne $script:ChocoExe) {
        Invoke-Step 'Installazione e configurazione LiteManager Server' { Install-LiteManagerServer }
        Invoke-Step 'Configurazione servizio Everything' { Set-EverythingEnterpriseConfiguration }
    }
    Invoke-Step 'Ripristino cache predefinite WinGet e Chocolatey' { Reset-PackageCacheLocations }

    # I criteri consumer precedono la rimozione per evitare reinstallazioni immediate.
    Invoke-Step 'Criteri locali Windows 11' { Set-MachinePolicies }
    Invoke-Step 'Rimozione app Store per utenti esistenti e futuri' { Remove-StoreApplications }

    if ($null -ne $script:ChocoExe) {
        Invoke-Step 'Configurazione applicazioni predefinite' { Set-DefaultApplications }
    }

    Invoke-Step 'Tweak aggiuntivi di sistema' { Set-AdditionalMachineTweaks }
    Invoke-Step 'Preferenze utente corrente' { Set-UserRegistryPreferences -UserRoot 'Registry::HKEY_CURRENT_USER' }
    Invoke-Step 'Preferenze profilo predefinito' { Set-DefaultProfilePreferences }
    Invoke-Step 'Distribuzione preset uniformi applicazioni' { Copy-UniformUserPresets }
    Invoke-Step 'Layout taskbar Windows 11' { Set-TaskbarLayout }
    Invoke-Step 'Pulizia collegamenti desktop pubblico' { Remove-PublicDesktopShortcuts }
    Invoke-Step 'Disabilitazione servizi non essenziali e attività in background' { Disable-RequestedServices }
    Invoke-Step 'Risparmio energia su alimentazione AC' { Set-AcPowerPreferences }
    Invoke-Step 'Aggiornamento shell Windows' { Restart-WindowsShell }
    Invoke-Step 'Esportazione pacchetti installati con WinGet' { Export-WingetSoftware }
    Invoke-Step 'Pulizia cartella %TEMP%' { Clear-Temp }
    Invoke-Step 'Pulizia cache Delivery Optimization' { Clear-DeliveryOptimizationCache }

    # WinUtil è l'ultima operazione e può sovrascrivere le personalizzazioni precedenti.
    # Dopo l'avvio lo script attende l'utente per un massimo di 20 minuti.
    $startWinUtil = $false
    if ($RunChrisTitus -and -not $SkipChrisTitus) {
        $startWinUtil = $true
    }
    elseif (-not $SkipChrisTitus) {
        $startWinUtil = Read-YesNoWithTimeout -Prompt 'Avviare Chris Titus WinUtil interattivo?' -Default $false -TimeoutSeconds 10
    }

    if ($startWinUtil) {
        Invoke-Step 'Chris Titus WinUtil e attesa utente (massimo 20 minuti)' { Invoke-ChrisTitusWinUtil }
    }
    else {
        Write-Log 'Chris Titus WinUtil non avviato (default, conferma negativa o -SkipChrisTitus).'
    }

    Write-Log 'Configurazione terminata. Riavvio e nuovo accesso consigliati prima della verifica finale.' -Level WARN
    if ($script:Failures.Count -gt 0) {
        throw ("Operazioni da verificare: {0}. Consultare il log {1}" -f ($script:Failures -join '; '), $LogPath)
    }
}
finally {
    if ($script:WingetCacheConfigured -or $script:ChocoCacheConfigured) {
        try { Reset-PackageCacheLocations }
        catch { Write-Log "Ripristino cache nella fase finale non riuscito: $($_.Exception.Message)" -Level ERROR }
    }
    try { Stop-Transcript | Out-Null } catch { }
}
