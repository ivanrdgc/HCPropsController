# HCPropsController - Documentación Completa

## Tabla de Contenidos

1. [HCPropsController.mq5 - Documentación Técnica](#hcpropscontrollermq5---documentación-técnica)
   - [Resumen General](#resumen-general)
   - [Arquitectura Master/Slave](#arquitectura-masterslave)
   - [Parámetros de Entrada](#parámetros-de-entrada)
   - [Variables Globales y de Estado](#variables-globales-y-de-estado)
   - [Funcionalidades Principales](#funcionalidades-principales)
   - [Sistema de Límites y Risk Management](#sistema-de-límites-y-risk-management)
   - [Sincronización Master/Slave](#sincronización-masterslave)
   - [Panel de Información (UI)](#panel-de-información-ui)
   - [Flujo de Ejecución](#flujo-de-ejecución)
   - [Observaciones y Posibles Problemas](#observaciones-y-posibles-problemas)

2. [Parcheador de Archivos SQX MQL5 - Instrucciones de Uso](#parcheador-de-archivos-sqx-mql5---instrucciones-de-uso)
   - [¿Qué hace este programa?](#qué-hace-este-programa)
   - [Archivos del Programa](#archivos-del-programa)
   - [Formas de Usar el Programa](#formas-de-usar-el-programa)
   - [Importante](#importante)
   - [¿Qué Significan los Resultados?](#qué-significan-los-resultados)
   - [Solución de Problemas](#solución-de-problemas)
   - [Notas Técnicas](#notas-técnicas)

---

# HCPropsController.mq5 - Documentación Técnica

## Resumen General

**HCPropsController.mq5** es un Expert Advisor (EA) para MetaTrader 5 diseñado para controlar operaciones de trading en cuentas de tipo "Props" (Prop Trading). El EA opera en dos modos:

- **MODO MASTER**: Ejecuta operaciones con límites de riesgo configurados
- **MODO SLAVE**: Replica las operaciones del Master de forma proporcional

El EA implementa un sistema completo de gestión de riesgos con límites diarios/totales de ganancia/pérdida, control de posiciones paralelas, límite de trades por día, horarios de trading y cierre forzado.

---

## Arquitectura Master/Slave

### Modo MASTER
- Ejecuta operaciones de trading en su propia cuenta
- Aplica todos los límites de riesgo configurados
- Escribe un archivo CSV compartido con el estado de sus posiciones
- Controla el estado de trading mediante variable global (`GV_DISABLE`)
- Archivo generado: `HCPropsController\master_{base64(servidor_cuenta)}.csv` en carpeta `Common`

### Modo SLAVE
- Lee el archivo CSV del Master periódicamente
- Replica las posiciones del Master proporcionalmente al balance inicial
- No aplica límites de riesgo (solo replica)
- Puede invertir las posiciones del Master (`RevertMasterPositions`)
- Puede mapear símbolos diferentes (`MasterSymbolNames` / `SlaveSymbolNames`)
- Detecta conexión/desconexión del Master

### Comunicación
- **Mecanismo**: Archivo CSV en carpeta compartida (FILE_COMMON)
- **Frecuencia**: Cada 1 segundo (OnTimer)
- **Formato CSV**: `symbol;direction;exposure;openPrice;ticket;timeOpen`
- **Exposure**: Volumen relativo al balance inicial del Master (proporcional)
- **Optimización**: Solo escribe/lee cuando hay cambios detectados

---

## Parámetros de Entrada

### Configuración General
- `Mode` (HCMode): `MODE_MASTER` o `MODE_SLAVE`

### Configuración SLAVE (solo en modo SLAVE)
- `MasterServer` (string): Nombre del servidor de la cuenta Master
- `MasterAccountNumber` (long): Número de cuenta del Master
- `RevertMasterPositions` (bool): Si `true`, invierte todas las posiciones (BUY→SELL, SELL→BUY)
- `MasterSymbolNames` (string): Lista de símbolos del Master separados por coma (ej: "EURUSD,WS30")
- `SlaveSymbolNames` (string): Lista de símbolos del Slave correspondientes (ej: "EURUSD.pro,US30")

### Límites de Equity (solo MASTER)
- `DailyProfitLimitPercent` (double): Límite diario de ganancia (%); 0 = deshabilitado
- `DailyLossLimitPercent` (double): Límite diario de pérdida (%); 0 = deshabilitado
- `TotalProfitLimitPercent` (double): Límite total de ganancia (%); 0 = deshabilitado
- `TotalLossLimitPercent` (double): Límite total de pérdida (%); 0 = deshabilitado

### Límites de Trading (solo MASTER)
- `MaxParallelTrades` (int): Límite de operaciones paralelas; 0 = deshabilitado
- `MaxTradesPerDay` (int): Límite de trades por día; 0 = deshabilitado

### Reseteo Diario (solo MASTER)
- `DailyResetHour` (int): Hora de reseteo diario (0-23)
- `DailyResetMinute` (int): Minuto de reseteo diario (0-59)

### Horarios de Trading (solo MASTER)
- `LimitTradingHours` (bool): Si `true`, limita aperturas a horarios especificados
- `TradingStartHour` (int): Hora de inicio (0-23)
- `TradingStartMinute` (int): Minuto de inicio (0-59)
- `TradingEndHour` (int): Hora de fin (0-23)
- `TradingEndMinute` (int): Minuto de fin (0-59)

### Cierre Forzado (solo MASTER)
- `ForceExitHour` (bool): Si `true`, fuerza cierre a hora especificada
- `TradingExitHour` (int): Hora de cierre forzado (0-23)
- `TradingExitMinute` (int): Minuto de cierre forzado (0-59)

---

## Variables Globales y de Estado

### Constantes
- `HCPROPS_KEY`: "HCPropsController" (prefijo para archivos/variables)
- `GV_DISABLE`: "HCPropsControllerDisableTrading" (variable global para deshabilitar trading)
- `PANEL_PREFIX`: "HCPanel_" (prefijo para objetos del panel)

### Variables de Estado (Runtime)
- `InitialBalanceTotal`: Balance inicial total (primer depósito detectado)
- `InitialEquityDaily`: Equity al inicio del día (se resetea diariamente)
- `LastDailyReset`: Timestamp del último reseteo diario
- `DailyUpperLimitEquity` / `DailyLowerLimitEquity`: Límites diarios calculados
- `TotalUpperLimitEquity` / `TotalLowerLimitEquity`: Límites totales calculados
- `TradesOpenedToday`: Contador de trades abiertos hoy
- `LastTradesCountReset`: Timestamp del último reset del contador de trades
- `ProcessedDeals[]`: Array de deals procesados (evita duplicados)

### Optimización Master/Slave
- `LastMasterPositions[]`: Último estado de posiciones guardado (Master)
- `LastMasterFileTime`: Timestamp del último archivo escrito (Master)
- `MasterStateInitialized`: Flag de inicialización del estado Master
- `LastSlaveFileTime`: Timestamp de última lectura del archivo (Slave)
- `MasterFileExists`: Flag de existencia del archivo Master (Slave)
- `LastPanelUpdate`: Timestamp de última actualización del panel (no se usa actualmente)

---

## Funcionalidades Principales

### 1. Cálculo de Balance Inicial

**Función**: `GetRealInitialBalance()`

Busca en el historial de deals el primer depósito (DEAL_TYPE_BALANCE o DEAL_TYPE_CREDIT con DEAL_ENTRY_IN). Si no encuentra depósito, usa el balance actual. Este valor es crítico para:
- Calcular límites totales (porcentaje sobre balance inicial)
- Calcular exposición proporcional para sincronización Master/Slave
- Determinar si la cuenta empezó hoy

**Función**: `AccountStartedToday()`

Verifica si el primer depósito ocurrió el mismo día que la ejecución actual. Usado para determinar si usar el balance inicial o el equity actual como `InitialEquityDaily` en el reseteo diario.

### 2. Reseteo Diario

**Función**: `PerformDailyReset()`

Ejecutado cuando se detecta el cambio de día según `DailyResetHour:DailyResetMinute`:
- Resetea contador de trades (`TradesOpenedToday = 0`)
- Limpia array de deals procesados
- Establece `InitialEquityDaily`:
  - Si cuenta empezó hoy: usa `InitialBalanceTotal`
  - Si no: usa equity actual
- Recalcula límites diarios
- Verifica límites para reactivar trading si corresponde

**Función**: `IsDailyResetTime()`

Calcula el inicio del día según `DailyResetHour:DailyResetMinute` y retorna `true` si `LastDailyReset < dayStart`. Permite horarios de reseteo personalizados (no necesariamente medianoche).

### 3. Control de Límites

**Función**: `CheckLimits()`

Función crítica que verifica todos los límites configurados y aplica acciones:

#### Límites de Equity (cierran posiciones):
- **Ganancia Diaria**: Si `equity >= DailyUpperLimitEquity`
- **Pérdida Diaria**: Si `equity <= DailyLowerLimitEquity`
- **Ganancia Total**: Si `equity >= TotalUpperLimitEquity`
- **Pérdida Total**: Si `equity <= TotalLowerLimitEquity`

**Acción**: Cierra todas las posiciones + elimina órdenes pendientes + deshabilita trading

#### Límites de Trading (solo eliminan órdenes pendientes):
- **Posiciones Paralelas**: Si `PositionsTotal() >= MaxParallelTrades`
- **Trades por Día**: Si `TradesOpenedToday >= MaxTradesPerDay`
- **Horarios**: Si está fuera de horario de trading

**Acción**: Solo elimina órdenes pendientes (no cierra posiciones activas)

#### Reactivación:
Si el trading está deshabilitado pero todos los límites están OK, reactiva el trading.

**Función**: `CalculateDailyLimits()` / `CalculateTotalLimits()`

Calculan los límites de equity usando fórmulas:

- **Límites Diarios (combinados)**:
  - Límite Superior: `Min(InitialEquityDaily * (1 + DailyProfitLimitPercent%), InitialEquityDaily + InitialBalanceTotal * DailyProfitLimitPercent%)`
  - Límite Inferior: `Max(InitialEquityDaily * (1 - DailyLossLimitPercent%), InitialEquityDaily - InitialBalanceTotal * DailyLossLimitPercent%)`

- **Límites Totales**:
  - Límite Superior: `InitialBalanceTotal * (1 + TotalProfitLimitPercent%)`
  - Límite Inferior: `InitialBalanceTotal * (1 - TotalLossLimitPercent%)`

### 4. Horarios de Trading

**Función**: `IsWithinTradingHours()`

Verifica si la hora actual está dentro del rango configurado. Soporta horarios que cruzan medianoche (ej: 22:00 - 06:00).

**Función**: `IsTradingEndTime()` / `IsForceExitTime()`

Verifican si es la hora exacta configurada (comparación de hora y minuto):
- `IsTradingEndTime()`: Elimina órdenes pendientes
- `IsForceExitTime()`: Cierra todas las posiciones + elimina órdenes

### 5. Conteo de Trades por Día

**Función**: `CountTradesOpenedToday()`

Cuenta trades abiertos desde el inicio del día (según `DailyResetHour:DailyResetMinute`):
- Selecciona historial desde `dayStart` hasta ahora
- Filtra deals: `DEAL_TYPE_BUY` o `DEAL_TYPE_SELL` con `DEAL_ENTRY_IN`
- Evita duplicados usando clave única: `symbol + "_" + positionId`
- Retorna número de trades únicos

**Evento**: `OnTradeTransaction()`

Detecta inmediatamente cuando se abre una nueva posición:
- Escucha `TRADE_TRANSACTION_POSITION` y `TRADE_TRANSACTION_DEAL_ADD`
- Filtra deals que abren posiciones (no órdenes pendientes)
- Evita duplicados con array `ProcessedDeals[]`
- Incrementa `TradesOpenedToday`
- Escribe inmediatamente al archivo de sincronización

### 6. Gestión de Posiciones

**Función**: `CloseAllPositions()`

Cierra todas las posiciones abiertas (itera desde el final para evitar problemas de índices).

**Función**: `DeleteAllPendingOrders()`

Elimina todas las órdenes pendientes (limit/stop orders).

**Función**: `CanOpenNewPosition()`

Verifica si se puede abrir una nueva posición:
- Trading no deshabilitado
- Límite de posiciones paralelas no alcanzado
- Límite de trades por día no alcanzado

**Nota**: Esta función no se usa en el código actual (parece ser un helper para uso externo).

---

## Sistema de Límites y Risk Management

### Límites Diarios

Los límites diarios se calculan de forma combinada:

1. **Relativo al equity del día**: `InitialEquityDaily * (1 ± porcentaje%)`
2. **Absoluto basado en balance inicial**: `InitialEquityDaily ± (InitialBalanceTotal * porcentaje%)`

Se toma el más restrictivo de ambos usando `MathMin()` (superior) o `MathMax()` (inferior).

**Ejemplo**:
- Balance Inicial: 10,000
- Equity Diario Inicial: 10,500
- Límite Ganancia Diaria: 4.6%

Límite Superior = Min(10,500 * 1.046, 10,500 + 10,000 * 0.046) = Min(10,983, 10,960) = **10,960**

Esto previene que límites diarios excedan límites totales.

### Límites Totales

Simples porcentajes sobre el balance inicial total:
- Límite Superior: `InitialBalanceTotal * (1 + TotalProfitLimitPercent%)`
- Límite Inferior: `InitialBalanceTotal * (1 - TotalLossLimitPercent%)`

### Prioridad de Límites

Cuando se alcanza un límite:
1. Se identifica el motivo (string `reason`)
2. Se determina si debe cerrar posiciones (`needClosePositions`)
3. Se ejecutan acciones en orden:
   - Eliminar órdenes pendientes
   - Cerrar posiciones (si corresponde)
   - Deshabilitar trading (`GV_DISABLE = 1.0`)
   - Actualizar panel

### Control de Trading

- **Deshabilitar**: `GlobalVariableSet(GV_DISABLE, 1.0)`
- **Habilitar**: `GlobalVariableSet(GV_DISABLE, 0.0)`
- **Verificar**: `GlobalVariableGet(GV_DISABLE) == 1.0`

Esta variable global permite que otros EAs/scripts respeten el estado de trading.

---

## Sincronización Master/Slave

### Master: Escritura de Archivo

**Función**: `MasterSync()`

**Optimización**: Solo escribe cuando hay cambios detectados.

**Proceso**:
1. Obtiene estado actual de posiciones (`GetCurrentPositions()`)
2. Detecta nuevas posiciones (backup si `OnTradeTransaction` falla)
3. Compara con último estado guardado (`PositionsChanged()`)
4. Si hay cambios o es primera vez:
   - Crea carpeta si no existe
   - Abre archivo CSV en modo escritura compartida
   - Escribe cada posición: `symbol;direction;exposure;openPrice;ticket;timeOpen`
   - Calcula `exposure = volume / InitialBalanceTotal` (proporcional)
   - Guarda estado actual como último estado

**Estructura de datos**:
```cpp
struct PositionState {
    string symbol;
    int direction;
    double volume;
    ulong ticket;
}
```

**Formato del archivo CSV**:
```
EURUSD;BUY;0.01;1.08500;123456789;1704067200
GBPUSD;SELL;0.005;1.26500;123456790;1704067300
```

Donde:
- `exposure`: Volumen relativo al balance inicial (ej: 0.01 = 1% del balance)
- `openPrice`: Precio de apertura
- `ticket`: Ticket de la posición
- `timeOpen`: Timestamp de apertura

**Función**: `WritePositionToFile()`

Llamada inmediatamente cuando se abre una nueva posición (desde `OnTradeTransaction`). Fuerza una sincronización completa después de un pequeño delay (100ms).

### Slave: Lectura y Replicación

**Función**: `SlaveSync()`

**Optimización**: Solo lee si el archivo fue modificado desde última lectura.

**Proceso**:

1. **Verificar existencia del archivo**:
   - Si no existe: marca `MasterFileExists = false` y retorna
   - Si existe: marca `MasterFileExists = true`

2. **Verificar timestamp de modificación**:
   - Si no cambió desde última lectura: retorna (optimización)
   - Si cambió: procede a leer

3. **Leer posiciones del Master**:
   - Abre archivo CSV en modo lectura compartida
   - Lee cada línea y construye array `masterList[]`
   - Convierte `exposure` a volumen real: `volume = exposure * InitialBalanceTotal`
   - Aplica reversión de dirección si `RevertMasterPositions == true`
   - Mapea símbolos si están configurados
   - Ajusta volumen según límites del símbolo (min, max, step)

4. **Obtener posiciones actuales del Slave**:
   - Construye arrays: `slaveSymbols[]`, `slaveDir[]`, `slaveVol[]`

5. **Cerrar posiciones que el Master NO tiene**:
   - Si una posición del Slave no está en `masterList[]`: la cierra

6. **Crear/ajustar posiciones según Master**:
   - Si no existe: abre nueva posición
   - Si dirección difiere: cierra y reabre
   - Si volumen difiere: ajusta (añade diferencia o cierra parcialmente)

**Mapeo de Símbolos**: `MapSymbol()`

Si `MasterSymbolNames` y `SlaveSymbolNames` están configurados, mapea símbolos del Master al Slave:
- Ejemplo: Master usa "EURUSD", Slave usa "EURUSD.pro"
- Divide ambas listas por comas y busca correspondencia por índice

**Reversión**: `ReverseDirection()`

Si `RevertMasterPositions == true`, invierte todas las direcciones:
- BUY → SELL
- SELL → BUY

**Proporcionalidad**:

El Slave replica proporcionalmente al balance inicial:
- Master tiene balance inicial de 10,000 y posición de 0.1 lotes
- Exposure = 0.1 / 10,000 = 0.00001
- Slave tiene balance inicial de 5,000
- Volumen Slave = 0.00001 * 5,000 = 0.05 lotes

### Optimizaciones

1. **Master**: Solo escribe cuando hay cambios detectados
2. **Slave**: Solo lee si el archivo fue modificado
3. **Comparación de estados**: Usa tickets de posición como identificadores únicos
4. **Timestamp de archivo**: Evita lecturas innecesarias

### Nombre de Archivo

**Función**: `GetMasterFileName()`

Genera nombre único basado en servidor y cuenta:
- Concatena: `servidor + "_" + cuenta`
- Codifica en Base64
- Retorna: `HCPropsController\master_{base64}.csv`

Esto permite múltiples Masters en el mismo sistema compartido sin conflictos.

---

## Panel de Información (UI)

**Función**: `UpdatePanel()`

Crea un panel de información en el gráfico mostrando estado completo del EA.

### Información Mostrada (Modo MASTER):

1. **Título**: "HC Props Controller"
2. **Modo**: "MASTER" o "SLAVE"
3. **Servidor**: Nombre del servidor de la cuenta
4. **Cuenta**: Número de cuenta
5. **Balance Inicial (total)**: `InitialBalanceTotal`
6. **Equity Inicial (diario)**: `InitialEquityDaily`
7. **Límites Diarios**: Rango con porcentajes (si están habilitados)
8. **Límites Totales**: Rango con porcentajes (si están habilitados)
9. **Operaciones Paralelas**: `actual / máximo` (si está habilitado)
10. **Trades Hoy**: `actual / máximo` (si está habilitado)
11. **Horarios de Trading**: Rango y estado ACTIVO/INACTIVO (si está habilitado)
12. **Hora de Cierre Forzado**: Hora configurada (si está habilitado)
13. **Estado de Trading**: PERMITIDO (verde) / DESHABILITADO (rojo)

### Información Mostrada (Modo SLAVE):

1. **Título**: "HC Props Controller"
2. **Modo**: "SLAVE"
3. **Servidor Master**: `MasterServer`
4. **Cuenta Master**: `MasterAccountNumber`
5. **Invertir Posiciones Master**: "SÍ" o "NO"
6. **Balance Inicial (total)**: `InitialBalanceTotal` (del Slave, para cálculo proporcional)
7. **Estado Master**: CONECTADO (verde) / ESPERANDO CONEXIÓN (rojo)

### Colores

- **Verde (clrLime)**: Estado positivo (trading permitido, Master conectado, horarios activos)
- **Rojo (clrRed)**: Estado negativo (trading deshabilitado, Master desconectado, límites alcanzados)
- **Naranja (clrOrange)**: Advertencia (horarios inactivos, límites totales)
- **Amarillo (clrYellow)**: Información (cierre forzado)
- **Blanco/Gris (clrWhite/clrGray)**: Información normal / deshabilitado
- **Dorado (clrGold)**: Límites diarios
- **Azul (clrDodgerBlue)**: Título

**Función**: `DrawText()`

Crea objetos de texto en el gráfico (OBJ_LABEL):
- Elimina objeto existente si existe
- Crea nuevo objeto con propiedades configuradas
- Posición: esquina superior izquierda con offset (10, y)
- Fuente: 12px
- No seleccionable, no oculto, no en background

**Actualización**: Se llama cada segundo desde `OnTimer()`.

---

## Flujo de Ejecución

### Inicialización (`OnInit()`)

1. Valida parámetros de entrada (horas, minutos, modo SLAVE)
2. Configura timer de 1 segundo
3. Calcula balance inicial total (`GetRealInitialBalance()`)
4. Calcula límites totales
5. Calcula inicio del día según `DailyResetHour:DailyResetMinute`
6. Si es necesario, ejecuta lógica de reseteo diario
7. Inicializa contador de trades desde historial (solo MASTER)
8. Calcula límites diarios
9. Verifica límites (`CheckLimits()`) - solo MASTER
10. Escribe archivo inicial (`MasterSync()`) - solo MASTER
11. Actualiza panel
12. Retorna `INIT_SUCCEEDED`

### Loop Principal (`OnTimer()` - cada 1 segundo)

#### Modo MASTER:

1. **Reseteo Diario**:
   - Si es hora de reset: ejecuta `PerformDailyReset()`

2. **Reset Contador de Trades**:
   - Si es hora de reset: resetea `TradesOpenedToday = 0`

3. **Fin de Horarios de Trading**:
   - Si es hora exacta: elimina órdenes pendientes

4. **Cierre Forzado**:
   - Si es hora exacta: cierra todas las posiciones + elimina órdenes

5. **Verificación de Límites**:
   - Ejecuta `CheckLimits()` (puede deshabilitar trading)

6. **Sincronización**:
   - Ejecuta `MasterSync()` (escribe archivo si hay cambios)

7. **Actualización de Panel**:
   - Ejecuta `UpdatePanel()`

#### Modo SLAVE:

1. **Sincronización**:
   - Ejecuta `SlaveSync()` (lee y replica posiciones)

2. **Actualización de Panel**:
   - Ejecuta `UpdatePanel()`

### Eventos de Trading (`OnTradeTransaction()`)

**Solo activo en modo MASTER**:

1. Detecta transacciones de tipo `TRADE_TRANSACTION_POSITION` o `TRADE_TRANSACTION_DEAL_ADD`
2. Obtiene ticket del deal
3. Verifica que sea un deal que abre posición (BUY/SELL con DEAL_ENTRY_IN)
4. Evita duplicados usando `ProcessedDeals[]`
5. Incrementa `TradesOpenedToday`
6. Verifica límites inmediatamente (`CheckLimits()`)
7. Escribe al archivo inmediatamente (`WritePositionToFile()`)

### Limpieza (`OnDeinit()`)

1. Mata el timer
2. Elimina todos los objetos del panel
3. Si es Master:
   - Elimina archivo de sincronización
   - Elimina variable global `GV_DISABLE`

---

## Observaciones y Posibles Problemas

### 1. Cálculo de Balance Inicial

**Problema Potencial**: `GetRealInitialBalance()` busca el primer depósito en todo el historial. Si hay múltiples depósitos, puede no ser el balance inicial real.

**Impacto**: Afecta cálculo de límites totales y exposición proporcional.

### 2. Conteo de Trades

**Complejidad**: Hay dos mecanismos:
- `OnTradeTransaction()`: Detección inmediata (preferido)
- `MasterSync()`: Backup si falla el evento
- `CountTradesOpenedToday()`: Recuento desde historial al inicio

**Problema Potencial**: Posible duplicación si ambos mecanismos procesan el mismo deal.

**Solución Actual**: Array `ProcessedDeals[]` previene duplicados.

### 3. Optimización de Lectura/Escritura

**Master**: Escribe solo si hay cambios detectados comparando estados.
**Slave**: Lee solo si el archivo fue modificado (timestamp).

**Problema Potencial**: Si el timestamp del archivo no se actualiza correctamente, el Slave podría no detectar cambios.

### 4. Sincronización de Archivos

**Problema Potencial**: Múltiples Masters/Slaves accediendo al mismo archivo simultáneamente podría causar problemas de lectura/escritura.

**Solución Actual**: Uso de `FILE_SHARE_WRITE` (Master) y `FILE_SHARE_READ` (Slave) permite acceso concurrente.

### 5. Mapeo de Símbolos

**Limitación**: Solo funciona si ambos arrays tienen el mismo número de elementos y están en el mismo orden.

**Mejora Posible**: Usar formato clave-valor (ej: "EURUSD=EURUSD.pro,WS30=US30").

### 6. Reseteo Diario

**Complejidad**: El reseteo no necesariamente ocurre a medianoche, sino según `DailyResetHour:DailyResetMinute`.

**Problema Potencial**: Si el EA se reinicia durante el día, podría recalcular mal el inicio del día.

### 7. Cierre Forzado

**Comportamiento**: Solo se ejecuta si la hora exacta coincide (hora y minuto).

**Problema Potencial**: Si el EA no está ejecutándose en ese momento exacto, no se ejecutará.

**Mejora Posible**: Ejecutar si estamos en o después de la hora configurada.

### 8. Límites Diarios Combinados

**Complejidad**: La fórmula combina dos cálculos (relativo al equity del día y absoluto basado en balance inicial).

**Comportamiento**: El límite más restrictivo se aplica.

### 9. Panel de Información

**Problema**: Se actualiza cada segundo, recreando todos los objetos de texto. Esto podría causar flickering.

**Mejora Posible**: Solo actualizar objetos que cambiaron.

### 10. Manejo de Errores

**Observación**: Hay manejo de errores en operaciones de archivo (reintento, logging), pero algunos casos edge podrían no estar cubiertos.

### 11. Variables Estáticas en OnTimer

**Uso**: Se usan variables `static` para evitar ejecuciones múltiples en `IsTradingEndTime()` e `IsForceExitTime()`.

**Problema Potencial**: Si el EA se reinicia, las variables estáticas se resetean.

### 12. Proporcionalidad Slave

**Asunción**: El Slave asume que `InitialBalanceTotal` es correcto. Si el balance inicial del Slave cambia (ej: depósito adicional), la proporcionalidad se rompe.

**Mejora Posible**: Recalcular proporcionalidad basándose en balance actual vs balance inicial del Master.

### 13. Sleep() en Funciones Críticas

**Uso**: `Sleep(100)` en `WritePositionToFile()` y `Sleep(50)` en `MasterSync()`.

**Problema**: `Sleep()` bloquea el thread del EA, lo que puede causar problemas en operaciones críticas.

**Mejora Posible**: Usar timestamps y verificación asíncrona en lugar de Sleep().

### 14. Validación de Símbolos

**Observación**: No hay validación de que los símbolos del Master existan en el Slave antes de intentar operarlos.

**Problema Potencial**: El Slave podría fallar al abrir posiciones si el símbolo no existe.

---

## Resumen de Funciones Críticas

### Gestión de Estado
- `GetRealInitialBalance()`: Balance inicial real
- `AccountStartedToday()`: Verificar si cuenta empezó hoy
- `PerformDailyReset()`: Reset diario completo

### Límites y Risk Management
- `CheckLimits()`: Verificación completa de límites
- `CalculateDailyLimits()`: Cálculo de límites diarios
- `CalculateTotalLimits()`: Cálculo de límites totales

### Sincronización
- `MasterSync()`: Escritura de estado Master
- `SlaveSync()`: Lectura y replicación Slave
- `WritePositionToFile()`: Escritura inmediata de nueva posición
- `PositionsChanged()`: Comparación de estados

### Trading
- `CloseAllPositions()`: Cerrar todas las posiciones
- `DeleteAllPendingOrders()`: Eliminar órdenes pendientes
- `DisableTrading()` / `EnableTrading()`: Control de trading

### Utilidades
- `Base64Encode()`: Codificación Base64
- `GetMasterFileName()`: Generación de nombre de archivo
- `MapSymbol()`: Mapeo de símbolos Master→Slave
- `ReverseDirection()`: Inversión de direcciones

### UI
- `UpdatePanel()`: Actualización completa del panel
- `DrawText()`: Creación de objetos de texto

---

## Conclusión

HCPropsController es un EA complejo y completo que implementa:

1. ✅ Sistema Master/Slave para copy trading
2. ✅ Gestión avanzada de riesgos con múltiples límites
3. ✅ Control de horarios de trading
4. ✅ Reseteo diario configurable
5. ✅ Sincronización optimizada mediante archivos
6. ✅ Panel informativo en tiempo real
7. ✅ Proporcionalidad entre Master y Slave
8. ✅ Inversión de posiciones opcional
9. ✅ Mapeo de símbolos opcional

**Puntos de Mejora Identificados**:
- Optimización del panel (evitar recreación completa)
- Manejo más robusto de errores
- Validación de símbolos en Slave
- Recalculo de proporcionalidad si hay cambios en balance
- Eliminación de Sleep() en funciones críticas
- Mejora en formato de mapeo de símbolos

---

**Versión del Documento**: 1.0  
**Fecha**: 2024  
**EA Versión**: 1.30

---

# Parcheador de Archivos SQX MQL5 - Instrucciones de Uso

## ¿Qué hace este programa?

Este programa modifica automáticamente los archivos `.mq5` exportados por SQX para que respeten la variable global `HCPropsControllerDisableTrading`, permitiendo deshabilitar el trading cuando sea necesario.

## Archivos del Programa

El programa consta de **2 archivos** que deben estar en la misma carpeta:

1. **`Ejecutar-Parcheador.bat`** - Archivo ejecutable principal (doble clic para usar)
2. **`Patch-SQX-GV-Disable.ps1`** - Script PowerShell con toda la lógica

## Formas de Usar el Programa

### **Opción 1: Método Más Fácil (Recomendado) - Doble Clic**

1. **Busque el archivo** `Ejecutar-Parcheador.bat` en la carpeta
2. **Haga doble clic** en `Ejecutar-Parcheador.bat`
3. Se abrirá una ventana con opciones:
   - Seleccione **Opción 1** para procesar todos los archivos `.mq5` en una carpeta
   - Seleccione **Opción 2** para procesar un archivo individual
   - Seleccione **Opción 3** para cancelar
4. Siga las instrucciones en pantalla

### **Opción 2: Arrastrar y Soltar**

1. **Arrastre** un archivo `.mq5` o una carpeta que contenga archivos `.mq5`
2. **Suéltelo** sobre el archivo `Patch-SQX-GV-Disable.ps1`
3. El programa procesará automáticamente los archivos

### **Opción 3: Doble Clic en el Script PowerShell**

1. **Haga doble clic** en `Patch-SQX-GV-Disable.ps1`
2. Se abrirá la misma interfaz gráfica que en la Opción 1
3. Siga las instrucciones en pantalla

### **Opción 4: Desde PowerShell (Usuarios Avanzados)**

Abra PowerShell y ejecute:

```powershell
.\Patch-SQX-GV-Disable.ps1 -Path "C:\Ruta\A\Su\Carpeta"
```

O para un archivo individual:

```powershell
.\Patch-SQX-GV-Disable.ps1 -Path "C:\Ruta\A\Su\Archivo.mq5"
```

## Importante

- **Ambos archivos necesarios**: Asegúrese de que `Ejecutar-Parcheador.bat` y `Patch-SQX-GV-Disable.ps1` estén en la misma carpeta
- **Respaldo Automático**: El programa crea automáticamente un archivo de respaldo (`.backup`) antes de modificar cualquier archivo
- **Solo archivos .mq5**: El programa solo procesa archivos con extensión `.mq5`
- **Búsqueda Recursiva**: Si selecciona una carpeta, el programa buscará archivos `.mq5` en todas las subcarpetas

## ¿Qué Significan los Resultados?

Al finalizar, verá un resumen con:

- **✓ Archivos parcheados**: Número de archivos modificados exitosamente
- **⚠ Archivos omitidos**: Archivos que no necesitaron parcheo (ya estaban parcheados o no contenían la función requerida)
- **✗ Errores**: Número de archivos que no se pudieron procesar (si hay errores, revise los mensajes en pantalla)

## Solución de Problemas

### "PowerShell no está disponible"
- Asegúrese de tener Windows 10 o superior
- PowerShell viene preinstalado en Windows modernos

### "No se encontraron archivos .mq5"
- Verifique que la carpeta seleccionada contenga archivos con extensión `.mq5`
- Asegúrese de que los archivos no estén ocultos

### "El archivo ya contiene la verificación GV_DISABLE"
- Esto significa que el archivo ya fue parcheado anteriormente
- No es necesario parchearlo nuevamente

## Notas Técnicas

- El programa modifica la función `sqHandleTradingOptions()` agregando una verificación al inicio
- Los archivos originales se guardan con extensión `.backup`
- El programa respeta la codificación UTF-8 de los archivos

## ¿Necesita Ayuda?

Si tiene problemas o preguntas, revise los mensajes de error en pantalla. El programa proporciona información detallada sobre cada paso del proceso.

---

**Versión del Documento**: 1.0  
**Fecha**: 2024

