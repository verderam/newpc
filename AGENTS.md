# Contesto operativo newpc

Questo file è la fonte di continuità per chi riprende il progetto in una nuova chat. Leggerlo insieme a `README.md` e alla versione corrente di `newpc.ps1` prima di modificare il codice. Non ricostruire il progetto da zero e non rimuovere funzionalità senza una richiesta esplicita.

## Obiettivo e preferenze

- Provisioning tradizionale, deterministico e ripetibile di PC **Windows 11 Pro** partendo da un'installazione pulita.
- L'AI genera e mantiene gli script, ma non deve essere una dipendenza del provisioning.
- Script canonico: `newpc.ps1`, Windows PowerShell **5.1**, eseguito come amministratore.
- Deve essere idempotente: controllare lo stato reale soltanto dove una ripetizione causerebbe errori, duplicazioni o interruzioni inutili.
- Utente: Valerio; risposte e documentazione in italiano, concise; nomi file brevi.
- A ogni richiesta accettata: aggiornare la repository, validare, fare commit e push. Mantenere aggiornato anche questo file quando cambiano comportamento, dipendenze o flusso di lavoro.

## Repository

- GitHub: `git@github.com:verderam/newpc.git`
- Branch di lavoro attuale: `main`.
- È già stata autorizzata una Deploy key SSH con accesso in scrittura. La chiave privata non deve mai essere pubblicata nella repository o incollata in chat; in una nuova sessione verificare che le credenziali SSH siano disponibili.
- Prima delle modifiche: `git pull --ff-only`.
- Prima del commit: `git diff --check`, controllo della sintassi e revisione di `git diff`.
- Non pubblicare log, `winget.json`, password, token, chiavi private o configurazioni contenenti segreti.

## Parametri attuali

```powershell
.\newpc.ps1 [-InstallRSAT] [-RunChrisTitus] [-SkipChrisTitus]
             [-SetUserFTAPath <percorso>] [-NetFx3Source <percorso>]
```

- RSAT è **disabilitato per default**; installarlo soltanto con `-InstallRSAT`.
- WinUtil viene proposto alla fine con conferma di 10 secondi e default negativo.
- `-RunChrisTitus` lo avvia senza conferma; `-SkipChrisTitus` lo esclude.
- Se avviato, WinUtil gira in una finestra PowerShell elevata separata. Lo script attende al massimo **20 minuti**, poi termina lasciando WinUtil aperto se ancora in uso.

## Comportamento da preservare

### Sistema e account

- Abilita RDP e aggiunge Everyone al gruppo Desktop remoto tramite SID `S-1-1-0` e `S-1-5-32-555`.
- Rinomina il PC `W-XXXXXX` con gli ultimi sei caratteri esadecimali del MAC della prima scheda fisica ordinata per `ifIndex`; rispetta un nome già attivo o pendente.
- Crea `adm` amministratore e `usr` standard soltanto se assenti. Password mascherata con timeout di 10 secondi: password immessa = senza scadenza; timeout/Invio vuoto = account senza password e cambio obbligatorio al primo accesso. Non usare WMIC.
- UAC resta attivo (`EnableLUA=1`), ma senza prompt per gli amministratori (`ConsentPromptBehaviorAdmin=0`, `PromptOnSecureDesktop=0`).
- Copia `bin` in `C:\bin`, `apps` in `C:\apps` e `settings\softwarepolicy.ini` in `C:\Windows\softwarepolicy`; Robocopy 0–7 è successo.
- Aggiunge `C:\bin` alla PATH senza duplicazioni, normalizzando gli slash finali e preservando il tipo Registry.

### Applicazioni

Installazione con WinGet e fallback Chocolatey, saltando pacchetti già rilevati:

- VLC, Veeam Agent, dupeGuru, FileZilla, Notepad++;
- PDF-XChange Editor, 7-Zip, LibreOffice, Open-Shell, PDF24;
- Google Chrome Enterprise, Google Drive, Revo Uninstaller, XnView MP;
- Everything, Simple Software Restriction Policy;
- LiteManager Server tramite Chocolatey `litemanager-server`.

Chocolatey viene installato tramite WinGet se assente. Non trasformare un errore di autenticazione/rete/package manager in un falso “già installato”.

### Associazioni

- Chrome per protocolli/formati registrati, tranne PDF.
- PDF-XChange Editor per PDF; supportare anche registrazioni `PXCEditor` e il fallback `NewPC.PDFXChange.Document`.
- 7-Zip per i formati registrati, tranne ISO/VHD/VHDX.
- XnView MP/Pro per immagini tramite `NewPC.XnView.Image`.
- VLC per video, non audio, tramite `NewPC.VLC.Video`.
- Non scrivere direttamente gli hash `UserChoice`: DISM per nuovi profili, criterio `DefaultAssociationsConfiguration` per tutti e SetUserFTA per l'utente corrente.
- SetUserFTA 2.x usa chiamate raggruppate per ProgID; 1.x usa un file di configurazione.

### Preferenze e pulizia

- Open-Shell “Classic with two columns”: `MenuStyle=1`, `ShowedStyle2=1`.
- Primo accesso senza domande iniziali: `EnableFirstLogonAnimation=0`, criterio `DisablePrivacyExperience=1`, suggerimenti/Windows Welcome disattivati e `ScoobeSystemSettingEnabled=0` nei profili corrente/Default. Non usare `SkipMachineOOBE` o `SkipUserOOBE`; lo script agisce sul primo accesso dei profili, non sostituisce un file Unattend per l'OOBE iniziale del sistema. Il cambio password obbligatorio resta invariato.
- Sfondo blu navy; niente Widget/ricerca; taskbar soltanto Esplora risorse e Visualizzazione attività tramite `TaskbarLayout.xml`.
- Finestre Explorer in un solo processo.
- Preserva sempre Calcolatrice, Foto, Store e componenti necessari; rimuove AppX consumer per utenti e provisioning.
- Distribuisce preset ai profili corrente, esistenti e Default; l'hive Default usa `HKU\NewPCDefault` e va sempre scaricato, anche dopo errori/interruzioni.
- Disabilita servizi consumer/background indicati nello script, Cortana tramite criterio, ibernazione e sospensioni AC; non modificare il timeout del monitor.
- Windows Update manuale senza notifiche.
- Tweak aggiuntivi: menu contestuale CMD senza `Extended`; niente riavvio automatico/dump dopo crash; stato avvio dettagliato; notifiche Security Center disattivate; `FilterAdministratorToken=0`; ultimo utente non visualizzato; AutoRun/AutoPlay disattivati; MSIServer in modalità provvisoria; suono di avvio disattivato.
- Tweak utente: WER senza interfaccia, effetti/animazioni ridotti, menu e timeout di chiusura più rapidi, `AutoEndTasks=1`, `AutoRestartShell=1`, tipo cartella generico `NotSpecified` e vecchie preferenze IE richieste.
- Non applicare `DesktopProcess=1` o `SeparateProcess=1`: contraddicono le finestre Explorer in un solo processo (`SeparateProcess=0`).
- Al termine: `winget export --include-versions` in `winget.json` nella directory corrente, poi pulizia del contenuto di `%TEMP%`. File temporanei bloccati = avviso, non fallimento.
- WinUtil è volutamente l'**ultima operazione** e può sovrascrivere le personalizzazioni precedenti.

### Amministrazione remota e funzionalità

- Telnet Client e .NET 3.5 sempre; RSAT soltanto su richiesta tramite parametro.
- Condivisioni amministrative `C$`/`ADMIN$`, WinRM/WMI, `LocalAccountTokenFilterPolicy=1`; SMB1 non va abilitato.
- `LanmanServer` va riavviato soltanto quando cambia `AutoShareWks`.
- Everything deve operare come servizio, senza avvio automatico della GUI o notifiche aggiornamenti.
- LiteManager deve usare autenticazione Windows e consentire accesso soltanto agli amministratori.

## Dipendenze esterne non presenti nella repository

La struttura attesa accanto allo script è:

```text
newpc.ps1
bin\SetUserFTA.exe
apps\
settings\softwarepolicy.ini
settings\LiteManagerServer.reg
settings\user-presets\
```

- `SetUserFTA.exe`: necessario per applicare subito le associazioni all'utente corrente; non inventarne un'implementazione.
- `softwarepolicy.ini`: senza il file la relativa fase fallisce.
- `LiteManagerServer.reg`: obbligatorio per la configurazione aziendale, esportato da un Server di riferimento con WinNT security, Administrators Full Control, nessun altro utente, fallback password e consenso utente disabilitati.
- LiteManager viene comunque **installato prima** del controllo del REG. Se il REG manca, ROMServer resta arrestato e lo script segnala la configurazione mancante. Non inventare valori Registry LiteManager.
- `apps` e `user-presets` sono opzionali; i preset hanno struttura speculare al profilo, ad esempio `AppData\Roaming\Notepad++\config.xml`.
- `.NET 3.5` può richiedere `-NetFx3Source 'D:\sources\sxs'` in assenza di una sorgente online.

## Problemi già affrontati: non reintrodurli

- `Add-WindowsCapability` in Windows PowerShell 5.1 **non accetta `-NoRestart`**: non ripristinarlo.
- La PATH va scritta aprendo la chiave Registry in scrittura; `Get-Item` seguito da `SetValue` ha causato accesso negato.
- Le scritture Registry usano `RegistryKey.CreateSubKey(..., $true)` e devono riportare chiave/valore esatti in caso di errore.
- Everything può restituire codice 1 se configurato mentre il client si sta chiudendo: usare `-exit -wait` prima delle opzioni.
- PDF-XChange 11 può registrare `PXCEditor.PDF`; non limitare il rilevamento ai soli nomi `PDFX`.
- Il controllo preventivo del REG LiteManager impediva l'installazione: il pacchetto deve essere installato prima.
- Per i servizi gestire anche `StartPending` e `StopPending`; non riavviare ripetutamente servizi senza necessità.
- Le funzionalità Windows già `Enabled`/`EnablePending` e RSAT `Installed`/`InstallPending` non vanno reinstallate.
- Gli avvisi di `winget export` su pacchetti non presenti nelle origini non sono necessariamente errori.
- Il batch di tweak fornito dall'utente contiene voci duplicate, percorsi errati (`SOFTWARE\SOFTWARE`, `HKLMHKEY_LOCAL_MACHINE`), impostazioni IDE/cache hardware-specifiche e vecchie chiavi Windows Update: non importarlo ciecamente. Sono stati integrati soltanto i tweak compatibili, correggendo percorsi e tipi; `AutoReboot` è impostato a 0 invece di essere eliminato.

## Stato della verifica

- La sintassi è stata validata staticamente dopo le modifiche.
- Un'esecuzione reale del 2026-10-25 ha evidenziato i problemi sopra elencati; le correzioni successive devono ancora essere confermate su VM.
- Non affermare che il provisioning è completamente testato finché non sono disponibili risultati reali.

### Prova minima richiesta su VM Windows 11 Pro

1. Eseguire due volte consecutive, inclusa una ripetizione prima del riavvio.
2. Verificare che non ricompaiano errori PATH/Registry e che non si duplichino voci PATH.
3. Verificare account, nome PC, RDP, pacchetti e servizi già presenti.
4. Verificare che RSAT non venga installato per default e che `-InstallRSAT` funzioni.
5. Verificare LiteManager sia installato; senza REG deve restare arrestato, con REG deve essere configurato e avviato.
6. Verificare Everything, PDF-XChange e tutte le associazioni per utente corrente e nuovo utente.
7. Verificare profilo Default, taskbar, Open-Shell, `winget.json`, `%TEMP%` e attesa WinUtil.
8. Controllare `%ProgramData%\NewPC\logs` e allegare il nuovo log se restano errori.
