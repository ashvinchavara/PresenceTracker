$files = Get-ChildItem -Path android -Recurse -File
foreach ($file in $files) {
    if ($file.Mode -like "*l*") {
        Write-Host "Fixing $($file.FullName)"
        $content = [System.IO.File]::ReadAllBytes($file.FullName)
        Remove-Item $file.FullName -Force
        [System.IO.File]::WriteAllBytes($file.FullName, $content)
    }
}
