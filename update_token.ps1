#Requires -Version 5.1
# FC27 Token Updater - WPF GUI edition
# Local license extraction using only Windows PowerShell and built-in .NET APIs.
# Gate flow: verify 16425884_sc.dlf license -> if missing, guide the user to own
# (Steam store), install, and launch appid 4407750 so the license file is created.
[CmdletBinding()]
param(
    [string]$GameDir,
    [string]$LicensePath = (Join-Path $env:ProgramData 'Electronic Arts\EA Services\License\16425884_sc.dlf'),
    [ValidateSet('Username', 'Language', 'Token')]
    [string]$Action,
    [string]$Username,
    [string]$Language,
    [switch]$DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----- Steam identifiers for EA SPORTS FC 27 -------------------------------
$script:AppId       = 4407750
$script:StoreUrl    = "steam://store/$($script:AppId)"
$script:StoreWebUrl = "https://store.steampowered.com/app/$($script:AppId)"
$script:InstallUrl  = "steam://install/$($script:AppId)"
$script:RunUrl      = "steam://run/$($script:AppId)"

$script:Languages = [ordered]@{
    ar_SA = 'Arabic'; cs_CZ = 'Czech'; da_DK = 'Danish'; de_DE = 'German'
    en_US = 'English (US)'; es_ES = 'Spanish (Spain)'; es_MX = 'Spanish (Mexico)'
    fr_FR = 'French'; it_IT = 'Italian'; ja_JP = 'Japanese'; ko_KR = 'Korean'
    nl_NL = 'Dutch'; no_NO = 'Norwegian'; pl_PL = 'Polish'; pt_BR = 'Portuguese (Brazil)'
    pt_PT = 'Portuguese (Portugal)'; ru_RU = 'Russian'; sv_SE = 'Swedish'
    tr_TR = 'Turkish'; zh_CN = 'Chinese (Simplified)'; zh_HK = 'Chinese (Hong Kong)'
}

# Folder that contains this script (captured at script scope; $MyInvocation.MyCommand.Path
# is NOT valid inside a function under StrictMode, so use $PSCommandPath / $PSScriptRoot).
$script:SelfDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot }
elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath }
else { (Get-Location).Path }

# Manual game-folder override (set from -GameDir or the Browse button); empty = auto-detect.
$script:ForcedGameDir = $null

# ----- Patch installer (downloads the FC27 crack files, then UnRARs them) --
# Branch zip of https://github.com/barryhamsy/fc26_standalone_installer (FC27_INSTALLER).
$script:PatchZipUrl   = 'https://github.com/barryhamsy/fc26_standalone_installer/archive/refs/heads/FC27_INSTALLER.zip'
$script:AutoTokenDone = $false
$script:WindowShown   = $false
$script:PatchStarted  = $false
$script:PatchState    = $null
$script:PatchPS       = $null
$script:PatchRunspace = $null
$script:PatchAsync    = $null

# Self-contained worker run in a background runspace (no external function deps).
# It downloads the branch zip, unpacks it, finds the first multipart .rar volume
# and UnRAR.exe under the Steam folder, then extracts the crack into the game
# folder. Progress is reported through the synchronized $State hashtable.
$script:PatchWorker = {
    param($State, $GameDir, $SteamPath, $ZipUrl)
    try {
        $ProgressPreference = 'SilentlyContinue'
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

        $work = Join-Path $env:TEMP ('fc27patch_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        $zip = Join-Path $work 'patch.zip'

        $State.Status = 'Downloading patch files...'
        Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing

        $State.Status = 'Unpacking download...'
        $unzip = Join-Path $work 'unzipped'
        Expand-Archive -LiteralPath $zip -DestinationPath $unzip -Force

        $State.Status = 'Locating archive parts...'
        $rars = @(Get-ChildItem -LiteralPath $unzip -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -match '(?i)^\.(rar|r\d\d|001)$' })
        if ($rars.Count -eq 0) { throw 'No .rar parts were found in the downloaded patch.' }
        $first = $rars | Where-Object { $_.Name -match '(?i)\.part0*1\.rar$' } | Select-Object -First 1
        if (-not $first) { $first = $rars | Where-Object { $_.Name -match '(?i)\.rar$' -and $_.Name -notmatch '(?i)\.part\d+\.rar$' } | Select-Object -First 1 }
        if (-not $first) { $first = $rars | Where-Object { $_.Name -match '(?i)\.001$' } | Select-Object -First 1 }
        if (-not $first) { $first = $rars | Sort-Object Name | Select-Object -First 1 }

        $State.Status = 'Locating UnRAR.exe...'
        $unrar = $null
        foreach ($cand in @((Join-Path $SteamPath 'UnRAR.exe'), (Join-Path $GameDir 'UnRAR.exe'))) {
            if ($cand -and (Test-Path -LiteralPath $cand)) { $unrar = $cand; break }
        }
        if (-not $unrar) {
            foreach ($base in @($SteamPath, $GameDir)) {
                if ($base -and (Test-Path -LiteralPath $base)) {
                    $u = Get-ChildItem -LiteralPath $base -Recurse -File -Filter 'UnRAR.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($u) { $unrar = $u.FullName; break }
                }
            }
        }
        if (-not $unrar) { throw 'UnRAR.exe was not found under the Steam folder.' }

        $State.Status = 'Extracting patch into game folder...'
        $dest = $GameDir
        if (-not $dest.EndsWith('\')) { $dest = $dest + '\' }
        $argStr = 'x -o+ -y "' + $first.FullName + '" "' + $dest + '"'
        $proc = Start-Process -FilePath $unrar -ArgumentList $argStr -WindowStyle Hidden -Wait -PassThru
        if ($proc.ExitCode -ne 0) { throw "UnRAR exited with code $($proc.ExitCode)." }

        try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        $State.Status = 'Patch installed.'
        $State.Done = $true
    }
    catch {
        $State.Error = $_.Exception.Message
        $State.Done = $true
    }
}

# ==========================================================================
#  CORE CONFIG / LICENSE LOGIC  (unchanged behaviour from v1.0.0)
# ==========================================================================
function Get-UpdatedSetting {
    param([byte[]]$Data, [string]$Key, [string]$Value)
    # Decode strictly, then retain the same encoding/BOM when changing one value.
    $prefix = [System.BitConverter]::ToString($Data, 0, [Math]::Min(4, $Data.Length))
    $codePage = 65001
    if ($prefix.StartsWith('FF-FE-00-00')) { $codePage = 12000 }
    elseif ($prefix.StartsWith('00-00-FE-FF')) { $codePage = 12001 }
    elseif ($prefix.StartsWith('FF-FE')) { $codePage = 1200 }
    elseif ($prefix.StartsWith('FE-FF')) { $codePage = 1201 }
    $encoderFallback = New-Object System.Text.EncoderExceptionFallback
    $decoderFallback = New-Object System.Text.DecoderExceptionFallback
    $encoding = [System.Text.Encoding]::GetEncoding($codePage, $encoderFallback, $decoderFallback)
    try { $text = $encoding.GetString($Data) }
    catch {
        if ($codePage -ne 65001 -or $prefix.StartsWith('EF-BB-BF')) { throw 'Unsupported config encoding.' }
        $encoding = [System.Text.Encoding]::GetEncoding([System.Text.Encoding]::Default.CodePage, $encoderFallback, $decoderFallback)
        $text = $encoding.GetString($Data)
    }
    $pattern = '(?m)^[\t ﻿]*"' + [regex]::Escape($Key) + '"[\t ]+"(?<value>[^"\r\n]*)"'
    $matchesFound = [regex]::Matches($text, $pattern)
    if ($matchesFound.Count -ne 1) { throw "Expected exactly one quoted $Key setting in anadius.cfg. No files changed." }
    $valueMatch = $matchesFound[0].Groups['value']
    $text = $text.Substring(0, $valueMatch.Index) + $Value + $text.Substring($valueMatch.Index + $valueMatch.Length)
    try { $updated = $encoding.GetBytes($text) }
    catch { throw 'This value cannot be saved in the config file encoding. No files changed.' }
    return [pscustomobject]@{ Data = $updated; Count = 1 }
}

function Get-LicenseToken {
    param([byte[]]$Data)
    # Matches decryptLicense() in origin_helper_tools.html, including header retry.
    $decrypted = $null
    foreach ($offset in @(0, 0x41)) {
        if ($Data.Length -le $offset) { continue }
        $aes = [System.Security.Cryptography.Aes]::Create()
        $decryptor = $null
        try {
            $aes.Key = [byte[]]@(65, 50, 114, 45, 208, 130, 239, 176, 220, 100, 87, 197, 118, 104, 202, 9)
            $aes.IV = New-Object byte[] 16
            $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
            $decryptor = $aes.CreateDecryptor()
            $decrypted = $decryptor.TransformFinalBlock($Data, $offset, $Data.Length - $offset)
            break
        }
        catch [System.Security.Cryptography.CryptographicException] { continue }
        finally {
            if ($null -ne $decryptor) { $decryptor.Dispose() }
            $aes.Dispose()
        }
    }
    if ($null -eq $decrypted) { throw 'Could not decrypt the license using the HTML helper format.' }
    $xmlText = [System.Text.Encoding]::UTF8.GetString($decrypted).TrimStart([char]0xFEFF)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $stringReader = New-Object System.IO.StringReader($xmlText)
    $reader = $null
    try {
        $reader = [System.Xml.XmlReader]::Create($stringReader, $settings)
        $document = New-Object System.Xml.XmlDocument
        $document.XmlResolver = $null
        $document.Load($reader)
    }
    catch { throw 'The decrypted license does not contain supported XML.' }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $stringReader.Dispose()
    }
    $element = $document.SelectSingleNode('//*[local-name()="GameToken"]')
    if ($null -eq $element -or [string]::IsNullOrWhiteSpace($element.InnerText)) {
        throw 'No GameToken was found in this license.'
    }
    $token = $element.InnerText.Trim()
    if ($null -ne $element.SelectSingleNode('*')) { throw 'Unexpected nested elements in GameToken.' }
    foreach ($character in $token.ToCharArray()) {
        $code = [int]$character
        if ($code -lt 33 -or $code -gt 126 -or $code -in @(34, 39, 92)) {
            throw 'The GameToken contains unexpected characters; configs were not changed.'
        }
    }
    return $token
}

# token.ini stores the token as a bare INI line: token=<value> (under [token]).
# We target that line directly so an existing token is overwritten, not just the
# one-time PASTE_... placeholder.
function Get-UpdatedIniToken {
    param([byte[]]$Data, [string]$Token, [string]$Key = 'token')
    # Latin-1 maps bytes one-to-one, preserving every byte outside the replacement.
    $byteMapping = [System.Text.Encoding]::GetEncoding(28591)
    $text = $byteMapping.GetString($Data)
    $pattern = '(?m)^(?<pre>[\t ﻿]*' + [regex]::Escape($Key) + '[\t ]*=[\t ]*)(?<value>[^\r\n]*)$'
    $found = [regex]::Matches($text, $pattern)
    if ($found.Count -lt 1) { throw "No '$Key=' line found in token.ini. No files changed." }
    $valueMatch = $found[0].Groups['value']
    $replacement = $byteMapping.GetString([System.Text.Encoding]::ASCII.GetBytes($Token))
    $text = $text.Substring(0, $valueMatch.Index) + $replacement + $text.Substring($valueMatch.Index + $valueMatch.Length)
    return [pscustomobject]@{ Data = $byteMapping.GetBytes($text); Count = 1 }
}

# Read the token currently stored in each config, so we can tell whether the
# license token is already applied (byte-preserving Latin-1 decode).
function Get-CfgTokenValue {
    param([string]$GameDir, [string]$Key = 'DenuvoToken')
    $path = Join-Path $GameDir 'anadius.cfg'
    if (-not [System.IO.File]::Exists($path)) { return $null }
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($path))
    $m = [regex]::Match($text, '(?m)^[\t ﻿]*"' + [regex]::Escape($Key) + '"[\t ]+"(?<v>[^"\r\n]*)"')
    if ($m.Success) { return $m.Groups['v'].Value } else { return $null }
}

function Get-IniTokenValue {
    param([string]$GameDir, [string]$Key = 'token')
    $path = Join-Path $GameDir 'token.ini'
    if (-not [System.IO.File]::Exists($path)) { return $null }
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($path))
    $m = [regex]::Match($text, '(?m)^[\t ﻿]*' + [regex]::Escape($Key) + '[\t ]*=[\t ]*(?<v>[^\r\n]*)$')
    if ($m.Success) { return $m.Groups['v'].Value.TrimEnd() } else { return $null }
}

function Write-AtomicFile {
    param([string]$Path, [byte[]]$Data)
    $temporary = Join-Path ([System.IO.Path]::GetDirectoryName($Path)) ('.token-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllBytes($temporary, $Data)
        [System.IO.File]::Replace($temporary, $Path, [NullString]::Value)
    }
    finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
}

function Get-Planned {
    param([string]$GameDir, [string]$Action, [string]$SettingValue, [string]$Token)
    if ($Action -eq 'Token') { $names = @('anadius.cfg', 'token.ini') } else { $names = @('anadius.cfg') }
    $missing = @($names | Where-Object { -not [System.IO.File]::Exists((Join-Path $GameDir $_)) })
    if ($missing.Count -gt 0) {
        throw "Missing config file(s): $($missing -join ', ').`r`nCopy the missing file(s) into the game folder, then try again."
    }
    $planned = foreach ($name in $names) {
        $path = Join-Path $GameDir $name
        $file = Get-Item -LiteralPath $path
        if (($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Config must be a regular file, not a symbolic link: $path"
        }
        $original = [System.IO.File]::ReadAllBytes($path)
        if ($Action -eq 'Token') {
            # Overwrite the token in place, whether it is a placeholder or a real token.
            if ($name -eq 'token.ini') { $updated = Get-UpdatedIniToken -Data $original -Token $Token }
            else { $updated = Get-UpdatedSetting -Data $original -Key 'DenuvoToken' -Value $Token }
        }
        else { $updated = Get-UpdatedSetting -Data $original -Key $Action -Value $SettingValue }
        [pscustomobject]@{ Path = $path; Original = $original; Updated = $updated.Data; Count = $updated.Count }
    }
    return @($planned)
}

function Invoke-Planned {
    param([object[]]$Planned)
    $log = New-Object System.Collections.Generic.List[string]
    $suffix = '.' + [guid]::NewGuid().ToString('N') + '.bak'
    $backups = @()
    foreach ($item in $Planned) {
        $backup = $item.Path + $suffix
        $stream = [System.IO.File]::Open($backup, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
        try { $stream.Write($item.Original, 0, $item.Original.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        $backups += $backup
        $log.Add("Backup: $([System.IO.Path]::GetFileName($backup))")
    }
    $changed = @()
    try {
        foreach ($item in $Planned) {
            $current = [System.IO.File]::ReadAllBytes($item.Path)
            if ([Convert]::ToBase64String($current) -cne [Convert]::ToBase64String($item.Original)) {
                throw "Config changed while processing: $($item.Path)"
            }
            Write-AtomicFile -Path $item.Path -Data $item.Updated
            $changed += $item
        }
    }
    catch {
        $failure = $_.Exception.Message
        $rollbackErrors = @()
        for ($index = $changed.Count - 1; $index -ge 0; $index--) {
            try { Write-AtomicFile -Path $changed[$index].Path -Data $changed[$index].Original }
            catch { $rollbackErrors += $changed[$index].Path }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw "Update failed: $failure`r`nRestore these files from the backups listed above: $($rollbackErrors -join ', ')"
        }
        throw "Update failed: $failure`r`nAny completed changes were rolled back."
    }
    return [pscustomobject]@{ Backups = $backups; Log = $log }
}

function Invoke-TokenAction {
    param([string]$GameDir, [string]$Action, [string]$SettingValue, [string]$LicensePath)
    $token = $null
    if ($Action -eq 'Token') {
        if (-not [System.IO.File]::Exists($LicensePath)) { throw "License file not found: $LicensePath" }
        $token = Get-LicenseToken -Data ([System.IO.File]::ReadAllBytes($LicensePath))
        # If both configs already hold this exact token, there is nothing to do.
        $curCfg = Get-CfgTokenValue -GameDir $GameDir
        $curIni = Get-IniTokenValue -GameDir $GameDir
        if (($null -ne $curCfg) -and ($null -ne $curIni) -and ($curCfg -ceq $token) -and ($curIni -ceq $token)) {
            return [pscustomobject]@{
                Token          = $token
                AlreadyApplied = $true
                Backups        = @()
                Log            = @('Token already applied; no changes needed.')
                Files          = @('anadius.cfg', 'token.ini')
            }
        }
    }
    $planned = Get-Planned -GameDir $GameDir -Action $Action -SettingValue $SettingValue -Token $token
    $result = Invoke-Planned -Planned $planned
    return [pscustomobject]@{
        Token          = $token
        AlreadyApplied = $false
        Backups        = $result.Backups
        Log            = $result.Log
        Files          = @($planned | ForEach-Object { [System.IO.Path]::GetFileName($_.Path) })
    }
}

# ==========================================================================
#  STEAM DETECTION
# ==========================================================================
function Get-SteamPath {
    foreach ($item in @(
            @{ Path = 'HKCU:\Software\Valve\Steam'; Name = 'SteamPath' },
            @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam'; Name = 'InstallPath' },
            @{ Path = 'HKLM:\SOFTWARE\Valve\Steam'; Name = 'InstallPath' })) {
        $prop = Get-ItemProperty -Path $item.Path -Name $item.Name -ErrorAction SilentlyContinue
        if ($prop -and $prop.PSObject.Properties[$item.Name]) {
            $value = $prop.($item.Name)
            if (-not [string]::IsNullOrWhiteSpace($value) -and (Test-Path -LiteralPath $value)) { return $value }
        }
    }
    return $null
}

function Get-SteamLibraryFolders {
    param([string]$SteamPath)
    $folders = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($SteamPath)) { return @() }
    $primary = Join-Path $SteamPath 'steamapps'
    if (Test-Path -LiteralPath $primary) { $folders.Add($primary) }
    $vdf = Join-Path $SteamPath 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $content = Get-Content -LiteralPath $vdf -Raw -ErrorAction SilentlyContinue
        if ($content) {
            foreach ($m in [regex]::Matches($content, '"path"\s+"([^"]+)"')) {
                $p = $m.Groups[1].Value -replace '\\\\', '\'
                $sa = Join-Path $p 'steamapps'
                if (Test-Path -LiteralPath $sa) { $folders.Add($sa) }
            }
        }
    }
    return @($folders | Select-Object -Unique)
}

function Get-SteamAppState {
    param([int]$AppId)
    $state = [pscustomobject]@{
        SteamInstalled = $false
        InLibrary      = $false
        GameInstalled  = $false
        InstallDir     = $null
        SteamPath      = $null
    }
    $steam = Get-SteamPath
    $state.SteamPath = $steam
    $state.SteamInstalled = [bool]$steam

    # Registry: presence means the client knows the app (owned / in library).
    $reg = "HKCU:\Software\Valve\Steam\Apps\$AppId"
    if (Test-Path -LiteralPath $reg) {
        $state.InLibrary = $true
        $inst = Get-ItemProperty -Path $reg -Name 'Installed' -ErrorAction SilentlyContinue
        if ($inst -and $inst.PSObject.Properties['Installed'] -and [int]$inst.Installed -eq 1) {
            $state.GameInstalled = $true
        }
    }

    # appmanifest confirms an installed copy and gives us the folder.
    foreach ($sa in (Get-SteamLibraryFolders -SteamPath $steam)) {
        $manifest = Join-Path $sa "appmanifest_$AppId.acf"
        if (Test-Path -LiteralPath $manifest) {
            $state.InLibrary = $true
            $state.GameInstalled = $true
            $c = Get-Content -LiteralPath $manifest -Raw -ErrorAction SilentlyContinue
            if ($c) {
                $mm = [regex]::Match($c, '"installdir"\s+"([^"]+)"')
                if ($mm.Success) {
                    # e.g.  <library>\steamapps\common\EA SPORTS FC 27 Demo
                    $state.InstallDir = Join-Path $sa (Join-Path 'common' $mm.Groups[1].Value)
                }
            }
            break
        }
    }
    return $state
}

# ==========================================================================
#  COMMAND-LINE MODE  (kept for automation / backward compatibility)
# ==========================================================================
function Invoke-CliMode {
    $script:ForcedGameDir = $GameDir
    if ([string]::IsNullOrWhiteSpace($GameDir)) {
        $GameDir = Get-Fc27GameDir -State (Get-SteamAppState -AppId $script:AppId)
    }
    $directory = Get-Item -LiteralPath $GameDir
    if (-not $directory.PSIsContainer) { throw "Not a folder: $GameDir" }
    $GameDir = $directory.FullName

    $settingValue = $null
    if ($Action -eq 'Username') {
        $Username = "$Username".Trim()
        if ([string]::IsNullOrWhiteSpace($Username) -or $Username -match '["\\\p{Cc}]') {
            throw 'Enter a non-empty username without quotes, backslashes, or control characters.'
        }
        $settingValue = $Username
    }
    elseif ($Action -eq 'Language') {
        $codes = @($script:Languages.Keys)
        if ($codes -notcontains $Language) { throw 'Unsupported language. Choose a valid code (e.g. en_US).' }
        $Language = $codes | Where-Object { $_ -ieq $Language } | Select-Object -First 1
        $settingValue = $Language + ',all'
    }

    if ($DryRun) {
        $token = $null
        if ($Action -eq 'Token') {
            if (-not [System.IO.File]::Exists($LicensePath)) { throw "License file not found: $LicensePath" }
            $token = Get-LicenseToken -Data ([System.IO.File]::ReadAllBytes($LicensePath))
        }
        $planned = Get-Planned -GameDir $GameDir -Action $Action -SettingValue $settingValue -Token $token
        foreach ($item in $planned) { Write-Host "Would apply $Action change to $($item.Path)" }
        Write-Host 'Preview complete. No files changed; token not displayed.'
        return
    }

    $result = Invoke-TokenAction -GameDir $GameDir -Action $Action -SettingValue $settingValue -LicensePath $LicensePath
    foreach ($line in $result.Log) { Write-Host $line }
    foreach ($f in $result.Files) { Write-Host "Updated $($f): $Action." }
    Write-Host 'Done.'
}

# ==========================================================================
#  GUI HELPERS  (script-scoped; act on $script:UI once the window is built)
# ==========================================================================
function New-Fc27Brush {
    param([string]$Hex)
    return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex)
}

function Set-Fc27Banner {
    param([string]$Kind, [string]$Title, [string]$Detail)
    $glyphs = @{
        ok    = [char]0xE930; warn = [char]0xE7BA; info = [char]0xE946; error = [char]0xEA39
    }
    $palette = @{
        ok    = @{ col = '#8ED629'; bg = '#12241A'; bd = '#2E5A2A' }
        warn  = @{ col = '#E8A33D'; bg = '#2A2113'; bd = '#5A4A2A' }
        info  = @{ col = '#66C0F4'; bg = '#132132'; bd = '#2A3F5A' }
        error = @{ col = '#F26D6D'; bg = '#2A1515'; bd = '#5A2A2A' }
    }
    $p = $palette[$Kind]
    $script:UI.BannerIcon.Text = [string]$glyphs[$Kind]
    $script:UI.BannerIcon.Foreground = New-Fc27Brush $p.col
    $script:UI.BannerBorder.Background = New-Fc27Brush $p.bg
    $script:UI.BannerBorder.BorderBrush = New-Fc27Brush $p.bd
    $script:UI.BannerTitle.Text = $Title
    $script:UI.BannerDetail.Text = $Detail
}

function Set-Fc27Log {
    param([string]$Text, [string]$Kind = 'muted')
    $col = @{ muted = '#7E93A6'; ok = '#8ED629'; error = '#F26D6D' }[$Kind]
    $script:UI.LogText.Foreground = New-Fc27Brush $col
    $script:UI.LogText.Text = $Text
}

function Set-Fc27Step {
    param([int]$Index, [string]$State)  # done | active | pending
    $circle = $script:UI["S$($Index)Circle"]
    $num = $script:UI["S$($Index)Num"]
    switch ($State) {
        'done' {
            $circle.Background = New-Fc27Brush '#5C9412'
            $num.Text = [string][char]0xE73E
            $num.FontFamily = 'Segoe MDL2 Assets'
            $num.FontSize = 14
            $num.Foreground = New-Fc27Brush '#FFFFFF'
        }
        'active' {
            $circle.Background = New-Fc27Brush '#1A72C4'
            $num.Text = "$Index"
            $num.FontFamily = 'Segoe UI'
            $num.FontSize = 15
            $num.Foreground = New-Fc27Brush '#FFFFFF'
        }
        default {
            $circle.Background = New-Fc27Brush '#22344A'
            $num.Text = "$Index"
            $num.FontFamily = 'Segoe UI'
            $num.FontSize = 15
            $num.Foreground = New-Fc27Brush '#8CA0B3'
        }
    }
}

function Test-Fc27HasConfigs {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
    return ([System.IO.File]::Exists((Join-Path $Dir 'anadius.cfg')) -and
        [System.IO.File]::Exists((Join-Path $Dir 'token.ini')))
}

function Get-Fc27GameDir {
    # Auto-detect the FC27 game folder (where anadius.cfg + token.ini live):
    #   Steam path -> libraryfolders.vdf "path" -> steamapps\appmanifest_4407750.acf
    #   -> "installdir" -> steamapps\common\<installdir>
    # Priority: manual override > detected install (with configs) > script folder
    # (with configs) > detected install > script folder.
    param($State)
    if (-not [string]::IsNullOrWhiteSpace($script:ForcedGameDir)) { return $script:ForcedGameDir }
    $install = $null
    if ($State -and $State.InstallDir) { $install = $State.InstallDir }
    if ($install -and (Test-Fc27HasConfigs $install)) { return $install }
    if (Test-Fc27HasConfigs $script:SelfDir) { return $script:SelfDir }
    if ($install) { return $install }
    return $script:SelfDir
}

function Test-Fc27Configs {
    $need = @('anadius.cfg', 'token.ini')
    $missing = @($need | Where-Object { -not [System.IO.File]::Exists((Join-Path $script:GameDir $_)) })
    if ($missing.Count -gt 0) {
        $script:UI.ConfigWarn.Text = "Not found in this folder: $($missing -join ', '). Use Browse to pick the folder that contains them."
        $script:UI.ConfigWarn.Visibility = 'Visible'
    }
    else {
        $script:UI.ConfigWarn.Visibility = 'Collapsed'
    }
}

function Open-Fc27Url {
    param([string]$Url)
    try { Start-Process $Url | Out-Null }
    catch {
        [System.Windows.MessageBox]::Show("Could not open:`r`n$Url`r`n`r`n$($_.Exception.Message)", 'FC27 Token Updater', 'OK', 'Warning') | Out-Null
    }
}

# Themed "ready to play" dialog shown after a token is applied or found already applied.
function Show-Fc27PlayDialog {
    param([string]$Title, [string]$Message)
    $dx = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" Background="Transparent"
        SizeToContent="Height" Width="440" WindowStartupLocation="CenterOwner" ShowInTaskbar="False">
  <Border Background="#111C27" BorderBrush="#2A3F5A" BorderThickness="1" CornerRadius="10">
    <StackPanel Margin="24,22,24,20">
      <StackPanel Orientation="Horizontal">
        <TextBlock x:Name="Glyph" FontFamily="Segoe MDL2 Assets" Text="&#xE930;" FontSize="26" Foreground="#8ED629" VerticalAlignment="Center" Margin="0,0,12,0"/>
        <TextBlock x:Name="Head" Text="Token applied" FontSize="18" FontWeight="Bold" Foreground="#EAF2F8" VerticalAlignment="Center"/>
      </StackPanel>
      <TextBlock x:Name="Body" Text="" FontSize="13" Foreground="#9FB2C4" TextWrapping="Wrap" Margin="0,14,0,20"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
        <Button x:Name="BtnClose" Content="Close" Cursor="Hand" Foreground="#C7D5E0" FontSize="14" Background="#22344A" BorderThickness="0" Padding="16,9" Margin="0,0,10,0"/>
        <Button x:Name="BtnPlay" Content="Launch game" Cursor="Hand" Foreground="#FFFFFF" FontWeight="SemiBold" FontSize="14" BorderThickness="0" Padding="18,9">
          <Button.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
              <GradientStop Color="#8ED629" Offset="0"/><GradientStop Color="#5C9412" Offset="1"/>
            </LinearGradientBrush>
          </Button.Background>
        </Button>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
    [xml]$dxml = $dx
    $dlgReader = New-Object System.Xml.XmlNodeReader $dxml
    $dlg = [Windows.Markup.XamlReader]::Load($dlgReader)
    $dlg.FindName('Head').Text = $Title
    $dlg.FindName('Body').Text = $Message
    if ($script:Window) { $dlg.Owner = $script:Window }
    $script:PlayDialog = $dlg
    $dlg.FindName('BtnPlay').Add_Click({ Open-Fc27Url $script:RunUrl; $script:PlayDialog.Close() })
    $dlg.FindName('BtnClose').Add_Click({ $script:PlayDialog.Close() })
    [void]$dlg.ShowDialog()
}

function Update-Fc27Gate {
    $licenseExists = [System.IO.File]::Exists($script:LicensePath)
    $state = Get-SteamAppState -AppId $script:AppId

    # Keep the game folder pointed at the detected Steam install (unless the user
    # picked one manually via Browse / -GameDir).
    if ([string]::IsNullOrWhiteSpace($script:ForcedGameDir)) {
        $auto = Get-Fc27GameDir -State $state
        if ($auto -and $auto -ne $script:GameDir) {
            $script:GameDir = $auto
            if ($script:UI) { $script:UI.TxtGameDir.Text = $auto }
        }
    }

    # Once the game is installed but not yet patched, fetch + extract the crack.
    Start-Fc27Patch

    if ($licenseExists) {
        $script:UI.PanelOnboard.Visibility = 'Collapsed'
        $script:UI.PanelTools.Visibility = 'Visible'
        Set-Fc27Banner 'ok' 'License detected' 'The license file 16425884_sc.dlf was found; the token is applied automatically.'
        Test-Fc27Configs
        # Auto-apply the token the moment the license and configs are both present
        # (no button click needed), exactly once.
        if ((-not $script:AutoTokenDone) -and $script:WindowShown -and (Test-Fc27HasConfigs $script:GameDir)) {
            $script:AutoTokenDone = $true
            [void](Invoke-Fc27TokenApply -Manual $false)
        }
        return
    }

    $script:UI.PanelTools.Visibility = 'Collapsed'
    $script:UI.PanelOnboard.Visibility = 'Visible'

    if (-not $state.SteamInstalled) {
        Set-Fc27Step 1 'active'; Set-Fc27Step 2 'pending'; Set-Fc27Step 3 'pending'
        Set-Fc27Banner 'warn' 'Steam not detected' 'Steam does not appear to be installed. Opening the store in your browser instead.'
        $script:UI.BtnPrimary.Content = 'Open store in browser'
        $script:PrimaryUrl = $script:StoreWebUrl
        $script:UI.PrimaryHint.Text = 'Install Steam and add FC27, then click Re-check.'
    }
    elseif (-not $state.InLibrary) {
        Set-Fc27Step 1 'active'; Set-Fc27Step 2 'pending'; Set-Fc27Step 3 'pending'
        Set-Fc27Banner 'info' 'FC27 is not in your library' 'Add EA SPORTS FC 27 (appid 4407750) to your Steam library first.'
        $script:UI.BtnPrimary.Content = 'Open FC27 store page'
        $script:PrimaryUrl = $script:StoreUrl
        $script:UI.PrimaryHint.Text = 'Add the game to your library in Steam, then click Re-check.'
    }
    elseif (-not $state.GameInstalled) {
        Set-Fc27Step 1 'done'; Set-Fc27Step 2 'active'; Set-Fc27Step 3 'pending'
        Set-Fc27Banner 'info' 'FC27 is not installed' 'The game is in your library but not installed yet.'
        $script:UI.BtnPrimary.Content = 'Install FC27'
        $script:PrimaryUrl = $script:InstallUrl
        $script:UI.PrimaryHint.Text = 'Finish the Steam download/install, then click Re-check.'
    }
    else {
        Set-Fc27Step 1 'done'; Set-Fc27Step 2 'done'; Set-Fc27Step 3 'active'
        Set-Fc27Banner 'warn' 'Launch the game once' 'FC27 is installed but has not created the license file yet. Play it once so 16425884_sc.dlf is generated.'
        $script:UI.BtnPrimary.Content = 'Launch FC27'
        $script:PrimaryUrl = $script:RunUrl
        $script:UI.PrimaryHint.Text = 'Start the game and reach the main menu, then click Re-check (this window also refreshes automatically).'
    }
}

# Apply the token (auto on license detection, or manually via the button) and
# show the "ready to play" dialog. Returns $true on success.
function Invoke-Fc27TokenApply {
    param([bool]$Manual)
    try {
        $r = Invoke-TokenAction -GameDir $script:GameDir -Action 'Token' -LicensePath $script:LicensePath
        if ($script:UI.ChkCopyToken.IsChecked -and $r.Token) {
            try { [System.Windows.Clipboard]::SetText($r.Token) } catch { }
        }
        if ($r.AlreadyApplied) {
            Set-Fc27Log 'Token already applied - you are ready to play.' 'ok'
            Show-Fc27PlayDialog 'Already activated' 'The token is already applied to anadius.cfg and token.ini. You can launch EA SPORTS FC 27 now.'
        }
        else {
            $how = if ($Manual) { 'Token re-applied to' } else { 'Token applied automatically to' }
            Set-Fc27Log ("$how $($r.Files -join ', '). " + ($r.Log -join '  ')) 'ok'
            Show-Fc27PlayDialog 'Token applied' 'The Denuvo token has been written to your configs (a backup of each was saved). You can launch EA SPORTS FC 27 now.'
        }
        return $true
    }
    catch {
        Set-Fc27Log "Token error: $($_.Exception.Message)" 'error'
        return $false
    }
}

# Start the background patch download/extract if the game is installed but not
# yet patched. Idempotent - runs at most once per session.
function Start-Fc27Patch {
    if ($script:PatchStarted) { return }
    if (Test-Fc27HasConfigs $script:GameDir) { return }   # already patched
    if ([string]::IsNullOrWhiteSpace($script:GameDir) -or -not (Test-Path -LiteralPath $script:GameDir)) { return }  # game not installed yet

    $script:PatchStarted = $true
    $steam = Get-SteamPath
    $script:PatchState = [hashtable]::Synchronized(@{ Status = 'Starting...'; Done = $false; Error = $null })

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:PatchWorker.ToString()).AddArgument($script:PatchState).AddArgument($script:GameDir).AddArgument($steam).AddArgument($script:PatchZipUrl)

    $script:PatchRunspace = $rs
    $script:PatchPS = $ps
    $script:PatchAsync = $ps.BeginInvoke()

    # Make the download unmistakable: full-window overlay with a live status.
    if ($script:UI.PatchStatus) { $script:UI.PatchStatus.Text = 'Downloading patch files from GitHub...' }
    if ($script:UI.PatchOverlay) { $script:UI.PatchOverlay.Visibility = 'Visible' }
    Set-Fc27Banner 'info' 'Installing patch' 'Downloading the FC27 patch from GitHub...'
    Set-Fc27Log 'Preparing patch files...' 'muted'
    if ($script:PatchTimer) { $script:PatchTimer.Start() }
}

# Poll the background patch worker and reflect its progress in the overlay + footer.
function Update-Fc27PatchProgress {
    if (-not $script:PatchState) { if ($script:PatchTimer) { $script:PatchTimer.Stop() }; return }
    $status = [string]$script:PatchState.Status
    if ($script:UI.PatchStatus) { $script:UI.PatchStatus.Text = $status }
    Set-Fc27Log ("Patch: " + $status) 'muted'
    if ($script:PatchState.Done) {
        if ($script:PatchTimer) { $script:PatchTimer.Stop() }
        $err = $script:PatchState.Error
        try { if ($script:PatchPS) { $script:PatchPS.EndInvoke($script:PatchAsync); $script:PatchPS.Dispose() } } catch { }
        try { if ($script:PatchRunspace) { $script:PatchRunspace.Dispose() } } catch { }
        $script:PatchPS = $null; $script:PatchRunspace = $null; $script:PatchState = $null
        if ($script:UI.PatchOverlay) { $script:UI.PatchOverlay.Visibility = 'Collapsed' }
        if ($err) {
            Set-Fc27Log "Patch step failed: $err" 'error'
            Set-Fc27Banner 'error' 'Patch step failed' $err
        }
        else {
            Set-Fc27Log 'Patch files installed.' 'ok'
        }
        Update-Fc27Gate
    }
}

# ==========================================================================
#  WPF GUI
# ==========================================================================
function Hide-ConsoleWindow {
    try {
        Add-Type -Name Win -Namespace Fc27Native -ErrorAction SilentlyContinue -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
        $h = [Fc27Native.Win]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero) { [void][Fc27Native.Win]::ShowWindow($h, 0) }
    }
    catch { }
}

function Show-Gui {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms | Out-Null

    $xamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="FC27 Token Updater" Height="708" Width="660"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        FontFamily="Segoe UI" Foreground="#C7D5E0" Background="#0E141B">
  <Window.Resources>
    <SolidColorBrush x:Key="Panel"  Color="#16212E"/>
    <SolidColorBrush x:Key="Panel2" Color="#1E2C3C"/>
    <SolidColorBrush x:Key="CardBorder" Color="#2A3F5A"/>

    <Style x:Key="BaseButton" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="18,10"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="6" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.88"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.72"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.38"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource BaseButton}">
      <Setter Property="Background">
        <Setter.Value>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#3BA5E0" Offset="0"/>
            <GradientStop Color="#1A72C4" Offset="1"/>
          </LinearGradientBrush>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GreenButton" TargetType="Button" BasedOn="{StaticResource BaseButton}">
      <Setter Property="Background">
        <Setter.Value>
          <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
            <GradientStop Color="#8ED629" Offset="0"/>
            <GradientStop Color="#5C9412" Offset="1"/>
          </LinearGradientBrush>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="GhostButton" TargetType="Button" BasedOn="{StaticResource BaseButton}">
      <Setter Property="Background" Value="#22344A"/>
      <Setter Property="Foreground" Value="#C7D5E0"/>
      <Setter Property="FontWeight" Value="Normal"/>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#0E1620"/>
      <Setter Property="Foreground" Value="#EAF2F8"/>
      <Setter Property="CaretBrush" Value="#66C0F4"/>
      <Setter Property="BorderBrush" Value="#33496A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="9,7"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border CornerRadius="6" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#EAF2F8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="ib" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="ib" Property="Background" Value="#1A72C4"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="ib" Property="Background" Value="#243448"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBox">
      <Setter Property="Foreground" Value="#EAF2F8"/>
      <Setter Property="Background" Value="#0E1620"/>
      <Setter Property="BorderBrush" Value="#33496A"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="ToggleButton" Focusable="False" ClickMode="Press"
                            Background="{TemplateBinding Background}"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border CornerRadius="6" Background="{TemplateBinding Background}" BorderBrush="#33496A" BorderThickness="1"/>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter x:Name="ContentSite" IsHitTestVisible="False"
                                Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                TextElement.Foreground="#EAF2F8"
                                Margin="12,0,32,0" VerticalAlignment="Center" HorizontalAlignment="Left"/>
              <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0"
                    Fill="#9FB2C4" Data="M0,0 L8,0 L4,4 Z"/>
              <Popup x:Name="Popup" Placement="Bottom" AllowsTransparency="True" Focusable="False"
                     IsOpen="{TemplateBinding IsDropDownOpen}" PopupAnimation="Slide">
                <Border x:Name="DropDownBorder" Background="#16212E" BorderBrush="#33496A" BorderThickness="1"
                        CornerRadius="6" Margin="0,4,0,0"
                        MinWidth="{Binding ActualWidth, ElementName=ToggleButton}"
                        MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer SnapsToDevicePixels="True">
                    <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ToggleButton" Property="Background" Value="#132132"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- Header -->
    <Border Grid.Row="0" Padding="22,18">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
          <GradientStop Color="#16212E" Offset="0"/>
          <GradientStop Color="#0E141B" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
      <StackPanel Orientation="Horizontal">
        <Border Width="4" Background="#66C0F4" CornerRadius="2" Margin="0,2,14,2"/>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="FC27 Token Updater" FontSize="22" FontWeight="Bold" Foreground="#EAF2F8"/>
          <TextBlock Text="EA SPORTS FC 27  -  Denuvo token &amp; config helper" FontSize="12" Foreground="#7E93A6" Margin="0,2,0,0"/>
        </StackPanel>
      </StackPanel>
    </Border>

    <!-- Status banner -->
    <Border x:Name="BannerBorder" Grid.Row="1" Margin="22,6,22,4" CornerRadius="8" Padding="16,12"
            Background="#132132" BorderBrush="#2A3F5A" BorderThickness="1">
      <StackPanel Orientation="Horizontal">
        <TextBlock x:Name="BannerIcon" FontFamily="Segoe MDL2 Assets" FontSize="22" VerticalAlignment="Center"
                   Foreground="#66C0F4" Margin="0,0,14,0" Text="&#xE946;"/>
        <StackPanel VerticalAlignment="Center">
          <TextBlock x:Name="BannerTitle" Text="Checking license..." FontSize="15" FontWeight="SemiBold" Foreground="#EAF2F8"/>
          <TextBlock x:Name="BannerDetail" Text="" FontSize="12" Foreground="#9FB2C4" Margin="0,2,0,0" TextWrapping="Wrap"/>
        </StackPanel>
      </StackPanel>
    </Border>

    <!-- Body -->
    <ScrollViewer Grid.Row="2" VerticalScrollBarVisibility="Auto" Padding="22,10,22,10">
      <Grid>

        <!-- ===== ONBOARDING ===== -->
        <StackPanel x:Name="PanelOnboard" Visibility="Collapsed">
          <TextBlock TextWrapping="Wrap" FontSize="13" Foreground="#9FB2C4" Margin="0,0,0,16"
                     Text="The license file 16425884_sc.dlf is missing. It is created by EA / Windows only after FC27 is owned, installed, and launched at least once. Follow the steps below, then use Re-check."/>

          <!-- Step 1 -->
          <Grid Margin="0,0,0,14">
            <Grid.ColumnDefinitions><ColumnDefinition Width="46"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border x:Name="S1Circle" Grid.Column="0" Width="34" Height="34" CornerRadius="17" Background="#22344A" VerticalAlignment="Top">
              <TextBlock x:Name="S1Num" Text="1" FontWeight="Bold" FontSize="15" Foreground="#C7D5E0" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Grid.Column="1" VerticalAlignment="Center">
              <TextBlock x:Name="S1Title" Text="Add FC27 to your Steam library" FontSize="14" FontWeight="SemiBold" Foreground="#EAF2F8"/>
              <TextBlock x:Name="S1Desc" Text="Own the game on Steam (appid 4407750)." FontSize="12" Foreground="#7E93A6" TextWrapping="Wrap" Margin="0,2,0,0"/>
            </StackPanel>
          </Grid>

          <!-- Step 2 -->
          <Grid Margin="0,0,0,14">
            <Grid.ColumnDefinitions><ColumnDefinition Width="46"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border x:Name="S2Circle" Grid.Column="0" Width="34" Height="34" CornerRadius="17" Background="#22344A" VerticalAlignment="Top">
              <TextBlock x:Name="S2Num" Text="2" FontWeight="Bold" FontSize="15" Foreground="#C7D5E0" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Grid.Column="1" VerticalAlignment="Center">
              <TextBlock x:Name="S2Title" Text="Install the game" FontSize="14" FontWeight="SemiBold" Foreground="#EAF2F8"/>
              <TextBlock x:Name="S2Desc" Text="Download and install FC27 through Steam." FontSize="12" Foreground="#7E93A6" TextWrapping="Wrap" Margin="0,2,0,0"/>
            </StackPanel>
          </Grid>

          <!-- Step 3 -->
          <Grid Margin="0,0,0,10">
            <Grid.ColumnDefinitions><ColumnDefinition Width="46"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
            <Border x:Name="S3Circle" Grid.Column="0" Width="34" Height="34" CornerRadius="17" Background="#22344A" VerticalAlignment="Top">
              <TextBlock x:Name="S3Num" Text="3" FontWeight="Bold" FontSize="15" Foreground="#C7D5E0" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Grid.Column="1" VerticalAlignment="Center">
              <TextBlock x:Name="S3Title" Text="Launch the game once" FontSize="14" FontWeight="SemiBold" Foreground="#EAF2F8"/>
              <TextBlock x:Name="S3Desc" Text="Play to the main menu so the license file is written, then come back." FontSize="12" Foreground="#7E93A6" TextWrapping="Wrap" Margin="0,2,0,0"/>
            </StackPanel>
          </Grid>

          <Button x:Name="BtnPrimary" Style="{StaticResource PrimaryButton}" HorizontalAlignment="Left" Margin="46,10,0,4" Content="Open Steam Store"/>
          <TextBlock x:Name="PrimaryHint" Margin="46,4,0,0" FontSize="12" Foreground="#7E93A6" TextWrapping="Wrap"
                     Text="After completing the step, click Re-check below."/>
        </StackPanel>

        <!-- ===== TOOLS ===== -->
        <StackPanel x:Name="PanelTools" Visibility="Collapsed">

          <!-- Game folder is auto-detected, so this block stays hidden. -->
          <StackPanel x:Name="GameFolderSection" Visibility="Collapsed">
            <TextBlock Text="GAME FOLDER" FontSize="11" FontWeight="Bold" Foreground="#66C0F4" Margin="0,0,0,6"/>
            <Grid Margin="0,0,0,4">
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <TextBox x:Name="TxtGameDir" Grid.Column="0" IsReadOnly="True" VerticalContentAlignment="Center"/>
              <Button x:Name="BtnBrowse" Grid.Column="1" Style="{StaticResource GhostButton}" Content="Browse" Margin="8,0,0,0"/>
            </Grid>
            <TextBlock x:Name="ConfigWarn" FontSize="12" Foreground="#E8A33D" TextWrapping="Wrap" Margin="0,4,0,0" Visibility="Collapsed"/>
            <Border Height="1" Background="#22344A" Margin="0,16,0,16"/>
          </StackPanel>

          <!-- Token card -->
          <Border Background="{StaticResource Panel}" BorderBrush="{StaticResource CardBorder}" BorderThickness="1" CornerRadius="8" Padding="16" Margin="0,0,0,4">
            <StackPanel>
              <TextBlock Text="Denuvo token" FontSize="14" FontWeight="SemiBold" Foreground="#EAF2F8"/>
              <TextBlock Text="The token is read from 16425884_sc.dlf and written into anadius.cfg and token.ini automatically once the license exists. Use this button to re-apply it after a Denuvo refresh." FontSize="12" Foreground="#7E93A6" TextWrapping="Wrap" Margin="0,2,0,10"/>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <CheckBox x:Name="ChkCopyToken" Grid.Column="0" Content="Also copy token to clipboard" Foreground="#9FB2C4" VerticalAlignment="Center"/>
                <Button x:Name="BtnToken" Grid.Column="1" Style="{StaticResource GreenButton}" Content="Re-apply token"/>
              </Grid>
            </StackPanel>
          </Border>
        </StackPanel>
      </Grid>
    </ScrollViewer>

    <!-- Footer -->
    <Border Grid.Row="3" Background="#0B1119" Padding="22,12" BorderBrush="#1B2836" BorderThickness="0,1,0,0">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" VerticalAlignment="Center">
          <TextBlock x:Name="LogText" Text="" FontSize="12" Foreground="#7E93A6" TextWrapping="Wrap"/>
          <TextBlock Text="3circledesign" FontSize="11" Foreground="#465A6E" Margin="0,3,0,0"/>
        </StackPanel>
        <Button x:Name="BtnRecheck" Grid.Column="1" Style="{StaticResource GhostButton}" Content="Re-check" VerticalAlignment="Center"/>
      </Grid>
    </Border>

    <!-- Download / install overlay (covers everything while patching) -->
    <Grid x:Name="PatchOverlay" Grid.Row="0" Grid.RowSpan="4" Panel.ZIndex="99" Visibility="Collapsed" Background="#E60A0F16">
      <Border Background="#16212E" BorderBrush="#2A3F5A" BorderThickness="1" CornerRadius="12" Padding="30,26"
              Width="450" VerticalAlignment="Center" HorizontalAlignment="Center">
        <StackPanel>
          <StackPanel Orientation="Horizontal">
            <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE896;" FontSize="26" Foreground="#66C0F4" VerticalAlignment="Center" Margin="0,0,12,0"/>
            <TextBlock Text="Installing FC27 patch" FontSize="19" FontWeight="Bold" Foreground="#EAF2F8" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock x:Name="PatchStatus" Text="Downloading patch files from GitHub..." FontSize="14" Foreground="#C7D5E0" TextWrapping="Wrap" Margin="0,16,0,14"/>
          <ProgressBar x:Name="PatchBar" IsIndeterminate="True" Height="7" Foreground="#66C0F4" Background="#0E1620" BorderThickness="0"/>
          <TextBlock Text="Downloading from github.com/barryhamsy/fc26_standalone_installer. This can take a few minutes on a slow connection - please keep this window open." FontSize="11" Foreground="#7E93A6" TextWrapping="Wrap" Margin="0,16,0,0"/>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

    [xml]$xaml = $xamlText
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $UI = @{}
    foreach ($name in @('BannerBorder', 'BannerIcon', 'BannerTitle', 'BannerDetail',
            'PanelOnboard', 'S1Circle', 'S1Num', 'S2Circle', 'S2Num', 'S3Circle', 'S3Num',
            'BtnPrimary', 'PrimaryHint',
            'PanelTools', 'TxtGameDir', 'BtnBrowse', 'ConfigWarn',
            'ChkCopyToken', 'BtnToken', 'LogText', 'BtnRecheck',
            'PatchOverlay', 'PatchStatus')) {
        $UI[$name] = $window.FindName($name)
    }
    $script:UI = $UI
    $script:Window = $window

    # A game folder passed with -GameDir is a manual override; otherwise auto-detect.
    $script:ForcedGameDir = $GameDir
    if ([string]::IsNullOrWhiteSpace($GameDir)) {
        $GameDir = Get-Fc27GameDir -State (Get-SteamAppState -AppId $script:AppId)
    }
    $script:GameDir = $GameDir
    $script:LicensePath = $LicensePath
    $UI.TxtGameDir.Text = $script:GameDir

    # ---- event wiring (handlers use script-scoped state + functions) ------
    $UI.BtnPrimary.Add_Click({ Open-Fc27Url $script:PrimaryUrl })
    $UI.BtnRecheck.Add_Click({ Update-Fc27Gate; Set-Fc27Log 'Re-checked.' 'muted' })

    $UI.BtnBrowse.Add_Click({
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'Select the folder that contains anadius.cfg and token.ini'
            if (Test-Path -LiteralPath $script:GameDir) { $dlg.SelectedPath = $script:GameDir }
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $script:GameDir = $dlg.SelectedPath
                $script:ForcedGameDir = $dlg.SelectedPath   # manual choice wins over auto-detect
                $script:UI.TxtGameDir.Text = $script:GameDir
                Test-Fc27Configs
                Set-Fc27Log 'Game folder set.' 'muted'
            }
        })

    $UI.BtnToken.Add_Click({ Invoke-Fc27TokenApply -Manual $true })

    # Auto-refresh while onboarding is visible (e.g. right after first launch),
    # and drive the background patch step.
    $script:Fc27Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Fc27Timer.Interval = [TimeSpan]::FromSeconds(3)
    $script:Fc27Timer.Add_Tick({
            if ($script:UI.PanelOnboard.Visibility -eq [System.Windows.Visibility]::Visible) {
                Update-Fc27Gate
            }
        })
    $script:Fc27Timer.Start()

    $script:PatchTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:PatchTimer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:PatchTimer.Add_Tick({ Update-Fc27PatchProgress })

    $window.Add_Closed({
            if ($script:Fc27Timer) { $script:Fc27Timer.Stop() }
            if ($script:PatchTimer) { $script:PatchTimer.Stop() }
            try { if ($script:PatchPS) { $script:PatchPS.Dispose() } } catch { }
            try { if ($script:PatchRunspace) { $script:PatchRunspace.Dispose() } } catch { }
        })

    # Kick off the patch download + first gate check once the window is on screen,
    # so nothing blocks before the UI renders.
    $window.Add_ContentRendered({
            $script:WindowShown = $true
            Update-Fc27Gate
        })
    [void]$window.ShowDialog()
}

# ==========================================================================
#  ENTRY POINT
# ==========================================================================
try {
    if (-not [string]::IsNullOrWhiteSpace($Action)) {
        Invoke-CliMode
        exit 0
    }
    Hide-ConsoleWindow
    Show-Gui
    exit 0
}
catch {
    $message = 'Error: ' + $_.Exception.Message
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
        [System.Windows.MessageBox]::Show($message, 'FC27 Token Updater', 'OK', 'Error') | Out-Null
    }
    catch {
        [Console]::Error.WriteLine($message)
    }
    exit 1
}
