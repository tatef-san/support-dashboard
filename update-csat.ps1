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
$sql = "SELECT Rating, SupportExperience, [ ServiceConsultant], WorkItemId, Comment, NegativeReason, Timestamp FROM [dbo].[Feedback] WHERE Timestamp IS NOT NULL AND [ ServiceConsultant] IS NOT NULL AND [ ServiceConsultant] <> '' ORDER BY Timestamp DESC"
$sCmd             = $sConn.CreateCommand()
$sCmd.CommandText = $sql
$sCmd.CommandTimeout = 60
$sDt              = New-Object System.Data.DataTable
(New-Object System.Data.SqlClient.SqlDataAdapter($sCmd)).Fill($sDt) | Out-Null
Write-Host "  Found $($sDt.Rows.Count) SA CSAT responses" -ForegroundColor Green

# Step 4: Query VoiceflowRating table (Maya CSAT)
Write-Host "  Querying Maya VoiceflowRating table..." -ForegroundColor Cyan
$mCmd             = $sConn.CreateCommand()
$mCmd.CommandText = "SELECT ID, Rating, CustomerEmail, AgentVersion, ConversationSummary, ImprovementFeedback, Timestamp FROM [dbo].[VoiceflowRating] WHERE Timestamp IS NOT NULL ORDER BY Timestamp DESC"
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
    $analyst  = if ($emailMap.ContainsKey($emailRaw)) { $emailMap[$emailRaw] } else { $emailRaw }
    if (-not $analyst) { continue }
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
    $mayaRows.Add([ordered]@{ id=$rowId; d=$d; cust=$custEmail; rating=$ratingVal; summary=$summary; fb=$fb; v=$version })
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

[System.IO.File]::WriteAllText($IndexHtml, $content, [System.Text.Encoding]::UTF8)
Write-Host ""
Write-Host "  Done. Refresh the dashboard to see updated data." -ForegroundColor Green
Write-Host ""
Start-Sleep -Seconds 3