Add-Type -AssemblyName System.Windows.Forms,System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Cut-video-at-image - Controller'    # plain ASCII title (avoid non-ASCII dashes
$form.Size = New-Object System.Drawing.Size(900,600)
$form.StartPosition = 'CenterScreen'

# Buttons
$btnDetect = New-Object System.Windows.Forms.Button -Property @{ Text='Run Detection'; Location = New-Object System.Drawing.Point(12,12); Size = New-Object System.Drawing.Size(120,30) }
$btnCut = New-Object System.Windows.Forms.Button -Property @{ Text='Run Cutting'; Location = New-Object System.Drawing.Point(138,12); Size = New-Object System.Drawing.Size(120,30) }
$btnConfig = New-Object System.Windows.Forms.Button -Property @{ Text='Edit config.json'; Location = New-Object System.Drawing.Point(264,12); Size = New-Object System.Drawing.Size(120,30) }
$btnOpenOut = New-Object System.Windows.Forms.Button -Property @{ Text='Open Outputs'; Location = New-Object System.Drawing.Point(390,12); Size = New-Object System.Drawing.Size(100,30) }
$btnOpenLogs = New-Object System.Windows.Forms.Button -Property @{ Text='Open Logs'; Location = New-Object System.Drawing.Point(496,12); Size = New-Object System.Drawing.Size(100,30) }
$lblStatus = New-Object System.Windows.Forms.Label -Property @{ Text='Idle'; Location = New-Object System.Drawing.Point(610,18); AutoSize=$true }

# Log textbox
$txtLog = New-Object System.Windows.Forms.TextBox -Property @{
    Multiline = $true; ReadOnly = $true; ScrollBars = 'Both'
    Font = New-Object System.Drawing.Font('Consolas',9); Location = New-Object System.Drawing.Point(12,52)
    Size = New-Object System.Drawing.Size(860,496); WordWrap = $false
}

$form.Controls.AddRange(@($btnDetect,$btnCut,$btnConfig,$btnOpenOut,$btnOpenLogs,$lblStatus,$txtLog))

function Start-ScriptJob($label, $scriptFile) {
    if (-not (Test-Path $scriptFile)) { [System.Windows.Forms.MessageBox]::Show("$scriptFile not found","Error") ; return }
    $lblStatus.Text = "$($label): starting"
    $txtLog.AppendText(("`r`n=== {0} started at {1} ===`r`n" -f $label, (Get-Date)))
    # Start the script file directly as a background job (more reliable than spawning nested powershell)
    $jobName = ("{0}-{1}" -f $label, (Get-Date).ToString('yyyyMMddHHmmss'))
    $job = Start-Job -FilePath $scriptFile -Name $jobName -ErrorAction SilentlyContinue
    $timer = New-Object System.Timers.Timer 700
    $timer.AutoReset = $true
    $timer.Add_Elapsed({
        try {
            $out = Receive-Job -Job $job -Keep -ErrorAction SilentlyContinue
            if ($out -and $out.Count -gt 0) {
                [void][System.Windows.Forms.Form]::BeginInvoke($form, [action]{
                    foreach ($line in $out) { $txtLog.AppendText("$line`r`n") }
                    $txtLog.SelectionStart = $txtLog.Text.Length; $txtLog.ScrollToCaret()
                })
            }
            if ($job.State -ne 'Running') {
                $final = Receive-Job -Job $job -ErrorAction SilentlyContinue
                if ($final) {
                    [void][System.Windows.Forms.Form]::BeginInvoke($form, [action]{
                        foreach ($line in $final) { $txtLog.AppendText("$line`r`n") }
                        $txtLog.AppendText(("=== {0} finished at {1} (state={2}) ===`r`n" -f $label, (Get-Date), $job.State))
                        $lblStatus.Text = "Idle"
                    })
                }
                $timer.Stop()
                Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            } else {
                [void][System.Windows.Forms.Form]::BeginInvoke($form, [action]{ $lblStatus.Text = "$($label): running" })
            }
        } catch { }
    })
    $timer.Start()
}

# Button events
$btnDetect.Add_Click({
    $script = Join-Path $PSScriptRoot '1.Detect_Image.ps1'
    Start-ScriptJob 'Detection' $script
})
$btnCut.Add_Click({
    $script = Join-Path $PSScriptRoot '2.Cut_Video.ps1'
    Start-ScriptJob 'Cutting' $script
})
$btnConfig.Add_Click({
    $cfg = Join-Path $PSScriptRoot 'config.json'
    if (-not (Test-Path $cfg)) { New-Item -Path $cfg -ItemType File -Force | Out-Null }
    Start-Process notepad.exe $cfg
})
$btnOpenOut.Add_Click({
    $dir = Join-Path $PSScriptRoot ( (Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json).outputsFolder )
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Start-Process explorer.exe $dir
})
$btnOpenLogs.Add_Click({
    $dir = Join-Path $PSScriptRoot ( (Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json).logsFolder )
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Start-Process explorer.exe $dir
})

# Close on Esc
$form.KeyPreview = $true
$form.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $form.Close() } })

[void]$form.ShowDialog()
