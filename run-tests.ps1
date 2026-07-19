<#
.SYNOPSIS
Builds the Docker image once (which also pre-compiles the app + tests and
warms the Maven plugin cache — see Dockerfile), then runs each JUnit 5
test target in its own brand-new, ephemeral container (docker run --rm),
IN PARALLEL. Each container calls the surefire:test goal directly against
the classes already baked into the image, so no container ever runs
`mvn compile` itself. Each invocation of `docker run` still starts a
fresh container from the built image, so every test target gets a fully
reset container (clean filesystem, clean JVM, no state left over from
any other test) — they just all run at the same time instead of one
after another.
#>

$ErrorActionPreference = "Stop"

# Always run relative to this script's location (the project root),
# regardless of the working directory this was invoked from.
$scriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
Set-Location $scriptRoot

$IMAGE_NAME = "simple-app-tests"

Write-Host "==> Building Docker image (${IMAGE_NAME})..."
docker build -t $IMAGE_NAME .
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker build failed"
    exit 1
}

Write-Host "==> Discovering test targets..."
$TEST_TARGETS = @()

if (Test-Path "src\test\java") {
    Get-ChildItem -Path "src\test\java" -Filter "*Test.java" -Recurse | ForEach-Object {
        $relativePath = $_.FullName -replace [regex]::Escape((Get-Item "src\test\java").FullName), ""
        $relativePath = $relativePath -replace "^[\\/]", ""
        $className = $relativePath -replace "\.java$", "" -replace "\\", "."
        $className = $className -replace "/", "."

        $lines = Get-Content -Path $_.FullName
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^\s*(?:public|protected|private)?\s*(?:static\s+)?(?:final\s+)?(?:[\w<>\[\],?]+\s+)+(\w+)\s*\(') {
                $methodName = $matches[1]

                $annotations = @()
                $cursor = $index - 1
                while ($cursor -ge 0) {
                    $trimmed = $lines[$cursor].Trim()
                    if ([string]::IsNullOrWhiteSpace($trimmed)) {
                        break
                    }
                    if ($trimmed.StartsWith("//") -or $trimmed.StartsWith("/*") -or $trimmed.StartsWith("*") -or $trimmed.StartsWith("*/")) {
                        $cursor--
                        continue
                    }
                    if ($trimmed.StartsWith("@") -or $trimmed.StartsWith("{") -or $trimmed.StartsWith("}") -or $trimmed.StartsWith(")") -or $trimmed.StartsWith(",") -or $trimmed.StartsWith('"')) {
                        $annotations += $trimmed
                        $cursor--
                        continue
                    }
                    break
                }

                $annotationLines = @($annotations | Select-Object -Last ($annotations.Count))
                if ($annotations.Count -gt 0) {
                    $annotationLines = @($annotations | Select-Object -Reverse)
                }
                $annotationText = $annotationLines -join "`n"

                if ($annotationText -notmatch '@Test' -and $annotationText -notmatch '@ParameterizedTest') {
                    continue
                }

                if ($annotationText -match '@ParameterizedTest' -and $annotationText -match '@CsvSource') {
                    $sourceBlock = $annotationText.Split('@CsvSource', 2)[1]
                    $invocationCount = @([regex]::Matches($sourceBlock, '"[^"]*"') | ForEach-Object { $_.Value } | Select-Object -Unique).Count
                } elseif ($annotationText -match '@ParameterizedTest' -and $annotationText -match '@ValueSource') {
                    $sourceBlock = $annotationText.Split('@ValueSource', 2)[1]
                    $invocationCount = @([regex]::Matches($sourceBlock, '"[^"]*"') | ForEach-Object { $_.Value } | Select-Object -Unique).Count
                } else {
                    $invocationCount = 1
                }

                for ($invocation = 1; $invocation -le $invocationCount; $invocation++) {
                    if ($invocationCount -gt 1) {
                        $TEST_TARGETS += "$className#$methodName[$invocation]"
                    } else {
                        $TEST_TARGETS += "$className#$methodName"
                    }
                }
            }
        }
    }
}

if ($TEST_TARGETS.Count -eq 0) {
    Write-Host "No test targets found."
    exit 1
}

$LOG_DIR = Join-Path ([System.IO.Path]::GetTempPath()) ("simple-app-tests-" + [System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
$jobs = @{}
$RUN_TARGETS = @()

Write-Host ""
Write-Host "==> Launching fresh, isolated containers in parallel..."

foreach ($TARGET in $TEST_TARGETS) {
    $RUN_TARGETS += $TARGET
    Write-Host "==> Starting container for: ${TARGET}"

    $job = Start-Job -ScriptBlock {
        param($ImageName, $TargetName, $LogDir)

        $logFile = Join-Path $LogDir ("{0}.log" -f $TargetName)
        $exitFile = Join-Path $LogDir ("{0}.exit" -f $TargetName)

        try {
            docker run --rm $ImageName `
                mvn -q -B -o surefire:test -Dtest="$TargetName" `
                -Dskip.local.tests=false -Dexec.skip=true `
                *> $logFile

            $exitCode = $LASTEXITCODE
        } catch {
            $exitCode = 1
        }

        Set-Content -Path $exitFile -Value $exitCode
    } -ArgumentList $IMAGE_NAME, $TARGET, $LOG_DIR

    $jobs[$TARGET] = $job
}

Write-Host "==> Waiting for all containers to finish..."
foreach ($TARGET in $RUN_TARGETS) {
    if ($jobs.ContainsKey($TARGET)) {
        Wait-Job -Job $jobs[$TARGET] | Out-Null
    }
}

$FAILED = 0

Write-Host ""
Write-Host "==> Results"
Write-Host "----------------------------------------"

foreach ($TARGET in $RUN_TARGETS) {
    $exitFile = Join-Path $LOG_DIR ("{0}.exit" -f $TARGET)
    $logFile = Join-Path $LOG_DIR ("{0}.log" -f $TARGET)

    $EXIT_CODE = 1
    if (Test-Path $exitFile) {
        $EXIT_CODE = [int](Get-Content $exitFile)
    }

    Write-Host ""
    Write-Host "----- ${TARGET} -----"
    if (Test-Path $logFile) {
        Get-Content $logFile
    }

    if ($EXIT_CODE -eq 0) {
        Write-Host "==> ${TARGET} PASSED"
    } else {
        Write-Host "==> ${TARGET} FAILED"
        $FAILED = 1
    }
}

Write-Host ""
if ($FAILED -eq 0) {
    Write-Host "All tests passed (each in its own freshly reset container, run in parallel)."
} else {
    Write-Host "Some tests failed."
    exit 1
}

# Cleanup
Remove-Item -Path $LOG_DIR -Recurse -Force -ErrorAction SilentlyContinue
