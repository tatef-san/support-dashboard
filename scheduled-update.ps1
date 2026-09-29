# scheduled-update.ps1
# Self-contained headless update script - runs on SQL server (10.171.0.9)
# Refreshes CSAT, closed tickets, and closedattr every run, then deploys to Azure.
# No interactive prompts. All credentials loaded from .credentials.ps1
#
# Folder layout on SQL server:
#   C:\DashboardUpdate\scheduled-update.ps1   <- this file
#   C:\DashboardUpdate\.credentials.ps1       <- credentials (never shared)
#   C:\DashboardUpdate\logs\                  <- auto-created, rotated weekly

param()

# Hardcoded install path - avoids $MyInvocation being null when run as SYSTEM via Task Scheduler
$WorkDir  = "C:\DashboardUpdate"
$LogDir   = Join-Path $WorkDir "logs"
$LogFile  = Join-Path $LogDir ("update-" + (Get-Date -Format "yyyy-MM-dd") + ".log")
$TempHtml = Join-Path $WorkDir "index.html"
$ClosedAttrFile = Join-Path $WorkDir "closedattr.json"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Log([string]$msg, [string]$color = "Gray") {
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "[$ts] $msg"
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Log-Section([string]$title) {
    Log ""
    Log ("=" * 50) "Cyan"
    Log "  $title" "Cyan"
    Log ("=" * 50) "Cyan"
}

# ── Prune logs older than 14 days ─────────────────────────────────────────────
Get-ChildItem $LogDir -Filter "update-*.log" |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
    Remove-Item -Force

Log ""
Log "Dashboard Auto-Update started" "White"
Log ("Run time: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))

# ── Load credentials ───────────────────────────────────────────────────────────
$credFile = Join-Path $WorkDir ".credentials.ps1"
if (-not (Test-Path $credFile)) {
    Log "ERROR: .credentials.ps1 not found at $credFile" "Red"
    exit 1
}
. $credFile

$SqlServer  = "10.171.0.9"
$SqlUser    = $env:SQL_USER
$SqlPass    = $env:SQL_PASS
$SpAppId    = "4e71ab59-a8a6-432a-851f-e2882ed143ea"
$TenantId   = "783727bb-afca-4f4e-925b-d2df74e54c12"
$StorageName = "stgperformacedashboard"
$SpSecret   = $env:AZ_SP_SECRET
$AdoPat     = $env:ADO_PAT
$AdoOrg     = "https://sanacommerce.visualstudio.com"
$AdoProj    = "Sana Projects"

foreach ($v in @("SQL_USER","SQL_PASS","AZ_SP_SECRET","ADO_PAT")) {
    if (-not (Get-Item "env:$v" -ErrorAction SilentlyContinue)) {
        Log "ERROR: $v not set in .credentials.ps1" "Red"; exit 1
    }
}

# ── Helpers ────────────────────────────────────────────────────────────────────
function Escape-Json([string]$s) {
    $s.Replace('\','\\').Replace('"','\"').Replace("`n",'\n').Replace("`r",'\r').Replace("`t",'\t')
}

function Open-Conn([string]$db) {
    $cs = "Server=$SqlServer;Database=$db;User ID=$SqlUser;Password=$SqlPass;TrustServerCertificate=True;Encrypt=False;Connect Timeout=30;"
    try {
        $c = New-Object System.Data.SqlClient.SqlConnection($cs)
        $c.Open()
        return $c
    } catch {
        # Throw a sanitized message - never expose the connection string
        throw "SQL connection to '$db' on $SqlServer failed: $($_.Exception.GetType().Name) - $($_.Exception.Message -replace [regex]::Escape($SqlPass),'***')"
    }
}

function Sanitize-Err([string]$msg) {
    if ($SqlPass)  { $msg = $msg -replace [regex]::Escape($SqlPass),  '***' }
    if ($SpSecret) { $msg = $msg -replace [regex]::Escape($SpSecret), '***' }
    if ($AdoPat)   {
        $msg = $msg -replace [regex]::Escape($AdoPat), '***'
        $adoB64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
        $msg = $msg -replace [regex]::Escape($adoB64), '***'
    }
    return $msg
}

# Force TLS 1.2 - required by Azure Storage (server may default to TLS 1.0/1.1)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── STEP 1: Download latest index.html from Azure ─────────────────────────────
Log-Section "STEP 1: Download latest index.html from Azure"
$azureUrl = "https://$StorageName.z6.web.core.windows.net/index.html"
try {
    Invoke-WebRequest -Uri $azureUrl -OutFile $TempHtml -UseBasicParsing -TimeoutSec 60
    Log "Downloaded index.html ($([Math]::Round((Get-Item $TempHtml).Length/1KB)) KB)" "Green"
} catch {
    Log "ERROR downloading index.html: $(Sanitize-Err "$_")" "Red"
    exit 1
}

# ── STEP 1b: Inject per-ticket analyst overrides ──────────────────────────────
# Bypasses the backlog-analyze attribution rule for specific ticket IDs.
# Idempotent: skipped if already present in downloaded file.
try {
    $ovContent = [System.IO.File]::ReadAllText($TempHtml, [System.Text.Encoding]::UTF8)
    if ($ovContent -notmatch '_TICKET_ANALYST_OVERRIDES') {
        $ovDefn = "  // Per-ticket analyst override: bypasses backlog-analyze attribution rule.`n" +
                  "  const _TICKET_ANALYST_OVERRIDES = {`n" +
                  "    '395664': 'Sarah Elfaramawy',`n" +
                  "    '399787': 'Sarah Elfaramawy',`n" +
                  "    '399904': 'Sarah Elfaramawy',`n" +
                  "    '401955': 'Sarah Elfaramawy',`n" +
                  "    '409656': 'Sarah Elfaramawy',`n" +
                  "    '410927': 'Sarah Elfaramawy',`n" +
                  "    '411017': 'Sarah Elfaramawy',`n" +
                  "    '401550': 'Ahmed Nouereldeen',`n" +
                  "    '410775': 'Anna Ohinska',`n" +
                  "    '420885': 'Anna Ohinska',`n" +
                  "    '405704': 'Rifa Khan',`n" +
                  "    '410168': 'Sarah Elfaramawy',`n" +
                  "    '414494': 'Sarah Elfaramawy',`n" +
                  "    '414798': 'Alexis Stephenson',`n" +
                  "    '383824': 'Najabi Salgado Giraldo',`n" +
                  "    '386926': 'Najabi Salgado Giraldo',`n" +
                  "    '389925': 'Najabi Salgado Giraldo',`n" +
                  "    '420111': 'Toqa Refaat',`n" +
                  "    '420139': 'Toqa Refaat',`n" +
                  "    '423382': 'Toqa Refaat',`n" +
                  "    '423545': 'Toqa Refaat',`n" +
                  "  };`n" +
                  "  const _ACCOUNT_ANALYST_OVERRIDES = {};`n`n"
        $ovContent = $ovContent -replace '(  const _ACCT_ALIASES = \{)', ($ovDefn + '  const _ACCT_ALIASES = {')

        $mapOld = "        var analystName = normalizeAnalystName(analystRaw);" + "`n" +
                  "        _nameCounts[analystName] = (_nameCounts[analystName] || 0) + 1;"
        $mapNew = "        var analystName = normalizeAnalystName(analystRaw);" + "`n" +
                  "        var _ticketId = String(f['System.Id'] || '');" + "`n" +
                  "        if (_TICKET_ANALYST_OVERRIDES[_ticketId]) { analystName = _TICKET_ANALYST_OVERRIDES[_ticketId]; }" + "`n" +
                  "        else { var _acctOv = _ACCOUNT_ANALYST_OVERRIDES[_segNormKey((f['System.AreaPath']||'').split('\\\\').pop()||'')]; if (_acctOv) analystName = _acctOv; }" + "`n" +
                  "        _nameCounts[analystName] = (_nameCounts[analystName] || 0) + 1;"
        $ovContent = $ovContent.Replace($mapOld, $mapNew)
        [System.IO.File]::WriteAllText($TempHtml, $ovContent, [System.Text.Encoding]::UTF8)
        Log "Analyst overrides injected for tickets 395664/399787/399904/401955/409656/410927/411017 -> Sarah Elfaramawy" "Green"
    } else {
        Log "Analyst overrides already present - skipped." "DarkGray"
    }
} catch {
    Log "WARNING: Could not inject analyst overrides: $(Sanitize-Err "$_")" "Yellow"
}

# ── STEP 2: CSAT update ────────────────────────────────────────────────────────
$NAME_MAP = @{
        'a.nouraldeen@sana-commerce.com'  = 'Ahmed Nouraldeen';  'ahmed nouraldeen'          = 'Ahmed Nouraldeen'
        's.elfarmawy@sana-commerce.com'   = 'Sarah Elfaramawy';  's.elfaramawy@sana-commerce.com' = 'Sarah Elfaramawy'; 'sarah elfaramawy' = 'Sarah Elfaramawy'
        't.refaat@sana-commerce.com'      = 'Toqa Refaat';       'toqa refaat'               = 'Toqa Refaat';       'toqa refaat abo-khatwa' = 'Toqa Refaat'
        'm.bayoumi@sana-commerce.com'     = 'Mohamed Bayoumi';   'mohamed bayoumi'           = 'Mohamed Bayoumi';   'mohamed ashraf bayoumy' = 'Mohamed Bayoumi'
        't.atef@sana-commerce.com'        = 'Tarek Atef';        'tarek atef'                = 'Tarek Atef'
        'n.salgado@sana-commerce.com'     = 'Najabi Salgado Giraldo'; 'najabi salgado giraldo' = 'Najabi Salgado Giraldo'
        'a.hoyos@sana-commerce.com'       = 'Alexander Hoyos Gonzalez'; 'alexander hoyos gonzalez' = 'Alexander Hoyos Gonzalez'
        'm.martinez@sana-commerce.com'    = 'Maria Daniela Martinez'; 'maria daniela martinez' = 'Maria Daniela Martinez'
        'f.tovar@sana-commerce.com'       = 'Francisco Tovar';   'francisco tovar'           = 'Francisco Tovar'
        'r.garcia@sana-commerce.com'      = 'Rafferty Garcia';   'rafferty garcia'           = 'Rafferty Garcia'
        'ri.khan@sana-commerce.com'       = 'Rifa Khan';         'rifa khan'                 = 'Rifa Khan'
        'a.stephenson@sana-commerce.com'  = 'Alexis Stephenson'; 'alexis stephenson'         = 'Alexis Stephenson'
        'a.chakravarty@sana-commerce.com' = 'Archana Chakravarty'; 'archana chakravarty'     = 'Archana Chakravarty'
        'a.ohinska@sana-commerce.com'     = 'Anna Ohinska';      'anna ohinska'              = 'Anna Ohinska'
        's.sreedharan@sana-commerce.com'  = 'Sruthi Sreedharan'; 'sruthi sreedharan'         = 'Sruthi Sreedharan'
        'm.johny@sana-commerce.com'       = 'Meha Johny';        'meha johny'                = 'Meha Johny'
        'j.huneburg@sana-commerce.com'    = 'Judith Huneburg';   'judith huneburg'           = 'Judith Huneburg'
        'k.durisova@sana-commerce.com'    = 'Katie Durisova';    'katie durisova'            = 'Katie Durisova'
        'g.overheul@sana-commerce.com'    = 'Gert Overheul';     'gert overheul'             = 'Gert Overheul'
        'h.savchuk@sana-commerce.com'     = 'Halyna Savchuk';    'halyna savchuk'            = 'Halyna Savchuk';   'halian savchuk' = 'Halyna Savchuk'
    }

Log-Section "STEP 2: CSAT update (Sphere_sana_Live)"
try {
    # Build WI -> last-commenter map from AzureDevops_Issue_Revision
    $csatAttrMap = @{}
    try {
        $connAttr = Open-Conn "Sana_Start_TicketIndex_live"
        $attrSql = "WITH live_check_threshold AS (SELECT WorkItemId, MIN(Revision) AS threshold_revision FROM AzureDevops_Issue_Revision WHERE Field='System.State' AND LOWER(Value) IN ('live check','done','cancelled') GROUP BY WorkItemId), comment_before_lc AS (SELECT r.WorkItemId, r.Revision, ROW_NUMBER() OVER (PARTITION BY r.WorkItemId ORDER BY r.Revision DESC) AS rn FROM AzureDevops_Issue_Revision r JOIN live_check_threshold lc ON lc.WorkItemId=r.WorkItemId WHERE r.Field='System.History' AND r.Revision < lc.threshold_revision), last_comment_rev AS (SELECT WorkItemId, Revision FROM comment_before_lc WHERE rn=1), last_commenter AS (SELECT lcr.WorkItemId, r.Value AS commenter_raw FROM last_comment_rev lcr JOIN AzureDevops_Issue_Revision r ON r.WorkItemId=lcr.WorkItemId AND r.Revision=lcr.Revision AND r.Field='System.ChangedBy') SELECT WorkItemId, commenter_raw FROM last_commenter"
        $attrCmd = $connAttr.CreateCommand(); $attrCmd.CommandText = $attrSql; $attrCmd.CommandTimeout = 300
        $attrDa  = New-Object System.Data.SqlClient.SqlDataAdapter($attrCmd)
        $attrDt  = New-Object System.Data.DataTable
        $attrDa.Fill($attrDt) | Out-Null
        $connAttr.Close()
        foreach ($arow in $attrDt.Rows) {
            $wiKey = [string][int]$arow["WorkItemId"]
            $commRaw = ([string]$arow["commenter_raw"]).Trim().ToLower()
            if ($wiKey -and $commRaw) { $csatAttrMap[$wiKey] = $commRaw }
        }
        Log "CSAT attribution map: $($csatAttrMap.Count) entries" "Green"
    } catch {
        Log "WARN: CSAT attribution query failed: $(Sanitize-Err "$_")" "Yellow"
    }

    $conn = Open-Conn "Sphere_sana_Live"

    $csatSql = "SELECT f.Rating, f.SupportExperience, ISNULL(e.DisplayName,'Unattributed') AS ServiceConsultant, f.WorkItemId, f.Comment, f.NegativeReason, f.Timestamp FROM [dbo].[Feedback] f LEFT JOIN [Prisma_sana_live].[dbo].[OrganizationEmployee] e ON LOWER(e.CompanyEmailAddress) = LOWER(LTRIM(RTRIM(f.[ ServiceConsultant]))) WHERE f.Timestamp >= '2025-01-01' ORDER BY f.Timestamp DESC"
    $csatCmd = $conn.CreateCommand(); $csatCmd.CommandText = $csatSql; $csatCmd.CommandTimeout = 60
    $csatDa  = New-Object System.Data.SqlClient.SqlDataAdapter($csatCmd)
    $csatDt  = New-Object System.Data.DataTable
    $csatDa.Fill($csatDt) | Out-Null
    Log "CSAT Feedback: $($csatDt.Rows.Count) rows" "Green"

    $ratingMap = @{ '2'='very satisfied'; '1'='satisfied'; '0'='neutral'; '-1'='unsatisfied'; '-2'='very unsatisfied' }
    $cetMap    = @{ '2'='Very Easy'; '1'='Easy'; '0'='Neither'; '-1'='Difficult'; '-2'='Very Difficult' }
    $csatRows  = [System.Collections.Generic.List[string]]::new()
    foreach ($row in $csatDt.Rows) {
        $ratingKey = [string][int]$row["Rating"]
        $rating    = $ratingMap[$ratingKey]
        if (-not $rating) { continue }
        $ts = $row["Timestamp"]
        $d  = if ($ts -is [DBNull]) { $null } else { ([datetime]$ts).ToString("yyyy-MM-dd") }
        if (-not $d) { continue }
        $analyst = ([string]$row["ServiceConsultant"]).Trim()
        if (-not $analyst) { $analyst = "Unattributed" }
        $cetRaw  = $row["SupportExperience"]
        $cetKey  = if ($cetRaw -is [DBNull]) { "" } else { [string][int]$cetRaw }
        $cet     = if ($cetMap.ContainsKey($cetKey)) { $cetMap[$cetKey] } else { "" }
        $wiRaw   = $row["WorkItemId"]
        $wi      = if ($wiRaw -is [DBNull]) { "null" } else { [string][int]$wiRaw }
        # Override analyst with last commenter before Live Check/Done if found on roster
        if ($wi -ne "null" -and $csatAttrMap.ContainsKey($wi)) {
            $commKey = $csatAttrMap[$wi]
            if ($NAME_MAP -and $NAME_MAP.ContainsKey($commKey)) { $analyst = $NAME_MAP[$commKey] }
        }
        $comment = if ($row["Comment"] -is [DBNull]) { "" } else { [string]$row["Comment"] }
        $reason  = if ($row["NegativeReason"] -is [DBNull]) { "" } else { [string]$row["NegativeReason"] }
        $csatRows.Add(('{' +
            '"d":"'       + $d + '",' +
            '"acct":"",' +
            '"wi":'       + $wi + ',' +
            '"c":"'       + (Escape-Json $analyst) + '",' +
            '"rating":"'  + $rating + '",' +
            '"reason":"'  + (Escape-Json $reason)  + '",' +
            '"comment":"' + (Escape-Json $comment) + '",' +
            '"mainCat":"","subCat":"",' +
            '"cet":"'     + (Escape-Json $cet)     + '",' +
            '"_src":"voiceflow"' +
            '}'))
    }

    $mayaSql = "SELECT ID, Rating, CustomerEmail, AgentVersion, ConversationSummary, ImprovementFeedback, Timestamp FROM [dbo].[VoiceflowRating] WHERE Timestamp >= '2025-01-01' ORDER BY Timestamp DESC"
    $mayaCmd = $conn.CreateCommand(); $mayaCmd.CommandText = $mayaSql; $mayaCmd.CommandTimeout = 60
    $mayaDa  = New-Object System.Data.SqlClient.SqlDataAdapter($mayaCmd)
    $mayaDt  = New-Object System.Data.DataTable
    $mayaDa.Fill($mayaDt) | Out-Null
    $conn.Close()
    Log "Maya CSAT: $($mayaDt.Rows.Count) rows" "Green"

    $mayaRows = [System.Collections.Generic.List[string]]::new()
    foreach ($mrow in $mayaDt.Rows) {
        $rv = if ($mrow["Rating"] -is [DBNull]) { 0 } else { [int]$mrow["Rating"] }
        if ($rv -lt 1 -or $rv -gt 5) { continue }
        $ts = $mrow["Timestamp"]
        $d  = if ($ts -is [DBNull]) { $null } else { ([datetime]$ts).ToString("yyyy-MM-dd") }
        if (-not $d) { continue }
        $mayaId  = if ($mrow["ID"] -is [DBNull]) { "0" } else { [string][int]$mrow["ID"] }
        $custRaw = if ($mrow["CustomerEmail"] -is [DBNull]) { "" } else { [string]$mrow["CustomerEmail"] }
        $sumRaw  = if ($mrow["ConversationSummary"] -is [DBNull]) { "" } else { [string]$mrow["ConversationSummary"] }
        $fbRaw   = if ($mrow["ImprovementFeedback"] -is [DBNull]) { "" } else { [string]$mrow["ImprovementFeedback"] }
        $verRaw  = if ($mrow["AgentVersion"] -is [DBNull]) { "" } else { [string]$mrow["AgentVersion"] }
        $mayaRows.Add(('{' +
            '"id":'       + $mayaId + ',' +
            '"d":"'       + $d + '",' +
            '"cust":"'    + (Escape-Json $custRaw) + '",' +
            '"rating":'   + $rv + ',' +
            '"summary":"' + (Escape-Json $sumRaw)  + '",' +
            '"fb":"'      + (Escape-Json $fbRaw)   + '",' +
            '"v":"'       + (Escape-Json $verRaw)  + '"' +
            '}'))
    }

    Log "CSAT: $($csatRows.Count) SA rows, $($mayaRows.Count) Maya rows" "Green"

    $csatJson  = '[' + ($csatRows -join ',') + ']'
    $csatB64   = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($csatJson))
    $inject1   = "window._vfCsatAutoData=JSON.parse(atob('$csatB64'));"
    $mayaJson  = '[' + ($mayaRows -join ',') + ']'
    $mayaB64   = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($mayaJson))
    $inject2   = "window._mayaCsatData=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('$mayaB64'),c=>c.charCodeAt(0))));"

    $content = [System.IO.File]::ReadAllText($TempHtml, [System.Text.Encoding]::UTF8)
    $content = [regex]::Replace($content, '(/\* VF_CSAT_AUTO_START \*/)[\s\S]*?(/\* VF_CSAT_AUTO_END \*/)',   '${1}' + $inject1 + '${2}')
    $content = [regex]::Replace($content, '(/\* MAYA_CSAT_AUTO_START \*/)[\s\S]*?(/\* MAYA_CSAT_AUTO_END \*/)', '${1}' + $inject2 + '${2}')
    [System.IO.File]::WriteAllText($TempHtml, $content, [System.Text.Encoding]::UTF8)
    Log "CSAT embedded in index.html" "Green"
} catch {
    Log "ERROR in CSAT step: $(Sanitize-Err "$_")" "Red"
}

# ── STEP 3: Closed tickets update (ADO + SQL) ─────────────────────────────────
Log-Section "STEP 3: Closed tickets (ADO + SQL)"
try {
    $AdoAuthB64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$AdoPat"))
    $AdoHdrs    = @{ Authorization = "Basic $AdoAuthB64"; "Content-Type" = "application/json" }

    Log "Fetching closed ticket IDs from ADO..." "Cyan"
    $wiqlBody = '{"query":"SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject]=''Sana Projects'' AND [System.State] IN (''Done'',''Live Accepted'',''Cancelled'') AND [System.CreatedDate] >= ''2025-01-01'' AND [System.WorkItemType] = ''Ticket'' ORDER BY [System.ChangedDate] DESC"}'
    $wiqlResp = Invoke-RestMethod -Uri "$AdoOrg/$([Uri]::EscapeDataString($AdoProj))/_apis/wit/wiql?api-version=7.1" -Method POST -Headers $AdoHdrs -Body $wiqlBody
    $adoIds   = @($wiqlResp.workItems | ForEach-Object { [int]$_.id })
    Log "ADO returned $($adoIds.Count) closed tickets" "Green"

    Log "Fetching ticket fields from ADO (batches of 200)..." "Cyan"
    $adoFields = "System.Id,System.AssignedTo,System.AreaPath,System.CreatedDate,System.ChangedDate,Microsoft.VSTS.Common.ClosedDate,Custom.TicketMainCategory,Custom.TicketSubCategory"
    $adoMap    = @{}
    for ($i = 0; $i -lt $adoIds.Count; $i += 200) {
        $chunk    = $adoIds[$i..([Math]::Min($i + 199, $adoIds.Count - 1))]
        $batchUrl = "$AdoOrg/$([Uri]::EscapeDataString($AdoProj))/_apis/wit/workItems?ids=$($chunk -join ',')&fields=$adoFields&api-version=7.0"
        try {
            $resp = Invoke-RestMethod -Uri $batchUrl -Method GET -Headers $AdoHdrs
            foreach ($item in $resp.value) {
                $f  = $item.fields
                $at = $f.'System.AssignedTo'
                $assignedTo = if ($at -is [string]) { $at } elseif ($at.uniqueName) { $at.uniqueName } elseif ($at.displayName) { $at.displayName } else { "" }
                $adoMap[$item.id] = @{
                    assignedTo = $assignedTo
                    areaPath   = [string]($f.'System.AreaPath')
                    created    = if ($f.'System.CreatedDate')               { ([datetime]$f.'System.CreatedDate').ToString("yyyy-MM-dd")               } else { "" }
                    changed    = if ($f.'System.ChangedDate')               { ([datetime]$f.'System.ChangedDate').ToString("yyyy-MM-dd")               } else { "" }
                    completed  = if ($f.'Microsoft.VSTS.Common.ClosedDate') { ([datetime]$f.'Microsoft.VSTS.Common.ClosedDate').ToString("yyyy-MM-dd") } else { "" }
                    mainCat    = if ($f.'Custom.TicketMainCategory') { [string]$f.'Custom.TicketMainCategory' } else { "" }
                    subCat     = if ($f.'Custom.TicketSubCategory')  { [string]$f.'Custom.TicketSubCategory'  } else { "" }
                }
            }
        } catch { Log "Batch starting $i failed: $(Sanitize-Err "$_")" "Yellow" }
    }
    Log "Fetched $($adoMap.Count) ticket details from ADO" "Green"

    Log "Querying SQL for attribution..." "Cyan"
    $ROSTER_LOWER = @(
        "'customer@sana-commerce.com'",
        "'a.nouraldeen@sana-commerce.com'","'ahmed nouraldeen'",
        "'s.elfarmawy@sana-commerce.com'","'s.elfaramawy@sana-commerce.com'","'sarah elfaramawy'",
        "'t.refaat@sana-commerce.com'","'toqa refaat'","'toqa refaat abo-khatwa'",
        "'m.bayoumi@sana-commerce.com'","'mohamed bayoumi'","'mohamed ashraf bayoumy'",
        "'t.atef@sana-commerce.com'","'tarek atef'",
        "'n.salgado@sana-commerce.com'","'najabi salgado giraldo'",
        "'a.hoyos@sana-commerce.com'","'alexander hoyos gonzalez'",
        "'m.martinez@sana-commerce.com'","'maria daniela martinez'",
        "'f.tovar@sana-commerce.com'","'francisco tovar'",
        "'r.garcia@sana-commerce.com'","'rafferty garcia'",
        "'ri.khan@sana-commerce.com'","'rifa khan'",
        "'a.stephenson@sana-commerce.com'","'alexis stephenson'",
        "'a.chakravarty@sana-commerce.com'","'archana chakravarty'",
        "'a.ohinska@sana-commerce.com'","'anna ohinska'",
        "'s.sreedharan@sana-commerce.com'","'sruthi sreedharan'",
        "'m.johny@sana-commerce.com'","'meha johny'",
        "'j.huneburg@sana-commerce.com'","'judith huneburg'",
        "'k.durisova@sana-commerce.com'","'katie durisova'",
        "'g.overheul@sana-commerce.com'","'gert overheul'",
        "'h.savchuk@sana-commerce.com'","'halyna savchuk'","'halian savchuk'"
    ) -join ","

    # Load full attribution SQL from attr_query.sql (next to this script, or in WorkDir)
    $attrSqlFile = Join-Path $PSScriptRoot "attr_query.sql"
    if (-not (Test-Path $attrSqlFile)) { $attrSqlFile = Join-Path $WorkDir "attr_query.sql" }
    $ATTR_SQL = (Get-Content $attrSqlFile -Raw) -replace '--ROSTER--', $ROSTER_LOWER

    $conn2  = Open-Conn "Sana_Start_TicketIndex_live"
    $cmd2   = $conn2.CreateCommand(); $cmd2.CommandText = $ATTR_SQL; $cmd2.CommandTimeout = 300
    $da2    = New-Object System.Data.SqlClient.SqlDataAdapter($cmd2)
    $attrDt = New-Object System.Data.DataTable
    $da2.Fill($attrDt) | Out-Null
    $conn2.Close()
    $sqlMap = @{}
    foreach ($r in $attrDt.Rows) {
        $wi = [int]$r.Item("WorkItemId")
        $sqlMap[$wi] = @{
            raw_analyst     = if ($r.Item("raw_analyst")      -is [System.DBNull]) { "" } else { [string]$r.Item("raw_analyst") }
            last_comment_by = if ($r.Item("last_comment_by")  -is [System.DBNull]) { "" } else { [string]$r.Item("last_comment_by") }
            activated_by    = if ($r.Item("activated_by")     -is [System.DBNull]) { "" } else { [string]$r.Item("activated_by") }
            todo_mover      = if ($r.Item("todo_mover")       -is [System.DBNull]) { "" } else { [string]$r.Item("todo_mover") }
            solo            = [int]$r.Item("solo")
            mainCat         = if ($r.Item("prismaMainCat")    -is [System.DBNull]) { "" } else { [string]$r.Item("prismaMainCat") }
            subCat          = if ($r.Item("prismaSubCat")     -is [System.DBNull]) { "" } else { [string]$r.Item("prismaSubCat") }
            acct            = if ($r.Item("prismaAcct")       -is [System.DBNull]) { "" } else { [string]$r.Item("prismaAcct") }
            last_reopen     = if ($r.Item("last_reopen_date") -is [System.DBNull]) { "" } else { [string]$r.Item("last_reopen_date") }
        }
    }
    Log "SQL returned $($attrDt.Rows.Count) attribution records" "Green"

    $NAME_MAP = @{
        'a.nouraldeen@sana-commerce.com'  = 'Ahmed Nouraldeen';  'ahmed nouraldeen'          = 'Ahmed Nouraldeen'
        's.elfarmawy@sana-commerce.com'   = 'Sarah Elfaramawy';  's.elfaramawy@sana-commerce.com' = 'Sarah Elfaramawy'; 'sarah elfaramawy' = 'Sarah Elfaramawy'
        't.refaat@sana-commerce.com'      = 'Toqa Refaat';       'toqa refaat'               = 'Toqa Refaat';       'toqa refaat abo-khatwa' = 'Toqa Refaat'
        'm.bayoumi@sana-commerce.com'     = 'Mohamed Bayoumi';   'mohamed bayoumi'           = 'Mohamed Bayoumi';   'mohamed ashraf bayoumy' = 'Mohamed Bayoumi'
        't.atef@sana-commerce.com'        = 'Tarek Atef';        'tarek atef'                = 'Tarek Atef'
        'n.salgado@sana-commerce.com'     = 'Najabi Salgado Giraldo'; 'najabi salgado giraldo' = 'Najabi Salgado Giraldo'
        'a.hoyos@sana-commerce.com'       = 'Alexander Hoyos Gonzalez'; 'alexander hoyos gonzalez' = 'Alexander Hoyos Gonzalez'
        'm.martinez@sana-commerce.com'    = 'Maria Daniela Martinez'; 'maria daniela martinez' = 'Maria Daniela Martinez'
        'f.tovar@sana-commerce.com'       = 'Francisco Tovar';   'francisco tovar'           = 'Francisco Tovar'
        'r.garcia@sana-commerce.com'      = 'Rafferty Garcia';   'rafferty garcia'           = 'Rafferty Garcia'
        'ri.khan@sana-commerce.com'       = 'Rifa Khan';         'rifa khan'                 = 'Rifa Khan'
        'a.stephenson@sana-commerce.com'  = 'Alexis Stephenson'; 'alexis stephenson'         = 'Alexis Stephenson'
        'a.chakravarty@sana-commerce.com' = 'Archana Chakravarty'; 'archana chakravarty'     = 'Archana Chakravarty'
        'a.ohinska@sana-commerce.com'     = 'Anna Ohinska';      'anna ohinska'              = 'Anna Ohinska'
        's.sreedharan@sana-commerce.com'  = 'Sruthi Sreedharan'; 'sruthi sreedharan'         = 'Sruthi Sreedharan'
        'm.johny@sana-commerce.com'       = 'Meha Johny';        'meha johny'                = 'Meha Johny'
        'j.huneburg@sana-commerce.com'    = 'Judith Huneburg';   'judith huneburg'           = 'Judith Huneburg'
        'k.durisova@sana-commerce.com'    = 'Katie Durisova';    'katie durisova'            = 'Katie Durisova'
        'g.overheul@sana-commerce.com'    = 'Gert Overheul';     'gert overheul'             = 'Gert Overheul'
        'h.savchuk@sana-commerce.com'     = 'Halyna Savchuk';    'halyna savchuk'            = 'Halyna Savchuk';   'halian savchuk' = 'Halyna Savchuk'
    }
    function Resolve-Analyst([string]$raw) {
        $key = $raw.Trim().ToLower()
        if ($NAME_MAP.ContainsKey($key)) { return $NAME_MAP[$key] }
        return $raw.Trim()
    }

    $closedRows = [System.Collections.Generic.List[string]]::new()
    foreach ($wi in ($adoMap.Keys | Sort-Object -Descending)) {
        $t       = $adoMap[$wi]
        $raw     = ""
        $solo    = 0
        $mainCat = $t.mainCat; $subCat = $t.subCat; $acct = ""

        if ($sqlMap.ContainsKey($wi)) {
            $sql = $sqlMap[$wi]
            $solo = $sql.solo
            if ($sql.mainCat) { $mainCat = $sql.mainCat }
            if ($sql.subCat)  { $subCat  = $sql.subCat  }
            if ($sql.acct)    { $acct    = $sql.acct     }

            # Priority 1: last commenter before Live Check/Done - roster only
            if ($sql.last_comment_by -and $NAME_MAP.ContainsKey($sql.last_comment_by.Trim().ToLower())) {
                $raw = $sql.last_comment_by
            }
            # Priority 2: who moved ticket into active working state - roster only
            elseif ($sql.activated_by -and $NAME_MAP.ContainsKey($sql.activated_by.Trim().ToLower())) {
                $raw = $sql.activated_by
            }
            # Priority 3: analyst assigned at closure - roster only
            elseif ($sql.raw_analyst -and $NAME_MAP.ContainsKey($sql.raw_analyst.Trim().ToLower())) {
                $raw = $sql.raw_analyst
            }
        }
        # Priority 3b: ADO current AssignedTo - roster only
        if (-not $raw) {
            $adoKey = $t.assignedTo.Trim().ToLower()
            if ($adoKey -and $NAME_MAP.ContainsKey($adoKey)) { $raw = $t.assignedTo }
        }
        # Priority 4: who moved ticket out of Backlog To Do - roster → attribute; non-roster → Team 4
        $analyst = Resolve-Analyst $raw
        if (-not $analyst -and $sqlMap.ContainsKey($wi)) {
            $mover = $sqlMap[$wi].todo_mover
            if ($mover) {
                $moverKey = $mover.Trim().ToLower()
                if ($NAME_MAP.ContainsKey($moverKey)) {
                    $analyst = Resolve-Analyst $mover
                } else {
                    $analyst = "Team 4"
                }
            }
        }
        if (-not $analyst) { $analyst = "Unassigned" }

        if (-not $acct -and $t.areaPath) { $acct = ($t.areaPath -split "\\")[-1].Trim() }

        # TTR: PowerBI-aligned - ClosedDate preferred over ChangedDate; last reopen overrides CreatedDate
        $sqlReopen = if ($sqlMap.ContainsKey($wi)) { $sqlMap[$wi].last_reopen } else { "" }
        $created = if ($sqlReopen) { $sqlReopen } else { $t.created }
        $closed  = if ($t.completed) { $t.completed } else { $t.changed }
        $age = 0
        if ($created -and $closed) { try { $age = ([datetime]$closed - [datetime]$created).Days } catch {} }
        if ($age -lt 0) { $age = 0 }

        $closedRows.Add(('{' +
            '"wi":'       + $wi + ',' +
            '"id":"'      + $wi + '",' +
            '"c":"'       + (Escape-Json $analyst)  + '",' +
            '"closed":"'  + (Escape-Json $closed)   + '",' +
            '"created":"' + (Escape-Json $created)  + '",' +
            '"age":'      + $age + ',' +
            '"mainCat":"' + (Escape-Json $mainCat)  + '",' +
            '"subCat":"'  + (Escape-Json $subCat)   + '",' +
            '"acct":"'    + (Escape-Json $acct)     + '",' +
            '"solo":'     + $solo + ',' +
            '"resp":null,"teams":[]' +
            '}'))
    }
    Log "Merged $($closedRows.Count) closed tickets" "Green"

    $closedJson = '[' + ($closedRows -join ',') + ']'
    $closedB64  = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($closedJson))
    $injectC    = "window._closedSqlData=JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('$closedB64'),c=>c.charCodeAt(0))));"
    $content    = [System.IO.File]::ReadAllText($TempHtml, [System.Text.Encoding]::UTF8)
    $content    = [regex]::Replace($content, '(/\* CLOSED_AUTO_START \*/)[\s\S]*?(/\* CLOSED_AUTO_END \*/)', '${1}' + $injectC + '${2}')
    [System.IO.File]::WriteAllText($TempHtml, $content, [System.Text.Encoding]::UTF8)
    Log "Closed tickets embedded in index.html" "Green"
} catch {
    Log "ERROR in closed tickets step: $(Sanitize-Err "$_")" "Red"
}

# ── STEP 4: Closedattr export ──────────────────────────────────────────────────
Log-Section "STEP 4: Closedattr (Live Check attribution)"
try {
    $CLOSEDATTR_SQL = "WITH state_changes AS (SELECT r.WorkItemId, MAX(r.Revision) AS close_revision FROM AzureDevops_Issue_Revision r WHERE r.Field='System.State' AND LOWER(r.Value) IN ('done','cancelled') AND r.WorkItemId IN (SELECT IssueId FROM AzureDevops_Issue WHERE IssueType IN ('Ticket','TicketSimple') AND IsInternal='False' AND (ProjectReleaseVersion LIKE 'Support%' OR ProjectReleaseVersion='Partner Support') AND ProjectReleaseVersion NOT LIKE '%wishlist%') GROUP BY r.WorkItemId), livecheck_revisions AS (SELECT r.WorkItemId, MAX(r.Revision) AS lc_revision FROM AzureDevops_Issue_Revision r JOIN state_changes sc ON sc.WorkItemId=r.WorkItemId WHERE r.Field='System.State' AND LOWER(r.Value)='live check' AND r.Revision<sc.close_revision GROUP BY r.WorkItemId), attribution_raw AS (SELECT sc.WorkItemId,(SELECT TOP 1 LOWER(RTRIM(r2.Value)) FROM AzureDevops_Issue_Revision r2 WHERE r2.WorkItemId=sc.WorkItemId AND r2.Field='System.ChangedBy' AND r2.Revision=lc.lc_revision) AS raw_value,(SELECT TOP 1 CONVERT(varchar,r3.ChangedDateUTC,23) FROM AzureDevops_Issue_Revision r3 WHERE r3.WorkItemId=sc.WorkItemId AND r3.Field='System.State' AND r3.Revision=sc.close_revision) AS close_date FROM state_changes sc JOIN livecheck_revisions lc ON lc.WorkItemId=sc.WorkItemId UNION ALL SELECT sc.WorkItemId,LOWER(RTRIM((SELECT TOP 1 r2.Value FROM AzureDevops_Issue_Revision r2 WHERE r2.WorkItemId=sc.WorkItemId AND r2.Field='System.AssignedTo' AND r2.Revision<=sc.close_revision ORDER BY r2.Revision DESC))) AS raw_value,(SELECT TOP 1 CONVERT(varchar,r3.ChangedDateUTC,23) FROM AzureDevops_Issue_Revision r3 WHERE r3.WorkItemId=sc.WorkItemId AND r3.Field='System.State' AND r3.Revision=sc.close_revision) AS close_date FROM state_changes sc WHERE NOT EXISTS (SELECT 1 FROM livecheck_revisions lc WHERE lc.WorkItemId=sc.WorkItemId)), last_touch AS (SELECT WorkItemId, close_date, CASE LOWER(RTRIM(raw_value)) WHEN 'a.nouraldeen@sana-commerce.com' THEN 'Ahmed Nouraldeen' WHEN 'ahmed nouraldeen' THEN 'Ahmed Nouraldeen' WHEN 's.elfaramawy@sana-commerce.com' THEN 'Sarah Elfaramawy' WHEN 'sarah elfaramawy' THEN 'Sarah Elfaramawy' WHEN 't.refaat@sana-commerce.com' THEN 'Toqa Refaat' WHEN 'toqa refaat' THEN 'Toqa Refaat' WHEN 'toqa refaat abo-khatwa' THEN 'Toqa Refaat' WHEN 'm.bayoumi@sana-commerce.com' THEN 'Mohamed Bayoumi' WHEN 'mohamed bayoumi' THEN 'Mohamed Bayoumi' WHEN 'mohamed ashraf bayoumy' THEN 'Mohamed Bayoumi' WHEN 't.atef@sana-commerce.com' THEN 'Tarek Atef' WHEN 'tarek atef' THEN 'Tarek Atef' WHEN 'n.salgado@sana-commerce.com' THEN 'Najabi Salgado Giraldo' WHEN 'najabi salgado giraldo' THEN 'Najabi Salgado Giraldo' WHEN 'a.hoyos@sana-commerce.com' THEN 'Alexander Hoyos Gonzalez' WHEN 'alexander hoyos gonzalez' THEN 'Alexander Hoyos Gonzalez' WHEN 'm.martinez@sana-commerce.com' THEN 'Maria Daniela Martinez' WHEN 'maria daniela martinez' THEN 'Maria Daniela Martinez' WHEN 'f.tovar@sana-commerce.com' THEN 'Francisco Tovar' WHEN 'francisco tovar' THEN 'Francisco Tovar' WHEN 'ri.khan@sana-commerce.com' THEN 'Rifa Khan' WHEN 'rifa khan' THEN 'Rifa Khan' WHEN 's.sreedharan@sana-commerce.com' THEN 'Sruthi Sreedharan' WHEN 'sruthi sreedharan' THEN 'Sruthi Sreedharan' WHEN 'm.johny@sana-commerce.com' THEN 'Meha Johny' WHEN 'meha johny' THEN 'Meha Johny' WHEN 'a.stephenson@sana-commerce.com' THEN 'Alexis Stephenson' WHEN 'alexis stephenson' THEN 'Alexis Stephenson' WHEN 'a.chakravarty@sana-commerce.com' THEN 'Archana Chakravarty' WHEN 'archana chakravarty' THEN 'Archana Chakravarty' WHEN 'g.overheul@sana-commerce.com' THEN 'Gert Overheul' WHEN 'gert overheul' THEN 'Gert Overheul' WHEN 'j.huneburg@sana-commerce.com' THEN 'Judith Huneburg' WHEN 'judith huneburg' THEN 'Judith Huneburg' WHEN 'a.ohinska@sana-commerce.com' THEN 'Anna Ohinska' WHEN 'anna ohinska' THEN 'Anna Ohinska' WHEN 'k.durisova@sana-commerce.com' THEN 'Katie Durisova' WHEN 'katie durisova' THEN 'Katie Durisova' ELSE NULL END AS analyst, ROW_NUMBER() OVER (PARTITION BY WorkItemId ORDER BY WorkItemId) AS rn FROM attribution_raw WHERE raw_value IS NOT NULL) SELECT lt.WorkItemId AS id, lt.analyst, lt.close_date FROM last_touch lt WHERE lt.rn=1 AND lt.analyst IS NOT NULL ORDER BY lt.WorkItemId DESC"

    $conn3   = Open-Conn "Sana_Start_TicketIndex_live"
    $cmd3    = $conn3.CreateCommand(); $cmd3.CommandText = $CLOSEDATTR_SQL; $cmd3.CommandTimeout = 300
    $reader3 = $cmd3.ExecuteReader()
    $caRows  = [System.Collections.Generic.List[string]]::new()
    while ($reader3.Read()) {
        $id       = [string]$reader3["id"]
        $analyst  = [string]$reader3["analyst"]
        $closeDate = if ($reader3["close_date"] -is [System.DBNull]) { "null" } else { '"' + [string]$reader3["close_date"] + '"' }
        $caRows.Add(('{' +
            '"id":'         + $id + ',' +
            '"analyst":"'   + (Escape-Json $analyst) + '",' +
            '"close_date":' + $closeDate +
            '}'))
    }
    $reader3.Close(); $conn3.Close()
    Log "Closedattr: $($caRows.Count) attributions" "Green"

    $caJson = '{"count":' + $caRows.Count + ',"rows":[' + ($caRows -join ',') + ']}'
    [System.IO.File]::WriteAllText($ClosedAttrFile, $caJson, [System.Text.Encoding]::UTF8)
    Log "Saved closedattr.json ($([Math]::Round((Get-Item $ClosedAttrFile).Length/1KB)) KB)" "Green"
} catch {
    Log "ERROR in closedattr step: $(Sanitize-Err "$_")" "Red"
}

# ── STEP 5: Active tickets export ────────────────────────────────────────────
Log-Section "STEP 5: Active tickets (Prisma_sana_live)"
$ActiveFile = Join-Path $WorkDir "active.json"
try {
    $ACTIVE_SQL = "SELECT w.WorkitemId AS id, w.State AS state, ISNULL(w.Title,'') AS title, ISNULL(w.AssignedTo,'') AS assignedTo, ISNULL(w.AssignedToEmail,'') AS assignedToEmail, ISNULL(eA.DisplayName,'') AS assignedName, ISNULL(org.Name,'') AS region, CONVERT(varchar,ISNULL(w.ReopenDate,w.CreatedDateUTC),23) AS created, CONVERT(varchar,w.CloseDate,23) AS closed, ISNULL(w.TicketMainCategory,'') AS mainCat, ISNULL(w.TicketSubCategory,'') AS subCat, ISNULL(w.ProjectReleaseVersion,'') AS version, ISNULL(ii.CustomerName,'') AS customer, DATEDIFF(day,ISNULL(w.ReopenDate,w.CreatedDateUTC),ISNULL(w.CloseDate,GETUTCDATE())) AS age FROM AzureDevopsWorkitems w LEFT JOIN OrganizationEmployee eA ON LOWER(eA.CompanyEmailAddress)=LOWER(w.AssignedToEmail) LEFT JOIN OrganizationRegion org ON org.ID=eA.RegionId LEFT JOIN IterationInfo ii ON ii.IterationID=w.ProjectIterationId WHERE w.Type IN ('Ticket','TicketSimple') AND (w.ProjectReleaseVersion LIKE 'Support%' OR w.ProjectReleaseVersion='Partner Support') AND w.ProjectReleaseVersion NOT LIKE '%wishlist%' AND w.CreatedDateUTC>='2025-01-01' AND LOWER(w.State) NOT IN ('done','live accepted','cancelled') ORDER BY w.CreatedDateUTC DESC"
    # Mover query: who first moved each active ticket from Backlog To Do into an analyze/active state
    $MOVER_SQL = "WITH activator AS (SELECT WorkItemId, MIN(Revision) AS activate_rev FROM Sana_Start_TicketIndex_live.dbo.AzureDevops_Issue_Revision WHERE Field='System.State' AND LOWER(Value) IN ('analyze','backlog analyze','backlog to analyze','in progress','active','analyzing','in analyze','sprint in progress','sprint analyze') AND WorkItemId IN (SELECT WorkitemId FROM AzureDevopsWorkitems WHERE Type IN ('Ticket','TicketSimple') AND (ProjectReleaseVersion LIKE 'Support%' OR ProjectReleaseVersion='Partner Support') AND ProjectReleaseVersion NOT LIKE '%wishlist%' AND CreatedDateUTC>='2025-01-01' AND LOWER(State) NOT IN ('done','live accepted','cancelled')) GROUP BY WorkItemId) SELECT a.WorkItemId, (SELECT TOP 1 RTRIM(r2.Value) FROM Sana_Start_TicketIndex_live.dbo.AzureDevops_Issue_Revision r2 WHERE r2.WorkItemId=a.WorkItemId AND r2.Field='System.ChangedBy' AND r2.Revision=a.activate_rev) AS activated_by FROM activator a"
    $NON_ANALYST = @('customer@sana-commerce.com','core_support@sana-commerce.com','sci@sana-commerce.com','hosting@sana-commerce.com','add-on_support@sana-commerce.com','ax_fo_support@ism-egroup.com','sapecc_support@ism-egroup.com','support-planning@sana-commerce.com')
    $connA = Open-Conn "Prisma_sana_live"

    # Build mover map: WorkItemId → activated_by (roster name)
    $moverMap = @{}
    $cmdMover = $connA.CreateCommand(); $cmdMover.CommandText = $MOVER_SQL; $cmdMover.CommandTimeout = 120
    $daMover = New-Object System.Data.SqlClient.SqlDataAdapter($cmdMover)
    $dtMover = New-Object System.Data.DataTable
    $daMover.Fill($dtMover) | Out-Null
    foreach ($mr in $dtMover.Rows) {
        $mWi  = [string]$mr.Item("WorkItemId")
        $mVal = if ($mr.Item("activated_by") -is [System.DBNull]) { "" } else { [string]$mr.Item("activated_by") }
        if ($mVal) { $moverMap[$mWi] = $mVal }
    }
    Log "Active mover map: $($moverMap.Count) entries" "Cyan"

    $cmdA  = $connA.CreateCommand(); $cmdA.CommandText = $ACTIVE_SQL; $cmdA.CommandTimeout = 120
    $daA   = New-Object System.Data.SqlClient.SqlDataAdapter($cmdA)
    $dtA   = New-Object System.Data.DataTable
    $daA.Fill($dtA) | Out-Null
    $connA.Close()
    $actRows = [System.Collections.Generic.List[string]]::new()
    foreach ($row in $dtA.Rows) {
        $wi      = [string]$row.Item("id")
        $emailRaw = ""; if (-not ($row.Item("assignedToEmail") -is [System.DBNull])) { $emailRaw = [string]$row.Item("assignedToEmail") }
        $email = $emailRaw.ToLower().Trim()
        $isCust  = ($email -eq 'customer@sana-commerce.com')
        $isTeam  = ($NON_ANALYST -contains $email) -and (-not $isCust)
        $assignedName = ""; if (-not ($row.Item("assignedName") -is [System.DBNull])) { $assignedName = [string]$row.Item("assignedName") }
        $assignedTo   = ""; if (-not ($row.Item("assignedTo")   -is [System.DBNull])) { $assignedTo   = [string]$row.Item("assignedTo") }
        $analyst = $assignedName.Trim()
        if (-not $analyst) { $analyst = $assignedTo.Trim() }
        # If assignee is not on roster, try mover attribution (who moved from Backlog To Do → Analyze)
        $analystKey = $analyst.Trim().ToLower()
        if (-not $analyst -or ($NON_ANALYST -contains $email) -or (-not $NAME_MAP.ContainsKey($analystKey))) {
            if ($moverMap.ContainsKey($wi)) {
                $moverRaw = $moverMap[$wi]
                $moverKey = $moverRaw.Trim().ToLower()
                if ($NAME_MAP.ContainsKey($moverKey)) {
                    $analyst = $NAME_MAP[$moverKey]
                } else {
                    $analyst = ""
                }
            } else {
                $analyst = ""
            }
        } else {
            $analyst = $NAME_MAP[$analystKey]
        }
        $ageVal  = $row.Item("age")
        $age = 0; if (-not ($ageVal -is [System.DBNull])) { $age = [int]$ageVal }
        $closedRaw = ""; if (-not ($row.Item("closed") -is [System.DBNull])) { $closedRaw = [string]$row.Item("closed") }
        $closedJ = 'null'; if ($closedRaw -and $closedRaw -ne '') { $closedJ = '"' + $closedRaw + '"' }
        $stateVal   = ""; if (-not ($row.Item("state")    -is [System.DBNull])) { $stateVal   = [string]$row.Item("state") }
        $titleVal   = ""; if (-not ($row.Item("title")    -is [System.DBNull])) { $titleVal   = [string]$row.Item("title") }
        $regionVal  = ""; if (-not ($row.Item("region")   -is [System.DBNull])) { $regionVal  = [string]$row.Item("region") }
        $createdVal = ""; if (-not ($row.Item("created")  -is [System.DBNull])) { $createdVal = [string]$row.Item("created") }
        $mainCatVal = ""; if (-not ($row.Item("mainCat")  -is [System.DBNull])) { $mainCatVal = [string]$row.Item("mainCat") }
        $subCatVal  = ""; if (-not ($row.Item("subCat")   -is [System.DBNull])) { $subCatVal  = [string]$row.Item("subCat") }
        $versionVal = ""; if (-not ($row.Item("version")  -is [System.DBNull])) { $versionVal = [string]$row.Item("version") }
        $customerVal= ""; if (-not ($row.Item("customer") -is [System.DBNull])) { $customerVal= [string]$row.Item("customer") }
        $actRows.Add(('{' +
            '"id":"'            + $wi                          + '",' +
            '"state":"'         + (Escape-Json $stateVal)      + '",' +
            '"title":"'         + (Escape-Json $titleVal)      + '",' +
            '"c":"'             + (Escape-Json $analyst)       + '",' +
            '"email":"'         + (Escape-Json $email)         + '",' +
            '"region":"'        + (Escape-Json $regionVal)     + '",' +
            '"created":"'       + $createdVal                  + '",' +
            '"closed":'         + $closedJ                     + ',' +
            '"age":'            + $age                         + ',' +
            '"pendingCustomer":' + $isCust.ToString().ToLower()+ ',' +
            '"escalated":'      + $isTeam.ToString().ToLower() + ',' +
            '"mainCat":"'       + (Escape-Json $mainCatVal)    + '",' +
            '"subCat":"'        + (Escape-Json $subCatVal)     + '",' +
            '"version":"'       + (Escape-Json $versionVal)    + '",' +
            '"customer":"'      + (Escape-Json $customerVal)   + '"' +
            '}'))
    }
    $actJson = '{"count":' + $actRows.Count + ',"source":"prisma_sql","rows":[' + ($actRows -join ',') + ']}'
    [System.IO.File]::WriteAllText($ActiveFile, $actJson, [System.Text.Encoding]::UTF8)
    Log "Active tickets: $($actRows.Count) rows → active.json ($([Math]::Round((Get-Item $ActiveFile).Length/1KB)) KB)" "Green"
} catch {
    Log "ERROR in active tickets step: $(Sanitize-Err "$_")" "Red"
}

# ── STEP 6: SecondLayer export ────────────────────────────────────────────────
Log-Section "STEP 6: SecondLayer attribution (Sana_Start_TicketIndex_live)"
$SecondLayerFile = Join-Path $WorkDir "secondlayer.json"
try {
    $SL_SQL = "WITH all_touches AS (SELECT r.WorkItemId, r.Value AS email, ROW_NUMBER() OVER (PARTITION BY r.WorkItemId ORDER BY r.Revision ASC) AS rn FROM Sana_Start_TicketIndex_live.dbo.AzureDevops_Issue_Revision r WHERE r.Field='System.AssignedTo' AND LOWER(RTRIM(r.Value)) IN ('a.nouraldeen@sana-commerce.com','ahmed nouraldeen','a.hoyos@sana-commerce.com','alexander hoyos gonzalez','n.salgado@sana-commerce.com','najabi salgado giraldo','m.bayoumi@sana-commerce.com','mohamed bayoumi','t.refaat@sana-commerce.com','toqa refaat','toqa refaat abo-khatwa','s.elfaramawy@sana-commerce.com','sarah elfaramawy','s.sreedharan@sana-commerce.com','sruthi sreedharan','m.johny@sana-commerce.com','meha johny','a.stephenson@sana-commerce.com','alexis stephenson','a.chakravarty@sana-commerce.com','archana chakravarty','g.overheul@sana-commerce.com','gert overheul','j.huneburg@sana-commerce.com','judith huneburg','a.ohinska@sana-commerce.com','anna ohinska','k.durisova@sana-commerce.com','katie durisova','ri.khan@sana-commerce.com','rifa khan','m.martinez@sana-commerce.com','maria daniela martinez','t.atef@sana-commerce.com','tarek atef','f.tovar@sana-commerce.com','francisco tovar','r.garcia@sana-commerce.com','raffery garcia') AND r.WorkItemId IN (SELECT WorkitemId FROM dbo.AzureDevopsWorkitems WHERE Type IN ('Ticket','TicketSimple') AND (ProjectReleaseVersion LIKE 'Support%' OR ProjectReleaseVersion='Partner Support') AND ProjectReleaseVersion NOT LIKE '%wishlist%' AND CreatedDateUTC>='2025-01-01')) SELECT WorkItemId, email AS analyst FROM all_touches WHERE rn=1 ORDER BY WorkItemId DESC"
    $connSL = Open-Conn "Prisma_sana_live"
    $cmdSL  = $connSL.CreateCommand(); $cmdSL.CommandText = $SL_SQL; $cmdSL.CommandTimeout = 120
    $rdrSL  = $cmdSL.ExecuteReader()
    $slRows = [System.Collections.Generic.List[string]]::new()
    while ($rdrSL.Read()) {
        $slRows.Add(('{' +
            '"wi":'       + [string]$rdrSL["WorkItemId"] + ',' +
            '"analyst":"' + (Escape-Json [string]$rdrSL["analyst"]) + '"' +
            '}'))
    }
    $rdrSL.Close(); $connSL.Close()
    $slJson = '{"count":' + $slRows.Count + ',"source":"sql_secondlayer","rows":[' + ($slRows -join ',') + ']}'
    [System.IO.File]::WriteAllText($SecondLayerFile, $slJson, [System.Text.Encoding]::UTF8)
    Log "SecondLayer: $($slRows.Count) rows → secondlayer.json ($([Math]::Round((Get-Item $SecondLayerFile).Length/1KB)) KB)" "Green"
} catch {
    Log "ERROR in secondlayer step: $(Sanitize-Err "$_")" "Red"
}

# ── STEP 7: Response times export ────────────────────────────────────────────
Log-Section "STEP 7: Response times (vwResponseTimePerTicketKoen)"
$RespFile = Join-Path $WorkDir "resp.json"
try {
    $RESP_SQL = "WITH src AS (SELECT vr.WorkItemId, CAST(vr.CreatedUTC AT TIME ZONE 'UTC' AT TIME ZONE 'W. Europe Standard Time' AS datetime) AS c_nl, CAST(vr.FirstResponseUTC AT TIME ZONE 'UTC' AT TIME ZONE 'W. Europe Standard Time' AS datetime) AS f_nl FROM vwResponseTimePerTicketKoen vr JOIN AzureDevops_Issue ai ON ai.IssueId=vr.WorkItemId WHERE ai.IsInternal='False' AND ai.IssueType IN ('Ticket','TicketSimple') AND ai.State<>'Cancelled' AND vr.FirstResponseUTC IS NOT NULL AND vr.CreatedUTC>='2025-01-01' AND vr.WorkItemId IN (SELECT WorkitemId FROM Prisma_sana_live.dbo.AzureDevopsWorkitems WHERE (ProjectReleaseVersion LIKE 'Support%' OR ProjectReleaseVersion='Partner Support') AND ProjectReleaseVersion NOT LIKE '%wishlist%') AND NOT EXISTS (SELECT 1 FROM AzureDevops_Issue_Revision rev WHERE rev.WorkItemId=vr.WorkItemId AND rev.Field='Custom.Reopendate' AND rev.Value IS NOT NULL AND rev.Value<>'')), clamped AS (SELECT WorkItemId, CAST(c_nl AS date) AS c_date, CAST(f_nl AS date) AS f_date, CASE WHEN DATEPART(HOUR,c_nl)*60+DATEPART(MINUTE,c_nl)<540 THEN 540 WHEN DATEPART(HOUR,c_nl)*60+DATEPART(MINUTE,c_nl)>1050 THEN 1050 ELSE DATEPART(HOUR,c_nl)*60+DATEPART(MINUTE,c_nl) END AS c_min, CASE WHEN DATEPART(HOUR,f_nl)*60+DATEPART(MINUTE,f_nl)<540 THEN 540 WHEN DATEPART(HOUR,f_nl)*60+DATEPART(MINUTE,f_nl)>1050 THEN 1050 ELSE DATEPART(HOUR,f_nl)*60+DATEPART(MINUTE,f_nl) END AS f_min FROM src) SELECT WorkItemId, CAST(CASE WHEN c_date=f_date THEN CASE WHEN DATENAME(WEEKDAY,c_date) IN ('Saturday','Sunday') THEN 0 ELSE f_min-c_min END ELSE CASE WHEN DATENAME(WEEKDAY,c_date) NOT IN ('Saturday','Sunday') THEN 1050-c_min ELSE 0 END+ISNULL((SELECT SUM(510) FROM (SELECT TOP 200 ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.columns) nums WHERE DATEADD(DAY,nums.n,CAST(c_date AS datetime))<CAST(f_date AS datetime) AND DATENAME(WEEKDAY,DATEADD(DAY,nums.n,CAST(c_date AS datetime))) NOT IN ('Saturday','Sunday')),0)+CASE WHEN DATENAME(WEEKDAY,f_date) NOT IN ('Saturday','Sunday') THEN f_min-540 ELSE 0 END END AS float)/60.0 AS biz_h FROM clamped"
    $connR = Open-Conn "Sana_Start_TicketIndex_live"
    $cmdR  = $connR.CreateCommand(); $cmdR.CommandText = $RESP_SQL; $cmdR.CommandTimeout = 180
    $rdrR  = $cmdR.ExecuteReader()
    $respRows = [System.Collections.Generic.List[string]]::new()
    while ($rdrR.Read()) {
        $bh = if ($rdrR["biz_h"] -is [System.DBNull]) { 0 } else { [Math]::Round([double]$rdrR["biz_h"], 2) }
        $respRows.Add(('{' +
            '"id":' + [string]$rdrR["WorkItemId"] + ',' +
            '"resp":' + $bh +
            '}'))
    }
    $rdrR.Close(); $connR.Close()
    $respJson = '{"count":' + $respRows.Count + ',"source":"biz_hours","rows":[' + ($respRows -join ',') + ']}'
    [System.IO.File]::WriteAllText($RespFile, $respJson, [System.Text.Encoding]::UTF8)
    Log "Response times: $($respRows.Count) rows → resp.json ($([Math]::Round((Get-Item $RespFile).Length/1KB)) KB)" "Green"
} catch {
    Log "ERROR in response times step: $(Sanitize-Err "$_")" "Red"
}

# ── STEP 8: Partner comments export ──────────────────────────────────────────
Log-Section "STEP 8: Partner comments (sphere_sana_live)"
$PartnerCommentsFile = Join-Path $WorkDir "partnercomments.json"
try {
    $PC_SQL = "SELECT WorkItemId AS id, RevisedByEmail AS email FROM (SELECT WorkItemId, RevisedByEmail, ROW_NUMBER() OVER (PARTITION BY WorkItemId ORDER BY DateCreated DESC) AS rn FROM AzureDevopsWorkItemComment WHERE RevisedByEmail LIKE '%@sana-commerce.com%' AND RevisedByEmail NOT IN ('partner@sana-commerce.com','customer@sana-commerce.com','migrations@sana-commerce.com')) ranked WHERE rn=1"
    $connPC = Open-Conn "sphere_sana_live"
    $cmdPC  = $connPC.CreateCommand(); $cmdPC.CommandText = $PC_SQL; $cmdPC.CommandTimeout = 120
    $rdrPC  = $cmdPC.ExecuteReader()
    $pcRows = [System.Collections.Generic.List[string]]::new()
    while ($rdrPC.Read()) {
        $pcEmail = ([string]$rdrPC["email"]).ToLower().Trim()
        $pcRows.Add(('{' +
            '"id":"'    + [string]$rdrPC["id"] + '",' +
            '"email":"' + (Escape-Json $pcEmail) + '"' +
            '}'))
    }
    $rdrPC.Close(); $connPC.Close()
    $pcJson = '{"rows":[' + ($pcRows -join ',') + ']}'
    [System.IO.File]::WriteAllText($PartnerCommentsFile, $pcJson, [System.Text.Encoding]::UTF8)
    Log "Partner comments: $($pcRows.Count) rows → partnercomments.json ($([Math]::Round((Get-Item $PartnerCommentsFile).Length/1KB)) KB)" "Green"
} catch {
    Log "ERROR in partner comments step: $(Sanitize-Err "$_")" "Red"
}

# ── STEP 9: Deploy to Azure (pure REST API - no Az module needed) ─────────────
Log-Section "STEP 9: Deploy to Azure Blob"
try {
    # Get OAuth token using Service Principal
    $tokenBody = "client_id=$SpAppId&client_secret=$([Uri]::EscapeDataString($SpSecret))&scope=https://storage.azure.com/.default&grant_type=client_credentials"
    try {
        $tokenResp = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method POST -Body $tokenBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
    } catch {
        # Never log the token body - it contains the SP secret
        Log "ERROR getting Azure token: check AZ_SP_SECRET in .credentials.ps1 ($($_.Exception.GetType().Name))" "Red"
        throw
    }
    $token = $tokenResp.access_token
    Log "Azure token acquired" "Green"

    function Upload-Blob([string]$localPath, [string]$blobName, [string]$contentType) {
        $bytes = [System.IO.File]::ReadAllBytes($localPath)
        $uri   = "https://$StorageName.blob.core.windows.net/`$web/$blobName"
        $hdrs  = @{
            Authorization              = "Bearer $token"
            "x-ms-blob-type"           = "BlockBlob"
            "x-ms-version"             = "2020-04-08"
            "Content-Type"             = $contentType
            "x-ms-blob-cache-control"  = "no-cache, no-store, must-revalidate"
        }
        Invoke-RestMethod -Uri $uri -Method PUT -Headers $hdrs -Body $bytes -ErrorAction Stop | Out-Null
        Log "Uploaded $blobName ($([Math]::Round($bytes.Length/1KB)) KB)" "Green"
    }

    Upload-Blob $TempHtml        "index.html"           "text/html; charset=utf-8"
    Upload-Blob $ClosedAttrFile  "closedattr.json"      "application/json; charset=utf-8"
    if (Test-Path $ActiveFile)          { Upload-Blob $ActiveFile          "active.json"          "application/json; charset=utf-8" }
    if (Test-Path $SecondLayerFile)     { Upload-Blob $SecondLayerFile     "secondlayer.json"     "application/json; charset=utf-8" }
    if (Test-Path $RespFile)            { Upload-Blob $RespFile            "resp.json"            "application/json; charset=utf-8" }
    if (Test-Path $PartnerCommentsFile) { Upload-Blob $PartnerCommentsFile "partnercomments.json" "application/json; charset=utf-8" }

    Log "Azure deployment complete" "Green"
} catch {
    Log "ERROR in Azure deploy step: $(Sanitize-Err "$_")" "Red"
}

Log ""
Log "Update complete: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "White"
Log ("Log: $LogFile")
