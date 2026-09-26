# update-closed.ps1
# Two-source closed ticket sync:
#   1. ADO REST API  -- authoritative ticket list (IDs, dates, categories, account)
#   2. SQL TicketIndex -- analyst attribution frozen at moment of closure
#      (immune to post-closure account transfers)
# Merges both and embeds result as window._closedSqlData in index.html.
#
# Prerequisites:
#   SQL password -- managed by setup-credentials.ps1
#   ADO PAT      -- paste when prompted (same PAT used in the dashboard Sync tab)

param(
    [string]$YearStart    = "2026-01-01",
    [string]$DashboardDir = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

trap {
    Write-Host ""
    Write-Host "  UNHANDLED ERROR: $_" -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

$Server   = "10.171.0.9"
$AdoOrg   = "https://sanacommerce.visualstudio.com"
$AdoProj  = "Sana Projects"
$IndexHtml = Join-Path $DashboardDir "index.html"

# Load credentials
$_creds = Join-Path $DashboardDir ".credentials.ps1"
if (Test-Path $_creds) { . $_creds }

$UserId = if ($env:SQL_USER) { $env:SQL_USER } else { "t.atef" }

if (-not $env:SQL_PASS) {
    Write-Host "  SQL password not found in environment." -ForegroundColor Yellow
    $secPw    = Read-Host "  SQL password for $UserId" -AsSecureString
    $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPw))
    if (-not $Password) {
        Write-Host "  No password entered." -ForegroundColor Red
        Read-Host "Press Enter to close"; exit 1
    }
} else {
    $Password = $env:SQL_PASS
}

if (-not $env:ADO_PAT) {
    Write-Host ""
    Write-Host "  ADO PAT not found in environment." -ForegroundColor Yellow
    Write-Host "  Paste the PAT from the dashboard Sync tab (Work Items: Read scope)." -ForegroundColor Gray
    $AdoPat = Read-Host "  ADO PAT"
    if (-not $AdoPat) {
        Write-Host "  No PAT entered - cannot call ADO API." -ForegroundColor Red
        Read-Host "Press Enter to close"; exit 1
    }
} else {
    $AdoPat = $env:ADO_PAT
}
$AdoAuthB64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
$AdoHdrs   = @{ Authorization = "Basic $AdoAuthB64"; "Content-Type" = "application/json" }

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Closed Ticket Sync  (ADO + SQL)" -ForegroundColor Cyan
Write-Host "  Period : $YearStart onwards" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# STEP 1: ADO WIQL -- get IDs of 2026 closed support tickets
# ============================================================
Write-Host "  [1/4] Fetching closed ticket IDs from ADO WIQL..." -ForegroundColor Cyan

$wiqlBody = '{"query":"SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject]=''Sana Projects'' AND [System.State] IN (''Done'',''Live Accepted'',''Cancelled'') AND [System.CreatedDate] >= ''' + $YearStart + ''' AND [System.WorkItemType] = ''Ticket'' ORDER BY [System.ChangedDate] DESC"}'
$wiqlUrl   = "$AdoOrg/$([Uri]::EscapeDataString($AdoProj))/_apis/wit/wiql?api-version=7.1"

try {
    $wiqlResp = Invoke-RestMethod -Uri $wiqlUrl -Method POST -Headers $AdoHdrs -Body $wiqlBody
    $adoIds   = @($wiqlResp.workItems | ForEach-Object { [int]$_.id })
    Write-Host "  Found $($adoIds.Count) closed tickets in ADO." -ForegroundColor Green
} catch {
    Write-Host "  ERROR calling ADO WIQL: $_" -ForegroundColor Red
    Read-Host "Press Enter to close"; exit 1
}

if ($adoIds.Count -eq 0) {
    Write-Host "  No closed tickets found for $YearStart onwards." -ForegroundColor Yellow
    Read-Host "Press Enter to close"; exit 0
}

# ============================================================
# STEP 2: ADO batch field fetch (chunks of 200)
# ============================================================
Write-Host "  [2/4] Fetching ticket fields from ADO (batches of 200)..." -ForegroundColor Cyan

$adoFields = "System.Id,System.AssignedTo,System.AreaPath,System.CreatedDate,System.ChangedDate,Microsoft.VSTS.Common.ClosedDate,Custom.TicketMainCategory,Custom.TicketSubCategory"
$adoMap    = @{}   # wi -> hashtable

$batchSize = 200
$batchNum  = 0
for ($i = 0; $i -lt $adoIds.Count; $i += $batchSize) {
    $batchNum++
    $chunk    = $adoIds[$i..([Math]::Min($i + $batchSize - 1, $adoIds.Count - 1))]
    $batchUrl = "$AdoOrg/$([Uri]::EscapeDataString($AdoProj))/_apis/wit/workItems?ids=$($chunk -join ',')&fields=$adoFields&api-version=7.0"
    try {
        $resp = Invoke-RestMethod -Uri $batchUrl -Method GET -Headers $AdoHdrs
        foreach ($item in $resp.value) {
            $f  = $item.fields
            # AssignedTo comes back as an object {displayName, uniqueName} or a plain string
            $at = $f.'System.AssignedTo'
            $assignedTo = ""
            if ($at) {
                if ($at -is [string])           { $assignedTo = $at }
                elseif ($at.uniqueName)          { $assignedTo = $at.uniqueName }
                elseif ($at.displayName)         { $assignedTo = $at.displayName }
            }
            $createdRaw   = $f.'System.CreatedDate'
            $changedRaw   = $f.'System.ChangedDate'
            $completedRaw = $f.'Microsoft.VSTS.Common.ClosedDate'
            $adoMap[$item.id] = @{
                assignedTo  = $assignedTo
                areaPath    = [string]($f.'System.AreaPath')
                created     = if ($createdRaw)   { ([datetime]$createdRaw).ToString("yyyy-MM-dd")   } else { "" }
                changed     = if ($changedRaw)   { ([datetime]$changedRaw).ToString("yyyy-MM-dd")   } else { "" }
                completed   = if ($completedRaw) { ([datetime]$completedRaw).ToString("yyyy-MM-dd") } else { "" }
                mainCat     = if ($f.'Custom.TicketMainCategory') { [string]$f.'Custom.TicketMainCategory' } else { "" }
                subCat      = if ($f.'Custom.TicketSubCategory')  { [string]$f.'Custom.TicketSubCategory'  } else { "" }
            }
        }
        Write-Host "    Batch $batchNum : $($chunk.Count) tickets" -ForegroundColor Gray
    } catch {
        Write-Host "  WARNING - batch $batchNum failed: $_" -ForegroundColor Yellow
    }
}
Write-Host "  Fetched details for $($adoMap.Count) tickets." -ForegroundColor Green

# ============================================================
# STEP 2b: SQL -- per-ticket first response time (business hours)
# ============================================================
Write-Host "  [2b/4] Querying SQL for per-ticket FRT (business hours)..." -ForegroundColor Cyan

$RESP_SQL = Get-Content (Join-Path $DashboardDir "resp_query.sql") -Raw

$respMap = @{}
$cs2b = "Server=$Server;Database=Sana_Start_TicketIndex_live;User ID=$UserId;Password=$Password;TrustServerCertificate=True;Encrypt=False;Connect Timeout=30;"
$conn2b = New-Object System.Data.SqlClient.SqlConnection($cs2b)
try {
    $conn2b.Open()
    $cmd2b = $conn2b.CreateCommand()
    $cmd2b.CommandText = $RESP_SQL
    $cmd2b.CommandTimeout = 120
    $da2b  = New-Object System.Data.SqlClient.SqlDataAdapter($cmd2b)
    $dt2b  = New-Object System.Data.DataTable
    $da2b.Fill($dt2b) | Out-Null
    $conn2b.Close()
    foreach ($r in $dt2b.Rows) {
        $wi2b = [int]$r.Item("WorkItemId")
        $bh   = $r.Item("biz_h")
        if ($bh -isnot [System.DBNull] -and $bh -ne $null) {
            $respMap[$wi2b] = [Math]::Round([double]$bh, 2)
        }
    }
    Write-Host "  FRT loaded for $($respMap.Count) tickets." -ForegroundColor Green
} catch {
    $conn2b.Close()
    Write-Host "  WARNING: FRT query failed - resp will be null: $_" -ForegroundColor Yellow
}

# ============================================================
# STEP 3: SQL -- analyst attribution frozen at closure + solo flag + Prisma categories
# ============================================================
Write-Host "  [3/4] Querying SQL for analyst attribution (frozen at closure)..." -ForegroundColor Cyan

$ROSTER_LOWER = @(
    "'customer@sana-commerce.com'",
    "'a.nouraldeen@sana-commerce.com'", "'ahmed nouraldeen'",
    "'s.elfarmawy@sana-commerce.com'",  "'s.elfaramawy@sana-commerce.com'", "'sarah elfaramawy'", "'sarah el farmawy'",
    "'t.refaat@sana-commerce.com'",     "'toqa refaat'", "'toqa refaat abo-khatwa'",
    "'m.bayoumi@sana-commerce.com'",    "'mohamed bayoumi'",
    "'t.atef@sana-commerce.com'",       "'tarek atef'",
    "'n.salgado@sana-commerce.com'",    "'najabi salgado giraldo'", "'najabi salgado'",
    "'a.hoyos@sana-commerce.com'",      "'alexander hoyos gonzalez'", "'alexander hoyos'",
    "'m.martinez@sana-commerce.com'",   "'maria daniela martinez'",
    "'f.tovar@sana-commerce.com'",      "'francisco tovar'",
    "'r.garcia@sana-commerce.com'",     "'rafferty garcia'",
    "'ri.khan@sana-commerce.com'",      "'rifa khan'",
    "'a.stephenson@sana-commerce.com'", "'alexis stephenson'",
    "'a.chakravarty@sana-commerce.com'","'archana chakravarty'",
    "'a.ohinska@sana-commerce.com'",    "'anna ohinska'",
    "'s.sreedharan@sana-commerce.com'", "'sruthi sreedharan'",
    "'m.johny@sana-commerce.com'",      "'meha johny'",
    "'j.huneburg@sana-commerce.com'",   "'judith huneburg'", "'judith hüneburg'",
    "'k.durisova@sana-commerce.com'",   "'katie durisova'",
    "'g.overheul@sana-commerce.com'",   "'gert overheul'",
    "'h.savchuk@sana-commerce.com'",    "'halyna savchuk'", "'halian savchuk'"
) -join ","

# Full attribution query -- no year filter (ADO already filters to 2026)
# Prisma LEFT JOIN adds categories and account name where available
$ATTR_SQL = (Get-Content (Join-Path $DashboardDir "attr_query.sql") -Raw) -replace '--ROSTER--', $ROSTER_LOWER

$sqlMap = @{}   # wi -> {raw_analyst, solo, mainCat, subCat, acct}

$cs3 = "Server=$Server;Database=Sana_Start_TicketIndex_live;User ID=$UserId;Password=$Password;TrustServerCertificate=True;Encrypt=False;Connect Timeout=30;"
$conn3 = New-Object System.Data.SqlClient.SqlConnection($cs3)
try {
    $conn3.Open()
} catch {
    Write-Host "  ERROR: Cannot connect to SQL Server: $_" -ForegroundColor Red
    Read-Host "Press Enter to close"; exit 1
}
$cmd3 = $conn3.CreateCommand()
$cmd3.CommandText    = $ATTR_SQL
$cmd3.CommandTimeout = 300
$da3    = New-Object System.Data.SqlClient.SqlDataAdapter($cmd3)
$attrDt = New-Object System.Data.DataTable
try {
    $da3.Fill($attrDt) | Out-Null
} catch {
    $conn3.Close()
    Write-Host "  ERROR querying attribution: $_" -ForegroundColor Red
    Read-Host "Press Enter to close"; exit 1
}
$conn3.Close()

foreach ($r in $attrDt.Rows) {
    $wi = [int]$r.Item("WorkItemId")
    $sqlMap[$wi] = @{
        raw_analyst      = if ($r.Item("raw_analyst")       -is [System.DBNull]) { "" } else { [string]$r.Item("raw_analyst") }
        last_comment_by  = if ($r.Item("last_comment_by")   -is [System.DBNull]) { "" } else { [string]$r.Item("last_comment_by") }
        activated_by     = if ($r.Item("activated_by")      -is [System.DBNull]) { "" } else { [string]$r.Item("activated_by") }
        todo_mover       = if ($r.Item("todo_mover")        -is [System.DBNull]) { "" } else { [string]$r.Item("todo_mover") }
        solo             = [int]$r.Item("solo")
        mainCat          = if ($r.Item("prismaMainCat")     -is [System.DBNull]) { "" } else { [string]$r.Item("prismaMainCat") }
        subCat           = if ($r.Item("prismaSubCat")      -is [System.DBNull]) { "" } else { [string]$r.Item("prismaSubCat") }
        acct             = if ($r.Item("prismaAcct")        -is [System.DBNull]) { "" } else { [string]$r.Item("prismaAcct") }
        last_reopen      = if ($r.Item("last_reopen_date")  -is [System.DBNull]) { "" } else { [string]$r.Item("last_reopen_date") }
    }
}
Write-Host "  SQL returned $($attrDt.Rows.Count) attribution records." -ForegroundColor Green

# ============================================================
# Name map and helpers
# ============================================================
$NAME_MAP = @{
    'a.nouraldeen@sana-commerce.com'  = 'Ahmed Nouraldeen'
    'ahmed nouraldeen'                = 'Ahmed Nouraldeen'
    's.elfarmawy@sana-commerce.com'   = 'Sarah Elfaramawy'
    's.elfaramawy@sana-commerce.com'  = 'Sarah Elfaramawy'
    'sarah elfaramawy'                = 'Sarah Elfaramawy'
    't.refaat@sana-commerce.com'      = 'Toqa Refaat'
    'toqa refaat'                     = 'Toqa Refaat'
    'toqa refaat abo-khatwa'          = 'Toqa Refaat'
    'm.bayoumi@sana-commerce.com'     = 'Mohamed Bayoumi'
    'mohamed bayoumi'                 = 'Mohamed Bayoumi'
    't.atef@sana-commerce.com'        = 'Tarek Atef'
    'tarek atef'                      = 'Tarek Atef'
    'n.salgado@sana-commerce.com'     = 'Najabi Salgado Giraldo'
    'najabi salgado giraldo'          = 'Najabi Salgado Giraldo'
    'a.hoyos@sana-commerce.com'       = 'Alexander Hoyos Gonzalez'
    'alexander hoyos gonzalez'        = 'Alexander Hoyos Gonzalez'
    'm.martinez@sana-commerce.com'    = 'Maria Daniela Martinez'
    'maria daniela martinez'          = 'Maria Daniela Martinez'
    'f.tovar@sana-commerce.com'       = 'Francisco Tovar'
    'francisco tovar'                 = 'Francisco Tovar'
    'r.garcia@sana-commerce.com'      = 'Rafferty Garcia'
    'rafferty garcia'                 = 'Rafferty Garcia'
    'ri.khan@sana-commerce.com'       = 'Rifa Khan'
    'rifa khan'                       = 'Rifa Khan'
    'a.stephenson@sana-commerce.com'  = 'Alexis Stephenson'
    'alexis stephenson'               = 'Alexis Stephenson'
    'a.chakravarty@sana-commerce.com' = 'Archana Chakravarty'
    'archana chakravarty'             = 'Archana Chakravarty'
    'a.ohinska@sana-commerce.com'     = 'Anna Ohinska'
    'anna ohinska'                    = 'Anna Ohinska'
    's.sreedharan@sana-commerce.com'  = 'Sruthi Sreedharan'
    'sruthi sreedharan'               = 'Sruthi Sreedharan'
    'm.johny@sana-commerce.com'       = 'Meha Johny'
    'meha johny'                      = 'Meha Johny'
    'j.huneburg@sana-commerce.com'    = 'Judith Huneburg'
    'judith huneburg'                 = 'Judith Huneburg'
    'k.durisova@sana-commerce.com'    = 'Katie Durisova'
    'katie durisova'                  = 'Katie Durisova'
    'g.overheul@sana-commerce.com'    = 'Gert Overheul'
    'gert overheul'                   = 'Gert Overheul'
    'h.savchuk@sana-commerce.com'     = 'Halyna Savchuk'
    'halyna savchuk'                  = 'Halyna Savchuk'
    'halian savchuk'                  = 'Halyna Savchuk'
}

function Resolve-Analyst([string]$raw) {
    $key = $raw.Trim().ToLower()
    if ($NAME_MAP.ContainsKey($key)) { return $NAME_MAP[$key] }
    return $raw.Trim()
}

function Escape-Json([string]$s) {
    $s.Replace('\','\\').Replace('"','\"').Replace("`n",'\n').Replace("`r",'\r').Replace("`t",'\t')
}

# ============================================================
# STEP 4: Merge ADO data + SQL attribution
# ============================================================
Write-Host "  [4/4] Merging ADO tickets with SQL attribution..." -ForegroundColor Cyan

$rows      = [System.Collections.Generic.List[string]]::new()
$nameCount = @{}
$sqlHits   = 0
$adoFallback = 0

foreach ($wi in ($adoMap.Keys | Sort-Object -Descending)) {
    $t = $adoMap[$wi]

    # Analyst: SQL frozen-at-closure wins; fall back to ADO current AssignedTo
    $raw  = ""
    $solo = 0
    $mainCat = $t.mainCat
    $subCat  = $t.subCat
    $acct    = ""

    if ($sqlMap.ContainsKey($wi)) {
        $sql    = $sqlMap[$wi]
        $solo   = $sql.solo
        if ($sql.mainCat) { $mainCat = $sql.mainCat }
        if ($sql.subCat)  { $subCat  = $sql.subCat  }
        if ($sql.acct)    { $acct    = $sql.acct     }
        $sqlHits++

        # Priority 1: last commenter before Live Check/Done — roster only
        $lcb = $sql.last_comment_by
        if ($lcb -and $NAME_MAP.ContainsKey($lcb.Trim().ToLower())) {
            $raw = $lcb
        }
        # Priority 2: who moved the ticket into an active working state — roster only
        elseif ($sql.activated_by -and $NAME_MAP.ContainsKey($sql.activated_by.Trim().ToLower())) {
            $raw = $sql.activated_by
        }
        # Priority 3: analyst assigned at closure — roster only
        elseif ($sql.raw_analyst -and $NAME_MAP.ContainsKey($sql.raw_analyst.Trim().ToLower())) {
            $raw = $sql.raw_analyst
        }
        # non-roster at all three levels → $raw stays "" → try ADO fallback
    }
    # Priority 3: ADO current AssignedTo — roster only
    if (-not $raw) {
        $adoKey = $t.assignedTo.Trim().ToLower()
        if ($adoKey -and $NAME_MAP.ContainsKey($adoKey)) {
            $raw = $t.assignedTo
            $adoFallback++
        }
    }
    # Priority 4: who moved ticket out of Backlog To Do
    # → roster match: attribute to them; non-roster but known person: Team 4
    $analyst = Resolve-Analyst $raw
    if (-not $analyst -and $sqlMap.ContainsKey($wi)) {
        $mover = $sqlMap[$wi].todo_mover
        if ($mover) {
            $moverKey = $mover.Trim().ToLower()
            if ($NAME_MAP.ContainsKey($moverKey)) {
                $raw = $mover
                $analyst = Resolve-Analyst $raw
            } else {
                $analyst = "Team 4"
            }
        }
    }
    if (-not $analyst) { $analyst = "Unassigned" }

    # Account: Prisma name first, then last segment of ADO AreaPath
    if (-not $acct -and $t.areaPath) {
        $acct = ($t.areaPath -split "\\")[-1].Trim()
    }

    # TTR: match Power BI logic
    # closed = CompletedDate when available, fallback to ChangedDate
    # created = last reopen date from SQL revision history when ticket was reopened, else original CreatedDate
    $sqlReopen = if ($sqlMap.ContainsKey($wi)) { $sqlMap[$wi].last_reopen } else { "" }
    $created = if ($sqlReopen) { $sqlReopen } else { $t.created }
    $closed  = if ($t.completed) { $t.completed } else { $t.changed }
    $age     = 0
    if ($created -and $closed) {
        try { $age = ([datetime]$closed - [datetime]$created).Days } catch {}
        if ($age -lt 0) { $age = 0 }
    }

    $nameCount[$analyst] = ($nameCount[$analyst] -as [int]) + 1

    $rows.Add(('{' +
        '"wi":'       + $wi + ',' +
        '"id":"'      + $wi + '",' +
        '"c":"'       + (Escape-Json $analyst) + '",' +
        '"closed":"'  + (Escape-Json $closed)  + '",' +
        '"created":"' + (Escape-Json $created) + '",' +
        '"age":'      + $age + ',' +
        '"mainCat":"' + (Escape-Json $mainCat) + '",' +
        '"subCat":"'  + (Escape-Json $subCat)  + '",' +
        '"acct":"'    + (Escape-Json $acct)    + '",' +
        '"solo":'     + $solo + ',' +
        '"resp":' + $(if ($respMap.ContainsKey($wi)) { $respMap[$wi] } else { 'null' }) + ',' +
        '"teams":[]' +
        '}'))
}

Write-Host "  Attribution: $sqlHits via SQL (frozen), $adoFallback via ADO fallback." -ForegroundColor Gray
Write-Host ""
Write-Host ("  {0,-35} {1,7}" -f "Analyst", "Tickets") -ForegroundColor Cyan
Write-Host ("  " + ("-" * 45)) -ForegroundColor DarkGray
foreach ($name in ($nameCount.Keys | Sort-Object { -($nameCount[$_]) })) {
    $color = if ($name -eq "Unassigned" -or $name -like "*customer@*") { "Yellow" } else { "Green" }
    Write-Host ("  {0,-35} {1,7}" -f $name, $nameCount[$name]) -ForegroundColor $color
}
Write-Host ""
Write-Host "  Total: $($rows.Count) closed tickets" -ForegroundColor White

# ============================================================
# STEP 5: Embed in index.html
# ============================================================
Write-Host ""
Write-Host "  Embedding in index.html..." -ForegroundColor Cyan

if (-not (Test-Path $IndexHtml)) {
    Write-Host "  ERROR: index.html not found at $IndexHtml" -ForegroundColor Red
    Read-Host "Press Enter to close"; exit 1
}

$jsonArray = '[' + ($rows -join ',') + ']'
$bytes     = [System.Text.Encoding]::UTF8.GetBytes($jsonArray)
$b64       = [Convert]::ToBase64String($bytes)
$inject    = "window._adoClosedAutoData=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('$b64'),c=>c.charCodeAt(0))));"

$content  = [System.IO.File]::ReadAllText($IndexHtml, [System.Text.Encoding]::UTF8)
$pattern  = '(/\* ADO_CLOSED_AUTO_START \*/)[\s\S]*?(/\* ADO_CLOSED_AUTO_END \*/)'

if (-not [regex]::IsMatch($content, $pattern)) {
    Write-Host "  ERROR: ADO_CLOSED_AUTO_START marker not found in index.html." -ForegroundColor Red
    Read-Host "Press Enter to close"; exit 1
}

$replacement = '${1}' + $inject + '${2}'
$newContent  = [regex]::Replace($content, $pattern, $replacement)
[System.IO.File]::WriteAllText($IndexHtml, $newContent, [System.Text.Encoding]::UTF8)
Write-Host "  Embedded $($rows.Count) tickets in index.html." -ForegroundColor Green

# ============================================================
# STEP 6: Deploy to Azure
# ============================================================
Write-Host ""
Write-Host "  Deploying to Azure Static Website..." -ForegroundColor Cyan
$deployScript = Join-Path $DashboardDir "deploy_azure.ps1"
if (Test-Path $deployScript) {
    & powershell.exe -ExecutionPolicy Bypass -File $deployScript
} else {
    Write-Host "  WARNING: deploy_azure.ps1 not found - run push_azure.bat manually." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Done! Refresh the dashboard to see" -ForegroundColor Green
Write-Host "  updated closed ticket counts." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Read-Host "Press Enter to close"
