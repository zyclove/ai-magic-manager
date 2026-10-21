param(
    [string]$JavaExecutable = 'C:\Program Files\Java\jdk-17\bin\java.exe',
    [string]$EvidenceDirectory = ''
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
if (!$EvidenceDirectory) {
    $EvidenceDirectory = Join-Path $repositoryRoot '.local/family-launch-20261015'
}
$cacheRoot = Join-Path $env:USERPROFILE '.gradle/caches/modules-2/files-2.1'
if (!(Test-Path -LiteralPath "$cacheRoot/org.jetbrains.kotlin/kotlin-compiler-embeddable/2.1.0")) {
    $cacheRoot = Join-Path $repositoryRoot '.local/child-gradle/caches/modules-2/files-2.1'
}

function Cached-Jars([string[]]$Coordinates) {
    foreach ($coordinate in $Coordinates) {
        $directory = Join-Path $cacheRoot $coordinate
        if (!(Test-Path -LiteralPath $directory)) { throw "Missing cached JVM dependency: $coordinate" }
        Get-ChildItem -LiteralPath $directory -Recurse -Filter '*.jar' | ForEach-Object FullName
    }
}

$compilerJars = @(Get-ChildItem -LiteralPath "$cacheRoot/org.jetbrains.kotlin" -Recurse -Filter '*.jar' |
    Where-Object { $_.FullName -match '\\2\.1\.0\\' } | ForEach-Object FullName)
$compilerJars += @(Cached-Jars @(
    'org.jetbrains.intellij.deps/trove4j/1.0.20200330',
    'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.9.0',
    'org.jetbrains/annotations/13.0'
))
$testJars = @(Cached-Jars @(
    'org.jetbrains.kotlin/kotlin-stdlib/2.1.0',
    'junit/junit/4.12',
    'org.hamcrest/hamcrest-core/1.3',
    'com.nimbusds/nimbus-jose-jwt/9.37.4'
))
$sourceDirectory = Join-Path $repositoryRoot 'apps/child/android/app/src/main/kotlin/com/aimanager/child/assisted'
$testDirectory = Join-Path $repositoryRoot 'apps/child/android/app/src/test/kotlin/com/aimanager/child/assisted'
$sources = @('AssistedEvaluator.kt', 'SignedAssistedConfiguration.kt', 'AssistedBackgroundSync.kt', 'AssistedConfigurationJournal.kt', 'InstalledBackgroundTransport.kt', 'AssistedServiceLifecycle.kt', 'AssistedUsageSynchronizer.kt' |
    ForEach-Object { Join-Path $sourceDirectory $_ } | Where-Object { Test-Path -LiteralPath $_ })
$tests = @(Get-ChildItem -LiteralPath $testDirectory -File |
    Where-Object { $_.Name -like 'Assisted*Test.kt' -or $_.Name -like 'SignedAssisted*Test.kt' })
if (!$tests.Count) { throw 'No assisted JVM tests found.' }
$testClasses = @($tests | ForEach-Object { "com.aimanager.child.assisted.$($_.BaseName)" })
New-Item -ItemType Directory -Path $EvidenceDirectory -Force | Out-Null
$targetJar = Join-Path $EvidenceDirectory 'assisted-native-tests.jar'
$compileLog = Join-Path $EvidenceDirectory 'assisted-native-compile.log'
$testLog = Join-Path $EvidenceDirectory 'assisted-native-tests.log'
& $JavaExecutable -cp ($compilerJars -join ';') org.jetbrains.kotlin.cli.jvm.K2JVMCompiler `
    -no-stdlib -no-reflect -jvm-target 17 -classpath ($testJars -join ';') `
    -d $targetJar @sources @($tests.FullName) *> $compileLog
if ($LASTEXITCODE -ne 0) {
    Get-Content -LiteralPath $compileLog
    exit $LASTEXITCODE
}
& $JavaExecutable -cp ((@($targetJar) + $testJars) -join ';') org.junit.runner.JUnitCore `
    @testClasses *> $testLog
$testExitCode = $LASTEXITCODE
Get-Content -LiteralPath $testLog
exit $testExitCode
