# verifactu-rails

Componente Ruby para la integración con **VERI\*FACTU** (AEAT), orientado a Rails.

> **Estado: en desarrollo, sin release público.** La capa Rails cierra el ciclo
> —libro registro, encadenamiento bajo lock, autochequeo y envío por lotes— y ha
> sido ejercitada contra el entorno de pruebas de la AEAT de punta a punta. Falta
> la reconciliación contra la consulta.
> El entorno de pruebas de la AEAT ha aceptado, con la huella validada por su
> propio recálculo: altas encadenadas, un lote de tres registros encadenados
> entre sí en un mismo envío, una anulación, una rectificativa R1 sustitutiva y
> una subsanación. La consulta contra el servicio real confirma además qué queda
> *anotado*: la subsanación sustituye al registro original y la anulación deja la
> factura en estado `Anulado`. La API puede cambiar sin aviso.

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
- Certificado del obligado tributario en formato PKCS12. Vale el de
  representante, que es el camino contrastado contra el servicio real.
- El **certificado de sello de entidad** también está soportado: la AEAT le
  asigna endpoints propios y `Transporte` los elige solo. Con él, declara
  `sello: true` de forma explícita en vez de fiarte de la detección automática,
  que adivina a partir del sujeto del certificado y no se ha podido contrastar
  con un sello real (la AEAT no emite certificados de prueba).

## Instalación

```ruby
# Gemfile
gem 'verifactu-rails'
```

```sh
rails g verifactu:install
rails db:migrate
```

El generador deja dos ficheros:

- **`db/migrate/…_instalar_verifactu.rb`**, que no copia el esquema: hereda de
  `VerifactuRails::Libro::Migracion`. Así lo que ejecuta tu `db:migrate` es
  exactamente el esquema que ejercita la suite de tests de la gema, índices
  únicos incluidos. Esa clase está congelada como esquema v1 por ese motivo:
  cualquier cambio futuro llegará como migración nueva, nunca editándola.
- **`config/initializers/verifactu.rb`**, con la identificación de tu SIF. Los
  valores vienen inválidos a propósito: con ellos el primer `anotar_alta!`
  levanta una `ValidacionError` en vez de remitir a la AEAT una identificación
  de sistema inventada.

Lo que el generador **no** hace, y no es un olvido:

- **No abre ninguna cadena.** El `NumeroInstalacion` no se autogenera en ninguna
  parte de esta gema. Un contenedor que se recrea en cada despliegue acabaría
  abriendo una instalación por despliegue, y eso vacía de sentido el
  encadenamiento.
- **No decide dónde vive tu certificado.** `Certificado` recibe los bytes ya
  cargados y no sabe leer ficheros ni variables de entorno: dónde se guarda la
  credencial es una decisión de quien despliega, no de una plantilla.

## Componentes

| Módulo | Qué hace |
|---|---|
| `VerifactuRails::Huella` | Serialización canónica y SHA-256 del registro (alta y anulación) |
| `VerifactuRails::Importe` | Formateo de importes; el mismo string va en la huella y en el XML |
| `VerifactuRails::Formato` | Fechas, marcas temporales y NIF, normalizados en un único sitio |
| `VerifactuRails::Detalle` / `Desglose` | Líneas del desglose de IVA (máximo 12) |
| `VerifactuRails::Destinatario` / `Tercero` | Identificación del cliente y de quien expide por cuenta ajena |
| `VerifactuRails::SistemaInformatico` | Identificación del SIF, obligatoria en cada registro |
| `VerifactuRails::RegistroAlta` / `RegistroAnulacion` | El registro: calcula su huella y emite su XML |
| `VerifactuRails::Envio` | Documento `RegFactuSistemaFacturacion` (lote de hasta 1000) |
| `VerifactuRails::Consulta` / `RespuestaConsulta` | Consulta de lo ya anotado: estados, encadenamiento guardado y paginación |
| `VerifactuRails::Certificado` | Carga de PKCS12, caducidad, detección de sello |
| `VerifactuRails::Transporte` | Cliente HTTP con TLS mutuo contra el endpoint correcto |
| `VerifactuRails::QR` | URL de cotejo del código QR. La AEAT no la devuelve: la construye el SIF |
| `VerifactuRails::Libro` | Capa Rails: libro registro append-only, encadenamiento bajo lock y autochequeo |
| `VerifactuRails::Libro::Remesa` | Envío por lotes de lo pendiente, con control de flujo y reintentos |

La capa `Libro` se carga aparte (`require 'verifactu_rails/libro'`) porque exige
ActiveRecord; el núcleo no depende de Rails. En una app Rails ese require sobra:
lo hace el railtie en cuanto ActiveRecord está listo. Pendiente: el job de
reconciliación contra la consulta.

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
  facturas_rectificadas: [IdFactura.new(id_emisor: '89890001K',
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
  nombre_razon: 'Tu Empresa SL', nif: '89890001K',
  nombre_sistema: 'TuFactura', id_sistema: '01',
  version: '1.0.0', numero_instalacion: 'INST-1'
)

registro = RegistroAlta.new(
  id_emisor: '89890001K', num_serie: 'FA/2026/0001',
  fecha_expedicion: Date.new(2026, 8, 6), nombre_razon_emisor: 'Tu Empresa SL',
  tipo_factura: 'F1', descripcion_operacion: 'Servicios de agosto',
  desglose: [Detalle.new(base_imponible: BigDecimal('100.00'), calificacion: 'S1',
                         tipo_impositivo: BigDecimal('21.00'),
                         cuota_repercutida: BigDecimal('21.00'))],
  cuota_total: BigDecimal('21.00'), importe_total: BigDecimal('121.00'),
  sistema_informatico: sistema, fecha_hora_gen: Time.now,
  destinatarios: [Destinatario.new(nombre_razon: 'Cliente SL', nif: '89890002E')]
)

# `anterior` es nil solo en el PRIMER registro de ese SIF+NIF. La cadena es una
# sola por sistema y obligado, no una por serie.
xml = Envio.new(nif_obligado: '89890001K', nombre_obligado: 'Tu Empresa SL',
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

## La capa Rails: el libro registro

```ruby
# En Rails esto lo deja hecho `rails g verifactu:install` y el require sobra.
# Fuera de Rails: require 'verifactu_rails/libro'

VerifactuRails::Libro.configure do |c|
  c.productor_nombre = 'Tu Empresa SL'   # quién PRODUCE el software
  c.productor_nif    = '89890001K'
  c.nombre_sistema   = 'TuFactura'
  c.id_sistema       = '01'
  c.version          = TuApp::VERSION
  c.entorno          = Rails.env.production? ? :produccion : :pruebas
end

```

Una cadena se abre **una sola vez** por fuente de facturación y se queda en la
base de datos. No es configuración: es un dato. Va en un `db/seeds.rb`, en una
tarea rake de alta de tienda o en tu panel de administración, nunca en un
initializer ni en el camino de la factura.

```ruby
# UNA VEZ, al dar de alta la tienda/TPV/sede. El nº de instalación NO se genera
# solo y no se reutiliza JAMÁS, ni al reinstalar en la misma máquina.
VerifactuRails::Libro::Cadena.abrir!(
  numero_instalacion: 'TIENDA-VALENCIA-20260807120000',
  nif_obligado: '89890001K', nombre_obligado: 'Tu Empresa SL'
)
```

A partir de ahí, en cada factura se **recupera** esa cadena, no se abre otra:

```ruby
cadena = VerifactuRails::Libro::Cadena.find_by!(
  numero_instalacion: tienda.numero_instalacion
)

registro = cadena.anotar_alta!(id_emisor: '89890001K', num_serie: 'FA/2026/0001', ...)
registro.qr_url   # ya disponible: el QR no depende de la AEAT
```

Guarda el `numero_instalacion` en tu propio modelo (la tienda, el TPV, la
empresa) y búscala por ahí. Si tu instalación es única, `Cadena.sole` sirve y
además te avisa si algún día deja de serlo, cosa que `first` no hace.

`anotar_alta!` calcula la huella, encadena y genera el QR **en una transacción con
la fila de la cadena bloqueada**. Tres cosas que conviene entender:

- **Bifurcar la cadena es imposible**, y no por el lock: por un índice único sobre
  `(cadena_id, huella_anterior)`. Está comprobado que la AEAT acepta una cadena
  bifurcada sin avisar, así que esa restricción es la única red que hay. Hay un
  test con ocho hilos que lo demuestra quitando el lock.
- **Una anomalía nunca interrumpe la facturación.** El autochequeo del art. 7.i)
  de la Orden se anota en la columna `anomalias` y se notifica, pero no lanza. Con
  datos inválidos sí se falla: ahí no hay factura que emitir tampoco.
- **El número de instalación no se autogenera jamás.** Si la gema lo hiciera, un
  contenedor que se recrea en cada despliegue abriría una instalación por
  despliegue, y eso vacía de sentido el encadenamiento.

### Enviar

```ruby
class EnviarRemesaJob < ApplicationJob
  def perform(numero_instalacion)
    cadena = VerifactuRails::Libro::Cadena.find_by!(numero_instalacion: numero_instalacion)

    # Certificado y transporte se construyen AQUÍ, no una vez al arrancar.
    certificado = VerifactuRails::Certificado.desde_pkcs12(bytes_del_p12, password)
    transporte  = VerifactuRails::Transporte.new(certificado: certificado,
                                                 entorno: VerifactuRails::Libro.configuracion.entorno)

    VerifactuRails::Libro::Remesa.new(cadena, transporte: transporte).enviar!
    # => #<Resultado estado: :enviado|:esperando|:nada_pendiente|:bloqueada_por_rechazo>
  end
end
```

La remesa no recibe registros: coge de la base de datos lo que esa cadena tenga
pendiente. Por eso lo único que hay que pasarle es la cadena, recuperada por su
número de instalación.

Sobre construir el transporte en cada envío, que parece derrochón y no lo es:
**`Transporte` no guarda ninguna conexión**. Abre un `Net::HTTP` nuevo dentro de
cada `enviar`, así que reutilizar el objeto no ahorra un solo handshake —el mTLS
completo se paga igual— y solo conseguirías compartir estado entre hilos. El
handshake, además, es uno por *remesa*, no por factura: el lote entero va en una
petición.

Con el certificado el razonamiento es el mismo pero por otro motivo: `Certificado`
comprueba la caducidad **al construirse**. Cachearlo al arrancar un proceso que
vive meses es justo lo que hace que el día que caduque no te avise esa
comprobación, sino un error TLS de la AEAT, que orienta mucho peor. Parsear el
PKCS12 cuesta milisegundos; el aviso vale más.

Llámalo desde un job encolado tras `anotar_alta!`, y también desde un cron de
seguridad por si un job se perdió. Es idempotente: reenviar algo ya anotado
devuelve "duplicado", y eso **cuenta como éxito**.

- **Agrupar no es el modo normal.** Las FAQs exigen remisión "inmediata o sin
  demora apreciable" a la expedición. Un comercio que factura cada diez minutos
  mandará siempre un registro por petición; el tope de 1000 es un techo para quien
  factura rápido. El tamaño del lote lo dicta el ritmo, no una decisión tuya.
- **Un rechazo detiene la cadena.** Un registro rechazado no consta en la AEAT, y
  todo lo que encadena detrás apunta a un eslabón que allí no existe. Seguir
  enviando funcionaría —la AEAT no valida el eslabón al recibir— y dejaría una
  cadena incoherente aceptada en silencio. Resolverlo es una decisión de negocio.

## Avisos de implementación

- **`Float` está prohibido** en importes: se rechaza en la entrada. Usa
  `BigDecimal`, `Integer` o `String`. El redondeo es `ROUND_HALF_UP`, no el
  bancario que Ruby trae por defecto.
- **Los espacios al borde se rechazan**, no se recortan. La especificación manda
  recortarlos, así que esto es *más estricto* que la norma: un valor con espacios
  al borde casi siempre es un defecto de los datos de origen y recortar en
  silencio lo taparía. Los espacios interiores sí se respetan.
- **Nunca `VERIFY_NONE`.** Desde la renovación de noviembre de 2025 la AEAT sirve
  con CA públicas (Entrust/Sectigo bajo USERTrust RSA), así que `ca_file` **no
  hace falta**: los cinco endpoints validan con el almacén del sistema. Si aun así
  falla, sospecha de un almacén anticuado o de un proxy que intercepte el TLS.
  Desactivar la comprobación nunca es el arreglo.
- **El encadenamiento es estrictamente serial.** Rails procesa en paralelo: hace
  falta un lock a nivel de base de datos por SIF+NIF, no por serie ni por factura.
- **La consulta devuelve una foto, no un libro.** Una fila por factura con su
  estado actual, no el histórico de registros: si una factura se subsanó o se
  anuló, su alta original ya no se devuelve. El histórico de la cadena hay que
  guardarlo uno mismo; `ConsultaLR` sirve para reconciliar el estado de cada
  factura, no para auditar el encadenamiento.
- **Los números de factura anulada no se reutilizan.** La AEAT responde "Registro
  de facturación duplicado". La excepción es la **subsanación**, que reusa el
  mismo `IDFactura` a propósito: con `subsanacion: 'S'` el reenvío se anota como
  corrección y no choca con el duplicado (comprobado contra preproducción).

## Tests

```sh
createdb verifactu_rails_test   # solo la primera vez
bundle exec rake test
```

Los tests del libro registro necesitan una base de datos **de verdad**: hay que
demostrar que un índice único impide bifurcar la cadena y que el lock serializa, y
eso no se simula con dobles. Se usa, por este orden, la conexión que ya haya
establecida, `VF_DATABASE_URL` o `DATABASE_URL`, y si no PostgreSQL local en
`verifactu_rails_test`.

Si no hay ninguna, la suite **aborta**; no se salta esos tests. Saltarlos los
convertiría en cobertura fantasma: desaparecerían en silencio justo en los
entornos mal configurados, que es donde más falta hacen.

218 tests, ~1760 aserciones. Incluye verificación cruzada de la huella contra
`josemmo/Verifactu-PHP` y `mybooking-es/verifactu-rb`, y validación del XML
generado contra los XSD oficiales de la AEAT, versionados en
[lib/verifactu_rails/schemas](lib/verifactu_rails/schemas/PROCEDENCIA.md).

Los **tres vectores oficiales** de la AEAT (Especificaciones huella v0.1.2, ap. 6)
están incorporados y se reproducen exactamente, incluido el encadenamiento entre
ellos. La verificación contra las otras dos implementaciones se conserva porque
cubre muchos más casos de los que la AEAT publica.

## Licencia

MIT. Se distribuye sin garantía de ningún tipo; ver [LICENSE](LICENSE).
