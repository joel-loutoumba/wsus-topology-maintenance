<#
.SYNOPSIS
    Monthly WSUS maintenance across a server topology, with an HTML e-mail report.

.DESCRIPTION
    For each WSUS server listed in -Servers (over the WSUS API, so it works against
    remote servers too):
      * collects health: role, last synchronization, client counts, clients in error;
      * declines 32-bit (x86) updates        (only where DeclineX86 = $true);
      * native cleanup A: obsolete computers, expired updates, unneeded content files;
      * native cleanup B: obsolete updates (isolated; can be heavy on a neglected DB).
    A single consolidated HTML report is e-mailed: totals + health table + actions
    table + legend. When clients are in error, a CSV (computer / KB / title) is attached.

    Use -ReportOnly for a read-only simulation (counts only, nothing is changed).
    See README.md for prerequisites, topology notes and scheduled-task setup.

.PARAMETER Servers
    Array of hashtables describing the topology. Each entry:
        @{ Name = '<host>'; Port = 8531|8530; Secure = $true|$false; DeclineX86 = $true|$false }
    On a replica topology, downstream servers inherit approvals/declines from the
    upstream: set DeclineX86 = $true only on the upstream (and on autonomous servers).

.PARAMETER SmtpServer      SMTP relay used to send the report.
.PARAMETER From            Sender address; supports "Display Name <address>".
.PARAMETER To              One or more recipients (array, or comma/semicolon string).
.PARAMETER LogPath         Transcript log file.
.PARAMETER ErrorCsvPath    CSV of clients in error (attached when non-empty).
.PARAMETER SkipDeclineX86  Globally disable the x86 decline step.
.PARAMETER ReportOnly      Simulation: count only, change nothing.
.PARAMETER NoMail          Do not send the e-mail (console/log output only).

.EXAMPLE
    .\Invoke-WsusMaintenance.ps1 -ReportOnly
    Simulation across all configured servers; nothing is modified.

.EXAMPLE
    .\Invoke-WsusMaintenance.ps1
    Full monthly run with e-mail report.

.NOTES
    Project : WSUS Topology Maintenance
    License : MIT
#>

[CmdletBinding()]
param(
    [object[]] $Servers = @(
        @{ Name = 'WSUS-UPSTREAM';      Port = 8531; Secure = $true; DeclineX86 = $true  }
        @{ Name = 'WSUS-DOWNSTREAM-01'; Port = 8531; Secure = $true; DeclineX86 = $false }
        # @{ Name = 'WSUS-DOWNSTREAM-02'; Port = 8531; Secure = $true; DeclineX86 = $false }
    ),
    [string]   $SmtpServer   = 'smtp.example.local',
    [string]   $From         = 'WSUS Report <wsus-report@example.local>',
    [string[]] $To           = @('it-admin@example.local'),
    [string]   $LogPath      = "$env:ProgramData\WsusMaintenance\maintenance.log",
    [string]   $ErrorCsvPath = "$env:ProgramData\WsusMaintenance\wsus-clients-in-error_$(Get-Date -Format 'yyyyMMdd_HHmm').csv",
    [switch]   $SkipDeclineX86,
    [switch]   $ReportOnly,
    [switch]   $NoMail
)

$ErrorActionPreference = 'Stop'
$StartTime    = Get-Date
$GlobalStatus = 'OK'
$Results      = New-Object System.Collections.Generic.List[object]
$ErrorRows    = New-Object System.Collections.Generic.List[object]
$UpdCache     = @{}

# --- Helpers -------------------------------------------------------------------
function ConvertTo-HtmlSafe([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
}
function Get-Worse([string]$a, [string]$b) {
    $rank = @{ 'OK' = 0; 'WARNING' = 1; 'FAILED' = 2 }
    if ($rank[$b] -gt $rank[$a]) { return $b } else { return $a }
}
function Get-NumSum($list, $prop) {
    $s = 0.0
    foreach ($r in $list) { $v = $r.$prop; if ("$v" -match '^\d+(\.\d+)?$') { $s += [double]$v } }
    return $s
}
function Format-Duration([TimeSpan]$span) {
    if     ($span.TotalHours   -ge 1) { return ('{0} h {1:00} min' -f [int]$span.TotalHours, $span.Minutes) }
    elseif ($span.TotalMinutes -ge 1) { return ('{0} min {1:00} s' -f $span.Minutes, $span.Seconds) }
    else                              { return ('{0} s'            -f [int]$span.TotalSeconds) }
}

# --- Init ----------------------------------------------------------------------
foreach ($dir in @((Split-Path $LogPath -Parent), (Split-Path $ErrorCsvPath -Parent))) {
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}
Start-Transcript -Path $LogPath -Append -Force | Out-Null

try {
    Import-Module UpdateServices -ErrorAction Stop
    Write-Output "=== WSUS TOPOLOGY MAINTENANCE : $($StartTime.ToString('yyyy-MM-dd HH:mm:ss')) ==="
    if ($ReportOnly) { Write-Output '*** SIMULATION (ReportOnly) ***' }

    foreach ($srv in $Servers) {
        $srvStart = Get-Date
        $name    = $srv.Name
        $port    = if ($srv.Port) { [int]$srv.Port } else { 8530 }
        $secure  = [bool]$srv.Secure
        $declX86 = (-not $SkipDeclineX86) -and ($srv.DeclineX86 -eq $true)

        $res = [ordered]@{
            Server = "${name}:$port"; Role = '?'; State = 'OK'
            SyncResult = '?'; SyncTime = '-'
            Clients = 0; ClientsErr = 0; ClientsNeed = 0
            X86 = 0; Expired = 0; Obsolete = 0; Computers = 0; ContentGB = 0
            Duration = '-'; Issues = ''
        }

        Write-Output "`n--- Server : ${name}:$port (SSL=$secure) ---"
        try {
            $p = @{ Name = $name; PortNumber = $port }
            if ($secure) { $p.UseSsl = $true }
            $wsus = Get-WsusServer @p
            Write-Output 'Connected.'

            # ---- Health (read-only, lightweight) ----
            try { $res.Role = if ($wsus.GetConfiguration().IsReplicaServer) { 'Replica' } else { 'Upstream' } } catch {}
            try {
                $st = $wsus.GetStatus()
                $res.Clients     = [int]$st.ComputerTargetCount
                $res.ClientsErr  = [int]$st.ComputerTargetsWithUpdateErrorsCount
                $res.ClientsNeed = [int]$st.ComputerTargetsNeedingUpdatesCount
            } catch { $res.Issues += 'GetStatus failed; ' }
            try {
                $si = $wsus.GetSubscription().GetLastSynchronizationInfo()
                $res.SyncResult = "$($si.Result)"
                if ($si.StartTime -and ([DateTime]$si.StartTime) -gt [DateTime]::MinValue) {
                    $res.SyncTime = ([DateTime]$si.StartTime).ToString('yyyy-MM-dd HH:mm')
                }
                if ($res.SyncResult -ne 'Succeeded') { $res.State = Get-Worse $res.State 'WARNING' }
            } catch { $res.SyncResult = '?' }
            if ($res.ClientsErr -gt 0) { $res.State = Get-Worse $res.State 'WARNING' }

            Write-Output ("Role={0} | Sync={1} ({2}) | Clients={3} (error={4}, need={5})" -f `
                $res.Role, $res.SyncResult, $res.SyncTime, $res.Clients, $res.ClientsErr, $res.ClientsNeed)

            # ---- Detail of clients in error (for the attached CSV) ----
            # WSUS exposes WHICH update failed on WHICH computer; the exact error code
            # (0x8024...) lives on the client (WindowsUpdate.log), not in WSUS.
            if ($res.ClientsErr -gt 0) {
                try {
                    $cs = New-Object Microsoft.UpdateServices.Administration.ComputerTargetScope
                    $cs.IncludedInstallationStates = [Microsoft.UpdateServices.Administration.UpdateInstallationStates]::Failed
                    $us = New-Object Microsoft.UpdateServices.Administration.UpdateScope
                    $us.IncludedInstallationStates = [Microsoft.UpdateServices.Administration.UpdateInstallationStates]::Failed
                    $errComp = $wsus.GetComputerTargets($cs)
                    foreach ($comp in $errComp) {
                        foreach ($iui in $comp.GetUpdateInstallationInfoPerUpdate($us)) {
                            if ("$($iui.UpdateInstallationState)" -ne 'Failed') { continue }
                            $uid = "$($iui.UpdateId)"
                            if (-not $UpdCache.ContainsKey($uid)) {
                                try { $UpdCache[$uid] = $wsus.GetUpdate($iui.UpdateId) } catch { $UpdCache[$uid] = $null }
                            }
                            $upd = $UpdCache[$uid]
                            $ErrorRows.Add([PSCustomObject]@{
                                Server         = "${name}:$port"
                                Computer       = $comp.FullDomainName
                                IPAddress      = $comp.IPAddress
                                LastContact    = $comp.LastReportedStatusTime
                                KB             = if ($upd) { ($upd.KnowledgebaseArticles -join ',') } else { '' }
                                Classification = if ($upd) { $upd.UpdateClassificationTitle } else { '' }
                                FailedUpdate   = if ($upd) { $upd.Title } else { $uid }
                            })
                        }
                    }
                    Write-Output "Error detail collected: $($errComp.Count) computer(s)."
                } catch { Write-Warning "Error-detail collection failed on $name : $_" }
            }

            if ($ReportOnly) {
                # ===== SIMULATION =====
                $allUpd = $wsus.GetUpdates()
                $res.X86 = ($allUpd | Where-Object {
                    (-not $_.IsDeclined) -and ($_.Title -match 'x86|32-Bit') -and ($_.Title -notmatch 'x64|ARM64')
                }).Count
                $res.Expired = ($allUpd | Where-Object {
                    (-not $_.IsDeclined) -and ($_.PublicationState -eq 'Expired')
                }).Count
                $threshold = (Get-Date).AddDays(-30)
                $res.Computers = ($wsus.GetComputerTargets() | Where-Object {
                    $c = @($_.LastSyncTime, $_.LastReportedStatusTime) | Where-Object { $_ -gt [DateTime]::MinValue }
                    if ($c) { (($c | Sort-Object)[-1]) -lt $threshold } else { $false }
                }).Count
                $res.Obsolete = 'n/a'
                Write-Output ("[Simulation] x86={0} | expired={1} | computers>30d={2} | obsolete=n/a" -f `
                    $res.X86, $res.Expired, $res.Computers)
            }
            else {
                # ===== LIVE RUN =====
                if ($declX86) {
                    $x86 = $wsus.GetUpdates() | Where-Object {
                        (-not $_.IsDeclined) -and ($_.Title -match 'x86|32-Bit') -and ($_.Title -notmatch 'x64|ARM64')
                    }
                    Write-Output "$($x86.Count) x86 update(s) not declined."
                    $okX = 0; $koReason = $null
                    foreach ($u in $x86) {
                        try { $u.Decline(); $okX++ }
                        catch {
                            $res.State = Get-Worse $res.State 'WARNING'
                            if (-not $koReason) {
                                $koReason = ($_.Exception.Message -split "`r?`n")[0]
                                Write-Warning "x86 decline failed on $name (replica?): $koReason"
                            }
                        }
                    }
                    $res.X86 = $okX
                    if ($koReason) { $res.Issues += "x86 decline failed ($koReason); " }
                    Write-Output "$okX x86 update(s) declined."
                }
                else { Write-Output 'x86 decline skipped (replica or disabled).' }

                # Cleanup A: obsolete computers / expired updates / unneeded content files
                try {
                    $cA = Invoke-WsusServerCleanup -UpdateServer $wsus `
                        -CleanupObsoleteComputers -DeclineExpiredUpdates -CleanupUnneededContentFiles
                    $res.Computers = [int]$cA.ObsoleteComputersDeleted
                    $res.Expired   = [int]$cA.ExpiredUpdatesDeclined
                    $res.ContentGB = if ($cA.DiskSpaceFreed) { [Math]::Round($cA.DiskSpaceFreed / 1GB, 2) } else { 0 }
                    Write-Output ("Cleanup A: computers={0} expired={1} content={2}GB" -f `
                        $res.Computers, $res.Expired, $res.ContentGB)
                }
                catch {
                    $res.State = Get-Worse $res.State 'WARNING'
                    $res.Issues += "Cleanup A failed: $_; "
                    Write-Warning "Cleanup A failed: $_"
                }

                # Cleanup B: obsolete updates (isolated; heavy on a neglected DB)
                try {
                    $cB = Invoke-WsusServerCleanup -UpdateServer $wsus -CleanupObsoleteUpdates
                    $res.Obsolete = [int]$cB.ObsoleteUpdatesDeleted
                    Write-Output ("Cleanup B: obsolete updates deleted={0}" -f $res.Obsolete)
                }
                catch {
                    $res.State = Get-Worse $res.State 'WARNING'
                    $res.Issues += 'Cleanup B (obsolete) failed -> remediate this DB locally; '
                    Write-Warning "Cleanup B failed (likely an unmaintained DB): $_"
                }
            }
        }
        catch {
            $res.State = 'FAILED'
            $res.Issues += "Connection/server failed: $_"
            Write-Warning "Server $name failed: $_"
        }

        $res.Duration = Format-Duration ((Get-Date) - $srvStart)
        $GlobalStatus = Get-Worse $GlobalStatus $res.State
        $Results.Add([PSCustomObject]$res)
    }

    Write-Output "`n=== DONE : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
}
catch {
    $GlobalStatus = 'FAILED'
    Write-Error "FATAL: $_"
}
finally {
    $end   = Get-Date
    $durTxt = Format-Duration ($end - $StartTime)
    $color  = switch ($GlobalStatus) { 'OK' { '#2e7d32' } 'WARNING' { '#f9a825' } default { '#c62828' } }
    $simTag = if ($ReportOnly) { ' [SIMULATION]' } else { '' }

    # --- Totals ---
    $totX86  = [int](Get-NumSum $Results 'X86')
    $totExp  = [int](Get-NumSum $Results 'Expired')
    $totOrd  = [int](Get-NumSum $Results 'Computers')
    $totGB   = [Math]::Round((Get-NumSum $Results 'ContentGB'), 2)
    $totObs  = if ($ReportOnly) { 'n/a' } else { [int](Get-NumSum $Results 'Obsolete') }
    $totCli  = [int](Get-NumSum $Results 'Clients')
    $totErr  = [int](Get-NumSum $Results 'ClientsErr')
    $nbOk    = ($Results | Where-Object { $_.State -eq 'OK' }).Count
    $nbWarn  = ($Results | Where-Object { $_.State -eq 'WARNING' }).Count
    $nbKo    = ($Results | Where-Object { $_.State -eq 'FAILED' }).Count
    $errBadge = if ($totErr -gt 0) { "<span style='color:#c62828;font-weight:bold'>$totErr</span>" } else { '0' }

    # --- CSV of clients in error (mail attachment) ---
    $attachments = @()
    $attachNote  = ''
    if ($ErrorRows.Count -gt 0) {
        try {
            $ErrorRows | Sort-Object Server, Computer, KB |
                Export-Csv -Path $ErrorCsvPath -Delimiter ';' -Encoding UTF8 -NoTypeInformation
            $attachments = @($ErrorCsvPath)
            $attachNote  = "<p style='color:#c62828'><b>$($ErrorRows.Count) failed update(s)</b> across clients in error &mdash; " +
                           "details (computer / IP / KB / title) attached: <i>$(Split-Path $ErrorCsvPath -Leaf)</i>.</p>"
            Write-Output "$($ErrorRows.Count) error row(s) exported: $ErrorCsvPath"
        } catch { Write-Warning "CSV export failed: $_" }
    }

    # --- Health table ---
    $rowsHealth = ($Results | ForEach-Object {
        $bg = switch ($_.State) { 'OK' { '#e8f5e9' } 'WARNING' { '#fff8e1' } default { '#ffebee' } }
        $sync = if ($_.SyncResult -eq 'Succeeded') { "$($_.SyncResult)" }
                else { "<span style='color:#c62828;font-weight:bold'>$(ConvertTo-HtmlSafe $_.SyncResult)</span>" }
        $err  = if ([int]$_.ClientsErr -gt 0) { "<span style='color:#c62828;font-weight:bold'>$($_.ClientsErr)</span>" } else { '0' }
        "<tr style='background:$bg'>" +
        "<td>$(ConvertTo-HtmlSafe $_.Server)</td>" +
        "<td align='center'>$($_.Role)</td>" +
        "<td align='center'>$($_.State)</td>" +
        "<td align='center'>$sync<br><span style='color:#888;font-size:11px'>$($_.SyncTime)</span></td>" +
        "<td align='right'>$($_.Clients)</td>" +
        "<td align='right'>$err</td>" +
        "<td align='right'>$($_.ClientsNeed)</td></tr>"
    }) -join ''

    # --- Actions table ---
    $rowsActions = ($Results | ForEach-Object {
        $bg = switch ($_.State) { 'OK' { '#e8f5e9' } 'WARNING' { '#fff8e1' } default { '#ffebee' } }
        "<tr style='background:$bg'>" +
        "<td>$(ConvertTo-HtmlSafe $_.Server)</td>" +
        "<td align='right'>$($_.X86)</td>" +
        "<td align='right'>$($_.Expired)</td>" +
        "<td align='right'>$($_.Obsolete)</td>" +
        "<td align='right'>$($_.Computers)</td>" +
        "<td align='right'>$($_.ContentGB)</td>" +
        "<td align='center'>$($_.Duration)</td>" +
        "<td>$(ConvertTo-HtmlSafe $_.Issues)</td></tr>"
    }) -join ''

    $body = @"
<html><body style='font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#222'>
<h2 style='color:$color;margin-bottom:4px'>WSUS Topology Maintenance$simTag &mdash; $GlobalStatus</h2>
<p style='margin-top:0'><b>Date:</b> $($StartTime.ToString('yyyy-MM-dd HH:mm:ss')) &mdash;
<b>Duration:</b> $durTxt &mdash;
<b>Servers:</b> $($Results.Count) ($nbOk OK, $nbWarn warning, $nbKo failed)</p>

<table cellpadding='8' style='border-collapse:collapse;background:#f5f7fa;border:1px solid #ddd'>
<tr>
<td><b>Clients</b><br>$totCli</td>
<td><b>Clients in error</b><br>$errBadge</td>
<td><b>x86 declined</b><br>$totX86</td>
<td><b>Expired declined</b><br>$totExp</td>
<td><b>Obsolete deleted</b><br>$totObs</td>
<td><b>Computers removed</b><br>$totOrd</td>
<td><b>Content freed</b><br>$totGB GB</td>
</tr>
</table>
$attachNote

<h3 style='margin-bottom:4px'>Server health</h3>
<table cellpadding='6' style='border-collapse:collapse' border='1'>
<tr style='background:#f0f0f0'>
<th align='left'>Server</th><th>Role</th><th>State</th><th>Last sync</th>
<th>Clients</th><th>In error</th><th>Needing updates</th></tr>
$rowsHealth
</table>

<h3 style='margin-bottom:4px'>Maintenance actions</h3>
<table cellpadding='6' style='border-collapse:collapse' border='1'>
<tr style='background:#f0f0f0'>
<th align='left'>Server</th><th>x86 decl.</th><th>Expired decl.</th><th>Obsolete del.</th>
<th>Computers del.</th><th>Content (GB)</th><th>Duration</th><th align='left'>Issues</th></tr>
$rowsActions
</table>

<h3 style='margin-bottom:4px'>Legend</h3>
<ul style='font-size:12px;color:#444;line-height:1.5'>
<li><b>Role</b>: Upstream manages approvals/declines; Replica inherits them (declines are read-only there, so it is normal that nothing is declined on a replica).</li>
<li><b>Last sync</b>: should be <i>Succeeded</i>. Anything else (red) means the catalog is no longer updating &mdash; investigate first.</li>
<li><b>In error</b> (red if &gt; 0): clients with at least one failed update. See the attached CSV for the failed KBs.</li>
<li><b>Needing updates</b>: clients missing approved updates &mdash; a coverage indicator, not an error.</li>
<li><b>x86 / Expired / Obsolete / Computers / Content</b>: volumes cleaned this run. Zeros everywhere = already healthy.</li>
<li><b>Row color</b>: green = OK, yellow = warning, red = failed.</li>
</ul>
<p style='color:#888;font-size:12px'>Generated $($end.ToString('yyyy-MM-dd HH:mm:ss')) &mdash; log: $LogPath</p>
</body></html>
"@

    Stop-Transcript | Out-Null

    if (-not $NoMail) {
        try {
            $recipients = @($To) |
                ForEach-Object { $_ -split '[;,]' } |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ }
            $subject = "[WSUS]$simTag $GlobalStatus - $($Results.Count) server(s), $totErr client(s) in error - $($end.ToString('yyyy-MM-dd'))"
            $mail = @{
                SmtpServer = $SmtpServer; From = $From; To = $recipients
                Subject = $subject; Body = $body; BodyAsHtml = $true
                Encoding = [System.Text.Encoding]::UTF8; ErrorAction = 'Stop'
            }
            if ($attachments.Count -gt 0) { $mail.Attachments = $attachments }
            Send-MailMessage @mail
            Write-Output "Report sent to: $($recipients -join ', ')"
        }
        catch { Write-Warning "E-mail send failed: $_" }
    }

    if ($GlobalStatus -eq 'FAILED') { exit 1 }
}
