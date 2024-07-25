#Dmitriy 2024

function OpenRunspacePool($throttleLimit) {
    $runspacePool = $null
    try{
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ImportPSModulesFromPath('.\modules')
        $runspacePool = [runspacefactory]::CreateRunspacePool(
                            1,
                            $throttleLimit, 
                            $iss, 
                            $host 
                            )
        $runspacePool.ApartmentState = "MTA"
        $runspacePool.Open()
        Write-Verbose "OpenRunspacePool: runspacePool Opened" -Verbose
    }
    catch {
        Write-Warning "OpenRunspacePool $_"
    }
    return $runspacePool
}

function WaitAndProcessTasks {
    param(
        [array] $runspaceTaskArr,
        [int] $timeoutMilliseconds,
        [ValidateSet("WaitOne", "WaitAny","WaitAll", "WaitCompleted", "WaitTime")]
        [string]$waitType = "WaitOne",
        [int] $sleep = 1000
    )

    $resultArr = @()
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $timeRemaining = $timeoutMilliseconds
    if($WaitType -eq "WaitOne") {
        foreach ($task in $runspaceTaskArr) {
            $timeRemaining = $timeoutMilliseconds - $stopwatch.ElapsedMilliseconds
            if($timeRemaining -gt 0) {
                Write-Verbose "WaitAndProcessTasks: WaitOne TimeRemaining $timeRemaining" -Verbose
                $task.AsyncResult.AsyncWaitHandle.WaitOne($timeRemaining,$true) | Out-Null
            }
        }
    }
    elseif($WaitType -eq "WaitAny")
    {           
        $allAsyncResult = $runspaceTaskArr | 
                            Where-Object {$_.AsyncResult.IsCompleted -contains $false} |
                            Select-Object -ExpandProperty AsyncResult | 
                            Select-Object -ExpandProperty AsyncWaitHandle
        while ($allAsyncResult.Count -gt 0 -and $timeRemaining -gt 0) 
        {
            Write-Verbose "WaitAndProcessTasks: WaitAny TimeRemaining $timeRemaining" -Verbose
            $index = [System.Threading.WaitHandle]::WaitAny($allAsyncResult,$timeRemaining,$true)
	        if ($index -eq [System.Threading.WaitHandle]::WaitTimeout) {
                Write-Verbose "WaitAndProcessTasks: WaitAny Timed out $timeRemaining" -Verbose 
                break
            }
            $timeRemaining = $timeoutMilliseconds - $stopwatch.ElapsedMilliseconds
            Start-Sleep -Milliseconds $sleep
            $allAsyncResult = $runspaceTaskArr | 
                        Where-Object {$_.AsyncResult.IsCompleted -contains $false} |
                        Select-Object -ExpandProperty AsyncResult | 
                        Select-Object -ExpandProperty AsyncWaitHandle
        }
    } 
    elseif($WaitType -eq "WaitCompleted")
    {           
       while ($runspaceTaskArr.AsyncResult.IsCompleted -contains $false -and $timeRemaining -gt 0) {
            Write-Verbose "WaitAndProcessTasks: WaitCompleted TimeRemaining $timeRemaining" -Verbose
            $timeRemaining = $timeoutMilliseconds - $stopwatch.ElapsedMilliseconds
            Start-Sleep -Milliseconds $sleep
        } 
    }
    else
    {
       while ($timeRemaining -gt 0) {
            Write-Verbose "WaitAndProcessTasks: RemainingTime  $timeRemaining" -Verbose
            $timeRemaining = $timeoutMilliseconds - $stopwatch.ElapsedMilliseconds
            Start-Sleep -Milliseconds $sleep
        }   
    }

    foreach ($task in $runspaceTaskArr) {  
        if ($task.AsyncResult.IsCompleted) {
            $resultArr += $task.PowerShell.EndInvoke($task.AsyncResult)
            Write-Host (Get-Date).ToString() "Done!  TaskId: $($task.TaskId)" -ForegroundColor Green
        }
        else {
            Write-Host (Get-Date).ToString() "False! TaskId: $($task.TaskId)" -ForegroundColor Yellow
            $task.PowerShell.Stop() | Out-Null
        }

        $task.AsyncResult = $null
        $task.PowerShell.Dispose()
    }
    return $resultArr
}

function CloseRunspacePool($runspacePool) {
    if($null -eq $runspacePool) {
        Write-Warning 'CloseRunspacePool: runspacePool is NULL'
        return
    }
    try {
        $runspacePool.Close()
        $runspacePool.Dispose()
        Write-Verbose "CloseRunspacePool: runspacePool closed" -Verbose
    }
    catch {
        Write-Warning "CloseRunspacePool: $_"
    }
}

function CreateTask([string] $taskId, [System.Management.Automation.Runspaces.RunspacePool]$runspacePool, [scriptblock]$scriptBlock,[array]$argumentArr) {

    if([string]::IsNullOrEmpty( $taskId)) {
        Write-Warning 'CreateTask: taskId is NULL'
        return $null
    }
    if($null -eq $runspacePool) {
        Write-Warning 'CreateTask: runspacePool is NULL'
        return $null
    }
    if($null -eq $scriptBlock) {
        Write-Warning 'CreateTask: scriptBlock is NULL'
        return $null
    }
    if($null -eq $argumentArr) {
        Write-Warning 'CreateTask: ArgumentArr is NULL'
        return $null
    }
    try {
        $powerShellTask = [powershell]::Create() 
        $powerShellTask.RunspacePool = $runspacePool
        $powerShellTask.AddScript($scriptBlock).AddParameters($argumentArr) | Out-Null
        $runspaceTask = [PSCustomObject]@{ 
            TaskId      = $taskId
            PowerShell  = $powerShellTask
            AsyncResult = $powerShellTask.BeginInvoke() 
        }
        return $runspaceTask 
    }
    catch {
        Write-Warning "CreateTask: $_"
        return $null
    }
}


function ForEach-Object-Parallel {
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [ScriptBlock]$ScriptBlock,
        [Parameter(Mandatory = $true, Position = 1, ValueFromPipeline = $true)]
        [Object[]]$InputObject,
        [int]$ThrottleLimit = [System.Environment]::ProcessorCount,
        [int]$TimeoutMilliseconds = 30,
        [string]$WaitMetod = "WaitOne"
    )


    begin {
        [int] $TaskID = 0
        $runspaceTaskArr = @()
        $resultArr = @()
        $runspacePool = OpenRunspacePool  $ThrottleLimit
        if($null -eq $runspacePool) {
            return $null
        }
    }
    process {
        foreach ($item in $InputObject) {
            $runspaceTask = CreateTask $TaskID $runspacePool $scriptBlock $item
            if($null -ne $runspaceTask) {
                $runspaceTaskArr += $runspaceTask
                $TaskID = $TaskID + 1
            }
        }
    }
    end {
        if($null -eq $runspaceTaskArr) {
            return $null
        }

        try {
            $totalWorkTime = [math]::Round((Measure-Command {
                 $resultArr = WaitAndProcessTasks  $runspaceTaskArr $TimeoutMilliseconds $WaitMetod
            }).TotalSeconds, 2)

            Write-Verbose "ForEach-Object-Parallel: TOTAL WorkTime = $totalWorkTime" -Verbose
            return $resultArr
        }
        catch {
            Write-Error "ForEach-Object-Parallel: $_"
        }
        finally {
            $runspaceTaskArr.Clear()
            CloseRunspacePool $runspacePool
        }
    }
}

function Processed($item)
{
    $randomTime = (Get-Random -Minimum 1 -Maximum 3)
    Start-Sleep -Seconds $randomTime
    "Processed item $item on thread $randomTime"
}

$data = 1..8
$result = $data | ForEach-Object-Parallel -ScriptBlock (${function:Processed})  -ThrottleLimit 2 -TimeoutMilliseconds 3000
$result
