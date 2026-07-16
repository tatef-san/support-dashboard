# dashboard_sql_api.ps1
# Local REST API — proxies Prisma SQL data for the Support Dashboard.
# Run this script while using the dashboard; it listens on http://localhost:3001.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File "C:\Sana\Rogier codes\dashboard_sql_api.ps1"
#
# Endpoints:
#   GET /api/active   — All 2026 Customer Support tickets (open + closed)
#   GET /api/health   — Liveness check
#
# Entra App Registration (for reference — used by dashboard MSAL.js, not this script)
#   Application ID : 4e71ab59-a8a6-432a-851f-e2882ed143ea
#   Tenant ID      : 783727bb-afca-4f4e-925b-d2df74e54c12

$Server = "10.171.0.9"
$DbUser = "t.atef"
$DbPass = "D@a6bKq7zsrWC2!"
$Port   = 3012

# ── DB helpers — ticket index DB (AzureDevops_Issue_Revision lives here) ──────
function Get-TicketConn {
    $cs = "Server=$Server;Database=Sana_Start_TicketIndex_live;User ID=$DbUser;Password=$DbPass;TrustServerCertificate=True;Encrypt=False;Connect Timeout=15;"
    $c = New-Object System.Data.SqlClient.SqlConnection($cs)
    $c.Open()
    return $c
}

function Query-Tickets($sql) {
    $conn = Get-TicketConn
    $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 60
    $da = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dt = New-Object System.Data.DataTable; $da.Fill($dt) | Out-Null
    $conn.Close()
    return $dt
}

# ── Team / shared mailboxes that are NOT individual analysts ──────────────────
$NON_ANALYST_EMAILS = @(
    'customer@sana-commerce.com',
    'core_support@sana-commerce.com',
    'sci@sana-commerce.com',
    'hosting@sana-commerce.com',
    'add-on_support@sana-commerce.com',
    'ax_fo_support@ism-egroup.com',
    'sapecc_support@ism-egroup.com',
    'support-planning@sana-commerce.com'
)

$NON_ANALYST_LOWER = $NON_ANALYST_EMAILS | ForEach-Object { $_.ToLower() }

# ── DB helpers ─────────────────────────────────────────────────────────────────
function Get-Conn {
    $cs = "Server=$Server;Database=Prisma_sana_live;User ID=$DbUser;Password=$DbPass;TrustServerCertificate=True;Encrypt=False;Connect Timeout=15;"
    $c = New-Object System.Data.SqlClient.SqlConnection($cs)
    $c.Open()
    return $c
}

function Query($sql) {
    $conn = Get-Conn
    $cmd = $conn.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 30
    $da = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dt = New-Object System.Data.DataTable; $da.Fill($dt) | Out-Null
    $conn.Close()
    return $dt
}

# ── SecondLayer SQL — last-touch attribution per ticket ───────────────────────
# For each 2026 support ticket, finds the last revision where one of our 16
# known CS analysts appears in AssignedTo OR ChangedBy. This mirrors how
# PowerBI attributes tickets to the analyst who last worked them.
$SECONDLAYER_SQL = @"
WITH all_touches AS (
    SELECT r.WorkItemId, r.Value AS email, r.Revision,
           ISNULL(oe.DisplayName, r.Value) AS analyst
    FROM dbo.AzureDevops_Issue_Revision r
    LEFT JOIN Prisma_sana_live.dbo.OrganizationEmployee oe
           ON LOWER(oe.CompanyEmailAddress) = LOWER(r.Value)
    WHERE r.Field IN ('System.AssignedTo','System.ChangedBy')
      AND LOWER(r.Value) IN (
          'a.nouraldeen@sana-commerce.com',
          'a.hoyos@sana-commerce.com',
          'n.salgado@sana-commerce.com',
          'm.bayoumi@sana-commerce.com',
          't.refaat@sana-commerce.com',
          's.elfaramawy@sana-commerce.com',
          's.sreedharan@sana-commerce.com',
          'm.johny@sana-commerce.com',
          'a.stephenson@sana-commerce.com',
          'a.chakravarty@sana-commerce.com',
          'g.overheul@sana-commerce.com',
          'j.huneburg@sana-commerce.com',
          'a.ohinska@sana-commerce.com',
          'k.durisova@sana-commerce.com',
          'ri.khan@sana-commerce.com',
          'm.martinez@sana-commerce.com'
      )
      AND r.WorkItemId IN (
          SELECT WorkitemId
          FROM Prisma_sana_live.dbo.AzureDevopsWorkitems
          WHERE Type IN ('Ticket','TicketSimple')
            AND (ProjectReleaseVersion LIKE 'Support%' OR ProjectReleaseVersion = 'Partner Support')
            AND ProjectReleaseVersion NOT LIKE '%wishlist%'
            AND CreatedDateUTC >= '2026-01-01'
      )
),
last_touch AS (
    SELECT WorkItemId, email, analyst,
           ROW_NUMBER() OVER (PARTITION BY WorkItemId ORDER BY Revision DESC) AS rn
    FROM all_touches
)
SELECT WorkItemId, email, analyst
FROM last_touch
WHERE rn = 1
ORDER BY WorkItemId DESC
"@

# ── SQL query for all 2026 Customer Support tickets ───────────────────────────
$ACTIVE_SQL = @"
SELECT
    w.WorkitemId                                        AS id,
    w.State                                             AS state,
    ISNULL(w.Title,'')                                  AS title,
    ISNULL(w.AssignedTo,'')                             AS assignedTo,
    ISNULL(w.AssignedToEmail,'')                        AS assignedToEmail,
    ISNULL(eAssigned.DisplayName,'')                    AS assignedName,
    ISNULL(org.Name,'')                                 AS region,
    CONVERT(varchar,w.CreatedDateUTC,23)                AS created,
    CONVERT(varchar,w.CloseDate,23)                     AS closed,
    CONVERT(varchar,w.ChangedDate,23)                   AS changed,
    ISNULL(w.TicketMainCategory,'')                     AS mainCat,
    ISNULL(w.TicketSubCategory,'')                      AS subCat,
    ISNULL(w.ProjectReleaseVersion,'')                  AS version,
    ISNULL(ii.CustomerName,'')                          AS customer,
    DATEDIFF(day, w.CreatedDateUTC,
        ISNULL(w.CloseDate, GETUTCDATE()))              AS age
FROM AzureDevopsWorkitems w
LEFT JOIN OrganizationEmployee eAssigned
       ON LOWER(eAssigned.CompanyEmailAddress) = LOWER(w.AssignedToEmail)
LEFT JOIN OrganizationRegion org ON org.ID = eAssigned.RegionId
LEFT JOIN ProjectIteration pi    ON pi.ID = w.ProjectIterationId
LEFT JOIN IterationInfo ii       ON ii.IterationID = w.ProjectIterationId
WHERE w.Type IN ('Ticket','TicketSimple')
  AND (w.ProjectReleaseVersion LIKE 'Support%' OR w.ProjectReleaseVersion = 'Partner Support')
  AND w.ProjectReleaseVersion NOT LIKE '%wishlist%'
  AND w.CreatedDateUTC >= '2026-01-01'
ORDER BY w.CreatedDateUTC DESC
"@

# ── JSON serialization helpers ────────────────────────────────────────────────
function Escape-Json([string]$s) {
    $s.Replace('\','\\').Replace('"','\"').Replace("`n",'\n').Replace("`r",'\r').Replace("`t",'\t')
}

function Row-To-Json($r, $nonAnalystLower) {
    # Determine pending status from assignee email
    $email  = ($r.assignedToEmail -as [string]).ToLower().Trim()
    $pending = if ($email -eq 'customer@sana-commerce.com') { 'customer' }
               elseif ($nonAnalystLower -contains $email)    { 'team' }
               else                                           { 'analyst' }

    # Analyst name: mapped DisplayName or fall back to AssignedTo raw
    $analyst = ($r.assignedName -as [string]).Trim()
    if (-not $analyst) { $analyst = ($r.assignedTo -as [string]).Trim() }
    if (-not $analyst -or ($nonAnalystLower -contains ($r.assignedToEmail -as [string]).ToLower())) {
        $analyst = ''  # no valid individual analyst
    }

    $age    = if ($r.age -eq [DBNull]::Value) { 0 } else { [int]$r.age }
    $closed = if ($r.closed -eq [DBNull]::Value -or [string]$r.closed -eq '') { 'null' } else { '"' + [string]$r.closed + '"' }

    return ('{' +
        '"id":"'           + [string]$r.id           + '",' +
        '"state":"'        + (Escape-Json [string]$r.state)   + '",' +
        '"title":"'        + (Escape-Json [string]$r.title)   + '",' +
        '"c":"'            + (Escape-Json $analyst)            + '",' +
        '"email":"'        + (Escape-Json $email)              + '",' +
        '"region":"'       + (Escape-Json [string]$r.region)  + '",' +
        '"created":"'      + [string]$r.created               + '",' +
        '"closed":'        + $closed                           + ',' +
        '"age":'           + $age                              + ',' +
        '"pendingCustomer":' + ($pending -eq 'customer').ToString().ToLower() + ',' +
        '"escalated":'     + ($pending -eq 'team').ToString().ToLower()       + ',' +
        '"mainCat":"'      + (Escape-Json [string]$r.mainCat) + '",' +
        '"subCat":"'       + (Escape-Json [string]$r.subCat)  + '",' +
        '"version":"'      + (Escape-Json [string]$r.version) + '",' +
        '"customer":"'     + (Escape-Json [string]$r.customer)+ '"' +
        '}')
}

# ── HTTP listener ──────────────────────────────────────────────────────────────
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() }
catch {
    Write-Host "Failed to start listener: $_" -ForegroundColor Red
    Write-Host "Try running as Administrator or check if port $Port is in use."
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "  Support Dashboard SQL API" -ForegroundColor Cyan
Write-Host "  Listening on http://localhost:$Port/" -ForegroundColor Green
Write-Host "  DB: $Server / Prisma_sana_live" -ForegroundColor Gray
Write-Host "  Press Ctrl+C to stop" -ForegroundColor Gray
Write-Host ""

try {
    while ($listener.IsListening) {
        $ctx  = $listener.GetContext()
        $req  = $ctx.Request
        $resp = $ctx.Response
        $path = $req.Url.AbsolutePath.ToLower().TrimEnd('/')

        # CORS — allow dashboard on any origin
        $resp.Headers.Add("Access-Control-Allow-Origin", "*")
        $resp.Headers.Add("Access-Control-Allow-Methods", "GET, OPTIONS")
        $resp.Headers.Add("Access-Control-Allow-Headers", "Content-Type, Authorization")
        $resp.ContentType = "application/json; charset=utf-8"

        if ($req.HttpMethod -eq "OPTIONS") { $resp.StatusCode = 200; $resp.Close(); continue }

        $ts = Get-Date -Format "HH:mm:ss"
        try {
            if ($path -eq "/api/health") {
                $body = '{"status":"ok","db":"Prisma_sana_live","port":' + $Port + '}'
                Write-Host "$ts GET /api/health" -ForegroundColor Gray
            }
            elseif ($path -eq "/api/active") {
                Write-Host "$ts GET /api/active — querying DB..." -ForegroundColor Yellow
                $dt   = Query $ACTIVE_SQL
                $jsonRows = ($dt.Rows | ForEach-Object { Row-To-Json $_ $NON_ANALYST_LOWER }) -join ','
                $body = '{"count":' + $dt.Rows.Count + ',"source":"prisma_sql","rows":[' + $jsonRows + ']}'
                Write-Host "$ts GET /api/active → $($dt.Rows.Count) tickets" -ForegroundColor Green
            }
            elseif ($path -eq "/api/secondlayer") {
                Write-Host "$ts GET /api/secondlayer — querying revision DB..." -ForegroundColor Yellow
                $dt = Query-Tickets $SECONDLAYER_SQL
                $jsonRows = ($dt.Rows | ForEach-Object {
                    $wi      = [string]$_.WorkItemId
                    $analyst = Escape-Json ([string]$_.analyst)
                    '{"wi":' + $wi + ',"analyst":"' + $analyst + '"}'
                }) -join ','
                $body = '{"count":' + $dt.Rows.Count + ',"source":"sql_secondlayer","rows":[' + $jsonRows + ']}'
                Write-Host "$ts GET /api/secondlayer → $($dt.Rows.Count) tickets" -ForegroundColor Green
            }
            else {
                $resp.StatusCode = 404
                $body = '{"error":"Not found","path":"' + $path + '"}'
            }
        }
        catch {
            $resp.StatusCode = 500
            $errMsg = ($_.Exception.Message -replace '"',"'") -replace '[\r\n]',' '
            $body = '{"error":"' + $errMsg + '"}'
            Write-Host "$ts ERROR: $_" -ForegroundColor Red
        }

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $resp.ContentLength64 = $bytes.Length
        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
        $resp.Close()
    }
}
finally {
    $listener.Stop()
    Write-Host "Server stopped." -ForegroundColor Gray
}
