# Procedencia de los esquemas

Estos ficheros son **el contrato con la AEAT**. Se versionan tal cual se sirven,
byte a byte, para que un `git diff` muestre exactamente qué cambia cuando la AEAT
los toca. **No editarlos nunca**, ni siquiera para arreglar rutas: ver más abajo
cómo se resuelve la dependencia remota sin tocarlos.

Descargados el **6 de agosto de 2026** de:

```
https://prewww2.aeat.es/static_files/common/internet/dep/aplicaciones/es/aeat/tikeV1.0/cont/ws/
```

## Ficheros de la AEAT

| Fichero | En alcance | SHA-256 |
|---|---|---|
| `SuministroInformacion.xsd` | sí — núcleo, define `RegistroAlta`/`RegistroAnulacion` | `ee4c1655175644de…` |
| `SuministroLR.xsd` | sí — envoltorio de envío, `RegFactuSistemaFacturacion` | `cbdac8d427cc5ab5…` |
| `RespuestaSuministro.xsd` | sí — respuesta al envío | `82acf80f785643ca…` |
| `ConsultaLR.xsd` | sí — consulta de registros remitidos | `bf2cdb8fc4b95b29…` |
| `RespuestaConsultaLR.xsd` | sí — respuesta a la consulta | `de35063acb8d9ba0…` |
| `EventosSIF.xsd` | **no** — registro de eventos, solo NO VERI\*FACTU | `cc7347c6a9a57a0c…` |
| `RespuestaValRegistNoVeriFactu.xsd` | **no** — validación NO VERI\*FACTU | `8f47af4f3c49d29b…` |

Los dos fuera de alcance se conservan como referencia del contrato completo; no se
compilan en los tests.

## Ficheros que NO son de la AEAT

- `xmldsig-core-schema.xsd` — del W3C (`http://www.w3.org/TR/xmldsig-core/`),
  SHA-256 `d102ad3df7664c30…`
- `catalog.xml` — nuestro, no viene de ninguna fuente externa

## Por qué hace falta el catálogo

`SuministroInformacion.xsd` importa el esquema de firma del W3C **por URL remota**:

```xml
<import namespace="http://www.w3.org/2000/09/xmldsig#"
        schemaLocation="http://www.w3.org/TR/xmldsig-core/xmldsig-core-schema.xsd"/>
```

libxml2 bloquea por defecto la carga de entidades de red (y hace bien), así que sin
más el esquema no compila: `Attempt to load network entity`.

La salida es un catálogo XML OASIS que redirige esa URL al fichero local, sin tocar
el XSD de la AEAT. Se activa con la variable de entorno `XML_CATALOG_FILES`, que
**pone el proceso de tests**, no la librería: una gema no debe escribir en una
variable de entorno global que el proceso anfitrión también podría estar usando.

```ruby
ENV['XML_CATALOG_FILES'] = File.expand_path('catalog.xml', __dir__)
```

Que la firma no se pueda resolver offline es, en la práctica, irrelevante para esta
gema: en modalidad VERI\*FACTU `ds:Signature` es **opcional** en el esquema y no la
emitimos. El import hay que resolverlo igualmente solo para que el XSD compile.

## Cómo actualizar

Volver a descargar sobre estos mismos ficheros y mirar el `git diff`. Si cambia
algo, actualizar los SHA-256 de `test/esquemas_test.rb` **en el mismo commit** que
el cambio del esquema, para que quede constancia de qué se aceptó y cuándo.
