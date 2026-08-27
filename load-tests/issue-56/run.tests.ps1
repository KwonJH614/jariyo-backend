$ErrorActionPreference = 'Stop'

$runnerPath = Join-Path $PSScriptRoot 'run.ps1'
if (Test-Path -LiteralPath $runnerPath) {
	. $runnerPath
}

function Assert-True {
	param([bool] $Condition, [string] $Message)

	if (-not $Condition) {
		throw $Message
	}
}

function Assert-False {
	param([bool] $Condition, [string] $Message)

	if ($Condition) {
		throw $Message
	}
}

function Assert-Equal {
	param($Expected, $Actual, [string] $Message)

	if ($Expected -ne $Actual) {
		throw "$Message (expected='$Expected', actual='$Actual')"
	}
}

$requiredFunctions = @(
	'Get-Issue56ComposeFiles',
	'Get-Issue56PeakRps',
	'ConvertTo-Issue56UtcSecond',
	'Test-Issue56PeakRpsRange',
	'Test-Issue56Integrity',
	'Test-Issue56DualDistribution',
	'Get-Issue56CleanupArguments',
	'New-Issue56JwtPem',
	'Resolve-Issue56K6Path'
)
foreach ($functionName in $requiredFunctions) {
	Assert-True ($null -ne (Get-Command $functionName -ErrorAction SilentlyContinue)) "runner function is missing: $functionName"
}

$k6Path = Resolve-Issue56K6Path
Assert-True (Test-Path -LiteralPath $k6Path -PathType Leaf) 'resolved k6 executable must exist'
Assert-Equal 'k6.exe' (Split-Path -Leaf $k6Path) 'resolved executable must be k6.exe on Windows'

$singleFiles = @(Get-Issue56ComposeFiles -Mode Single)
$dualFiles = @(Get-Issue56ComposeFiles -Mode Dual)
Assert-Equal 1 $singleFiles.Count 'Single must select only the base Compose file'
Assert-Equal 'compose.yaml' (Split-Path -Leaf $singleFiles[0]) 'Single base Compose file is wrong'
Assert-Equal 2 $dualFiles.Count 'Dual must select base and override Compose files'
Assert-Equal 'compose.yaml' (Split-Path -Leaf $dualFiles[0]) 'Dual base Compose file is wrong'
Assert-Equal 'compose.dual.yaml' (Split-Path -Leaf $dualFiles[1]) 'Dual override Compose file is wrong'

Assert-Equal '2026-08-24T05:00:00Z' (ConvertTo-Issue56UtcSecond -Value ([DateTimeOffset]::Parse('2026-08-24T14:00:00.900+09:00'))) 'DateTimeOffset must preserve its instant'
Assert-Equal '2026-08-24T05:00:00Z' (ConvertTo-Issue56UtcSecond -Value '2026-08-24T14:00:00.900+09:00') 'string timestamp must preserve its explicit offset'

$rawPath = [IO.Path]::GetTempFileName()
try {
	$rawLines = [Collections.Generic.List[string]]::new()
	foreach ($millisecond in 1..8) {
		$time = "2026-08-24T05:00:00.$($millisecond.ToString('000'))Z"
		[void]$rawLines.Add("{`"type`":`"Point`",`"metric`":`"walk_in_poll_started`",`"data`":{`"time`":`"$time`",`"value`":1,`"tags`":{`"scenario`":`"base`"}}}")
	}
	foreach ($millisecond in 1..90) {
		$time = "2026-08-24T06:00:00.$($millisecond.ToString('000'))Z"
		[void]$rawLines.Add("{`"type`":`"Point`",`"metric`":`"walk_in_poll_started`",`"data`":{`"time`":`"$time`",`"value`":1,`"tags`":{`"scenario`":`"stressed`"}}}")
	}
	[void]$rawLines.Add('{"type":"Point","metric":"walk_in_poll_started","data":{"time":"2026-08-24T05:00:01.000Z","value":1,"tags":{"scenario":"base"}}}')
	[void]$rawLines.Add('{"type":"Point","metric":"http_reqs","data":{"time":"2026-08-24T05:00:00.500Z","value":1,"tags":{"scenario":"base"}}}')
	[void]$rawLines.Add('{"type":"Point","metric":"walk_in_poll_started","data":{"time":"2026-08-24T06:00:00.400Z","value":1,"tags":{"scenario":"operator"}}}')
	$rawLines | Set-Content -LiteralPath $rawPath -Encoding utf8
	$peak = Get-Issue56PeakRps -RawJsonPath $rawPath
	Assert-Equal 8 $peak.Base.PeakRps 'Base peak RPS must use polling dispatch points'
	Assert-Equal 90 $peak.Stressed.PeakRps 'Stressed peak RPS must exclude operator requests'
	Assert-Equal '2026-08-24T05:00:00Z' $peak.Base.Second 'Base peak second must preserve the original UTC instant'
	Assert-True (Test-Issue56PeakRpsRange -Peak $peak) '8/90 RPS must satisfy the issue ranges'

	$peak.Base.PeakRps = 7
	Assert-False (Test-Issue56PeakRpsRange -Peak $peak) 'Base below 8 RPS must fail'
	$peak.Base.PeakRps = 8
	$peak.Stressed.PeakRps = 101
	Assert-False (Test-Issue56PeakRpsRange -Peak $peak) 'Stressed above 100 RPS must fail'
} finally {
	Remove-Item -LiteralPath $rawPath -Force
}

$validIntegrity = @([pscustomobject]@{
	total_count = 180
	distinct_queue_count = 180
	active_count = 178
	checked_in_count = 2
	restored_waiting_count = 2
	invalid_transition_count = 0
})
Assert-True (Test-Issue56Integrity -Rows $validIntegrity) 'expected final walk-in state must pass integrity validation'

$duplicateQueue = @([pscustomobject]@{
	total_count = 180
	distinct_queue_count = 179
	active_count = 178
	checked_in_count = 2
	restored_waiting_count = 2
	invalid_transition_count = 0
})
Assert-False (Test-Issue56Integrity -Rows $duplicateQueue) 'duplicate queue numbers must fail integrity validation'

$invalidTransition = @([pscustomobject]@{
	total_count = 180
	distinct_queue_count = 180
	active_count = 178
	checked_in_count = 2
	restored_waiting_count = 2
	invalid_transition_count = 1
})
Assert-False (Test-Issue56Integrity -Rows $invalidTransition) 'unexpected transition history must fail integrity validation'

$integritySql = Get-Issue56IntegritySql
Assert-True ($integritySql -match 'history\.previous_status') 'integrity SQL must use the migration previous_status column'
Assert-True ($integritySql -match 'history\.new_status') 'integrity SQL must use the migration new_status column'
Assert-False ($integritySql -match 'history\.next_status') 'integrity SQL must not reference a nonexistent next_status column'

$services = @(
	[pscustomobject]@{ service = 'api-1'; upstream = '172.30.0.2:8080' },
	[pscustomobject]@{ service = 'api-2'; upstream = '172.30.0.3:8080' }
)
$bothUpstreams = "request=/api/v1/walk-ins/a upstream=172.30.0.2:8080`nrequest=/api/v1/walk-ins/b upstream=172.30.0.3:8080"
Assert-True (Test-Issue56DualDistribution -NginxLog $bothUpstreams -Services $services) 'Dual logs must contain both API upstreams'
Assert-False (Test-Issue56DualDistribution -NginxLog 'request=/api/v1/walk-ins/a upstream=172.30.0.2:8080' -Services $services) 'Dual logs missing one API upstream must fail'

$cleanup = @(Get-Issue56CleanupArguments -Mode Dual)
Assert-True ($cleanup -contains '--project-name') 'cleanup must be scoped to a Compose project'
Assert-True ($cleanup -contains 'jariyo-issue-56') 'cleanup must use the issue-specific project'
Assert-True ($cleanup -contains 'down') 'cleanup must use docker compose down'
Assert-True ($cleanup -contains '-v') 'cleanup must remove only the issue project volume'
Assert-True ($cleanup -contains '--remove-orphans') 'cleanup must remove only issue project orphans'

$pem = New-Issue56JwtPem
try {
	Assert-True ($pem.Public -match '^-----BEGIN PUBLIC KEY-----\\n') 'public key must be SubjectPublicKeyInfo PEM with literal newlines'
	Assert-True ($pem.Private -match '^-----BEGIN PRIVATE KEY-----\\n') 'private key must be PKCS#8 PEM with literal newlines'
	Assert-False ($pem.Public -match "`r|`n") 'public key must not contain physical newlines'
	Assert-False ($pem.Private -match "`r|`n") 'private key must not contain physical newlines'
} finally {
	$pem = $null
}

Write-Host 'Issue #56 runner focused tests passed.'
