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

# ── Business-hours calculator matching PowerBI "Adjusted Response Hours" ───────
# Fractional business hours — counts minutes within 09:00-17:30 NL time, skipping weekends
function Get-BizHours([datetime]$startUtc, [datetime]$endUtc) {
    if ($null -eq $startUtc -or $null -eq $endUtc -or $endUtc -le $startUtc) { return 0.0 }
    $tz       = [System.TimeZoneInfo]::FindSystemTimeZoneById("W. Europe Standard Time")
    $created  = [System.TimeZoneInfo]::ConvertTimeFromUtc($startUtc, $tz)
    $resp     = [System.TimeZoneInfo]::ConvertTimeFromUtc($endUtc,   $tz)
    $BIZ_START = 9.0   # 09:00
    $BIZ_END   = 17.5  # 17:30
    $total = 0.0
    $day = $created.Date
    while ($day -le $resp.Date) {
        $dow = $day.DayOfWeek
        if ($dow -ne 'Saturday' -and $dow -ne 'Sunday') {
            $fromH = if ($day -eq $created.Date) { [Math]::Max(($created - $created.Date).TotalHours, $BIZ_START) } else { $BIZ_START }
            $toH   = if ($day -eq $resp.Date)    { [Math]::Min(($resp    - $resp.Date).TotalHours,    $BIZ_END)   } else { $BIZ_END   }
            if ($toH -gt $fromH) { $total += $toH - $fromH }
        }
        $day = $day.AddDays(1)
    }
    return [Math]::Round($total, 2)
}

# ── Response times — business hours computed in SQL (09:00-17:30 NL, Mon-Fri) ──
$RESP_SQL = @"
WITH src AS (
  SELECT vr.WorkItemId,
    CAST(vr.CreatedUTC       AT TIME ZONE 'UTC' AT TIME ZONE 'W. Europe Standard Time' AS datetime) AS c_nl,
    CAST(vr.FirstResponseUTC AT TIME ZONE 'UTC' AT TIME ZONE 'W. Europe Standard Time' AS datetime) AS f_nl
  FROM   vwResponseTimePerTicketKoen vr
  JOIN   AzureDevops_Issue ai ON ai.IssueId = vr.WorkItemId
  WHERE  ai.IsInternal = 'False'
    AND  ai.IssueType  IN ('Ticket','TicketSimple')
    AND  ai.State      <> 'Cancelled'
    AND  vr.FirstResponseUTC IS NOT NULL
    AND  vr.CreatedUTC >= '2026-01-01'
    AND  NOT EXISTS (
           SELECT 1 FROM AzureDevops_Issue_Revision rev
           WHERE  rev.WorkItemId = vr.WorkItemId
             AND  rev.Field = 'Custom.Reopendate'
             AND  rev.Value IS NOT NULL AND rev.Value <> ''
         )
),
clamped AS (
  SELECT WorkItemId,
    CAST(c_nl AS date) AS c_date, CAST(f_nl AS date) AS f_date,
    CASE WHEN DATEPART(HOUR,c_nl)*60+DATEPART(MINUTE,c_nl) <  540 THEN  540
         WHEN DATEPART(HOUR,c_nl)*60+DATEPART(MINUTE,c_nl) > 1050 THEN 1050
         ELSE DATEPART(HOUR,c_nl)*60+DATEPART(MINUTE,c_nl) END AS c_min,
    CASE WHEN DATEPART(HOUR,f_nl)*60+DATEPART(MINUTE,f_nl) <  540 THEN  540
         WHEN DATEPART(HOUR,f_nl)*60+DATEPART(MINUTE,f_nl) > 1050 THEN 1050
         ELSE DATEPART(HOUR,f_nl)*60+DATEPART(MINUTE,f_nl) END AS f_min
  FROM src
)
SELECT WorkItemId,
  CAST(
    CASE WHEN c_date = f_date THEN
           CASE WHEN DATENAME(WEEKDAY,c_date) IN ('Saturday','Sunday') THEN 0 ELSE f_min - c_min END
         ELSE
           CASE WHEN DATENAME(WEEKDAY,c_date) NOT IN ('Saturday','Sunday') THEN 1050 - c_min ELSE 0 END
           + ISNULL((
               SELECT SUM(510)
               FROM (SELECT TOP 200 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.columns) nums
               WHERE DATEADD(DAY,nums.n,CAST(c_date AS datetime)) < CAST(f_date AS datetime)
                 AND DATENAME(WEEKDAY,DATEADD(DAY,nums.n,CAST(c_date AS datetime))) NOT IN ('Saturday','Sunday')
             ), 0)
           + CASE WHEN DATENAME(WEEKDAY,f_date) NOT IN ('Saturday','Sunday') THEN f_min - 540 ELSE 0 END
    END
  AS float) / 60.0 AS biz_h
FROM clamped
"@

# ── Closed ticket attribution + business-hours resp (SecondLayer for all 2026 closed) ──
$CLOSEDATTR_SQL = @"
WITH last_touch AS (
    SELECT r.WorkItemId,
           CASE LOWER(r.Value)
             WHEN 'a.nouraldeen@sana-commerce.com'  THEN 'Ahmed Nouraldeen'
             WHEN 's.elfaramawy@sana-commerce.com'  THEN 'Sarah Elfaramawy'
             WHEN 't.refaat@sana-commerce.com'      THEN 'Toqa Refaat'
             WHEN 'm.bayoumi@sana-commerce.com'     THEN 'Mohamed Bayoumi'
             WHEN 't.atef@sana-commerce.com'        THEN 'Tarek Atef'
             WHEN 'n.salgado@sana-commerce.com'     THEN 'Najabi Salgado Giraldo'
             WHEN 'a.hoyos@sana-commerce.com'       THEN 'Alexander Hoyos Gonzalez'
             WHEN 'm.martinez@sana-commerce.com'    THEN 'Maria Daniela Martinez'
             WHEN 'f.tovar@sana-commerce.com'       THEN 'Francisco Tovar'
             WHEN 'r.garcia@sana-commerce.com'      THEN 'Raffery Garcia'
             WHEN 'ri.khan@sana-commerce.com'       THEN 'Rifa Khan'
             WHEN 's.sreedharan@sana-commerce.com'  THEN 'Sruthi Sreedharan'
             WHEN 'm.johny@sana-commerce.com'       THEN 'Meha Johny'
             WHEN 'a.stephenson@sana-commerce.com'  THEN 'Alexis Stephenson'
             WHEN 'a.chakravarty@sana-commerce.com' THEN 'Archana Chakravarty'
             WHEN 'g.overheul@sana-commerce.com'    THEN 'Gert Overheul'
             WHEN 'j.huneburg@sana-commerce.com'    THEN 'Judith Hüneburg'
             WHEN 'a.ohinska@sana-commerce.com'     THEN 'Anna Ohinska'
             WHEN 'k.durisova@sana-commerce.com'    THEN 'Katie Durisova'
             ELSE r.Value
           END AS analyst,
           ROW_NUMBER() OVER (PARTITION BY r.WorkItemId ORDER BY r.Revision DESC) AS rn
    FROM   AzureDevops_Issue_Revision r
    WHERE  r.Field IN ('System.AssignedTo','System.ChangedBy')
      AND  LOWER(r.Value) IN (
               'a.nouraldeen@sana-commerce.com','a.hoyos@sana-commerce.com',
               'n.salgado@sana-commerce.com','m.bayoumi@sana-commerce.com',
               't.refaat@sana-commerce.com','s.elfaramawy@sana-commerce.com',
               's.sreedharan@sana-commerce.com','m.johny@sana-commerce.com',
               'a.stephenson@sana-commerce.com','a.chakravarty@sana-commerce.com',
               'g.overheul@sana-commerce.com','j.huneburg@sana-commerce.com',
               'a.ohinska@sana-commerce.com','k.durisova@sana-commerce.com',
               'ri.khan@sana-commerce.com','m.martinez@sana-commerce.com'
           )
      AND  r.WorkItemId IN (
               SELECT WorkitemId FROM Prisma_sana_live.dbo.AzureDevopsWorkitems
               WHERE  Type IN ('Ticket','TicketSimple')
                 AND  (ProjectReleaseVersion LIKE 'Support%' OR ProjectReleaseVersion = 'Partner Support')
                 AND  ProjectReleaseVersion NOT LIKE '%wishlist%'
                 AND  CreatedDateUTC >= '2026-01-01'
           )
),
resp_src AS (
    SELECT vr.WorkItemId,
        CAST(vr.CreatedUTC       AT TIME ZONE 'UTC' AT TIME ZONE 'W. Europe Standard Time' AS datetime) AS c_nl,
        CAST(vr.FirstResponseUTC AT TIME ZONE 'UTC' AT TIME ZONE 'W. Europe Standard Time' AS datetime) AS f_nl
    FROM vwResponseTimePerTicketKoen vr
    WHERE vr.FirstResponseUTC IS NOT NULL
),
resp_clamped AS (
    SELECT WorkItemId,
        CAST(c_nl AS date) AS c_date, CAST(f_nl AS date) AS f_date,
        CASE WHEN DATEPART(HOUR,c_nl)*60+DATEPART(MINUTE,c_nl) <  540 THEN  540
             WHEN DATEPART(HOUR,c_nl)*60+DATEPART(MINUTE,c_nl) > 1050 THEN 1050
             ELSE DATEPART(HOUR,c_nl)*60+DATEPART(MINUTE,c_nl) END AS c_min,
        CASE WHEN DATEPART(HOUR,f_nl)*60+DATEPART(MINUTE,f_nl) <  540 THEN  540
             WHEN DATEPART(HOUR,f_nl)*60+DATEPART(MINUTE,f_nl) > 1050 THEN 1050
             ELSE DATEPART(HOUR,f_nl)*60+DATEPART(MINUTE,f_nl) END AS f_min
    FROM resp_src
),
resp_biz AS (
    SELECT WorkItemId,
      CAST(
        CASE WHEN c_date = f_date THEN
               CASE WHEN DATENAME(WEEKDAY,c_date) IN ('Saturday','Sunday') THEN 0 ELSE f_min - c_min END
             ELSE
               CASE WHEN DATENAME(WEEKDAY,c_date) NOT IN ('Saturday','Sunday') THEN 1050 - c_min ELSE 0 END
               + ISNULL((
                   SELECT SUM(510)
                   FROM (SELECT TOP 200 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.columns) nums
                   WHERE DATEADD(DAY,nums.n,CAST(c_date AS datetime)) < CAST(f_date AS datetime)
                     AND DATENAME(WEEKDAY,DATEADD(DAY,nums.n,CAST(c_date AS datetime))) NOT IN ('Saturday','Sunday')
                 ), 0)
               + CASE WHEN DATENAME(WEEKDAY,f_date) NOT IN ('Saturday','Sunday') THEN f_min - 540 ELSE 0 END
        END
      AS float) / 60.0 AS biz_h
    FROM resp_clamped
)
SELECT lt.WorkItemId AS id, lt.analyst, rb.biz_h
FROM   last_touch lt
LEFT JOIN resp_biz rb ON rb.WorkItemId = lt.WorkItemId
WHERE  lt.rn = 1
ORDER  BY lt.WorkItemId DESC
"@

# ── Simple in-memory cache (30 min TTL) ───────────────────────────────────────
$_cache = @{}
$CACHE_TTL_SEC = 1800

# ── SecondLayer SQL — last-touch attribution per ticket ───────────────────────
# Runs on Prisma connection; cross-joins into Sana_Start_TicketIndex_live.
# For team-mailbox tickets: finds the last revision where one of our 16
# analysts appears in AssignedTo OR ChangedBy (whoever last worked it).
$SECONDLAYER_SQL = @"
WITH all_touches AS (
    SELECT r.WorkItemId, r.Value AS email,
           ISNULL(oe.DisplayName, r.Value) AS analyst,
           ROW_NUMBER() OVER (PARTITION BY r.WorkItemId ORDER BY r.Revision DESC) AS rn
    FROM Sana_Start_TicketIndex_live.dbo.AzureDevops_Issue_Revision r
    LEFT JOIN dbo.OrganizationEmployee oe
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
          SELECT WorkitemId FROM dbo.AzureDevopsWorkitems
          WHERE Type IN ('Ticket','TicketSimple')
            AND (ProjectReleaseVersion LIKE 'Support%' OR ProjectReleaseVersion = 'Partner Support')
            AND ProjectReleaseVersion NOT LIKE '%wishlist%'
            AND CreatedDateUTC >= '2026-01-01'
      )
)
SELECT WorkItemId, email, analyst
FROM all_touches
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
Write-Host "  Listening: http://localhost:$Port/" -ForegroundColor Green
Write-Host "  DB: $Server / Prisma_sana_live  |  Ctrl+C to stop" -ForegroundColor Gray
Write-Host "  Endpoints: /api/active  /api/secondlayer  /api/resp  /api/closedattr" -ForegroundColor Gray
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
                $actDt = New-Object System.Data.DataTable
                $actCs = "Server=$Server;Database=Prisma_sana_live;User ID=$DbUser;Password=$DbPass;TrustServerCertificate=True;Encrypt=False;Connect Timeout=15;"
                $actConn = New-Object System.Data.SqlClient.SqlConnection($actCs); $actConn.Open()
                $actCmd = $actConn.CreateCommand(); $actCmd.CommandText = $ACTIVE_SQL; $actCmd.CommandTimeout = 60
                $actDa = New-Object System.Data.SqlClient.SqlDataAdapter($actCmd)
                $actDa.Fill($actDt) | Out-Null
                $actConn.Close()
                $actParts = @()
                foreach ($row in $actDt.Rows) {
                    $actEmail   = (($row['assignedToEmail'] -as [string]).ToLower().Trim())
                    $actIsCust  = ($actEmail -eq 'customer@sana-commerce.com')
                    $actIsTeam  = ($NON_ANALYST_LOWER -contains $actEmail) -and (-not $actIsCust)
                    $actAnalyst = ($row['assignedName'] -as [string]).Trim()
                    if (-not $actAnalyst) { $actAnalyst = ($row['assignedTo'] -as [string]).Trim() }
                    if (-not $actAnalyst -or ($NON_ANALYST_LOWER -contains $actEmail)) { $actAnalyst = '' }
                    $actAge     = if ($row['age'] -eq [DBNull]::Value) { 0 } else { [int]($row['age']) }
                    $actClosedR = ($row['closed'] -as [string])
                    $actClosed  = if (-not $actClosedR -or $actClosedR -eq '') { 'null' } else { '"' + $actClosedR + '"' }
                    $actParts  += ('{' +
                        '"id":"'           + ($row['id']       -as [string])                    + '",' +
                        '"state":"'        + (Escape-Json ($row['state']   -as [string]))       + '",' +
                        '"title":"'        + (Escape-Json ($row['title']   -as [string]))       + '",' +
                        '"c":"'            + (Escape-Json $actAnalyst)                          + '",' +
                        '"email":"'        + (Escape-Json $actEmail)                            + '",' +
                        '"region":"'       + (Escape-Json ($row['region']  -as [string]))       + '",' +
                        '"created":"'      + ($row['created']  -as [string])                    + '",' +
                        '"closed":'        + $actClosed                                         + ',' +
                        '"age":'           + $actAge                                            + ',' +
                        '"pendingCustomer":'+ $actIsCust.ToString().ToLower()                   + ',' +
                        '"escalated":'     + $actIsTeam.ToString().ToLower()                    + ',' +
                        '"mainCat":"'      + (Escape-Json ($row['mainCat'] -as [string]))       + '",' +
                        '"subCat":"'       + (Escape-Json ($row['subCat']  -as [string]))       + '",' +
                        '"version":"'      + (Escape-Json ($row['version'] -as [string]))       + '",' +
                        '"customer":"'     + (Escape-Json ($row['customer']-as [string]))       + '"' +
                    '}')
                }
                $jsonRows = $actParts -join ','
                $body = '{"count":' + $actDt.Rows.Count + ',"source":"prisma_sql","rows":[' + $jsonRows + ']}'
                Write-Host "$ts GET /api/active → $($actDt.Rows.Count) tickets" -ForegroundColor Green
            }
            elseif ($path -eq "/api/secondlayer") {
                Write-Host "$ts GET /api/secondlayer — querying revision DB..." -ForegroundColor Yellow
                $slDt = New-Object System.Data.DataTable
                $slCs = "Server=$Server;Database=Prisma_sana_live;User ID=$DbUser;Password=$DbPass;TrustServerCertificate=True;Encrypt=False;Connect Timeout=15;"
                $slConn = New-Object System.Data.SqlClient.SqlConnection($slCs); $slConn.Open()
                $slCmd = $slConn.CreateCommand(); $slCmd.CommandText = $SECONDLAYER_SQL; $slCmd.CommandTimeout = 60
                $slDa = New-Object System.Data.SqlClient.SqlDataAdapter($slCmd)
                $slDa.Fill($slDt) | Out-Null
                $slConn.Close()
                $slParts = @()
                foreach ($slRow in $slDt.Rows) {
                    $slWi      = $slRow['WorkItemId']
                    $slAnalyst = Escape-Json ($slRow['analyst'] -as [string])
                    $slParts  += '{"wi":' + $slWi + ',"analyst":"' + $slAnalyst + '"}'
                }
                $jsonRows = $slParts -join ','
                $body = '{"count":' + $slDt.Rows.Count + ',"source":"sql_secondlayer","rows":[' + $jsonRows + ']}'
                Write-Host "$ts GET /api/secondlayer → $($slDt.Rows.Count) tickets" -ForegroundColor Green
            }
            elseif ($path -eq "/api/resp") {
                $cKey = "resp"
                $cached = $_cache[$cKey]
                if ($cached -and ((Get-Date) - $cached.ts).TotalSeconds -lt $CACHE_TTL_SEC) {
                    $body = $cached.body
                    Write-Host "$ts  /api/resp -> cached" -ForegroundColor Gray
                } else {
                    Write-Host "$ts  /api/resp - querying..." -ForegroundColor Yellow
                    $rConn = New-Object System.Data.SqlClient.SqlConnection("Server=$Server;Database=Sana_Start_TicketIndex_live;User ID=$DbUser;Password=$DbPass;TrustServerCertificate=True;Encrypt=False;Connect Timeout=15;")
                    $rConn.Open()
                    $rCmd = $rConn.CreateCommand(); $rCmd.CommandText = $RESP_SQL; $rCmd.CommandTimeout = 60
                    $rDa = New-Object System.Data.SqlClient.SqlDataAdapter($rCmd)
                    $rDt = New-Object System.Data.DataTable; $rDa.Fill($rDt) | Out-Null
                    $rConn.Close()
                    $rParts = @()
                    foreach ($row in $rDt.Rows) {
                        $wi = [string]$row['WorkItemId']
                        $bh = [double]$row['biz_h']
                        $rParts += '{"id":' + $wi + ',"resp":' + $bh + '}'
                    }
                    $body = '{"count":' + $rDt.Rows.Count + ',"source":"biz_hours","rows":[' + ($rParts -join ',') + ']}'
                    $_cache[$cKey] = @{ ts = Get-Date; body = $body }
                    Write-Host "$ts  /api/resp -> $($rDt.Rows.Count) response times" -ForegroundColor Green
                }
            }
            elseif ($path -eq "/api/closedattr") {
                $cKey = "closedattr"
                $cached = $_cache[$cKey]
                if ($cached -and ((Get-Date) - $cached.ts).TotalSeconds -lt $CACHE_TTL_SEC) {
                    $body = $cached.body
                    Write-Host "$ts  /api/closedattr -> cached" -ForegroundColor Gray
                } else {
                    Write-Host "$ts  /api/closedattr - querying..." -ForegroundColor Yellow
                    $caConn = New-Object System.Data.SqlClient.SqlConnection("Server=$Server;Database=Sana_Start_TicketIndex_live;User ID=$DbUser;Password=$DbPass;TrustServerCertificate=True;Encrypt=False;Connect Timeout=15;")
                    $caConn.Open()
                    $caCmd = $caConn.CreateCommand(); $caCmd.CommandText = $CLOSEDATTR_SQL; $caCmd.CommandTimeout = 90
                    $caDa = New-Object System.Data.SqlClient.SqlDataAdapter($caCmd)
                    $caDt = New-Object System.Data.DataTable; $caDa.Fill($caDt) | Out-Null
                    $caConn.Close()
                    $caParts = @()
                    $caAnalyst = 0; $caResp = 0
                    foreach ($row in $caDt.Rows) {
                        $wi       = [string]$row['id']
                        $analyst  = Escape-Json ([string]$row['analyst'])
                        $bhVal    = $row['biz_h']
                        $respJson = 'null'
                        if ($bhVal -ne [DBNull]::Value) {
                            $respJson = [string]([double]$bhVal)
                            $caResp++
                        }
                        if ($analyst) { $caAnalyst++ }
                        $caParts += '{"id":' + $wi + ',"analyst":"' + $analyst + '","resp":' + $respJson + '}'
                    }
                    $body = '{"count":' + $caDt.Rows.Count + ',"source":"closedattr","rows":[' + ($caParts -join ',') + ']}'
                    $_cache[$cKey] = @{ ts = Get-Date; body = $body }
                    Write-Host "$ts  /api/closedattr -> $($caDt.Rows.Count) attributions ($caAnalyst analyst, $caResp resp)" -ForegroundColor Green
                }
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
