# Fuentes y hallazgos

Qué dice la documentación oficial de VERI\*FACTU, qué se ha comprobado contra el
servicio real de la AEAT y qué sigue siendo suposición. Es la justificación de
las decisiones de diseño de la gema y el respaldo de [COMPLIANCE.md](../COMPLIANCE.md).

Cada bloque lleva marcado de dónde sale lo que afirma:

- **[doc]** — de la documentación oficial de la AEAT.
- **[real]** — comprobado contra el entorno de pruebas (preproducción).
- **[?]** — deducido o supuesto, sin comprobar.

## Documentos

Los PDF no se versionan aquí: pesan casi 2 MB y no producen diffs legibles. Se
registran URL, versión y SHA-256 para detectar que han cambiado.

| Documento | Versión | SHA-256 |
|---|---|---|
| [Especificaciones huella/hash](https://www.agenciatributaria.es/static_files/AEAT_Desarrolladores/EEDD/IVA/VERI-FACTU/Veri-Factu_especificaciones_huella_hash_registros.pdf) | 0.1.2 | `f4334c254bb875b417247b54315199f8…` |
| [Validaciones y errores](https://www.agenciatributaria.es/static_files/AEAT_Desarrolladores/EEDD/IVA/VERI-FACTU/Validaciones_Errores_Veri-Factu.pdf) | 1.2.2 | `426eb926fc098a36a163f66ca5f40d9e…` |
| [Especificaciones del código QR](https://www.agenciatributaria.es/static_files/AEAT_Desarrolladores/EEDD/IVA/VERI-FACTU/DetalleEspecificacTecnCodigoQRfactura.pdf) | 0.5.0 | `f86b3c260d8a4963dbc18c5007732b53…` |
| [FAQs de empresas de desarrollo](https://www.agenciatributaria.es/static_files/AEAT_Desarrolladores/EEDD/IVA/VERI-FACTU/FAQs-Desarrolladores.pdf) | 1.3 | `73906dc8afbbb9da35f6cb489980352b…` |

Índice por si cambian de nombre:
[Documentación VERI\*FACTU para desarrolladores](https://www.agenciatributaria.es/AEAT.desarrolladores/Desarrolladores/_menu_/Documentacion/Sistemas_Informaticos_de_Facturacion_y_Sistemas_VERI_FACTU/Sistemas_Informaticos_de_Facturacion_y_Sistemas_VERI_FACTU.html).
Para comprobar si han cambiado: `curl -sL -A "Mozilla/5.0" "<url>" | shasum -a 256`.

Además: `DsRegistroVeriFactu.xlsx` (Diseños de registro v1.0), Descripción SWeb
v1.0.3 y el
[listado de errores](https://prewww2.aeat.es/static_files/common/internet/dep/aplicaciones/es/aeat/tikeV1.0/cont/ws/errores.properties)
(ISO-8859-1, 247 códigos: 44 rechazan el envío completo, 193 la factura y 10
producen aceptación con obligación de subsanar).

## La huella

**[doc]** Los ceros a la derecha son irrelevantes: *"se tratarán indistintamente
los valores con una o dos posiciones en los decimales"*. La exigencia real no es
un formato concreto sino **coherencia entre la huella y el XML**. "Siempre 2
decimales" es válido, y el `241.4` del ejemplo oficial también.

**[doc]** Los espacios al borde hay que recortarlos. La gema los **rechaza**, que
es más estricto: casi siempre son un defecto de los datos de origen y recortar en
silencio lo taparía.

**[doc]** Un campo vacío va como `Campo=` (nombre, igual, nada). Es el caso del
primer registro de la cadena.

**[real]** La huella que construye la gema coincide con la que recalcula la AEAT,
tanto en altas como en anulaciones. La serialización de la anulación es distinta
—no lleva importes ni tipo de factura, solo IDFactura, fecha de generación y
huella anterior— y también cuadra.

**[doc]** Una huella que no coincide **no provoca rechazo**: es *error admisible*
(ap. 4.3.1), el registro se acepta y queda anotado, pero obliga a subsanarlo.

Los tres vectores oficiales del ap. 6 están en `test/diferencial_test.rb` y se
reproducen exactamente, encadenamiento incluido.

## Validaciones implementadas

**[doc]** De Validaciones v1.2.2:

| Ap. | Regla | Dónde |
|---|---|---|
| 3.1.3.1 | `IDEmisorFactura` = NIF del `ObligadoEmision` de la cabecera | `Envio#validar_emisores!` |
| 3.1.3.1 | `FechaExpedicionFactura` no futura ni anterior a 28-10-2024 | `RegistroAlta#validar_fecha_expedicion!` |
| 3.1.3.1 | `NumSerieFactura`: ASCII 32-126, prohibidos `"` `'` `<` `>` `=` | `Formato.num_serie` |
| 3.1.3.3 | `TipoRectificativa` obligatorio y exclusivo de R1-R5 | `RegistroAlta#validar_rectificativa!` |
| 3.1.3.4 | `FacturasRectificadas` **no obligatoria**, exclusiva de R1-R5 | ídem |
| 3.1.3.5 | `FacturasSustituidas` **no obligatoria**, exclusiva de F3 | `#validar_sustitutiva!` |
| 3.1.3.6 | `ImporteRectificacion` obligatorio y exclusivo de `TipoRectificativa=S` | `#validar_importe_rectificacion!` |
| 3.1.3.13 | Destinatarios obligatorios en F1/F3/R1-R4, prohibidos en F2/R5 | `#validar_destinatarios!` |
| 2 | `RechazoPrevio` distinto de "N" solo dentro de una subsanación | `#validar_subsanacion!` |
| 8 y 9 | `FacturaSimplificadaArt7273` solo en F1/F3/R1-R4; `FacturaSinIdentifDestinatarioArt61d` solo en F2/R5 | `#validar_marcas!` |
| 10 | `Macrodato` obligatorio si `ImporteTotal >= |100.000.000,00|` | `#validar_macrodato!` |
| 11 | `EmitidaPorTerceroODestinatario` "T" exige `Tercero`; "D" exige `Destinatarios` | `#validar_emisor_tercero!` |
| 12 | `Tercero` solo con "T", NIF distinto del emisor, sin `IDType` 07, y desde ES solo 03 | ídem y `Tercero` |
| 13 | Reglas de `IDOtro` del destinatario (07 exige ES; desde ES solo 03 o 07) | `IdOtro.normalizar` |
| 14 | `Cupon` solo "S" y solo con R1 o R5 | `#validar_cupon!` |
| 15.1 | Ventanas temporales de `TipoImpositivo` | `Detalle#validar_en_fecha!` |
| 15.3 | El recargo de equivalencia tiene que cuadrar con el tipo impositivo | ídem |
| 15.4 | `CalificacionOperacion` S2 solo en F1/F3/R1-R4 | `#validar_inversion_sujeto_pasivo!` |
| 15.4-15.7 | Coherencia de `Calificacion`, `OperacionExenta`, `ClaveRegimen` y recargo | `Detalle#validar_coherencia!` |

Tres cosas que conviene entender:

- **El 5 % ya no es declarable a secas.** Fue una rebaja temporal cuya ventana
  cerró el 30-09-2024, y como `FechaExpedicionFactura` no puede ser anterior al
  28-10-2024, hoy solo cabe informando una `FechaOperacion` dentro de la ventana.
  Igual para el 2 % y el 7,5 %. Se mide contra `FechaOperacion`, o la de
  expedición si falta.
- **Las reglas cruzadas no caben en el objeto del que hablan.** Un `Detalle` no
  conoce el `TipoFactura` ni la fecha de operación, así que 15.1, 15.3 y 15.4 las
  dispara `RegistroAlta`, igual que `Envio` comprueba que el emisor de cada
  registro sea el obligado de la cabecera.
- **Fuera de las ventanas que la norma menciona no se impone nada.** Inventar
  restricciones donde el texto calla repetiría el error que ya hubo al hacer
  obligatorias 3.1.3.4 y 3.1.3.5, que no lo son.

**Una regla del ap. 13 se decidió NO implementar**: "si un destinatario se
identifica con `IDType=02`, `TipoFactura` debe ser F1/F3/R1-R4" es redundante,
porque los tipos se reparten entre los que exigen destinatario y los que lo
prohíben. Escribirla habría dejado una comprobación incapaz de fallar, que
aparenta cobertura sin cubrir nada.

**Sin implementar**: ap. 15.2 `BaseImponibleACoste`, porque el campo no está
soportado por la gema.

**[doc] Otros errores admisibles** (se aceptan, obligan a subsanar): `ImporteTotal`
o `CuotaTotal` que no cuadran con el desglose, con margen de ±10,00 € (no aplica
si `ClaveRegimen` es 03, 05, 06, 08 o 09); `PrimerRegistro="S"` cuando ya existen
registros para ese SIF y NIF; y `FechaHoraHusoGenRegistro` posterior a la hora de
la AEAT (este exceptuado de subsanación).

## Listas de códigos

**[doc]** De la hoja "6)Listas" del Excel de diseños, que es la fuente autorizada
de los enumerados que las Validaciones citan sin desarrollar:

| Lista | Campo | Valores |
|---|---|---|
| L1 | `Impuesto` | 01 IVA, 02 IPSI, 03 IGIC, 05 Otros |
| L2 | `TipoFactura` | F1, F2, F3, R1–R5 |
| L3 | `TipoRectificativa` | S sustitución, I diferencias |
| L6 | `EmitidaPorTerceroODestinatario` | D, T |
| L7 | `IDType` | 02 NIF-IVA, 03 pasaporte, 04 doc. oficial, 05 cert. residencia, 06 otro, 07 no censado |
| L8A | `ClaveRegimen` con IVA | 01–11, 14, 15, 17, 18, 19, 20 |
| L8B | `ClaveRegimen` con IGIC | 01–11, 14, 15, 17, 18, 19 (+ 20 según Validaciones) |
| L9 | `CalificacionOperacion` | S1, S2, N1, N2 |
| **L10** | `OperacionExenta` | **E1–E6 únicamente** |
| L12 | `TipoHuella` | 01 SHA-256 |
| L15 | `IDVersion` | 1.0 |
| L16 | `GeneradoPor` | E expedidor, D destinatario, T tercero |
| L17 | `RechazoPrevio` | N, S, X |

L10 confirma que **E7 y E8 solo se admiten con IGIC**; `Detalle::EXENCIONES` los
incluye siempre y es por tanto demasiado permisiva.

`ClaveRegimen = 21` no aparece en L8A ni L8B pero sí en el XSD y en el ap. 15.6.11
de Validaciones. El Excel es v1.0 y Validaciones v1.2.2: se sigue a la más
reciente.

## Alcance no cubierto: las operativas de subsanación y rechazo

**[doc]** Los cuadros de operativa del Excel definen **seis operativas de alta y
cuatro de anulación**, cada una distinguida por una combinación de campos:

| Operativa de alta | `Subsanacion` | `RechazoPrevio` |
|---|---|---|
| Alta inicial ("normal") | ausente o N | ausente o N |
| Alta de subsanación | S | ausente o N |
| Alta por rechazo de subsanación | S | S |
| Alta por rechazo / sin registro previo | S | X |

La gema **solo construye la primera fila de cada cuadro**, y eso importa más de lo
que parece: como una huella que no cuadra es error admisible y obliga a subsanar,
quien reciba un `AceptadoConErrores` no tiene forma de corregirlo con esta gema.
El mecanismo de corrección entero depende de estos campos.

`RechazoPrevio = X` es además el camino de migración desde NO VERI\*FACTU:
registros que existen en el SIF pero nunca se remitieron.

## Endpoints, TLS y certificados

**[doc]** Los dominios de preproducción se corresponden uno a uno con producción:

| Preproducción | Producción | Uso |
|---|---|---|
| `prewww1.aeat.es` | `www1.agenciatributaria.gob.es` | Web services, certificado normal |
| `prewww2.aeat.es` | `www2.agenciatributaria.gob.es` | Estáticos (de aquí salen los XSD) y cotejo del QR |
| `prewww10.aeat.es` | `www10.agenciatributaria.gob.es` | Web services con **certificado de sello** |

**Aviso operativo del propio portal:** preproducción es para pruebas *puntuales*.
Nada de pruebas masivas ni de validaciones integradas en procesos de producción;
un uso que consideren abusivo puede acabar en bloqueo de acceso.

**[real] `ca_file` no hace falta.** Tras la renovación de noviembre de 2025, los
cinco endpoints validan con el almacén de confianza del sistema (`Verify return
code: 0`). Sirven cadenas de CA públicas: Entrust OV TLS y Sectigo, ambas bajo
USERTrust RSA. `ca_file` sigue existiendo por si hay que anclar la cadena en algún
entorno, pero ante un fallo de verificación lo probable es un almacén anticuado o
un proxy interceptando el TLS. Nunca `VERIFY_NONE`.

**[real]** El mTLS funciona con certificado de representante de la FNMT, y
`Certificado#sello?` acierta el caso negativo (va a `prewww1`, que es lo
correcto).

**[?] El caso del sello queda sin contrastar, y seguirá así.** La AEAT no emite
certificados de prueba —preproducción exige un certificado real de una CA
reconocida— y el de sello de entidad de la FNMT es de pago y solo para personas
jurídicas. Con él hay que declarar `sello: true` explícitamente en vez de fiarse
de la heurística sobre el sujeto del certificado, que nunca ha visto un sello
real.

## Cadenas, instalaciones y varias fuentes de facturación

**[doc]** La cadena es **una por SIF + NIF obligado**, no una por serie. Pero
"SIF" no es el producto: lo identifica el bloque `SistemaInformatico` completo, y
dentro de él el `NumeroInstalacion` distingue instalaciones. Las FAQs:

> cada una de esas facturaciones distintas (sean de distintos OEF o del mismo OEF
> pero de distintos centros de facturación independientes, como tiendas) debe
> tener un nº de instalación propio y distinto al resto (pasado, presente o
> futuro) **porque se consideran SIF independientes, como si fueran "SIF
> virtuales"**

Con varias fuentes (tiendas, TPV, web, un job) hay dos arquitecturas válidas: un
solo SIF, que obliga a serializar todas las fuentes contra una cadena con un lock
de base de datos; o un SIF virtual por fuente, con cadenas independientes y sin
lock entre ellas. La segunda es la que la AEAT contempla expresamente y la que
evita el problema de raíz.

El `NumeroInstalacion` **no puede repetirse nunca**, ni al reinstalar sobre la
misma máquina. Las FAQs recomiendan un timestamp de instalación o un secuencial
propio del obligado. `IndicadorMultiplesOT` va a "S" cuando un SIF en la nube
atiende a varios obligados a la vez.

**Regla dura de diseño: la gema no autogenera nunca un `NumeroInstalacion`.** Si
lo hiciera, un contenedor que se recrea en cada despliegue produciría una
instalación por despliegue —y en el límite una por factura—, cada registro saldría
`PrimerRegistro="S"`, la AEAT lo aceptaría y la cadena dejaría de demostrar nada.
Lo que lo impide no es técnico: las FAQs prohíben que la identidad del SIF cambie
"con cada factura ni con cada sesión o arranque del producto", la trazabilidad es
obligación legal del productor (art. 29.2.j LGT) y certificar por declaración
responsable un SIF que no cumple el RD 1007/2023 es sancionable.

## La AEAT no impide bifurcar la cadena

**[real]** Se enviaron dos altas distintas apuntando ambas al **mismo**
predecesor. La AEAT aceptó las dos con `Correcto`, sin aviso ni error admisible.

```
Registro 1  (PrimerRegistro)
   ├── Registro 2   -> anterior: Registro 1
   └── Registro 3   -> anterior: Registro 1     <-- cadena bifurcada, aceptada
```

Es el hallazgo con más consecuencias de diseño de toda la integración:

- **No hay red de seguridad.** La AEAT no valida al recibir que el
  `RegistroAnterior` sea de verdad el último anotado. Una condición de carrera
  produce una cadena rota que se acepta en silencio y no se descubre al enviar.
- **El lock no es una optimización, es lo único que sostiene la integridad**, y
  dentro de la gema lo respalda un índice único sobre `(cadena_id,
  huella_anterior)`.
- **Que no lo rechacen no significa que no lo vean.** La AEAT conserva todos los
  registros, y la lista L1E de tipos de anomalía incluye "el campo huella del
  registro anterior no se corresponde con la huella del registro anterior". Lo que
  no hay es detección síncrona.

**La huella anterior no la da la AEAT**: hay que guardarla. Cada registro almacena
la suya y el siguiente lee la última de su cadena bajo lock.

## Qué queda anotado: la consulta devuelve una foto, no un libro

**[real]** Consultada una cadena con **6 registros de facturación sobre 4
facturas**, la consulta devolvió **4 filas**: una por factura, con su estado
actual, no el histórico. De ahí tres conclusiones:

- **La subsanación sustituye al original, no convive con él.** La factura
  subsanada aparece una sola vez, con los importes corregidos y
  `TimestampUltimaModificacion` a la hora de la subsanación. `Correcto` al
  subsanar significa de verdad "he reemplazado el registro anterior".
- **La anulación surte efecto**: la factura queda en `Anulado`, un estado que
  `RespuestaSuministro` ni siquiera puede expresar (solo conoce Correcto,
  AceptadoConErrores e Incorrecto). Sin este servicio no hay forma de observarlo.
- **La cadena NO se puede reconstruir entera desde la consulta.** Es la cara B: los
  eslabones sustituidos desaparecen, así que los registros que encadenaban tras
  ellos *parecen* huérfanos aunque la cadena esté intacta. Por lo mismo, se
  informaron **cero** registros marcados `PrimerRegistro`, porque el primero de la
  cadena había sido sustituido.

**Corolario para la capa Rails: el histórico de la cadena hay que guardarlo uno
mismo.** La consulta sirve para reconciliar el estado de cada factura, no para
auditar el encadenamiento. Detectar una bifurcación sigue dependiendo del SIF.

Detalles confirmados de paso: las huellas devueltas **coinciden** con las
almacenadas; los importes vuelven **sin ceros a la derecha** (`181.5`, `121`,
`133.1`); y el orden de las filas **no es cronológico**, así que no conviene
apoyarse en él.

**[real] `Subsanacion="S"` evita el rechazo por duplicado.** Reenviar una factura
con el mismo `IDFactura` e importes distintos se anota como `Correcto`, sin
`RegistroDuplicado`. El mismo cuerpo sin la marca habría chocado con "Registro de
facturación duplicado".

## Reconciliación

**[real]** Dos altas remitidas y reconciliadas a continuación: 2 facturas
locales, 2 filas de la AEAT, 0 divergencias.

**[real] La AEAT imputa el periodo por FECHA DE EXPEDICIÓN.** Es lo que asume
`Reconciliacion#vigentes` al elegir qué facturas locales revisar.

**[?] El cotejo del `SistemaInformatico` lo aplica el servidor: probable, no
comprobado.** El razonamiento es indirecto: había 4 facturas anotadas bajo el
mismo NIF y el mismo periodo en otra instalación, y la consulta filtrada devolvió
solo las 2 de la instalación consultada. **Falta la premisa**: que esas 4
siguieran almacenadas ese día. Preproducción no tiene trascendencia tributaria y
nada garantiza que no purguen datos, así que "las purgaron" explica lo observado
igual de bien. Se cierra pidiendo el mismo periodo con el SIF de la otra
instalación.

Consecuencia práctica que no depende de eso: **el SIF que se manda en el filtro
tiene que ser el mismo con el que se anotaron los registros**. Con uno distinto la
respuesta viene `SinDatos`, y eso se disfraza de "no consta ninguna factura". Por
eso `Reconciliacion` filtra además en cliente por el `NumeroInstalacion` de cada
fila.

## El código QR: la AEAT NO devuelve la URL

**[doc]** Conviene decirlo explícito porque es la suposición natural y es falsa:
la URL de cotejo no llega en ninguna respuesta. No está en
`RespuestaSuministro.xsd`, ni en `RespuestaConsultaLR.xsd`, ni se menciona en
Validaciones. La construye el propio SIF con datos que ya tiene.

```
Pruebas:     https://prewww2.aeat.es/wlpl/TIKE-CONT/ValidarQR?
Producción:  https://www2.agenciatributaria.gob.es/wlpl/TIKE-CONT/ValidarQR?
```

Cuatro parámetros: `nif`, `numserie`, `fecha` (DD-MM-AAAA) e `importe`.

- **El host no es el del SOAP.** El cotejo va por `prewww2`/`www2`, los envíos por
  `prewww1`/`prewww10`.
- **El URL encoding no es opcional y el caso es alcanzable.** `Formato.num_serie`
  admite `&`, `%`, `+` y espacios, así que un número de serie válido para el envío
  puede partir la URL si se concatena sin codificar. UTF-8.
- Hay una URL distinta para NO VERI\*FACTU (`ValidarQRNoVerifactu`), fuera de
  alcance.

**Consecuencia de diseño.** Como el QR no depende de la respuesta de la AEAT, se
genera al crear el registro y bajo el mismo lock, antes de enviar nada: la
impresión de la factura queda desacoplada del envío asíncrono. Ojo al matiz: que
el QR sea *válido* no significa que la factura *conste*. Si el envío nunca se
completa, quien escanee obtendrá un "no consta".

## Ritmo de remisión: los lotes NO son el modo normal

**[doc]** Las FAQs son tajantes:

> debe asegurarse que la generación del RF se produzca de forma "simultánea"
> (entiéndase inmediata o sin demora apreciable) a la expedición de la factura
> para su instantáneo almacenamiento o remisión a la AEAT

Un comercio que factura cada diez minutos mandará siempre un registro por
petición. El tope de 1000 es un techo para quien factura rápido, no un objetivo:
el tamaño del lote lo dicta el ritmo de facturación, no una decisión de diseño.

**[real] Un envío admite una cadena entera, no solo un eslabón.** Varios registros
encadenados entre sí dentro del mismo `RegFactuSistemaFacturacion` se anotan
todos. Esto separa dos cosas fáciles de confundir: el **cálculo** de la cadena
sigue necesitando el lock por SIF+NIF, pero el **transporte** puede agrupar.

**[real] `TiempoEsperaEnvio` no escala con el tamaño del lote**: 60 s tanto tras
un lote de tres como tras un envío de uno. Es el valor inicial que fija el art.
16.2 de la Orden. Agrupar sale más barato que encadenar peticiones: mismo coste de
espera, más registros dentro. Medido solo en preproducción, y la AEAT lo devuelve
en cada respuesta precisamente porque puede variarlo.

**[doc]** `TiempoEsperaEnvio` significa esperar esos segundos **o** acumular hasta
el límite de lote, lo que ocurra primero.

## Obligaciones del SIF que no se leen en el esquema (OM art. 7.i)

**[doc]** Dos comprobaciones **antes de generar cada registro**, que no se deducen
de ningún XSD:

> 1.º El último registro de facturación generado está correctamente encadenado.
> 2.º La fecha y hora de generación del último registro de facturación generado
> no es superior en más de un minuto a la fecha y hora actuales que se utilizarán
> para fechar el registro de facturación a generar.

En la primera se mira **un eslabón hacia atrás**, no la cadena entera: que la
`Huella` del `RegistroAnterior` del RF n-1 se corresponda con la huella del RF
n-2.

La segunda confunde y las FAQs lo aclaran: que pasen horas entre registros **no es
problema**. Lo que no se admite es que el registro a generar tenga fecha anterior
en más de un minuto al ya generado. Es un control de que el reloj no va hacia
atrás, no de que factures rápido.

**Y lo más importante: detectar una anomalía NO puede parar la caja.**

> será preciso generar el siguiente RF, ya que la facturación por este motivo
> **NUNCA debe interrumpirse**

Conviene no confundir dos clases de fallo:

- **Datos inválidos del registro** (un tipo impositivo inexistente, un desglose
  incoherente): no se puede generar el registro, y ahí sí hay que fallar. Con esos
  datos tampoco se puede emitir la factura.
- **Anomalía de trazabilidad** (el eslabón anterior no cuadra): se anota, se avisa
  y se sigue. Nunca bloquea.

Las FAQs añaden que el orden de generación debe seguir el orden cronológico de
expedición, lo que encaja con serializar bajo lock.

## Recuperación ante desastre

**[doc]** Si se pierde la base de datos local a mitad de año hay dos salidas:

1. **Recuperar el último eslabón desde la AEAT.** La consulta devuelve, de cada
   registro, su `Huella` y su `FechaHoraHusoGenRegistro`. El de marca temporal
   mayor es el último de la cadena, y con su `IDFactura` + `Huella` se reanuda.
   Solo vale en modalidad VERI\*FACTU, que es donde la AEAT los conserva.
2. **No recuperarlo: abrir instalación nueva.** Reinstalar exige un nº de
   instalación nuevo, y una instalación nueva arranca su propia cadena con
   `PrimerRegistro="S"`.

De aquí sale una idea que ordena bastante: **la cadena no es un hilo eterno del
contribuyente, es por instalación**. Romperla no es un pecado irreparable; es
motivo para abrir una instalación nueva. Lo que sí es irreparable es reutilizar un
número de factura, y eso sí lo detecta la AEAT.

## Respuestas y errores del servicio

**[doc]** Estados: `EstadoEnvio` (Correcto / ParcialmenteCorrecto / Incorrecto),
`EstadoRegistro` (Correcto / AceptadoConErrores / Incorrecto) y
`EstadoRegistroDuplicado` (Correcta / AceptadaConErrores / Anulada). La consulta
usa otros: Correcto, AceptadoConErrores y **Anulado**, que el canal de envío no
sabe expresar.

**[doc]** Solo hay que escapar `&` como `&amp;` y `<` como `&lt;`, lo que respalda
la asimetría huella-cruda / XML-escapado. Ceros a la izquierda prohibidos en
numéricos, irrelevantes tras el separador decimal.

**[real] Los fallos de servicio llegan como SOAP Fault**, no como
`RespuestaSuministro`, con el código dentro de `faultstring` en el formato
`Codigo[NNNN].descripción`.

**[real] La identificación del obligado es por el PAR NIF + NombreRazon.** Con el
NIF correcto y un nombre que no cuadre con el censo, la AEAT responde `4104` "el
NIF no está identificado", que apunta al campo equivocado; el detalle del error sí
devuelve los dos campos. Lo mismo para el destinatario, con el código `1239`. Un
NIF con dígito de control incorrecto da `4116`.

**[real]** Un sobre SOAP con dos declaraciones XML devuelve `Codigo[102].Error
interno en el servidor`: es un fallo de parseo, no de negocio, y el mensaje no
orienta en absoluto.

**[real]** Estos códigos existen como error propio de la AEAT, lo que respalda las
validaciones implementadas leyendo el ap. 15:

| Código | Regla |
|---|---|
| 1237 | N1/N2 con IVA no admiten tipo, cuota ni recargo |
| 1238 | Una exenta no admite esos cuatro campos |
| 1245 | `ClaveRegimen` obligatoria con IVA/IPSI/IGIC |
| 1232-1234 | Reglas cruzadas de `IDType` y `CodigoPais` |
| 1235-1236 | Ventanas temporales de `TipoImpositivo` |

**[doc]** WSDL de pruebas:
`https://prewww2.aeat.es/static_files/common/internet/dep/aplicaciones/es/aeat/tikeV1.0/cont/ws/SistemaFacturacion.wsdl`

## Lo que sigue sin comprobarse

- **El certificado de sello** y su endpoint (`prewww10`/`www10`). No hay forma
  barata de probarlo: la AEAT no emite certificados de prueba.
- **El cotejo del SIF en servidor**, por la premisa que falta (ver arriba).
- **Las operativas de subsanación por rechazo y de anulación sin registro
  previo**, que la gema no construye.
- **Los caminos de rechazo**: una factura válida no los recorre, así que las
  validaciones de error solo están ejercitadas contra los tests propios.

## Nota operativa

Los guiones de `examples/` contra preproducción y la suite de tests **no deben
compartir base de datos**. La suite tira las tablas, las recrea y vacía cadenas y
registros en cada test; correrla contra una base con datos de pruebas reales los
destruye. La gema lo impide abortando si el nombre de la base no parece de tests,
pero la separación conviene hacerla explícita con `VF_DATABASE_URL`.
