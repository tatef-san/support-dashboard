WITH state_changes AS (
    SELECT r.WorkItemId, MAX(r.Revision) AS close_revision
    FROM   AzureDevops_Issue_Revision r
    WHERE  r.Field = 'System.State'
      AND  LOWER(r.Value) IN ('done','live accepted','cancelled')
      AND  r.WorkItemId IN (
               SELECT IssueId FROM AzureDevops_Issue
               WHERE  IssueType IN ('Ticket','TicketSimple')
                 AND  IsInternal = 'False'
                 AND  (ProjectReleaseVersion LIKE 'Support%' OR ProjectReleaseVersion = 'Partner Support')
                 AND  ProjectReleaseVersion NOT LIKE '%wishlist%'
           )
    GROUP BY r.WorkItemId
),
reopen_dates AS (
    SELECT r.WorkItemId,
           MAX(TRY_CAST(r.Value AS date)) AS last_reopen_date
    FROM   AzureDevops_Issue_Revision r
    WHERE  r.Field = 'Custom.Reopendate'
      AND  r.Value IS NOT NULL AND r.Value <> ''
      AND  r.WorkItemId IN (SELECT WorkItemId FROM state_changes)
    GROUP BY r.WorkItemId
),
-- Revision where ticket first entered Live Check, Done, Live Accepted, or Cancelled
-- (the moment the SA declared the ticket done on their side)
live_check_revs AS (
    SELECT WorkItemId, MIN(Revision) AS target_rev
    FROM   AzureDevops_Issue_Revision
    WHERE  Field = 'System.State'
      AND  LOWER(Value) IN ('live check','done','live accepted','cancelled')
      AND  WorkItemId IN (SELECT WorkItemId FROM state_changes)
    GROUP BY WorkItemId
),
-- Last comment revision before Live Check / Done
last_comment_rev AS (
    SELECT lc.WorkItemId,
           MAX(r.Revision) AS last_history_rev
    FROM   live_check_revs lc
    JOIN   AzureDevops_Issue_Revision r
           ON r.WorkItemId = lc.WorkItemId
          AND r.Field      = 'System.History'
          AND r.Revision   < lc.target_rev
    GROUP BY lc.WorkItemId
),
-- Who made that last comment revision
last_commenter AS (
    SELECT lcr.WorkItemId,
           (SELECT TOP 1 RTRIM(r2.Value)
            FROM   AzureDevops_Issue_Revision r2
            WHERE  r2.WorkItemId = lcr.WorkItemId
              AND  r2.Field      = 'System.ChangedBy'
              AND  r2.Revision   = lcr.last_history_rev
           ) AS last_comment_by
    FROM   last_comment_rev lcr
),
-- First revision where ticket entered an active SA working state
-- (SA picks up the ticket and moves it out of To Do / Backlog)
state_activator AS (
    SELECT WorkItemId, MIN(Revision) AS activate_rev
    FROM   AzureDevops_Issue_Revision
    WHERE  Field = 'System.State'
      AND  LOWER(Value) IN (
               'analyze','backlog analyze','in progress','active',
               'analyzing','in analyze','backlog to analyze'
           )
      AND  WorkItemId IN (SELECT WorkItemId FROM state_changes)
    GROUP BY WorkItemId
),
activator_person AS (
    SELECT sa.WorkItemId,
           (SELECT TOP 1 RTRIM(r2.Value)
            FROM   AzureDevops_Issue_Revision r2
            WHERE  r2.WorkItemId = sa.WorkItemId
              AND  r2.Field      = 'System.ChangedBy'
              AND  r2.Revision   = sa.activate_rev
           ) AS activated_by
    FROM   state_activator sa
),
analyst_at_close AS (
    SELECT sc.WorkItemId,
           (SELECT TOP 1 RTRIM(r2.Value)
            FROM   AzureDevops_Issue_Revision r2
            WHERE  r2.WorkItemId = sc.WorkItemId
              AND  r2.Field      = 'System.AssignedTo'
              AND  r2.Revision  <= sc.close_revision
            ORDER BY r2.Revision DESC) AS raw_analyst
    FROM   state_changes sc
),
-- First revision where state changed FROM 'Backlog To Do' to anything
backlog_todo_mover AS (
    SELECT r.WorkItemId, MIN(r.Revision) AS move_rev
    FROM   AzureDevops_Issue_Revision r
    WHERE  r.Field = 'System.State'
      AND  r.WorkItemId IN (SELECT WorkItemId FROM state_changes)
      AND  EXISTS (
               SELECT 1 FROM AzureDevops_Issue_Revision prev
               WHERE  prev.WorkItemId = r.WorkItemId
                 AND  prev.Field      = 'System.State'
                 AND  LOWER(prev.Value) = 'backlog to do'
                 AND  prev.Revision = (
                          SELECT MAX(r2.Revision)
                          FROM   AzureDevops_Issue_Revision r2
                          WHERE  r2.WorkItemId = r.WorkItemId
                            AND  r2.Field      = 'System.State'
                            AND  r2.Revision   < r.Revision
                      )
           )
    GROUP BY r.WorkItemId
),
backlog_todo_person AS (
    SELECT bm.WorkItemId,
           (SELECT TOP 1 RTRIM(r2.Value)
            FROM   AzureDevops_Issue_Revision r2
            WHERE  r2.WorkItemId = bm.WorkItemId
              AND  r2.Field      = 'System.ChangedBy'
              AND  r2.Revision   = bm.move_rev) AS todo_mover
    FROM   backlog_todo_mover bm
),
non_roster_touches AS (
    SELECT DISTINCT r.WorkItemId
    FROM   AzureDevops_Issue_Revision r
    WHERE  r.Field = 'System.AssignedTo'
      AND  r.WorkItemId IN (SELECT WorkItemId FROM state_changes)
      AND  r.Value IS NOT NULL AND r.Value <> ''
      AND  LOWER(RTRIM(r.Value)) NOT IN (--ROSTER--)
)
SELECT
    ac.WorkItemId,
    ac.raw_analyst,
    lcm.last_comment_by,
    ap.activated_by,
    btp.todo_mover,
    CASE WHEN nr.WorkItemId IS NULL THEN 1 ELSE 0 END AS solo,
    ISNULL(p.TicketMainCategory, '') AS prismaMainCat,
    ISNULL(p.TicketSubCategory,  '') AS prismaSubCat,
    ISNULL(ii.CustomerName,      '') AS prismaAcct,
    CONVERT(varchar(10), rd.last_reopen_date, 120)  AS last_reopen_date
FROM   analyst_at_close ac
LEFT JOIN last_commenter     lcm ON lcm.WorkItemId = ac.WorkItemId
LEFT JOIN activator_person   ap  ON ap.WorkItemId  = ac.WorkItemId
LEFT JOIN backlog_todo_person btp ON btp.WorkItemId = ac.WorkItemId
LEFT JOIN non_roster_touches nr  ON nr.WorkItemId  = ac.WorkItemId
LEFT JOIN reopen_dates       rd  ON rd.WorkItemId  = ac.WorkItemId
LEFT JOIN Prisma_sana_live.dbo.AzureDevopsWorkitems p
       ON p.WorkitemId = ac.WorkItemId
LEFT JOIN Prisma_sana_live.dbo.IterationInfo ii
       ON ii.IterationID = p.ProjectIterationId
