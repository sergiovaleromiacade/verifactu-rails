# verifactu-rails

Componente Ruby para la integración con **VERI\*FACTU** (AEAT), orientado a Rails.

> **Estado: en desarrollo, sin release público.** El generador de XML y la capa
> Rails todavía no existen. La API puede cambiar sin aviso.

## Qué es y qué no es

Esto es una **librería**: calcula la huella encadenada, formatea importes de forma
canónica y habla con la AEAT por TLS mutuo. No es un sistema de facturación llave
en mano, y no se afirma aquí que su uso baste para cumplir el RD 1007/2023 ni la
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
| `VerifactuRails::Certificado` | Carga de PKCS12, caducidad, detección de sello |
| `VerifactuRails::Transporte` | Cliente HTTP con TLS mutuo contra el endpoint correcto |

Pendiente: generador de XML, QR de cotejo, capa Rails (modelo append-only, job con
lock por NIF+serie).

## Uso

```ruby
require 'verifactu-rails'

huella = VerifactuRails::Huella.alta(
  id_emisor:        'B12345678',
  num_serie:        'FA/2026/0001',
  fecha_expedicion: Date.new(2026, 8, 6),
  tipo_factura:     'F1',
  cuota_total:      BigDecimal('21.00'),
  importe_total:    BigDecimal('121.00'),
  fecha_hora_gen:   Time.now,
  huella_anterior:  nil   # nil solo en el primer registro de la cadena NIF+serie
)
```

Cuando la AEAT rechace por huella, lo primero que hay que mirar no es el digest
sino la cadena que lo produce, que `Huella.serializar` expone tal cual.

## Avisos de implementación

- **`Float` está prohibido** en importes: se rechaza en la entrada. Usa
  `BigDecimal`, `Integer` o `String`. El redondeo es `ROUND_HALF_UP`, no el
  bancario que Ruby trae por defecto.
- **Los espacios al borde se rechazan**, no se recortan. La especificación es
  ambigua y es preferible fallar pronto y ruidosamente.
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

42 tests, ~1100 aserciones. Incluye verificación cruzada de la huella contra
`josemmo/Verifactu-PHP` y `mybooking-es/verifactu-rb`.

Los vectores oficiales de la AEAT todavía **no** están incorporados: hoy tenemos
concordancia con dos implementaciones independientes, que no es lo mismo que la
fuente primaria.

## Licencia

MIT. Se distribuye sin garantía de ningún tipo; ver [LICENSE](LICENSE).
