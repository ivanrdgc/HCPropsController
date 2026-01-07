# PowerShell script to patch SQX-exported MQL5 files to respect GV_DISABLE variable
# Script de PowerShell para parchear archivos MQL5 exportados por SQX para respetar la variable GV_DISABLE
#
# FORMAS DE USO (de mas facil a mas avanzada):
#   1. Doble clic en "Ejecutar-Parcheador.bat" - Abre interfaz grafica interactiva (RECOMENDADO)
#   2. Arrastrar archivo/carpeta al script - Procesa automaticamente
#   3. Doble clic en este script (.ps1) - Abre interfaz grafica interactiva
#   4. Desde PowerShell: .\Patch-SQX-GV-Disable.ps1 -Path "C:\Ruta\A\Carpeta"
#   5. Desde PowerShell: .\Patch-SQX-GV-Disable.ps1 -Path "C:\Ruta\A\Archivo.mq5"
#
# NOTA: Este script requiere que "Ejecutar-Parcheador.bat" este en la misma carpeta
#       si se ejecuta mediante el metodo 1.

param(
    [Parameter(Mandatory=$false)]
    [string]$Path
)

# Funcion para mostrar interfaz grafica de seleccion
function Show-FolderDialog {
    Add-Type -AssemblyName System.Windows.Forms
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.Description = "Seleccione la carpeta que contiene los archivos .mq5 a parchear"
    $folderDialog.ShowNewFolderButton = $false
    
    if ($folderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $folderDialog.SelectedPath
    }
    return $null
}

function Show-FileDialog {
    Add-Type -AssemblyName System.Windows.Forms
    $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $fileDialog.Filter = "Archivos MQL5 (*.mq5)|*.mq5|Todos los archivos (*.*)|*.*"
    $fileDialog.Title = "Seleccione el archivo .mq5 a parchear"
    $fileDialog.Multiselect = $false
    
    if ($fileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $fileDialog.FileName
    }
    return $null
}

# Si no se proporciono Path, usar interfaz grafica o modo interactivo
if (-not $Path) {
    # Limpiar pantalla para mejor presentacion
    Clear-Host
    
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Parcheador de Archivos SQX MQL5      " -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Este programa modifica archivos .mq5 para respetar" -ForegroundColor Gray
    Write-Host "la variable global HCPropsControllerDisableTrading" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Seleccione una opcion:" -ForegroundColor Yellow
    Write-Host "  1. Seleccionar carpeta (procesara todos los .mq5)" -ForegroundColor White
    Write-Host "  2. Seleccionar archivo individual" -ForegroundColor White
    Write-Host "  3. Cancelar" -ForegroundColor White
    Write-Host ""
    
    $choice = Read-Host "Ingrese su opcion (1-3)"
    
    switch ($choice) {
        "1" {
            $Path = Show-FolderDialog
            if (-not $Path) {
                Write-Host "Operacion cancelada." -ForegroundColor Yellow
                exit 0
            }
        }
        "2" {
            $Path = Show-FileDialog
            if (-not $Path) {
                Write-Host "Operacion cancelada." -ForegroundColor Yellow
                exit 0
            }
        }
        "3" {
            Write-Host "Operacion cancelada." -ForegroundColor Yellow
            exit 0
        }
        default {
            Write-Host "Opcion invalida. Saliendo..." -ForegroundColor Red
            exit 1
        }
    }
}

# Si el Path viene de arrastrar y soltar, puede tener comillas
$Path = $Path.Trim('"').Trim("'")

# Mostrar informacion cuando se proporciona path directamente
if ($PSBoundParameters.ContainsKey('Path')) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Parcheador de Archivos SQX MQL5      " -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}

# Validar que la ruta existe
if (-not (Test-Path $Path)) {
    Write-Host ""
    Write-Host "ERROR: La ruta '$Path' no existe." -ForegroundColor Red
    Write-Host "Por favor, verifique la ruta e intente nuevamente." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Presione Enter para salir"
    exit 1
}

# Determine if path is a file or folder
$pathItem = Get-Item $Path
$mq5Files = @()

if ($pathItem.PSIsContainer) {
    # Es una carpeta - obtener todos los archivos .mq5
    $mq5Files = Get-ChildItem -Path $Path -Filter "*.mq5" -File -Recurse
    
    if ($mq5Files.Count -eq 0) {
        Write-Host ""
        Write-Host "ADVERTENCIA: No se encontraron archivos .mq5 en la carpeta:" -ForegroundColor Yellow
        Write-Host "  $Path" -ForegroundColor Gray
        Write-Host ""
        Read-Host "Presione Enter para salir"
        exit 0
    }
    
    Write-Host ""
    Write-Host "Se encontraron $($mq5Files.Count) archivo(s) .mq5 para procesar..." -ForegroundColor Cyan
    Write-Host ""
} else {
    # Es un archivo - verificar que sea .mq5
    if ($pathItem.Extension -ne ".mq5") {
        Write-Host ""
        Write-Host "ERROR: El archivo '$Path' no es un archivo .mq5." -ForegroundColor Red
        Write-Host "Por favor, seleccione un archivo con extension .mq5" -ForegroundColor Yellow
        Write-Host ""
        Read-Host "Presione Enter para salir"
        exit 1
    }
    
    # Procesar solo este archivo
    $mq5Files = @($pathItem)
    Write-Host ""
    Write-Host "Procesando archivo: $($pathItem.Name)" -ForegroundColor Cyan
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
        Write-Host "[$fileIndex/$($mq5Files.Count)] Procesando: $($file.Name)..." -ForegroundColor White
        
        # Leer contenido del archivo
        $content = Get-Content -Path $file.FullName -Raw -Encoding UTF8
        
        # Verificar si el archivo contiene la funcion SQX
        if ($content -notmatch [regex]::Escape($functionSignature)) {
            Write-Host "  [!] Omitido: El archivo no contiene la funcion sqHandleTradingOptions()" -ForegroundColor Yellow
            $skippedCount++
            continue
        }
        
        # Verificar si ya esta parcheado
        if ($content -match "HCPropsControllerDisableTrading") {
            Write-Host "  [!] Omitido: El archivo ya contiene la verificacion GV_DISABLE" -ForegroundColor Yellow
            $skippedCount++
            continue
        }
        
        # Buscar la funcion y agregar la verificacion al inicio
        # Patron: bool sqHandleTradingOptions() { ... }
        # Necesitamos encontrar la llave de apertura y agregar la verificacion justo despues
        # Manejar diferentes patrones de espacios en blanco (espacios, tabs, saltos de linea)
        
        # Patron: firma de funcion seguida de espacios opcionales y llave de apertura
        # Usar un patron mas simple que maneje cualquier espacio en blanco incluyendo saltos de linea
        $pattern = "(bool\s+sqHandleTradingOptions\s*\(\s*\)\s*\{)"
        $replacement = "`$1`r`n$checkCode"
        
        # Probar si el patron coincide usando regex
        $regex = New-Object System.Text.RegularExpressions.Regex($pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
        
        if ($regex.IsMatch($content)) {
            # Realizar el reemplazo
            $newContent = $regex.Replace($content, $replacement)
            
            # Crear respaldo
            $backupPath = "$($file.FullName).backup"
            Copy-Item -Path $file.FullName -Destination $backupPath -Force
            Write-Host "  [BACKUP] Respaldo creado: $($file.Name).backup" -ForegroundColor Gray
            
            # Escribir contenido parcheado
            [System.IO.File]::WriteAllText($file.FullName, $newContent, [System.Text.Encoding]::UTF8)
            
            Write-Host "  [OK] Parcheado exitosamente!" -ForegroundColor Green
            $patchedCount++
        } else {
            Write-Host "  [ERROR] No se pudo encontrar el patron de funcion para parchear" -ForegroundColor Red
            $errorCount++
        }
    }
    catch {
        Write-Host "  [ERROR] Error al procesar archivo: $_" -ForegroundColor Red
        $errorCount++
    }
}

$separator = "=" * 60
Write-Host ""
Write-Host $separator -ForegroundColor Cyan
Write-Host "                    RESUMEN" -ForegroundColor Cyan
Write-Host $separator -ForegroundColor Cyan
Write-Host "  [OK] Archivos parcheados: $patchedCount" -ForegroundColor Green
Write-Host "  [!] Archivos omitidos:  $skippedCount" -ForegroundColor Yellow
if ($errorCount -gt 0) {
    Write-Host "  [ERROR] Errores:            $errorCount" -ForegroundColor Red
} else {
    Write-Host "  [ERROR] Errores:            $errorCount" -ForegroundColor Green
}
Write-Host $separator -ForegroundColor Cyan
Write-Host ""

if ($patchedCount -gt 0) {
    Write-Host "Proceso completado!" -ForegroundColor Green
    Write-Host "Los archivos originales se guardaron con extension .backup" -ForegroundColor Gray
    Write-Host ""
}

# Pausar para que el usuario pueda ver los resultados
if (-not $PSBoundParameters.ContainsKey('Path')) {
    Write-Host "Presione Enter para salir..." -ForegroundColor Gray
    Read-Host
}
