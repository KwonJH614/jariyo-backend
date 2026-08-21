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

function Assert-Equal {
	param($Expected, $Actual, [string] $Message)

	if ($Expected -ne $Actual) {
		throw "$Message (expected='$Expected', actual='$Actual')"
	}
}

$requiredFunctions = @(
	'Get-Issue57ComposeFiles',
	'Get-Issue57Slots',
	'Get-Issue57PeakRps',
	'Test-Issue57Integrity',
	'Test-Issue57DualDistribution',
	'Get-Issue57CleanupArguments',
	'New-Issue57JwtPem'
)
foreach ($functionName in $requiredFunctions) {
	Assert-True ($null -ne (Get-Command $functionName -ErrorAction SilentlyContinue)) "runner function is missing: $functionName"
}

$singleFiles = @(Get-Issue57ComposeFiles -Mode Single)
$dualFiles = @(Get-Issue57ComposeFiles -Mode Dual)
Assert-Equal 1 $singleFiles.Count 'Single must select only the base Compose file'
Assert-Equal 'compose.yaml' (Split-Path -Leaf $singleFiles[0]) 'Single base Compose file is wrong'
Assert-Equal 2 $dualFiles.Count 'Dual must select base and override Compose files'
Assert-Equal 'compose.yaml' (Split-Path -Leaf $dualFiles[0]) 'Dual base Compose file is wrong'
Assert-Equal 'compose.dual.yaml' (Split-Path -Leaf $dualFiles[1]) 'Dual override Compose file is wrong'

$now = [DateTimeOffset]::Parse('2026-08-21T23:30:00-04:00')
$slots = Get-Issue57Slots -Now $now
Assert-Equal '2026-08-24T14:00:00+09:00' $slots.Base 'Base must be 14:00 two KST calendar days ahead'
Assert-Equal '2026-08-24T15:00:00+09:00' $slots.Stressed 'Stressed must be 15:00 two KST calendar days ahead'
Assert-True ($slots.Base -ne $slots.Stressed) 'Base and Stressed slots must be distinct'

$rawPath = [IO.Path]::GetTempFileName()
try {
	@(
		'{"type":"Point","metric":"http_reqs","data":{"time":"2026-08-24T05:00:00.100Z","value":1,"tags":{"scenario":"base","attempt":"initial"}}}',
		'{"type":"Point","metric":"http_reqs","data":{"time":"2026-08-24T05:00:00.900Z","value":1,"tags":{"scenario":"base","attempt":"initial"}}}',
		'{"type":"Point","metric":"http_reqs","data":{"time":"2026-08-24T05:00:01.000Z","value":1,"tags":{"scenario":"base","attempt":"initial"}}}',
		'{"type":"Point","metric":"http_reqs","data":{"time":"2026-08-24T05:00:00.500Z","value":50,"tags":{"phase":"setup"}}}',
		'{"type":"Point","metric":"http_reqs","data":{"time":"2026-08-24T06:00:00.100Z","value":1,"tags":{"scenario":"stressed","attempt":"initial"}}}',
		'{"type":"Point","metric":"http_reqs","data":{"time":"2026-08-24T06:00:00.200Z","value":1,"tags":{"scenario":"stressed","attempt":"initial"}}}',
		'{"type":"Point","metric":"http_reqs","data":{"time":"2026-08-24T06:00:00.300Z","value":1,"tags":{"scenario":"stressed","attempt":"initial"}}}',
		'{"type":"Point","metric":"http_reqs","data":{"time":"2026-08-24T06:00:00.400Z","value":99,"tags":{"scenario":"stressed","attempt":"retry"}}}'
	) | Set-Content -LiteralPath $rawPath -Encoding utf8
	$peak = Get-Issue57PeakRps -RawJsonPath $rawPath
	Assert-Equal 2 $peak.Base.PeakRps 'Base peak RPS must group initial requests by second'
	Assert-Equal 3 $peak.Stressed.PeakRps 'Stressed peak RPS must exclude retry requests'
} finally {
	Remove-Item -LiteralPath $rawPath -Force
}

$validRows = @(
	[pscustomobject]@{ scenario = 'base'; confirmed_count = '1' },
	[pscustomobject]@{ scenario = 'stressed'; confirmed_count = '1' }
)
Assert-True (Test-Issue57Integrity -Rows $validRows) 'one confirmed row for both slots must pass'
Assert-True (-not (Test-Issue57Integrity -Rows @($validRows[0]))) 'a missing slot must fail integrity'
$invalidRows = @($validRows[0], [pscustomobject]@{ scenario = 'stressed'; confirmed_count = '2' })
Assert-True (-not (Test-Issue57Integrity -Rows $invalidRows)) 'more than one confirmed row must fail integrity'

$dualServices = @(
	[pscustomobject]@{ service = 'api-1'; upstream = '172.29.0.3:8080' },
	[pscustomobject]@{ service = 'api-2'; upstream = '172.29.0.4:8080' }
)
$distributedLog = @'
nginx-1 | request upstream=172.29.0.3:8080 status=201
nginx-1 | request upstream=172.29.0.4:8080 status=409
'@
Assert-True (Test-Issue57DualDistribution -NginxLog $distributedLog -Services $dualServices) 'resolved upstream IPs for both API services must pass'
$oneUpstreamLog = 'nginx-1 | request upstream=172.29.0.3:8080 status=201'
Assert-True (-not (Test-Issue57DualDistribution -NginxLog $oneUpstreamLog -Services $dualServices)) 'a missing resolved upstream IP must fail distribution'

$cleanup = @(Get-Issue57CleanupArguments -Mode Dual)
$projectIndex = [Array]::IndexOf($cleanup, '--project-name')
Assert-True ($projectIndex -ge 0) 'cleanup must set an explicit Compose project'
Assert-Equal 'jariyo-issue-57' $cleanup[$projectIndex + 1] 'cleanup project must stay scoped to issue 57'
Assert-Equal 'down' $cleanup[$cleanup.Count - 3] 'cleanup action must be down'
Assert-Equal '-v' $cleanup[$cleanup.Count - 2] 'cleanup must remove only this project volume'
Assert-Equal '--remove-orphans' $cleanup[$cleanup.Count - 1] 'cleanup must remove only this project orphans'
Assert-True (-not ($cleanup -contains 'prune')) 'cleanup must never use Docker prune'

$pemOutput = @(& { $script:pem = New-Issue57JwtPem })
Assert-Equal 0 $pemOutput.Count 'RSA generation must not print key material'
Assert-True $pem.Public.StartsWith('-----BEGIN PUBLIC KEY-----\n') 'public key must use X.509 PEM and literal newlines'
Assert-True $pem.Private.StartsWith('-----BEGIN PRIVATE KEY-----\n') 'private key must use PKCS#8 PEM and literal newlines'
Assert-True (-not $pem.Public.Contains("`n")) 'public PEM must not contain real newlines'
Assert-True (-not $pem.Private.Contains("`n")) 'private PEM must not contain real newlines'
Assert-True (-not $pem.Public.Contains('PRIVATE KEY')) 'public material must not contain private key data'

Write-Output 'PASS: 7 focused runner behavior groups'
