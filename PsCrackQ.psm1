﻿$script:CrackQApiSession = [ordered]@{
    Url             = $null
    SessionVariable     = $null
    Headers = $null
}

Function Connect-CrackQ
{
    param
    (
          [Parameter(Mandatory = $true)] [System.Uri] $CrackQUrl
        , [Parameter(Mandatory = $true)] [string] $User
        , [Parameter(Mandatory = $true)] [string] $Pass
    )

    $script:CrackQApiSession.Url = $CrackQUrl

    # Get a CSRF token
    $uri = "{0}api/login" -f $script:CrackQApiSession.Url
    Invoke-RestMethod -Uri $uri -Method Options -ContentType "application/json" -SessionVariable sv
    # From https://hochwald.net/get-cookies-from-powershell-webrequestsession/
    $cookieInfoObject = $sv.Cookies.GetType().InvokeMember('m_domainTable', [Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::GetField -bor [Reflection.BindingFlags]::Instance, $null, $sv.Cookies, @())
    if(-not ($csrfCookie = $cookieInfoObject.Values.Values  | ?{$_.Name -eq "csrftoken"}))
    {
        throw "Unable to retrieve csrftoken from $CrackqUrl"
    }

    $script:CrackQApiSession.SessionVariable = $sv

    $script:CrackQApiSession.Headers = @{
            'X-CSRFTOKEN'= $csrfCookie.Value
        }

    $body = [pscustomobject] @{
            user = $User
            password = $Pass
        } | ConvertTo-Json

    Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -WebSession $script:CrackQApiSession.SessionVariable -Headers $script:CrackQApiSession.Headers  | Out-Null
}

Function Disconnect-CrackQ
{
    $uri = "{0}api/logout" -f $script:CrackQApiSession.Url
    Invoke-RestMethod -Uri $uri -Method Get -ContentType "application/json" -WebSession $script:CrackQApiSession.SessionVariable  -Headers $script:CrackQApiSession.Headers | Out-Null
}

Function Get-CrackQTemplate
{
    param
    (
          [Parameter(Mandatory = $true)] [string] $TemplateName
    )

    $uri = "{0}api/tasks/templates" -f $script:CrackQApiSession.Url
    $result = Invoke-RestMethod -Uri $uri -Method Get -ContentType "application/json" -WebSession $script:CrackQApiSession.SessionVariable  -Headers $script:CrackQApiSession.Headers

    if(-not ($template = $result | ?{$_.Name -eq $TemplateName}))
    {
        throw ("Unable to find CrackQ template matching `"{0}`"" -f $TemplateName)
    }
    if($template.Count -gt 1)
    {
        $template  | ConvertTo-Json
        throw ("Found multiple CrackQ templates matching `"{0}`"" -f $TemplateName)
    }

    return $template
}

Function Invoke-CrackQTask
{
    param
    (
          [Parameter(Mandatory = $true)] [string[]] $Hashes
        , [Parameter(Mandatory = $true)] $Template
        , [Parameter(Mandatory = $true)] [string] $JobRef
        , [Parameter(Mandatory = $false)] [string] $HashMode = "1000"
    )

    # Use the template as the starting point for the job
    $jobSubmission = $template.Details
    $jobSubmission.PSObject.Properties.Remove("stats")
    foreach($p in ($jobSubmission.PSObject.Properties | ?{$_.Value -eq "None"}))
    {
        $p.Value = $null
    }

    # Add mandatory properties
    $jobSubmission | Add-Member -NotePropertyName "name" -NotePropertyValue ("{0} using template {1}" -f $jobRef,$TemplateName)
    $jobSubmission | Add-Member -NotePropertyName "disable_brain" -NotePropertyValue $false
    $jobSubmission | Add-Member -NotePropertyName "username" -NotePropertyValue $false
    $jobSubmission | Add-Member -NotePropertyName "hash_mode" -NotePropertyValue $HashMode
    $jobSubmission | Add-Member -NotePropertyName "hash_list" -NotePropertyValue $null
    $jobSubmission.hash_list = $Hashes

    $body = [pscustomobject] @{
            jobs = @($jobSubmission)
            name = $JobRef
        } | ConvertTo-Json -Depth 10

    $uri = "{0}api/tasks" -f $script:CrackQApiSession.Url
    $result = Invoke-RestMethod -Uri $uri -Method Post -ContentType "application/json" -Body $body -WebSession $script:CrackQApiSession.SessionVariable -Headers $script:CrackQApiSession.Headers
    $stopwatch =  [system.diagnostics.stopwatch]::StartNew()

    if(-not ($jobId = $result.jobs[0]))
    {
        throw "Job not submitted to CrackQ"
    }

    $uri = "{0}api/queuing/{1}" -f $script:CrackQApiSession.Url,$jobId
    if (-not (     ($job = Invoke-RestMethod -Uri $uri -Method Get -ContentType "application/json" -WebSession $script:CrackQApiSession.SessionVariable  -Headers $script:CrackQApiSession.Headers) -and ("started","finished") -contains $job.Status ))
    {
        throw "Job {0} not started on CrackQ" -f $jobId
    }

    $jobTimeout =  [timespan]::FromMinutes($jobSubmission.timeout)
    Write-Host ("Job {0} started on CrackQ with a timeout of {1:hh:mm}" -f $jobId,([datetime]$jobTimeout.Ticks))

    # Poll for job status
    do
    {
        Start-Sleep -Seconds (5*60)
        Write-Host ("Job {0} in status {1}" -f $jobId,$job.Status)
        $job = Invoke-RestMethod -Uri $uri -Method Get -ContentType "application/json" -WebSession $script:CrackQApiSession.SessionVariable  -Headers $script:CrackQApiSession.Headers

    } while ( $job.Status -eq "started" -and ($stopwatch.ElapsedMilliseconds/1000) -lt ($jobSubmission.timeout + 10*60))
    $stopwatch.Stop()

    <#
    Status        : started
    Result        : 

    Status        : finished
    Result        : Cracked
    Cracked       : {22386f282a56f5695b3d2d9f9ec7e3d7:spice4352@, aeef705bc4eef3c0a1111ce97dd61c1d:June2018}
    #>

    $job
    $job.Cracked
    
}

Export-ModuleMember -Function Connect-CrackQ
Export-ModuleMember -Function Disconnect-CrackQ
Export-ModuleMember -Function Get-CrackQTemplate
Export-ModuleMember -Function Invoke-CrackQTask