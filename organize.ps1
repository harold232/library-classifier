#requires -Version 5.1
<#
.SYNOPSIS
Organiza una biblioteca leyendo automáticamente config.json.

.USO
    .\organize-config.ps1
    .\organize-config.ps1 -UndoLast
    .\organize-config.ps1 -ConfigPath ".\config.json"
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json"),
    [switch]$UndoLast
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-ProjectPath {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$BaseDirectory
    )

    if ([IO.Path]::IsPathRooted($Value)) {
        return [IO.Path]::GetFullPath($Value)
    }

    return [IO.Path]::GetFullPath((Join-Path $BaseDirectory $Value))
}

function Get-NormalizedText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }

    $decomposed = $Text.Normalize([Text.NormalizationForm]::FormD)
    $builder = New-Object Text.StringBuilder

    foreach ($character in $decomposed.ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)

        if ($category -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($character)
        }
    }

    $normalized = $builder.ToString().Normalize(
        [Text.NormalizationForm]::FormC
    ).ToLowerInvariant()

    $normalized = [Regex]::Replace($normalized, "[^\p{L}\p{N}]+", " ")
    return [Regex]::Replace($normalized.Trim(), "\s+", " ")
}

function Test-TermMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Term
    )

    if ([string]::IsNullOrWhiteSpace($Term)) {
        return $false
    }

    $escapedTerm = [Regex]::Escape($Term)
    $pattern = "(?<![\p{L}\p{N}])" + $escapedTerm + "(?![\p{L}\p{N}])"
    return [Regex]::IsMatch(
        $Text,
        $pattern,
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
}

function Get-UniqueTargetPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $Path
    }

    $directory = Split-Path -Parent $Path
    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    $extension = [IO.Path]::GetExtension($Path)
    $counter = 2

    do {
        $candidate = Join-Path $directory ("{0} ({1}){2}" -f $name, $counter, $extension)
        $counter++
    } while (Test-Path -LiteralPath $candidate)

    return $candidate
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $candidateFull = [IO.Path]::GetFullPath($Candidate).TrimEnd("\", "/")
    $parentFull = [IO.Path]::GetFullPath($Parent).TrimEnd("\", "/")
    $prefix = $parentFull + [IO.Path]::DirectorySeparatorChar

    return $candidateFull.Equals(
        $parentFull,
        [StringComparison]::OrdinalIgnoreCase
    ) -or $candidateFull.StartsWith(
        $prefix,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Import-Rules {
    param([Parameter(Mandatory = $true)][string]$RulesPath)

    if (-not (Test-Path -LiteralPath $RulesPath -PathType Container)) {
        throw "No existe la carpeta de reglas: $RulesPath"
    }

    $files = @(
        Get-ChildItem -LiteralPath $RulesPath -Filter "rules-*.json" -File |
        Sort-Object Name
    )

    if ($files.Count -eq 0) {
        throw "No se encontraron archivos rules-*.json en: $RulesPath"
    }

    $allRules = New-Object System.Collections.Generic.List[object]
    $sequence = 0

    foreach ($file in $files) {
        try {
            $data = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 |
                ConvertFrom-Json
        }
        catch {
            throw "JSON inválido en '$($file.FullName)': $($_.Exception.Message)"
        }

        foreach ($categoryProperty in $data.PSObject.Properties) {
            foreach ($rule in @($categoryProperty.Value)) {
                if ([string]::IsNullOrWhiteSpace([string]$rule.folder)) {
                    Write-Warning "Regla sin folder omitida en $($file.Name)."
                    continue
                }

                $keywords = @()

                if ($null -ne $rule.keywords) {
                    $keywords = @(
                        @($rule.keywords) |
                        ForEach-Object {
                            Get-NormalizedText ([string]$_)
                        } |
                        Where-Object {
                            -not [string]::IsNullOrWhiteSpace($_)
                        } |
                        Select-Object -Unique
                    )
                }

                $authors = @()

                if ($null -ne $rule.authors) {
                    $authors = @(
                        @($rule.authors) |
                        ForEach-Object {
                            Get-NormalizedText ([string]$_)
                        } |
                        Where-Object {
                            -not [string]::IsNullOrWhiteSpace($_)
                        } |
                        Select-Object -Unique
                    )
                }

                if (($keywords.Count + $authors.Count) -eq 0) {
                    continue
                }

                $sequence++
                $priority = if ($null -eq $rule.priority) { 0 } else { [int]$rule.priority }

                $allRules.Add([PSCustomObject]@{
                    Category = [string]$categoryProperty.Name
                    Folder = ([string]$rule.folder).Trim().Replace("\", "/")
                    Priority = $priority
                    Keywords = $keywords
                    Authors = $authors
                    RuleFile = $file.Name
                    Sequence = $sequence
                })
            }
        }
    }

    return $allRules.ToArray()
}

function Find-BestRule {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][object[]]$Rules
    )

    $text = Get-NormalizedText $FileName
    $matches = New-Object System.Collections.Generic.List[object]

    foreach ($rule in $Rules) {
        $keywordMatches = @(
            $rule.Keywords |
            Where-Object { Test-TermMatch -Text $text -Term $_ }
        )

        $authorMatches = @(
            $rule.Authors |
            Where-Object { Test-TermMatch -Text $text -Term $_ }
        )

        $totalMatches = $keywordMatches.Count + $authorMatches.Count

        if ($totalMatches -eq 0) {
            continue
        }

        $matchedLength = 0
        foreach ($term in @($keywordMatches + $authorMatches)) {
            $matchedLength += $term.Length
        }

        $score = (
            ([long]$rule.Priority * 1000000000L) +
            ([long]$authorMatches.Count * 1000000L) +
            ([long]$totalMatches * 1000L) +
            [long]$matchedLength
        )

        $matches.Add([PSCustomObject]@{
            Rule = $rule
            Score = $score
            KeywordMatches = $keywordMatches
            AuthorMatches = $authorMatches
        })
    }

    return $matches |
        Sort-Object `
            @{ Expression = "Score"; Descending = $true },
            @{ Expression = { $_.Rule.Sequence }; Descending = $false } |
        Select-Object -First 1
}

function Undo-LastMove {
    param([Parameter(Mandatory = $true)][string]$LogPath)

    $lastLog = Get-ChildItem -LiteralPath $LogPath -Filter "organize-move-*.csv" -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $lastLog) {
        throw "No hay un log de movimiento para deshacer."
    }

    $rows = @(
        Import-Csv -LiteralPath $lastLog.FullName |
        Where-Object {
            $_.Operation -eq "Move" -and
            $_.Status -in @("Matched", "Unmatched")
        }
    )

    if ($rows.Count -eq 0) {
        throw "El último log no contiene movimientos reversibles."
    }

    $undoRows = New-Object System.Collections.Generic.List[object]
    $index = 0

    foreach ($row in @($rows | Select-Object -Reverse)) {
        $index++
        Write-Progress `
            -Activity "Deshaciendo último movimiento" `
            -Status "$index de $($rows.Count)" `
            -PercentComplete ([int](100 * $index / $rows.Count))

        try {
            if (-not (Test-Path -LiteralPath $row.Target -PathType Leaf)) {
                throw "No existe: $($row.Target)"
            }

            $originalDirectory = Split-Path -Parent $row.Source
            [void](New-Item -ItemType Directory -Path $originalDirectory -Force)

            $restorePath = Get-UniqueTargetPath $row.Source
            Move-Item -LiteralPath $row.Target -Destination $restorePath

            $undoRows.Add([PSCustomObject]@{
                Timestamp = (Get-Date).ToString("s")
                Status = "Restored"
                From = $row.Target
                To = $restorePath
                Error = ""
            })
        }
        catch {
            $undoRows.Add([PSCustomObject]@{
                Timestamp = (Get-Date).ToString("s")
                Status = "Error"
                From = $row.Target
                To = $row.Source
                Error = $_.Exception.Message
            })
        }
    }

    Write-Progress -Activity "Deshaciendo último movimiento" -Completed

    $undoLog = Join-Path $LogPath ("undo-{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    $undoRows | Export-Csv -LiteralPath $undoLog -NoTypeInformation -Encoding UTF8

    Write-Host "Movimiento deshecho."
    Write-Host "Log: $undoLog"
}

# ----------------------------------------------------------------------
# 1. LECTURA EXPLÍCITA DE config.json
# ----------------------------------------------------------------------

$configFullPath = [IO.Path]::GetFullPath($ConfigPath)

Write-Host ""
Write-Host "Leyendo configuración:"
Write-Host "  $configFullPath"

if (-not (Test-Path -LiteralPath $configFullPath -PathType Leaf)) {
    throw "No existe config.json en: $configFullPath"
}

try {
    $config = Get-Content -LiteralPath $configFullPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    throw "No se pudo leer config.json: $($_.Exception.Message)"
}

$requiredProperties = @("SourcePath", "DestinationPath")

foreach ($propertyName in $requiredProperties) {
    if (
        $null -eq $config.PSObject.Properties[$propertyName] -or
        [string]::IsNullOrWhiteSpace([string]$config.$propertyName)
    ) {
        throw "Falta '$propertyName' en config.json."
    }
}

$configDirectory = Split-Path -Parent $configFullPath

$sourcePath = Resolve-ProjectPath -Value ([string]$config.SourcePath) -BaseDirectory $configDirectory
$destinationPath = Resolve-ProjectPath -Value ([string]$config.DestinationPath) -BaseDirectory $configDirectory

$rulesValue = if ($null -ne $config.PSObject.Properties["RulesPath"]) {
    [string]$config.RulesPath
} else {
    ".\rules"
}

$logValue = if ($null -ne $config.PSObject.Properties["LogPath"]) {
    [string]$config.LogPath
} else {
    ".\logs"
}

$rulesPath = Resolve-ProjectPath -Value $rulesValue -BaseDirectory $configDirectory
$logPath = Resolve-ProjectPath -Value $logValue -BaseDirectory $configDirectory

$simulation = if ($null -ne $config.PSObject.Properties["Simulation"]) {
    [bool]$config.Simulation
} else {
    $true
}

$copy = if ($null -ne $config.PSObject.Properties["Copy"]) {
    [bool]$config.Copy
} else {
    $false
}

$recurse = if ($null -ne $config.PSObject.Properties["Recurse"]) {
    [bool]$config.Recurse
} else {
    $true
}

$includeNonPdf = if ($null -ne $config.PSObject.Properties["IncludeNonPdf"]) {
    [bool]$config.IncludeNonPdf
} else {
    $false
}

$createFolders = if ($null -ne $config.PSObject.Properties["CreateFolders"]) {
    [bool]$config.CreateFolders
} else {
    $true
}

$unmatchedFolder = if ($null -ne $config.PSObject.Properties["UnmatchedFolder"]) {
    [string]$config.UnmatchedFolder
} else {
    "Archive/Unmatched"
}

[void](New-Item -ItemType Directory -Path $logPath -Force)

Write-Host "Configuración cargada correctamente:"
Write-Host "  SourcePath:       $sourcePath"
Write-Host "  DestinationPath:  $destinationPath"
Write-Host "  RulesPath:        $rulesPath"
Write-Host "  LogPath:          $logPath"
Write-Host "  Simulation:       $simulation"
Write-Host "  Copy:             $copy"
Write-Host "  Recurse:          $recurse"
Write-Host "  IncludeNonPdf:    $includeNonPdf"
Write-Host "  CreateFolders:    $createFolders"
Write-Host "  UnmatchedFolder:  $unmatchedFolder"
Write-Host ""

if ($UndoLast) {
    Undo-LastMove -LogPath $logPath
    return
}

if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
    throw "No existe SourcePath: $sourcePath"
}

if (
    $sourcePath.Equals(
        $destinationPath,
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "SourcePath y DestinationPath no pueden ser iguales."
}

$rules = Import-Rules -RulesPath $rulesPath
Write-Host "Reglas cargadas: $($rules.Count)"

$searchParameters = @{
    LiteralPath = $sourcePath
    File = $true
}

if ($recurse) {
    $searchParameters.Recurse = $true
}

$files = @(
    Get-ChildItem @searchParameters |
    Where-Object {
        if (-not $includeNonPdf -and $_.Extension -ine ".pdf") {
            return $false
        }

        if (Test-PathInside -Candidate $_.FullName -Parent $destinationPath) {
            return $false
        }

        if (Test-PathInside -Candidate $_.FullName -Parent $rulesPath) {
            return $false
        }

        if (Test-PathInside -Candidate $_.FullName -Parent $logPath) {
            return $false
        }

        return $true
    }
)

Write-Host "Archivos encontrados: $($files.Count)"
Write-Host ""

$results = New-Object System.Collections.Generic.List[object]
$categoryCounts = @{}
$ruleCounts = @{}

$processed = 0
$matched = 0
$unmatched = 0
$errors = 0

foreach ($file in $files) {
    $processed++

    $percent = if ($files.Count -gt 0) {
        [int](100 * $processed / $files.Count)
    } else {
        100
    }

    Write-Progress `
        -Activity "Organizando biblioteca" `
        -Status "$processed de $($files.Count): $($file.Name)" `
        -PercentComplete $percent

    $best = Find-BestRule -FileName $file.BaseName -Rules $rules

    if ($null -ne $best) {
        $relativeFolder = $best.Rule.Folder
        $status = "Matched"
        $matched++

        if (-not $categoryCounts.ContainsKey($best.Rule.Category)) {
            $categoryCounts[$best.Rule.Category] = 0
        }
        $categoryCounts[$best.Rule.Category]++

        $ruleKey = "$($best.Rule.RuleFile)|$($best.Rule.Folder)"
        if (-not $ruleCounts.ContainsKey($ruleKey)) {
            $ruleCounts[$ruleKey] = 0
        }
        $ruleCounts[$ruleKey]++
    }
    else {
        $relativeFolder = $unmatchedFolder
        $status = "Unmatched"
        $unmatched++
    }

    $targetDirectory = Join-Path $destinationPath (
        $relativeFolder.Replace("/", [IO.Path]::DirectorySeparatorChar)
    )

    $targetPath = Get-UniqueTargetPath (
        Join-Path $targetDirectory $file.Name
    )

    try {
        if (-not $simulation) {
            if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
                if (-not $createFolders) {
                    throw "La carpeta no existe y CreateFolders=false: $targetDirectory"
                }

                [void](New-Item -ItemType Directory -Path $targetDirectory -Force)
            }

            if ($copy) {
                Copy-Item -LiteralPath $file.FullName -Destination $targetPath
            }
            else {
                Move-Item -LiteralPath $file.FullName -Destination $targetPath
            }
        }

        $results.Add([PSCustomObject]@{
            Timestamp = (Get-Date).ToString("s")
            Operation = if ($simulation) { "Simulation" } elseif ($copy) { "Copy" } else { "Move" }
            Status = if ($simulation) { "Simulation-$status" } else { $status }
            Source = $file.FullName
            Target = $targetPath
            Category = if ($null -ne $best) { $best.Rule.Category } else { "" }
            RuleFolder = $relativeFolder
            Priority = if ($null -ne $best) { $best.Rule.Priority } else { "" }
            Keywords = if ($null -ne $best) { $best.KeywordMatches -join " | " } else { "" }
            Authors = if ($null -ne $best) { $best.AuthorMatches -join " | " } else { "" }
            RuleFile = if ($null -ne $best) { $best.Rule.RuleFile } else { "" }
            Error = ""
        })
    }
    catch {
        $errors++

        $results.Add([PSCustomObject]@{
            Timestamp = (Get-Date).ToString("s")
            Operation = if ($copy) { "Copy" } else { "Move" }
            Status = "Error"
            Source = $file.FullName
            Target = $targetPath
            Category = if ($null -ne $best) { $best.Rule.Category } else { "" }
            RuleFolder = $relativeFolder
            Priority = if ($null -ne $best) { $best.Rule.Priority } else { "" }
            Keywords = ""
            Authors = ""
            RuleFile = if ($null -ne $best) { $best.Rule.RuleFile } else { "" }
            Error = $_.Exception.Message
        })

        Write-Warning $_.Exception.Message
    }
}

Write-Progress -Activity "Organizando biblioteca" -Completed

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$mode = if ($simulation) { "simulation" } elseif ($copy) { "copy" } else { "move" }

$mainLog = Join-Path $logPath "organize-$mode-$timestamp.csv"
$unmatchedLog = Join-Path $logPath "unmatched-$timestamp.csv"
$categoryLog = Join-Path $logPath "categories-$timestamp.csv"
$ruleUsageLog = Join-Path $logPath "rule-usage-$timestamp.csv"

$results |
    Export-Csv -LiteralPath $mainLog -NoTypeInformation -Encoding UTF8

$results |
    Where-Object { $_.Status -in @("Unmatched", "Simulation-Unmatched") } |
    Export-Csv -LiteralPath $unmatchedLog -NoTypeInformation -Encoding UTF8

@(
    foreach ($name in $categoryCounts.Keys) {
        [PSCustomObject]@{
            Category = $name
            Count = $categoryCounts[$name]
        }
    }
) |
    Sort-Object Count -Descending |
    Export-Csv -LiteralPath $categoryLog -NoTypeInformation -Encoding UTF8

@(
    foreach ($key in $ruleCounts.Keys) {
        $parts = $key -split "\|", 2

        [PSCustomObject]@{
            RuleFile = $parts[0]
            Folder = $parts[1]
            Count = $ruleCounts[$key]
        }
    }
) |
    Sort-Object Count -Descending |
    Export-Csv -LiteralPath $ruleUsageLog -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Resumen"
Write-Host "-------"
Write-Host "Procesados:     $processed"
Write-Host "Clasificados:   $matched"
Write-Host "Sin clasificar: $unmatched"
Write-Host "Errores:        $errors"

if ($simulation) {
    Write-Host ""
    Write-Host "SIMULACIÓN: no se crearon carpetas ni se movieron archivos."
}

Write-Host ""
Write-Host "Logs:"
Write-Host "  $mainLog"
Write-Host "  $unmatchedLog"
Write-Host "  $categoryLog"
Write-Host "  $ruleUsageLog"

if (-not $simulation -and -not $copy) {
    Write-Host ""
    Write-Host "Para deshacer el último movimiento:"
    Write-Host "  .\organize-config.ps1 -UndoLast"
}