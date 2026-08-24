[CmdletBinding()]
param(
	[ValidateSet('Single', 'Dual', 'All')]
	[string] $Mode = 'All'
)

$ErrorActionPreference = 'Stop'
$script:Issue57ProjectName = 'jariyo-issue-57'
$script:Issue57StoreId = '00000000-0000-7000-8000-000000000001'
$script:Issue57StaffId = '00000000-0000-7000-8000-000000000301'

function Get-Issue57ComposeFiles {
	param([ValidateSet('Single', 'Dual')] [string] $Mode)

	$files = @(Join-Path $PSScriptRoot 'compose.yaml')
	if ($Mode -eq 'Dual') {
		$files += Join-Path $PSScriptRoot 'compose.dual.yaml'
	}
	return $files
}

function Get-Issue57ComposeArguments {
	param([ValidateSet('Single', 'Dual')] [string] $Mode)

	$arguments = @('compose', '--project-name', $script:Issue57ProjectName)
	foreach ($file in @(Get-Issue57ComposeFiles -Mode $Mode)) {
		$arguments += @('-f', $file)
	}
	return $arguments
}

function Get-Issue57CleanupArguments {
	param([ValidateSet('Single', 'Dual')] [string] $Mode)

	return @(Get-Issue57ComposeArguments -Mode $Mode) + @('down', '-v', '--remove-orphans')
}

function Get-Issue57Slots {
	param([DateTimeOffset] $Now = [DateTimeOffset]::Now)

	$offset = [TimeSpan]::FromHours(9)
	$date = $Now.ToOffset($offset).Date.AddDays(2)
	return [pscustomobject]@{
		Base = ([DateTimeOffset]::new($date.AddHours(14), $offset)).ToString("yyyy-MM-dd'T'HH:mm:sszzz")
		Stressed = ([DateTimeOffset]::new($date.AddHours(15), $offset)).ToString("yyyy-MM-dd'T'HH:mm:sszzz")
	}
}

function Get-Issue57PeakRps {
	param([Parameter(Mandatory)] [string] $RawJsonPath)

	$buckets = @{}
	Get-Content -LiteralPath $RawJsonPath | ForEach-Object {
		if ([string]::IsNullOrWhiteSpace($_)) {
			return
		}
		$point = $_ | ConvertFrom-Json
		if ($point.type -ne 'Point' -or
			$point.metric -ne 'reservation_initial_started' -or
			$point.data.tags.attempt -ne 'initial' -or
			$point.data.tags.scenario -notin @('base', 'stressed')) {
			return
		}
		$second = ConvertTo-Issue57UtcSecond -Value $point.data.time
		$key = "$($point.data.tags.scenario)|$second"
		$buckets[$key] = [double]($buckets[$key] ?? 0) + [double]$point.data.value
	}

	$result = [ordered]@{}
	foreach ($scenario in @('base', 'stressed')) {
		$peak = $buckets.GetEnumerator() |
			Where-Object { $_.Key.StartsWith("$scenario|") } |
			Sort-Object -Property @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Name'; Descending = $false } |
			Select-Object -First 1
		$result[$scenario.Substring(0, 1).ToUpperInvariant() + $scenario.Substring(1)] = [pscustomobject]@{
			Scenario = $scenario
			PeakRps = if ($null -eq $peak) { 0 } else { [int]$peak.Value }
			Second = if ($null -eq $peak) { $null } else { $peak.Key.Substring($scenario.Length + 1) }
		}
	}
	return [pscustomobject]$result
}

function ConvertTo-Issue57UtcSecond {
	param([Parameter(Mandatory)] $Value)

	if ($Value -is [DateTimeOffset]) {
		$instant = $Value
	} elseif ($Value -is [DateTime]) {
		$dateTime = [DateTime]$Value
		if ($dateTime.Kind -eq [DateTimeKind]::Unspecified) {
			$dateTime = [DateTime]::SpecifyKind($dateTime, [DateTimeKind]::Utc)
		}
		$instant = [DateTimeOffset]::new($dateTime)
	} elseif ($Value -is [string]) {
		$instant = [DateTimeOffset]::Parse(
			[string]$Value,
			[Globalization.CultureInfo]::InvariantCulture,
			[Globalization.DateTimeStyles]::AllowWhiteSpaces
		)
	} else {
		throw "지원하지 않는 k6 timestamp 타입입니다: $($Value.GetType().FullName)"
	}

	return $instant.ToUniversalTime().ToString(
		"yyyy-MM-dd'T'HH:mm:ss'Z'",
		[Globalization.CultureInfo]::InvariantCulture
	)
}

function Test-Issue57PeakRpsRange {
	param([Parameter(Mandatory)] $Peak)

	return $Peak.Base.PeakRps -ge 10 -and $Peak.Base.PeakRps -le 20 -and
		$Peak.Stressed.PeakRps -ge 50 -and $Peak.Stressed.PeakRps -le 100
}

function Test-Issue57Integrity {
	param([Parameter(Mandatory)] [object[]] $Rows)

	if ($Rows.Count -ne 2) {
		return $false
	}
	foreach ($scenario in @('base', 'stressed')) {
		$matches = @($Rows | Where-Object { $_.scenario -eq $scenario })
		if ($matches.Count -ne 1 -or
			[int]$matches[0].confirmed_count -ne 1 -or
			[int]$matches[0].matching_count -ne 1) {
			return $false
		}
	}
	return $true
}

function Test-Issue57DualDistribution {
	param(
		[Parameter(Mandatory)] [string] $NginxLog,
		[Parameter(Mandatory)] [object[]] $Services
	)

	$upstreams = @()
	foreach ($service in @('api-1', 'api-2')) {
		$matches = @($Services | Where-Object { $_.service -eq $service })
		if ($matches.Count -ne 1 -or [string]::IsNullOrWhiteSpace($matches[0].upstream)) {
			return $false
		}
		$upstreams += [string]$matches[0].upstream
	}
	if (@($upstreams | Select-Object -Unique).Count -ne 2) {
		return $false
	}
	foreach ($upstream in $upstreams) {
		if ($NginxLog -notmatch "(?m)(?:^|\s)upstream=$([regex]::Escape($upstream))(?=\s|$)") {
			return $false
		}
	}
	return $true
}

function New-Issue57JwtPem {
	$rsa = [Security.Cryptography.RSA]::Create(2048)
	try {
		return [pscustomobject]@{
			Public = $rsa.ExportSubjectPublicKeyInfoPem() -replace "`r?`n", '\n'
			Private = $rsa.ExportPkcs8PrivateKeyPem() -replace "`r?`n", '\n'
		}
	} finally {
		$rsa.Dispose()
	}
}

function Invoke-Issue57External {
	param(
		[Parameter(Mandatory)] [string] $FilePath,
		[Parameter(Mandatory)] [string[]] $Arguments
	)

	$startInfo = [Diagnostics.ProcessStartInfo]::new()
	$startInfo.FileName = $FilePath
	$startInfo.UseShellExecute = $false
	$startInfo.RedirectStandardOutput = $true
	$startInfo.RedirectStandardError = $true
	foreach ($argument in $Arguments) {
		[void]$startInfo.ArgumentList.Add($argument)
	}
	$process = [Diagnostics.Process]::new()
	$process.StartInfo = $startInfo
	try {
		[void]$process.Start()
		$stdout = $process.StandardOutput.ReadToEndAsync()
		$stderr = $process.StandardError.ReadToEndAsync()
		$process.WaitForExit()
		return [pscustomobject]@{
			ExitCode = $process.ExitCode
			StdOut = $stdout.GetAwaiter().GetResult()
			StdErr = $stderr.GetAwaiter().GetResult()
		}
	} finally {
		$process.Dispose()
	}
}

function Assert-Issue57Dependencies {
	foreach ($command in @('docker', 'k6')) {
		if ($null -eq (Get-Command $command -ErrorAction SilentlyContinue)) {
			throw "필수 명령을 찾을 수 없습니다: $command"
		}
	}
	$composeVersion = Invoke-Issue57External -FilePath 'docker' -Arguments @('compose', 'version')
	if ($composeVersion.ExitCode -ne 0) {
		throw "docker compose를 사용할 수 없습니다: $($composeVersion.StdErr.Trim())"
	}
	$dockerInfo = Invoke-Issue57External -FilePath 'docker' -Arguments @('info', '--format', '{{.ServerVersion}}')
	if ($dockerInfo.ExitCode -ne 0) {
		throw "Docker Engine을 사용할 수 없습니다: $($dockerInfo.StdErr.Trim())"
	}
	$k6Version = Invoke-Issue57External -FilePath 'k6' -Arguments @('version')
	if ($k6Version.ExitCode -ne 0) {
		throw "k6를 사용할 수 없습니다: $($k6Version.StdErr.Trim())"
	}
}

function Get-Issue57DualServices {
	param([Parameter(Mandatory)] [string[]] $ComposeArguments)

	$networkName = "$($script:Issue57ProjectName)_default"
	$result = @()
	foreach ($service in @('api-1', 'api-2')) {
		$container = Invoke-Issue57External -FilePath 'docker' -Arguments ($ComposeArguments + @('ps', '-q', $service))
		$containerIds = @($container.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
		if ($container.ExitCode -ne 0 -or $containerIds.Count -ne 1 -or $containerIds[0] -notmatch '^[a-f0-9]{12,64}$') {
			throw "Compose 서비스 $service 컨테이너 ID를 정확히 하나 확인하지 못했습니다."
		}

		$template = '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{json .NetworkSettings.Networks}}'
		$inspection = Invoke-Issue57External -FilePath 'docker' -Arguments @('inspect', '--format', $template, $containerIds[0])
		$parts = @($inspection.StdOut.Trim() -split '\|', 3)
		if ($inspection.ExitCode -ne 0 -or $parts.Count -ne 3 -or
			$parts[0] -ne $script:Issue57ProjectName -or $parts[1] -ne $service) {
			throw "Compose 서비스 $service 컨테이너 label 검증에 실패했습니다."
		}
		$networks = $parts[2] | ConvertFrom-Json
		$network = @($networks.PSObject.Properties | Where-Object { $_.Name -eq $networkName })
		$parsedIp = $null
		$ip = if ($network.Count -eq 1) { [string]$network[0].Value.IPAddress } else { '' }
		if (-not [Net.IPAddress]::TryParse($ip, [ref]$parsedIp) -or
			$parsedIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
			throw "Compose 서비스 $service 프로젝트 네트워크 IPv4를 확인하지 못했습니다."
		}
		$result += [pscustomobject]@{
			service = $service
			containerId = $containerIds[0]
			network = $networkName
			ip = $ip
			upstream = "${ip}:8080"
		}
	}
	return $result
}

function Start-Issue57Stats {
	param(
		[ValidateSet('Single', 'Dual')] [string] $Mode,
		[Parameter(Mandatory)] [string] $ResultDirectory
	)

	$psResult = Invoke-Issue57External -FilePath 'docker' -Arguments (@(Get-Issue57ComposeArguments -Mode $Mode) + @('ps', '-q'))
	if ($psResult.ExitCode -ne 0) {
		throw "Compose 컨테이너 ID 조회 실패: $($psResult.StdErr.Trim())"
	}
	$containerIds = @($psResult.StdOut -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
	if ($containerIds.Count -eq 0) {
		throw 'docker stats를 수집할 현재 Compose 컨테이너가 없습니다.'
	}

	$arguments = @('stats', '--no-trunc', '--format', '{{.Container}},{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.NetIO}},{{.BlockIO}},{{.PIDs}}') + $containerIds
	return Start-Process -FilePath 'docker' -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput (Join-Path $ResultDirectory 'docker-stats.csv') -RedirectStandardError (Join-Path $ResultDirectory 'docker-stats.stderr.log') -PassThru
}

function Write-Issue57PeakEvidence {
	param(
		[Parameter(Mandatory)] [string] $RawJsonPath,
		[Parameter(Mandatory)] [string] $ResultDirectory
	)

	$peak = Get-Issue57PeakRps -RawJsonPath $RawJsonPath
	$peak | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ResultDirectory 'peak-rps.json') -Encoding utf8
	@(
		'# 초기 예약 요청 피크 RPS',
		'',
		'| 시나리오 | Peak RPS | UTC 초 |',
		'|---|---:|---|',
		"| Base | $($peak.Base.PeakRps) | $($peak.Base.Second) |",
		"| Stressed | $($peak.Stressed.PeakRps) | $($peak.Stressed.Second) |"
	) | Set-Content -LiteralPath (Join-Path $ResultDirectory 'peak-rps.md') -Encoding utf8
	if (-not (Test-Issue57PeakRpsRange -Peak $peak)) {
		throw "초기 예약 dispatch 피크 RPS가 범위를 벗어났습니다: Base $($peak.Base.PeakRps) (10~20), Stressed $($peak.Stressed.PeakRps) (50~100)"
	}
}

function Get-Issue57IntegritySql {
	param([Parameter(Mandatory)] $Slots)

	return @"
SELECT 'base' AS scenario, '$($Slots.Base)' AS expected_start_at,
       count(*) FILTER (WHERE status = 'CONFIRMED') AS confirmed_count,
       count(*) AS matching_count
FROM reservation
WHERE store_id = '$script:Issue57StoreId'
  AND assigned_staff_id = '$script:Issue57StaffId'
  AND start_at = TIMESTAMPTZ '$($Slots.Base)'
UNION ALL
SELECT 'stressed' AS scenario, '$($Slots.Stressed)' AS expected_start_at,
       count(*) FILTER (WHERE status = 'CONFIRMED') AS confirmed_count,
       count(*) AS matching_count
FROM reservation
WHERE store_id = '$script:Issue57StoreId'
  AND assigned_staff_id = '$script:Issue57StaffId'
  AND start_at = TIMESTAMPTZ '$($Slots.Stressed)';
"@
}

function Invoke-Issue57Mode {
	param(
		[ValidateSet('Single', 'Dual')] [string] $Mode,
		[Parameter(Mandatory)] $Slots
	)

	$timestamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmssfff')
	$resultDirectory = Join-Path (Join-Path $PSScriptRoot 'results') "$timestamp-$($Mode.ToLowerInvariant())"
	[void](New-Item -ItemType Directory -Path $resultDirectory -Force)
	$compose = @(Get-Issue57ComposeArguments -Mode $Mode)
	$failures = [Collections.Generic.List[string]]::new()
	$statsProcess = $null
	$statsProcessId = $null
	$dualServices = @()
	$k6ExitCode = $null
	$cleanupExitCode = $null
	$startedAt = [DateTimeOffset]::UtcNow
	$logsCaptured = $false

	Write-Host "[$Mode] 결과 경로: $resultDirectory"
	try {
		$preCleanup = Invoke-Issue57External -FilePath 'docker' -Arguments (Get-Issue57CleanupArguments -Mode $Mode)
		$preCleanup.StdOut | Set-Content -LiteralPath (Join-Path $resultDirectory 'pre-cleanup.stdout.log') -Encoding utf8
		$preCleanup.StdErr | Set-Content -LiteralPath (Join-Path $resultDirectory 'pre-cleanup.stderr.log') -Encoding utf8
		if ($preCleanup.ExitCode -ne 0) {
			[void]$failures.Add("startup cleanup exit $($preCleanup.ExitCode)")
			throw '초기 Compose 정리에 실패했습니다.'
		}

		$up = Invoke-Issue57External -FilePath 'docker' -Arguments ($compose + @('up', '-d', '--build', '--wait', '--wait-timeout', '240'))
		$up.StdOut | Set-Content -LiteralPath (Join-Path $resultDirectory 'compose-up.stdout.log') -Encoding utf8
		$up.StdErr | Set-Content -LiteralPath (Join-Path $resultDirectory 'compose-up.stderr.log') -Encoding utf8
		if ($up.ExitCode -ne 0) {
			[void]$failures.Add("startup exit $($up.ExitCode)")
			throw 'Compose가 240초 안에 정상 상태가 되지 못했습니다.'
		}

		$seed = Invoke-Issue57External -FilePath 'docker' -Arguments ($compose + @('exec', '-T', 'postgres', 'psql', '-v', 'ON_ERROR_STOP=1', '-U', 'jariyo', '-d', 'jariyo', '-f', '/fixtures/issue-57.sql'))
		$seed.StdOut | Set-Content -LiteralPath (Join-Path $resultDirectory 'fixture.stdout.log') -Encoding utf8
		$seed.StdErr | Set-Content -LiteralPath (Join-Path $resultDirectory 'fixture.stderr.log') -Encoding utf8
		if ($seed.ExitCode -ne 0) {
			[void]$failures.Add("seed exit $($seed.ExitCode)")
			throw 'fixture 적용에 실패했습니다.'
		}
		if ($Mode -eq 'Dual') {
			$dualServices = @(Get-Issue57DualServices -ComposeArguments $compose)
			$dualServices | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $resultDirectory 'dual-upstreams.json') -Encoding utf8
		}

		$statsProcess = Start-Issue57Stats -Mode $Mode -ResultDirectory $resultDirectory
		$statsProcessId = $statsProcess.Id
		$rawJsonPath = Join-Path $resultDirectory 'raw.json'
		$k6ResultDirectory = $resultDirectory.Replace('\', '/')
		$k6 = Invoke-Issue57External -FilePath 'k6' -Arguments @(
			'run', '--out', "json=$rawJsonPath",
			'-e', 'BASE_URL=http://localhost:8080',
			'-e', "BASE_START_AT=$($Slots.Base)",
			'-e', "STRESSED_START_AT=$($Slots.Stressed)",
			'-e', "RESULT_DIR=$k6ResultDirectory",
			(Join-Path $PSScriptRoot 'reservation-conflict.js')
		)
		$k6ExitCode = $k6.ExitCode
		$k6.StdOut | Set-Content -LiteralPath (Join-Path $resultDirectory 'k6.stdout.log') -Encoding utf8
		$k6.StdErr | Set-Content -LiteralPath (Join-Path $resultDirectory 'k6.stderr.log') -Encoding utf8
		if ($k6ExitCode -ne 0) {
			[void]$failures.Add("k6 exit $k6ExitCode")
		}

		try {
			Write-Issue57PeakEvidence -RawJsonPath $rawJsonPath -ResultDirectory $resultDirectory
		} catch {
			[void]$failures.Add("peak RPS analysis: $($_.Exception.Message)")
		}

		$sql = Get-Issue57IntegritySql -Slots $Slots
		$integrity = Invoke-Issue57External -FilePath 'docker' -Arguments ($compose + @('exec', '-T', 'postgres', 'psql', '--csv', '-v', 'ON_ERROR_STOP=1', '-U', 'jariyo', '-d', 'jariyo', '-c', $sql))
		$integrity.StdOut | Set-Content -LiteralPath (Join-Path $resultDirectory 'integrity.csv') -Encoding utf8
		$integrity.StdErr | Set-Content -LiteralPath (Join-Path $resultDirectory 'integrity.stderr.log') -Encoding utf8
		if ($integrity.ExitCode -ne 0) {
			[void]$failures.Add("integrity query exit $($integrity.ExitCode)")
		} else {
			$rows = @($integrity.StdOut | ConvertFrom-Csv)
			if (-not (Test-Issue57Integrity -Rows $rows)) {
				[void]$failures.Add('integrity expected exactly one matching CONFIRMED row for each slot')
			}
		}
	} catch {
		if ($failures.Count -eq 0 -or -not $failures[$failures.Count - 1].Contains($_.Exception.Message)) {
			[void]$failures.Add($_.Exception.Message)
		}
	} finally {
		$statsExitCode = $null
		try {
			try {
				$logs = Invoke-Issue57External -FilePath 'docker' -Arguments ($compose + @('logs', '--no-color', '--timestamps'))
				$logs.StdOut | Set-Content -LiteralPath (Join-Path $resultDirectory 'compose.log') -Encoding utf8
				$logs.StdErr | Set-Content -LiteralPath (Join-Path $resultDirectory 'compose-logs.stderr.log') -Encoding utf8
				$logsCaptured = $logs.ExitCode -eq 0
				if (-not $logsCaptured) {
					[void]$failures.Add("log capture exit $($logs.ExitCode)")
				}
				if ($Mode -eq 'Dual' -and $logsCaptured -and
					-not (Test-Issue57DualDistribution -NginxLog $logs.StdOut -Services $dualServices)) {
					[void]$failures.Add('dual Nginx access logs did not contain both resolved API upstream addresses')
				}
			} catch {
				[void]$failures.Add("log capture: $($_.Exception.Message)")
			}

			if ($null -ne $statsProcess) {
				try {
					$statsExitedBeforeStop = $statsProcess.HasExited
					if (-not $statsExitedBeforeStop) {
						$statsProcess.Kill()
						if (-not $statsProcess.WaitForExit(5000)) {
							[void]$failures.Add('stats collector did not exit within 5 seconds')
						}
					}
					if ($statsProcess.HasExited) {
						$statsExitCode = $statsProcess.ExitCode
					}
					if ($statsExitedBeforeStop) {
						[void]$failures.Add("stats collector exited early with code $statsExitCode")
					}
				} catch {
					[void]$failures.Add("stats stop: $($_.Exception.Message)")
				} finally {
					$statsProcess.Dispose()
				}
			}
		} finally {
			try {
				$cleanup = Invoke-Issue57External -FilePath 'docker' -Arguments (Get-Issue57CleanupArguments -Mode $Mode)
				$cleanupExitCode = $cleanup.ExitCode
				$cleanup.StdOut | Set-Content -LiteralPath (Join-Path $resultDirectory 'cleanup.stdout.log') -Encoding utf8
				$cleanup.StdErr | Set-Content -LiteralPath (Join-Path $resultDirectory 'cleanup.stderr.log') -Encoding utf8
				if ($cleanupExitCode -ne 0) {
					[void]$failures.Add("cleanup exit $cleanupExitCode")
				}
			} catch {
				[void]$failures.Add("cleanup: $($_.Exception.Message)")
			}
		}

		[ordered]@{
			mode = $Mode
			composeProject = $script:Issue57ProjectName
			startedAt = $startedAt.ToString('o')
			finishedAt = [DateTimeOffset]::UtcNow.ToString('o')
			baseStartAt = $Slots.Base
			stressedStartAt = $Slots.Stressed
			k6ExitCode = $k6ExitCode
			statsProcessId = $statsProcessId
			statsExitCode = $statsExitCode
			logsCaptured = $logsCaptured
			cleanupExitCode = $cleanupExitCode
			success = $failures.Count -eq 0
			failures = @($failures)
		} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $resultDirectory 'run-metadata.json') -Encoding utf8
	}

	if ($failures.Count -gt 0) {
		Write-Error "[$Mode] 실패: $($failures -join '; ')" -ErrorAction Continue
		return $false
	}
	Write-Host "[$Mode] 성공"
	return $true
}

function Invoke-Issue57Run {
	param([ValidateSet('Single', 'Dual', 'All')] [string] $Mode = 'All')

	Assert-Issue57Dependencies
	$environmentNames = @('JWT_ISSUER', 'JWT_AUDIENCE', 'JWT_PUBLIC_KEY', 'JWT_PRIVATE_KEY', 'POSTGRES_DB', 'POSTGRES_USER', 'POSTGRES_PASSWORD')
	$environment = @{}
	foreach ($name in $environmentNames) {
		$environment[$name] = [pscustomobject]@{
			Exists = Test-Path -LiteralPath "Env:$name"
			Value = [Environment]::GetEnvironmentVariable($name, 'Process')
		}
	}

	try {
		$pem = New-Issue57JwtPem
		$env:JWT_ISSUER = 'https://api.jariyo.local'
		$env:JWT_AUDIENCE = 'jariyo-web'
		$env:JWT_PUBLIC_KEY = $pem.Public
		$env:JWT_PRIVATE_KEY = $pem.Private
		$env:POSTGRES_DB = 'jariyo'
		$env:POSTGRES_USER = 'jariyo'
		$env:POSTGRES_PASSWORD = 'jariyo'

		$slots = Get-Issue57Slots
		$modes = if ($Mode -eq 'All') { @('Single', 'Dual') } else { @($Mode) }
		$success = $true
		foreach ($selectedMode in $modes) {
			if (-not (Invoke-Issue57Mode -Mode $selectedMode -Slots $slots)) {
				$success = $false
			}
		}
		return $(if ($success) { 0 } else { 1 })
	} finally {
		$pem = $null
		foreach ($name in $environmentNames) {
			if ($environment[$name].Exists) {
				[Environment]::SetEnvironmentVariable($name, $environment[$name].Value, 'Process')
			} else {
				[Environment]::SetEnvironmentVariable($name, $null, 'Process')
			}
		}
	}
}

if ($MyInvocation.InvocationName -ne '.') {
	try {
		exit (Invoke-Issue57Run -Mode $Mode)
	} catch {
		Write-Error $_.Exception.Message
		exit 1
	}
}
