# update-util.ps1 — Pull logged hours + iterations from Prisma_sana_live
# Injects analyst utilisation data directly into the dashboard.
# Double-click to run (or: Right-click → Run with PowerShell)

param(
    [string]$YearStart    = "$(Get-Date -Format yyyy)-01-01",
    [string]$DashboardDir = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

$Server    = "10.171.0.9"
$Database  = "prisma_sana_live"
$IndexHtml = Join-Path $DashboardDir "index.html"

# Windows Authentication — same as customer_support_validation.ps1
$CS = "Server=$Server;Database=$Database;Integrated Security=True;TrustServerCertificate=True;Encrypt=False;Connect Timeout=30;"

Write-Host ""
Write-Host "=== Support Dashboard — Utilisation Sync from Prisma ===" -ForegroundColor Cyan
Write-Host "  Period : $YearStart to today" -ForegroundColor Gray
Write-Host ""

function RunQuery([string]$sql, [int]$timeout = 120) {
    $conn = New-Object System.Data.SqlClient.SqlConnection($CS)
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.CommandTimeout = $timeout
    $da = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dt = New-Object System.Data.DataTable
    $da.Fill($dt) | Out-Null
    $conn.Close()
    return $dt
}

# ── Step 1: Connect ───────────────────────────────────────────────────────────
Write-Host "  Connecting to Prisma_sana_live..." -ForegroundColor Cyan
try {
    RunQuery "SELECT 1" | Out-Null
    Write-Host "  Connected." -ForegroundColor Green
} catch {
    Write-Host "  ERROR: Could not connect — $_" -ForegroundColor Red
    Write-Host "  Make sure you are on the Sana network (or VPN)." -ForegroundColor Yellow
    Read-Host "Press Enter to close"; exit 1
}

# ── Step 2: Query hours per analyst per ISO week ──────────────────────────────
Write-Host "  Querying TimeHour data..." -ForegroundColor Cyan

$sql = @"
SELECT
    COALESCE(e.DisplayName, LTRIM(RTRIM(e.FirstName)) + ' ' + LTRIM(RTRIM(e.LastName))) AS EmployeeName,
    e.CompanyEmailAddress                                                                  AS Email,
    DATEPART(ISO_WEEK, th.WorkDate)                                                       AS IsoWeek,
    YEAR(th.WorkDate)                                                                     AS WorkYear,
    SUM(th.BillableHours)                                                                 AS TotalHours,
    MAX(pi.FullName)                                                                      AS IterationName,
    MAX(rt.Name)                                                                          AS IterationType
FROM       [TimeHour]             th
INNER JOIN [OrganizationEmployee] e  ON e.ID  = th.EmployeeID
LEFT  JOIN [ProjectIteration]     pi ON pi.ID = th.IterationID
LEFT  JOIN [ReferenceIterationType] rt ON rt.ID = pi.IterationTypeID
WHERE th.WorkDate >= '$YearStart'
  AND e.Deactivated = 0
  AND e.CompanyEmailAddress LIKE '%@sana-commerce.com'
GROUP BY
    e.DisplayName, e.FirstName, e.LastName, e.CompanyEmailAddress,
    DATEPART(ISO_WEEK, th.WorkDate), YEAR(th.WorkDate)
ORDER BY
    e.DisplayName, YEAR(th.WorkDate), DATEPART(ISO_WEEK, th.WorkDate)
"@

try {
    $dt = RunQuery $sql
    Write-Host "  Found $($dt.Rows.Count) analyst-week rows." -ForegroundColor Green
} catch {
    Write-Host "  ERROR querying TimeHour: $_" -ForegroundColor Red
    Read-Host "Press Enter to close"; exit 1
}

if ($dt.Rows.Count -eq 0) {
    Write-Host "  No hours data found — dashboard not updated." -ForegroundColor Yellow
    Read-Host "Press Enter to close"; exit 0
}

# ── Step 3: Build util store (keyed by display name) ─────────────────────────
$store = [ordered]@{}
foreach ($r in $dt.Rows) {
    $name  = ([string]$r["EmployeeName"]).Trim() -replace '\s+', ' '
    if (-not $name -or $name -eq ' ') { continue }

    $year  = [int]$r["WorkYear"]
    $week  = [int]$r["IsoWeek"]
    $label = "Week $week $year"
    $hrs   = try { [double]$r["TotalHours"] } catch { 0 }
    $iter  = if ($r["IterationName"] -isnot [System.DBNull]) { [string]$r["IterationName"] } else { "" }
    $type  = if ($r["IterationType"]  -isnot [System.DBNull]) { [string]$r["IterationType"]  } else { "" }

    if (-not $store[$name]) { $store[$name] = [System.Collections.Generic.List[object]]::new() }
    # Deduplicate: replace if same week already exists
    $store[$name] = [System.Collections.Generic.List[object]]($store[$name] | Where-Object { $_.week -ne $label })
    $entry = [ordered]@{ week = $label; ticketHours = [math]::Round($hrs, 2) }
    if ($iter) { $entry["iterationName"] = $iter }
    if ($type) { $entry["iterationType"] = $type }
    $store[$name].Add($entry)
}

# ── Summary table ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ("  {0,-35} {1,7} {2,8} {3,8}" -f "Analyst", "Weeks", "Hours", "Util%") -ForegroundColor Cyan
Write-Host ("  " + "-" * 65) -ForegroundColor DarkGray
foreach ($name in $store.Keys) {
    $entries = @($store[$name])
    $total   = ($entries | Measure-Object -Property ticketHours -Sum).Sum
    $wks     = $entries.Count
    $util    = if ($wks) { [math]::Round($total / ($wks * 40) * 100, 1) } else { 0 }
    $col     = if ($util -ge 80) { 'Green' } elseif ($util -ge 60) { 'Yellow' } else { 'Red' }
    Write-Host ("  {0,-35} {1,7} {2,8} {3,7}%" -f $name, $wks, [math]::Round($total,1), $util) -ForegroundColor $col
}
Write-Host ""

# ── Step 4: Inject into index.html ───────────────────────────────────────────
if (-not (Test-Path $IndexHtml)) {
    Write-Host "  ERROR: index.html not found at: $IndexHtml" -ForegroundColor Red
    Read-Host "Press Enter to close"; exit 1
}

$jsonObj = @{}
foreach ($k in $store.Keys) { $jsonObj[$k] = @($store[$k]) }
$json  = $jsonObj | ConvertTo-Json -Compress -Depth 4
$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
$b64   = [Convert]::ToBase64String($bytes)
$inject = "window._prismaUtilData=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('$b64'),c=>c.charCodeAt(0))));"

$content = [System.IO.File]::ReadAllText($IndexHtml, [System.Text.Encoding]::UTF8)
$sm = "/* UTIL_AUTO_START */"; $em = "/* UTIL_AUTO_END */"
$i1 = $content.IndexOf($sm); $i2 = $content.IndexOf($em)

if ($i1 -lt 0 -or $i2 -lt 0) {
    Write-Host "  ERROR: UTIL_AUTO markers not found in index.html." -ForegroundColor Red
    Write-Host "  Pull the latest dashboard from GitHub first." -ForegroundColor Yellow
    Read-Host "Press Enter to close"; exit 1
}

$content = $content.Substring(0, $i1 + $sm.Length) + $inject + $content.Substring($i2)
[System.IO.File]::WriteAllText($IndexHtml, $content, [System.Text.Encoding]::UTF8)

Write-Host "  Done!  $($store.Count) analysts · $($dt.Rows.Count) week entries injected." -ForegroundColor Green
Write-Host "  Open / refresh the dashboard to see updated utilization." -ForegroundColor Green
Write-Host ""
Start-Sleep -Seconds 2
