$ErrorActionPreference = "Stop"

$root = "C:\Users\Amaury\Desktop\Cars"
$imagesRoot = Join-Path $root "model-images"
$manifestPath = Join-Path $imagesRoot "manifest.csv"

if (!(Test-Path $imagesRoot)) {
    New-Item -Path $imagesRoot -ItemType Directory | Out-Null
}

function Get-ModelTokens {
    param(
        [string]$Brand,
        [string]$Model
    )

    $brandNorm = ($Brand.ToUpper() -replace '[^A-Z0-9]+', ' ').Trim()
    $modelNorm = ($Model.ToUpper() -replace '[^A-Z0-9]+', ' ').Trim()
    $tokens = @()
    if ($brandNorm) { $tokens += ($brandNorm -split '\s+') }
    if ($modelNorm) { $tokens += ($modelNorm -split '\s+') }
    return $tokens | Where-Object { $_ -and $_.Length -ge 2 } | Select-Object -Unique
}

function Test-IsPlausibleCarImage {
    param(
        [string]$Title,
        [string[]]$Tokens
    )

    if (-not $Title) { return $false }
    $t = $Title.ToUpper()

    $badKeywords = @(
        'ENGINE', 'MOTOR', 'TRANSMISSION', 'GEARBOX', 'PISTON', 'CYLINDER',
        'INTERIOR', 'DASHBOARD', 'STEERING', 'SEAT', 'WHEEL', 'RIM', 'TIRE',
        'LOGO', 'EMBLEM', 'BADGE', 'BROCHURE', 'MANUAL', 'DIAGRAM',
        'DEALERSHIP', 'SHOWROOM', 'BUILDING', 'OFFICE', 'FACTORY',
        'CONCEPT ART', 'RENDER', 'TOY', 'MODEL CAR'
    )

    foreach ($kw in $badKeywords) {
        if ($t -like "*$kw*") { return $false }
    }

    $goodKeywords = @('FRONT', 'REAR', 'SIDE', 'EXTERIOR', 'PARKED', 'ON ROAD', 'SEDAN', 'SUV', 'HATCHBACK', 'COUPE')
    $goodHit = $false
    foreach ($g in $goodKeywords) {
        if ($t -like "*$g*") { $goodHit = $true; break }
    }

    $tokenHits = 0
    foreach ($tk in $Tokens) {
        if ($t -like "*$tk*") { $tokenHits++ }
    }

    # strict enough to avoid random images
    return ($tokenHits -ge 2) -or (($tokenHits -ge 1) -and $goodHit)
}

function Get-CommonsCarImage {
    param(
        [string]$Brand,
        [string]$Model
    )

    $query = "$Brand $Model car"
    $encoded = [uri]::EscapeDataString($query)
    $url = "https://commons.wikimedia.org/w/api.php?action=query&generator=search&gsrnamespace=6&gsrsearch=$encoded&gsrlimit=25&prop=imageinfo&iiprop=url&iiurlwidth=1400&format=json"
    $tokens = Get-ModelTokens -Brand $Brand -Model $Model

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $res = Invoke-RestMethod -Uri $url -Method Get -Headers @{ "User-Agent" = "CarsImageCollector/1.1 (contact: local-script)" }
            if (-not $res.query.pages) { return $null }

            $candidates = $res.query.pages.PSObject.Properties.Value
            foreach ($c in $candidates) {
                if (-not $c.imageinfo -or $c.imageinfo.Count -eq 0) { continue }
                $title = $c.title
                if (-not (Test-IsPlausibleCarImage -Title $title -Tokens $tokens)) { continue }

                $img = $c.imageinfo[0]
                $imgUrl = if ($img.thumburl) { $img.thumburl } else { $img.url }
                if (-not $imgUrl) { continue }

                return [PSCustomObject]@{
                    Title = $title
                    Url = $imgUrl
                }
            }
            return $null
        } catch {
            Start-Sleep -Seconds (2 * $attempt)
        }
    }

    return $null
}

function Get-WikipediaCarImageFallback {
    param(
        [string]$Brand,
        [string]$Model
    )

    $query = "$Brand $Model car"
    $encoded = [uri]::EscapeDataString($query)
    $searchUrl = "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=$encoded&format=json&srlimit=8"
    $tokens = Get-ModelTokens -Brand $Brand -Model $Model

    try {
        $search = Invoke-RestMethod -Uri $searchUrl -Method Get -Headers @{ "User-Agent" = "CarsImageCollector/1.1 (contact: local-script)" }
    } catch {
        return $null
    }

    if (-not $search.query.search) { return $null }

    foreach ($r in $search.query.search) {
        $title = $r.title
        if (-not (Test-IsPlausibleCarImage -Title $title -Tokens $tokens)) { continue }
        $tEnc = [uri]::EscapeDataString($title)
        $sumUrl = "https://en.wikipedia.org/api/rest_v1/page/summary/$tEnc"
        try {
            $sum = Invoke-RestMethod -Uri $sumUrl -Method Get -Headers @{ "User-Agent" = "CarsImageCollector/1.1 (contact: local-script)" }
            if ($sum.thumbnail -and $sum.thumbnail.source) {
                return [PSCustomObject]@{
                    Title = $title
                    Url = $sum.thumbnail.source
                }
            }
        } catch {
            continue
        }
    }
    return $null
}

$records = New-Object System.Collections.Generic.List[object]

# start fresh to avoid keeping wrong images
if (Test-Path $imagesRoot) {
    Get-ChildItem -Path $imagesRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item $_.FullName -Recurse -Force
    }
}

$brands = Get-ChildItem -Path $root -Directory | Where-Object { $_.Name -notin @("model-images", "scripts", ".git") }
foreach ($brand in $brands) {
    $models = Get-ChildItem -Path $brand.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "UNCLASSIFIED" }
    foreach ($model in $models) {
        $brandName = $brand.Name
        $modelName = $model.Name

        $brandImageDir = Join-Path $imagesRoot $brandName
        if (!(Test-Path $brandImageDir)) {
            New-Item -Path $brandImageDir -ItemType Directory | Out-Null
        }

        $safeModel = ($modelName -replace '[^A-Za-z0-9_\-]', '_')
        $outPath = Join-Path $brandImageDir ($safeModel + ".jpg")

        $thumb = Get-CommonsCarImage -Brand $brandName -Model $modelName
        if (-not $thumb) {
            $thumb = Get-WikipediaCarImageFallback -Brand $brandName -Model $modelName
        }

        if ($thumb) {
            try {
                Invoke-WebRequest -Uri $thumb.Url -OutFile $outPath -Headers @{ "User-Agent" = "CarsImageCollector/1.1 (contact: local-script)" }
                $status = "downloaded"
            } catch {
                $status = "failed_download"
            }
        } else {
            $status = "not_found"
        }

        $records.Add([PSCustomObject]@{
            Brand = $brandName
            Model = $modelName
            Status = $status
            SourceTitle = if ($thumb) { $thumb.Title } else { "" }
            SourceUrl = if ($thumb) { $thumb.Url } else { "" }
            LocalImage = if ($status -eq "downloaded") { $outPath } else { "" }
        })
    }
}

$records | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8

$downloaded = ($records | Where-Object { $_.Status -eq "downloaded" }).Count
$notFound = ($records | Where-Object { $_.Status -eq "not_found" }).Count
$failed = ($records | Where-Object { $_.Status -eq "failed_download" }).Count

Write-Output "Manifest: $manifestPath"
Write-Output "Downloaded: $downloaded"
Write-Output "Not found: $notFound"
Write-Output "Failed download: $failed"
