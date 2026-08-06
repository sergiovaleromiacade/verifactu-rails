# verifactu-rails

Componente Ruby para la integración con **VERI\*FACTU** (AEAT), orientado a Rails.

> **Estado: en desarrollo, sin release público.** La capa Rails todavía no existe
> y nada se ha probado aún contra el entorno real de la AEAT. La API puede cambiar
> sin aviso.

## Qué es y qué no es

Esto es una **librería**: calcula la huella encadenada, formatea importes de forma
canónica, genera el XML de los registros y habla con la AEAT por TLS mutuo. No es
un sistema de facturación llave en mano, y no se afirma aquí que su uso baste para
cumplir el RD 1007/2023 ni la
Orden HAC/1177/2024. La responsabilidad de la declaración responsable del art. 13
recae en quien despliega el sistema de facturación, no en el autor de esta gema.
Ver [COMPLIANCE.md](COMPLIANCE.md) cuando exista.

## Alcance

**Solo modalidad VERI\*FACTU** (remisión continua a la AEAT). No se implementa el
modo NO VERI\*FACTU: exigiría firma XAdES de cada registro y registro de eventos.
La AEAT contempla explícitamente esta reducción de alcance (FAQs Desarrolladores
v1.3, ap. 15, nota 1).

Fuera de alcance: Facturae/B2G, TicketBAI/Batuz, TPV.

## Requisitos

- Ruby >= 3.0
- Certificado del obligado tributario en formato PKCS12. Se **recomienda
  certificado de sello de entidad** antes que el de representante: menor radio de
  explosión si se filtra, y la AEAT le asigna endpoints propios.

## Componentes

| Módulo | Qué hace |
|---|---|
| `VerifactuRails::Huella` | Serialización canónica y SHA-256 del registro (alta y anulación) |
| `VerifactuRails::Importe` | Formateo de importes; el mismo string va en la huella y en el XML |
| `VerifactuRails::Formato` | Fechas, marcas temporales y NIF, normalizados en un único sitio |
| `VerifactuRails::Detalle` / `Desglose` | Líneas del desglose de IVA (máximo 12) |
| `VerifactuRails::SistemaInformatico` | Identificación del SIF, obligatoria en cada registro |
| `VerifactuRails::RegistroAlta` / `RegistroAnulacion` | El registro: calcula su huella y emite su XML |
| `VerifactuRails::Envio` | Documento `RegFactuSistemaFacturacion` (lote de hasta 1000) |
| `VerifactuRails::Certificado` | Carga de PKCS12, caducidad, detección de sello |
| `VerifactuRails::Transporte` | Cliente HTTP con TLS mutuo contra el endpoint correcto |

Pendiente: QR de cotejo, capa Rails (modelo append-only, job con lock por
NIF+serie).

### Rectificativas

`R1`–`R5` exigen `tipo_rectificativa:`. `facturas_rectificadas:` es opcional pero
exclusiva de `R1`–`R5`, y `facturas_sustituidas:` es opcional pero exclusiva de
`F3`. La diferencia entre los dos tipos de rectificativa sí importa:

- **`'S'` sustitutiva** — la factura reexpresa el importe corregido completo, así
  que hay que declarar el original en `importe_rectificacion:`.
- **`'I'` incremental** — los importes de la propia factura *ya son* la
  diferencia, y `importe_rectificacion:` se rechaza.

```ruby
RegistroAlta.new(
  ..., tipo_factura: 'R1', tipo_rectificativa: 'S',
  facturas_rectificadas: [IdFactura.new(id_emisor: 'B12345678',
                                        num_serie: 'FA/2026/0001',
                                        fecha_expedicion: Date.new(2026, 8, 1))],
  importe_rectificacion: ImporteRectificacion.new(base: BigDecimal('100.00'),
                                                  cuota: BigDecimal('21.00'))
)
```

El XSD deja casi todos estos campos opcionales, así que estas reglas las impone la
gema, no el esquema: sin ellas se puede montar un `R1` sintácticamente válido que
la AEAT rechaza con un error mucho menos claro.

## Uso

```ruby
require 'verifactu-rails'
include VerifactuRails

# Quien despliega el SIF se identifica; no es esta gema, es tu sistema.
sistema = SistemaInformatico.new(
  nombre_razon: 'Tu Empresa SL', nif: 'B12345678',
  nombre_sistema: 'TuFactura', id_sistema: '01',
  version: '1.0.0', numero_instalacion: 'INST-1'
)

registro = RegistroAlta.new(
  id_emisor: 'B12345678', num_serie: 'FA/2026/0001',
  fecha_expedicion: Date.new(2026, 8, 6), nombre_razon_emisor: 'Tu Empresa SL',
  tipo_factura: 'F1', descripcion_operacion: 'Servicios de agosto',
  desglose: [Detalle.new(base_imponible: BigDecimal('100.00'), calificacion: 'S1',
                         tipo_impositivo: BigDecimal('21.00'),
                         cuota_repercutida: BigDecimal('21.00'))],
  cuota_total: BigDecimal('21.00'), importe_total: BigDecimal('121.00'),
  sistema_informatico: sistema, fecha_hora_gen: Time.now,
  destinatarios: [Destinatario.new(nombre_razon: 'Cliente SL', nif: 'B87654321')]
)

# `anterior` es nil solo en el primer registro de la cadena de ese NIF+serie.
xml = Envio.new(nif_obligado: 'B12345678', nombre_obligado: 'Tu Empresa SL',
                entradas: [[registro, anterior]]).to_xml
```

El registro calcula su huella y monta su XML **a partir de los mismos campos ya
normalizados**, para que no puedan divergir: la AEAT recalcula la huella sobre el
XML que recibe.

Matiz importante, contrastado con la fuente primaria: una huella que no cuadra
**no provoca rechazo**. Es un *error admisible*, así que el registro se acepta y
queda registrado, pero **obliga a subsanarlo** (Validaciones v1.2.2, ap. 4.3.1).
Sigue siendo algo que no quieres, solo que el coste es una subsanación y no un
envío perdido.

Otro matiz: al generar la huella, la AEAT ignora los ceros a la derecha en los
campos numéricos —`123.1` y `123.10` valen igual—, de modo que la exigencia real
no es un formato concreto sino **coherencia entre la huella y el XML**.

Cuando la AEAT rechace por huella, lo primero que hay que mirar no es el digest
sino la cadena que lo produce, que `Huella.serializar` expone tal cual.

## Avisos de implementación

- **`Float` está prohibido** en importes: se rechaza en la entrada. Usa
  `BigDecimal`, `Integer` o `String`. El redondeo es `ROUND_HALF_UP`, no el
  bancario que Ruby trae por defecto.
- **Los espacios al borde se rechazan**, no se recortan. La especificación manda
  recortarlos, así que esto es *más estricto* que la norma: un valor con espacios
  al borde casi siempre es un defecto de los datos de origen y recortar en
  silencio lo taparía. Los espacios interiores sí se respetan.
- **Nunca `VERIFY_NONE`.** Si falla la verificación TLS contra la AEAT, falta la
  cadena de la CA en `ca_file`; desactivar la comprobación no es el arreglo.
- **El encadenamiento es estrictamente serial.** Rails procesa en paralelo: hace
  falta un lock a nivel de base de datos por NIF+serie, no por factura.
- **Los números de factura anulada no se reutilizan.** La AEAT responde "Registro
  de facturación duplicado".

## Tests

```sh
bundle exec rake test
```

90 tests, ~1230 aserciones. Incluye verificación cruzada de la huella contra
`josemmo/Verifactu-PHP` y `mybooking-es/verifactu-rb`, y validación del XML
generado contra los XSD oficiales de la AEAT, versionados en
[lib/verifactu_rails/schemas](lib/verifactu_rails/schemas/PROCEDENCIA.md).

Los **tres vectores oficiales** de la AEAT (Especificaciones huella v0.1.2, ap. 6)
están incorporados y se reproducen exactamente, incluido el encadenamiento entre
ellos. La verificación contra las otras dos implementaciones se conserva porque
cubre muchos más casos de los que la AEAT publica.

## Licencia

MIT. Se distribuye sin garantía de ningún tipo; ver [LICENSE](LICENSE).
