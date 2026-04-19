param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

$imagesRoot = Join-Path $Root "model-images"
$manifestPath = Join-Path $imagesRoot "manifest.csv"
$missingPath = Join-Path $imagesRoot "missing-images.csv"

if (!(Test-Path $imagesRoot)) {
    New-Item -Path $imagesRoot -ItemType Directory | Out-Null
}

Get-ChildItem -Path $imagesRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Recurse -Force
}

$brandAliasMap = @{
    "CHRYSLER_DODGE_JEEP"   = @("Chrysler", "Dodge", "Jeep")
    "GM_CHEVY_GMC_CADILLAC" = @("Buick", "Cadillac", "Chevrolet", "GMC")
    "HONDA"                 = @("Honda", "Acura")
    "HYUNDAI"               = @("Hyundai", "Kia", "Genesis")
    "LDV_AUTOMOTIVE"        = @("LDV")
    "MERCEDES"              = @("Mercedes", "Mercedes-Benz")
    "TOYOTA"                = @("Toyota", "Lexus")
    "VOLKSWAGEN"            = @("Volkswagen", "VW")
}

$modelAliasMap = @{
    "ATTO3"        = @("Atto 3")
    "CRUISER06"    = @("PT Cruiser")
    "CRV"          = @("CR-V")
    "CX50"         = @("CX-50", "CX 50")
    "ESTIMA"       = @("Estima", "Previa")
    "GLE350"       = @("GLE 350", "GLE-Class")
    "HRV"          = @("HR-V")
    "IS300"        = @("IS 300")
    "LACROSS"      = @("LaCrosse")
    "NX200T"       = @("NX 200t", "NX 200T")
    "RAV4"         = @("RAV4")
    "RX8"          = @("RX-8", "RX 8")
    "SANTA_FE"     = @("Santa Fe")
    "TRAIL_BLAZER" = @("Trailblazer", "Trail Blazer")
    "TYPE"         = @("Tipo", "Type 160")
}

$detectedBrandMap = @{
    "ACURA"       = "Acura"
    "BUICK"       = "Buick"
    "CADI"        = "Cadillac"
    "CADILLAC"    = "Cadillac"
    "CHEVROLET"   = "Chevrolet"
    "CHEVY"       = "Chevrolet"
    "CHRYSLER"    = "Chrysler"
    "DODGE"       = "Dodge"
    "FIAT"        = "Fiat"
    "FORD"        = "Ford"
    "GENESIS"     = "Genesis"
    "GMC"         = "GMC"
    "HONDA"       = "Honda"
    "HYUNDAI"     = "Hyundai"
    "JEEP"        = "Jeep"
    "KIA"         = "Kia"
    "LDV"         = "LDV"
    "LEXUS"       = "Lexus"
    "MAZDA"       = "Mazda"
    "MERC"        = "Mercedes-Benz"
    "MERCEDES"    = "Mercedes-Benz"
    "NISSAN"      = "Nissan"
    "OPEL"        = "Opel"
    "PEUGEOT"     = "Peugeot"
    "RENAULT"     = "Renault"
    "SKODA"       = "Skoda"
    "SUBARU"      = "Subaru"
    "TOYOTA"      = "Toyota"
    "VOLKSWAGEN"  = "Volkswagen"
    "VOLVO"       = "Volvo"
    "VW"          = "Volkswagen"
    "BYD"         = "BYD"
    "BMW"         = "BMW"
}

function Add-Unique {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string[]]$Values
    )

    foreach ($value in $Values) {
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if (-not $List.Contains($value)) {
            $List.Add($value) | Out-Null
        }
    }
}

function Normalize-Text {
    param([string]$Text)

    if (-not $Text) { return "" }
    return (($Text.ToUpperInvariant() -replace '[^A-Z0-9]+', ' ').Trim())
}

function Invoke-WithRetry {
    param(
        [scriptblock]$Action,
        [int]$MaxAttempts = 5,
        [int]$InitialDelaySeconds = 2
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $Action
        } catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                try {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                } catch {
                    $statusCode = $null
                }
            }

            if ($attempt -ge $MaxAttempts) {
                throw
            }

            $delay = [math]::Min(45, [int]($InitialDelaySeconds * [math]::Pow(2, $attempt - 1)))
            if ($statusCode -eq 429) {
                $delay = [math]::Min(60, $delay + 5)
            }

            Start-Sleep -Seconds $delay
        }
    }
}

function Get-BrandAliases {
    param(
        [string]$Brand,
        [string]$ModelPath
    )

    $aliases = New-Object "System.Collections.Generic.List[string]"
    Add-Unique -List $aliases -Values @(($Brand -replace '_', ' '))

    if ($brandAliasMap.ContainsKey($Brand)) {
        Add-Unique -List $aliases -Values $brandAliasMap[$Brand]
    }

    Get-ChildItem -Path $ModelPath -Recurse -Filter *.sub -File -ErrorAction SilentlyContinue |
        Select-Object -First 24 |
        ForEach-Object {
            $tokens = (Normalize-Text $_.BaseName) -split '\s+'
            foreach ($token in $tokens) {
                if ($detectedBrandMap.ContainsKey($token)) {
                    Add-Unique -List $aliases -Values @($detectedBrandMap[$token])
                }
            }
        }

    return $aliases
}

function Get-ModelAliases {
    param([string]$Model)

    $aliases = New-Object "System.Collections.Generic.List[string]"
    $base = ($Model -replace '_', ' ').Trim()
    Add-Unique -List $aliases -Values @($base)

    $spaced = $base -replace '([A-Za-z]+)(\d+)', '$1 $2'
    $spaced = $spaced -replace '(\d+)([A-Za-z]+)', '$1 $2'
    Add-Unique -List $aliases -Values @($spaced)

    if ($spaced -match ' ') {
        Add-Unique -List $aliases -Values @($spaced -replace ' ', '-')
    }

    if ($modelAliasMap.ContainsKey($Model)) {
        Add-Unique -List $aliases -Values $modelAliasMap[$Model]
    }

    return $aliases
}

function Test-TextContainsAny {
    param(
        [string]$Text,
        [System.Collections.Generic.List[string]]$Candidates
    )

    $normalizedText = Normalize-Text $Text
    foreach ($candidate in $Candidates) {
        $normalizedCandidate = Normalize-Text $candidate
        if (-not $normalizedCandidate) { continue }
        if ($normalizedText -like "*$normalizedCandidate*") {
            return $true
        }
    }

    return $false
}

function Test-IsVehicleSummary {
    param($Summary)

    if (-not $Summary) { return $false }

    $text = @($Summary.title, $Summary.description, $Summary.extract) -join ' '
    $normalized = Normalize-Text $text
    $keywords = @(
        "AUTOMOBILE", "CAR", "CROSSOVER", "COUPE", "HATCHBACK", "MINIVAN",
        "PICKUP", "SEDAN", "SPORT UTILITY VEHICLE", "SUV", "TRUCK", "VEHICLE", "WAGON"
    )

    foreach ($keyword in $keywords) {
        if ($normalized -like "*$keyword*") {
            return $true
        }
    }

    return $false
}

function Get-WikipediaSummary {
    param([string]$Title)

    $encodedTitle = [uri]::EscapeDataString($Title)
    $url = "https://en.wikipedia.org/api/rest_v1/page/summary/$encodedTitle"

    try {
        return Invoke-WithRetry -Action {
            Invoke-RestMethod -Uri $url -Method Get -Headers @{ "User-Agent" = "Mozilla/5.0 (Cars README builder)" }
        } -MaxAttempts 4 -InitialDelaySeconds 2
    } catch {
        return $null
    }
}

function Search-Wikipedia {
    param([string]$Query)

    $encoded = [uri]::EscapeDataString($Query)
    $url = "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=$encoded&format=json&srlimit=6"

    try {
        return Invoke-WithRetry -Action {
            Invoke-RestMethod -Uri $url -Method Get -Headers @{ "User-Agent" = "Mozilla/5.0 (Cars README builder)" }
        } -MaxAttempts 4 -InitialDelaySeconds 2
    } catch {
        return $null
    }
}

function Select-ImageForModel {
    param(
        [string]$Brand,
        [string]$Model,
        [string]$ModelPath
    )

    $brandAliases = Get-BrandAliases -Brand $Brand -ModelPath $ModelPath
    $modelAliases = Get-ModelAliases -Model $Model

    $titleCandidates = New-Object "System.Collections.Generic.List[string]"
    foreach ($brandAlias in $brandAliases) {
        foreach ($modelAlias in $modelAliases) {
            Add-Unique -List $titleCandidates -Values @(
                "$brandAlias $modelAlias",
                "$brandAlias $modelAlias car"
            )
        }
    }

    foreach ($candidateTitle in $titleCandidates) {
        $summary = Get-WikipediaSummary -Title $candidateTitle
        if (-not $summary) { continue }
        if (-not $summary.thumbnail -or -not $summary.thumbnail.source) { continue }
        if (-not (Test-IsVehicleSummary -Summary $summary)) { continue }
        if (-not (Test-TextContainsAny -Text $summary.title -Candidates $modelAliases)) { continue }

        return [PSCustomObject]@{
            Title = $summary.title
            Url = $summary.thumbnail.source
        }
    }

    $queryCandidates = New-Object "System.Collections.Generic.List[string]"
    foreach ($brandAlias in $brandAliases) {
        foreach ($modelAlias in $modelAliases) {
            Add-Unique -List $queryCandidates -Values @(
                "$brandAlias $modelAlias car",
                "$brandAlias $modelAlias automobile"
            )
        }
    }

    foreach ($query in $queryCandidates) {
        $searchResult = Search-Wikipedia -Query $query
        if (-not $searchResult -or -not $searchResult.query.search) { continue }

        foreach ($result in $searchResult.query.search) {
            if (-not (Test-TextContainsAny -Text $result.title -Candidates $modelAliases)) { continue }

            $summary = Get-WikipediaSummary -Title $result.title
            if (-not $summary) { continue }
            if (-not $summary.thumbnail -or -not $summary.thumbnail.source) { continue }
            if (-not (Test-IsVehicleSummary -Summary $summary)) { continue }

            $combinedText = @($summary.title, $summary.description, $summary.extract) -join ' '
            if (-not (Test-TextContainsAny -Text $combinedText -Candidates $brandAliases)) { continue }

            return [PSCustomObject]@{
                Title = $summary.title
                Url = $summary.thumbnail.source
            }
        }
    }

    return $null
}

function Save-Image {
    param(
        [string]$Url,
        [string]$OutFile
    )

    Invoke-WithRetry -Action {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -Headers @{ "User-Agent" = "Mozilla/5.0 (Cars README builder)" }
    } -MaxAttempts 5 -InitialDelaySeconds 2 | Out-Null
}

$records = New-Object "System.Collections.Generic.List[object]"
$brands = Get-ChildItem -Path $Root -Directory |
    Where-Object { $_.Name -notin @(".git", "model-images", "scripts") } |
    Sort-Object Name

foreach ($brand in $brands) {
    $models = Get-ChildItem -Path $brand.FullName -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "UNCLASSIFIED" } |
        Sort-Object Name

    foreach ($model in $models) {
        $brandName = $brand.Name
        $modelName = $model.Name
        $brandOut = Join-Path $imagesRoot $brandName

        if (!(Test-Path $brandOut)) {
            New-Item -Path $brandOut -ItemType Directory | Out-Null
        }

        $safeModel = ($modelName -replace '[^A-Za-z0-9_\-]', '_')
        $outFile = Join-Path $brandOut ($safeModel + ".jpg")

        $selected = Select-ImageForModel -Brand $brandName -Model $modelName -ModelPath $model.FullName
        $status = "not_found"
        $sourceTitle = ""
        $sourceUrl = ""
        $localImage = ""

        if ($selected) {
            $sourceTitle = $selected.Title
            $sourceUrl = $selected.Url

            try {
                Save-Image -Url $sourceUrl -OutFile $outFile
                $status = "downloaded"
                $localImage = $outFile
            } catch {
                $status = "failed_download"
            }
        }

        $records.Add([PSCustomObject]@{
            Brand = $brandName
            Model = $modelName
            Status = $status
            SourceTitle = $sourceTitle
            SourceUrl = $sourceUrl
            LocalImage = $localImage
        }) | Out-Null

        Start-Sleep -Milliseconds 750
    }
}

$records | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
$records | Where-Object { $_.Status -ne "downloaded" } | Export-Csv -Path $missingPath -NoTypeInformation -Encoding UTF8

$downloaded = ($records | Where-Object { $_.Status -eq "downloaded" }).Count
$failed = ($records | Where-Object { $_.Status -eq "failed_download" }).Count
$notFound = ($records | Where-Object { $_.Status -eq "not_found" }).Count

Write-Output "Manifest: $manifestPath"
Write-Output "Downloaded: $downloaded"
Write-Output "Failed download: $failed"
Write-Output "Not found: $notFound"
