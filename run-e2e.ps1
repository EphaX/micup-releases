# SPDX-License-Identifier: AGPL-3.0-or-later
# Micup v1 -> v2 bridge end-to-end test, run inside Windows Sandbox (bridge-e2e.wsb). Results go to
# C:\micup-bridge\bridge-sonuc.txt. Host preparation (E:\micup-sandbox\bridge = C:\micup-bridge):
#   build-bridge.ps1 -SetupExe <task 1.14 Micup-win-Setup.exe> -OutDir E:\micup-sandbox\bridge
#   build-bridge.ps1 -SetupExe <any non-installer file>       -OutDir E:\micup-sandbox\bridge\bozuk
#   copy sandbox\run-e2e.ps1 to E:\micup-sandbox\bridge
#   optional: Micup-Setup-0.4.4-x64.exe next to it (otherwise downloaded from EphaX/micup-releases)
# Scenarios (one fresh sandbox each; bridge-e2e.wsb runs direct, change its -Scenario for the others):
#   direct    broken bridge keeps v1, then the real bridge moves a per-user v1 to v2
#   allusers  per-machine v1 ("/allusers", HKLM): UAC Yes removes it; UAC No keeps it, shows the notice once and
#             closes v1's update channel; a rerun asks nothing. Needs a person at the UAC prompts and the notice.
#   updater   v1's own electron-updater finds the bridge on a local generic feed
param([ValidateSet('direct', 'allusers', 'updater')][string]$Scenario = 'direct')
$ErrorActionPreference = 'Stop'
$dir = 'C:\micup-bridge'
$report = Join-Path $dir 'bridge-sonuc.txt'
$bridgeArgs = '--updated', '/S', '--force-run'
$v1Guid = '23f9d4a0-f5b8-519e-985d-0d53839c95e1'
$uninstallRoots = @(
	'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
	'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
	'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
$v2Root = Join-Path $env:LOCALAPPDATA 'micup_desktop'
$v1UpdaterId = Join-Path $env:APPDATA 'Micup\.updaterId'
$closedChannelId = '00000000-0000-4000-8000-0000ffffffff'

function Write-Result([string]$line) { $line | Tee-Object -FilePath $report -Append }

function Step([string]$name, [scriptblock]$check) {
	try {
		Write-Result $(if (& $check) { "PASS $name" } else { "FAIL $name" })
	} catch {
		Write-Result "FAIL $name : $_"
	}
}

function Get-V1Entry {
	foreach ($root in $uninstallRoots) {
		foreach ($key in "{$v1Guid}", $v1Guid) {
			$entry = Get-ItemProperty (Join-Path $root $key) -ErrorAction SilentlyContinue
			if ($entry) { return [pscustomobject]@{Key = Join-Path $root $key; InstallLocation = $entry.InstallLocation} }
		}
	}
	return $null
}

function Install-V1([switch]$AllUsers) {
	$installer = Join-Path $dir 'Micup-Setup-0.4.4-x64.exe'
	if (-not (Test-Path $installer)) {
		$installer = Join-Path $env:TEMP 'Micup-Setup-0.4.4-x64.exe'
		Invoke-WebRequest 'https://github.com/EphaX/micup-releases/releases/download/v0.4.4/Micup-Setup-0.4.4-x64.exe' -OutFile $installer -UseBasicParsing
	}
	Start-Process $installer -ArgumentList $(if ($AllUsers) { '/S', '/allusers' } else { '/S' }) -Wait
	Start-Sleep -Seconds 3
	Get-Process -Name 'Micup' -ErrorAction SilentlyContinue | Stop-Process -Force
	$entry = Get-V1Entry
	Write-Result "INFO v1 uninstall key form: $(if ($entry) { $entry.Key } else { 'not found' }), install location: $($entry.InstallLocation)"
	return $entry
}

function Invoke-Bridge([string]$path) {
	(Start-Process $path -ArgumentList $bridgeArgs -Wait -PassThru).ExitCode
}

function Test-V2Owns-Protocol {
	$command = (Get-ItemProperty 'HKCU:\Software\Classes\micup\shell\open\command' -ErrorAction SilentlyContinue).'(default)'
	return [bool]($command -and $command -like '*micup_desktop*')
}

function Wait-Until([scriptblock]$condition, [int]$seconds) {
	$deadline = (Get-Date).AddSeconds($seconds)
	while (-not (& $condition) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
	return [bool](& $condition)
}

function Save-BridgeLogs {
	Copy-Item (Join-Path $env:TEMP 'micup-bridge*.log') $dir -ErrorAction SilentlyContinue
}

Remove-Item $report -ErrorAction SilentlyContinue

if ($Scenario -eq 'direct') {
	$v1 = Install-V1
	Step 'v1 0.4.4 installed' { $null -ne $v1 }

	$code = Invoke-Bridge (Join-Path $dir 'bozuk\Micup-Setup-1.0.0-x64.exe')
	Step 'broken v2 setup: bridge exits 1' { $code -eq 1 }
	Step 'broken v2 setup: v1 entry kept' { $null -ne (Get-V1Entry) }
	Step 'broken v2 setup: v1 files kept' { Test-Path $v1.InstallLocation }
	Step 'broken v2 setup: no v2' { -not (Test-Path (Join-Path $v2Root 'current\Micup.exe')) }

	$code = Invoke-Bridge (Join-Path $dir 'Micup-Setup-1.0.0-x64.exe')
	Step 'bridge exits 0' { $code -eq 0 }
	Step 'v2 installed' { Test-Path (Join-Path $v2Root 'current\Micup.exe') }
	Step 'v1 entry removed' { $null -eq (Get-V1Entry) }
	Step 'v1 files removed' { Wait-Until { -not (Test-Path (Join-Path $v1.InstallLocation '*.exe')) } 60 }
	Step 'start menu shortcut present' { Test-Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Micup.lnk') }
	Step 'v2 started and registered micup://' { Wait-Until { Test-V2Owns-Protocol } 60 }
	Start-Process 'micup://invite/x'
	Step 'micup://invite/x runs v2' {
		Wait-Until { Get-Process -Name 'Micup' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$v2Root*" } } 30
	}
	Write-Result 'MANUAL the micup://invite/x window shows the invite screen'
} elseif ($Scenario -eq 'allusers') {
	$bridge = Join-Path $dir 'Micup-Setup-1.0.0-x64.exe'
	Write-Result 'MANUAL answer Yes on the UAC prompt of the v1 installer'
	$v1 = Install-V1 -AllUsers
	Step 'per-machine v1 installed (HKLM entry)' { $v1 -and $v1.Key -like 'HKLM:*' }

	Write-Result 'MANUAL answer Yes on the UAC prompt the bridge raises for the v1 uninstaller'
	$code = Invoke-Bridge $bridge
	Step 'UAC yes: bridge exits 0' { $code -eq 0 }
	Step 'UAC yes: v2 installed' { Test-Path (Join-Path $v2Root 'current\Micup.exe') }
	Step 'UAC yes: v1 entry removed' { $null -eq (Get-V1Entry) }
	Step 'UAC yes: v1 files removed' { Wait-Until { -not (Test-Path (Join-Path $v1.InstallLocation '*.exe')) } 60 }
	Step 'UAC yes: v1 update channel left alone' { (Get-Content -Raw $v1UpdaterId -ErrorAction SilentlyContinue) -ne $closedChannelId }
	Step 'UAC yes: v2 started and registered micup://' { Wait-Until { Test-V2Owns-Protocol } 60 }

	Write-Result 'MANUAL answer Yes on the UAC prompt of the v1 installer'
	$v1 = Install-V1 -AllUsers
	Step 'per-machine v1 installed again' { $v1 -and $v1.Key -like 'HKLM:*' }
	Write-Result 'MANUAL answer No on the bridge UAC prompt; a Turkish notice must ask to remove the old Micup under Uygulamalar; close it'
	$code = Invoke-Bridge $bridge
	Step 'UAC no: bridge exits 2' { $code -eq 2 }
	Step 'UAC no: v1 entry kept' { $null -ne (Get-V1Entry) }
	Step 'UAC no: v1 update channel closed' { (Get-Content -Raw $v1UpdaterId -ErrorAction SilentlyContinue) -eq $closedChannelId }
	Step 'UAC no: v2 started' {
		Wait-Until { Get-Process -Name 'Micup' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$v2Root*" } } 30
	}
	Get-Process -Name 'Micup' -ErrorAction SilentlyContinue | Stop-Process -Force

	Write-Result 'MANUAL this rerun must show no UAC prompt and no notice'
	$code = Invoke-Bridge $bridge
	Step 'rerun: bridge exits 2 without asking again' {
		$code -eq 2 -and (Select-String -Path (Join-Path $env:TEMP 'micup-bridge.log') -Pattern 'not asking again' -Quiet)
	}
	Step 'rerun: v1 entry still kept' { $null -ne (Get-V1Entry) }
} else {
	$v1 = Install-V1
	Step 'v1 0.4.4 installed' { $null -ne $v1 }
	$feed = Join-Path $v1.InstallLocation 'resources\app-update.yml'
	$cacheLine = Get-Content $feed -ErrorAction SilentlyContinue | Where-Object { $_ -like 'updaterCacheDirName:*' }
	Set-Content -Path $feed -Encoding ascii -Value (@('provider: generic', 'url: http://localhost:8080/') + @($cacheLine | Where-Object { $_ }))
	$server = Start-Job -ArgumentList $dir -ScriptBlock {
		param($root)
		$listener = New-Object Net.HttpListener
		$listener.Prefixes.Add('http://localhost:8080/')
		$listener.Start()
		while ($listener.IsListening) {
			$context = $listener.GetContext()
			$file = Join-Path $root ([Uri]::UnescapeDataString($context.Request.Url.AbsolutePath.TrimStart('/')))
			if ((Split-Path $file -Parent) -eq $root -and (Test-Path $file -PathType Leaf)) {
				$bytes = [IO.File]::ReadAllBytes($file)
				$context.Response.ContentLength64 = $bytes.Length
				$context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
			} else {
				$context.Response.StatusCode = 404
			}
			$context.Response.Close()
		}
	}
	try {
		Start-Process (Get-ChildItem $v1.InstallLocation -Filter 'Micup.exe' | Select-Object -First 1).FullName
		Write-Result 'MANUAL if v1 shows an update prompt, accept it and write down what it asked'
		$migrated = Wait-Until { Test-Path (Join-Path $v2Root 'current\Micup.exe') } 300
		if (-not $migrated) {
			Get-Process -Name 'Micup' -ErrorAction SilentlyContinue | ForEach-Object { [void]$_.CloseMainWindow() }
			$migrated = Wait-Until { Test-Path (Join-Path $v2Root 'current\Micup.exe') } 300
		}
		Step 'v1 updater downloaded and ran the unsigned bridge' { $migrated }
		Step 'v1 entry removed' { Wait-Until { $null -eq (Get-V1Entry) } 120 }
		Step 'v2 started and registered micup://' { Wait-Until { Test-V2Owns-Protocol } 60 }
	} finally {
		Stop-Job $server
	}
}
Save-BridgeLogs
