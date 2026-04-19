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
    "MERCEDES"              = @("Mercedes-Benz", "Mercedes")
    "TOYOTA"                = @("Toyota", "Lexus")
    "VOLKSWAGEN"            = @("Volkswagen", "VW")
}

$modelAliasMap = @{
    "ATTO3"        = "Atto 3"
    "CRUISER06"    = "PT Cruiser"
    "CRV"          = "CR-V"
    "CX50"         = "CX-50"
    "ESTIMA"       = "Estima"
    "GLE350"       = "GLE 350"
    "HRV"          = "HR-V"
    "IS300"        = "IS 300"
    "LACROSS"      = "LaCrosse"
    "NX200T"       = "NX 200t"
    "RAV4"         = "RAV4"
    "RX8"          = "RX-8"
    "SANTA_FE"     = "Santa Fe"
    "TRAIL_BLAZER" = "Trailblazer"
    "TYPE"         = "Tipo"
}

$queryOverrideMap = @{
    "BMW|X5"                    = @("BMW X5 SUV side view", "BMW X5 side profile")
    "FORD|MONDEO"               = @("Ford Mondeo side view", "Ford Mondeo wagon side view")
    "HYUNDAI|G90"               = @("Genesis G90 side view", "Genesis G90 sedan side view")
    "HYUNDAI|GV80"              = @("Genesis GV80 SUV side view", "Genesis GV80 side view")
    "NISSAN|VERSA"              = @("Nissan Versa sedan side view", "Nissan Versa side view")
    "PEUGEOT|PARTNER"           = @("Peugeot Partner van side view", "Peugeot Partner side view")
    "SUBARU|OUTBACK"            = @("Subaru Outback wagon side view", "Subaru Outback side view")
    "TOYOTA|IS"                 = @("Lexus IS sedan side view", "Lexus IS side view")
    "TOYOTA|NX200T"             = @("Lexus NX 200t side view", "Lexus NX200t side view")
    "VOLKSWAGEN|GOLF"           = @("Volkswagen Golf hatchback side view", "Volkswagen Golf side view")
    "VOLVO|S40"                 = @("Volvo S40 sedan side view", "Volvo S40 side view")
}

$skipImageKeys = @(
    "FIAT|C1",
    "FIAT|C3",
    "FIAT|C9",
    "LDV_AUTOMOTIVE|T80"
)

$detectedBrandMap = @{
    "ACURA"      = "Acura"
    "BUICK"      = "Buick"
    "CADI"       = "Cadillac"
    "CADILLAC"   = "Cadillac"
    "CHEVROLET"  = "Chevrolet"
    "CHEVY"      = "Chevrolet"
    "CHRYSLER"   = "Chrysler"
    "DODGE"      = "Dodge"
    "FIAT"       = "Fiat"
    "FORD"       = "Ford"
    "GENESIS"    = "Genesis"
    "GMC"        = "GMC"
    "HONDA"      = "Honda"
    "HYUNDAI"    = "Hyundai"
    "JEEP"       = "Jeep"
    "KIA"        = "Kia"
    "LDV"        = "LDV"
    "LEXUS"      = "Lexus"
    "MAZDA"      = "Mazda"
    "MERC"       = "Mercedes-Benz"
    "MERCEDES"   = "Mercedes-Benz"
    "NISSAN"     = "Nissan"
    "OPEL"       = "Opel"
    "PEUGEOT"    = "Peugeot"
    "RENAULT"    = "Renault"
    "SKODA"      = "Skoda"
    "SUBARU"     = "Subaru"
    "TOYOTA"     = "Toyota"
    "VOLKSWAGEN" = "Volkswagen"
    "VOLVO"      = "Volvo"
    "VW"         = "Volkswagen"
    "BYD"        = "BYD"
    "BMW"        = "BMW"
}

$badKeywords = @(
    "alamy", "art", "badge", "brochure", "clipart", "dashboard", "dreamstime",
    "drawing", "emblem", "engine", "favicon", "footer_twitter", "freepik",
    "ftcdn", "hdwall", "icon", "illustration", "interior", "layout", "logo",
    "manual", "mechanical", "pattern", "pinterest", "pinimg", "pngitem",
    "monitor", "rare-gallery", "render", "rim", "screen", "seat", "shutterstock", "steering",
    "stablediffusion", "sticker", "stock", "suwalls", "teahub", "template",
    "tire", "toppng", "tyre", "utilitaires.drivek", "vector", "vhv.rs",
    "wallpaper", "wallpapercave", "wallpaperaccess", "wallpapersden", "wallup",
    "wheel"
)

function Normalize-Text {
    param([string]$Text)

    if (-not $Text) { return "" }
    return (($Text.ToUpperInvariant() -replace '[^A-Z0-9]+', ' ').Trim())
}

function Invoke-WithRetry {
    param(
        [scriptblock]$Action,
        [int]$MaxAttempts = 3,
        [int]$InitialDelaySeconds = 2
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $Action
        } catch {
            if ($attempt -ge $MaxAttempts) {
                throw
            }

            Start-Sleep -Seconds ([math]::Min(15, $InitialDelaySeconds * $attempt))
        }
    }
}

function Get-SearchBrand {
    param(
        [string]$Brand,
        [string]$ModelPath
    )

    $files = Get-ChildItem -Path $ModelPath -Recurse -Filter *.sub -File -ErrorAction SilentlyContinue |
        Select-Object -First 20

    foreach ($file in $files) {
        $tokens = (Normalize-Text $file.BaseName) -split '\s+'
        foreach ($token in $tokens) {
            if ($detectedBrandMap.ContainsKey($token)) {
                return $detectedBrandMap[$token]
            }
        }
    }

    if ($brandAliasMap.ContainsKey($Brand)) {
        return $brandAliasMap[$Brand][0]
    }

    return ($Brand -replace '_', ' ')
}

function Get-SearchModel {
    param([string]$Model)

    if ($modelAliasMap.ContainsKey($Model)) {
        return $modelAliasMap[$Model]
    }

    $value = ($Model -replace '_', ' ').Trim()
    $value = $value -replace '([A-Za-z]+)(\d+)', '$1 $2'
    $value = $value -replace '(\d+)([A-Za-z]+)', '$1 $2'
    return $value
}

function Get-BingCandidates {
    param([string]$Query)

    $encodedQuery = [uri]::EscapeDataString($Query)
    $url = "https://www.bing.com/images/search?q=$encodedQuery&form=HDRSC3"
    $html = Invoke-WithRetry -Action {
        (Invoke-WebRequest -Uri $url -Headers @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" }).Content
    }

    $matches = [regex]::Matches($html, 'murl&quot;:&quot;(.*?)&quot;')
    $results = New-Object "System.Collections.Generic.List[string]"

    foreach ($match in $matches) {
        $decoded = [System.Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
        if ([string]::IsNullOrWhiteSpace($decoded)) { continue }
        if (-not $results.Contains($decoded)) {
            $results.Add($decoded) | Out-Null
        }
    }

    return $results
}

function Test-AllowedUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }

    $normalized = $Url.ToLowerInvariant()
    foreach ($badKeyword in $badKeywords) {
        if ($normalized -like "*$badKeyword*") {
            return $false
        }
    }

    return $true
}

function Get-Queries {
    param(
        [string]$Brand,
        [string]$Model,
        [string]$SearchBrand,
        [string]$SearchModel
    )

    $key = "$Brand|$Model"
    if ($queryOverrideMap.ContainsKey($key)) {
        return $queryOverrideMap[$key]
    }

    return @(
        "$SearchBrand $SearchModel car side view",
        "$SearchBrand $SearchModel car front side"
    )
}

$records = New-Object "System.Collections.Generic.List[object]"
$models = @()

Get-ChildItem -Path $Root -Directory |
    Where-Object { $_.Name -notin @(".git", "model-images", "scripts") } |
    Sort-Object Name |
    ForEach-Object {
        $brandDir = $_
        Get-ChildItem -Path $brandDir.FullName -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne "UNCLASSIFIED" } |
            Sort-Object Name |
            ForEach-Object {
                $models += [PSCustomObject]@{
                    Brand = $brandDir.Name
                    Model = $_.Name
                    Path = $_.FullName
                }
            }
    }

$total = $models.Count

for ($index = 0; $index -lt $total; $index++) {
    $entry = $models[$index]
    $skipKey = "$($entry.Brand)|$($entry.Model)"
    $searchBrand = Get-SearchBrand -Brand $entry.Brand -ModelPath $entry.Path
    $searchModel = Get-SearchModel -Model $entry.Model
    $queries = Get-Queries -Brand $entry.Brand -Model $entry.Model -SearchBrand $searchBrand -SearchModel $searchModel

    Write-Output ("[{0}/{1}] {2}/{3}" -f ($index + 1), $total, $entry.Brand, $entry.Model)

    $status = "not_found"
    $sourceUrl = ""
    $sourceTitle = ""

    if ($skipImageKeys -contains $skipKey) {
        Write-Output "  skipped: ambiguous model, no safe image selected"
        $records.Add([PSCustomObject]@{
            Brand = $entry.Brand
            Model = $entry.Model
            Status = $status
            SourceTitle = $sourceTitle
            SourceUrl = $sourceUrl
            LocalImage = ""
        }) | Out-Null

        Start-Sleep -Milliseconds 100
        continue
    }

    foreach ($query in $queries) {
        Write-Output ("  search: {0}" -f $query)

        try {
            $candidates = Get-BingCandidates -Query $query
        } catch {
            Write-Output ("  error: {0}" -f $_.Exception.Message)
            continue
        }

        $selected = $null
        foreach ($candidate in ($candidates | Select-Object -First 12)) {
            if (Test-AllowedUrl -Url $candidate) {
                $selected = $candidate
                break
            }
        }

        if ($selected) {
            $status = "found_remote"
            $sourceUrl = $selected
            $sourceTitle = $query
            Write-Output ("  image: {0}" -f $selected)
            break
        }

        Write-Output "  no usable image"
    }

    $records.Add([PSCustomObject]@{
        Brand = $entry.Brand
        Model = $entry.Model
        Status = $status
        SourceTitle = $sourceTitle
        SourceUrl = $sourceUrl
        LocalImage = ""
    }) | Out-Null

    Start-Sleep -Milliseconds 250
}

$records | Export-Csv -Path $manifestPath -NoTypeInformation -Encoding UTF8
$records | Where-Object { $_.Status -ne "found_remote" } | Export-Csv -Path $missingPath -NoTypeInformation -Encoding UTF8

$found = ($records | Where-Object { $_.Status -eq "found_remote" }).Count
$missing = ($records | Where-Object { $_.Status -ne "found_remote" }).Count

Write-Output ""
Write-Output "Manifest: $manifestPath"
Write-Output "Found remote images: $found"
Write-Output "Missing images: $missing"
