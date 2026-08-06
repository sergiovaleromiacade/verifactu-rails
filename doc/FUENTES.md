# Fuentes normativas y qué se ha sacado de cada una

Los PDF **no se versionan** aquí: son documentos de la AEAT, pesan casi 2 MB y no
producen diffs legibles. Se registran URL, versión y SHA-256 para poder detectar
que han cambiado, y se anota qué regla concreta salió de dónde.

Descargados y contrastados el **6 de agosto de 2026**.

## Documentos

| Documento | Versión | SHA-256 |
|---|---|---|
| [Especificaciones huella/hash](https://www.agenciatributaria.es/static_files/AEAT_Desarrolladores/EEDD/IVA/VERI-FACTU/Veri-Factu_especificaciones_huella_hash_registros.pdf) | 0.1.2 | `f4334c254bb875b417247b54315199f8…` |
| [Validaciones y errores](https://www.agenciatributaria.es/static_files/AEAT_Desarrolladores/EEDD/IVA/VERI-FACTU/Validaciones_Errores_Veri-Factu.pdf) | 1.2.2 | `426eb926fc098a36a163f66ca5f40d9e…` |

Para comprobar si han cambiado:

```sh
curl -sL -A "Mozilla/5.0" "<url>" | shasum -a 256
```

## De las Especificaciones de la huella (v0.1.2)

- **Ap. 6 — los tres vectores oficiales.** Incorporados a
  `test/diferencial_test.rb`. Encadenan entre sí (alta → alta → anulación), así que
  cubren también el encadenamiento. Se reproducen exactamente.
- **Ap. 3 — ceros a la derecha irrelevantes.** *"en los campos numéricos se
  tratarán indistintamente los valores con una o dos posiciones en los decimales,
  sin tener relevancia los ceros a la derecha"*. La exigencia real no es un formato
  concreto sino coherencia entre la huella y el XML. Nuestro "siempre 2 decimales"
  es válido; el `241.4` del ejemplo oficial también.
- **Ap. 3 — espacios al borde: la spec manda recortarlos.** No es ambigua, como
  se creía. Nosotros rechazamos, que es más estricto. Ver `Formato.texto`.
- **Ap. 3 — campo vacío.** Va como `Campo=` (nombre, igual, nada). Es el caso del
  primer registro de la cadena.

## De las Validaciones (v1.2.2)

Implementadas:

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

Nótese que 3.1.3.4 y 3.1.3.5 **corrigieron** una implementación previa que las
hacía obligatorias: era más estricta que la norma y bloqueaba casos válidos.

Sobre 3.1.3.6: el commit que implementó las rectificativas (`ee25e53`) avisa de
que esa regla estaba *deducida* y no leída en la tabla de validaciones. **Ese aviso
ha quedado obsoleto**: se escribió antes de tener este PDF, y el apartado la
recoge literalmente en sus dos direcciones ("Sólo deberá incluirse esta agrupación
si el campo TipoRectificativa = 'S'" y "Obligatorio si TipoRectificativa = 'S'").
No queda ninguna regla inferida en el código de rectificativas.

Pendientes de implementar (no bloquean, pero convendría):

- **Ap. 3.1.3.10 `Macrodato`**: obligatorio si `ImporteTotal >= |100.000.000,00|`.
- **Ap. 3.1.3.8/9**: `FacturaSimplificadaArt7273` solo en F1/F3/R1-R4;
  `FacturaSinIdentifDestinatarioArt61d` solo en F2/R5.
- **Ap. 3.1.3.11/12**: `EmitidaPorTerceroODestinatario` = "T" exige bloque
  `Tercero`; = "D" exige `Destinatarios`.
- **Ap. 3.1.3.13**: reglas finas de `IDOtro` (si `IDType=07`, `CodigoPais` debe ser
  "ES"; si `CodigoPais=ES`, `IDType` debe ser "03" o "07"; `IDType=02` exige
  TipoFactura F1/F3/R1-R4).
- **Ap. 3.1.3.14 `Cupon`**: solo con TipoFactura R5 o R1.
- **Ap. 3.1.3.15**: tabla larga de coherencia entre `Impuesto`, `ClaveRegimen`,
  `TipoImpositivo`, `CalificacionOperacion` y `OperacionExenta`. Es el bloque más
  grande que queda.
- **Ap. 3.1.3.2**: `RechazoPrevio` solo con `Subsanacion`. Ninguno de los dos
  campos está soportado todavía.

### Lo que NO provoca rechazo

Errores *admisibles* (ap. 4.3.1): el registro se acepta y queda registrado, pero
hay que **subsanarlo**. Entre ellos:

- Huella que no coincide con la calculada por la AEAT.
- `ImporteTotal` o `CuotaTotal` que no cuadran con la suma del desglose, con un
  margen de ±10,00 €. No se aplica si `ClaveRegimen` es 03, 05, 06, 08 o 09.
- `PrimerRegistro="S"` cuando ya existen registros para ese SIF y NIF.
- `FechaHoraHusoGenRegistro` posterior a la hora de la AEAT (exceptuado de
  subsanación).

Esto matiza la idea de que una huella mal calculada "se rechaza": no se rechaza,
pero genera una obligación de subsanar.

## Portal de pruebas externas (preproducción)

Entorno abierto de la AEAT para probar presentación y consulta, sin trascendencia
tributaria. La única condición es autenticarse con certificado electrónico.

Los dominios se corresponden uno a uno con producción:

| Preproducción | Producción | Uso |
|---|---|---|
| `prewww1.aeat.es` | `www1.agenciatributaria.gob.es` | Web services, certificado normal |
| `prewww2.aeat.es` | `www2.agenciatributaria.gob.es` | Estáticos (de aquí salen los XSD) |
| `prewww10.aeat.es` | `www10.agenciatributaria.gob.es` | Web services con **certificado de sello** |

Esto confirma la tabla `ENDPOINTS` de `Transporte`, incluida la separación del
endpoint de sello, que es el detalle menos documentado de todos.

**Aviso operativo, del propio portal:** es para pruebas *puntuales*. Nada de
pruebas masivas ni de validaciones integradas en procesos de producción; un uso
que consideren abusivo puede acabar en bloqueo de acceso. Relevante aquí porque
`Envio` admite lotes de 1000 registros: contra preproducción, moderación.

### La cadena TLS ya no necesita `ca_file`

El 21 de noviembre de 2025 la AEAT renovó los certificados de la sede electrónica
y del dominio `*.aeat.es`. Comprobado el 06-08-2026 contra los cinco endpoints,
todos validan con **`Verify return code: 0 (ok)`** usando el almacén de confianza
del sistema:

```
prewww1/prewww10.aeat.es      *.aeat.es
                              <- Entrust OV TLS Issuing RSA CA 2
                              <- Sectigo Public Server Authentication Root R46
                              <- USERTrust RSA Certification Authority

www1/www2/www10.gob.es        agenciatributaria.gob.es (QWAC)
                              <- Sectigo Qualified Website Authentication CA R35
                              <- USERTrust RSA Certification Authority
```

Todas son CA públicas presentes en cualquier almacén estándar, así que **no hay
que empaquetar raíces propias**. Esto invalida el punto "pendiente de verificar"
número 3 del traspaso original ("la AEAT sirve con cadena propia"): era cierto
antes de la renovación, ya no.

`ca_file` sigue existiendo en `Transporte` por si hace falta anclar la cadena en
un entorno concreto, pero deja de ser el arreglo por defecto ante un fallo de
verificación. Ahí lo probable es un almacén de confianza anticuado o un proxy
corporativo interceptando el TLS.

## Diseños de registro (Excel v1.0)

`DsRegistroVeriFactu.xlsx`, 11 hojas. Las relevantes en alcance:

### Listas de códigos (hoja "6)Listas")

Son la fuente autorizada de los enumerados que las Validaciones citan sin
desarrollar:

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

L10 confirma que **E7 y E8 no son valores generales**: solo se admiten con
IGIC. Nuestra constante `Detalle::EXENCIONES` los incluye siempre y es por tanto
demasiado permisiva.

L1E–L4E son del registro de eventos: fuera de alcance.

Discrepancia de versiones: `ClaveRegimen = 21` no aparece en L8A ni en L8B, pero
sí en el XSD y en el ap. 15.6.11 de las Validaciones (que le dedica un apartado
para IGIC). El Excel es v1.0 y las Validaciones v1.2.2, así que se sigue a las
más recientes.

### Cuadros de operativa (hojas "A" y "B") — afectan al ALCANCE

Esto no es una tabla de formatos: define **las seis operativas de alta y las
cuatro de anulación**, y cada una se distingue por una combinación de campos que
esta gema **todavía no emite**.

Alta, según `Subsanacion` + `RechazoPrevio`:

| Operativa | `Subsanacion` | `RechazoPrevio` |
|---|---|---|
| Alta inicial ("normal") | ausente o N | ausente o N |
| Alta de subsanación | S | ausente o N |
| Alta por rechazo de subsanación | S | S |
| Alta por rechazo / sin registro previo | S | X |

Anulación, según `SinRegistroPrevio` + `RechazoPrevio`: las cuatro combinaciones
de ambos campos.

**Consecuencia:** hoy solo sabemos construir la primera fila de cada cuadro. Y eso
importa más de lo que parece, porque una huella que no cuadra es *error admisible*
y **obliga a subsanar** (Validaciones ap. 4.3.1): sin `Subsanacion`, quien reciba
un "AceptadoConErrores" no tiene forma de corregirlo con esta gema. El mecanismo
de corrección entero depende de estos campos.

`RechazoPrevio = X` es además el camino de migración desde NO VERI\*FACTU:
registros que existen en el SIF del obligado pero nunca se remitieron.

## Servicios web (Descripción SWeb v1.0.3)

- **Ap. 6.8** — ceros a la izquierda prohibidos en numéricos (`01` mal, `1` bien),
  pero tras el separador decimal son irrelevantes: *"12345 es lo mismo que 12345.0
  y que 12345.00"*. Nuestro formato de 2 decimales es válido, y también lo es el
  `241.4` del ejemplo oficial.
- **Ap. 6.9** — solo hay que escapar `&` como `&amp;` y `<` como `&lt;`.
  Respalda la asimetría huella-cruda / XML-escapado.
- **Respuesta**: `EstadoEnvio` (Correcto / ParcialmenteCorrecto / Incorrecto),
  `EstadoRegistro` (Correcto / AceptadoConErrores / Incorrecto) y
  `EstadoRegistroDuplicado` (Correcta / AceptadaConErrores / Anulada).
- **`TiempoEsperaEnvio`**: esperar esos segundos **o** acumular hasta el límite de
  lote, lo que ocurra primero.
- **WSDL** de pruebas: `https://prewww2.aeat.es/static_files/common/internet/dep/aplicaciones/es/aeat/tikeV1.0/cont/ws/SistemaFacturacion.wsdl`

### Códigos de error

Listado completo en `https://prewww2.aeat.es/static_files/common/internet/dep/aplicaciones/es/aeat/tikeV1.0/cont/ws/errores.properties`
(ISO-8859-1). **247 códigos** en tres categorías: 44 rechazan el envío completo,
193 rechazan la factura, y **10** producen aceptación con obligación de subsanar.

## Contrastado contra preproducción (06-08-2026)

**Primer registro aceptado.** `EstadoEnvio=Correcto`, `EstadoRegistro=Correcto`,
CSV emitido. Lo que eso demuestra, por orden de importancia:

- **La huella coincide con la que recalcula la AEAT.** Un desajuste habría dado
  `AceptadoConErrores` con obligación de subsanar (ap. 4.3.1), y salió `Correcto`
  limpio. Es la validación que ningún test propio puede dar: confirma la cadena
  de serialización, el formateo de importes y la marca temporal con offset,
  todo contra el recálculo real del servicio.
- El XML pasa las validaciones de negocio, no solo el XSD.
- El transporte completo funciona: mTLS, sobre SOAP, endpoint y lectura de la
  respuesta.

Lo que **NO** demuestra, y conviene no dar por bueno: fue un alta F1 con una sola
línea de desglose y `PrimerRegistro`. Siguen sin probarse contra el servicio real
el encadenamiento, las anulaciones, las rectificativas, la subsanación y los lotes
de más de un registro. Tampoco se ejercitaron las validaciones de rechazo: una
factura válida no recorre esos caminos.

Primeros envíos reales a `prewww1.aeat.es` con un certificado de representante de
la FNMT. Lo que confirman:

- **mTLS funciona sin `ca_file`.** `HTTP 200` a la primera. Cierra el punto 3 de
  "pendiente de verificar" del traspaso, que ya se había descartado inspeccionando
  la cadena TLS y ahora tiene una prueba de verdad.
- **`Certificado#sello?` acierta el caso negativo.** Un certificado de
  representante da `false` y va a `prewww1`, que es lo correcto. Queda sin probar
  el caso positivo (un certificado de sello real).
- **El sobre SOAP llevaba dos declaraciones XML.** Respuesta:
  `Codigo[102].Error interno en el servidor`. Era un fallo de parseo, no de
  negocio, y por eso el mensaje no orientaba. Corregido en `Transporte#envolver`.
- **El NIF se valida en dos pasos, con códigos distintos**: `4116` si el dígito de
  control no cuadra y `4104` si el formato es correcto pero el NIF no consta como
  obligado. Un NIF inventado con forma plausible (`B12345678`) cae en el 4116.
- **Los fallos de servicio llegan como SOAP Fault**, no como
  `RespuestaSuministro`, con el código dentro de `faultstring` en el formato
  `Codigo[NNNN].descripción`. `Respuesta` lo extrae.
- **La identificación del obligado es por el PAR NIF + NombreRazon.** Con el NIF
  correcto y un nombre que no cuadre con el censo, la AEAT responde 4104 "el NIF
  no está identificado", que apunta al campo equivocado. El detalle del error sí
  devuelve los dos campos, y ahí está la pista. Lo mismo aplica al destinatario,
  con el código 1239.
- **`Respuesta` leyó correctamente una respuesta real**: `EstadoEnvio`,
  `TiempoEsperaEnvio` y la línea con su código y descripción.
- **`TiempoEsperaEnvio` devolvió 60**, el valor inicial que fija el art. 16.2 de
  la Orden.

### Códigos que confirman reglas deducidas del PDF

Estos existen como error propio de la AEAT, lo que respalda las validaciones que
se implementaron leyendo el ap. 15 de Validaciones:

| Código | Regla | Dónde se implementa |
|---|---|---|
| 1237 | N1/N2 con IVA no admiten tipo, cuota ni recargo | `Detalle#validar_calificacion!` |
| 1238 | Una exenta no admite esos cuatro campos | `Detalle#validar_exenta!` |
| 1245 | ClaveRegimen obligatoria con IVA/IPSI/IGIC | `Detalle#validar_clave_regimen!` |
| 1232-1234 | Reglas cruzadas de IDType y CodigoPais | `Destinatario#normalizar_id_otro` |
| 1235-1236 | Ventanas temporales de TipoImpositivo | **pendiente** |

## Ejemplos de registro

`ejemploRegistro.xml` y `ejemploRegistro-firmado-epes-xades4j.xml` (fuera del
repositorio). El segundo es el primero más un `ds:Signature` XAdES-EPES adosado,
lo que confirma que la firma es un añadido opcional y no altera el resto del
documento: coherente con implementar solo VERI\*FACTU.
