# Create a log file path with the current date appended
$logFilePath = Join-Path $env:Temp "Log-$((Get-Date).ToString('ddMMyyyy'))"
$throttleLimit = 50
$taskCount = 50
$timeoutMilliseconds = 5000
$runspaceTasks = @()

# Define the script block to execute asynchronously
$scriptBlock = {
    Param(
        $index,
        $logFile,
        $sleepDuration,
        $timeout
    )    

    try {
        $scriptWorkTime = [math]::Round((Measure-Command { 
            $mutex = New-Object System.Threading.Mutex($false, "LogMutex")
            Start-Sleep -Seconds $sleepDuration
            if ($mutex.WaitOne($timeout) ) {
                try {
                    "[$(Get-Date)] | $index ----  Writing time: $sleepDuration Log: $logFile" | Out-File $logFile -Append
                    Write-Verbose "   $index ----  Writing time: $sleepDuration Log: $logFile" -Verbose
                } 
                catch {
                    Write-Warning $_
                }
            } 
            else {
                Write-Warning "Timed out acquiring mutex! $index ----  Writing time: $sleepDuration Log: $logFile"
            }
            $mutex.ReleaseMutex() | Out-Null
        }).TotalSeconds, 2)
    }
    catch {
        Write-Warning $_
        $scriptWorkTime = 0
    }
    finally {
        $mutex.Dispose()
    }
    $scriptWorkTime
}

try {
    $runspacePool = [runspacefactory]::CreateRunspacePool(
        1,
        $throttleLimit, 
        [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault(), 
        $host 
    )
    $runspacePool.ApartmentState = "MTA"
    $runspacePool.Open()

    1..$taskCount | ForEach-Object {
        $sleepDuration = Get-Random (1..10)
        $powerShellTask = [powershell]::Create() 
        $powerShellTask.RunspacePool = $runspacePool
        $powerShellTask.AddScript($scriptBlock).AddArgument($_.ToString()).AddArgument($logFilePath).AddArgument($sleepDuration).AddArgument($timeoutMilliseconds / 2) | Out-Null

        Write-Host "Index: $_  Sleep: $sleepDuration" -ForegroundColor DarkYellow

        $runspaceTasks += [PSCustomObject]@{ 
            Index   = $_
            Sleep   = $sleepDuration
            PowerShell = $powerShellTask
            AsyncResult = $powerShellTask.BeginInvoke() 
        }
    }  

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $timeRemaining = $timeoutMilliseconds

    $totalWorkTime = [math]::Round((Measure-Command {
    $allAsyncResult = $runspaceTasks | 
                            Where-Object {$_.AsyncResult.IsCompleted -contains $false} |
                            Select-Object -ExpandProperty AsyncResult | 
                            Select-Object -ExpandProperty AsyncWaitHandle
        while ($allAsyncResult.Count -gt 0 -and $timeRemaining -gt 0) 
        {
            Write-Host $timeRemaining -ForegroundColor Yellow
            $index = [System.Threading.WaitHandle]::WaitAny($allAsyncResult,$timeRemaining,$true)
		    if ($index -eq [System.Threading.WaitHandle]::WaitTimeout) {
                Write-Host (Get-Date).Tostring() 'Timed out!'
                break
            }
            $timeRemaining = $timeoutMilliseconds - $stopwatch.ElapsedMilliseconds
            Start-Sleep -Milliseconds 500
            $allAsyncResult = $runspaceTasks | 
                        Where-Object {$_.AsyncResult.IsCompleted -contains $false} |
                        Select-Object -ExpandProperty AsyncResult | 
                        Select-Object -ExpandProperty AsyncWaitHandle
        }

        foreach ($task in $runspaceTasks) {  
            if ($task.AsyncResult.IsCompleted) {
                $scriptWorkTime = $task.PowerShell.EndInvoke($task.AsyncResult) 
                Write-Host (Get-Date).ToString() "Done! Index: $($task.Index)  ScriptWorkTime: $scriptWorkTime Sleep: $($task.Sleep)" -ForegroundColor Green
            }
            else {
                Write-Host (Get-Date).ToString() "False! Index: $($task.Index) Sleep: $($task.Sleep)" -ForegroundColor Yellow
                $task.PowerShell.Stop() | Out-Null
            }
            $task.AsyncResult = $null
            $task.PowerShell.Dispose()
        }
    }).TotalSeconds, 2)

    Write-Host "TOTAL WorkTime = $totalWorkTime" 
} 
catch {
    Write-Error "An error occurred: $_"
}
finally {
    $runspaceTasks.Clear()
    $runspacePool.Close()
    $runspacePool.Dispose()
}
