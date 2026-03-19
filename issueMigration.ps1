# -------- CONFIG --------
$Config = [ordered]@{
    GitLabUrl                    = 'https://gitlab.com'
    GitLabProjectId              = '79462265'
    GitLabToken                  = $env:GITLAB_TOKEN

    AdoOrg                       = '12104042'
    AdoProject                   = 'test'
    AdoPat                       = $env:ADO_PAT

    GitLabState                  = 'all'      # opened, closed, all
    PerPage                      = 100
    GitLabCommentsPerPage        = 100
    IncludeInternalGitLabComments= $false
    TrySetClosedReasonCompleted  = $true
    MigrateIssueLinks            = $true

    AdoApiVersion                = '7.1'
    AdoCommentsApiVersion        = '7.1-preview.4'
    TempRoot                     = (Join-Path $env:TEMP 'gitlab-ado-migration')
}
# -------- SETUP --------
New-Item -ItemType Directory -Force -Path $Config.TempRoot | Out-Null
$script:ProcessedGitLabLinkIds = @{}

$GitLabHeaders = @{ 'PRIVATE-TOKEN' = $Config.GitLabToken }
$AdoAuthBase64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($Config.AdoPat)"))
$AdoPatchHeaders = @{
    Authorization = "Basic $AdoAuthBase64"
    'Content-Type' = 'application/json-patch+json'
    Accept = 'application/json'
}
$AdoJsonHeaders = @{
    Authorization = "Basic $AdoAuthBase64"
    'Content-Type' = 'application/json'
    Accept = 'application/json'
}

# -------- HELPERS --------
function Convert-ToJsonPatchDocument {
    param([array]$Operations)
    '[' + (($Operations | ForEach-Object { $_ | ConvertTo-Json -Depth 30 -Compress }) -join ',') + ']'
}

function Invoke-Api {
    param(
        [ValidateSet('Get','Post','Patch')][string]$Method,
        [string]$Uri,
        [hashtable]$Headers,
        $Body = $null,
        [string]$ErrorContext = 'API call',
        [switch]$ReturnNullOnError
    )

    try {
        $params = @{ Method = $Method; Uri = $Uri; Headers = $Headers; ErrorAction = 'Stop' }
        if ($null -ne $Body) { $params.Body = $Body }
        Invoke-RestMethod @params
    }
    catch {
        Write-Warning "$ErrorContext mislukt"
        Write-Warning $_.Exception.Message
        if ($_.ErrorDetails?.Message) { Write-Warning $_.ErrorDetails.Message }
        if ($ReturnNullOnError) { return $null }
        throw
    }
}

function Invoke-Download {
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [string]$OutFile,
        [string]$ErrorContext = 'Download'
    )

    try {
        Invoke-WebRequest -Method Get -Uri $Uri -Headers $Headers -OutFile $OutFile -ErrorAction Stop | Out-Null
        $OutFile
    }
    catch {
        Write-Warning "$ErrorContext mislukt"
        Write-Warning $_.Exception.Message
        if ($_.ErrorDetails?.Message) { Write-Warning $_.ErrorDetails.Message }
        throw
    }
}

function Get-GitLabPaged {
    param(
        [string]$Path,
        [int]$PerPage = 100
    )

    $items = @()
    $page = 1

    do {
        $sep = if ($Path -match '\?') { '&' } else { '?' }
        $uri = "{0}/api/v4/projects/{1}/{2}{3}per_page={4}&page={5}" -f $Config.GitLabUrl, $Config.GitLabProjectId, $Path, $sep, $PerPage, $page
        Write-Host "GitLab ophalen: $Path (pagina $page)"
        $data = Invoke-Api -Method Get -Uri $uri -Headers $GitLabHeaders -ErrorContext "GitLab ophalen [$Path]" -ReturnNullOnError
        if (-not $data -or $data.Count -eq 0) { break }
        $items += $data
        $page++
    } while ($true)

    $items
}

function Get-GitLabIssueComments {
    param([int]$IssueIid)

    $notes = Get-GitLabPaged -Path ("issues/{0}/notes?activity_filter=only_comments&sort=asc&order_by=created_at" -f $IssueIid) -PerPage $Config.GitLabCommentsPerPage
    if ($Config.IncludeInternalGitLabComments) { return $notes }

    @($notes | Where-Object {
        -not (($_.PSObject.Properties.Name -contains 'internal' -and $_.internal -eq $true) -or
              ($_.PSObject.Properties.Name -contains 'confidential' -and $_.confidential -eq $true))
    })
}

function Get-GitLabIssueLinks {
    param([int]$IssueIid)
    $uri = "{0}/api/v4/projects/{1}/issues/{2}/links" -f $Config.GitLabUrl, $Config.GitLabProjectId, $IssueIid
    Invoke-Api -Method Get -Uri $uri -Headers $GitLabHeaders -ErrorContext "GitLab links ophalen voor issue #$IssueIid" -ReturnNullOnError
}

function Get-AdoWorkItemType {
    param([array]$Labels)
    switch -Regex ($Labels -join ' ') {
        '(?i)(^|\s)(type::epic|epic)(\s|$)'    { 'Epic'; break }
        '(?i)(^|\s)(type::task|task)(\s|$)'    { 'Task'; break }
        '(?i)(^|\s)(type::bug|bug)(\s|$)'      { 'Issue'; break }
        '(?i)(^|\s)(type::feature|feature)(\s|$)' { 'Issue'; break }
        default { 'Issue' }
    }
}

function Get-AdoStateInfo {
    param([object]$GitLabIssue)

    if ($GitLabIssue.state -eq 'closed') {
        return @{
            State  = 'Done'
            Reason = $(if ($Config.TrySetClosedReasonCompleted) { 'Completed' } else { $null })
        }
    }

    @{ State = 'To Do'; Reason = $null }
}

function Convert-LabelsToTags {
    param([array]$Labels)
    if (-not $Labels) { return '' }
    ($Labels -join '; ')
}

function Invoke-AdoWorkItemPatch {
    param(
        [int]$WorkItemId,
        [array]$Operations,
        [string]$ErrorContext = 'ADO work item patch'
    )

    $encodedProject = [uri]::EscapeDataString($Config.AdoProject)
    $uri = "https://dev.azure.com/{0}/{1}/_apis/wit/workitems/{2}?api-version={3}" -f $Config.AdoOrg, $encodedProject, $WorkItemId, $Config.AdoApiVersion
    $body = Convert-ToJsonPatchDocument -Operations $Operations
    Invoke-Api -Method Patch -Uri $uri -Headers $AdoPatchHeaders -Body $body -ErrorContext $ErrorContext
}

function Add-AdoComment {
    param([int]$WorkItemId, [string]$Text)

    $encodedProject = [uri]::EscapeDataString($Config.AdoProject)
    $uri = "https://dev.azure.com/{0}/{1}/_apis/wit/workItems/{2}/comments?format=markdown&api-version={3}" -f $Config.AdoOrg, $encodedProject, $WorkItemId, $Config.AdoCommentsApiVersion
    $body = @{ text = $Text } | ConvertTo-Json -Depth 10
    Invoke-Api -Method Post -Uri $uri -Headers $AdoJsonHeaders -Body $body -ErrorContext "ADO comment toevoegen aan work item $WorkItemId" | Out-Null
}

function Set-AdoWorkItemStateAndReason {
    param([int]$WorkItemId, [string]$State, [string]$Reason)

    $ops = @(@{ op = 'add'; path = '/fields/System.State'; value = $State })
    if ($Reason) { $ops += @{ op = 'add'; path = '/fields/System.Reason'; value = $Reason } }

    try {
        Invoke-AdoWorkItemPatch -WorkItemId $WorkItemId -Operations $ops -ErrorContext "ADO state/reason zetten voor $WorkItemId" | Out-Null
        return @{ StateApplied = $true; ReasonApplied = [bool]$Reason; FinalReason = $Reason }
    }
    catch {
        if (-not $Reason) { throw }
        Write-Warning 'State + Reason mislukt, retry met alleen State.'
        Invoke-AdoWorkItemPatch -WorkItemId $WorkItemId -Operations @(@{ op = 'add'; path = '/fields/System.State'; value = $State }) -ErrorContext "ADO state retry voor $WorkItemId" | Out-Null
        return @{ StateApplied = $true; ReasonApplied = $false; FinalReason = $null }
    }
}

function Get-GitLabUploadMatches {
    param([string]$Markdown)

    if ([string]::IsNullOrWhiteSpace($Markdown)) { return @() }

    [regex]::Matches($Markdown, '!\[(.*?)\]\((/uploads/([a-f0-9]{32})/([^)]+))\)(\{[^}]+\})?') | ForEach-Object {
        [PSCustomObject]@{
            FullMatch    = $_.Value
            AltText      = $_.Groups[1].Value
            RelativePath = $_.Groups[2].Value
            Secret       = $_.Groups[3].Value
            FileName     = $_.Groups[4].Value
        }
    }
}

function Convert-UploadMarkdownWithPlaceholders {
    param([string]$Markdown, [array]$Uploads)

    $result = $Markdown
    foreach ($u in $Uploads) {
        $result = $result.Replace($u.FullMatch, "[[ADO_INLINE_IMAGE::$($u.FileName)]]")
    }
    $result
}

function Convert-PlaceholdersWithInlineImages {
    param([string]$Markdown, [hashtable]$AttachmentUrlMap)

    $result = $Markdown
    foreach ($name in $AttachmentUrlMap.Keys) {
        $result = $result.Replace("[[ADO_INLINE_IMAGE::$name]]", "<img src=`"$($AttachmentUrlMap[$name])`" alt=`"$name`" />")
    }
    $result
}

function Convert-MarkdownToRawDescriptionHtml {
    param([string]$Markdown)
    if ([string]::IsNullOrWhiteSpace($Markdown)) { $Markdown = '(lege GitLab description)' }
    '<pre>{0}</pre>' -f [System.Net.WebUtility]::HtmlEncode($Markdown)
}

function Convert-MarkdownToMixedHtml {
    param([string]$Markdown)
    if ([string]::IsNullOrWhiteSpace($Markdown)) { return '<div>(lege GitLab description)</div>' }

    ($Markdown -split "`r?`n" | ForEach-Object {
        if ($_ -match '<img\s+src=') { $_ } else { '<div>{0}</div>' -f [System.Net.WebUtility]::HtmlEncode($_) }
    }) -join "`n"
}

function Update-AdoDescription {
    param([int]$WorkItemId, [string]$DescriptionHtml)

    Invoke-AdoWorkItemPatch -WorkItemId $WorkItemId -Operations @(
        @{ op = 'add'; path = '/fields/System.Description'; value = $DescriptionHtml }
    ) -ErrorContext "ADO description updaten voor $WorkItemId" | Out-Null
}

function Add-AdoAttachment {
    param([string]$FilePath)

    $fileName = [IO.Path]::GetFileName($FilePath)
    $encodedProject = [uri]::EscapeDataString($Config.AdoProject)
    $encodedFileName = [uri]::EscapeDataString($fileName)
    $uri = "https://dev.azure.com/{0}/{1}/_apis/wit/attachments?fileName={2}&api-version={3}" -f $Config.AdoOrg, $encodedProject, $encodedFileName, $Config.AdoApiVersion
    $bytes = [IO.File]::ReadAllBytes($FilePath)
    $headers = @{ Authorization = "Basic $AdoAuthBase64"; 'Content-Type' = 'application/octet-stream'; Accept = 'application/json' }
    Invoke-Api -Method Post -Uri $uri -Headers $headers -Body $bytes -ErrorContext "ADO attachment upload ($fileName)"
}

function Get-AdoRelationTypeFromGitLabLink {
    param([string]$GitLabLinkType)
    switch ($GitLabLinkType) {
        'relates_to'    { 'System.LinkTypes.Related' }
        'blocks'        { 'System.LinkTypes.Dependency-Forward' }
        'is_blocked_by' { 'System.LinkTypes.Dependency-Reverse' }
        default         { $null }
    }
}

function Add-AdoWorkItemRelation {
    param([int]$SourceWorkItemId, [int]$TargetWorkItemId, [string]$RelationType, [string]$Comment)

    $targetUrl = "https://dev.azure.com/{0}/_apis/wit/workItems/{1}" -f $Config.AdoOrg, $TargetWorkItemId
    Invoke-AdoWorkItemPatch -WorkItemId $SourceWorkItemId -Operations @(
        @{
            op = 'add'; path = '/relations/-'
            value = @{ rel = $RelationType; url = $targetUrl; attributes = @{ comment = $Comment } }
        }
    ) -ErrorContext "ADO relation toevoegen $SourceWorkItemId -> $TargetWorkItemId" | Out-Null
}

function Build-GitLabCommentText {
    param([object]$Note)

    if ([string]::IsNullOrWhiteSpace($Note.body)) {
        return '(lege GitLab comment)'
    }

    return $Note.body
}

function New-AdoWorkItemInitial {
    param([object]$GitLabIssue, [string]$WorkItemType)

    $title = $GitLabIssue.title
    $descriptionRaw = [string]$GitLabIssue.description
    $uploads = @(Get-GitLabUploadMatches -Markdown $descriptionRaw)
    $cleanMarkdown = Convert-UploadMarkdownWithPlaceholders -Markdown $descriptionRaw -Uploads $uploads
    $descriptionHtml = Convert-MarkdownToRawDescriptionHtml -Markdown $cleanMarkdown
    $tags = Convert-LabelsToTags -Labels $GitLabIssue.labels

    Write-Host "Aanmaken ADO work item: [$WorkItemType] $title"


    $ops = @(
        @{ op = 'add'; path = '/fields/System.Title'; value = $title },
        @{ op = 'add'; path = '/fields/System.Description'; value = $descriptionHtml }
    )
    if ($tags) { $ops += @{ op = 'add'; path = '/fields/System.Tags'; value = $tags } }

    $encodedProject = [uri]::EscapeDataString($Config.AdoProject)
    $encodedType = [uri]::EscapeDataString($WorkItemType)
    $uri = "https://dev.azure.com/{0}/{1}/_apis/wit/workitems/`${2}?api-version={3}" -f $Config.AdoOrg, $encodedProject, $encodedType, $Config.AdoApiVersion
    $created = Invoke-Api -Method Patch -Uri $uri -Headers $AdoPatchHeaders -Body (Convert-ToJsonPatchDocument -Operations $ops) -ErrorContext "ADO work item aanmaken [$WorkItemType]"

    [PSCustomObject]@{ id = [int]$created.id; url = $created.url; uploads = $uploads; originalMarkdown = $descriptionRaw }
}

function Update-AdoWorkItemContent {
    param([int]$WorkItemId, [object]$GitLabIssue, [array]$Uploads, [string]$OriginalMarkdown)

    $gitlabComments = @(Get-GitLabIssueComments -IssueIid ([int]$GitLabIssue.iid))

    $attachedNames = @()
    $attachmentUrlMap = @{}

    foreach ($upload in $Uploads) {
        try {
            $safeName = [IO.Path]::GetFileName($upload.FileName)
            $destPath = Join-Path $Config.TempRoot $safeName
            $encodedFileName = [uri]::EscapeDataString($upload.FileName)
            $downloadUri = "{0}/api/v4/projects/{1}/uploads/{2}/{3}" -f $Config.GitLabUrl, $Config.GitLabProjectId, $upload.Secret, $encodedFileName
            Invoke-Download -Uri $downloadUri -Headers $GitLabHeaders -OutFile $destPath -ErrorContext "GitLab upload downloaden ($safeName)" | Out-Null

            $adoAttachment = Add-AdoAttachment -FilePath $destPath
            $attachmentUrlMap[$upload.FileName] = $adoAttachment.url
        }
        catch {
            Write-Warning "Upload/attachment migratie mislukt voor bestand '$($upload.FileName)' in GitLab issue #$($GitLabIssue.iid)"
            Write-Warning $_.Exception.Message
            if ($_.ErrorDetails?.Message) { Write-Warning $_.ErrorDetails.Message }
        }
    }

    try {
        $markdownWithPlaceholders = Convert-UploadMarkdownWithPlaceholders -Markdown $OriginalMarkdown -Uploads $Uploads
        $markdownWithInlineImages = Convert-PlaceholdersWithInlineImages -Markdown $markdownWithPlaceholders -AttachmentUrlMap $attachmentUrlMap
        Update-AdoDescription -WorkItemId $WorkItemId -DescriptionHtml (Convert-MarkdownToMixedHtml -Markdown $markdownWithInlineImages)
        Write-Host '  Description bijgewerkt met inline afbeeldingen'
    }
    catch {
        Write-Warning "Description updaten met inline afbeeldingen mislukt voor issue #$($GitLabIssue.iid)"
        Write-Warning $_.Exception.Message
        if ($_.ErrorDetails?.Message) { Write-Warning $_.ErrorDetails.Message }
    }


    $migratedCommentCount = 0
    foreach ($gitlabComment in $gitlabComments) {
        try {
            Add-AdoComment -WorkItemId $WorkItemId -Text (Build-GitLabCommentText -Note $gitlabComment)
            $migratedCommentCount++
        }
        catch {
            Write-Warning "GitLab comment migratie mislukt voor note ID '$($gitlabComment.id)' in issue #$($GitLabIssue.iid)"
            Write-Warning $_.Exception.Message
            if ($_.ErrorDetails?.Message) { Write-Warning $_.ErrorDetails.Message }
        }
    }

    [PSCustomObject]@{ attachmentCount = $attachedNames.Count; commentCount = $migratedCommentCount }
}

function Convert-GitLabIssueLinksToAdo {
    param([array]$GitLabIssues, [hashtable]$IssueMapByIid)

    $migratedLinkCount = 0

    foreach ($issue in $GitLabIssues) {
        $sourceIid = [int]$issue.iid
        if (-not $IssueMapByIid.ContainsKey("$sourceIid")) { continue }

        foreach ($link in @(Get-GitLabIssueLinks -IssueIid $sourceIid)) {
            if ($null -eq $link.id) { continue }
            $gitlabLinkId = [string]$link.id
            if ($script:ProcessedGitLabLinkIds.ContainsKey($gitlabLinkId)) { continue }

            $sourceIssueObj = $link.source_issue
            $targetIssueObj = $link.target_issue
            if ($null -eq $sourceIssueObj -or $null -eq $targetIssueObj) { continue }

            if ([int]$sourceIssueObj.project_id -ne [int]$Config.GitLabProjectId -or [int]$targetIssueObj.project_id -ne [int]$Config.GitLabProjectId) {
                Write-Host "  Skip link ${gitlabLinkId}: source/target in ander project"
                $script:ProcessedGitLabLinkIds[$gitlabLinkId] = $true
                continue
            }

            $actualSourceIid = [int]$sourceIssueObj.iid
            $actualTargetIid = [int]$targetIssueObj.iid
            if (-not $IssueMapByIid.ContainsKey("$actualSourceIid") -or -not $IssueMapByIid.ContainsKey("$actualTargetIid")) {
                Write-Host "  Skip link ${gitlabLinkId}: source/target issue niet in ADO-map"
                $script:ProcessedGitLabLinkIds[$gitlabLinkId] = $true
                continue
            }

            $relationType = Get-AdoRelationTypeFromGitLabLink -GitLabLinkType $link.link_type
            if (-not $relationType) {
                Write-Host "  Skip link ${gitlabLinkId}: onbekend GitLab link type '$($link.link_type)'"
                $script:ProcessedGitLabLinkIds[$gitlabLinkId] = $true
                continue
            }

            $sourceAdoId = [int]$IssueMapByIid["$actualSourceIid"].AdoId
            $targetAdoId = [int]$IssueMapByIid["$actualTargetIid"].AdoId


            try {
                Add-AdoWorkItemRelation -SourceWorkItemId $sourceAdoId -TargetWorkItemId $targetAdoId -RelationType $relationType -Comment "Gemigreerd uit GitLab issue link ($($link.link_type)): #$actualSourceIid -> #$actualTargetIid"
                $script:ProcessedGitLabLinkIds[$gitlabLinkId] = $true
                $migratedLinkCount++
            }
            catch {
                Write-Warning "Link migratie mislukt voor GitLab link ID '$gitlabLinkId' (#$actualSourceIid -> #$actualTargetIid)"
                Write-Warning $_.Exception.Message
                if ($_.ErrorDetails?.Message) { Write-Warning $_.ErrorDetails.Message }
            }
        }
    }

    $migratedLinkCount
}

# -------- MAIN --------
try {
    $issues = @(Get-GitLabPaged -Path ("issues?state={0}" -f $Config.GitLabState) -PerPage $Config.PerPage)

    Write-Host "`nTotaal opgehaalde GitLab issues: $($issues.Count)`n"

    $results = @()
    $issueMapByIid = @{}

    # FASE 1: items maken + content finaliseren
    foreach ($issue in $issues) {
        $workItemType = Get-AdoWorkItemType -Labels $issue.labels
        $stateInfo = Get-AdoStateInfo -GitLabIssue $issue
        $initialItem = New-AdoWorkItemInitial -GitLabIssue $issue -WorkItemType $workItemType
        $adoId = $initialItem.id

        $finalizationResult = Update-AdoWorkItemContent -WorkItemId $adoId -GitLabIssue $issue -Uploads $initialItem.uploads -OriginalMarkdown $initialItem.originalMarkdown

        $issueMapByIid["$($issue.iid)"] = @{
            GitLabIssue   = $issue
            AdoId         = $adoId
            AdoType       = $workItemType
            DesiredState  = $stateInfo.State
            DesiredReason = $stateInfo.Reason
        }

        $results += [PSCustomObject]@{
            GitLabIssueIID = $issue.iid
            GitLabTitle    = $issue.title
            AdoType        = $workItemType
            DesiredState   = $stateInfo.State
            AdoId          = $adoId
            Attachments    = $finalizationResult.attachmentCount
            Comments       = $finalizationResult.commentCount
            AdoUrl         = $initialItem.url
        }
    }

    # FASE 2: links migreren
    $migratedLinkCount = 0
    if ($Config.MigrateIssueLinks) {
        Write-Host "`nLinks tussen issues migreren..."
        $migratedLinkCount = Convert-GitLabIssueLinksToAdo -GitLabIssues $issues -IssueMapByIid $issueMapByIid
    }

    # FASE 3: finale states zetten
    Write-Host "`nStates/reasons finaliseren..."
    foreach ($issue in $issues) {
        $mapEntry = $issueMapByIid["$($issue.iid)"]
        if ($null -eq $mapEntry) { continue }


        try {
            $stateResult = Set-AdoWorkItemStateAndReason -WorkItemId ([int]$mapEntry.AdoId) -State $mapEntry.DesiredState -Reason $mapEntry.DesiredReason
            Write-Host "  State toegepast: $($stateResult.StateApplied), reason toegepast: $($stateResult.ReasonApplied)"
        }
        catch {
            Write-Warning "Finale state/reason zetten mislukt voor GitLab issue #$($issue.iid)"
            Write-Warning $_.Exception.Message
            if ($_.ErrorDetails?.Message) { Write-Warning $_.ErrorDetails.Message }
        }
    }

    Write-Host "`nMigratie klaar. Resultaten:"
    $results | Format-Table -AutoSize
    Write-Host "`nTotaal gemigreerde links: $migratedLinkCount"
}
catch {
    Write-Error "Algemene fout in script: $($_.Exception.Message)"
    if ($_.ErrorDetails?.Message) { Write-Error $_.ErrorDetails.Message }
}
