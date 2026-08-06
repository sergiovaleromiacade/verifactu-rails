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

## Ejemplos de registro

`ejemploRegistro.xml` y `ejemploRegistro-firmado-epes-xades4j.xml` (fuera del
repositorio). El segundo es el primero más un `ds:Signature` XAdES-EPES adosado,
lo que confirma que la firma es un añadido opcional y no altera el resto del
documento: coherente con implementar solo VERI\*FACTU.
