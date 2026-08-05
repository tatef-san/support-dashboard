# update-csat.ps1
# Pulls CSAT data from Sphere_sana_Live and bakes it directly into index.html.
# Double-click this file (or right-click → Run with PowerShell) to refresh CSAT.
# No browser interaction needed — just open/refresh the dashboard afterwards.

$Server       = "10.171.0.9"
$Database     = "Sphere_sana_Live"
$DashboardDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$IndexHtml    = Join-Path $DashboardDir "index.html"

Write-Host ""
Write-Host "=== Support Dashboard — CSAT Update ===" -ForegroundColor Cyan
Write-Host ""

# ── 1. Connect to database ────────────────────────────────────────────────────
$cs   = "Server=$Server;Database=$Database;User ID=t.atef;Password=D@a6bKq7zsrWC2!;TrustServerCertificate=True;Encrypt=False;Connect Timeout=30;"
$conn = New-Object System.Data.SqlClient.SqlConnection($cs)
try {
    $conn.Open()
    Write-Host "  Connected to $Database" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: Could not connect to database: $_" -ForegroundColor Red
    Write-Host "  Make sure you are on the Sana network or VPN." -ForegroundColor Yellow
    Read-Host "`nPress Enter to close"
    exit 1
}

# ── 2. Query Feedback table ───────────────────────────────────────────────────
Write-Host "  Querying Feedback table..." -ForegroundColor Cyan
$sql = "SELECT f.Rating, f.SupportExperience, e.DisplayName AS ServiceConsultant, f.WorkItemId, f.Comment, f.NegativeReason, f.Timestamp FROM [dbo].[Feedback] f INNER JOIN [Prisma_sana_live].[dbo].[OrganizationEmployee] e ON LOWER(e.CompanyEmailAddress) = LOWER(f.[ ServiceConsultant]) WHERE f.Timestamp >= '2026-01-01' AND f.[ ServiceConsultant] IS NOT NULL AND f.[ ServiceConsultant] <> '' AND LOWER(f.[ ServiceConsultant]) LIKE '%@sana-commerce.com' ORDER BY f.Timestamp DESC"
$cmd             = $conn.CreateCommand()
$cmd.CommandText = $sql
$cmd.CommandTimeout = 60
$adapter         = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
$dt              = New-Object System.Data.DataTable
$adapter.Fill($dt) | Out-Null
$conn.Close()
Write-Host "  Found $($dt.Rows.Count) CSAT responses" -ForegroundColor Green

if ($dt.Rows.Count -eq 0) {
    Write-Host "  No data found — dashboard not updated." -ForegroundColor Yellow
    Read-Host "`nPress Enter to close"
    exit 0
}

# ── 3. Map to dashboard CSAT format ──────────────────────────────────────────
$ratingMap = @{ '2'='very satisfied'; '1'='satisfied'; '0'='neutral'; '-1'='unsatisfied'; '-2'='very unsatisfied' }
$cetMap    = @{ '2'='Very Easy'; '1'='Easy'; '0'='Neither'; '-1'='Difficult'; '-2'='Very Difficult' }

$rows = @()
foreach ($r in $dt.Rows) {
    $ratingKey = [string][int]$r["Rating"]
    $rating    = $ratingMap[$ratingKey]
    if (-not $rating) { continue }

    $ts = $r["Timestamp"]
    $d  = if ($ts -is [DBNull] -or $ts -eq $null) { $null } else { ([datetime]$ts).ToString("yyyy-MM-dd") }
    if (-not $d) { continue }

    $analyst = ([string]$r["ServiceConsultant"]).Trim()
    if (-not $analyst) { continue }

    $cetKey = if ($r["SupportExperience"] -is [DBNull]) { "" } else { [string][int]$r["SupportExperience"] }
    $cet    = if ($cetMap[$cetKey]) { $cetMap[$cetKey] } else { "" }

    $wi      = if ($r["WorkItemId"] -is [DBNull]) { $null } else { [int]$r["WorkItemId"] }
    $comment = if ($r["Comment"]       -is [DBNull]) { "" } else { [string]$r["Comment"] }
    $reason  = if ($r["NegativeReason"] -is [DBNull]) { "" } else { [string]$r["NegativeReason"] }

    $rows += [ordered]@{
        d       = $d
        acct    = ""
        wi      = $wi
        c       = $analyst
        rating  = $rating
        reason  = $reason
        comment = $comment
        mainCat = ""
        subCat  = ""
        cet     = $cet
        "_src"  = "voiceflow"
    }
}

Write-Host "  Mapped $($rows.Count) valid rows" -ForegroundColor Green

# ── 4. Encode as base64 JSON (safe for embedding in a <script> tag) ───────────
$json   = $rows | ConvertTo-Json -Compress -Depth 3
$bytes  = [System.Text.Encoding]::UTF8.GetBytes($json)
$base64 = [Convert]::ToBase64String($bytes)
$inject = "window._vfCsatAutoData=JSON.parse(atob('$base64'));"

# ── 5. Patch index.html between the markers ───────────────────────────────────
if (-not (Test-Path $IndexHtml)) {
    Write-Host "  ERROR: index.html not found at $IndexHtml" -ForegroundColor Red
    Read-Host "`nPress Enter to close"
    exit 1
}

$content = [System.IO.File]::ReadAllText($IndexHtml, [System.Text.Encoding]::UTF8)

$pattern     = '(/\* VF_CSAT_AUTO_START \*/)[\s\S]*?(/\* VF_CSAT_AUTO_END \*/)'
$replacement = '${1}' + $inject + '${2}'
$newContent  = [regex]::Replace($content, $pattern, $replacement)

if ($newContent -eq $content) {
    Write-Host "  WARNING: Marker not found in index.html — file was not updated." -ForegroundColor Yellow
    Write-Host "  Make sure index.html contains the VF_CSAT_AUTO_START marker." -ForegroundColor Yellow
} else {
    [System.IO.File]::WriteAllText($IndexHtml, $newContent, [System.Text.Encoding]::UTF8)
    Write-Host "  index.html updated successfully" -ForegroundColor Green
}

# ── 6. Push to GitHub ────────────────────────────────────────────────────────
Write-Host "  Pushing to GitHub..." -ForegroundColor Cyan
Push-Location $DashboardDir
try {
    git add index.html 2>&1 | Out-Null
    $stamp = Get-Date -Format "yyyy-MM-dd HH:mm"
    git commit -m "Update CSAT data ($stamp)" 2>&1 | Out-Null
    git push origin main 2>&1 | Out-Null
    Write-Host "  Pushed to GitHub — dashboard will refresh in ~1 min." -ForegroundColor Green
} catch {
    Write-Host "  WARNING: Git push failed: $_" -ForegroundColor Yellow
} finally {
    Pop-Location
}

# ── 7. Done ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  CSAT update complete — $($rows.Count) rows baked into dashboard." -ForegroundColor Green
Write-Host "  Open or refresh the dashboard to see updated CSAT data." -ForegroundColor Cyan
Write-Host ""
Start-Sleep -Seconds 2
