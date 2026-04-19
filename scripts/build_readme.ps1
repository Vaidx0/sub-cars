param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"

$readmePath = Join-Path $Root "README.md"
$imagesRoot = Join-Path $Root "model-images"
$manifestPath = Join-Path $imagesRoot "manifest.csv"
$culture = [System.Globalization.CultureInfo]::InvariantCulture

function Encode-RelativePath {
    param([string]$RelativePath)

    $normalized = $RelativePath -replace '\\', '/'
    $segments = $normalized -split '/'
    $encodedSegments = foreach ($segment in $segments) {
        if ($segment -eq ".") {
            "."
        } elseif ($segment -eq "") {
            ""
        } else {
            [uri]::EscapeDataString($segment)
        }
    }

    return ($encodedSegments -join '/')
}

function Format-Frequency {
    param([string]$RawValue)

    if ([string]::IsNullOrWhiteSpace($RawValue)) {
        return "Unknown"
    }

    $number = 0.0
    if ([double]::TryParse($RawValue.Trim(), [System.Globalization.NumberStyles]::Any, $culture, [ref]$number)) {
        return [string]::Format($culture, "{0:0.000} MHz", ($number / 1000000.0))
    }

    return $RawValue
}

function Html-Encode {
    param([string]$Value)

    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function Get-RelativePathCompat {
    param(
        [string]$BasePath,
        [string]$TargetPath
    )

    $baseUri = [uri]((Resolve-Path $BasePath).Path.TrimEnd('\') + '\')
    $targetUri = [uri](Resolve-Path $TargetPath).Path
    $relativeUri = $baseUri.MakeRelativeUri($targetUri)
    return [uri]::UnescapeDataString($relativeUri.ToString()) -replace '/', '\'
}

$manifestMap = @{}
if (Test-Path $manifestPath) {
    Import-Csv -Path $manifestPath | ForEach-Object {
        $manifestMap["$($_.Brand)|$($_.Model)"] = $_
    }
}

$models = New-Object "System.Collections.Generic.List[object]"
$brands = Get-ChildItem -Path $Root -Directory |
    Where-Object { $_.Name -notin @(".git", "model-images", "scripts") } |
    Sort-Object Name

foreach ($brand in $brands) {
    $modelDirs = Get-ChildItem -Path $brand.FullName -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "UNCLASSIFIED" } |
        Sort-Object Name

    foreach ($modelDir in $modelDirs) {
        $subFiles = Get-ChildItem -Path $modelDir.FullName -Recurse -Filter *.sub -File -ErrorAction SilentlyContinue |
            Sort-Object FullName

        if ($subFiles.Count -eq 0) {
            continue
        }

        $safeModel = ($modelDir.Name -replace '[^A-Za-z0-9_\-]', '_')
        $localImageRelative = Join-Path "model-images" (Join-Path $brand.Name ($safeModel + ".jpg"))
        $localImagePath = Join-Path $Root $localImageRelative
        $manifestEntry = $manifestMap["$($brand.Name)|$($modelDir.Name)"]

        $imageHtml = "Aucune image"
        $imageType = "missing"
        if (Test-Path $localImagePath) {
            $encodedImagePath = Encode-RelativePath -RelativePath $localImageRelative
            $altText = Html-Encode "$($brand.Name) $($modelDir.Name)"
            $imageHtml = "<img src=""$encodedImagePath"" alt=""$altText"" width=""160"">"
            $imageType = "local"
        } elseif ($manifestEntry -and $manifestEntry.SourceUrl) {
            $altText = Html-Encode "$($brand.Name) $($modelDir.Name)"
            $imageHtml = "<img src=""$($manifestEntry.SourceUrl)"" alt=""$altText"" width=""160"">"
            $imageType = "remote"
        }

        $fileLinks = New-Object "System.Collections.Generic.List[string]"
        $frequencies = New-Object "System.Collections.Generic.List[string]"
        foreach ($subFile in $subFiles) {
            $relativePath = Get-RelativePathCompat -BasePath $Root -TargetPath $subFile.FullName
            $encodedPath = Encode-RelativePath -RelativePath $relativePath
            $displayName = Html-Encode $subFile.Name
            $fileLinks.Add("<a href=""$encodedPath""><code>$displayName</code></a>") | Out-Null

            $frequencyLine = Select-String -Path $subFile.FullName -Pattern '^Frequency:\s*(.+)$' | Select-Object -First 1
            if ($frequencyLine) {
                $freqText = Format-Frequency -RawValue $frequencyLine.Matches[0].Groups[1].Value
            } else {
                $freqText = "Unknown"
            }

            $frequencies.Add((Html-Encode $freqText)) | Out-Null
        }

        $modelRelativePath = Get-RelativePathCompat -BasePath $Root -TargetPath $modelDir.FullName
        $encodedModelPath = Encode-RelativePath -RelativePath $modelRelativePath
        $modelLabel = Html-Encode "$($brand.Name) / $($modelDir.Name)"
        $modelHtml = "<a href=""$encodedModelPath""><strong>$modelLabel</strong></a><br>$($subFiles.Count) fichier(s)"

        $models.Add([PSCustomObject]@{
            Brand = $brand.Name
            Model = $modelDir.Name
            ImageHtml = $imageHtml
            ImageType = $imageType
            LinksHtml = ($fileLinks -join "<br>")
            FrequencyHtml = ($frequencies -join "<br>")
            ModelHtml = $modelHtml
            SubCount = $subFiles.Count
        }) | Out-Null
    }
}

$modelCount = $models.Count
$subCount = ($models | Measure-Object -Property SubCount -Sum).Sum
$allSubCount = (Get-ChildItem -Path $Root -Recurse -Filter *.sub -File -ErrorAction SilentlyContinue | Measure-Object).Count
$localImageCount = ($models | Where-Object { $_.ImageType -eq "local" }).Count
$remoteImageCount = ($models | Where-Object { $_.ImageType -eq "remote" }).Count
$missingImageCount = ($models | Where-Object { $_.ImageType -eq "missing" }).Count

$builder = New-Object System.Text.StringBuilder
[void]$builder.AppendLine("# Cars Dataset")
[void]$builder.AppendLine()
[void]$builder.AppendLine("Ce README est genere a partir de l'arborescence du depot.")
[void]$builder.AppendLine('Le tableau suit l''ordre demande: image de la voiture, liens vers les fichiers `.sub`, frequence, puis marque / modele.')
[void]$builder.AppendLine()
[void]$builder.AppendLine("## Resume")
[void]$builder.AppendLine()
[void]$builder.AppendLine("- Modeles indexes: $modelCount")
[void]$builder.AppendLine(("- Fichiers `.sub` affiches dans le tableau: " + $subCount))
[void]$builder.AppendLine(("- Fichiers `.sub` totaux dans le depot: " + $allSubCount))
[void]$builder.AppendLine("- Images locales: $localImageCount")
[void]$builder.AppendLine("- Images distantes de secours: $remoteImageCount")
[void]$builder.AppendLine("- Modeles sans image: $missingImageCount")
[void]$builder.AppendLine()
[void]$builder.AppendLine("Les images distantes viennent du manifeste genere a partir d'une recherche web et peuvent changer si la source distante change.")
[void]$builder.AppendLine()
[void]$builder.AppendLine('Les dossiers `UNCLASSIFIED` restent dans le depot, mais ne sont pas affiches ici car ils ne correspondent pas a un modele unique.')
[void]$builder.AppendLine()
[void]$builder.AppendLine("## Catalogue")
[void]$builder.AppendLine()
[void]$builder.AppendLine("<table>")
[void]$builder.AppendLine("  <thead>")
[void]$builder.AppendLine("    <tr>")
[void]$builder.AppendLine("      <th>Image</th>")
[void]$builder.AppendLine("      <th>Liens .sub</th>")
[void]$builder.AppendLine("      <th>Frequence(s)</th>")
[void]$builder.AppendLine("      <th>Marque / modele</th>")
[void]$builder.AppendLine("    </tr>")
[void]$builder.AppendLine("  </thead>")
[void]$builder.AppendLine("  <tbody>")

foreach ($entry in $models) {
    [void]$builder.AppendLine("    <tr>")
    [void]$builder.AppendLine("      <td>$($entry.ImageHtml)</td>")
    [void]$builder.AppendLine("      <td>$($entry.LinksHtml)</td>")
    [void]$builder.AppendLine("      <td>$($entry.FrequencyHtml)</td>")
    [void]$builder.AppendLine("      <td>$($entry.ModelHtml)</td>")
    [void]$builder.AppendLine("    </tr>")
}

[void]$builder.AppendLine("  </tbody>")
[void]$builder.AppendLine("</table>")
[void]$builder.AppendLine()
[void]$builder.AppendLine("## Regenerer")
[void]$builder.AppendLine()
[void]$builder.AppendLine('```powershell')
[void]$builder.AppendLine("powershell -ExecutionPolicy Bypass -File .\scripts\fetch_model_images_bing.ps1")
[void]$builder.AppendLine("powershell -ExecutionPolicy Bypass -File .\scripts\build_readme.ps1")
[void]$builder.AppendLine('```')

[System.IO.File]::WriteAllText($readmePath, $builder.ToString(), ([System.Text.UTF8Encoding]::new($false)))

Write-Output "README generated at $readmePath"
