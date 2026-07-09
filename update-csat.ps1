# update-csat.ps1 - Pulls CSAT from Sphere_sana_Live + Maya VoiceflowRating, updates index.html
# Right-click and choose "Run with PowerShell"

$SphereServer   = "10.171.0.9"
$SphereDatabase = "Sphere_sana_Live"
$PrismaDatabase = "prisma_sana_live"
$UserId         = "t.atef"
$Password       = "D@a6bKq7zsrWC2!"
$DashboardDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$IndexHtml      = Join-Path $DashboardDir "index.html"

Write-Host ""
Write-Host "=== Support Dashboard - CSAT + Maya Update ===" -ForegroundColor Cyan
Write-Host ""

function OpenConn($db) {
    $cs = "Server=$SphereServer;Database=$db;User ID=$UserId;Password=$Password;TrustServerCertificate=True;Encrypt=False;Connect Timeout=30;"
    $c  = New-Object System.Data.SqlClient.SqlConnection($cs)
    $c.Open()
    return $c
}

# Step 1: Load email to display name from Prisma
Write-Host "  Loading employee directory..." -ForegroundColor Cyan
try {
    $pConn = OpenConn $PrismaDatabase
    $pCmd  = $pConn.CreateCommand()
    $pCmd.CommandText = "SELECT CompanyEmailAddress, LTRIM(RTRIM(FirstName)) + ' ' + LTRIM(RTRIM(LastName)) AS DisplayName FROM OrganizationEmployee WHERE Deactivated = 0 AND CompanyEmailAddress LIKE '%@sana-commerce.com'"
    $pDt   = New-Object System.Data.DataTable
    (New-Object System.Data.SqlClient.SqlDataAdapter($pCmd)).Fill($pDt) | Out-Null
    $pConn.Close()
    $emailMap = @{}
    foreach ($r in $pDt.Rows) {
        $email = ([string]$r["CompanyEmailAddress"]).ToLower().Trim()
        $name  = ([string]$r["DisplayName"]).Trim() -replace '\s+',' '
        if ($email -and $name) { $emailMap[$email] = $name }
    }
    Write-Host "  Loaded $($emailMap.Count) employees" -ForegroundColor Green
} catch {
    Write-Host "  WARNING: Could not load employee directory: $_" -ForegroundColor Yellow
    $emailMap = @{}
}

# Step 2: Connect to Sphere
Write-Host "  Connecting to Sphere_sana_Live..." -ForegroundColor Cyan
try {
    $sConn = OpenConn $SphereDatabase
    Write-Host "  Connected" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: Could not connect: $_" -ForegroundColor Red
    Read-Host "Press Enter to close"; exit 1
}

# Step 3: Query Feedback table (SA CSAT)
Write-Host "  Querying SA Feedback table..." -ForegroundColor Cyan
$sql = "SELECT Rating, SupportExperience, [ ServiceConsultant], WorkItemId, Comment, NegativeReason, Timestamp FROM [dbo].[Feedback] WHERE Timestamp IS NOT NULL AND Timestamp >= '2026-01-01' ORDER BY Timestamp DESC"
$sCmd             = $sConn.CreateCommand()
$sCmd.CommandText = $sql
$sCmd.CommandTimeout = 60
$sDt              = New-Object System.Data.DataTable
(New-Object System.Data.SqlClient.SqlDataAdapter($sCmd)).Fill($sDt) | Out-Null
Write-Host "  Found $($sDt.Rows.Count) SA CSAT responses" -ForegroundColor Green

# Step 4: Query VoiceflowRating table (Maya CSAT)
Write-Host "  Querying Maya VoiceflowRating table..." -ForegroundColor Cyan
$chkCmd = $sConn.CreateCommand()
$chkCmd.CommandText = "SELECT CASE WHEN COL_LENGTH('dbo.VoiceflowRating','WorkItemId') IS NOT NULL THEN 1 ELSE 0 END"
$hasWI  = [int]$chkCmd.ExecuteScalar()
$wiCol  = if ($hasWI) { "CAST(WorkItemId AS NVARCHAR) AS WorkItemId" } else { "CAST(NULL AS NVARCHAR) AS WorkItemId" }
$mCmd             = $sConn.CreateCommand()
$mCmd.CommandText = "SELECT ID, Rating, CustomerEmail, AgentVersion, ConversationSummary, ImprovementFeedback, Timestamp, $wiCol FROM [dbo].[VoiceflowRating] WHERE Timestamp IS NOT NULL ORDER BY Timestamp DESC"
$mCmd.CommandTimeout = 60
$mDt              = New-Object System.Data.DataTable
(New-Object System.Data.SqlClient.SqlDataAdapter($mCmd)).Fill($mDt) | Out-Null
$sConn.Close()
Write-Host "  Found $($mDt.Rows.Count) Maya CSAT responses" -ForegroundColor Green

# Step 5: Map SA CSAT rows
$ratingMap = @{ '2'='very satisfied'; '1'='satisfied'; '0'='neutral'; '-1'='unsatisfied'; '-2'='very unsatisfied' }
$cetMap    = @{ '2'='Very Easy'; '1'='Easy'; '0'='Neither'; '-1'='Difficult'; '-2'='Very Difficult' }
$saRows = [System.Collections.Generic.List[object]]::new()
foreach ($r in $sDt.Rows) {
    $ratingKey = [string][int]$r["Rating"]
    $rating    = $ratingMap[$ratingKey]; if (-not $rating) { continue }
    $ts = $r["Timestamp"]; if ($ts -is [System.DBNull]) { continue }
    $d = ([datetime]$ts).ToString("yyyy-MM-dd")
    $emailRaw = ([string]$r[" ServiceConsultant"]).Trim().ToLower()
    # Rows with empty SA email get c="" - they count in Overall but not individual analyst views
    # Rows with an unrecognised email keep the email as the name (as before)
    $analyst  = if ($emailMap.ContainsKey($emailRaw)) { $emailMap[$emailRaw] } elseif ($emailRaw) { $emailRaw } else { "" }
    $cetKey = if ($r["SupportExperience"] -is [System.DBNull]) { "" } else { [string][int]$r["SupportExperience"] }
    $cet    = if ($cetKey -ne "" -and $cetMap.ContainsKey($cetKey)) { $cetMap[$cetKey] } else { "" }
    $wi     = if ($r["WorkItemId"] -is [System.DBNull]) { $null } else { [int]$r["WorkItemId"] }
    $comment= if ($r["Comment"] -is [System.DBNull]) { "" } else { [string]$r["Comment"] }
    $reason = if ($r["NegativeReason"] -is [System.DBNull]) { "" } else { [string]$r["NegativeReason"] }
    $saRows.Add([ordered]@{ d=$d; acct=""; wi=$wi; c=$analyst; rating=$rating; reason=$reason; comment=$comment; mainCat=""; subCat=""; cet=$cet; _src="voiceflow" })
}
Write-Host "  Mapped $($saRows.Count) SA CSAT rows" -ForegroundColor Green

# Step 6: Map Maya rows
$mayaRows = [System.Collections.Generic.List[object]]::new()
foreach ($r in $mDt.Rows) {
    $ratingVal = if ($r["Rating"] -is [System.DBNull]) { continue } else { [int]$r["Rating"] }
    if ($ratingVal -lt 1 -or $ratingVal -gt 5) { continue }
    $ts = $r["Timestamp"]; if ($ts -is [System.DBNull]) { continue }
    $d       = ([datetime]$ts).ToString("yyyy-MM-dd")
    $custEmail = if ($r["CustomerEmail"] -is [System.DBNull]) { "" } else { [string]$r["CustomerEmail"] }
    $version   = if ($r["AgentVersion"] -is [System.DBNull]) { "" } else { [string]$r["AgentVersion"] }
    $summary   = if ($r["ConversationSummary"] -is [System.DBNull]) { "" } else { [string]$r["ConversationSummary"] }
    $fb        = if ($r["ImprovementFeedback"] -is [System.DBNull]) { "" } else { [string]$r["ImprovementFeedback"] }
    $rowId     = if ($r["ID"] -is [System.DBNull]) { 0 } else { [int]$r["ID"] }
    $wiId      = if ($r["WorkItemId"] -is [System.DBNull] -or [string]$r["WorkItemId"] -eq "") { 0 } else { try { [int]$r["WorkItemId"] } catch { 0 } }
    $mayaRows.Add([ordered]@{ id=$rowId; wi=$wiId; d=$d; cust=$custEmail; rating=$ratingVal; summary=$summary; fb=$fb; v=$version })
}
Write-Host "  Mapped $($mayaRows.Count) Maya rows" -ForegroundColor Green

if ($saRows.Count -eq 0 -and $mayaRows.Count -eq 0) {
    Write-Host "  No data found - dashboard not updated." -ForegroundColor Yellow
    Read-Host "Press Enter to close"; exit 0
}

# Step 7: Inject both into index.html
if (-not (Test-Path $IndexHtml)) {
    Write-Host "  ERROR: index.html not found at $IndexHtml" -ForegroundColor Red
    Read-Host "Press Enter to close"; exit 1
}

$content = [System.IO.File]::ReadAllText($IndexHtml, [System.Text.Encoding]::UTF8)

# Inject SA CSAT
if ($saRows.Count -gt 0) {
    $json   = $saRows | ConvertTo-Json -Compress -Depth 3
    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($json)
    $base64 = [Convert]::ToBase64String($bytes)
    $inject = "window._vfCsatAutoData=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('$base64'),c=>c.charCodeAt(0))));"
    $sm = "/* VF_CSAT_AUTO_START */"; $em = "/* VF_CSAT_AUTO_END */"
    $iStart = $content.IndexOf($sm); $iEnd = $content.IndexOf($em)
    if ($iStart -ge 0 -and $iEnd -ge 0) {
        $content = $content.Substring(0, $iStart + $sm.Length) + $inject + $content.Substring($iEnd)
        Write-Host "  SA CSAT injected ($($saRows.Count) rows)" -ForegroundColor Green
    } else { Write-Host "  WARNING: SA CSAT markers not found" -ForegroundColor Yellow }
}

# Inject Maya CSAT
if ($mayaRows.Count -gt 0) {
    $json2   = $mayaRows | ConvertTo-Json -Compress -Depth 3
    $bytes2  = [System.Text.Encoding]::UTF8.GetBytes($json2)
    $base642 = [Convert]::ToBase64String($bytes2)
    $inject2 = "window._mayaCsatData=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('$base642'),c=>c.charCodeAt(0))));"
    $sm2 = "/* MAYA_CSAT_AUTO_START */"; $em2 = "/* MAYA_CSAT_AUTO_END */"
    $iStart2 = $content.IndexOf($sm2); $iEnd2 = $content.IndexOf($em2)
    if ($iStart2 -ge 0 -and $iEnd2 -ge 0) {
        $content = $content.Substring(0, $iStart2 + $sm2.Length) + $inject2 + $content.Substring($iEnd2)
        Write-Host "  Maya CSAT injected ($($mayaRows.Count) rows)" -ForegroundColor Green
    } else { Write-Host "  WARNING: Maya CSAT markers not found" -ForegroundColor Yellow }
}

# Step 8: Query ADO directly for ALL closed tickets in 2026 (accurate monthly TTR)
# Load ADO credentials from ado_config.ps1 (gitignored - never commit that file)
$AdoConfigFile = Join-Path $DashboardDir "ado_config.ps1"
$AdoPat = ""; $AdoOrg = "https://sanacommerce.visualstudio.com"; $AdoProj = "Sana%20Projects"
if (Test-Path $AdoConfigFile) { . $AdoConfigFile } else {
    Write-Host "  NOTE: ado_config.ps1 not found - TTR data skipped. Create it with `$AdoPat, `$AdoOrg, `$AdoProj." -ForegroundColor Yellow
}

if (-not $AdoPat) {
    Write-Host "  Skipping ADO closed ticket query (no PAT configured in ado_config.ps1)" -ForegroundColor Yellow
} else {
    $AdoToken  = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
    $AdoHeaders = @{ Authorization = "Basic $AdoToken"; "Content-Type" = "application/json" }

    # Build reverse name map: lowercase display name -> canonical roster name
    $nameMap = @{}
    foreach ($name in $emailMap.Values) { $nameMap[$name.ToLower()] = $name }

    Write-Host "  Querying ADO for ALL closed tickets in 2026..." -ForegroundColor Cyan
    $adoClosedMap = @{}  # wi (int) -> {wi, closed, acct, c, age}

    try {
        # --- Part A: TicketSimple with ClosedDate in 2026 (exact close date) ---
        Write-Host "  Part A: TicketSimple closed from 2026-01-01 onward..." -ForegroundColor Cyan
        $gte = ">="
        $wiqlA = @{ query = "SELECT [System.Id] FROM WorkItems WHERE [System.WorkItemType]='TicketSimple' AND [Microsoft.VSTS.Common.ClosedDate] $gte '2026-01-01' ORDER BY [Microsoft.VSTS.Common.ClosedDate] DESC" } | ConvertTo-Json
        $resultA = Invoke-RestMethod -Uri "$AdoOrg/$AdoProj/_apis/wit/wiql?api-version=7.1" -Method POST -Headers $AdoHeaders -Body $wiqlA
        Write-Host "    Found $($resultA.workItems.Count) TicketSimple records" -ForegroundColor Green

        # --- Part B: Ticket-type Created in 2026, state=Done (use ChangedDate as close date approx) ---
        Write-Host "  Part B: Ticket type Created in 2026, state=Done..." -ForegroundColor Cyan
        $wiqlB = @{ query = "SELECT [System.Id] FROM WorkItems WHERE [System.WorkItemType]='Ticket' AND [System.State]='Done' AND [System.CreatedDate] $gte '2026-01-01' ORDER BY [System.ChangedDate] DESC" } | ConvertTo-Json
        $resultB = Invoke-RestMethod -Uri "$AdoOrg/$AdoProj/_apis/wit/wiql?api-version=7.1" -Method POST -Headers $AdoHeaders -Body $wiqlB
        Write-Host "    Found $($resultB.workItems.Count) Ticket (Done) records" -ForegroundColor Green

        # Combine all WI IDs (deduplicated)
        $allIds = [System.Collections.Generic.HashSet[int]]::new()
        $resultA.workItems | ForEach-Object { $allIds.Add([int]$_.id) | Out-Null }
        $resultB.workItems | ForEach-Object { $allIds.Add([int]$_.id) | Out-Null }
        $allIdArr = @($allIds)
        Write-Host "  Total unique WIs to fetch: $($allIdArr.Count)" -ForegroundColor Cyan

        # Batch-fetch fields (200 per call)
        $adoOk = 0; $adoFail = 0
        $batchSize = 200
        $adoFields = "System.Id,System.WorkItemType,System.CreatedDate,Microsoft.VSTS.Common.ClosedDate,System.ChangedDate,Custom.LastModifiedBy,System.AreaPath"
        $qsep = [char]38  # URL query string separator (&) - avoids PS5.1 parser issues with & in strings
        for ($i = 0; $i -lt $allIdArr.Count; $i += $batchSize) {
            $chunk  = $allIdArr[$i..([Math]::Min($i + $batchSize - 1, $allIdArr.Count - 1))]
            $idsStr = $chunk -join ','
            $url    = $AdoOrg + "/_apis/wit/workItems?ids=" + $idsStr + $qsep + "fields=" + $adoFields + $qsep + "api-version=7.1"
            try {
                $resp = Invoke-RestMethod -Uri $url -Method GET -Headers $AdoHeaders -ErrorAction Stop
                foreach ($item in $resp.value) {
                    $f   = $item.fields
                    $wid = [int]$f.'System.Id'
                    $wt  = [string]$f.'System.WorkItemType'

                    # Determine close date: TicketSimple uses ClosedDate; Ticket uses ChangedDate
                    $closedRaw = $null
                    if ($wt -eq 'TicketSimple' -and $f.'Microsoft.VSTS.Common.ClosedDate') {
                        $closedRaw = $f.'Microsoft.VSTS.Common.ClosedDate'
                    } elseif ($f.'System.ChangedDate') {
                        $closedRaw = $f.'System.ChangedDate'
                    }
                    if (-not $closedRaw) { $adoOk++; continue }

                    $closedDt  = [datetime]$closedRaw
                    # Skip if close date is outside 2026 (sanity guard)
                    if ($closedDt.Year -lt 2026 -or $closedDt.Year -gt 2026) { $adoOk++; continue }
                    $closedStr = $closedDt.ToString('yyyy-MM-dd')

                    # TTR
                    $age = $null
                    if ($f.'System.CreatedDate') {
                        $ttr = [int]($closedDt - [datetime]$f.'System.CreatedDate').TotalDays
                        if ($ttr -ge 0) { $age = $ttr }
                    }

                    # SA display name → match against roster
                    $rawSA = ([string]$f.'Custom.LastModifiedBy').Trim()
                    $saName = if ($rawSA -and $nameMap.ContainsKey($rawSA.ToLower())) { $nameMap[$rawSA.ToLower()] } else { $rawSA }

                    # Account from AreaPath last segment
                    $areaPath = ([string]$f.'System.AreaPath').Trim()
                    $acct = if ($areaPath) { ($areaPath -split '\\')[-1].Trim() } else { '' }

                    $adoClosedMap[$wid] = [ordered]@{ wi=$wid; closed=$closedStr; acct=$acct; c=$saName; age=$age }
                    $adoOk++
                }
            } catch {
                Write-Host "    Batch $i failed: $_" -ForegroundColor Yellow
                $adoFail += $chunk.Count
            }
            if (($i / $batchSize) % 5 -eq 4) { Write-Host "    ...processed $($i + $batchSize) / $($allIdArr.Count)" -ForegroundColor Gray }
        }
        $withTTR = ($adoClosedMap.Values | Where-Object { $_.age -ne $null }).Count
        Write-Host "  ADO fetch done: $adoOk ok, $adoFail failed, $($adoClosedMap.Count) records, $withTTR with TTR" -ForegroundColor Green

        $closedRows = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $adoClosedMap.Values) { $closedRows.Add($row) }
        $closedRows = $closedRows | Sort-Object { $_.closed } -Descending
        Write-Host "  Total closed rows to inject: $($closedRows.Count)" -ForegroundColor Green

        if ($closedRows.Count -gt 0) {
            $frJson   = $closedRows | ConvertTo-Json -Compress -Depth 3
            $frBytes  = [System.Text.Encoding]::UTF8.GetBytes($frJson)
            $frBase64 = [Convert]::ToBase64String($frBytes)
            $frInject = "window._adoClosedAutoData=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('$frBase64'),c=>c.charCodeAt(0))));"
            $frSm = "/* ADO_CLOSED_AUTO_START */"; $frEm = "/* ADO_CLOSED_AUTO_END */"
            $frStart = $content.IndexOf($frSm); $frEnd = $content.IndexOf($frEm)
            if ($frStart -ge 0 -and $frEnd -ge 0) {
                $content = $content.Substring(0, $frStart + $frSm.Length) + $frInject + $content.Substring($frEnd)
                Write-Host "  Closed tickets injected ($($closedRows.Count) rows, $withTTR with TTR)" -ForegroundColor Green
            } else { Write-Host "  WARNING: ADO_CLOSED_AUTO markers not found in index.html" -ForegroundColor Yellow }
        }
    } catch {
        Write-Host "  WARNING: ADO closed ticket query failed: $_" -ForegroundColor Yellow
    }
}

[System.IO.File]::WriteAllText($IndexHtml, $content, [System.Text.Encoding]::UTF8)
Write-Host ""
Write-Host "  Done. Refresh the dashboard to see updated data." -ForegroundColor Green
Write-Host ""
Start-Sleep -Seconds 3