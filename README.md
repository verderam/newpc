# newpc

Script PowerShell 5.1 per configurare in modo rapido e ripetibile un client **Windows 11 Pro**, con installazione delle applicazioni, preferenze utente, associazioni dei file e amministrazione remota.

## Uso

Eseguire da Windows PowerShell come amministratore:

```powershell
.\newpc.ps1
```

Opzioni principali:

```powershell
# Installa anche tutte le funzionalità RSAT disponibili
.\newpc.ps1 -InstallRSAT

# Avvia automaticamente Chris Titus WinUtil al termine
.\newpc.ps1 -RunChrisTitus

# Salta Chris Titus WinUtil senza chiedere conferma
.\newpc.ps1 -SkipChrisTitus

# Usa una sorgente offline per .NET Framework 3.5
.\newpc.ps1 -NetFx3Source 'D:\sources\sxs'
```

## File accessori

Affiancare allo script questa struttura, secondo necessità:

```text
newpc.ps1
bin\SetUserFTA.exe
apps\
settings\softwarepolicy.ini
settings\LiteManagerServer.reg
settings\user-presets\
```

- `bin` viene copiato in `C:\bin` e aggiunto alla PATH; `SetUserFTA.exe` applica subito le associazioni all'utente corrente.
- `apps` viene copiato in `C:\apps`.
- `softwarepolicy.ini` viene copiato in `C:\Windows\softwarepolicy`.
- `LiteManagerServer.reg` contiene la configurazione aziendale di LiteManager Server. Senza questo file il pacchetto viene installato, ma il server resta arrestato e non configurato.
- `user-presets` replica la struttura dei profili utente e distribuisce le preimpostazioni applicative.

Al termine viene creato `winget.json` nella cartella corrente e svuotata la cartella `%TEMP%`. I log sono salvati in `C:\ProgramData\NewPC\logs`.

> Lo script abilita opzioni amministrative che riducono alcune protezioni, tra cui RDP per Everyone e prompt UAC disabilitato per gli amministratori. Verificarne la conformità ai criteri aziendali e provarlo prima su una VM Windows 11 Pro.
