# HCPropsController

Herramienta completa para gestionar y controlar operaciones de trading en cuentas de Prop Trading con MetaTrader 5.

## 📥 Descargar

Ve a la sección [**Releases**](https://github.com/ivanrdgc/HCPropsController/releases) y descarga la última versión. Descomprime el archivo ZIP en tu carpeta de trabajo.

## 🚀 Inicio Rápido

### ¿Qué incluye este proyecto?

1. **HCPropsController.mq5** - Expert Advisor para controlar límites de riesgo y copy trading
2. **Parcheador de StrategyQuant** - Herramienta para modificar EAs exportados desde SQX

---

## 📋 Parchear EAs de StrategyQuant

Si exportas Expert Advisors desde StrategyQuant (SQX), necesitas parchearlos para que respeten los límites del HCPropsController.

### Pasos Sencillos:

1. **Descarga los archivos del parcheador**:
   - `Ejecutar-Parcheador.bat`
   - `Patch-SQX-GV-Disable.ps1`

2. **Coloca ambos archivos en la misma carpeta**

3. **Haz doble clic en `Ejecutar-Parcheador.bat`**

4. **Selecciona una opción**:
   - **Opción 1**: Procesar todos los archivos `.mq5` en una carpeta
   - **Opción 2**: Procesar un archivo individual

5. **Sigue las instrucciones en pantalla**

El programa creará automáticamente un respaldo (`.backup`) de cada archivo antes de modificarlo.

### ¿Qué hace el parcheador?

Modifica tus EAs para que se detengan automáticamente cuando el HCPropsController alcance los límites de riesgo configurados.

---

## 🎮 Usar HCPropsController

### Instalación

1. Copia el archivo `HCPropsController.mq5` a la carpeta `MQL5/Experts/` de tu MetaTrader 5
2. Reinicia MetaTrader 5 o actualiza la lista de Expert Advisors (F5)
3. Arrastra el EA a un gráfico

### Dos Modos de Operación

#### 🔴 Modo MASTER (Cuenta Principal)

El EA controla los límites de riesgo y ejecuta operaciones en esta cuenta.

**Parámetros Principales:**

**Límites de Ganancia/Pérdida:**
- `DailyProfitLimitPercent` - Límite diario de ganancia (%). Ejemplo: `4.6` = 4.6%
- `DailyLossLimitPercent` - Límite diario de pérdida (%). Ejemplo: `4.6` = 4.6%
- `TotalProfitLimitPercent` - Límite total de ganancia (%). Ejemplo: `8.1` = 8.1%
- `TotalLossLimitPercent` - Límite total de pérdida (%). Ejemplo: `8.1` = 8.1%
- **Nota**: Pon `0` para deshabilitar cualquier límite

**Límites de Trading:**
- `MaxParallelTrades` - Máximo de operaciones abiertas al mismo tiempo. Ejemplo: `1` = solo 1 operación
- `MaxTradesPerDay` - Máximo de trades por día. Ejemplo: `1` = solo 1 trade al día
- `MaxConsecWinsPerDay` - Máximo de ganancias consecutivas por día. Ejemplo: `0` = sin límite
- `MaxConsecLosesPerDay` - Máximo de pérdidas consecutivas por día. Ejemplo: `0` = sin límite
- **Nota**: Pon `0` para deshabilitar cualquier límite

**Reseteo Diario:**
- `DailyResetHour` - Hora del reseteo diario (0-23). Ejemplo: `0` = medianoche
- `DailyResetMinute` - Minuto del reseteo diario (0-59). Ejemplo: `0` = en punto

**Horarios de Trading:**
- `LimitTradingHours` - Activar límite de horarios. `true` = activado, `false` = desactivado
- `TradingStartHour` - Hora de inicio (0-23). Ejemplo: `6` = 6:00 AM
- `TradingStartMinute` - Minuto de inicio (0-59). Ejemplo: `0` = en punto
- `TradingEndHour` - Hora de fin (0-23). Ejemplo: `20` = 8:00 PM
- `TradingEndMinute` - Minuto de fin (0-59). Ejemplo: `0` = en punto

**Cierre Forzado:**
- `ForceExitHour` - Activar cierre forzado. `true` = activado, `false` = desactivado
- `TradingExitHour` - Hora de cierre forzado (0-23). Ejemplo: `22` = 10:00 PM
- `TradingExitMinute` - Minuto de cierre forzado (0-59). Ejemplo: `0` = en punto

**Ejemplo de Configuración Típica:**
```
DailyProfitLimitPercent = 4.6
DailyLossLimitPercent = 4.6
TotalProfitLimitPercent = 8.1
TotalLossLimitPercent = 8.1
MaxParallelTrades = 1
MaxTradesPerDay = 1
DailyResetHour = 0
DailyResetMinute = 0
LimitTradingHours = true
TradingStartHour = 6
TradingStartMinute = 0
TradingEndHour = 20
TradingEndMinute = 0
ForceExitHour = true
TradingExitHour = 22
TradingExitMinute = 0
```

#### 🔵 Modo SLAVE (Cuenta Replicadora)

El EA replica las operaciones de la cuenta MASTER de forma proporcional.

**Parámetros Principales:**

**Conexión al Master:**
- `MasterServer` - Nombre exacto del servidor de la cuenta Master. **IMPORTANTE**: Debe coincidir exactamente, incluyendo espacios
- `MasterAccountNumber` - Número de cuenta del Master

**Opciones de Replicación:**
- `RevertMasterPositions` - Invertir posiciones del Master. `true` = invertir (BUY→SELL), `false` = copiar igual
- `MasterSymbolNames` - Símbolos del Master separados por coma. Ejemplo: `EURUSD,WS30`
- `SlaveSymbolNames` - Símbolos del Slave correspondientes. Ejemplo: `EURUSD.pro,US30`
- `SlaveSymbolMultipliers` - Multiplicadores de volumen separados por coma. Ejemplo: `0.1,1,10`

**Ejemplo de Configuración:**
```
MasterServer = "Mi Broker Demo"
MasterAccountNumber = 12345678
RevertMasterPositions = false
MasterSymbolNames = "EURUSD,WS30"
SlaveSymbolNames = "EURUSD.pro,US30"
SlaveSymbolMultipliers = "1,1"
```

**Nota sobre Proporcionalidad:**
- Si el Master tiene balance de $10,000 y abre 0.1 lotes
- Y el Slave tiene balance de $5,000
- El Slave abrirá 0.05 lotes (proporcional al balance)

---

## 📊 Panel de Información

El EA muestra un panel en el gráfico con toda la información importante:

- Estado de trading (HABILITADO/DESHABILITADO)
- Límites configurados y estado actual
- Trades abiertos hoy / máximo permitido
- Horarios de trading
- Próximos eventos (reseteo diario, cierre forzado)
- En modo SLAVE: estado de conexión con el Master

---

## ⚠️ Importante

### Para Usuarios de StrategyQuant:

1. **Primero** parchea tus EAs exportados desde SQX usando el parcheador
2. **Luego** instala y configura el HCPropsController
3. **Finalmente** ejecuta tus EAs parcheados junto con el HCPropsController

### Verificación del Nombre del Servidor (Modo SLAVE):

El nombre del servidor debe coincidir **EXACTAMENTE** con el del Master, incluyendo:
- Mayúsculas y minúsculas
- Espacios
- Caracteres especiales

Para verificar el nombre exacto del servidor:
1. Abre MetaTrader 5
2. Ve a "Herramientas" → "Opciones" → "Servidor"
3. Copia el nombre exacto que aparece allí

---

## ❓ Preguntas Frecuentes

**P: ¿Puedo usar el EA sin parchear mis EAs de SQX?**  
R: Sí, pero tus EAs no se detendrán automáticamente cuando se alcancen los límites.

**P: ¿Qué pasa si alcanzo un límite?**  
R: El EA cerrará todas las posiciones, eliminará órdenes pendientes y deshabilitará el trading hasta el próximo reseteo diario.

**P: ¿Puedo tener múltiples cuentas SLAVE conectadas a un MASTER?**  
R: Sí, puedes tener tantas cuentas SLAVE como quieras conectadas al mismo MASTER.

**P: ¿El Slave replica exactamente el mismo volumen?**  
R: No, replica proporcionalmente según el balance inicial de cada cuenta.

**P: ¿Qué significa "0 = no limitado"?**  
R: Si pones `0` en cualquier límite, ese límite estará deshabilitado y no se aplicará.

---

## 📚 Documentación Técnica

Para información técnica detallada, consulta [**DOCS.md**](DOCS.md).

---

## 🆘 Soporte

Si tienes problemas:
1. Revisa los mensajes en la pestaña "Expertos" de MetaTrader 5
2. Verifica que todos los parámetros estén configurados correctamente
3. Asegúrate de que los archivos estén en las carpetas correctas

---

## 📝 Notas

- El EA funciona solo con MetaTrader 5
- Requiere Windows para usar el parcheador (PowerShell)
- Los límites se calculan automáticamente basándose en el balance inicial de la cuenta
- El panel se actualiza cada segundo con la información más reciente

---

**Versión**: 1.30  
**Última actualización**: 2024
