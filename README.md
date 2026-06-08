# HCPropsController

Herramienta completa para gestionar y controlar operaciones de trading en cuentas de Prop Trading con MetaTrader 5.

## 📥 Descargar

Ve a la sección [**Releases**](https://github.com/ivanrdgc/HCPropsController/releases) y descarga la última versión. Descomprime el archivo ZIP en tu carpeta de trabajo.

## 🚀 Inicio Rápido

### ¿Qué incluye este proyecto?

1. **HCPropsController.mq5** - Expert Advisor que reúne en un solo EA: copy trading Master/Slave, guardián de límites de riesgo (prop firm) y **filtro de noticias económicas**.
2. **CheckCalendar.mq5** - Script para verificar que el calendario económico nativo de MT5 funciona en tu broker.
3. **Parcheador de StrategyQuant** - Herramienta para modificar EAs exportados desde SQX.

> **Todo se controla desde un único EA.** El filtro de noticias está integrado en `HCPropsController` (no es un EA aparte). No requiere ningún servidor, login ni licencia: funciona 100% offline.

---

## 📋 Parchear EAs de StrategyQuant

Si exportas Expert Advisors desde StrategyQuant (SQX), necesitas parchearlos para que respeten los límites del HCPropsController.

![Interfaz del Parcheador - Paso 1](images/patch-1.png)

### Pasos Sencillos:

1. **Descarga los archivos del parcheador**:
   - `Ejecutar-Parcheador.bat`
   - `Patch-SQX-GV-Disable.ps1`

2. **Coloca ambos archivos en la misma carpeta**

3. **Haz doble clic en `Ejecutar-Parcheador.bat`**

![Interfaz del Parcheador - Opciones](images/patch-2.png)

4. **Selecciona una opción**:
   - **Opción 1**: Procesar todos los archivos `.mq5` en una carpeta
   - **Opción 2**: Procesar un archivo individual

![Interfaz del Parcheador - Resultado](images/patch-3.png)

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

![Configuración del EA - Parámetros](images/ea-config-params.png)

**=== CONFIGURACIÓN GENERAL ===**
- `Modo de operación` - Selecciona `Master (ejecuta operaciones)` para este modo
- `PropFirmMode` - `true` = activa el guardián de límites; `false` = el Master solo sincroniza posiciones (relay puro, sin intervenir en tu trading)
- `Forzar Balance Inicial` - `0` = detectar automáticamente el primer depósito; `>0` = usar ese valor como balance inicial
- `ResetCountersOnInit` - `true` + reiniciar el EA = resetea contadores, equity inicial y **desbloquea** los límites totales. Úsalo al empezar una cuenta nueva

**=== ARCHIVO DE SINCRONIZACIÓN ===**
- `FileName` - Nombre del archivo compartido (vacío = se genera automáticamente a partir de servidor+cuenta). El Slave debe apuntar al mismo nombre.
- `CustomFilePath` - Ruta personalizada dentro de `Common\Files` (opcional)
- `Symbols` - (MASTER) Símbolos a replicar separados por coma (vacío = todos). Ej: `EURUSD,US30`

**=== LÍMITES DE EQUITY (Solo modo MASTER) ===**
- `Límite diario de ganancia (%); 0 = no limitado` - Límite diario de ganancia. Ejemplo: `4.6` = 4.6%
- `Límite diario de pérdida (%); 0 = no limitado` - Límite diario de pérdida. Ejemplo: `4.6` = 4.6%
- `Límite total de ganancia (%); 0 = no limitado` - Límite total de ganancia. Ejemplo: `8.1` = 8.1%
- `Límite total de pérdida (%); 0 = no limitado` - Límite total de pérdida. Ejemplo: `8.1` = 8.1%
- **Nota**: Pon `0` para deshabilitar cualquier límite

**=== LÍMITES DE TRADING (Solo modo MASTER) ===**
- `Límite de operaciones paralelas; 0 = no limitado` - Máximo de operaciones abiertas al mismo tiempo. Ejemplo: `1` = solo 1 operación
- `Límite de trades por día; 0 = no limitado` - Máximo de trades por día. Ejemplo: `1` = solo 1 trade al día
- `Límite de pérdidas consecutivas por día; 0 = no limitado` - Máximo de pérdidas consecutivas. Ejemplo: `0` = sin límite
- `Límite de ganancias consecutivas por día; 0 = no limitado` - Máximo de ganancias consecutivas. Ejemplo: `0` = sin límite
- **Nota**: Pon `0` para deshabilitar cualquier límite

**=== RESETEO DIARIO (Solo modo MASTER) ===**
- `Hora de reseteo diario` - Hora del reseteo (0-23). Ejemplo: `0` = medianoche
- `Minuto de reseteo diario` - Minuto del reseteo (0-59). Ejemplo: `0` = en punto

**=== HORARIOS DE TRADING (Solo modo MASTER) ===**
- `Limitar aperturas a las horas especificadas` - Activar límite de horarios. `true` = activado, `false` = desactivado
- `Hora de inicio del trading` - Hora de inicio (0-23). Ejemplo: `6` = 6:00 AM
- `Minuto de inicio del trading` - Minuto de inicio (0-59). Ejemplo: `0` = en punto
- `Hora de fin del trading` - Hora de fin (0-23). Ejemplo: `20` = 8:00 PM
- `Minuto de fin del trading` - Minuto de fin (0-59). Ejemplo: `0` = en punto

**=== CIERRE FORZADO (Solo modo MASTER) ===**
- `Forzar cierre a la hora especificada` - Activar cierre forzado. `true` = activado, `false` = desactivado
- `Hora de cierre forzado` - Hora de cierre (0-23). Ejemplo: `22` = 10:00 PM
- `Minuto de cierre forzado` - Minuto de cierre (0-59). Ejemplo: `0` = en punto

**Ejemplo de Configuración Típica:**
```
Modo de operación = Master (ejecuta operaciones)
Límite diario de ganancia (%) = 4.6
Límite diario de pérdida (%) = 4.6
Límite total de ganancia (%) = 8.1
Límite total de pérdida (%) = 8.1
Límite de operaciones paralelas = 1
Límite de trades por día = 1
Hora de reseteo diario = 0
Minuto de reseteo diario = 0
Limitar aperturas a las horas especificadas = true
Hora de inicio del trading = 6
Minuto de inicio del trading = 0
Hora de fin del trading = 20
Minuto de fin del trading = 0
Forzar cierre a la hora especificada = true
Hora de cierre forzado = 22
Minuto de cierre forzado = 0
```

#### 🔵 Modo SLAVE (Cuenta Replicadora)

El EA replica las operaciones de la cuenta MASTER de forma proporcional.

**Parámetros Principales:**

**=== CONFIGURACIÓN GENERAL ===**
- `Modo de operación` - Selecciona `Slave (replica operaciones)` para este modo

**=== CONFIGURACIÓN SLAVE (Solo modo SLAVE) ===**
- `MasterServer` - Nombre exacto del servidor del Master (solo si `FileName` está vacío). **Debe coincidir EXACTAMENTE**, incluyendo espacios y mayúsculas. (Si usas `FileName`, este campo no hace falta.)
- `MasterAccountNumber` - Número de cuenta del Master (solo si `FileName` está vacío). Ejemplo: `12345678`
- `SymbolMapping` - Mapeo de símbolos en formato `MASTER:SLAVE;MASTER2:SLAVE2`. Ejemplo: `EURUSD:EURUSD.pro;US30:US30Cash`. Vacío = mismo nombre
- `CopyMode` - `NORMAL` replica también las modificaciones de SL/TP; `INCOGNITO` fija el SL/TP solo al abrir e ignora cambios posteriores
- `InverseMode` - `true` = opera al revés (BUY→SELL) e intercambia SL/TP; `false` = copia igual
- `RiskMultiplier` - Multiplicador de lotaje. Lote Slave = Lote Master × multiplicador. `1.0` = mismo lotaje, `0.5` = mitad, `2.0` = doble
- `Slippage` - Slippage permitido en puntos. Ejemplo: `10`
- `MagicNumber` - Magic de las órdenes del Slave. Debe ser único por cada Slave dentro de un MISMO terminal MT5. El EA solo gestiona posiciones con este magic
- `SlaveTotalProfitLimitPercent` - Límite total de ganancia del Slave (%); `0` = sin límite. Al alcanzarlo, cierra todo y detiene la replicación

**Ejemplo de Configuración:**
```
Modo de operación = Slave (replica operaciones)
MasterServer = "Mi Broker Demo"
MasterAccountNumber = 12345678
SymbolMapping = "EURUSD:EURUSD.pro;US30:US30Cash"
CopyMode = NORMAL
InverseMode = false
RiskMultiplier = 1.0
Slippage = 10
MagicNumber = 987654
```

**Nota sobre el lotaje:**
- El Slave replica el lotaje del Master multiplicado por `RiskMultiplier`.
- Cada posición del Master se replica de forma independiente (mapeo por ticket, vía el comentario `HC<ticket>` de la orden).
- Diseñado para cuentas en modo **hedging** (y para el caso habitual de 1 posición por símbolo por cuenta).

---

## 📊 Panel de Información

El EA muestra un panel en el gráfico con toda la información importante:

**Modo MASTER:**
![Panel del HCPropsController - Modo Master](images/panel-example.png)

**Modo SLAVE:**
![Panel del HCPropsController - Modo Slave](images/panel-example-slave.png)

**Información mostrada:**
- Estado de trading (HABILITADO/DESHABILITADO)
- Límites configurados y estado actual
- Trades abiertos hoy / máximo permitido
- Horarios de trading
- Próximos eventos (reseteo diario, cierre forzado)
- En modo SLAVE: estado de conexión con el Master

---

## 📰 Filtro de Noticias (integrado, sin servidor)

El EA puede pausar o cerrar el trading alrededor de noticias económicas usando el **calendario económico nativo de MetaTrader 5**. No necesita email, ni API, ni WebRequest: lee el calendario que MetaQuotes ya entrega al terminal.

> El filtro de noticias funciona en **modo MASTER**. Cuando el Master pausa o cierra por una noticia, los Slaves lo replican automáticamente al sincronizar.

### Parámetros (grupo `=== PROTECCIÓN DE NOTICIAS ===`)

- `NewsMode` - Qué hacer durante una noticia:
  - `NEWS_OPERATE` - No hacer nada (filtro desactivado).
  - `NEWS_PAUSE_OPEN` *(recomendado)* - Bloquea **nuevas** aperturas y cancela órdenes pendientes; **mantiene** las posiciones abiertas.
  - `NEWS_CLOSE_ALL` - Cierra TODAS las posiciones + cancela pendientes + bloquea nuevas entradas.
- `NewsDuration` - Segundos de protección **antes y después** de cada noticia. Ej: `120` → protección desde 2 min antes hasta 2 min después (ventana de 4 min).
- `NewsCurrencies` - Currencies a vigilar, en mayúsculas y sin espacios: `EUR,USD,GBP`. Si lo dejas **vacío**, usa automáticamente las divisas del símbolo del gráfico.
- `NewsMinImpact` - Impacto mínimo: `NEWS_IMP_LOW` / `NEWS_IMP_MODERATE` / `NEWS_IMP_HIGH` (por defecto **HIGH**, solo noticias de alto impacto).
- `NewsSource` - `NEWS_SOURCE_MT5` (calendario nativo, recomendado) o `NEWS_SOURCE_URL` (feed propio, ver abajo).
- `NewsCalendarUrl` - Solo si `NewsSource = NEWS_SOURCE_URL`: URL de un CSV con líneas `epoch,CURRENCY,impacto` (1=Low,2=Moderate,3=High).

### Cómo funciona

1. El EA consulta el calendario al iniciar y lo refresca **una vez por hora**.
2. Filtra las noticias por las currencies elegidas y el impacto mínimo.
3. Cuando entra en la ventana `[noticia − NewsDuration, noticia + NewsDuration]` aplica el `NewsMode`.
4. Al salir de la ventana, reactiva el trading automáticamente.

El panel del gráfico muestra `NOTICIA ACTIVA: ...` en rojo durante la protección, y `Noticias: vigilando (N)` el resto del tiempo.

### ✅ Cómo verificar que el calendario funciona en tu broker

El calendario lo entrega **MetaQuotes**, no el broker, pero algunos brokers/builds restringen el acceso desde MQL5. Comprueba estos 3 puntos:

1. **Interfaz:** En MT5, `Ver → Caja de herramientas → Calendario`. Si ves eventos listados, el terminal tiene datos de calendario.
2. **Script:** Compila y ejecuta `CheckCalendar.mq5` (arrástralo a un gráfico). En la pestaña *Expertos* imprimirá cuántos eventos de alto impacto hay en los próximos días. Si imprime `>>> OK ...`, el EA podrá leer las noticias en este broker.
3. **Log del EA:** Al iniciar (con `NewsMode` distinto de `OPERATE`), el EA imprime `NEWS: N noticias programadas`. Si siempre es `0` en días con noticias evidentes (NFP, IPC, FOMC), el broker no está sirviendo el calendario.

**Requisitos:** el terminal debe estar **conectado** a un servidor de trading (el calendario se sincroniza desde ahí). En el *Probador de Estrategias* el calendario puede estar limitado en builds antiguos.

**Si tu broker no sirve el calendario:** usa `NewsSource = NEWS_SOURCE_URL` y aloja (o apunta a) un CSV con el formato `epoch,CURRENCY,impacto`. En ese caso, añade la URL en `Herramientas → Opciones → Expert Advisors → Permitir WebRequest`.

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
R: Replica el lotaje del Master multiplicado por `RiskMultiplier` (1.0 = mismo lotaje). Ajusta el multiplicador si las cuentas tienen tamaños distintos.

**P: ¿Funciona el filtro de noticias sin internet/servidor?**  
R: Usa el calendario nativo de MT5 (sin backend ni login). Verifica que tu broker lo sirve con el script `CheckCalendar.mq5` (ver sección Filtro de Noticias).

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

**Versión**: 2.0
**Última actualización**: 2026
