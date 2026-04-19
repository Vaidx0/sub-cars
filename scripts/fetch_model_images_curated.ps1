$ErrorActionPreference = "Stop"

$root = "C:\Users\Amaury\Desktop\Cars"
$imagesRoot = Join-Path $root "model-images"
$manifestPath = Join-Path $imagesRoot "manifest.csv"
$missingPath = Join-Path $imagesRoot "missing-images.csv"

if (!(Test-Path $imagesRoot)) {
    New-Item -Path $imagesRoot -ItemType Directory | Out-Null
}

# Remove previous brand image folders to regenerate cleanly.
Get-ChildItem -Path $imagesRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item $_.FullName -Recurse -Force
}

function Normalize-Text {
    param([string]$Text)
    if (-not $Text) { return "" }
    return (($Text.ToUpper() -replace '[^A-Z0-9]+', ' ').Trim())
}

function Get-BrandTokens {
    param([string]$Brand)
    $n = Normalize-Text $Brand
    $tokens = $n -split '\s+'
    $expanded = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tokens) {
        if ($t) { $expanded.Add($t) }
    }

    # Brand aliases used in page titles.
    switch ($Brand.ToUpper()) {
        "GM_CHEVY_GMC_CADILLAC" { foreach ($a in @("CHEVROLET", "CHEVY", "GMC", "CADILLAC", "BUICK")) { $expanded.Add($a) } }
        "CHRYSLER_DODGE_JEEP"   { foreach ($a in @("CHRYSLER", "DODGE", "JEEP")) { $expanded.Add($a) } }
        "LDV_AUTOMOTIVE"        { $expanded.Add("LDV") }
    }
    return $expanded | Select-Object -Unique
}

function Get-ModelTokens {
    param([string]$Model)
    $n = Normalize-Text $Model
    return ($n -split '\s+') | Where-Object { $_ -and $_.Length -ge 2 } | Select-Object -Unique
}

function Is-CarPage {
    param([string]$Extract)
    if (-not $Extract) { return $false }
    $u = $Extract.ToUpper()
    return ($u -like "*AUTOMOBILE*") -or ($u -like "*CAR*") -or ($u -like "*VEHICLE*")
}

function Select-WikipediaImage {
    param(
        [string]$Brand,
        [string]$Model
    )

    $brandTokens = Get-BrandTokens -Brand $Brand
    $modelTokens = Get-ModelTokens -Model $Model
    if ($modelTokens.Count -eq 0) { return $null }

    $query = "$Brand $Model car"
    $searchUrl = "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=$([uri]::EscapeDataString($query))&format=json&srlimit=10"

    try {
        $search = Invoke-RestMethod -Uri $searchUrl -Method Get -Headers @{ "User-Agent" = "CarsModelCurator/1.0 (local)" }
    } catch {
        return $null
    }

    if (-not $search.query.search) { return $null }

    foreach ($item in $search.query.search) {
        $title = $item.title
        $titleNorm = Normalize-Text $title

        $modelHit = $false
        foreach ($mt in $modelTokens) {
            if ($titleNorm -like "*$mt*") { $modelHit = $true; break }
        }
        if (-not $modelHit) { continue }

        $brandHit = $false
        foreach ($bt in $brandTokens) {
            if ($titleNorm -like "*$bt*") { $brandHit = $true; break }
        }
        if (-not $brandHit) { continue }

        $sumUrl = "https://en.wikipedia.org/api/rest_v1/page/summary/$([uri]::EscapeDataString($title))"
        try {
            $sum = Invoke-RestMethod -Uri $sumUrl -Method Get -Headers @{ "User-Agent" = "CarsModelCurator/1.0 (local)" }
        } catch {
            continue
        }

        if (-not $sum.thumbnail -or -not $sum.thumbnail.source) { continue }
        if (-not (Is-CarPage -Extract $sum.extract)) { continue }

        return [PSCustomObject]@{
            Title = $title
            Url = $sum.thumbnail.source
        }
    }

    return $null
}

$records = New-Object System.Collections.Generic.List[object]
$brands = Get-ChildItem -Path $root -Directory | Where-Object { $_.Name -notin @(".git", "model-images", "scripts") }

foreach ($brand in $brands) {
    $models = Get-ChildItem -Path $brand.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "UNCLASSIFIED" }
    foreach ($model in $models) {
        $brandName = $brand.Name
        $modelName = $model.Name
        $brandOut = Join-Path $imagesRoot $brandName
        if (!(Test-Path $brandOut)) {
            New-Item -Path $brandOut -ItemType Directory | Out-Null
        }

        $safeModel = ($modelName -replace '[^A-Za-z0-9_\-]', '_')
        $outFile = Join-Path $brandOut ($safeModel + ".jpg")

        $sel = Select-WikipediaImage -Brand $brandName -Model $modelName
        if ($sel) {
            try {
                Invoke-WebRequest -Uri $sel.Url -OutFile $outFile -Headers @{ "User-Agent" = "CarsModelCurator/1.0 (local)" }
                $status = "downloaded"
                $sourceTitle = $sel.Title
                $sourceUrl = $sel.Url
                $local = $outFile
            } catch {
                $status = "failed_download"
                $sourceTitle = $sel.Title
                $sourceUrl = $sel.Url
                $local = ""
            }
        } else {
            $status = "not_found"
            $sourceTitle = ""
            $sourceUrl = ""
            $local = ""
        }

        $records.Add([PSCustomObject]@{
            Brand = $brandName
            Model = $modelName
            Status = $status
            SourceTitle = $sourceTitle
            SourceUrl = $sourceUrl
            LocalImage = $local
        })
    }
}

$records | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
$records | Where-Object { $_.Status -ne "downloaded" } | Export-Csv -Path $missingPath -NoTypeInformation -Encoding UTF8

$downloaded = ($records | Where-Object { $_.Status -eq "downloaded" }).Count
$notFound = ($records | Where-Object { $_.Status -eq "not_found" }).Count
$failed = ($records | Where-Object { $_.Status -eq "failed_download" }).Count

Write-Output "Manifest: $manifestPath"
Write-Output "Downloaded: $downloaded"
Write-Output "Not found: $notFound"
Write-Output "Failed download: $failed"
