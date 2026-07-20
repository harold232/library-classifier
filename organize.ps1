#requires -Version 5.1
<#
.SYNOPSIS
Organiza una biblioteca de archivos usando reglas JSON.

.DESCRIPTION
Carga todos los archivos rules-*.json, evalúa el nombre de cada archivo,
selecciona la regla coincidente con mayor prioridad y mueve o copia el archivo
a la carpeta indicada por la regla.

La simulación se ejecuta con el parámetro estándar -WhatIf.

.EXAMPLE
.\organize.ps1 -SourcePath "D:\PDFs" -DestinationPath "D:\Library" -Recurse -WhatIf

.EXAMPLE
.\organize.ps1 -SourcePath "D:\PDFs" -DestinationPath "D:\Library" -Recurse

.EXAMPLE
.\organize.ps1 -SourcePath "D:\PDFs" -DestinationPath "D:\Library" -Recurse -Copy
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationPath,

    [ValidateNotNullOrEmpty()]
    [string]$RulesPath = (Join-Path $PSScriptRoot "rules"),

    [switch]$Recurse,

    [switch]$Copy,

    [switch]$IncludeNonPdf,

    [switch]$NoUnmatchedFolder,

    [ValidateNotNullOrEmpty()]
    [string]$UnmatchedFolder = "Archive/Unmatched",

    [ValidateNotNullOrEmpty()]
    [string]$LogPath = (Join-Path $PSScriptRoot "logs")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-NormalizedText {
    param(
        [AllowNull()]
        [string]$Text
    )

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

    $normalized = $builder.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
    $normalized = [Regex]::Replace($normalized, "[^\p{L}\p{N}]+", " ")
    return [Regex]::Replace($normalized.Trim(), "\s+", " ")
}

function Test-TermMatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NormalizedText,

        [Parameter(Mandatory = $true)]
        [string]$NormalizedTerm
    )

    if ([string]::IsNullOrWhiteSpace($NormalizedTerm)) {
        return $false
    }

    $escapedTerm = [Regex]::Escape($NormalizedTerm)
    $pattern = "(?<![\p{L}\p{N}])$escapedTerm(?![\p{L}\p{N}])"
    return [Regex]::IsMatch($NormalizedText, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-UniqueTargetPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

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

function Get-FullNormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CandidatePath,

        [Parameter(Mandatory = $true)]
        [string]$ParentPath
    )

    $candidate = Get-FullNormalizedPath $CandidatePath
    $parent = Get-FullNormalizedPath $ParentPath
    $prefix = $parent + [IO.Path]::DirectorySeparatorChar

    return $candidate.Equals($parent, [StringComparison]::OrdinalIgnoreCase) -or
           $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Import-OrganizerRules {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "No existe la carpeta de reglas: $Path"
    }

    $ruleFiles = Get-ChildItem -LiteralPath $Path -Filter "rules-*.json" -File |
        Sort-Object Name

    if (-not $ruleFiles) {
        throw "No se encontraron archivos rules-*.json en: $Path"
    }

    $loadedRules = New-Object System.Collections.Generic.List[object]
    $sequence = 0

    foreach ($ruleFile in $ruleFiles) {
        try {
            $json = Get-Content -LiteralPath $ruleFile.FullName -Raw -Encoding UTF8 |
                ConvertFrom-Json
        }
        catch {
            throw "JSON inválido en '$($ruleFile.FullName)': $($_.Exception.Message)"
        }

        foreach ($categoryProperty in $json.PSObject.Properties) {
            $categoryName = [string]$categoryProperty.Name
            $categoryRules = @($categoryProperty.Value)

            foreach ($rule in $categoryRules) {
                if (-not $rule.folder) {
                    Write-Warning "Regla omitida sin 'folder' en $($ruleFile.Name)."
                    continue
                }

                $priority = 0
                if ($null -ne $rule.priority) {
                    $priority = [int]$rule.priority
                }

                $keywords = @()
                if ($null -ne $rule.keywords) {
                    $keywords = @($rule.keywords) |
                        ForEach-Object { Get-NormalizedText ([string]$_) } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Select-Object -Unique
                }

                $authors = @()
                if ($null -ne $rule.authors) {
                    $authors = @($rule.authors) |
                        ForEach-Object { Get-NormalizedText ([string]$_) } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                        Select-Object -Unique
                }

                if (($keywords.Count + $authors.Count) -eq 0) {
                    Write-Warning "Regla omitida sin keywords ni authors: $($rule.folder)"
                    continue
                }

                $sequence++

                $loadedRules.Add([PSCustomObject]@{
                    Category   = $categoryName
                    Folder     = ([string]$rule.folder).Trim().Replace("\", "/")
                    Priority   = $priority
                    Keywords   = $keywords
                    Authors    = $authors
                    SourceFile = $ruleFile.Name
                    Sequence   = $sequence
                })
            }
        }
    }

    return @($loadedRules)
}

function Find-BestRule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [object[]]$Rules
    )

    $normalizedText = Get-NormalizedText $Text
    $matches = New-Object System.Collections.Generic.List[object]

    foreach ($rule in $Rules) {
        $keywordMatches = @(
            $rule.Keywords |
            Where-Object { Test-TermMatch -NormalizedText $normalizedText -NormalizedTerm $_ }
        )

        $authorMatches = @(
            $rule.Authors |
            Where-Object { Test-TermMatch -NormalizedText $normalizedText -NormalizedTerm $_ }
        )

        if (($keywordMatches.Count + $authorMatches.Count) -eq 0) {
            continue
        }

        $matchedCharacters = 0
        foreach ($term in @($keywordMatches + $authorMatches)) {
            $matchedCharacters += $term.Length
        }

        # Orden de decisión:
        # 1. prioridad de la regla
        # 2. coincidencias de autores
        # 3. cantidad de coincidencias
        # 4. longitud total de términos coincidentes
        # 5. orden estable de carga
        $score = ([long]$rule.Priority * 1000000000L) +
                 ([long]$authorMatches.Count * 1000000L) +
                 ([long]($keywordMatches.Count + $authorMatches.Count) * 1000L) +
                 [long]$matchedCharacters

        $matches.Add([PSCustomObject]@{
            Rule              = $rule
            Score             = $score
            KeywordMatches    = $keywordMatches
            AuthorMatches     = $authorMatches
            MatchedCharacters = $matchedCharacters
        })
    }

    return $matches |
        Sort-Object `
            @{ Expression = "Score"; Descending = $true },
            @{ Expression = { $_.Rule.Sequence }; Descending = $false } |
        Select-Object -First 1
}

$sourceFull = Get-FullNormalizedPath $SourcePath
$destinationFull = Get-FullNormalizedPath $DestinationPath
$rulesFull = Get-FullNormalizedPath $RulesPath
$logFull = Get-FullNormalizedPath $LogPath

if (-not (Test-Path -LiteralPath $sourceFull -PathType Container)) {
    throw "No existe la carpeta de origen: $sourceFull"
}

if ($sourceFull.Equals($destinationFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw "La carpeta de origen y la de destino no pueden ser la misma."
}

$rules = Import-OrganizerRules -Path $rulesFull
Write-Host ("Reglas cargadas: {0}" -f $rules.Count)

$getChildItemParameters = @{
    LiteralPath = $sourceFull
    File        = $true
}

if ($Recurse) {
    $getChildItemParameters.Recurse = $true
}

$files = @(Get-ChildItem @getChildItemParameters | Where-Object {
    if (-not $IncludeNonPdf -and $_.Extension -ine ".pdf") {
        return $false
    }

    # Evita volver a procesar la biblioteca si el destino está dentro del origen.
    if (Test-PathInside -CandidatePath $_.FullName -ParentPath $destinationFull) {
        return $false
    }

    # Evita procesar archivos del propio proyecto si está dentro del origen.
    if (Test-PathInside -CandidatePath $_.FullName -ParentPath $rulesFull) {
        return $false
    }

    if (Test-PathInside -CandidatePath $_.FullName -ParentPath $logFull) {
        return $false
    }

    return $true
})

Write-Host ("Archivos encontrados: {0}" -f $files.Count)

$results = New-Object System.Collections.Generic.List[object]
$processed = 0
$matched = 0
$unmatched = 0
$errors = 0
$operationName = if ($Copy) { "Copiar" } else { "Mover" }

foreach ($file in $files) {
    $processed++
    $bestMatch = Find-BestRule -Text $file.BaseName -Rules $rules

    if ($null -ne $bestMatch) {
        $relativeFolder = $bestMatch.Rule.Folder
        $status = "Matched"
        $matched++
    }
    elseif (-not $NoUnmatchedFolder) {
        $relativeFolder = $UnmatchedFolder
        $status = "Unmatched"
        $unmatched++
    }
    else {
        $results.Add([PSCustomObject]@{
            Timestamp       = (Get-Date).ToString("s")
            Status          = "SkippedUnmatched"
            Source          = $file.FullName
            Target          = ""
            Category        = ""
            RuleFolder      = ""
            Priority        = ""
            Keywords        = ""
            Authors         = ""
            RuleFile        = ""
            Error           = ""
        })
        continue
    }

    $platformRelativeFolder = $relativeFolder.Replace(
        "/",
        [IO.Path]::DirectorySeparatorChar
    )

    $targetDirectory = Join-Path $destinationFull $platformRelativeFolder
    $targetPath = Join-Path $targetDirectory $file.Name
    $targetPath = Get-UniqueTargetPath -Path $targetPath

    $category = ""
    $priority = ""
    $keywords = ""
    $authors = ""
    $ruleFile = ""

    if ($null -ne $bestMatch) {
        $category = $bestMatch.Rule.Category
        $priority = $bestMatch.Rule.Priority
        $keywords = ($bestMatch.KeywordMatches -join " | ")
        $authors = ($bestMatch.AuthorMatches -join " | ")
        $ruleFile = $bestMatch.Rule.SourceFile
    }

    try {
        $description = "{0} a '{1}'" -f $operationName, $targetPath

        if ($PSCmdlet.ShouldProcess($file.FullName, $description)) {
            if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
                [void](New-Item -ItemType Directory -Path $targetDirectory -Force)
            }

            if ($Copy) {
                Copy-Item -LiteralPath $file.FullName -Destination $targetPath
            }
            else {
                Move-Item -LiteralPath $file.FullName -Destination $targetPath
            }
        }

        $results.Add([PSCustomObject]@{
            Timestamp       = (Get-Date).ToString("s")
            Status          = if ($WhatIfPreference) { "Simulation-$status" } else { $status }
            Source          = $file.FullName
            Target          = $targetPath
            Category        = $category
            RuleFolder      = $relativeFolder
            Priority        = $priority
            Keywords        = $keywords
            Authors         = $authors
            RuleFile        = $ruleFile
            Error           = ""
        })
    }
    catch {
        $errors++

        $results.Add([PSCustomObject]@{
            Timestamp       = (Get-Date).ToString("s")
            Status          = "Error"
            Source          = $file.FullName
            Target          = $targetPath
            Category        = $category
            RuleFolder      = $relativeFolder
            Priority        = $priority
            Keywords        = $keywords
            Authors         = $authors
            RuleFile        = $ruleFile
            Error           = $_.Exception.Message
        })

        Write-Warning ("Error procesando '{0}': {1}" -f $file.FullName, $_.Exception.Message)
    }
}

if (-not (Test-Path -LiteralPath $logFull -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $logFull -Force)
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$mode = if ($WhatIfPreference) { "simulation" } elseif ($Copy) { "copy" } else { "move" }
$csvLog = Join-Path $logFull ("organize-{0}-{1}.csv" -f $mode, $timestamp)

$results | Export-Csv -LiteralPath $csvLog -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Resumen"
Write-Host "-------"
Write-Host ("Procesados:      {0}" -f $processed)
Write-Host ("Con coincidencia:{0,6}" -f $matched)
Write-Host ("Sin coincidencia:{0,6}" -f $unmatched)
Write-Host ("Errores:         {0,6}" -f $errors)
Write-Host ("Registro: {0}" -f $csvLog)

if ($WhatIfPreference) {
    Write-Host ""
    Write-Host "Simulación completada. No se movieron ni copiaron archivos."
}