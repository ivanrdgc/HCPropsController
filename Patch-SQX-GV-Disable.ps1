# PowerShell script to patch SQX-exported MQL5 files to respect GV_DISABLE variable
#
# WAYS TO USE (from easiest to most advanced):
#   1. Double-click "Run-Patcher.bat" - Opens interactive graphical interface (RECOMMENDED)
#   2. Drag a file/folder onto the script - Processes automatically
#   3. Double-click this script (.ps1) - Opens interactive graphical interface
#   4. From PowerShell: .\Patch-SQX-GV-Disable.ps1 -Path "C:\Path\To\Folder"
#   5. From PowerShell: .\Patch-SQX-GV-Disable.ps1 -Path "C:\Path\To\File.mq5"
#
# NOTE: This script requires that "Run-Patcher.bat" be in the same folder
#       if run via method 1.

param(
    [Parameter(Mandatory=$false)]
    [string]$Path
)

# Function to show graphical selection interface
function Show-FolderDialog {
    Add-Type -AssemblyName System.Windows.Forms
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.Description = "Select the folder that contains the .mq5 files to patch"
    $folderDialog.ShowNewFolderButton = $false

    if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $folderDialog.SelectedPath
    }
    return $null
}

function Show-FileDialog {
    Add-Type -AssemblyName System.Windows.Forms
    $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $fileDialog.Filter = "MQL5 Files (*.mq5)|*.mq5|All files (*.*)|*.*"
    $fileDialog.Title = "Select the .mq5 file to patch"
    $fileDialog.Multiselect = $false

    if ($fileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $fileDialog.FileName
    }
    return $null
}

# If no Path was provided, use graphical interface or interactive mode
if (-not $Path) {
    # Clear screen for better presentation
    Clear-Host

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  SQX MQL5 File Patcher                " -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "This program modifies .mq5 files to respect" -ForegroundColor Gray
    Write-Host "the global variable HCPropsControllerDisableTrading" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Select an option:" -ForegroundColor Yellow
    Write-Host "  1. Select folder (will process all .mq5)" -ForegroundColor White
    Write-Host "  2. Select individual file" -ForegroundColor White
    Write-Host "  3. Cancel" -ForegroundColor White
    Write-Host ""

    $choice = Read-Host "Enter your option (1-3)"

    switch ($choice) {
        "1" {
            $Path = Show-FolderDialog
            if (-not $Path) {
                Write-Host "Operation cancelled." -ForegroundColor Yellow
                exit 0
            }
        }
        "2" {
            $Path = Show-FileDialog
            if (-not $Path) {
                Write-Host "Operation cancelled." -ForegroundColor Yellow
                exit 0
            }
        }
        "3" {
            Write-Host "Operation cancelled." -ForegroundColor Yellow
            exit 0
        }
        default {
            Write-Host "Invalid option. Exiting..." -ForegroundColor Red
            exit 1
        }
    }
}

# If the Path comes from drag and drop, it may have quotes
$Path = $Path.Trim('"').Trim("'")

# Show information when path is provided directly
if ($PSBoundParameters.ContainsKey('Path')) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  SQX MQL5 File Patcher                " -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}

# Validate that the path exists
if (-not (Test-Path $Path)) {
    Write-Host ""
    Write-Host "ERROR: The path '$Path' does not exist." -ForegroundColor Red
    Write-Host "Please verify the path and try again." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

# Determine if path is a file or folder
$pathItem = Get-Item $Path
$mq5Files = @()

if ($pathItem.PSIsContainer) {
    # It is a folder - get all .mq5 files
    $mq5Files = Get-ChildItem -Path $Path -Filter "*.mq5" -File -Recurse

    if ($mq5Files.Count -eq 0) {
        Write-Host ""
        Write-Host "WARNING: No .mq5 files were found in the folder:" -ForegroundColor Yellow
        Write-Host "  $Path" -ForegroundColor Gray
        Write-Host ""
        Read-Host "Press Enter to exit"
        exit 0
    }

    Write-Host ""
    Write-Host "Found $($mq5Files.Count) .mq5 file(s) to process..." -ForegroundColor Cyan
    Write-Host ""
} else {
    # It is a file - verify that it is .mq5
    if ($pathItem.Extension -ne ".mq5") {
        Write-Host ""
        Write-Host "ERROR: The file '$Path' is not a .mq5 file." -ForegroundColor Red
        Write-Host "Please select a file with the .mq5 extension" -ForegroundColor Yellow
        Write-Host ""
        Read-Host "Press Enter to exit"
        exit 1
    }

    # Process only this file
    $mq5Files = @($pathItem)
    Write-Host ""
    Write-Host "Processing file: $($pathItem.Name)" -ForegroundColor Cyan
    Write-Host ""
}

# Define the function signature to search for
$functionSignature = "bool sqHandleTradingOptions()"
$checkCode = "   // Check global variable to disable trading`r`n   if(GlobalVariableGet(`"HCPropsControllerDisableTrading`") == 1.0) return false;`r`n"

$patchedCount = 0
$skippedCount = 0
$errorCount = 0

$fileIndex = 0
foreach ($file in $mq5Files) {
    $fileIndex++
    try {
        Write-Host "[$fileIndex/$($mq5Files.Count)] Processing: $($file.Name)..." -ForegroundColor White

        # Read file content
        $content = Get-Content -Path $file.FullName -Raw -Encoding UTF8

        # Check whether the file contains the SQX function
        if ($content -notmatch [regex]::Escape($functionSignature)) {
            Write-Host "  [!] Skipped: The file does not contain the sqHandleTradingOptions() function" -ForegroundColor Yellow
            $skippedCount++
            continue
        }

        # Check whether it is already patched
        if ($content -match "HCPropsControllerDisableTrading") {
            Write-Host "  [!] Skipped: The file already contains the GV_DISABLE check" -ForegroundColor Yellow
            $skippedCount++
            continue
        }

        # Find the function and add the check at the start
        # Pattern: bool sqHandleTradingOptions() { ... }
        # We need to find the opening brace and add the check right after
        # Handle different whitespace patterns (spaces, tabs, line breaks)

        # Pattern: function signature followed by optional whitespace and opening brace
        # Use a simpler pattern that handles any whitespace including line breaks
        $pattern = "(bool\s+sqHandleTradingOptions\s*\(\s*\)\s*\{)"
        $replacement = "`$1`r`n$checkCode"

        # Test whether the pattern matches using regex
        $regex = New-Object System.Text.RegularExpressions.Regex($pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)

        if ($regex.IsMatch($content)) {
            # Perform the replacement
            $newContent = $regex.Replace($content, $replacement)

            # Create backup
            $backupPath = "$($file.FullName).backup"
            Copy-Item -Path $file.FullName -Destination $backupPath -Force
            Write-Host "  [BACKUP] Backup created: $($file.Name).backup" -ForegroundColor Gray

            # Write patched content
            [System.IO.File]::WriteAllText($file.FullName, $newContent, [System.Text.Encoding]::UTF8)

            Write-Host "  [OK] Patched successfully!" -ForegroundColor Green
            $patchedCount++
        } else {
            Write-Host "  [ERROR] Could not find the function pattern to patch" -ForegroundColor Red
            $errorCount++
        }
    }
    catch {
        Write-Host "  [ERROR] Error processing file: $_" -ForegroundColor Red
        $errorCount++
    }
}

$separator = "=" * 60
Write-Host ""
Write-Host $separator -ForegroundColor Cyan
Write-Host "                    SUMMARY" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan
Write-Host "  [OK] Files patched: $patchedCount" -ForegroundColor Green
Write-Host "  [!] Files skipped:  $skippedCount" -ForegroundColor Yellow
if ($errorCount -gt 0) {
    Write-Host "  [ERROR] Errors:            $errorCount" -ForegroundColor Red
} else {
    Write-Host "  [ERROR] Errors:            $errorCount" -ForegroundColor Green
}
Write-Host $separator -ForegroundColor Cyan
Write-Host ""

if ($patchedCount -gt 0) {
    Write-Host "Process completed!" -ForegroundColor Green
    Write-Host "The original files were saved with the .backup extension" -ForegroundColor Gray
    Write-Host ""
}

# Pause so the user can see the results
if (-not $PSBoundParameters.ContainsKey('Path')) {
    Write-Host "Press Enter to exit..." -ForegroundColor Gray
    Read-Host
}
